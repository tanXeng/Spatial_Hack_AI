import Foundation
import QuartzCore
import RealityKit
import simd

enum AuraPunchPhase: String, Sendable {
    case idle
    /// Waiting for hands and head to be tracked well enough to place a shoulder.
    case acquiring
    /// The ghost leads the punch and waits at each end for the user to match it.
    case guiding
    /// Counting the user in before their attempt.
    case countdown
    /// Capturing the user's attempt.
    case attempting
    /// Comparing and writing feedback.
    case scoring
    case results
}

/// Drives one Aura Punch rep: demo → attempt → score → feedback.
///
/// Shares the `HandTrackingService` and the immersive scene root with Reactive Strike rather than
/// standing up its own — two ARKit sessions competing for the same providers is a good way to get
/// neither.
@Observable
@MainActor
final class AuraPunchSession {
    // MARK: Configuration

    var technique: Technique = .jab
    var stance: Stance = .orthodox

    /// Anthropometry will populate this later; until then every user gets average proportions.
    var measurements: BodyMeasurements = .averageAdult

    /// How many call-and-response reps the ghost leads before the scored attempt.
    ///
    /// Four is enough for the speed-up to be felt without the warm-up outlasting the user's
    /// patience — the ghost waits for them at both ends, so a slow first rep costs real time.
    var guidedRepetitions = 4

    /// Each guided rep plays in this fraction of the previous rep's wall-clock duration, so the
    /// punch gets progressively faster and the user is pulled up to speed rather than being
    /// asked to match a full-speed punch cold.
    var guidedSpeedUp: Double = 0.85

    /// Floor on the compounding speed-up. Without it, rep four of a 0.5 s jab would be asking a
    /// beginner to complete a punch faster than they can perceive the cue to start it.
    var minimumGuidedSpeedFactor: Double = 0.55

    /// Fraction of the reference's peak reach the user must hit for the ghost to accept the
    /// extension and start coming back. Relative to the reference rather than absolute because a
    /// hook peaks near 0.70 by design — an absolute threshold would be unreachable for it.
    var followExtensionFraction: Float = 0.80

    /// Fraction of peak reach the user must drop back under to count as returned to guard.
    var followGuardFraction: Float = 0.45

    /// How long the ghost holds a position waiting for the user before moving on anyway.
    ///
    /// Without a ceiling the guide deadlocks whenever tracking is poor or the user simply stops,
    /// leaving a frozen arm and no way forward except quitting the feature.
    var followHoldTimeout: TimeInterval = 6

    /// How long the user's attempt is captured for. The recorder trims the idle time at either
    /// end, so this only needs to be comfortably longer than a punch.
    var attemptWindow: TimeInterval = 3.0

    // MARK: Observable state

    private(set) var phase: AuraPunchPhase = .idle
    private(set) var statusMessage = "Ready"
    private(set) var errorMessage: String?
    private(set) var score: TechniqueScore?
    private(set) var feedback: CoachingFeedback?
    private(set) var currentDemoRep = 0
    /// Live reach fraction during the attempt, for the UI's punch meter.
    private(set) var liveReach: Float = 0

    var isRunning: Bool {
        phase != .idle && phase != .results
    }

    // MARK: Collaborators

    private let hands: HandTrackingService
    /// One recorder per arm. Both run through the attempt so the session can tell which hand the
    /// user actually threw with instead of assuming they used the one that was asked for.
    private let recorders: [BodySide: MotionRecorder] = [
        .left: MotionRecorder(),
        .right: MotionRecorder()
    ]
    private let scorer = TechniqueScorer()
    private let feedbackGenerator: FeedbackGenerating

    private var demoArm: ArmSilhouetteEntity?
    private var mirrorArm: ArmSilhouetteEntity?
    private weak var sceneRoot: Entity?

    private var loopTask: Task<Void, Never>?

    /// Frame interval for the pose loop. Hand tracking runs at ~90 Hz; polling faster just burns
    /// cycles re-reading the same anchor.
    private let frameInterval: Duration = .milliseconds(11)

    init(hands: HandTrackingService, feedbackGenerator: FeedbackGenerating = MockFeedbackGenerator()) {
        self.hands = hands
        self.feedbackGenerator = feedbackGenerator
    }

    // MARK: Scene

    /// Called when the immersive space comes up. Builds the ghost arms lazily so nothing is
    /// allocated for users who never open Aura Punch.
    func attach(to root: Entity) {
        // The immersive space can be closed and reopened, which hands us a fresh root each time.
        detach()
        sceneRoot = root

        let punchingSide = technique.hand.side(for: stance)

        let demo = ArmSilhouetteEntity(side: punchingSide, tint: .demo)
        demo.attach(to: root)
        demoArm = demo

        let mirror = ArmSilhouetteEntity(side: punchingSide, tint: .mirror)
        mirror.attach(to: root)
        mirrorArm = mirror
    }

    func detach() {
        demoArm?.removeFromScene()
        mirrorArm?.removeFromScene()
        demoArm = nil
        mirrorArm = nil
        sceneRoot = nil
    }

    // MARK: Control

    func start() {
        guard phase == .idle || phase == .results else { return }

        score = nil
        feedback = nil
        errorMessage = nil
        currentDemoRep = 0
        liveReach = 0

        // Rebuild the ghost arms for the currently selected technique — switching from a jab to a
        // cross switches which arm throws, and a silhouette built for the old side would appear
        // on the wrong arm.
        if let root = sceneRoot {
            attach(to: root)
        }

        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    func stop() {
        // No-op when nothing is running, so Reactive Strike's own stop path — which shares this
        // call — never clears a finished Aura Punch result out from under the user.
        guard isRunning else { return }

        loopTask?.cancel()
        loopTask = nil
        for recorder in recorders.values { recorder.cancel() }
        demoArm?.isVisible = false
        mirrorArm?.isVisible = false
        phase = .idle
        statusMessage = "Stopped"
    }

    func reset() {
        stop()
        phase = .idle
        score = nil
        feedback = nil
        errorMessage = nil
        statusMessage = "Ready"
    }

    // MARK: Session loop

    private func runSession() async {
        let solver = ArmPoseSolver(measurements: measurements)
        let demoSide = technique.hand.side(for: stance)
        let demoReference = ReferencePunchLibrary.punch(
            for: technique,
            stance: stance,
            measurements: measurements,
            side: demoSide
        )

        guard await acquireTracking() else { return }
        guard !Task.isCancelled else { return }

        await runGuidedFollowAlong(reference: demoReference, side: demoSide, solver: solver)
        guard !Task.isCancelled else { return }

        await runCountdown()
        guard !Task.isCancelled else { return }

        let capture = await recordAttempt(solver: solver)
        guard !Task.isCancelled else { return }

        guard let capture else {
            fail("Couldn't see a punch. Keep both hands in view and throw again.")
            return
        }

        // Score against a reference mirrored onto the arm they actually used, so a jab thrown off
        // the wrong hand is graded as a jab and reported as a hand fault — rather than being
        // compared to the opposite arm and failing every geometry metric for the wrong reason.
        let scoringReference = ReferencePunchLibrary.punch(
            for: technique,
            stance: stance,
            measurements: measurements,
            side: capture.side
        )
        await finish(
            attempt: capture.attempt,
            reference: scoringReference,
            thrownSide: capture.side
        )
    }

    /// Blocks until head and hand tracking are both usable, or gives up.
    ///
    /// Aura Punch cannot start without both: the head places the shoulder, the hand places the
    /// wrist, and the whole arm is reconstructed between them.
    private func acquireTracking() async -> Bool {
        phase = .acquiring
        statusMessage = "Hold your guard up so we can see your hands…"

        await hands.start()
        guard hands.isRunning else {
            fail(hands.statusMessage)
            return false
        }

        let deadline = CACurrentMediaTime() + 8
        while CACurrentMediaTime() < deadline {
            if Task.isCancelled { return false }
            if hands.hasFullUpperBodyTracking, currentBodyFrame(solver: ArmPoseSolver(measurements: measurements)) != nil {
                return true
            }
            try? await Task.sleep(for: frameInterval)
        }

        fail("Couldn't see your hands and head clearly. Face forward with both hands up and try again.")
        return false
    }

    /// What the user has to do before the ghost will move on from a hold.
    private enum ReachGoal {
        /// Reach at least this far — the user is matching full extension.
        case extend(Float)
        /// Come back under this — the user is returning to guard.
        case retract(Float)

        func isMet(by reach: Float) -> Bool {
            switch self {
            case .extend(let target): return reach >= target
            case .retract(let target): return reach <= target
            }
        }
    }

    /// Leads the user through the punch call-and-response, one waypoint at a time.
    ///
    /// The ghost throws, then **holds at full extension until the user matches it**, then returns
    /// to guard and **waits there until the user comes back too**. Each completed rep is played
    /// faster than the last, so the pace is pulled up gradually instead of the user being asked to
    /// match a full-speed punch from cold.
    ///
    /// This replaces the old fire-and-forget demo, which played at fixed speed whether or not the
    /// user was anywhere near keeping up.
    private func runGuidedFollowAlong(
        reference: ReferencePunch,
        side: BodySide,
        solver: ArmPoseSolver
    ) async {
        phase = .guiding
        mirrorArm?.isVisible = false

        let peak = max(reference.peakReach, 0.001)
        let extendTarget = peak * followExtensionFraction
        let guardTarget = peak * followGuardFraction
        let reps = max(1, guidedRepetitions)
        var speedFactor: Double = 1

        for rep in 1...reps {
            if Task.isCancelled { return }
            currentDemoRep = rep

            let pace = rep == 1 ? "" : " — faster"
            statusMessage = "Rep \(rep) of \(reps)\(pace): follow the ghost out"
            await playGhost(
                reference: reference,
                side: side,
                solver: solver,
                from: 0,
                to: reference.peakTime,
                speedFactor: speedFactor
            )
            if Task.isCancelled { return }

            statusMessage = "Extend all the way — the ghost is waiting"
            await holdGhost(
                reference: reference,
                side: side,
                solver: solver,
                at: reference.peakTime,
                until: .extend(extendTarget)
            )
            if Task.isCancelled { return }

            statusMessage = "Bring it back with the ghost"
            await playGhost(
                reference: reference,
                side: side,
                solver: solver,
                from: reference.peakTime,
                to: reference.duration,
                speedFactor: speedFactor
            )
            if Task.isCancelled { return }

            statusMessage = "Back to guard"
            await holdGhost(
                reference: reference,
                side: side,
                solver: solver,
                at: reference.duration,
                until: .retract(guardTarget)
            )
            if Task.isCancelled { return }

            speedFactor = max(minimumGuidedSpeedFactor, speedFactor * guidedSpeedUp)
        }

        demoArm?.isVisible = false
        demoArm?.setTint(.demo)
        liveReach = 0
    }

    /// Animates the ghost across a slice of the reference trajectory.
    ///
    /// `speedFactor` scales wall-clock duration, so 0.7 plays the same motion 30% quicker without
    /// touching the authored trajectory.
    private func playGhost(
        reference: ReferencePunch,
        side: BodySide,
        solver: ArmPoseSolver,
        from start: TimeInterval,
        to end: TimeInterval,
        speedFactor: Double
    ) async {
        let span = max(0, end - start)
        guard span > 0 else {
            poseGhost(reference: reference, side: side, solver: solver, at: end)
            return
        }

        let wallDuration = span * speedFactor
        let began = CACurrentMediaTime()

        while true {
            if Task.isCancelled { return }

            let elapsed = CACurrentMediaTime() - began
            let progress = wallDuration > 0 ? min(1, elapsed / wallDuration) : 1
            poseGhost(
                reference: reference,
                side: side,
                solver: solver,
                at: start + span * progress
            )
            updateLiveReach(side: side, solver: solver)

            if progress >= 1 { return }
            try? await Task.sleep(for: frameInterval)
        }
    }

    /// Freezes the ghost at one point in the trajectory until the user's own arm satisfies `goal`.
    ///
    /// The pose is re-solved every frame rather than held as a fixed world position, so the ghost
    /// stays attached to the user's shoulder while they wait — otherwise it would detach and drift
    /// the moment they shifted their stance mid-hold.
    private func holdGhost(
        reference: ReferencePunch,
        side: BodySide,
        solver: ArmPoseSolver,
        at referenceTime: TimeInterval,
        until goal: ReachGoal
    ) async {
        let deadline = CACurrentMediaTime() + followHoldTimeout

        while CACurrentMediaTime() < deadline {
            if Task.isCancelled { return }

            poseGhost(reference: reference, side: side, solver: solver, at: referenceTime)

            if let reach = updateLiveReach(side: side, solver: solver), goal.isMet(by: reach) {
                return
            }

            try? await Task.sleep(for: frameInterval)
        }
    }

    /// Poses the ghost at one instant of the reference, re-anchored to the user's body.
    private func poseGhost(
        reference: ReferencePunch,
        side: BodySide,
        solver: ArmPoseSolver,
        at referenceTime: TimeInterval
    ) {
        // Re-solve the body frame every frame so the ghost stays glued to the user even as they
        // shift their weight or turn — it is their body the demo is drawn on.
        guard let frame = currentBodyFrame(solver: solver),
              let sample = reference.sample(at: referenceTime) else {
            demoArm?.isVisible = false
            return
        }

        demoArm?.isVisible = true
        demoArm?.pose(
            shoulder: frame.shoulder(side, measurements: measurements),
            elbow: solver.denormalize(sample.elbow, side: side, frame: frame),
            fist: solver.denormalize(sample.fist, side: side, frame: frame)
        )

        // Flash near peak extension so the user's eye lands on the moment that matters. Measured
        // against this punch's own peak, since a hook never approaches a straight punch's reach.
        let emphasisThreshold = max(reference.peakReach, 0.001) * 0.85
        demoArm?.setTint(sample.reachFraction >= emphasisThreshold ? .emphasis : .demo)
    }

    /// Current normalized reach of one arm, also published for the UI's punch meter.
    @discardableResult
    private func updateLiveReach(side: BodySide, solver: ArmPoseSolver) -> Float? {
        guard let frame = currentBodyFrame(solver: solver),
              let hand = hands.observation(for: side) else {
            return nil
        }

        let pose = solver.solve(hand: hand, frame: frame)
        let reach = solver.normalize(
            pose: pose,
            guardHand: nil,
            frame: frame,
            startTime: 0
        ).reachFraction

        liveReach = reach
        return reach
    }

    private func runCountdown() async {
        phase = .countdown
        for count in [3, 2, 1] {
            if Task.isCancelled { return }
            statusMessage = "Your turn in \(count)…"
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Captures the user's attempt on **both** arms, recording dropouts explicitly rather than
    /// skipping frames.
    ///
    /// Both hands are recorded because the app cannot assume the user threw with the hand it asked
    /// for — recording only the expected arm would turn a cross thrown off the lead hand into a
    /// capture of a stationary guard, which scores as a failed punch instead of the hand mistake
    /// it actually was. The arm that reached furthest is taken as the one that threw.
    ///
    /// Returns `nil` when neither arm produced a gradeable punch.
    private func recordAttempt(
        solver: ArmPoseSolver
    ) async -> (side: BodySide, attempt: RecordedAttempt)? {
        phase = .attempting
        statusMessage = "Throw it!"

        let startTime = CACurrentMediaTime()
        for recorder in recorders.values { recorder.begin(at: startTime) }

        while CACurrentMediaTime() - startTime < attemptWindow {
            if Task.isCancelled { break }

            let now = CACurrentMediaTime()

            guard let frame = currentBodyFrame(solver: solver) else {
                // Tracking is gone this frame. Record the gap — see MotionRecorder for why this
                // matters more than it looks like it should.
                for recorder in recorders.values { recorder.recordDropout(at: now) }
                mirrorArm?.isVisible = false
                try? await Task.sleep(for: frameInterval)
                continue
            }

            var leadingPose: ArmPose?
            var leadingReach: Float = -1

            for side in [BodySide.left, .right] {
                guard let recorder = recorders[side] else { continue }
                guard let hand = hands.observation(for: side) else {
                    recorder.recordDropout(at: now)
                    continue
                }

                let pose = solver.solve(hand: hand, frame: frame)
                let sample = solver.normalize(
                    pose: pose,
                    guardHand: hands.observation(for: side.opposite)?.fistPosition,
                    frame: frame,
                    startTime: startTime
                )
                recorder.record(sample)

                if sample.reachFraction > leadingReach {
                    leadingReach = sample.reachFraction
                    leadingPose = pose
                }
            }

            // Mirror whichever arm is currently reaching furthest, so the user sees their own
            // punch drawn back to them regardless of which hand they chose. Beyond looking good,
            // this makes IK error visible on-device: if the ghost doesn't sit on their real arm,
            // the shoulder estimate or the measurements are off.
            if let leadingPose {
                liveReach = leadingReach
                mirrorArm?.isVisible = true
                mirrorArm?.pose(
                    shoulder: leadingPose.shoulder,
                    elbow: leadingPose.elbow,
                    fist: leadingPose.fist
                )
            } else {
                mirrorArm?.isVisible = false
            }

            try? await Task.sleep(for: frameInterval)
        }

        mirrorArm?.isVisible = false

        let captured = recorders.mapValues { $0.finish() }
        guard let thrown = captured.max(by: { $0.value.peakReach < $1.value.peakReach }),
              thrown.value.peakReach > 0 else {
            return nil
        }
        return (thrown.key, thrown.value)
    }

    private func finish(
        attempt: RecordedAttempt,
        reference: ReferencePunch,
        thrownSide: BodySide
    ) async {
        phase = .scoring
        statusMessage = "Scoring…"

        guard let computed = scorer.score(
            attempt: attempt,
            reference: reference,
            technique: technique,
            thrownSide: thrownSide,
            stance: stance
        ) else {
            // Refusing to score a bad capture is deliberate: a confident number built on
            // interpolated motion would coach the user on a punch they never threw.
            fail("Couldn't track that attempt cleanly enough to score it. Keep your hands in view and try again.")
            return
        }

        score = computed
        feedback = await feedbackGenerator.feedback(for: computed, technique: technique)

        phase = .results
        statusMessage = computed.wrongHand
            ? "Round complete — that was your \(computed.thrownHandName) hand"
            : "Round complete"
    }

    // MARK: Helpers

    private func currentBodyFrame(solver: ArmPoseSolver) -> BodyFrame? {
        guard let head = hands.deviceTransform else { return nil }
        return solver.bodyFrame(headTransform: head)
    }

    private func fail(_ message: String) {
        errorMessage = message
        statusMessage = "Couldn't complete the rep"
        phase = .idle
        demoArm?.isVisible = false
        mirrorArm?.isVisible = false
    }
}

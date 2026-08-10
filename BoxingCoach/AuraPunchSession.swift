import Foundation
import QuartzCore
import RealityKit
import simd

enum AuraPunchPhase: String, Sendable {
    case idle
    /// Waiting for hands and head to be tracked well enough to place a shoulder.
    case acquiring
    /// The coach character demonstrates the punch once before the ghost follow-along begins.
    case coachDemo
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

    /// How close (in arm-reach units) the user's fist must get to the ghost's *actual position* —
    /// not just how far it has extended — before a hold is considered matched.
    ///
    /// Matching on reach alone cannot tell a hook from a jab: both can hit the same distance from
    /// the shoulder while pointing in completely different directions, which is exactly how a
    /// hook gets "finessed" — punched straight instead of arced. Comparing full 3D position
    /// against the reference's own pose at that instant closes that gap while automatically
    /// respecting a hook's lower ~0.70 peak reach, since the target is the reference's own point
    /// in space rather than an absolute threshold. Looser than the scorer's `pathGood` (0.11)
    /// because this checks one live, possibly-noisy instant rather than an averaged trajectory.
    var followPositionTolerance: Float = 0.16

    /// How long the ghost holds a position waiting for the user before moving on anyway.
    ///
    /// Without a ceiling the guide deadlocks whenever tracking is poor or the user simply stops,
    /// leaving a frozen arm and no way forward except quitting the feature.
    var followHoldTimeout: TimeInterval = 6

    /// How long the user's attempt is captured for. Used only as a safety ceiling if hit detection stalls.
    var attemptWindow: TimeInterval = 4.0

    var targetVisualRadius: Float = 0.07
    var targetHitRadius: Float = 0.12
    var scoredPunchCount = 3

    private let scoredPunchSafetyTimeout: TimeInterval = 20
    private let interScoredPunchDelay: TimeInterval = 0.45
    /// How long to keep recording after a target hit so retraction can be scored.
    private let postHitCaptureDuration: TimeInterval = 1.0
    /// Follow-through ends once reach drops below this fraction of the hit peak.
    private let retractionReachFraction: Float = 0.85

    // MARK: Observable state

    private(set) var phase: AuraPunchPhase = .idle
    private(set) var statusMessage = "Ready"
    /// Large headline shown in the immersive coaching banner during the drill.
    private(set) var coachingHeadline = "GET READY"
    /// Supporting line under the headline in the immersive coaching banner.
    private(set) var coachingDetail = "Raise your guard to begin"
    private(set) var errorMessage: String?
    private(set) var score: TechniqueScore?
    private(set) var feedback: CoachingFeedback?
    private(set) var currentDemoRep = 0
    /// Active scored punch during the 3-punch round (0 when not scoring).
    private(set) var currentScoredPunch = 0
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
    private let coachAudio: CoachAudioPlayer
    private let targets = TargetController()

    private var demoArm: ArmSilhouetteEntity?
    private var mirrorArm: ArmSilhouetteEntity?
    private let coach = CoachCharacterEntity()
    private weak var sceneRoot: Entity?

    private var loopTask: Task<Void, Never>?

    /// Reused briefly when head tracking flickers mid-attempt so hand samples are not discarded.
    private var cachedBodyFrame: BodyFrame?
    private var cachedBodyFrameTime: TimeInterval = 0
    private let bodyFrameCacheDuration: TimeInterval = 0.25

    /// Frame interval for the pose loop. Hand tracking runs at ~90 Hz; polling faster just burns
    /// cycles re-reading the same anchor.
    private let frameInterval: Duration = .milliseconds(11)

    init(
        hands: HandTrackingService,
        feedbackGenerator: FeedbackGenerating = MockFeedbackGenerator(),
        coachAudio: CoachAudioPlayer? = nil
    ) {
        self.hands = hands
        self.feedbackGenerator = feedbackGenerator
        self.coachAudio = coachAudio ?? CoachAudioPlayer()
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

        coach.attach(to: root)
        coach.isVisible = false

        targets.attach(to: root)
    }

    func detach() {
        targets.removeActiveTarget()
        demoArm?.removeFromScene()
        mirrorArm?.removeFromScene()
        coach.removeFromScene()
        demoArm = nil
        mirrorArm = nil
        sceneRoot = nil
    }

    /// Loads the coach model ahead of the first Aura session. Loading fails soft so the existing
    /// ghost tutorial remains available if an asset cannot be decoded.
    func preloadCoach() async {
        await coach.load()
    }

    // MARK: Control

    func start() {
        guard phase == .idle || phase == .results else { return }

        score = nil
        feedback = nil
        errorMessage = nil
        currentDemoRep = 0
        currentScoredPunch = 0
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
        targets.removeActiveTarget()
        dismissCoach()
        demoArm?.isVisible = false
        mirrorArm?.isVisible = false
        currentScoredPunch = 0
        phase = .idle
        statusMessage = "Stopped"
        coachAudio.stop()
    }

    func reset() {
        stop()
        phase = .idle
        score = nil
        feedback = nil
        errorMessage = nil
        statusMessage = "Ready"
    }

    /// Prepares audio output. Call when the immersive space opens, before `start()`.
    func prepareCoachAudio() {
        coachAudio.prepare()
    }

    // MARK: Session loop

    private func runSession() async {
        let solver = ArmPoseSolver(measurements: measurements)

        guard await acquireTracking() else { return }
        guard !Task.isCancelled else { return }

        await runCoachDemo(solver: solver)
        guard !Task.isCancelled else { return }

        // Reference/side are resolved per rep inside the guided loop rather than once here, so
        // an `.either`-hand technique like the hook or uppercut can alternate its demo arm.
        await runGuidedFollowAlong(solver: solver)
        guard !Task.isCancelled else { return }

        await runCountdown()
        guard !Task.isCancelled else { return }

        await runScoredTargetRound(solver: solver)
    }

    /// Blocks until head and hand tracking are both usable, or gives up.
    ///
    /// Aura Punch cannot start without both: the head places the shoulder, the hand places the
    /// wrist, and the whole arm is reconstructed between them.
    private func acquireTracking() async -> Bool {
        phase = .acquiring
        setCoaching(
            headline: "GET READY",
            detail: "Raise your guard — the hologram will show you the punch",
            status: "Hold your guard up so we can see your hands…"
        )
        coachAudio.play(id: .welcome)

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

    /// What the user has to do before the ghost will move on from a hold: get their fist to the
    /// ghost's actual position, not just match its distance from the shoulder.
    ///
    /// This is deliberately position-based rather than magnitude-based. A magnitude-only check
    /// (matching `reachFraction` — see `ArmPoseSolver.MotionSample`) cannot distinguish a hook
    /// from a jab, since both can reach the same distance from the shoulder while pointing in
    /// totally different directions. Comparing the full normalized fist vector forces the user to
    /// actually trace the arc instead of punching straight to wherever satisfies a number.
    private struct HoldGoal {
        /// The reference's normalized fist position at this instant.
        let targetFist: SIMD3<Float>
        let tolerance: Float

        func isMet(by fist: SIMD3<Float>) -> Bool {
            simd_distance(fist, targetFist) <= tolerance
        }
    }

    /// Which arm rep `rep` of the guided follow-along should demonstrate.
    ///
    /// Techniques thrown with a specific hand (`.lead`/`.rear`) always demonstrate on that side.
    /// `.either`-hand techniques — the hook and uppercut — alternate sides rep to rep, so the
    /// tutorial actually trains both arms instead of only ever showing the lead side (which is
    /// what a single fixed `PunchHand.side(for:)` lookup would otherwise do for every rep).
    private func demoSide(forRep rep: Int, technique: Technique, stance: Stance) -> BodySide {
        guard technique.hand == .either else {
            return technique.hand.side(for: stance)
        }
        return rep.isMultiple(of: 2) ? stance.rearSide : stance.leadSide
    }

    /// Shows one full-speed, full-body example before the interactive ghost repetitions. Any
    /// missing asset, animation, or body frame skips this stage without failing the training run.
    private func runCoachDemo(solver: ArmPoseSolver) async {
        guard await coach.load(), !Task.isCancelled else { return }

        let side = technique.hand.side(for: stance)
        guard let resolved = CoachCharacterEntity.resolveClip(technique: technique, side: side),
              let frame = currentBodyFrame(solver: solver) else { return }

        phase = .coachDemo
        demoArm?.isVisible = false
        mirrorArm?.isVisible = false
        coach.place(
            using: frame,
            measurements: measurements,
            demoSide: side,
            reflected: resolved.reflected
        )
        coach.isVisible = true
        coach.playIdle()

        let handLabel = technique.hand == .either ? " \(side.rawValue)" : ""
        setCoaching(
            headline: "WATCH THE COACH",
            detail: "He throws the\(handLabel) \(technique.name.lowercased()) once — watch the whole motion",
            status: "Watch the coach throw the\(handLabel) \(technique.name.lowercased())"
        )

        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        if let duration = coach.play(clip: resolved.clip) {
            try? await Task.sleep(for: .seconds(duration))
        }
        guard !Task.isCancelled else {
            dismissCoach()
            return
        }

        // Keep the coach beside the user through the guided phase, then remove him before the
        // unaided scored punches begin.
        coach.playIdle()
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func dismissCoach() {
        coach.stop()
        coach.isVisible = false
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
    private func runGuidedFollowAlong(solver: ArmPoseSolver) async {
        phase = .guiding
        mirrorArm?.isVisible = false

        let reps = max(1, guidedRepetitions)
        var speedFactor: Double = 1

        for rep in 1...reps {
            if Task.isCancelled { return }
            currentDemoRep = rep

            // Resolved per rep, not once for the whole set, so an `.either`-hand technique can
            // alternate which arm the ghost demonstrates on.
            let side = demoSide(forRep: rep, technique: technique, stance: stance)
            let reference = ReferencePunchLibrary.punch(
                for: technique,
                stance: stance,
                measurements: measurements,
                side: side
            )
            let handLabel = technique.hand == .either ? " — \(side.rawValue) \(technique.name.lowercased())" : ""

            let pace = rep == 1 ? "" : " — faster"
            setCoaching(
                headline: "FOLLOW THE HOLOGRAM",
                detail: "Rep \(rep) of \(reps)\(pace)\(handLabel) — aim for the target",
                status: "Rep \(rep) of \(reps)\(pace)\(handLabel): follow the hologram out"
            )
            spawnLandingTarget(reference: reference, side: side, solver: solver)
            await playGhost(
                reference: reference,
                side: side,
                solver: solver,
                from: 0,
                to: reference.peakTime,
                speedFactor: speedFactor,
                phaseMessage: statusMessage,
                trackLandingTarget: true
            )
            if Task.isCancelled { return }

            setCoaching(
                headline: "MATCH THE HOLOGRAM",
                detail: "Extend all the way — hit the target",
                status: "Extend all the way — the hologram is waiting"
            )
            await holdGhost(
                reference: reference,
                side: side,
                solver: solver,
                at: reference.peakTime,
                phaseMessage: statusMessage,
                trackLandingTarget: true
            )
            if Task.isCancelled { return }

            targets.removeActiveTarget()

            setCoaching(
                headline: "RETURN WITH THE HOLOGRAM",
                detail: "Bring it back together",
                status: "Bring it back with the hologram"
            )
            await playGhost(
                reference: reference,
                side: side,
                solver: solver,
                from: reference.peakTime,
                to: reference.duration,
                speedFactor: speedFactor,
                phaseMessage: statusMessage,
                trackLandingTarget: false
            )
            if Task.isCancelled { return }

            setCoaching(
                headline: "BACK TO GUARD",
                detail: "Match the hologram's guard",
                status: "Back to guard"
            )
            await holdGhost(
                reference: reference,
                side: side,
                solver: solver,
                at: reference.duration,
                phaseMessage: statusMessage,
                trackLandingTarget: false
            )
            if Task.isCancelled { return }

            speedFactor = max(minimumGuidedSpeedFactor, speedFactor * guidedSpeedUp)
        }

        targets.removeActiveTarget()
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
        speedFactor: Double,
        phaseMessage: String,
        trackLandingTarget: Bool = false
    ) async {
        let span = max(0, end - start)
        guard span > 0 else {
            poseGhost(reference: reference, side: side, solver: solver, at: end)
            return
        }

        let wallDuration = span * speedFactor
        var activeElapsed: TimeInterval = 0
        var lastTick = CACurrentMediaTime()

        while activeElapsed < wallDuration {
            if Task.isCancelled { return }

            let now = CACurrentMediaTime()
            let guardUp = nonPunchingGuardStatus(punchingSide: side, solver: solver)

            if guardUp == false {
                if statusMessage != GuardCoach.waitMessage {
                    coachAudio.play(id: .guardUp)
                }
                statusMessage = GuardCoach.waitMessage
                let progress = wallDuration > 0 ? min(1, activeElapsed / wallDuration) : 1
                poseGhost(
                    reference: reference,
                    side: side,
                    solver: solver,
                    at: start + span * progress
                )
                updateLiveReach(side: side, solver: solver)
                if trackLandingTarget {
                    updateLandingTarget(reference: reference, side: side, solver: solver)
                }
                lastTick = now
                try? await Task.sleep(for: frameInterval)
                continue
            }

            if statusMessage == GuardCoach.waitMessage {
                statusMessage = phaseMessage
            }

            activeElapsed += now - lastTick
            lastTick = now

            let progress = wallDuration > 0 ? min(1, activeElapsed / wallDuration) : 1
            poseGhost(
                reference: reference,
                side: side,
                solver: solver,
                at: start + span * progress
            )
            updateLiveReach(side: side, solver: solver)
            if trackLandingTarget {
                updateLandingTarget(reference: reference, side: side, solver: solver)
            }

            if progress >= 1 { return }
            try? await Task.sleep(for: frameInterval)
        }
    }

    /// Freezes the ghost at one point in the trajectory until the user's fist actually reaches
    /// that point in space — not just until it reaches the same distance from the shoulder.
    ///
    /// The pose is re-solved every frame rather than held as a fixed world position, so the ghost
    /// stays attached to the user's shoulder while they wait — otherwise it would detach and drift
    /// the moment they shifted their stance mid-hold.
    private func holdGhost(
        reference: ReferencePunch,
        side: BodySide,
        solver: ArmPoseSolver,
        at referenceTime: TimeInterval,
        phaseMessage: String,
        trackLandingTarget: Bool = false
    ) async {
        guard let targetFist = reference.sample(at: referenceTime)?.fist else { return }
        let goal = HoldGoal(targetFist: targetFist, tolerance: followPositionTolerance)
        let deadline = CACurrentMediaTime() + followHoldTimeout

        while CACurrentMediaTime() < deadline {
            if Task.isCancelled { return }

            if nonPunchingGuardStatus(punchingSide: side, solver: solver) == false {
                if statusMessage != GuardCoach.waitMessage {
                    coachAudio.play(id: .guardUp)
                }
                statusMessage = GuardCoach.waitMessage
                poseGhost(reference: reference, side: side, solver: solver, at: referenceTime)
                try? await Task.sleep(for: frameInterval)
                continue
            }

            if statusMessage == GuardCoach.waitMessage {
                statusMessage = phaseMessage
            }

            poseGhost(reference: reference, side: side, solver: solver, at: referenceTime)
            if trackLandingTarget {
                updateLandingTarget(reference: reference, side: side, solver: solver)
            }

            if let fist = updateLiveReach(side: side, solver: solver), goal.isMet(by: fist) {
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

        // Flash near the punch's semantic landing. Most punches use radial reach; uppercuts use
        // spatial proximity to the chin landing so the radially longer hip load does not flash.
        demoArm?.setTint(reference.shouldEmphasize(sample) ? .emphasis : .demo)
    }

    /// Current normalized fist position of one arm — shoulder-relative, arm-reach units, same
    /// space as `ReferencePunch` samples. Also publishes `reachFraction` for the UI's punch
    /// meter, but callers that need to know *where* the fist is (not just how far it travelled)
    /// should use the returned position rather than re-deriving it from `liveReach`.
    @discardableResult
    private func updateLiveReach(side: BodySide, solver: ArmPoseSolver) -> SIMD3<Float>? {
        guard let frame = currentBodyFrame(solver: solver),
              let hand = hands.observation(for: side) else {
            return nil
        }

        let pose = solver.solve(hand: hand, frame: frame)
        let sample = solver.normalize(
            pose: pose,
            guardHand: nil,
            frame: frame,
            startTime: 0
        )

        liveReach = sample.reachFraction
        return sample.fist
    }

    private func runCountdown() async {
        phase = .countdown
        dismissCoach()
        coachAudio.play(id: .countdown)
        for count in [3, 2, 1] {
            if Task.isCancelled { return }
            setCoaching(
                headline: "YOUR TURN",
                detail: count == 1 ? "\(scoredPunchCount) punches — hit each target" : "Starting in \(count)…",
                status: "Your turn in \(count)…"
            )
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func runScoredTargetRound(solver: ArmPoseSolver) async {
        phase = .attempting
        currentScoredPunch = 0
        coachAudio.play(id: .hitTarget)

        let expectedSide = technique.hand.side(for: stance)
        let reference = ReferencePunchLibrary.punch(
            for: technique,
            stance: stance,
            measurements: measurements,
            side: expectedSide
        )

        var scores: [TechniqueScore] = []

        for punchIndex in 1...scoredPunchCount {
            guard !Task.isCancelled else { return }

            currentScoredPunch = punchIndex
            setCoaching(
                headline: "HIT THE TARGET",
                detail: "Punch \(punchIndex) of \(scoredPunchCount) — hit the target",
                status: "Punch \(punchIndex) of \(scoredPunchCount) — hit the target!"
            )

            guard let frame = currentBodyFrame(solver: solver),
                  let landing = landingWorldPosition(
                    reference: reference,
                    side: expectedSide,
                    solver: solver,
                    frame: frame,
                    at: reference.peakTime
                  )
            else {
                continue
            }

            targets.spawnTarget(at: landing, radius: targetVisualRadius)

            let capture = await capturePunchUntilHit(
                solver: solver,
                reference: reference,
                side: expectedSide
            )

            if let capture {
                let punchReference = ReferencePunchLibrary.punch(
                    for: technique,
                    stance: stance,
                    measurements: measurements,
                    side: capture.side
                )
                if let computed = scorer.score(
                    attempt: capture.attempt,
                    reference: punchReference,
                    technique: technique,
                    thrownSide: capture.side,
                    stance: stance
                ) {
                    scores.append(computed)
                }
            }

            try? await Task.sleep(for: .milliseconds(220))
            targets.removeActiveTarget()

            if punchIndex < scoredPunchCount {
                try? await Task.sleep(for: .seconds(interScoredPunchDelay))
            }
        }

        currentScoredPunch = 0
        mirrorArm?.isVisible = false

        guard let aggregated = TechniqueScore.averaging(scores, techniqueID: technique.id) else {
            fail("Couldn't see a punch. Keep both hands in view and hit each target.")
            return
        }

        await finishAggregated(aggregated)
    }

    /// Records motion until the user's fist reaches the active target, then through retraction.
    private func capturePunchUntilHit(
        solver: ArmPoseSolver,
        reference: ReferencePunch,
        side: BodySide
    ) async -> (side: BodySide, attempt: RecordedAttempt)? {
        let throwMessage = statusMessage

        cachedBodyFrame = nil
        cachedBodyFrameTime = 0

        let startTime = CACurrentMediaTime()
        hands.beginAttemptCapture()
        defer { hands.endAttemptCapture() }

        for recorder in recorders.values { recorder.begin(at: startTime) }

        let armingDeadline = CACurrentMediaTime() + scoredPunchSafetyTimeout
        var hitDetected = false
        var hitPeakReach: Float = 0
        var followThroughDeadline: TimeInterval = 0

        while true {
            if Task.isCancelled { break }

            let now = CACurrentMediaTime()
            if !hitDetected, now >= armingDeadline { break }
            if hitDetected, now >= followThroughDeadline { break }

            updateLandingTarget(reference: reference, side: side, solver: solver)

            if !hitDetected,
               let hitPosition = targets.activeTargetPosition,
               let fist = hands.nearestFistPosition(to: hitPosition),
               distance(fist, hitPosition) <= targetHitRadius {
                hitDetected = true
                targets.flash(result: .hit)
                followThroughDeadline = now + postHitCaptureDuration
            }

            let leadingReach = recordAttemptFrame(
                solver: solver,
                startTime: startTime,
                throwMessage: throwMessage,
                at: now
            )

            if let leadingReach {
                if hitDetected {
                    hitPeakReach = max(hitPeakReach, leadingReach)
                    if hitPeakReach > 0,
                       leadingReach < hitPeakReach * retractionReachFraction {
                        break
                    }
                }
            }

            try? await Task.sleep(for: frameInterval)
        }

        mirrorArm?.isVisible = false

        guard hitDetected else {
            for recorder in recorders.values { recorder.cancel() }
            return nil
        }

        return selectedCapturedAttempt(for: technique.id)
    }

    /// Records one frame of both arms; returns the leading reach fraction if any hand tracked.
    @discardableResult
    private func recordAttemptFrame(
        solver: ArmPoseSolver,
        startTime: TimeInterval,
        throwMessage: String,
        at now: TimeInterval
    ) -> Float? {
        guard let frame = bodyFrameForAttempt(solver: solver, at: now) else {
            for handSide in [BodySide.left, .right] {
                guard let recorder = recorders[handSide] else { continue }
                if hands.observation(for: handSide) == nil {
                    recorder.recordDropout(at: now)
                }
            }
            mirrorArm?.isVisible = false
            return nil
        }

        var leadingPose: ArmPose?
        var leadingReach: Float = -1
        var leadingSide: BodySide?

        for handSide in [BodySide.left, .right] {
            guard let recorder = recorders[handSide] else { continue }
            guard let hand = hands.observation(for: handSide) else {
                recorder.recordDropout(at: now)
                continue
            }

            let pose = solver.solve(hand: hand, frame: frame)
            let sample = solver.normalize(
                pose: pose,
                guardHand: hands.observation(for: handSide.opposite)?.fistPosition,
                frame: frame,
                startTime: startTime
            )
            recorder.record(sample)

            if sample.reachFraction > leadingReach {
                leadingReach = sample.reachFraction
                leadingPose = pose
                leadingSide = handSide
            }
        }

        if let leadingSide, nonPunchingGuardStatus(punchingSide: leadingSide, solver: solver) == false {
            statusMessage = GuardCoach.waitMessage
            if let leadingPose, leadingReach >= 0 {
                liveReach = leadingReach
                mirrorArm?.isVisible = true
                mirrorArm?.pose(
                    shoulder: leadingPose.shoulder,
                    elbow: leadingPose.elbow,
                    fist: leadingPose.fist
                )
            }
            return leadingReach >= 0 ? leadingReach : nil
        }

        if statusMessage == GuardCoach.waitMessage {
            statusMessage = throwMessage
        }

        if let leadingPose, leadingReach >= 0 {
            liveReach = leadingReach
            mirrorArm?.isVisible = true
            mirrorArm?.pose(
                shoulder: leadingPose.shoulder,
                elbow: leadingPose.elbow,
                fist: leadingPose.fist
            )
            return leadingReach
        }

        mirrorArm?.isVisible = false
        return nil
    }

    private func selectedCapturedAttempt(
        for techniqueID: String
    ) -> (side: BodySide, attempt: RecordedAttempt)? {
        let captured = recorders.mapValues { $0.finish() }
        guard let thrown = captured.max(by: {
            $0.value.extensionMagnitude(for: techniqueID)
                < $1.value.extensionMagnitude(for: techniqueID)
        }),
              thrown.value.extensionMagnitude(for: techniqueID) > 0 else {
            return nil
        }
        return (thrown.key, thrown.value)
    }

    private func finishAggregated(_ aggregated: TechniqueScore) async {
        phase = .scoring
        statusMessage = "Scoring…"

        score = aggregated
        feedback = await feedbackGenerator.feedback(for: aggregated, technique: technique)

        coachAudio.play(id: aggregated.overall >= 74 ? .resultsGood : .resultsNeedsWork)
        phase = .results
        statusMessage = aggregated.wrongHand
            ? "Round complete — that was your \(aggregated.thrownHandName) hand"
            : "Round complete"
    }

    // MARK: Helpers

    private func landingWorldPosition(
        reference: ReferencePunch,
        side: BodySide,
        solver: ArmPoseSolver,
        frame: BodyFrame,
        at referenceTime: TimeInterval
    ) -> SIMD3<Float>? {
        guard let sample = reference.sample(at: referenceTime) else { return nil }
        return solver.denormalize(sample.fist, side: side, frame: frame)
    }

    private func spawnLandingTarget(
        reference: ReferencePunch,
        side: BodySide,
        solver: ArmPoseSolver
    ) {
        guard let frame = currentBodyFrame(solver: solver),
              let landing = landingWorldPosition(
                reference: reference,
                side: side,
                solver: solver,
                frame: frame,
                at: reference.peakTime
              ) else { return }
        targets.spawnTarget(at: landing, radius: targetVisualRadius)
    }

    private func updateLandingTarget(
        reference: ReferencePunch,
        side: BodySide,
        solver: ArmPoseSolver
    ) {
        guard let frame = currentBodyFrame(solver: solver),
              let landing = landingWorldPosition(
                reference: reference,
                side: side,
                solver: solver,
                frame: frame,
                at: reference.peakTime
              ) else { return }
        targets.updateActiveTargetPosition(landing)
    }

    private func currentBodyFrame(solver: ArmPoseSolver) -> BodyFrame? {
        guard let head = hands.deviceTransform else { return nil }
        return solver.bodyFrame(headTransform: head)
    }

    private func bodyFrameForAttempt(solver: ArmPoseSolver, at time: TimeInterval) -> BodyFrame? {
        if let frame = currentBodyFrame(solver: solver) {
            cachedBodyFrame = frame
            cachedBodyFrameTime = time
            return frame
        }
        if let cachedBodyFrame, time - cachedBodyFrameTime <= bodyFrameCacheDuration {
            return cachedBodyFrame
        }
        return nil
    }

    private func setCoaching(headline: String, detail: String, status: String? = nil) {
        coachingHeadline = headline
        coachingDetail = detail
        if let status {
            statusMessage = status
        }
    }

    /// `true` = guard up, `false` = dropped, `nil` = guard hand not visible (do not pause).
    private func nonPunchingGuardStatus(
        punchingSide: BodySide,
        solver: ArmPoseSolver
    ) -> Bool? {
        guard let frame = currentBodyFrame(solver: solver) else { return nil }
        let guardSide = punchingSide.opposite
        return GuardCoach.isGuardUp(
            guardFistWorld: hands.observation(for: guardSide)?.fistPosition,
            frame: frame,
            measurements: measurements,
            guardSide: guardSide
        )
    }

    private func fail(_ message: String) {
        errorMessage = message
        statusMessage = "Couldn't complete the rep"
        phase = .idle
        currentScoredPunch = 0
        targets.removeActiveTarget()
        demoArm?.isVisible = false
        mirrorArm?.isVisible = false
    }
}

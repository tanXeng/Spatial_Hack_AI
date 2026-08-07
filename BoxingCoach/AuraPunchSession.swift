import Foundation
import QuartzCore
import RealityKit
import simd

enum AuraPunchPhase: String, Sendable {
    case idle
    /// Waiting for hands and head to be tracked well enough to place a shoulder.
    case acquiring
    /// The ghost arm is demonstrating the punch.
    case demonstrating
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

    /// How many times the ghost demonstrates before the user attempts.
    ///
    /// Two is the compromise: one is easy to miss while the user is still finding the ghost, and
    /// three makes the loop feel slow when they already know the punch.
    var demoRepetitions = 2

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
    private let recorder = MotionRecorder()
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
        recorder.cancel()
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
        let reference = ReferencePunchLibrary.punch(
            for: technique,
            stance: stance,
            measurements: measurements
        )
        let punchingSide = technique.hand.side(for: stance)

        guard await acquireTracking() else { return }
        guard !Task.isCancelled else { return }

        await runDemo(reference: reference, side: punchingSide, solver: solver)
        guard !Task.isCancelled else { return }

        await runCountdown()
        guard !Task.isCancelled else { return }

        let attempt = await recordAttempt(side: punchingSide, solver: solver)
        guard !Task.isCancelled else { return }

        await finish(attempt: attempt, reference: reference)
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

    /// Plays the reference trajectory on the ghost arm, re-anchored to the user's body each frame.
    private func runDemo(reference: ReferencePunch, side: BodySide, solver: ArmPoseSolver) async {
        phase = .demonstrating
        mirrorArm?.isVisible = false

        for rep in 1...max(1, demoRepetitions) {
            if Task.isCancelled { return }
            currentDemoRep = rep
            statusMessage = "Watch the \(technique.name.lowercased()) — rep \(rep) of \(max(1, demoRepetitions))"

            let start = CACurrentMediaTime()
            while true {
                if Task.isCancelled { return }
                let elapsed = CACurrentMediaTime() - start
                if elapsed > reference.duration { break }

                // Re-solve the body frame every frame so the ghost stays glued to the user even
                // as they shift their weight or turn — it is their body the demo is drawn on.
                if let frame = currentBodyFrame(solver: solver),
                   let sample = reference.sample(at: elapsed) {
                    let shoulder = frame.shoulder(side, measurements: measurements)
                    let elbow = solver.denormalize(sample.elbow, side: side, frame: frame)
                    let fist = solver.denormalize(sample.fist, side: side, frame: frame)

                    demoArm?.isVisible = true
                    demoArm?.pose(shoulder: shoulder, elbow: elbow, fist: fist)

                    // Flash at peak extension so the user's eye lands on the moment that matters.
                    demoArm?.setTint(sample.reachFraction > 0.85 ? .emphasis : .demo)
                } else {
                    demoArm?.isVisible = false
                }

                try? await Task.sleep(for: frameInterval)
            }

            // Beat between reps so they read as separate punches rather than one twitchy loop.
            try? await Task.sleep(for: .milliseconds(450))
        }

        demoArm?.isVisible = false
        demoArm?.setTint(.demo)
    }

    private func runCountdown() async {
        phase = .countdown
        for count in [3, 2, 1] {
            if Task.isCancelled { return }
            statusMessage = "Your turn in \(count)…"
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Captures the user's attempt, recording dropouts explicitly rather than skipping frames.
    private func recordAttempt(side: BodySide, solver: ArmPoseSolver) async -> RecordedAttempt {
        phase = .attempting
        statusMessage = "Throw it!"

        let startTime = CACurrentMediaTime()
        recorder.begin(at: startTime)

        while CACurrentMediaTime() - startTime < attemptWindow {
            if Task.isCancelled { break }

            let now = CACurrentMediaTime()

            guard let frame = currentBodyFrame(solver: solver),
                  let hand = hands.observation(for: side)
            else {
                // Tracking is gone this frame. Record the gap — see MotionRecorder for why this
                // matters more than it looks like it should.
                recorder.recordDropout(at: now)
                mirrorArm?.isVisible = false
                try? await Task.sleep(for: frameInterval)
                continue
            }

            let pose = solver.solve(hand: hand, frame: frame)
            let guardHand = hands.observation(for: side.opposite)?.fistPosition

            let sample = solver.normalize(
                pose: pose,
                guardHand: guardHand,
                frame: frame,
                startTime: startTime
            )
            recorder.record(sample)
            liveReach = sample.reachFraction

            // Draw the reconstructed arm back to the user. Beyond looking good, this makes IK
            // error visible on-device: if the ghost doesn't sit on their real arm, the shoulder
            // estimate or the measurements are off.
            mirrorArm?.isVisible = true
            mirrorArm?.pose(shoulder: pose.shoulder, elbow: pose.elbow, fist: pose.fist)

            try? await Task.sleep(for: frameInterval)
        }

        mirrorArm?.isVisible = false
        return recorder.finish()
    }

    private func finish(attempt: RecordedAttempt, reference: ReferencePunch) async {
        phase = .scoring
        statusMessage = "Scoring…"

        guard let computed = scorer.score(attempt: attempt, reference: reference, technique: technique) else {
            // Refusing to score a bad capture is deliberate: a confident number built on
            // interpolated motion would coach the user on a punch they never threw.
            fail("Couldn't track that attempt cleanly enough to score it. Keep your hands in view and try again.")
            return
        }

        score = computed
        feedback = await feedbackGenerator.feedback(for: computed, technique: technique)

        phase = .results
        statusMessage = "Round complete"
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

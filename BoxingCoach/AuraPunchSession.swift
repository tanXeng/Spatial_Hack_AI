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

/// Resolves the immutable physical hand for one Aura repetition. Either-hand techniques alternate
/// lead/rear; stance-specific techniques retain their semantic lead/rear mapping every time.
enum AuraPunchSideSequence {
    static func side(
        forRepetition repetition: Int,
        technique: Technique,
        stance: Stance
    ) -> BodySide {
        guard technique.hand == .either else {
            return technique.hand.side(for: stance)
        }
        return repetition.isMultiple(of: 2) ? stance.rearSide : stance.leadSide
    }
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
    /// Invalidates a demonstration segment when a live command changes where the loop continues.
    /// The loop witnesses this token after every suspension before it may publish another step.
    private(set) var demoContinuationGeneration: UInt64 = 1
    /// Active scored punch during the 3-punch round (0 when not scoring).
    private(set) var currentScoredPunch = 0
    private(set) var isVoicePaused = false
    private(set) var voicePauseInvalidationCount = 0
    private(set) var voiceResumeGeneration: UInt64 = 1
    private(set) var activeVoiceResumeGeneration: UInt64?
    private(set) var demonstrationRate: TrainingDemoRate = .normal
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
    private let audienceTrack: CoachLearnerLevel
    let audioCoordinator: TrainingAudioCoordinator
    private let targets = TargetController()

    private var demoArm: ArmSilhouetteEntity?
    private var mirrorArm: ArmSilhouetteEntity?
    private weak var sceneRoot: Entity?

    private var loopTask: Task<Void, Never>?
    /// At most one optional relay request may be associated with the visible result.
    private var phrasingTask: Task<Void, Never>?
    /// Monotonic local token. It never crosses the relay boundary.
    private var feedbackGeneration: UInt64 = 0
    private var phaseBeforeVoicePause: AuraPunchPhase?
    private var requestedDemoRep: Int?
    private var scoredRoundScores: [TechniqueScore] = []
    /// The last actionable metric focus in this training session.
    private var previousCorrectionFocus: SubMetricKind?

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
        audienceTrack: CoachLearnerLevel,
        audioCoordinator: TrainingAudioCoordinator? = nil
    ) {
        self.hands = hands
        self.feedbackGenerator = feedbackGenerator
        self.audienceTrack = audienceTrack
        self.audioCoordinator = audioCoordinator ?? TrainingAudioCoordinator()
    }

    isolated deinit {
        loopTask?.cancel()
        phrasingTask?.cancel()
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

        targets.attach(to: root)
    }

    func detach() {
        cancelPendingPhrasing()
        targets.removeActiveTarget()
        demoArm?.removeFromScene()
        mirrorArm?.removeFromScene()
        demoArm = nil
        mirrorArm = nil
        sceneRoot = nil
    }

    // MARK: Control

    func start() {
        guard phase == .idle || phase == .results else { return }

        audioCoordinator.handleImmediately(.experienceDidEnter(.learn))

        cancelPendingPhrasing()
        score = nil
        feedback = nil
        errorMessage = nil
        currentDemoRep = 0
        currentScoredPunch = 0
        liveReach = 0
        isVoicePaused = false
        phaseBeforeVoicePause = nil
        invalidateVoiceResume()
        invalidateDemoContinuation()
        scoredRoundScores.removeAll(keepingCapacity: true)

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

    func stop(preservingVoiceCapture: Bool = false) {
        // Results are not "running", but their optional phrasing request still is.
        cancelPendingPhrasing()

        // No-op when nothing is running, so Reactive Strike's own stop path — which shares this
        // call — never clears a finished Aura Punch result out from under the user.
        guard isRunning else { return }

        loopTask?.cancel()
        loopTask = nil
        for recorder in recorders.values { recorder.cancel() }
        targets.removeActiveTarget()
        demoArm?.isVisible = false
        mirrorArm?.isVisible = false
        currentScoredPunch = 0
        isVoicePaused = false
        phaseBeforeVoicePause = nil
        invalidateVoiceResume()
        invalidateDemoContinuation()
        phase = .idle
        statusMessage = "Stopped"
        audioCoordinator.handleImmediately(.trainingDidStop(
            preservingVoiceCapture: preservingVoiceCapture
        ))
    }

    func reset() {
        stop()
        invalidateVoiceResume()
        invalidateDemoContinuation()
        phase = .idle
        score = nil
        feedback = nil
        previousCorrectionFocus = nil
        scoredRoundScores.removeAll(keepingCapacity: true)
        errorMessage = nil
        statusMessage = "Ready"
    }

    /// Stops the active capture/demo task before the microphone opens. Recorder state and the
    /// visible target are discarded without producing a score or miss.
    func pauseForVoice() -> String? {
        guard !isVoicePaused,
              [.acquiring, .guiding, .countdown, .attempting].contains(phase) else {
            return nil
        }
        phaseBeforeVoicePause = phase
        isVoicePaused = true
        voicePauseInvalidationCount &+= 1
        invalidateVoiceResume()
        invalidateDemoContinuation()
        loopTask?.cancel()
        loopTask = nil
        for recorder in recorders.values { recorder.cancel() }
        targets.removeActiveTarget()
        mirrorArm?.isVisible = false
        statusMessage = "Training paused · return both fists to guard to resume"
        return "Training paused."
    }

    func resumeAfterFreshGuard(
        countdown: @MainActor (Int) async throws -> Void = { count in
            _ = count
            try await Task.sleep(for: .seconds(1))
        },
        commandIsCurrent: @MainActor () -> Bool = { true }
    ) async -> String? {
        await performVoiceResume(
            evidence: { [weak self] in self?.currentVoiceGuardSnapshot() },
            countdown: countdown,
            commandIsCurrent: commandIsCurrent
        )
    }

    func resumeAfterFreshGuard(
        using snapshot: VoiceGuardSnapshot,
        countdown: @MainActor (Int) async throws -> Void,
        commandIsCurrent: @MainActor () -> Bool = { true }
    ) async -> String? {
        await performVoiceResume(
            evidence: { snapshot },
            countdown: countdown,
            commandIsCurrent: commandIsCurrent
        )
    }

    private func performVoiceResume(
        evidence: @MainActor () -> VoiceGuardSnapshot?,
        countdown: @MainActor (Int) async throws -> Void,
        commandIsCurrent: @MainActor () -> Bool
    ) async -> String? {
        guard !Task.isCancelled,
              isVoicePaused,
              commandIsCurrent(),
              let initialEvidence = evidence(),
              acceptsVoiceResumeGuard(initialEvidence) else { return nil }

        voiceResumeGeneration &+= 1
        let requestGeneration = voiceResumeGeneration
        let trackingGeneration = initialEvidence.generation
        let pausedPhase = phaseBeforeVoicePause

        func requestIsCurrent() -> Bool {
            guard !Task.isCancelled,
                  requestGeneration == voiceResumeGeneration,
                  isVoicePaused,
                  commandIsCurrent(),
                  let currentEvidence = evidence(),
                  currentEvidence.generation == trackingGeneration else { return false }
            return acceptsVoiceResumeGuard(currentEvidence)
        }

        for count in [3, 2, 1] {
            guard requestIsCurrent() else { return nil }
            setCoaching(
                headline: "YOUR TURN",
                detail: "Resuming in \(count)…",
                status: "Resuming in \(count)…"
            )
            do {
                try await countdown(count)
            } catch {
                return nil
            }
            guard requestIsCurrent() else { return nil }
        }

        guard requestIsCurrent(),
              let pausedPhase,
              [.acquiring, .guiding, .countdown, .attempting].contains(pausedPhase) else {
            return nil
        }
        isVoicePaused = false
        phaseBeforeVoicePause = nil
        activeVoiceResumeGeneration = requestGeneration
        let solver = ArmPoseSolver(measurements: measurements)
        loopTask = Task { [weak self] in
            guard let self else { return }
            switch pausedPhase {
            case .acquiring, .guiding:
                await self.runGuidedFollowAlong(
                    solver: solver,
                    startingAt: max(1, self.currentDemoRep)
                )
                guard !Task.isCancelled else { return }
                await self.runCountdown()
                guard !Task.isCancelled else { return }
                await self.runScoredTargetRound(solver: solver)
            case .countdown, .attempting:
                await self.runCountdown()
                guard !Task.isCancelled else { return }
                await self.runScoredTargetRound(solver: solver)
            case .idle, .scoring, .results:
                return
            }
        }
        return "Tracking is fresh. Resuming training."
    }

    func repeatDemo() -> String? {
        guard phase == .guiding, !isVoicePaused else { return nil }
        let repeatedRep = max(1, currentDemoRep)
        invalidateDemoContinuation()
        loopTask?.cancel()
        targets.removeActiveTarget()
        let solver = ArmPoseSolver(measurements: measurements)
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.runGuidedFollowAlong(solver: solver, startingAt: repeatedRep)
            guard !Task.isCancelled else { return }
            await self.runCountdown()
            guard !Task.isCancelled else { return }
            await self.runScoredTargetRound(solver: solver)
        }
        return "Repeating demo \(repeatedRep)."
    }

    func setDemoRate(_ rate: TrainingDemoRate) -> String? {
        guard phase == .guiding, !isVoicePaused else { return nil }
        demonstrationRate = rate
        switch rate {
        case .slower: return "Showing the demo slower."
        case .normal: return "Demo speed reset."
        case .faster: return "Showing the demo faster."
        }
    }

    func advanceDemo() -> String? {
        guard phase == .guiding, !isVoicePaused else { return nil }
        let nextRep = min(max(1, currentDemoRep + 1), max(1, guidedRepetitions))
        guard nextRep > currentDemoRep else { return nil }
        demoContinuationGeneration &+= 1
        requestedDemoRep = nextRep
        currentDemoRep = nextRep
        return "Moving to demo \(nextRep)."
    }

    /// Publishes the rep that the production demonstration loop is about to play. A stale loop
    /// cannot overwrite an accepted `next` command because its captured generation is rejected.
    @discardableResult
    func guidedDemoDidBegin(
        at rep: Int,
        continuationGeneration: UInt64
    ) -> Bool {
        guard continuationGeneration == demoContinuationGeneration,
              requestedDemoRep == nil,
              (1...max(1, guidedRepetitions)).contains(rep) else { return false }
        phase = .guiding
        currentDemoRep = rep
        return true
    }

    private func invalidateDemoContinuation() {
        demoContinuationGeneration &+= 1
        requestedDemoRep = nil
    }

    private func invalidateVoiceResume() {
        voiceResumeGeneration &+= 1
        activeVoiceResumeGeneration = nil
    }

    func requestCorrection() -> String? {
        feedback?.primaryFix ?? (phase == .attempting ? statusMessage : nil)
    }

    func requestGuardExplanation() -> String? {
        guard phase != .idle else { return nil }
        return "Keep the other fist by your chin so every punch starts and finishes from guard."
    }

    func requestTargetHelp() -> String? {
        guard phase != .idle, phase != .results else { return nil }
        return "Follow the hologram, punch through its visible target, then return to guard."
    }

    func requestProgress() -> String {
        switch phase {
        case .guiding:
            return "Demo \(min(currentDemoRep, guidedRepetitions)) of \(guidedRepetitions)"
        case .countdown:
            return "Demo complete · scored punches start next"
        case .attempting:
            return "Punch \(min(currentScoredPunch, scoredPunchCount)) of \(scoredPunchCount)"
        case .scoring:
            return "Scoring \(scoredRoundScores.count) punches"
        case .results:
            return "\(scoredRoundScores.count) of \(scoredPunchCount) punches complete"
        case .idle, .acquiring:
            return statusMessage
        }
    }

    func acceptsVoiceResumeGuard(_ snapshot: VoiceGuardSnapshot) -> Bool {
        VoiceGuardValidator.accepts(
            snapshot,
            capturedGuards: nil,
            shoulderWidth: measurements.shoulderWidth,
            armReach: measurements.armReach
        )
    }

    private func currentVoiceGuardSnapshot() -> VoiceGuardSnapshot? {
        guard let frame = currentBodyFrame(solver: ArmPoseSolver(measurements: measurements)),
              let left = hands.freshObservation(for: .left),
              let right = hands.freshObservation(for: .right) else { return nil }
        let generation = hands.providerGeneration
        let continuityEpoch = hands.continuityEpoch
        return VoiceGuardSnapshot(
            trackingIsRunning: hands.isRunning,
            capturedAt: CACurrentMediaTime(),
            generation: generation,
            continuityEpoch: continuityEpoch,
            frame: VoiceGuardFrame(frame),
            left: VoiceGuardHandEvidence(
                side: left.side,
                fistPosition: left.fistPosition,
                fistState: left.fistState,
                acquisitionTimestamp: left.acquisitionTimestamp,
                generation: generation,
                continuityEpoch: continuityEpoch
            ),
            right: VoiceGuardHandEvidence(
                side: right.side,
                fistPosition: right.fistPosition,
                fistState: right.fistState,
                acquisitionTimestamp: right.acquisitionTimestamp,
                generation: generation,
                continuityEpoch: continuityEpoch
            )
        )
    }

    // MARK: Session loop

    private func runSession() async {
        let solver = ArmPoseSolver(measurements: measurements)

        guard await acquireTracking() else { return }
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
        playCoachCue(.welcome, caption: "Raise your guard and follow the hologram.")

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
        AuraPunchSideSequence.side(
            forRepetition: rep,
            technique: technique,
            stance: stance
        )
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
        solver: ArmPoseSolver,
        startingAt startRep: Int = 1
    ) async {
        guard !Task.isCancelled else { return }
        phase = .guiding
        mirrorArm?.isVisible = false

        let reps = max(1, guidedRepetitions)
        let clampedStartRep = min(max(1, startRep), reps)
        var rep = clampedStartRep
        var continuationGeneration = demoContinuationGeneration
        var speedFactor = max(
            minimumGuidedSpeedFactor,
            pow(guidedSpeedUp, Double(clampedStartRep - 1))
        )

        demoLoop: while rep <= reps {
            guard !Task.isCancelled else { return }
            if let requestedRep = requestedDemoRep {
                rep = requestedRep
                requestedDemoRep = nil
                continuationGeneration = demoContinuationGeneration
                speedFactor = max(
                    minimumGuidedSpeedFactor,
                    pow(guidedSpeedUp, Double(rep - 1))
                )
            }
            guard guidedDemoDidBegin(
                at: rep,
                continuationGeneration: continuationGeneration
            ) else { return }

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
                trackLandingTarget: true,
                continuationGeneration: continuationGeneration
            )
            guard !Task.isCancelled else { return }
            if continuationGeneration != demoContinuationGeneration {
                guard requestedDemoRep != nil else { return }
                continue demoLoop
            }

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
                trackLandingTarget: true,
                continuationGeneration: continuationGeneration
            )
            guard !Task.isCancelled else { return }
            if continuationGeneration != demoContinuationGeneration {
                guard requestedDemoRep != nil else { return }
                continue demoLoop
            }

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
                trackLandingTarget: false,
                continuationGeneration: continuationGeneration
            )
            guard !Task.isCancelled else { return }
            if continuationGeneration != demoContinuationGeneration {
                guard requestedDemoRep != nil else { return }
                continue demoLoop
            }

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
                trackLandingTarget: false,
                continuationGeneration: continuationGeneration
            )
            guard !Task.isCancelled else { return }
            if continuationGeneration != demoContinuationGeneration {
                guard requestedDemoRep != nil else { return }
                continue demoLoop
            }

            speedFactor = max(minimumGuidedSpeedFactor, speedFactor * guidedSpeedUp)
            rep += 1
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
        trackLandingTarget: Bool = false,
        continuationGeneration: UInt64
    ) async {
        let span = max(0, end - start)
        guard span > 0 else {
            guard !Task.isCancelled,
                  continuationGeneration == demoContinuationGeneration else { return }
            poseGhost(reference: reference, side: side, solver: solver, at: end)
            return
        }

        let wallDuration = span * speedFactor / demonstrationRate.playbackMultiplier
        var activeElapsed: TimeInterval = 0
        var lastTick = CACurrentMediaTime()

        while activeElapsed < wallDuration {
            guard !Task.isCancelled,
                  continuationGeneration == demoContinuationGeneration else { return }

            let now = CACurrentMediaTime()
            let guardUp = nonPunchingGuardStatus(punchingSide: side, solver: solver)

            if guardUp == false {
                if statusMessage != GuardCoach.waitMessage {
                    playCoachCue(.guardUp, caption: GuardCoach.waitMessage)
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
        trackLandingTarget: Bool = false,
        continuationGeneration: UInt64
    ) async {
        guard let targetFist = reference.sample(at: referenceTime)?.fist else { return }
        let goal = HoldGoal(targetFist: targetFist, tolerance: followPositionTolerance)
        let deadline = CACurrentMediaTime() + followHoldTimeout

        while CACurrentMediaTime() < deadline {
            guard !Task.isCancelled,
                  continuationGeneration == demoContinuationGeneration else { return }

            if nonPunchingGuardStatus(punchingSide: side, solver: solver) == false {
                if statusMessage != GuardCoach.waitMessage {
                    playCoachCue(.guardUp, caption: GuardCoach.waitMessage)
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
        playCoachCue(.countdown, caption: "Your turn in three, two, one.")
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
        audioCoordinator.handleImmediately(.experienceDidEnter(.baseline))
        currentScoredPunch = 0
        playCoachCue(.hitTarget, caption: "Hit each target.")

        var punchIndex = scoredRoundScores.count + 1
        while punchIndex <= scoredPunchCount {
            guard !Task.isCancelled else { return }

            currentScoredPunch = punchIndex
            setCoaching(
                headline: "HIT THE TARGET",
                detail: "Punch \(punchIndex) of \(scoredPunchCount) — hit the target",
                status: "Punch \(punchIndex) of \(scoredPunchCount) — hit the target!"
            )

            // `punchIndex` advances only after semantic admission, so a technical retry preserves
            // this exact physical side and evidence chain instead of alternating mid-punch.
            let expectedSide = AuraPunchSideSequence.side(
                forRepetition: punchIndex,
                technique: technique,
                stance: stance
            )
            let reference = ReferencePunchLibrary.punch(
                for: technique,
                stance: stance,
                measurements: measurements,
                side: expectedSide
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
                statusMessage = "Tracking changed · punch discarded"
                try? await Task.sleep(for: .milliseconds(220))
                continue
            }

            if audioCoordinator.presentation.isScoringFrozen,
               !audioCoordinator.presentation.requiresExplicitRecovery,
               hands.freshObservation(for: expectedSide) != nil {
                audioCoordinator.handleImmediately(.trackingDidResume)
            }
            guard !audioCoordinator.presentation.isScoringFrozen else {
                statusMessage = audioCoordinator.presentation.caption
                    ?? "Training paused · return to guard"
                try? await Task.sleep(for: .milliseconds(25))
                continue
            }

            targets.spawnTarget(at: landing, radius: targetVisualRadius)
            audioCoordinator.handleImmediately(.targetDidAppear(position: landing))

            let capture = await capturePunchUntilHit(
                solver: solver,
                side: expectedSide
            )

            guard let capture else {
                targets.removeActiveTarget()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(interScoredPunchDelay))
                continue
            }

            let punchReference = ReferencePunchLibrary.punch(
                for: technique,
                stance: stance,
                measurements: measurements,
                side: capture.side
            )
            guard let computed = scorer.score(
                attempt: capture.attempt,
                reference: punchReference,
                technique: technique,
                thrownSide: capture.side,
                stance: stance
            ) else {
                statusMessage = "Punch evidence was invalid · reset in guard"
                targets.removeActiveTarget()
                try? await Task.sleep(for: .milliseconds(220))
                continue
            }
            scoredRoundScores.append(computed)
            punchIndex += 1

            try? await Task.sleep(for: .milliseconds(220))
            targets.removeActiveTarget()

            if punchIndex <= scoredPunchCount {
                try? await Task.sleep(for: .seconds(interScoredPunchDelay))
            }
        }

        currentScoredPunch = 0
        mirrorArm?.isVisible = false

        guard let aggregated = TechniqueScore.averaging(
            scoredRoundScores,
            techniqueID: technique.id
        ) else {
            fail("Couldn't see a punch. Keep both hands in view and hit each target.")
            return
        }

        finishAggregated(aggregated)
    }

    /// Records one fixed physical hand through validated outbound contact and return to guard.
    private func capturePunchUntilHit(
        solver: ArmPoseSolver,
        side: BodySide
    ) async -> (side: BodySide, attempt: RecordedAttempt)? {
        let throwMessage = statusMessage

        cachedBodyFrame = nil
        cachedBodyFrameTime = 0

        let startTime = CACurrentMediaTime()
        guard let targetPosition = targets.activeTargetPosition else {
            statusMessage = "Punch evidence was invalid · reset in guard"
            return nil
        }
        guard let guardObservation = hands.freshObservation(for: side) else {
            statusMessage = "Tracking changed · punch discarded"
            return nil
        }
        guard guardObservation.fistState == .closed else {
            rejectCurrentPunch(
                PunchEvidenceFeedback.message(
                    for: .fistNotClosed(side: side, state: guardObservation.fistState)
                ),
                at: targetPosition
            )
            return nil
        }

        let captureChain = PunchEvidenceCaptureChain(
            generation: hands.providerGeneration,
            continuityEpoch: hands.continuityEpoch
        )
        var validator = PunchEvidenceValidator(
            configuration: .init(
                technique: technique,
                stance: stance,
                requiredHand: side,
                guardPosition: guardObservation.fistPosition,
                targetPosition: targetPosition,
                targetRadius: targetHitRadius,
                generation: captureChain.generation,
                continuityEpoch: captureChain.continuityEpoch
            )
        )

        hands.beginAttemptCapture()
        defer { hands.endAttemptCapture() }

        for recorder in recorders.values { recorder.begin(at: startTime) }
        var trackingContinuity = TrackingContinuityObserver(epoch: captureChain.continuityEpoch)

        let armingDeadline = CACurrentMediaTime() + scoredPunchSafetyTimeout
        var evidenceCursor = PunchEvidenceFrameCursor()

        while CACurrentMediaTime() < armingDeadline {
            if Task.isCancelled { break }
            if trackingContinuity.observe(hands.continuityEpoch) {
                for recorder in recorders.values { recorder.cancel() }
                mirrorArm?.isVisible = false
                statusMessage = "Tracking changed · punch discarded"
                audioCoordinator.handleImmediately(.trackingDidPause(.staleSamples))
                return nil
            }

            let now = CACurrentMediaTime()
            _ = recordAttemptFrame(
                solver: solver,
                startTime: startTime,
                throwMessage: throwMessage,
                at: now
            )

            if let evidenceFrame = punchEvidenceFrame(now: now, requiredSide: side),
               evidenceCursor.shouldObserve(evidenceFrame) {
                let event = validator.observe(evidenceFrame)
                switch event {
                case .waiting:
                    break
                case .armed:
                    statusMessage = "Punch through the target"
                case .contact:
                    statusMessage = PunchEvidenceFeedback.returnToGuard(side: side, style: .snap)
                case .readyForCoverage:
                    guard let attempt = capturedAttempt(for: side), attempt.isUsable else {
                        for recorder in recorders.values { recorder.cancel() }
                        mirrorArm?.isVisible = false
                        rejectCurrentPunch(
                            PunchEvidenceFeedback.message(for: .missingTrackingCoverage),
                            at: targetPosition
                        )
                        return nil
                    }
                    guard let coverage = captureChain.coverage(
                        trackedFraction: attempt.trackedFraction,
                        currentGeneration: hands.providerGeneration,
                        currentContinuityEpoch: hands.continuityEpoch
                    ) else {
                        for recorder in recorders.values { recorder.cancel() }
                        mirrorArm?.isVisible = false
                        statusMessage = "Tracking changed · punch discarded"
                        audioCoordinator.handleImmediately(.trackingDidPause(.staleSamples))
                        return nil
                    }
                    switch PunchEvidenceAttemptAction(
                        event: validator.complete(coverage: coverage)
                    ) {
                    case .admit:
                        // Satisfying feedback is downstream of semantic admission only.
                        targets.flash(result: .hit)
                        audioCoordinator.handleImmediately(.validatedImpact(
                            position: targetPosition,
                            quality: .clean
                        ))
                        mirrorArm?.isVisible = false
                        return (side, attempt)
                    case let .retry(reason):
                        for recorder in recorders.values { recorder.cancel() }
                        mirrorArm?.isVisible = false
                        rejectCurrentPunch(
                            PunchEvidenceFeedback.message(for: reason),
                            at: targetPosition
                        )
                        return nil
                    case .waiting, .armed, .contact, .completeCoverage:
                        for recorder in recorders.values { recorder.cancel() }
                        mirrorArm?.isVisible = false
                        rejectCurrentPunch("Punch evidence was incomplete", at: targetPosition)
                        return nil
                    }
                case let .invalid(reason):
                    for recorder in recorders.values { recorder.cancel() }
                    mirrorArm?.isVisible = false
                    rejectCurrentPunch(
                        PunchEvidenceFeedback.message(for: reason),
                        at: targetPosition
                    )
                    return nil
                case .validated:
                    break
                }
            }

            try? await Task.sleep(for: frameInterval)
        }

        mirrorArm?.isVisible = false
        for recorder in recorders.values { recorder.cancel() }
        if !Task.isCancelled,
           case let .retry(reason) = PunchEvidenceAttemptAction(event: validator.finish()) {
            rejectCurrentPunch(PunchEvidenceFeedback.message(for: reason), at: targetPosition)
        }
        return nil
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

    private func capturedAttempt(for side: BodySide) -> RecordedAttempt? {
        let captured = recorders.mapValues { $0.finish() }
        return captured[side]
    }

    /// Publishes the deterministic result synchronously, then starts one optional prose request.
    ///
    /// The returned task is primarily useful to callers that need to coordinate teardown. The
    /// session also owns and cancels it, and accepts its value only while this exact generation is
    /// still active.
    @discardableResult
    func finishAggregated(_ aggregated: TechniqueScore) -> Task<Void, Never> {
        guard !audioCoordinator.presentation.isScoringFrozen else {
            statusMessage = audioCoordinator.presentation.caption
                ?? "Training paused · no score recorded"
            return Task {}
        }
        cancelPendingPhrasing()
        phase = .scoring
        statusMessage = "Scoring…"

        let resultTechnique = technique
        let resultStance = stance
        let localFeedback = feedbackGenerator.localFeedback(
            for: aggregated,
            technique: resultTechnique,
            stance: resultStance,
            previousFocus: previousCorrectionFocus,
            audienceTrack: audienceTrack
        )
        score = aggregated
        feedback = localFeedback

        if let focus = localFeedback.decision.focus {
            previousCorrectionFocus = focus
        } else if localFeedback.correctionCode == .repeatShape {
            previousCorrectionFocus = nil
        }

        if localFeedback.correctionCode != .trackingRecovery {
            audioCoordinator.handleImmediately(.experienceDidEnter(.celebrate))
            playCoachCue(
                aggregated.overall >= 74 ? .resultsGood : .resultsNeedsWork,
                kind: .result,
                caption: aggregated.overall >= 74
                    ? "Strong round."
                    : "Round complete. Review the correction and try again."
            )
        }
        phase = .results
        statusMessage = aggregated.wrongHand
            ? "Round complete — that was your \(aggregated.thrownHandName) hand"
            : "Round complete"

        guard localFeedback.correctionCode != .trackingRecovery else {
            return Task {}
        }

        let generation = feedbackGeneration
        let generator = feedbackGenerator
        let task = Task { [weak self, generator, resultTechnique, aggregated, localFeedback] in
            let phrasing = await generator.phrasing(
                for: aggregated,
                technique: resultTechnique,
                decision: localFeedback.decision
            )

            guard let self else { return }
            defer {
                if self.feedbackGeneration == generation {
                    self.phrasingTask = nil
                }
            }
            guard
                !Task.isCancelled,
                self.feedbackGeneration == generation,
                self.phase == .results,
                self.score?.techniqueID == aggregated.techniqueID
            else {
                return
            }
            guard let phrasing else { return }
            self.feedback = localFeedback.applying(phrasing)
        }
        phrasingTask = task
        return task
    }

    // MARK: Helpers

    private func punchEvidenceFrame(
        now: TimeInterval,
        requiredSide: BodySide
    ) -> PunchEvidenceValidator.Frame? {
        let observations = [BodySide.left, .right].compactMap {
            hands.freshObservation(for: $0)
        }
        guard let required = observations.first(where: { $0.side == requiredSide }) else {
            return nil
        }
        return PunchEvidenceValidator.Frame(
            now: now,
            deviceTimestamp: required.deviceTimestamp,
            generation: hands.providerGeneration,
            continuityEpoch: hands.continuityEpoch,
            hands: observations.map {
                PunchEvidenceValidator.HandSample(
                    side: $0.side,
                    fistPosition: $0.fistPosition,
                    fistState: $0.fistState,
                    acquisitionTimestamp: $0.acquisitionTimestamp,
                    quality: .measured
                )
            }
        )
    }

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
        audioCoordinator.handleImmediately(.targetDidAppear(position: landing))
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

    private func cancelPendingPhrasing() {
        feedbackGeneration &+= 1
        phrasingTask?.cancel()
        phrasingTask = nil
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
        audioCoordinator.handleImmediately(.trainingDidStop(preservingVoiceCapture: false))
    }

    private func playCoachCue(
        _ clip: CoachClipID,
        kind: TrainingCoachCueKind = .phaseInstruction,
        caption: String
    ) {
        audioCoordinator.handleImmediately(.coachCue(TrainingCoachCue(
            kind: kind,
            clip: clip,
            caption: caption
        )))
    }

    private func rejectCurrentPunch(_ reason: String, at position: SIMD3<Float>) {
        statusMessage = reason
        if targets.showInvalidEvidenceOnce() {
            audioCoordinator.handleImmediately(.rejectedImpact(
                position: position,
                reason: reason
            ))
        }
    }
}

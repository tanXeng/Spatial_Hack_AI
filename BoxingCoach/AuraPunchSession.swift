import Foundation
import QuartzCore
import RealityKit
import simd

@MainActor
protocol CoachAudioPlaying: AnyObject {
    func prepare()
    func play(id: CoachClipID)
    func stop()
}

/// The live Aura loop depends on accepted tracking observations, not on ARKit ownership. Keeping
/// that boundary injectable lets the entire cycle run against a deterministic provider while the
/// app continues to share one concrete `HandTrackingService` with Reactive Strike.
@MainActor
protocol AuraHandTracking: AnyObject {
    var providerGeneration: UInt64 { get }
    var continuityEpoch: UInt64 { get }
    var statusMessage: String { get }
    var deviceTransform: simd_float4x4? { get }
    var isRunning: Bool { get }
    var hasFullUpperBodyTracking: Bool { get }

    func start() async
    func beginAttemptCapture()
    func endAttemptCapture()
    func observation(for side: BodySide) -> HandObservation?
    func freshObservation(for side: BodySide, maxAge: TimeInterval) -> HandObservation?
}

extension AuraHandTracking {
    func freshObservation(for side: BodySide) -> HandObservation? {
        freshObservation(for: side, maxAge: 0.1)
    }
}

extension HandTrackingService: AuraHandTracking {}

@MainActor
protocol AuraSessionClock: AnyObject {
    var now: TimeInterval { get }
    func sleep(for duration: Duration) async
}

@MainActor
private final class ContinuousAuraSessionClock: AuraSessionClock {
    var now: TimeInterval { CACurrentMediaTime() }

    func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

/// A capture override receives the same fitted reference and tracking identity as the live
/// recorder. Production leaves this nil and therefore still passes through the semantic punch
/// validator; deterministic integration exercises can substitute this single sensor boundary
/// while retaining Aura's real scoring, admission, proof, transfer, and persistence path.
struct AuraPunchCaptureRequest {
    let technique: Technique
    let stance: Stance
    let side: BodySide
    let reference: ReferencePunch
    let providerGeneration: UInt64
    let continuityEpoch: UInt64
}

struct AuraCapturedPunch {
    let side: BodySide
    let attempt: RecordedAttempt
    let punch: ValidatedPunchEvidence
}
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
    var track: TrainingTrack

    /// A same-participant Fit result may be reused; nil runs Fit in the immersive cycle.
    var persistedReach: BilateralReach?
    var reachDidFit: ((BilateralReach) -> Void)?
    var voiceGuardDidRecover: (() -> Void)?
    var cycleDidComplete: (
        (CoachingCycleResult, BilateralReach) async throws -> CoachingCyclePersistenceScope
    )?

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
    private(set) var coachingCycle: CoachingCycleSession

    var learningStage: LearningStage { coachingCycle.stage }
    var cyclePresentation: CoachingCyclePresentation { coachingCycle.presentation }
    var proofMetric: CoachingProofMetric? { coachingCycle.proofMetric }
    var publicProgress: CoachingCycleProgress? { coachingCycle.publicProgress }
    var correctionFocus: SubMetricKind? { coachingCycle.correctionFocus }
    var correctionOverlay: CorrectionPathOverlay? { coachingCycle.correctionOverlay }
    var cycleResult: CoachingCycleResult? { coachingCycle.result }
    var fittedReach: BilateralReach? { coachingCycle.fittedReach }
    var isTrackingPaused: Bool { coachingCycle.isTrackingPaused }
    var isTrainingPaused: Bool { coachingCycle.isTrainingPaused }

    var isRunning: Bool {
        phase != .idle && phase != .results
    }

    // MARK: Collaborators

    private let hands: any AuraHandTracking
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
    private let clock: any AuraSessionClock
    private let captureOverride: (@MainActor (AuraPunchCaptureRequest) async -> AuraCapturedPunch?)?
    private let targets = TargetController()
    private let pathOverlay = PunchPathOverlayEntity()

    private var demoArm: ArmSilhouetteEntity?
    private var mirrorArm: ArmSilhouetteEntity?
    private weak var sceneRoot: Entity?

    private var loopTask: Task<Void, Never>?
    private var voiceRecoveryTask: Task<Void, Never>?
    private var recoveringVoiceCaptureID: UUID?
    private var coachVoiceCyclePauseOwner = CoachVoiceCyclePauseOwner()
    /// At most one optional relay request may be associated with the visible result.
    private var phrasingTask: Task<Void, Never>?
    /// Monotonic local token. It never crosses the relay boundary.
    private var feedbackGeneration: UInt64 = 0
    private var phaseBeforeVoicePause: AuraPunchPhase?
    private var requestedDemoRep: Int?
    private var scoredRoundScores: [TechniqueScore] = []
    /// The last actionable metric focus in this training session.
    private var previousCorrectionFocus: SubMetricKind?
    private var guardPositionsBody: [BodySide: SIMD3<Float>] = [:]

    /// Reused briefly when head tracking flickers mid-attempt so hand samples are not discarded.
    private var cachedBodyFrame: BodyFrame?
    private var cachedBodyFrameTime: TimeInterval = 0
    private let bodyFrameCacheDuration: TimeInterval = 0.25

    /// Frame interval for the pose loop. Hand tracking runs at ~90 Hz; polling faster just burns
    /// cycles re-reading the same anchor.
    private let frameInterval: Duration = .milliseconds(11)

    init(
        hands: any AuraHandTracking,
        feedbackGenerator: FeedbackGenerating = MockFeedbackGenerator(),
        audienceTrack: CoachLearnerLevel,
        audioCoordinator: TrainingAudioCoordinator? = nil,
        coachAudio: (any CoachAudioPlaying)? = nil,
        clock: (any AuraSessionClock)? = nil,
        captureOverride: (@MainActor (AuraPunchCaptureRequest) async -> AuraCapturedPunch?)? = nil
    ) {
        self.hands = hands
        self.feedbackGenerator = feedbackGenerator
        self.audienceTrack = audienceTrack
        self.audioCoordinator = audioCoordinator ?? TrainingAudioCoordinator()
        self.clock = clock ?? ContinuousAuraSessionClock()
        self.captureOverride = captureOverride
        _ = coachAudio
        let selectedTrack: TrainingTrack = audienceTrack == .beginner
            ? .firstRound
            : .technicalCamp
        track = selectedTrack
        coachingCycle = CoachingCycleSession(
            track: selectedTrack,
            technique: .jab,
            stance: .orthodox
        )
    }

    isolated deinit {
        loopTask?.cancel()
        voiceRecoveryTask?.cancel()
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
        pathOverlay.attach(to: root)
    }

    func detach() {
        cancelPendingPhrasing()
        targets.removeActiveTarget()
        demoArm?.removeFromScene()
        mirrorArm?.removeFromScene()
        pathOverlay.clear()
        pathOverlay.removeFromScene()
        demoArm = nil
        mirrorArm = nil
        sceneRoot = nil
    }

    // MARK: Control

    func start() {
        guard phase == .idle || phase == .results else { return }

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
        guidedRepetitions = track.guidedRehearsalCount
        coachingCycle = CoachingCycleSession(
            track: track,
            technique: technique,
            stance: stance
        )
        audioCoordinator.handleImmediately(
            .experienceDidEnter(coachingCycle.stage.trainingAudioStage)
        )
        guardPositionsBody.removeAll(keepingCapacity: false)
        pathOverlay.clear()

        // Rebuild the ghost arms for the currently selected technique — switching from a jab to a
        // cross switches which arm throws, and a silhouette built for the old side would appear
        // on the wrong arm.
        if let root = sceneRoot {
            attach(to: root)
        }

        loopTask?.cancel()
        voiceRecoveryTask?.cancel()
        voiceRecoveryTask = nil
        coachVoiceCyclePauseOwner.reset()
        loopTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    func stop(
        preservingVoiceCapture: Bool = false,
        emitsTrainingStop: Bool = true
    ) {
        // Results are not "running", but their optional phrasing request still is.
        cancelPendingPhrasing()

        // No-op when nothing is running, so Reactive Strike's own stop path — which shares this
        // call — never clears a finished Aura Punch result out from under the user.
        guard isRunning else { return }

        loopTask?.cancel()
        loopTask = nil
        voiceRecoveryTask?.cancel()
        voiceRecoveryTask = nil
        recoveringVoiceCaptureID = nil
        coachVoiceCyclePauseOwner.reset()
        for recorder in recorders.values { recorder.cancel() }
        targets.removeActiveTarget()
        pathOverlay.hide()
        demoArm?.isVisible = false
        mirrorArm?.isVisible = false
        currentScoredPunch = 0
        isVoicePaused = false
        phaseBeforeVoicePause = nil
        invalidateVoiceResume()
        invalidateDemoContinuation()
        phase = .idle
        statusMessage = "Stopped"
        if emitsTrainingStop {
            audioCoordinator.handleImmediately(.trainingDidStop(
                preservingVoiceCapture: preservingVoiceCapture
            ))
        }
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
        recoveringVoiceCaptureID = nil
        coachVoiceCyclePauseOwner.reset()
        persistedReach = nil
        guardPositionsBody.removeAll(keepingCapacity: false)
        coachingHeadline = "GET READY"
        coachingDetail = "Raise your guard to begin"
        currentDemoRep = 0
        currentScoredPunch = 0
        liveReach = 0
        coachingCycle = CoachingCycleSession(
            track: track,
            technique: technique,
            stance: stance
        )
        pathOverlay.clear()
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
        AuraVoiceCaptureTrainingPolicy.captureDidBegin(cycle: &coachingCycle)
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

        guard requestIsCurrent(), phaseBeforeVoicePause != nil else {
            return nil
        }
        isVoicePaused = false
        phaseBeforeVoicePause = nil
        activeVoiceResumeGeneration = requestGeneration
        AuraVoiceCaptureTrainingPolicy.guardRecoveryDidComplete(cycle: &coachingCycle)
        applyCyclePresentation()
        return "Tracking is fresh. Resuming training."
    }

    func repeatDemo() -> String? {
        guard phase == .guiding,
              coachingCycle.stage == .guidedRehearsal,
              !isVoicePaused else { return nil }
        let repeatedRep = max(1, currentDemoRep)
        demoContinuationGeneration &+= 1
        requestedDemoRep = repeatedRep
        targets.removeActiveTarget()
        return "Repeating demo \(repeatedRep)."
    }

    func setDemoRate(_ rate: TrainingDemoRate) -> String? {
        guard phase == .guiding,
              coachingCycle.stage == .guidedRehearsal,
              !isVoicePaused else { return nil }
        demonstrationRate = rate
        switch rate {
        case .slower: return "Showing the demo slower."
        case .normal: return "Demo speed reset."
        case .faster: return "Showing the demo faster."
        }
    }

    func advanceDemo() -> String? {
        guard phase == .guiding,
              currentDemoRep > 0,
              !isVoicePaused else { return nil }
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

    /// Consumes the exact lifecycle emitted by `CoachVoiceCoach`. Capture release is intentionally
    /// non-terminal; recognition, routing, response playback, and a fresh fitted guard all remain
    /// inside the same pause owned by this coaching cycle.
    func handleCoachVoiceCycle(_ event: CoachVoiceCyclePauseOwner.Event) {
        guard isRunning else {
            coachVoiceCyclePauseOwner.reset()
            return
        }

        switch coachVoiceCyclePauseOwner.observe(event) {
        case .pauseTraining:
            trainingWillPauseForVoiceCapture()
        case .holdTraining, .ignore:
            break
        case .beginFreshGuardRecovery:
            let captureID: UUID
            switch event {
            case .responseCompleted(let id), .responseCancelled(let id):
                captureID = id
            default:
                return
            }
            trainingDidFinishVoiceResponse(captureID: captureID)
        case .resumeTraining:
            trainingDidConfirmVoiceGuardRecovery()
            voiceGuardDidRecover?()
        }
    }

    private func trainingWillPauseForVoiceCapture() {
        guard phase != .idle, phase != .results else { return }
        voiceRecoveryTask?.cancel()
        voiceRecoveryTask = nil
        recoveringVoiceCaptureID = nil
        AuraVoiceCaptureTrainingPolicy.captureDidBegin(cycle: &coachingCycle)
        for recorder in recorders.values { recorder.cancel() }
        targets.removeActiveTarget()
        setCoaching(
            headline: "TRAINING PAUSED",
            detail: "Ask your question, then return both closed fists to your fitted guard",
            status: "Training paused for Ask Coach"
        )
    }

    private func trainingDidFinishVoiceResponse(captureID: UUID) {
        guard coachingCycle.isTrainingPaused else { return }
        voiceRecoveryTask?.cancel()
        recoveringVoiceCaptureID = captureID
        voiceRecoveryTask = Task { [weak self] in
            await self?.recoverAfterVoiceCapture()
        }
    }

    private func trainingDidConfirmVoiceGuardRecovery() {
        guard coachingCycle.isTrainingPaused, recoveringVoiceCaptureID != nil else { return }
        recoveringVoiceCaptureID = nil
        AuraVoiceCaptureTrainingPolicy.guardRecoveryDidComplete(cycle: &coachingCycle)
        applyCyclePresentation()
    }

    // MARK: Session loop

    private func runSession() async {
        let solver = ArmPoseSolver(measurements: measurements)

        guard await acquireTracking() else { return }
        guard !Task.isCancelled else { return }

        guard await runFit(solver: solver) else { return }
        guard !Task.isCancelled else { return }

        await runLearningSequence(solver: solver)
        guard !Task.isCancelled, coachingCycle.stage == .baseline else { return }

        guard await runEvidenceRound(solver: solver) else { return }
        guard !Task.isCancelled, coachingCycle.stage == .correction else { return }

        while !Task.isCancelled {
            if coachingCycle.stage == .correction {
                await presentCorrection(solver: solver)
                guard !Task.isCancelled else { return }
                guard await waitForTrainingResume() else { return }
                do {
                    try coachingCycle.beginCorrectiveDrill()
                } catch {
                    fail("The corrective drill could not begin. Start the cycle again.")
                    return
                }
            }

            await runCorrectiveDrill(solver: solver)
            guard !Task.isCancelled else { return }
            guard await waitForTrainingResume() else { return }
            do {
                try coachingCycle.completeCorrectiveDrill()
            } catch {
                fail("The corrective drill could not complete. Start the cycle again.")
                return
            }

            guard await runEvidenceRound(solver: solver) else { return }
            guard !Task.isCancelled, coachingCycle.stage == .proof else { return }

            await presentProof()
            guard !Task.isCancelled else { return }
            guard await waitForTrainingResume() else { return }
            if coachingCycle.proofMeetsTarget { break }

            do {
                try coachingCycle.retryCorrectionFromProof()
                setCoaching(
                    headline: "KEEP THE CORRECTION",
                    detail: "The selected metric did not improve enough yet. Practice it once more.",
                    status: "Proof held · correction remains active"
                )
                await pauseAwareDelay(seconds: 1.2)
            } catch {
                fail("The correction could not be retried safely.")
                return
            }
        }

        do {
            guard await waitForTrainingResume() else { return }
            try coachingCycle.continueFromProof()
        } catch {
            fail("Like-for-like proof was unavailable. Repeat the retest.")
            return
        }

        guard await runOneTwoTransfer(solver: solver) else { return }
        guard !Task.isCancelled else { return }
        do {
            guard await waitForTrainingResume() else { return }
            try coachingCycle.completeTransfer()
        } catch {
            fail("The transfer could not be completed.")
            return
        }

        guard await waitForTrainingResume() else { return }
        guard let result = coachingCycle.result,
              let reach = coachingCycle.fittedReach,
              let cycleDidComplete else {
            fail("Athlete memory is unavailable, so this proof was not saved.")
            return
        }
        let persistenceScope: CoachingCyclePersistenceScope
        do {
            persistenceScope = try await cycleDidComplete(result, reach)
        } catch {
            fail("Your proof is complete, but athlete memory could not be saved.")
            return
        }
        guard await waitForTrainingResume() else { return }

        phase = .results
        currentScoredPunch = 0
        pathOverlay.hide()
        targets.removeActiveTarget()
        setCoaching(
            headline: "COMPLETE",
            detail: AuraCyclePersistencePresentation.detail(for: persistenceScope),
            status: AuraCyclePersistencePresentation.status(for: persistenceScope)
        )
        audioCoordinator.handleImmediately(.experienceDidEnter(.celebrate))
        audioCoordinator.handleImmediately(.unrankedResultDidFinalize)
        playCoachCue(
            .resultsGood,
            kind: .result,
            caption: "Coaching cycle complete. Your proof is ready."
        )
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

        while !Task.isCancelled {
            if Task.isCancelled { return false }
            if hands.hasFullUpperBodyTracking, currentBodyFrame(solver: ArmPoseSolver(measurements: measurements)) != nil {
                return true
            }
            await clock.sleep(for: frameInterval)
        }
        return false
    }

    private func runFit(solver: ArmPoseSolver) async -> Bool {
        phase = .acquiring
        applyCyclePresentation()
        guard let guards = await acquireCycleGuard(solver: solver) else { return false }
        guardPositionsBody = guards

        let reach: BilateralReach
        if let persistedReach {
            reach = persistedReach
        } else {
            guard let measured = await calibrateCycleReach(using: guards, solver: solver) else {
                return false
            }
            reach = measured
            persistedReach = measured
        }

        do {
            guard await waitForTrainingResume() else { return false }
            try coachingCycle.completeFit(reach: reach)
            reachDidFit?(reach)
            applyCyclePresentation()
            return true
        } catch {
            fail("Reach fit could not be admitted. Return to guard and try again.")
            return false
        }
    }

    private func acquireCycleGuard(
        solver: ArmPoseSolver
    ) async -> [BodySide: SIMD3<Float>]? {
        var totals: [BodySide: SIMD3<Float>] = [.left: .zero, .right: .zero]
        var count: Float = 0
        var lastPairTimestamp: TimeInterval?
        var continuity = TrackingContinuityObserver(epoch: hands.continuityEpoch)

        while !Task.isCancelled {
            if coachingCycle.isTrainingPaused {
                guard await waitForTrainingResume() else { return nil }
                totals = [.left: .zero, .right: .zero]
                count = 0
                lastPairTimestamp = nil
                continuity = TrackingContinuityObserver(epoch: hands.continuityEpoch)
                continue
            }
            if continuity.observe(hands.continuityEpoch) {
                totals = [.left: .zero, .right: .zero]
                count = 0
                lastPairTimestamp = nil
                coachingCycle.trackingDidPause()
                setCoaching(
                    headline: "TRACKING PAUSED",
                    detail: "Hold both closed fists in guard and look forward",
                    status: "Tracking paused · hold both fists in guard"
                )
            }

            guard let frame = currentBodyFrame(solver: solver),
                  let left = hands.freshObservation(for: .left),
                  let right = hands.freshObservation(for: .right),
                  left.fistState == .closed,
                  right.fistState == .closed
            else {
                await clock.sleep(for: .milliseconds(25))
                continue
            }

            let pairTimestamp = min(left.acquisitionTimestamp, right.acquisitionTimestamp)
            guard lastPairTimestamp.map({ pairTimestamp > $0 }) ?? true else {
                await clock.sleep(for: .milliseconds(25))
                continue
            }
            lastPairTimestamp = pairTimestamp

            let leftBody = frame.toBody(left.fistPosition)
            let rightBody = frame.toBody(right.fistPosition)
            let nearHead = simd_distance(left.fistPosition, frame.headPosition) <= 0.45
                && simd_distance(right.fistPosition, frame.headPosition) <= 0.45
            guard leftBody.isFinite, rightBody.isFinite, nearHead else {
                await clock.sleep(for: .milliseconds(25))
                continue
            }

            if coachingCycle.isTrackingPaused {
                coachingCycle.trackingDidResume()
                applyCyclePresentation()
            }
            totals[.left, default: .zero] += leftBody
            totals[.right, default: .zero] += rightBody
            count += 1
            if count >= 12 {
                return [
                    .left: totals[.left, default: .zero] / count,
                    .right: totals[.right, default: .zero] / count,
                ]
            }

            await clock.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private func calibrateCycleReach(
        using guards: [BodySide: SIMD3<Float>],
        solver: ArmPoseSolver
    ) async -> BilateralReach? {
        setCoaching(
            headline: "FIT YOUR REACH",
            detail: "Extend each closed fist comfortably and hold",
            status: "Fit · extend each arm comfortably"
        )
        playCoachCue(.calibrateReach, caption: "Extend each arm comfortably and hold.")

        var samples: [BodySide: [ReachSample]] = [.left: [], .right: []]
        var lastTimestamp: [BodySide: TimeInterval] = [:]
        var reaches: [BodySide: Float] = [:]
        var continuity = TrackingContinuityObserver(epoch: hands.continuityEpoch)

        while !Task.isCancelled {
            if coachingCycle.isTrainingPaused {
                guard await waitForTrainingResume() else { return nil }
                samples = [.left: [], .right: []]
                lastTimestamp.removeAll(keepingCapacity: true)
                reaches.removeAll(keepingCapacity: true)
                continuity = TrackingContinuityObserver(epoch: hands.continuityEpoch)
                continue
            }
            if continuity.observe(hands.continuityEpoch) {
                samples = [.left: [], .right: []]
                lastTimestamp.removeAll(keepingCapacity: true)
                reaches.removeAll(keepingCapacity: true)
                coachingCycle.trackingDidPause()
                setCoaching(
                    headline: "TRACKING PAUSED",
                    detail: "Return both fists to guard to restart Fit",
                    status: "Tracking paused · Fit restarted"
                )
                guard await waitForTrackingRecovery(solver: solver) else { return nil }
            }

            guard let frame = currentBodyFrame(solver: solver) else {
                await clock.sleep(for: .milliseconds(16))
                continue
            }

            for side in [BodySide.left, .right] where reaches[side] == nil {
                guard let guardPosition = guards[side],
                      let observation = hands.freshObservation(for: side),
                      observation.fistState == .closed,
                      observation.acquisitionTimestamp > (lastTimestamp[side] ?? -.infinity)
                else { continue }

                lastTimestamp[side] = observation.acquisitionTimestamp
                let fistBody = frame.toBody(observation.fistPosition)
                guard let candidate = ReachCalibration.candidateForwardReach(
                    guardPosition: guardPosition,
                    fistPosition: fistBody
                ) else { continue }
                samples[side, default: []].append(
                    ReachSample(forward: candidate, time: observation.acquisitionTimestamp)
                )
                if let settled = ReachCalibration.settledForwardReach(
                    from: samples[side, default: []]
                ) {
                    reaches[side] = settled
                    statusMessage = reaches.count == 1
                        ? "Fit · extend and hold the other arm"
                        : "Fit complete"
                }
            }

            if let bilateral = BilateralReach(reaches) {
                playCoachCue(.reachCalibrated, caption: "Reach calibrated.")
                return bilateral
            }
            await clock.sleep(for: .milliseconds(16))
        }
        return nil
    }

    private func runLearningSequence(solver: ArmPoseSolver) async {
        phase = .guiding
        let side = AuraPunchSideSequence.side(
            forRepetition: 1,
            technique: technique,
            stance: stance
        )
        let reference = fittedReference(side: side)
        let pace = 1 / max(Double(track.demonstrationRate), 0.01)

        applyCyclePresentation()
        await playGhost(
            reference: reference,
            side: side,
            solver: solver,
            from: 0,
            to: reference.duration,
            speedFactor: pace,
            phaseMessage: statusMessage
        )
        guard await advanceLearningCycle() else { return }

        applyCyclePresentation()
        spawnLandingTarget(reference: reference, side: side, solver: solver)
        await playGhost(
            reference: reference,
            side: side,
            solver: solver,
            from: 0,
            to: reference.peakTime,
            speedFactor: pace,
            phaseMessage: statusMessage,
            trackLandingTarget: true
        )
        guard await advanceLearningCycle() else { return }

        applyCyclePresentation()
        await holdGhost(
            reference: reference,
            side: side,
            solver: solver,
            at: reference.peakTime,
            phaseMessage: statusMessage,
            trackLandingTarget: true
        )
        guard await advanceLearningCycle() else { return }

        targets.removeActiveTarget()
        applyCyclePresentation()
        await playGhost(
            reference: reference,
            side: side,
            solver: solver,
            from: reference.peakTime,
            to: reference.duration,
            speedFactor: pace,
            phaseMessage: statusMessage
        )
        await holdGhost(
            reference: reference,
            side: side,
            solver: solver,
            at: reference.duration,
            phaseMessage: statusMessage
        )
        guard await advanceLearningCycle() else { return }

        await runGuidedFollowAlong(solver: solver)
    }

    private func advanceLearningCycle() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard await waitForTrainingResume() else { return false }
        do {
            try coachingCycle.completeLearningStep()
            return true
        } catch {
            fail("The learning sequence could not advance.")
            return false
        }
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
        ) / max(Double(track.demonstrationRate), 0.01)

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
            let reference = fittedReference(side: side)
            let handLabel = technique.hand == .either ? " — \(side.rawValue) \(technique.name.lowercased())" : ""

            let pace = track == .firstRound ? " — steady pace" : " — technical pace"
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

            guard await waitForTrainingResume() else { return }
            do {
                try coachingCycle.completeGuidedRehearsal()
            } catch {
                fail("The guided rehearsal could not advance.")
                return
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
        continuationGeneration: UInt64? = nil
    ) async {
        let continuationGeneration = continuationGeneration ?? demoContinuationGeneration
        let span = max(0, end - start)
        guard span > 0 else {
            guard !Task.isCancelled,
                  continuationGeneration == demoContinuationGeneration else { return }
            poseGhost(reference: reference, side: side, solver: solver, at: end)
            return
        }

        let wallDuration = span * speedFactor / demonstrationRate.playbackMultiplier
        var activeClock = AuraGuidanceActiveClock()

        while activeClock.activeElapsed < wallDuration {
            guard !Task.isCancelled,
                  continuationGeneration == demoContinuationGeneration else { return }

            let now = clock.now
            if coachingCycle.isTrainingPaused {
                _ = activeClock.observe(at: now, availability: .guardUnavailable)
                await clock.sleep(for: frameInterval)
                continue
            }
            let availability = guidanceAvailability(punchingSide: side, solver: solver)

            if availability == .trackingUnavailable {
                _ = activeClock.observe(at: now, availability: .trackingUnavailable)
                guard await recoverGuidanceTracking(solver: solver) else { return }
                continue
            }

            if availability == .guardUnavailable {
                _ = activeClock.observe(at: now, availability: .guardUnavailable)
                if statusMessage != GuardCoach.waitMessage {
                    playCoachCue(.guardUp, caption: GuardCoach.waitMessage)
                }
                statusMessage = GuardCoach.waitMessage
                let progress = wallDuration > 0 ? min(1, activeClock.activeElapsed / wallDuration) : 1
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
                await clock.sleep(for: frameInterval)
                continue
            }

            if statusMessage == GuardCoach.waitMessage {
                statusMessage = phaseMessage
            }

            _ = activeClock.observe(at: now, availability: .ready)

            let progress = wallDuration > 0 ? min(1, activeClock.activeElapsed / wallDuration) : 1
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
            await clock.sleep(for: frameInterval)
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
        continuationGeneration: UInt64? = nil
    ) async {
        let continuationGeneration = continuationGeneration ?? demoContinuationGeneration
        guard let targetFist = reference.sample(at: referenceTime)?.fist else { return }
        let goal = HoldGoal(targetFist: targetFist, tolerance: followPositionTolerance)
        var activeClock = AuraGuidanceActiveClock()

        while activeClock.activeElapsed < followHoldTimeout {
            guard !Task.isCancelled,
                  continuationGeneration == demoContinuationGeneration else { return }

            let now = clock.now
            if coachingCycle.isTrainingPaused {
                _ = activeClock.observe(at: now, availability: .guardUnavailable)
                await clock.sleep(for: frameInterval)
                continue
            }
            let availability = guidanceAvailability(punchingSide: side, solver: solver)
            if availability == .trackingUnavailable {
                _ = activeClock.observe(at: now, availability: .trackingUnavailable)
                guard await recoverGuidanceTracking(solver: solver) else { return }
                continue
            }
            if availability == .guardUnavailable {
                _ = activeClock.observe(at: now, availability: .guardUnavailable)
                if statusMessage != GuardCoach.waitMessage {
                    playCoachCue(.guardUp, caption: GuardCoach.waitMessage)
                }
                statusMessage = GuardCoach.waitMessage
                poseGhost(reference: reference, side: side, solver: solver, at: referenceTime)
                await clock.sleep(for: frameInterval)
                continue
            }

            _ = activeClock.observe(at: now, availability: .ready)

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

            await clock.sleep(for: frameInterval)
        }
    }

    private func recoverGuidanceTracking(solver: ArmPoseSolver) async -> Bool {
        coachingCycle.trackingDidPause()
        for recorder in recorders.values { recorder.cancel() }
        setCoaching(
            headline: "TRACKING PAUSED",
            detail: "Hold both closed fists in your fitted guard to restart this step",
            status: "Tracking paused · guidance frozen"
        )
        return await waitForTrackingRecovery(solver: solver)
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
            await clock.sleep(for: .seconds(1))
        }
    }

    private func runEvidenceRound(solver: ArmPoseSolver) async -> Bool {
        phase = .attempting
        applyCyclePresentation()
        audioCoordinator.handleImmediately(.roundDidStart)
        currentScoredPunch = 0
        playCoachCue(.hitTarget, caption: "Hit each target.")

        while coachingCycle.stage == .baseline || coachingCycle.stage == .retest {
            guard !Task.isCancelled else { return false }
            if coachingCycle.isTrainingPaused {
                guard await waitForTrainingResume() else { return false }
                continue
            }

            let punchIndex = coachingCycle.activeAttemptCount + 1
            currentScoredPunch = punchIndex
            applyCyclePresentation()

            // `punchIndex` advances only after semantic admission, so a technical retry preserves
            // this exact physical side and evidence chain instead of alternating mid-punch.
            let expectedSide = AuraPunchSideSequence.side(
                forRepetition: punchIndex,
                technique: technique,
                stance: stance
            )
            let reference = fittedReference(side: expectedSide)

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
                await clock.sleep(for: .milliseconds(220))
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
            coachingCycle.beginPartialAttempt()

            let capture = await capturePunchUntilHit(
                solver: solver,
                side: expectedSide,
                punchTechnique: technique
            )

            guard let capture else {
                coachingCycle.rejectPartialAttempt(.invalidEvidence)
                targets.removeActiveTarget()
                guard !Task.isCancelled else { return false }
                if coachingCycle.isTrainingPaused {
                    guard await waitForTrainingResume() else { return false }
                    continue
                }
                if statusMessage.hasPrefix("Tracking") {
                    coachingCycle.trackingDidPause()
                    setCoaching(
                        headline: "TRACKING PAUSED",
                        detail: "Hold both closed fists in guard to retry this rep",
                        status: "Tracking paused · no attempt recorded"
                    )
                    guard await waitForTrackingRecovery(solver: solver) else { return false }
                }
                await clock.sleep(for: .seconds(interScoredPunchDelay))
                continue
            }

            let punchReference = fittedReference(side: capture.side)
            guard let computed = scorer.score(
                attempt: capture.attempt,
                reference: punchReference,
                technique: technique,
                thrownSide: capture.side,
                stance: stance
            ) else {
                AuraScoringAdmissionPolicy.scorerRejectedAttempt(cycle: &coachingCycle)
                statusMessage = "Punch evidence was invalid · reset in guard"
                targets.removeActiveTarget()
                await clock.sleep(for: .milliseconds(220))
                continue
            }
            let metricQuality = Dictionary(uniqueKeysWithValues: computed.metrics.map { metric in
                (metric.kind, metric.quality ?? (metric.kind == .elbow ? .inferred : .measured))
            })
            do {
                let immutable = try TechniqueAttemptEvidence(
                    punch: capture.punch,
                    score: computed,
                    metricQuality: metricQuality
                )
                let admitted = try CoachingAttemptEvidence(
                    evidence: immutable,
                    actualSamples: capture.attempt.samples,
                    referenceSamples: capture.attempt.endsNearExtension()
                        ? punchReference.outboundSamples
                        : punchReference.samples
                )
                try coachingCycle.admit(admitted)
            } catch {
                coachingCycle.rejectPartialAttempt(.invalidEvidence)
                statusMessage = "Punch evidence was invalid · reset in guard"
                targets.removeActiveTarget()
                await clock.sleep(for: .milliseconds(220))
                continue
            }

            await clock.sleep(for: .milliseconds(220))
            targets.removeActiveTarget()

            if coachingCycle.stage == .baseline || coachingCycle.stage == .retest {
                await clock.sleep(for: .seconds(interScoredPunchDelay))
            }
        }

        currentScoredPunch = 0
        mirrorArm?.isVisible = false
        return coachingCycle.stage == .correction || coachingCycle.stage == .proof
    }

    private func presentCorrection(solver: ArmPoseSolver) async {
        phase = .guiding
        guard let correction = coachingCycle.correction else { return }

        if let baseline = TechniqueScore.averaging(
            coachingCycle.baselineAttempts.map(\.evidence.score),
            techniqueID: technique.id
        ) {
            score = baseline
            feedback = feedbackGenerator.localFeedback(
                for: baseline,
                technique: technique,
                stance: stance,
                previousFocus: previousCorrectionFocus,
                audienceTrack: track == .firstRound ? .beginner : .athlete
            )
            previousCorrectionFocus = correction.focus
        }

        applyCyclePresentation()
        if let overlay = coachingCycle.correctionOverlay,
           let frame = currentBodyFrame(solver: solver) {
            pathOverlay.show(
                actual: overlay.actualSamples.map {
                    CorrectionPathSample(
                        position: solver.denormalize(
                            $0.position,
                            side: overlay.side,
                            frame: frame
                        ),
                        provenance: $0.provenance
                    )
                },
                reference: overlay.referenceSamples.map {
                    CorrectionPathSample(
                        position: solver.denormalize(
                            $0.position,
                            side: overlay.side,
                            frame: frame
                        ),
                        provenance: $0.provenance
                    )
                }
            )
            coachingDetail = "\(correction.localCue) · \(overlay.actualLabel) in coral · \(overlay.referenceLabel) in cyan · \(Int((overlay.trackedFraction * 100).rounded()))% tracked · \(correction.evidenceLabel.rawValue) · \(overlay.sourceBadge)"
        }
        await pauseAwareDelay(seconds: 2.5)
    }

    private func runCorrectiveDrill(solver: ArmPoseSolver) async {
        phase = .guiding
        pathOverlay.hide()
        applyCyclePresentation()
        guard let drill = coachingCycle.correction?.drill else { return }
        let plan = CorrectiveDrillPlan(drill: drill)
        setCoaching(
            headline: plan.headline,
            detail: plan.instruction,
            status: "Corrective drill · \(plan.instruction)"
        )

        let side = AuraPunchSideSequence.side(
            forRepetition: 1,
            technique: technique,
            stance: stance
        )
        let reference = fittedReference(side: side)
        let speed = 1 / max(Double(track.demonstrationRate), 0.01)

        for step in plan.steps {
            guard !Task.isCancelled else { return }
            switch step {
            case .trackingRecovery:
                coachingCycle.trackingDidPause()
                guard await waitForTrackingRecovery(solver: solver) else { return }
            case .correctHandGuard, .guardAnchorHold, .guardHold:
                await holdGhost(
                    reference: reference,
                    side: side,
                    solver: solver,
                    at: reference.duration,
                    phaseMessage: statusMessage
                )
            case .elbowCheckpoint:
                await holdGhost(
                    reference: reference,
                    side: side,
                    solver: solver,
                    at: reference.peakTime * 0.55,
                    phaseMessage: statusMessage
                )
            case .outbound, .pathCheckpoint:
                spawnLandingTarget(reference: reference, side: side, solver: solver)
                await playGhost(
                    reference: reference,
                    side: side,
                    solver: solver,
                    from: 0,
                    to: reference.peakTime,
                    speedFactor: speed,
                    phaseMessage: statusMessage,
                    trackLandingTarget: true
                )
            case .landingHold:
                spawnLandingTarget(reference: reference, side: side, solver: solver)
                await holdGhost(
                    reference: reference,
                    side: side,
                    solver: solver,
                    at: reference.peakTime,
                    phaseMessage: statusMessage,
                    trackLandingTarget: true
                )
            case .returnToGuard:
                targets.removeActiveTarget()
                await playGhost(
                    reference: reference,
                    side: side,
                    solver: solver,
                    from: reference.peakTime,
                    to: reference.duration,
                    speedFactor: speed,
                    phaseMessage: statusMessage
                )
            case .fullShape:
                spawnLandingTarget(reference: reference, side: side, solver: solver)
                await playGhost(
                    reference: reference,
                    side: side,
                    solver: solver,
                    from: 0,
                    to: reference.duration,
                    speedFactor: speed,
                    phaseMessage: statusMessage,
                    trackLandingTarget: true
                )
                targets.removeActiveTarget()
                await holdGhost(
                    reference: reference,
                    side: side,
                    solver: solver,
                    at: reference.duration,
                    phaseMessage: statusMessage
                )
            }
        }
        targets.removeActiveTarget()
        demoArm?.isVisible = false
    }

    private func presentProof() async {
        phase = .scoring
        if let retest = TechniqueScore.averaging(
            coachingCycle.retestAttempts.map(\.evidence.score),
            techniqueID: technique.id
        ) {
            score = retest
        }
        applyCyclePresentation()
        if let proof = coachingCycle.proofMetric {
            let direction: String
            switch coachingCycle.proofDisposition {
            case .improved:
                direction = "improved"
            case .reinforced:
                direction = "held at its strong baseline"
            case .retry:
                direction = "did not improve enough yet"
            }
            coachingDetail = "\(proof.kind.title) \(Int(proof.baseline.rounded())) to \(Int(proof.retest.rounded())) · \(direction) · \(proof.sourceBadge)"
            statusMessage = coachingDetail
        }
        await pauseAwareDelay(seconds: 2.5)
    }

    /// Transfers the frozen proof into the existing stance-aware 1–2 semantic contract. The same
    /// punch validator enforces correct physical hand, fresh outbound motion, contact, and return.
    private func runOneTwoTransfer(solver: ArmPoseSolver) async -> Bool {
        phase = .attempting
        pathOverlay.hide()
        applyCyclePresentation()

        guard let reach = coachingCycle.fittedReach?.conservative else {
            fail("Transfer needs the fitted bilateral reach.")
            return false
        }
        let authored = Combination.oneTwo.targets(forwardBase: reach, stance: stance)
        let minimumSeparation = max(
            max(CombinationPunchValidator.guardRadius, CombinationPunchValidator.minimumOutwardTravel),
            targetHitRadius
        ) + 0.02
        guard let resolved = CombinationTargetResolver.resolve(
            authored,
            guardPositions: guardPositionsBody,
            minimumSeparation: minimumSeparation,
            maximumForward: reach * 1.05
        ) else {
            fail("Your fitted reach leaves too little space beyond guard for the 1–2 transfer.")
            return false
        }

        for target in resolved {
            if coachingCycle.isTrainingPaused {
                guard await waitForTrainingResume() else { return false }
            }
            setCoaching(
                headline: "TRANSFER · SET GUARD",
                detail: "Hold both closed fists in your fitted guard before the next 1–2 step",
                status: "Transfer · fresh fitted guard required"
            )
            guard await waitForFittedGuard(solver: solver) else { return false }
            applyCyclePresentation()
            while !Task.isCancelled {
                if coachingCycle.isTrainingPaused {
                    guard await waitForTrainingResume() else { return false }
                    continue
                }
                guard let frame = currentBodyFrame(solver: solver) else {
                    coachingCycle.trackingDidPause()
                    setCoaching(
                        headline: "TRACKING PAUSED",
                        detail: "Hold both fists in guard to resume the 1–2",
                        status: "Tracking paused · transfer held"
                    )
                    guard await waitForTrackingRecovery(solver: solver) else { return false }
                    continue
                }

                let worldTarget = frame.toWorld(target.position)
                targets.spawnTarget(at: worldTarget, radius: targetVisualRadius)
                let transferTechnique: Technique = target.punch == .jab ? .jab : .cross
                let capture = await capturePunchUntilHit(
                    solver: solver,
                    side: target.requiredHand,
                    punchTechnique: transferTechnique
                )
                targets.removeActiveTarget()
                guard capture != nil else {
                    if statusMessage.hasPrefix("Tracking") {
                        coachingCycle.trackingDidPause()
                        guard await waitForTrackingRecovery(solver: solver) else { return false }
                    }
                    continue
                }
                break
            }
        }

        return !Task.isCancelled
    }

    private func waitForFittedGuard(solver: ArmPoseSolver) async -> Bool {
        var gate = AuraGuardRecoveryGate()

        while !Task.isCancelled {
            if coachingCycle.isTrainingPaused {
                await clock.sleep(for: .milliseconds(25))
                continue
            }
            if gate.observe(guardRecoverySample(solver: solver, requiresFittedGuard: true)) {
                return true
            }
            await clock.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func waitForTrackingRecovery(solver: ArmPoseSolver) async -> Bool {
        var gate = AuraGuardRecoveryGate()

        while !Task.isCancelled {
            if gate.observe(guardRecoverySample(
                solver: solver,
                requiresFittedGuard: !guardPositionsBody.isEmpty
            )) {
                coachingCycle.trackingDidResume()
                applyCyclePresentation()
                return true
            }
            await clock.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func guardRecoverySample(
        solver: ArmPoseSolver,
        requiresFittedGuard: Bool
    ) -> AuraGuardRecoveryGate.Sample {
        guard let frame = currentBodyFrame(solver: solver),
              let left = hands.freshObservation(for: .left),
              let right = hands.freshObservation(for: .right)
        else {
            return .init(
                providerGeneration: hands.providerGeneration,
                continuityEpoch: hands.continuityEpoch,
                pairTimestamp: nil,
                observationsFresh: false,
                freshClosedAndGuarded: false
            )
        }

        let guarded: Bool
        if requiresFittedGuard,
           let leftGuard = guardPositionsBody[.left],
           let rightGuard = guardPositionsBody[.right] {
            guarded = CombinationPunchValidator.isRetracted(
                fist: frame.toBody(left.fistPosition),
                guardPosition: leftGuard,
                radius: CombinationPunchValidator.guardRadius
            ) && CombinationPunchValidator.isRetracted(
                fist: frame.toBody(right.fistPosition),
                guardPosition: rightGuard,
                radius: CombinationPunchValidator.guardRadius
            )
        } else {
            guarded = simd_distance(left.fistPosition, frame.headPosition) <= 0.45
                && simd_distance(right.fistPosition, frame.headPosition) <= 0.45
        }

        return .init(
            providerGeneration: hands.providerGeneration,
            continuityEpoch: hands.continuityEpoch,
            pairTimestamp: min(left.acquisitionTimestamp, right.acquisitionTimestamp),
            observationsFresh: true,
            freshClosedAndGuarded: left.fistState == .closed
                && right.fistState == .closed
                && guarded
        )
    }

    private func recoverAfterVoiceCapture() async {
        defer { voiceRecoveryTask = nil }
        let solver = ArmPoseSolver(measurements: measurements)
        setCoaching(
            headline: "RETURN TO GUARD",
            detail: "Hold both closed fists in your fitted guard to resume",
            status: "Ask Coach complete · waiting for fresh guard"
        )

        guard await waitForTrackingRecovery(solver: solver), !Task.isCancelled else { return }

        for count in [3, 2, 1] {
            guard !Task.isCancelled else { return }
            setCoaching(
                headline: "RESUMING",
                detail: "Fresh guard confirmed · \(count)",
                status: "Training resumes in \(count)"
            )
            await clock.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled else { return }
        guard let recoveringVoiceCaptureID else { return }
        handleCoachVoiceCycle(.freshGuardRecovered(recoveringVoiceCaptureID))
    }

    private func waitForTrainingResume() async -> Bool {
        while coachingCycle.isTrainingPaused, !Task.isCancelled {
            await clock.sleep(for: .milliseconds(25))
        }
        return !Task.isCancelled
    }

    private func pauseAwareDelay(seconds: TimeInterval) async {
        var activeElapsed: TimeInterval = 0
        var previous = clock.now
        while activeElapsed < seconds, !Task.isCancelled {
            let now = clock.now
            if !coachingCycle.isTrainingPaused {
                activeElapsed += max(0, now - previous)
            }
            previous = now
            await clock.sleep(for: .milliseconds(25))
        }
    }

    /// Records one fixed physical hand through validated outbound contact and return to guard.
    private func capturePunchUntilHit(
        solver: ArmPoseSolver,
        side: BodySide,
        punchTechnique: Technique
    ) async -> AuraCapturedPunch? {
        let throwMessage = statusMessage

        cachedBodyFrame = nil
        cachedBodyFrameTime = 0

        let startTime = clock.now
        guard let targetPosition = targets.activeTargetPosition else {
            statusMessage = "Punch evidence was invalid · reset in guard"
            return nil
        }
        guard !coachingCycle.isTrainingPaused,
              let guardFrame = currentBodyFrame(solver: solver),
              let calibratedBodyGuard = guardPositionsBody[side],
              let guardObservation = hands.freshObservation(for: side)
        else {
            statusMessage = "Tracking changed · punch discarded"
            return nil
        }
        let transferGuard = AuraTransferGuardContract(
            calibratedBodyGuard: calibratedBodyGuard,
            frame: guardFrame
        )
        guard transferGuard.isFreshGuard(
            fistWorld: guardObservation.fistPosition,
            fistState: guardObservation.fistState
        ) else {
            let reason = guardObservation.fistState == .closed
                ? "Return the \(side.rawValue) fist to your fitted guard"
                : PunchEvidenceFeedback.message(
                    for: .fistNotClosed(side: side, state: guardObservation.fistState)
                )
            rejectCurrentPunch(reason, at: targetPosition)
            return nil
        }

        let captureChain = PunchEvidenceCaptureChain(
            generation: hands.providerGeneration,
            continuityEpoch: hands.continuityEpoch
        )
        if let captureOverride {
            let reference = ReferencePunchLibrary.punch(
                for: punchTechnique,
                stance: stance,
                measurements: measurements,
                side: side,
                conservativeReach: coachingCycle.fittedReach?.conservative
                    ?? persistedReach?.conservative
            )
            let request = AuraPunchCaptureRequest(
                technique: punchTechnique,
                stance: stance,
                side: side,
                reference: reference,
                providerGeneration: captureChain.generation,
                continuityEpoch: captureChain.continuityEpoch
            )
            guard let captured = await captureOverride(request),
                  captured.side == side,
                  captured.punch.technique == punchTechnique,
                  captured.punch.stance == stance,
                  captured.punch.side == side,
                  captured.punch.generation == captureChain.generation,
                  captured.attempt.isUsable
            else {
                statusMessage = "Punch evidence was invalid · reset in guard"
                return nil
            }
            return captured
        }
        var validator = PunchEvidenceValidator(
            configuration: .init(
                technique: punchTechnique,
                stance: stance,
                requiredHand: side,
                guardPosition: transferGuard.worldGuard,
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

        let armingDeadline = clock.now + scoredPunchSafetyTimeout
        var evidenceCursor = PunchEvidenceFrameCursor()

        while clock.now < armingDeadline {
            if Task.isCancelled { break }
            if coachingCycle.isTrainingPaused {
                for recorder in recorders.values { recorder.cancel() }
                mirrorArm?.isVisible = false
                return nil
            }
            if trackingContinuity.observe(hands.continuityEpoch) {
                for recorder in recorders.values { recorder.cancel() }
                mirrorArm?.isVisible = false
                statusMessage = "Tracking changed · punch discarded"
                audioCoordinator.handleImmediately(.trackingDidPause(.staleSamples))
                return nil
            }

            let now = clock.now
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
                    case let .admit(punch):
                        // Satisfying feedback is downstream of semantic admission only.
                        targets.flash(result: .hit)
                        audioCoordinator.handleImmediately(.validatedImpact(
                            position: targetPosition,
                            quality: .clean
                        ))
                        mirrorArm?.isVisible = false
                        return AuraCapturedPunch(side: side, attempt: attempt, punch: punch)
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

            await clock.sleep(for: frameInterval)
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
            audioCoordinator.handleImmediately(.unrankedResultDidFinalize)
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

    private func fittedReference(side: BodySide) -> ReferencePunch {
        ReferencePunchLibrary.punch(
            for: technique,
            stance: stance,
            measurements: measurements,
            side: side,
            conservativeReach: coachingCycle.fittedReach?.conservative ?? persistedReach?.conservative
        )
    }

    private func applyCyclePresentation() {
        let presentation = coachingCycle.presentation
        if coachingCycle.stage != .complete {
            audioCoordinator.handleImmediately(
                .experienceDidEnter(coachingCycle.stage.trainingAudioStage)
            )
        }
        setCoaching(
            headline: presentation.stage,
            detail: presentation.instruction,
            status: [presentation.progress, presentation.instruction]
                .compactMap { $0 }
                .joined(separator: " · ")
        )
    }

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

    private func guidanceAvailability(
        punchingSide: BodySide,
        solver: ArmPoseSolver
    ) -> AuraGuidanceAvailability {
        guard let frame = currentBodyFrame(solver: solver) else {
            return AuraGuidanceTrackingPolicy.availability(
                bodyFrameAvailable: false,
                punchingHandAvailable: false,
                guardHandAvailable: false,
                nonPunchingGuardUp: nil
            )
        }
        let guardSide = punchingSide.opposite
        let punchingHand = hands.freshObservation(for: punchingSide)
        let guardHand = hands.freshObservation(for: guardSide)
        let guardUp = guardHand.flatMap { observation in
            GuardCoach.isGuardUp(
                guardFistWorld: observation.fistPosition,
                frame: frame,
                measurements: measurements,
                guardSide: guardSide
            )
        }
        return AuraGuidanceTrackingPolicy.availability(
            bodyFrameAvailable: true,
            punchingHandAvailable: punchingHand != nil,
            guardHandAvailable: guardHand != nil,
            nonPunchingGuardUp: guardUp
        )
    }

    /// `true` = guard up, `false` = dropped, `nil` = guard hand not visible.
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

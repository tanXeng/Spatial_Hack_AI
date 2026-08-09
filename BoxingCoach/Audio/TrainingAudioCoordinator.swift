import Foundation
import Observation
import os

@MainActor
protocol TrainingAudioResourceResolving {
    func url(for resource: TrainingAudioResourceID) -> URL?
}

@MainActor
protocol TrainingAudioBackend: AnyObject {
    var playbackDidFinish: ((TrainingAudioPlaybackHandle) -> Void)? { get set }
    var systemEventHandler: ((TrainingAudioSystemEvent) -> Void)? { get set }

    func attachScene() throws
    func detachScene()
    func apply(mix: TrainingAudioMix, fadeDuration: Duration)
    func play(_ request: TrainingAudioPlaybackRequest) -> TrainingAudioPlaybackHandle?
    func stop(_ handle: TrainingAudioPlaybackHandle)
    func stop(channels: Set<TrainingAudioChannel>)
    func stopAll()
    func beginVoiceCapture() throws
    func endVoiceCapture()
    func recoverPlaybackSession() throws
    func mediaServicesWereReset() throws
}

@MainActor
protocol TrainingAudioDecayWaiting {
    func wait(for duration: Duration) async throws
}

@MainActor
final class SystemTrainingAudioDecayWaiter: TrainingAudioDecayWaiting {
    func wait(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Owns semantic audio policy, focus, captions, mixes, and every live playback handle.
/// Rendering is delegated to a deliberately narrow backend so policy remains deterministic.
@Observable
@MainActor
final class TrainingAudioCoordinator {
    private static let logger = Logger(
        subsystem: "com.josephkwokpersonalteam.BoxingCoach",
        category: "TrainingAudio"
    )
    private static let captureChannels: Set<TrainingAudioChannel> = [.coach, .impact, .status]
    private static let maximumImpactVoices = 4

    private struct ActivePlayback {
        let handle: TrainingAudioPlaybackHandle
        let resource: TrainingAudioResourceID
        let generation: UInt64
        let priority: TrainingCoachCueKind?
    }

    private struct CapturePreparation {
        let id: UInt64
        let generation: UInt64
        let origin: TrainingAudioSceneOwner
        var duplicateWaiters: [CheckedContinuation<TrainingAudioEventOutcome, Never>] = []
    }

    private struct PendingVoiceResponse {
        let cue: TrainingCoachCue
        let generation: UInt64
    }

    private(set) var presentation: TrainingAudioPresentationState = .detached
    private(set) var generation: UInt64 = 0

    var activeImpactVoiceCount: Int { impactVoices.count }

    private let backend: any TrainingAudioBackend
    private let resources: any TrainingAudioResourceResolving
    private let decayWaiter: any TrainingAudioDecayWaiting
    private let fadeDuration: Duration
    private let captureDecay: Duration

    private var attachedScenes: Set<TrainingAudioSceneOwner> = []
    private var backendReady = false
    private var trackingPaused = false
    private var foreground: ActivePlayback?
    private var ambience: ActivePlayback?
    private var crowd: ActivePlayback?
    private var status: ActivePlayback?
    private var impactVoices: [ActivePlayback] = []
    private var pendingVoiceResponse: PendingVoiceResponse?
    private var nextImpactVariant = 0
    private var nextCapturePreparationID: UInt64 = 0
    private var capturePreparation: CapturePreparation?
    private var activeCaptureOrigin: TrainingAudioSceneOwner?
    private var captureRevocationHandler: (@MainActor () -> Void)?

    private var sceneAttached: Bool { !attachedScenes.isEmpty }

    private var highestActivePriority: TrainingCoachCueKind? {
        [foreground?.priority, status?.priority].compactMap { $0 }.max()
    }

    convenience init() {
        self.init(
            backend: CoachAudioPlayer(),
            resources: CoachClipLibrary(),
            decayWaiter: SystemTrainingAudioDecayWaiter()
        )
    }

    init(
        backend: any TrainingAudioBackend,
        resources: any TrainingAudioResourceResolving,
        decayWaiter: any TrainingAudioDecayWaiting,
        fadeDuration: Duration = .milliseconds(200),
        captureDecay: Duration = .milliseconds(200)
    ) {
        self.backend = backend
        self.resources = resources
        self.decayWaiter = decayWaiter
        self.fadeDuration = Self.comfortFade(fadeDuration)
        self.captureDecay = Self.comfortFade(captureDecay)

        backend.playbackDidFinish = { [weak self] handle in
            self?.playbackFinished(handle)
        }
        backend.systemEventHandler = { [weak self] event in
            _ = self?.handleSystemEvent(event)
        }
    }

    func setCaptureRevocationHandler(_ handler: @escaping @MainActor () -> Void) {
        captureRevocationHandler = handler
    }

    @discardableResult
    func handle(_ event: TrainingAudioEvent) async -> TrainingAudioEventOutcome {
        if case let .voiceCaptureDidBegin(origin) = event {
            return await beginVoiceCapture(origin: origin)
        }
        return handleImmediately(event)
    }

    /// Handles semantic events that cannot suspend. Session engines use this path so cue ordering
    /// remains deterministic without spawning unstructured tasks.
    @discardableResult
    func handleImmediately(_ event: TrainingAudioEvent) -> TrainingAudioEventOutcome {
        switch event {
        case let .sceneDidAttach(owner):
            return attachScene(owner)
        case let .experienceDidEnter(stage):
            return enter(stage)
        case let .targetDidAppear(position):
            return targetAppeared(at: position)
        case let .validatedImpact(position, quality):
            return playValidatedImpact(at: position, quality: quality)
        case let .coachCue(cue):
            return playCoachCue(cue)
        case let .trackingDidPause(reason):
            return pauseForTracking(reason)
        case .trackingDidResume:
            return resumeAfterTracking()
        case .voiceCaptureDidBegin:
            assertionFailure("voiceCaptureDidBegin must use the async handle(_:)")
            return .staleGeneration
        case .voiceCaptureDidEnd:
            return endVoiceCapture()
        case let .audioSystemEvent(systemEvent):
            return handleSystemEvent(systemEvent)
        case .audioRecoveryConfirmed:
            return recoverAfterExplicitConfirmation()
        case .trainingWillBegin:
            return prepareForTrainingStart()
        case let .trainingDidStop(preservingVoiceCapture):
            return stopTrainingAudio(preservingVoiceCapture: preservingVoiceCapture)
        case let .sceneDidDetach(owner):
            return detachScene(owner)
        }
    }

    private func attachScene(_ owner: TrainingAudioSceneOwner) -> TrainingAudioEventOutcome {
        guard attachedScenes.insert(owner).inserted else { return .handled }
        guard attachedScenes.count == 1 else { return .handled }

        generation &+= 1
        trackingPaused = false
        presentation.status = .ready
        presentation.caption = "Training audio ready."
        presentation.requiresExplicitRecovery = false
        presentation.isCapturing = false
        applyCurrentMix()

        do {
            try backend.attachScene()
            backendReady = true
            applyCurrentMix()
            startEnvironmentBedsIfNeeded()
            return .handled
        } catch {
            backendReady = false
            presentation.status = .unavailable
            presentation.caption = "Audio is unavailable. Visual coaching remains active."
            Self.logger.error("Audio scene attachment failed: \(error.localizedDescription, privacy: .public)")
            return .backendUnavailable
        }
    }

    private func enter(_ stage: TrainingAudioStage) -> TrainingAudioEventOutcome {
        presentation.stage = stage
        guard !trackingPaused,
              !presentation.requiresExplicitRecovery,
              capturePreparation == nil,
              !presentation.isCapturing else {
            return .handled
        }
        if highestActivePriority == nil {
            presentation.caption = stage.caption
        }
        guard sceneAttached else { return .ignoredWhileDetached }
        guard backendReady else { return .backendUnavailable }

        applyCurrentMix()
        startEnvironmentBedsIfNeeded()
        return .handled
    }

    private func targetAppeared(at position: SIMD3<Float>) -> TrainingAudioEventOutcome {
        presentation.targetPosition = position
        guard !trackingPaused,
              !presentation.requiresExplicitRecovery,
              capturePreparation == nil,
              !presentation.isCapturing,
              highestActivePriority == nil else {
            return sceneAttached ? .handled : .ignoredWhileDetached
        }
        presentation.caption = "Target ready."
        return sceneAttached ? .handled : .ignoredWhileDetached
    }

    private func playValidatedImpact(
        at position: SIMD3<Float>,
        quality: TrainingImpactQuality
    ) -> TrainingAudioEventOutcome {
        guard !trackingPaused,
              capturePreparation == nil,
              !presentation.isCapturing,
              !presentation.requiresExplicitRecovery else {
            return .handled
        }
        if highestActivePriority == nil {
            presentation.caption = quality.caption
        }
        guard sceneAttached else { return .ignoredWhileDetached }
        guard backendReady else { return .backendUnavailable }

        let resource = impactResourceForNextVoice()
        guard let url = resources.url(for: resource) else {
            Self.logger.notice("Impact resource unavailable: \(resource.fileName, privacy: .public)")
            return .missingResource(resource)
        }

        if impactVoices.count >= Self.maximumImpactVoices {
            let oldest = impactVoices.removeFirst()
            backend.stop(oldest.handle)
        }

        let request = TrainingAudioPlaybackRequest(
            resource: resource,
            url: url,
            channel: .impact,
            loops: false,
            position: position,
            generation: generation
        )
        guard let handle = backend.play(request) else { return .backendUnavailable }
        impactVoices.append(ActivePlayback(
            handle: handle,
            resource: resource,
            generation: generation,
            priority: nil
        ))
        return .handled
    }

    private func playCoachCue(_ cue: TrainingCoachCue) -> TrainingAudioEventOutcome {
        if (trackingPaused || presentation.requiresExplicitRecovery), cue.kind != .safety {
            return .suppressed(by: .safety)
        }

        if cue.kind == .safety {
            pendingVoiceResponse = nil
            presentation.caption = cue.caption
            captureRevocationHandler?()
        }

        if cue.kind == .safety,
           capturePreparation != nil || presentation.isCapturing {
            let captureOutcome = preemptVoiceCaptureForSafety()
            guard captureOutcome == .handled else { return captureOutcome }
        }

        if let activePriority = highestActivePriority, cue.kind < activePriority {
            return .suppressed(by: activePriority)
        }

        if cue.kind != .safety {
            presentation.caption = cue.caption
        }

        if capturePreparation != nil || presentation.isCapturing {
            guard cue.kind == .voiceResponse else {
                return .suppressed(by: .voiceResponse)
            }
            pendingVoiceResponse = PendingVoiceResponse(cue: cue, generation: generation)
            return .deferredUntilCaptureEnds
        }

        return startForegroundCue(cue)
    }

    private func preemptVoiceCaptureForSafety() -> TrainingAudioEventOutcome {
        let wasCapturing = presentation.isCapturing
        generation &+= 1
        invalidateCapturePreparation()
        pendingVoiceResponse = nil
        activeCaptureOrigin = nil
        presentation.isCapturing = false

        if wasCapturing {
            backend.endVoiceCapture()
            do {
                try backend.recoverPlaybackSession()
                backendReady = true
            } catch {
                backendReady = false
                presentation.status = .awaitingExplicitRecovery
                presentation.requiresExplicitRecovery = true
                Self.logger.error(
                    "Safety cue playback recovery failed: \(error.localizedDescription, privacy: .public)"
                )
                return .backendUnavailable
            }
        }

        presentation.status = trackingPaused
            ? .trackingPaused
            : (presentation.requiresExplicitRecovery ? .awaitingExplicitRecovery : .ready)
        applyCurrentMix()
        return .handled
    }

    private func startForegroundCue(_ cue: TrainingCoachCue) -> TrainingAudioEventOutcome {
        guard sceneAttached else { return .ignoredWhileDetached }
        guard backendReady else { return .backendUnavailable }

        if let current = foreground {
            backend.stop(current.handle)
            foreground = nil
            presentation.activePriority = nil
        }
        if let currentStatus = status,
           let statusPriority = currentStatus.priority,
           cue.kind >= statusPriority {
            backend.stop(currentStatus.handle)
            status = nil
        }

        let resource = TrainingAudioResourceID.coach(cue.clip)
        guard let url = resources.url(for: resource) else {
            applyCurrentMix()
            Self.logger.notice("Coach resource unavailable: \(resource.fileName, privacy: .public)")
            return .missingResource(resource)
        }

        let request = TrainingAudioPlaybackRequest(
            resource: resource,
            url: url,
            channel: .coach,
            loops: false,
            position: nil,
            generation: generation
        )
        guard let handle = backend.play(request) else { return .backendUnavailable }
        foreground = ActivePlayback(
            handle: handle,
            resource: resource,
            generation: generation,
            priority: cue.kind
        )
        presentation.activePriority = highestActivePriority
        applyCurrentMix()
        return .handled
    }

    private func pauseForTracking(_ reason: TrainingTrackingPauseReason) -> TrainingAudioEventOutcome {
        captureRevocationHandler?()
        guard sceneAttached else { return .ignoredWhileDetached }
        generation &+= 1
        invalidateCapturePreparation()
        trackingPaused = true
        pendingVoiceResponse = nil
        activeCaptureOrigin = nil
        presentation.status = .trackingPaused
        presentation.caption = "Tracking paused. Keep your space clear and bring both hands into view."
        presentation.isCapturing = false
        presentation.activePriority = nil

        backend.stop(channels: Self.captureChannels)
        backend.endVoiceCapture()
        clearPlaybackRecords(in: Self.captureChannels)
        applyCurrentMix()
        playStatusResource(.trackingLost, caption: presentation.caption)
        return .handled
    }

    private func resumeAfterTracking() -> TrainingAudioEventOutcome {
        guard sceneAttached else { return .ignoredWhileDetached }
        trackingPaused = false
        presentation.status = presentation.requiresExplicitRecovery ? .awaitingExplicitRecovery : .ready
        presentation.caption = "Tracking restored. Return both hands to guard."
        applyCurrentMix()
        if !presentation.requiresExplicitRecovery {
            playStatusResource(.trackingRestored, caption: presentation.caption)
        }
        return .handled
    }

    private func beginVoiceCapture(
        origin: TrainingAudioSceneOwner
    ) async -> TrainingAudioEventOutcome {
        guard attachedScenes.contains(origin) else { return .ignoredWhileDetached }
        guard backendReady else { return .backendUnavailable }
        guard !trackingPaused, !presentation.requiresExplicitRecovery else { return .handled }
        guard !presentation.isCapturing else { return .captureReady }
        if highestActivePriority == .safety {
            return .suppressed(by: .safety)
        }

        if capturePreparation != nil {
            return await waitForActiveCapturePreparation()
        }

        let captureGeneration = generation
        nextCapturePreparationID &+= 1
        let preparationID = nextCapturePreparationID
        capturePreparation = CapturePreparation(
            id: preparationID,
            generation: captureGeneration,
            origin: origin
        )
        pendingVoiceResponse = nil
        presentation.status = .capturePreparing
        presentation.caption = "Preparing microphone…"
        presentation.activePriority = nil
        backend.stop(channels: Self.captureChannels)
        clearPlaybackRecords(in: Self.captureChannels)
        applyCurrentMix(asVoiceCapture: true)

        do {
            try await decayWaiter.wait(for: captureDecay)
            guard !Task.isCancelled,
                  capturePreparation?.id == preparationID,
                  capturePreparation?.generation == captureGeneration,
                  generation == captureGeneration,
                  attachedScenes.contains(origin),
                  !trackingPaused,
                  !presentation.requiresExplicitRecovery else {
                cancelCapturePreparationIfCurrent(id: preparationID)
                return .staleGeneration
            }
            try backend.beginVoiceCapture()
            presentation.status = .capturing
            presentation.caption = "Listening…"
            presentation.isCapturing = true
            presentation.mix = .voiceCapture
            activeCaptureOrigin = origin
            completeCapturePreparation(id: preparationID, with: .captureReady)
            return .captureReady
        } catch is CancellationError {
            cancelCapturePreparationIfCurrent(id: preparationID)
            return .staleGeneration
        } catch {
            pendingVoiceResponse = nil
            activeCaptureOrigin = nil
            completeCapturePreparation(id: preparationID, with: .backendUnavailable)
            presentation.status = .unavailable
            presentation.caption = "Microphone audio is unavailable. Use the visible controls."
            applyCurrentMix()
            Self.logger.error("Voice capture focus failed: \(error.localizedDescription, privacy: .public)")
            return .backendUnavailable
        }
    }

    private func endVoiceCapture() -> TrainingAudioEventOutcome {
        guard sceneAttached else { return .ignoredWhileDetached }
        generation &+= 1
        if let pendingVoiceResponse {
            self.pendingVoiceResponse = PendingVoiceResponse(
                cue: pendingVoiceResponse.cue,
                generation: generation
            )
        }
        invalidateCapturePreparation()
        backend.endVoiceCapture()
        presentation.isCapturing = false
        activeCaptureOrigin = nil

        do {
            try backend.recoverPlaybackSession()
            backendReady = true
        } catch {
            backendReady = false
            presentation.status = .awaitingExplicitRecovery
            presentation.caption = "Audio recovery failed. Confirm recovery to hear the coach response."
            presentation.requiresExplicitRecovery = true
            return .backendUnavailable
        }

        presentation.status = presentation.requiresExplicitRecovery ? .awaitingExplicitRecovery : .ready
        applyCurrentMix()

        return playPendingVoiceResponseIfCurrentGeneration()
    }

    private func handleSystemEvent(_ event: TrainingAudioSystemEvent) -> TrainingAudioEventOutcome {
        switch event {
        case .interruptionBegan:
            enterExplicitRecovery(
                caption: "Audio interrupted. Training remains paused until you resume."
            )
        case .routeChanged:
            enterExplicitRecovery(
                caption: "Audio route changed. Check your surroundings, then resume."
            )
        case .mediaServicesWereReset:
            enterExplicitRecovery(
                caption: "Audio restarted. Training remains paused until you resume.",
                hardStopEnvironment: true
            )
            do {
                try backend.mediaServicesWereReset()
                backendReady = true
            } catch {
                backendReady = false
                presentation.status = .unavailable
                presentation.caption = "Audio is unavailable. Visual coaching remains active."
                return .backendUnavailable
            }
        case .interruptionEnded:
            guard sceneAttached else { return .ignoredWhileDetached }
            do {
                try backend.recoverPlaybackSession()
                backendReady = true
                presentation.caption = "Audio is ready. Resume when your guard is set."
            } catch {
                backendReady = false
                presentation.status = .unavailable
                presentation.caption = "Audio is unavailable. Visual coaching remains active."
                return .backendUnavailable
            }
        }
        return .handled
    }

    private func recoverAfterExplicitConfirmation() -> TrainingAudioEventOutcome {
        guard sceneAttached else { return .ignoredWhileDetached }
        do {
            try backend.recoverPlaybackSession()
            backendReady = true
        } catch {
            backendReady = false
            presentation.status = .unavailable
            presentation.caption = "Audio is unavailable. Visual coaching remains active."
            return .backendUnavailable
        }

        presentation.requiresExplicitRecovery = false
        presentation.status = trackingPaused ? .trackingPaused : .ready
        presentation.caption = trackingPaused
            ? "Tracking is still paused. Bring both hands into view."
            : "Audio restored. Return both hands to guard."
        applyCurrentMix()
        startEnvironmentBedsIfNeeded()
        return playPendingVoiceResponseIfCurrentGeneration()
    }

    private func detachScene(_ owner: TrainingAudioSceneOwner) -> TrainingAudioEventOutcome {
        guard attachedScenes.remove(owner) != nil else { return .handled }
        let captureBelongsToDepartingScene = capturePreparation?.origin == owner
            || activeCaptureOrigin == owner
        if !attachedScenes.isEmpty {
            guard captureBelongsToDepartingScene else { return .handled }
            return stopTrainingAudio(preservingVoiceCapture: false)
        }
        captureRevocationHandler?()
        generation &+= 1
        invalidateCapturePreparation()
        backendReady = false
        trackingPaused = false
        pendingVoiceResponse = nil
        activeCaptureOrigin = nil
        backend.endVoiceCapture()
        backend.stopAll()
        backend.detachScene()
        clearAllPlaybackRecords()
        presentation = .detached
        return .handled
    }

    private func prepareForTrainingStart() -> TrainingAudioEventOutcome {
        let coordinatorCaptureNeedsEnding = capturePreparation != nil || presentation.isCapturing
        let shouldRecoverDeferredVoiceResponse = presentation.requiresExplicitRecovery
            && pendingVoiceResponse != nil
        pendingVoiceResponse = nil
        captureRevocationHandler?()
        guard sceneAttached else { return .ignoredWhileDetached }

        var stoppedVoiceResponse = false
        if foreground?.priority == .voiceResponse, let foreground {
            backend.stop(foreground.handle)
            self.foreground = nil
            presentation.activePriority = highestActivePriority
            stoppedVoiceResponse = true
        }

        if coordinatorCaptureNeedsEnding {
            return endVoiceCapture()
        }
        if shouldRecoverDeferredVoiceResponse {
            return recoverAfterExplicitConfirmation()
        }
        if stoppedVoiceResponse {
            presentation.caption = presentation.stage.caption
            applyCurrentMix()
        }
        return .handled
    }

    private func stopTrainingAudio(
        preservingVoiceCapture: Bool
    ) -> TrainingAudioEventOutcome {
        let preservesWindowCapture = preservingVoiceCapture
            && attachedScenes.contains(.controlWindow)
            && (capturePreparation?.origin == .controlWindow
                || activeCaptureOrigin == .controlWindow)
        if preservesWindowCapture,
           capturePreparation != nil || presentation.isCapturing {
            return .handled
        }
        captureRevocationHandler?()
        guard sceneAttached else { return .ignoredWhileDetached }
        generation &+= 1
        let wasCapturing = presentation.isCapturing
        invalidateCapturePreparation()
        pendingVoiceResponse = nil
        activeCaptureOrigin = nil
        backend.stop(channels: Self.captureChannels)
        clearPlaybackRecords(in: Self.captureChannels)
        presentation.isCapturing = false

        if wasCapturing {
            backend.endVoiceCapture()
            do {
                try backend.recoverPlaybackSession()
                backendReady = true
            } catch {
                backendReady = false
                presentation.status = .awaitingExplicitRecovery
                presentation.caption = "Audio recovery failed. Confirm recovery before continuing."
                presentation.requiresExplicitRecovery = true
                return .backendUnavailable
            }
        }

        presentation.status = trackingPaused
            ? .trackingPaused
            : (presentation.requiresExplicitRecovery ? .awaitingExplicitRecovery : .ready)
        if !trackingPaused, !presentation.requiresExplicitRecovery {
            presentation.caption = "Training stopped."
        }
        applyCurrentMix()
        return .handled
    }

    private func enterExplicitRecovery(
        caption: String,
        hardStopEnvironment: Bool = false
    ) {
        captureRevocationHandler?()
        guard sceneAttached else { return }
        generation &+= 1
        invalidateCapturePreparation()
        pendingVoiceResponse = nil
        activeCaptureOrigin = nil
        backend.endVoiceCapture()
        if hardStopEnvironment {
            backend.stopAll()
            clearAllPlaybackRecords()
        } else {
            backend.stop(channels: Self.captureChannels)
            clearPlaybackRecords(in: Self.captureChannels)
        }
        presentation.status = .awaitingExplicitRecovery
        presentation.caption = caption
        presentation.isCapturing = false
        presentation.requiresExplicitRecovery = true
        presentation.activePriority = nil
        presentation.mix = .silent
        backend.apply(mix: .silent, fadeDuration: fadeDuration)
    }

    private func playStatusResource(_ resource: TrainingAudioResourceID, caption: String?) {
        if let current = status {
            backend.stop(current.handle)
            status = nil
        }
        presentation.caption = caption
        presentation.activePriority = highestActivePriority
        applyCurrentMix()

        guard backendReady, let url = resources.url(for: resource) else { return }
        let request = TrainingAudioPlaybackRequest(
            resource: resource,
            url: url,
            channel: .status,
            loops: false,
            position: nil,
            generation: generation
        )
        guard let handle = backend.play(request) else { return }
        status = ActivePlayback(
            handle: handle,
            resource: resource,
            generation: generation,
            priority: .safety
        )
        presentation.activePriority = highestActivePriority
        applyCurrentMix()
    }

    private func startEnvironmentBedsIfNeeded() {
        guard sceneAttached,
              backendReady,
              !trackingPaused,
              capturePreparation == nil,
              !presentation.isCapturing,
              !presentation.requiresExplicitRecovery else {
            return
        }

        if ambience == nil,
           let url = resources.url(for: .gymAmbience),
           let handle = backend.play(TrainingAudioPlaybackRequest(
               resource: .gymAmbience,
               url: url,
               channel: .ambience,
               loops: true,
               position: nil,
               generation: generation
           )) {
            ambience = ActivePlayback(
                handle: handle,
                resource: .gymAmbience,
                generation: generation,
                priority: nil
            )
        }

        switch TrainingAudioMix.stage(presentation.stage).crowd {
        case .muted:
            break
        case .decibels:
            if crowd == nil,
               let url = resources.url(for: .competitionCrowd),
               let handle = backend.play(TrainingAudioPlaybackRequest(
                   resource: .competitionCrowd,
                   url: url,
                   channel: .crowd,
                   loops: true,
                   position: nil,
                   generation: generation
               )) {
                crowd = ActivePlayback(
                    handle: handle,
                    resource: .competitionCrowd,
                    generation: generation,
                    priority: nil
                )
            }
        }
    }

    private func impactResourceForNextVoice() -> TrainingAudioResourceID {
        let variants = TrainingAudioResourceID.cleanImpactVariants
        let resource = variants[nextImpactVariant % variants.count]
        nextImpactVariant = (nextImpactVariant + 1) % variants.count
        return resource
    }

    private func applyCurrentMix(asVoiceCapture: Bool = false) {
        let mix: TrainingAudioMix
        if presentation.requiresExplicitRecovery {
            mix = .silent
        } else if asVoiceCapture || capturePreparation != nil || presentation.isCapturing {
            mix = .voiceCapture
        } else if trackingPaused {
            mix = .trackingPaused
        } else if let priority = highestActivePriority {
            mix = TrainingAudioMix.stage(presentation.stage).ducked(for: priority)
        } else {
            mix = TrainingAudioMix.stage(presentation.stage)
        }
        presentation.mix = mix
        guard sceneAttached, backendReady else { return }
        backend.apply(mix: mix, fadeDuration: fadeDuration)
    }

    private func playbackFinished(_ handle: TrainingAudioPlaybackHandle) {
        if foreground?.handle == handle {
            guard foreground?.generation == generation else { return }
            foreground = nil
            presentation.activePriority = highestActivePriority
            applyCurrentMix()
            return
        }
        if status?.handle == handle {
            status = nil
            presentation.activePriority = highestActivePriority
            applyCurrentMix()
            return
        }
        if ambience?.handle == handle {
            ambience = nil
            return
        }
        if crowd?.handle == handle {
            crowd = nil
            return
        }
        impactVoices.removeAll { $0.handle == handle }
    }

    private func clearPlaybackRecords(in channels: Set<TrainingAudioChannel>) {
        if channels.contains(.coach) {
            foreground = nil
        }
        if channels.contains(.impact) {
            impactVoices.removeAll()
        }
        if channels.contains(.status) {
            status = nil
        }
        if channels.contains(.ambience) {
            ambience = nil
        }
        if channels.contains(.crowd) {
            crowd = nil
        }
        presentation.activePriority = highestActivePriority
    }

    private func clearAllPlaybackRecords() {
        foreground = nil
        ambience = nil
        crowd = nil
        status = nil
        impactVoices.removeAll()
        presentation.activePriority = nil
    }

    private func waitForActiveCapturePreparation() async -> TrainingAudioEventOutcome {
        await withCheckedContinuation { continuation in
            guard var preparation = capturePreparation,
                  preparation.generation == generation else {
                continuation.resume(returning: .staleGeneration)
                return
            }
            preparation.duplicateWaiters.append(continuation)
            capturePreparation = preparation
        }
    }

    private func completeCapturePreparation(
        id: UInt64,
        with outcome: TrainingAudioEventOutcome
    ) {
        guard let preparation = capturePreparation,
              preparation.id == id else {
            return
        }
        capturePreparation = nil
        for waiter in preparation.duplicateWaiters {
            waiter.resume(returning: outcome)
        }
    }

    private func invalidateCapturePreparation() {
        guard let preparation = capturePreparation else { return }
        capturePreparation = nil
        for waiter in preparation.duplicateWaiters {
            waiter.resume(returning: .staleGeneration)
        }
    }

    private func cancelCapturePreparationIfCurrent(id: UInt64) {
        guard capturePreparation?.id == id else { return }
        completeCapturePreparation(id: id, with: .staleGeneration)
        presentation.status = trackingPaused
            ? .trackingPaused
            : (presentation.requiresExplicitRecovery ? .awaitingExplicitRecovery : .ready)
        presentation.isCapturing = false
        activeCaptureOrigin = nil
        applyCurrentMix()
    }

    private func playPendingVoiceResponseIfCurrentGeneration() -> TrainingAudioEventOutcome {
        guard let pendingVoiceResponse else { return .handled }
        guard pendingVoiceResponse.generation == generation else {
            self.pendingVoiceResponse = nil
            return .staleGeneration
        }
        self.pendingVoiceResponse = nil
        presentation.caption = pendingVoiceResponse.cue.caption
        return startForegroundCue(pendingVoiceResponse.cue)
    }

    private static func comfortFade(_ requested: Duration) -> Duration {
        min(max(requested, .milliseconds(150)), .milliseconds(300))
    }
}

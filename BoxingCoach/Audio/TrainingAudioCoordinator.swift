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

    private(set) var presentation: TrainingAudioPresentationState = .detached
    private(set) var generation: UInt64 = 0

    var activeImpactVoiceCount: Int { impactVoices.count }

    private let backend: any TrainingAudioBackend
    private let resources: any TrainingAudioResourceResolving
    private let decayWaiter: any TrainingAudioDecayWaiting
    private let fadeDuration: Duration
    private let captureDecay: Duration

    private var sceneAttached = false
    private var backendReady = false
    private var trackingPaused = false
    private var foreground: ActivePlayback?
    private var ambience: ActivePlayback?
    private var crowd: ActivePlayback?
    private var status: ActivePlayback?
    private var impactVoices: [ActivePlayback] = []
    private var pendingVoiceResponse: TrainingCoachCue?
    private var nextImpactVariant = 0

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

    @discardableResult
    func handle(_ event: TrainingAudioEvent) async -> TrainingAudioEventOutcome {
        switch event {
        case .sceneDidAttach:
            attachScene()
        case let .experienceDidEnter(stage):
            enter(stage)
        case let .targetDidAppear(position):
            targetAppeared(at: position)
        case let .validatedImpact(position, quality):
            playValidatedImpact(at: position, quality: quality)
        case let .coachCue(cue):
            playCoachCue(cue)
        case let .trackingDidPause(reason):
            pauseForTracking(reason)
        case .trackingDidResume:
            resumeAfterTracking()
        case .voiceCaptureDidBegin:
            await beginVoiceCapture()
        case .voiceCaptureDidEnd:
            endVoiceCapture()
        case let .audioSystemEvent(systemEvent):
            handleSystemEvent(systemEvent)
        case .audioRecoveryConfirmed:
            recoverAfterExplicitConfirmation()
        case .sceneDidDetach:
            detachScene()
        }
    }

    private func attachScene() -> TrainingAudioEventOutcome {
        guard !sceneAttached else { return .handled }

        generation &+= 1
        sceneAttached = true
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
        presentation.caption = stage.caption
        guard sceneAttached else { return .ignoredWhileDetached }
        guard backendReady else { return .backendUnavailable }

        applyCurrentMix()
        startEnvironmentBedsIfNeeded()
        return .handled
    }

    private func targetAppeared(at position: SIMD3<Float>) -> TrainingAudioEventOutcome {
        presentation.targetPosition = position
        presentation.caption = "Target ready."
        return sceneAttached ? .handled : .ignoredWhileDetached
    }

    private func playValidatedImpact(
        at position: SIMD3<Float>,
        quality: TrainingImpactQuality
    ) -> TrainingAudioEventOutcome {
        presentation.caption = quality.caption
        guard sceneAttached else { return .ignoredWhileDetached }
        guard backendReady else { return .backendUnavailable }
        guard !trackingPaused,
              !presentation.isCapturing,
              !presentation.requiresExplicitRecovery else {
            return .handled
        }

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
        if let activePriority = foreground?.priority, cue.kind < activePriority {
            return .suppressed(by: activePriority)
        }

        presentation.caption = cue.caption

        if presentation.isCapturing {
            guard cue.kind == .voiceResponse else {
                return .suppressed(by: .voiceResponse)
            }
            pendingVoiceResponse = cue
            return .deferredUntilCaptureEnds
        }

        return startForegroundCue(cue)
    }

    private func startForegroundCue(_ cue: TrainingCoachCue) -> TrainingAudioEventOutcome {
        guard sceneAttached else { return .ignoredWhileDetached }
        guard backendReady else { return .backendUnavailable }

        if let current = foreground {
            backend.stop(current.handle)
            foreground = nil
            presentation.activePriority = nil
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
        presentation.activePriority = cue.kind
        applyCurrentMix()
        return .handled
    }

    private func pauseForTracking(_ reason: TrainingTrackingPauseReason) -> TrainingAudioEventOutcome {
        guard sceneAttached else { return .ignoredWhileDetached }
        trackingPaused = true
        pendingVoiceResponse = nil
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

    private func beginVoiceCapture() async -> TrainingAudioEventOutcome {
        guard sceneAttached else { return .ignoredWhileDetached }
        guard backendReady else { return .backendUnavailable }
        guard !trackingPaused, !presentation.requiresExplicitRecovery else { return .handled }
        guard !presentation.isCapturing else { return .captureReady }

        let captureGeneration = generation
        pendingVoiceResponse = nil
        presentation.caption = "Preparing microphone…"
        presentation.activePriority = nil
        backend.stop(channels: Self.captureChannels)
        clearPlaybackRecords(in: Self.captureChannels)
        applyCurrentMix(asVoiceCapture: true)

        do {
            try await decayWaiter.wait(for: captureDecay)
            guard !Task.isCancelled,
                  generation == captureGeneration,
                  sceneAttached,
                  !trackingPaused,
                  !presentation.requiresExplicitRecovery else {
                return .staleGeneration
            }
            try backend.beginVoiceCapture()
            presentation.status = .capturing
            presentation.caption = "Listening…"
            presentation.isCapturing = true
            presentation.mix = .voiceCapture
            return .captureReady
        } catch is CancellationError {
            return .staleGeneration
        } catch {
            presentation.status = .unavailable
            presentation.caption = "Microphone audio is unavailable. Use the visible controls."
            applyCurrentMix()
            Self.logger.error("Voice capture focus failed: \(error.localizedDescription, privacy: .public)")
            return .backendUnavailable
        }
    }

    private func endVoiceCapture() -> TrainingAudioEventOutcome {
        generation &+= 1
        backend.endVoiceCapture()
        presentation.isCapturing = false

        do {
            try backend.recoverPlaybackSession()
            backendReady = true
        } catch {
            backendReady = false
            presentation.status = .unavailable
            presentation.caption = "Audio is unavailable. Visual coaching remains active."
            return .backendUnavailable
        }

        presentation.status = presentation.requiresExplicitRecovery ? .awaitingExplicitRecovery : .ready
        applyCurrentMix()

        guard let pendingVoiceResponse else { return .handled }
        self.pendingVoiceResponse = nil
        return startForegroundCue(pendingVoiceResponse)
    }

    private func handleSystemEvent(_ event: TrainingAudioSystemEvent) -> TrainingAudioEventOutcome {
        switch event {
        case .interruptionBegan:
            enterExplicitRecovery(caption: "Audio interrupted. Training remains paused until you resume.")
        case .routeChanged:
            enterExplicitRecovery(caption: "Audio route changed. Check your surroundings, then resume.")
        case .mediaServicesWereReset:
            enterExplicitRecovery(caption: "Audio restarted. Training remains paused until you resume.")
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
        return .handled
    }

    private func detachScene() -> TrainingAudioEventOutcome {
        guard sceneAttached else { return .handled }
        generation &+= 1
        sceneAttached = false
        backendReady = false
        trackingPaused = false
        pendingVoiceResponse = nil
        backend.endVoiceCapture()
        backend.stopAll()
        backend.detachScene()
        clearAllPlaybackRecords()
        presentation = .detached
        return .handled
    }

    private func enterExplicitRecovery(caption: String) {
        guard sceneAttached else { return }
        generation &+= 1
        pendingVoiceResponse = nil
        backend.endVoiceCapture()
        backend.stopAll()
        clearAllPlaybackRecords()
        presentation.status = .awaitingExplicitRecovery
        presentation.caption = caption
        presentation.isCapturing = false
        presentation.requiresExplicitRecovery = true
        presentation.activePriority = nil
        presentation.mix = .silent
        backend.apply(mix: .silent, fadeDuration: fadeDuration)
    }

    private func playStatusResource(_ resource: TrainingAudioResourceID, caption: String?) {
        guard backendReady, let url = resources.url(for: resource) else { return }
        if let current = status {
            backend.stop(current.handle)
        }
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
        presentation.caption = caption
    }

    private func startEnvironmentBedsIfNeeded() {
        guard sceneAttached,
              backendReady,
              !trackingPaused,
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
        let variants: [TrainingAudioResourceID] = [.cleanImpact1, .cleanImpact2, .cleanImpact3]
        let resource = variants[nextImpactVariant % variants.count]
        nextImpactVariant = (nextImpactVariant + 1) % variants.count
        return resource
    }

    private func applyCurrentMix(asVoiceCapture: Bool = false) {
        let mix: TrainingAudioMix
        if presentation.requiresExplicitRecovery {
            mix = .silent
        } else if asVoiceCapture || presentation.isCapturing {
            mix = .voiceCapture
        } else if trackingPaused {
            mix = .trackingPaused
        } else if let priority = foreground?.priority {
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
            presentation.activePriority = nil
            applyCurrentMix()
            return
        }
        if status?.handle == handle {
            status = nil
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
            presentation.activePriority = nil
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
    }

    private func clearAllPlaybackRecords() {
        foreground = nil
        ambience = nil
        crowd = nil
        status = nil
        impactVoices.removeAll()
        presentation.activePriority = nil
    }

    private static func comfortFade(_ requested: Duration) -> Duration {
        min(max(requested, .milliseconds(150)), .milliseconds(300))
    }
}

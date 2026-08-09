import AVFoundation
import Foundation
import os

/// AVFoundation renderer for `TrainingAudioCoordinator`.
///
/// This type owns audio mechanics only: session configuration, player instances, notification
/// forwarding, and gain ramps. Semantic priority, captions, focus, and handle lifetime policy stay
/// in `TrainingAudioCoordinator`.
@MainActor
final class CoachAudioPlayer: TrainingAudioBackend {
    private static let logger = Logger(
        subsystem: "com.josephkwokpersonalteam.BoxingCoach",
        category: "CoachAudio"
    )
    private static let maximumLegacyQueueLength = 3

    var playbackDidFinish: ((TrainingAudioPlaybackHandle) -> Void)?
    var systemEventHandler: ((TrainingAudioSystemEvent) -> Void)?

    private let playbackDelegate = PlaybackDelegate()
    private var players: [TrainingAudioPlaybackHandle: AVAudioPlayer] = [:]
    private var channels: [TrainingAudioPlaybackHandle: TrainingAudioChannel] = [:]
    private var nextHandleValue = 1
    private var currentMix = TrainingAudioMix.stage(.fit)
    private var sceneAttached = false
    private var playbackReady = false
    private var captureActive = false
    private var notificationObservers: [NotificationCenter.ObservationToken] = []

    // Transitional source-compatibility for sessions that Task 8 will move to semantic events.
    private var legacyQueue: [CoachClipID] = []
    private var legacyHandle: TrainingAudioPlaybackHandle?
    private var legacyVoiceResponseContinuation: CheckedContinuation<Void, Never>?

    init() {
        playbackDelegate.onFinish = { [weak self] player in
            Task { @MainActor in
                self?.playerDidFinish(player)
            }
        }
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func attachScene() throws {
        if !sceneAttached {
            sceneAttached = true
            registerForAudioSystemEvents()
        }
        try configurePlaybackSession()
    }

    func detachScene() {
        guard sceneAttached else { return }
        stopAll()
        removeAudioSystemObservers()
        sceneAttached = false
        captureActive = false
        playbackReady = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func apply(mix: TrainingAudioMix, fadeDuration: Duration) {
        currentMix = mix
        let seconds = Self.seconds(for: fadeDuration)
        for (handle, player) in players {
            guard let channel = channels[handle] else { continue }
            player.setVolume(mix.gain(for: channel).linearAmplitude, fadeDuration: seconds)
        }
    }

    func play(_ request: TrainingAudioPlaybackRequest) -> TrainingAudioPlaybackHandle? {
        do {
            if !playbackReady || captureActive {
                try configurePlaybackSession()
            }
            let player = try AVAudioPlayer(contentsOf: request.url)
            let handle = TrainingAudioPlaybackHandle(rawValue: nextHandleValue)
            nextHandleValue &+= 1
            player.delegate = playbackDelegate
            player.numberOfLoops = request.loops ? -1 : 0
            player.volume = currentMix.gain(for: request.channel).linearAmplitude
            player.prepareToPlay()
            players[handle] = player
            channels[handle] = request.channel
            guard player.play() else {
                players[handle] = nil
                channels[handle] = nil
                Self.logger.error("AVAudioPlayer refused \(request.resource.fileName, privacy: .public)")
                return nil
            }
            return handle
        } catch {
            Self.logger.error(
                "Unable to play \(request.resource.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func stop(_ handle: TrainingAudioPlaybackHandle) {
        players.removeValue(forKey: handle)?.stop()
        channels[handle] = nil
        finishLegacyPlaybackIfNeeded(handle)
    }

    func stop(channels channelsToStop: Set<TrainingAudioChannel>) {
        let handles = channels.compactMap { handle, channel in
            channelsToStop.contains(channel) ? handle : nil
        }
        for handle in handles {
            stop(handle)
        }
    }

    func stopAll() {
        let handles = Array(players.keys)
        for handle in handles {
            stop(handle)
        }
        legacyQueue.removeAll()
        finishLegacyResponseIfNeeded()
    }

    func beginVoiceCapture() throws {
        registerForAudioSystemEvents()
        let session = AVAudioSession.sharedInstance()
        if captureActive, session.category == .playAndRecord, session.mode == .voiceChat {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            return
        }

        try session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.mixWithOthers, .duckOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        captureActive = true
        playbackReady = false
    }

    func endVoiceCapture() {
        guard captureActive else { return }
        captureActive = false
        playbackReady = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func recoverPlaybackSession() throws {
        try configurePlaybackSession()
    }

    func mediaServicesWereReset() throws {
        stopAll()
        captureActive = false
        playbackReady = false
        if sceneAttached {
            try configurePlaybackSession()
        }
    }

    // MARK: Transitional coaching API

    /// Warms the backend for existing session call sites. New code sends `.sceneDidAttach` to the
    /// semantic coordinator instead.
    func prepare() {
        do {
            try attachScene()
        } catch {
            Self.logger.error("Audio preparation failed: \(error.localizedDescription, privacy: .public)")
        }
        if CoachClipLibrary.url(for: .welcome) == nil {
            Self.logger.error("welcome.mp3 not found in app bundle — check CoachAudio target membership")
        }
    }

    func play(id: CoachClipID) {
        if legacyHandle != nil {
            enqueueLegacy(id)
        } else {
            startLegacyPlayback(id)
        }
    }

    func playAndWait(for id: CoachClipID) async {
        legacyQueue.removeAll()
        if let legacyHandle {
            stop(legacyHandle)
        }
        await withCheckedContinuation { continuation in
            legacyVoiceResponseContinuation = continuation
            startLegacyPlayback(id)
            if legacyHandle == nil {
                finishLegacyResponseIfNeeded()
            }
        }
    }

    func play(named name: String) {
        guard let id = CoachClipID(rawValue: name) else {
            Self.logger.error("Unknown coach clip id: \(name, privacy: .public)")
            return
        }
        play(id: id)
    }

    func stop() {
        stopAll()
    }

    var isClipPlaying: Bool { legacyHandle != nil }

    func prepareForVoiceCapture() throws {
        stop(channels: [.coach, .impact, .status])
        try beginVoiceCapture()
    }

    func restorePlaybackAfterCapture() {
        endVoiceCapture()
        do {
            try recoverPlaybackSession()
        } catch {
            Self.logger.error("Playback recovery failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func restorePlaybackMode() {
        restorePlaybackAfterCapture()
    }

    // MARK: Audio mechanics

    private func configurePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        if playbackReady,
           !captureActive,
           session.category == .playback,
           session.mode == .spokenAudio {
            try session.setActive(true)
            return
        }

        if captureActive {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        try session.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.mixWithOthers, .duckOthers]
        )
        try session.setActive(true)
        captureActive = false
        playbackReady = true
    }

    private func registerForAudioSystemEvents() {
        guard notificationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        notificationObservers.append(center.addObserver(
            of: session,
            for: AVAudioSession.DidBecomeInactiveMessage.self
        ) { [weak self] message in
            let deactivation: TrainingAudioSessionDeactivation
            switch message.deactivationResult {
            case .appDeactivated:
                deactivation = .appInitiated
            case .systemInterruption:
                deactivation = .systemInterruption
            @unknown default:
                deactivation = .systemInterruption
            }
            guard let event = TrainingAudioSystemEventMapper.event(for: deactivation) else { return }
            self?.systemEventHandler?(event)
        })

        notificationObservers.append(center.addObserver(
            of: session,
            for: AVAudioSession.ResumptionRecommendationMessage.self
        ) { [weak self] message in
            guard message.recommendation == .shouldResume else { return }
            self?.systemEventHandler?(.interruptionEnded)
        })

        notificationObservers.append(center.addObserver(
            of: session,
            for: AudioRouteDidChangeMessage.self
        ) { [weak self] _ in
            self?.systemEventHandler?(.routeChanged)
        })

        notificationObservers.append(center.addObserver(
            of: session,
            for: AudioMediaServicesWereResetMessage.self
        ) { [weak self] _ in
            self?.systemEventHandler?(.mediaServicesWereReset)
        })
    }

    private func removeAudioSystemObservers() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func playerDidFinish(_ player: AVAudioPlayer) {
        guard let entry = players.first(where: { $0.value === player }) else { return }
        let handle = entry.key
        players[handle] = nil
        channels[handle] = nil
        let wasLegacy = legacyHandle == handle
        if wasLegacy {
            legacyHandle = nil
            finishLegacyResponseIfNeeded()
            playNextLegacyClip()
        }
        playbackDidFinish?(handle)
    }

    private func enqueueLegacy(_ id: CoachClipID) {
        if legacyQueue.last == id { return }
        if legacyQueue.count >= Self.maximumLegacyQueueLength {
            legacyQueue.removeFirst()
        }
        legacyQueue.append(id)
    }

    private func startLegacyPlayback(_ id: CoachClipID) {
        guard let url = CoachClipLibrary.url(for: id) else {
            Self.logger.error("Missing coach clip: \(id.rawValue, privacy: .public).mp3")
            finishLegacyResponseIfNeeded()
            playNextLegacyClip()
            return
        }
        let request = TrainingAudioPlaybackRequest(
            resource: .coach(id),
            url: url,
            channel: .coach,
            loops: false,
            position: nil,
            generation: 0
        )
        legacyHandle = play(request)
        if legacyHandle == nil {
            finishLegacyResponseIfNeeded()
            playNextLegacyClip()
        }
    }

    private func playNextLegacyClip() {
        guard legacyHandle == nil, !legacyQueue.isEmpty else { return }
        startLegacyPlayback(legacyQueue.removeFirst())
    }

    private func finishLegacyPlaybackIfNeeded(_ handle: TrainingAudioPlaybackHandle) {
        guard legacyHandle == handle else { return }
        legacyHandle = nil
        finishLegacyResponseIfNeeded()
    }

    private func finishLegacyResponseIfNeeded() {
        guard let continuation = legacyVoiceResponseContinuation else { return }
        legacyVoiceResponseContinuation = nil
        continuation.resume()
    }

    private static func seconds(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private extension TrainingAudioMix {
    func gain(for channel: TrainingAudioChannel) -> TrainingAudioGain {
        switch channel {
        case .coach:
            coach
        case .ambience:
            ambience
        case .crowd:
            crowd
        case .impact:
            impact
        case .status:
            status
        }
    }
}

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: ((AVAudioPlayer) -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?(player)
    }
}

private struct AudioRouteDidChangeMessage: NotificationCenter.MainActorMessage {
    typealias Subject = AVAudioSession

    static var name: Notification.Name { AVAudioSession.routeChangeNotification }

    static func makeMessage(_ notification: Notification) -> Self? {
        Self()
    }

    static func makeNotification(_ message: Self) -> Notification {
        Notification(name: name)
    }
}

private struct AudioMediaServicesWereResetMessage: NotificationCenter.MainActorMessage {
    typealias Subject = AVAudioSession

    static var name: Notification.Name { AVAudioSession.mediaServicesWereResetNotification }

    static func makeMessage(_ notification: Notification) -> Self? {
        Self()
    }

    static func makeNotification(_ message: Self) -> Notification {
        Notification(name: name)
    }
}

import AVFoundation
import Foundation
import RealityKit
import os

/// Owns the RealityKit audio entities for one mixed-immersion scene. The ambient fields and
/// mono emitter pools are created once per scene root, reused for every cue, and removed together.
@MainActor
final class TrainingSpatialAudioScene {
    private weak var worldRoot: Entity?
    private weak var bodyAnchor: Entity?
    private var ambienceFields: [TrainingAudioChannel: Entity] = [:]
    private var targetEmitters: [Entity] = []
    private var bodyEmitters: [Entity] = []
    private var nextTargetEmitter = 0
    private var nextBodyEmitter = 0

    var entityCount: Int {
        ambienceFields.count + targetEmitters.count + bodyEmitters.count
    }

    func attach(worldRoot: Entity, bodyAnchor: Entity) {
        if self.worldRoot === worldRoot,
           self.bodyAnchor === bodyAnchor,
           entityCount > 0 {
            return
        }
        detach()
        self.worldRoot = worldRoot
        self.bodyAnchor = bodyAnchor

        let gym = Entity()
        gym.name = "TrainingGymAmbienceField"
        gym.ambientAudio = AmbientAudioComponent(gain: 0)
        bodyAnchor.addChild(gym)
        ambienceFields[.ambience] = gym

        let crowd = Entity()
        crowd.name = "TrainingCompetitionCrowdField"
        crowd.ambientAudio = AmbientAudioComponent(gain: 0)
        bodyAnchor.addChild(crowd)
        ambienceFields[.crowd] = crowd

        targetEmitters = (0..<4).map { index in
            let emitter = Entity()
            emitter.name = "TrainingTargetAudioEmitter\(index + 1)"
            emitter.spatialAudio = Self.monoSpatialComponent
            worldRoot.addChild(emitter)
            return emitter
        }

        bodyEmitters = (0..<3).map { index in
            let emitter = Entity()
            emitter.name = "TrainingBodyAudioEmitter\(index + 1)"
            emitter.position = SIMD3<Float>(Float(index - 1) * 0.34, 0.02, -1.15)
            emitter.spatialAudio = Self.monoSpatialComponent
            bodyAnchor.addChild(emitter)
            return emitter
        }
    }

    func detach() {
        for entity in ambienceFields.values { entity.removeFromParent() }
        for entity in targetEmitters { entity.removeFromParent() }
        for entity in bodyEmitters { entity.removeFromParent() }
        ambienceFields.removeAll()
        targetEmitters.removeAll()
        bodyEmitters.removeAll()
        nextTargetEmitter = 0
        nextBodyEmitter = 0
        worldRoot = nil
        bodyAnchor = nil
    }

    func playbackEntity(for request: TrainingAudioPlaybackRequest) -> Entity? {
        switch request.channel {
        case .ambience, .crowd:
            return ambienceFields[request.channel]
        case .impact:
            guard targetEmitters.isEmpty == false else { return nil }
            let entity = targetEmitters[nextTargetEmitter % targetEmitters.count]
            nextTargetEmitter = (nextTargetEmitter + 1) % targetEmitters.count
            if let position = request.position { entity.position = position }
            return entity
        case .status:
            guard bodyEmitters.isEmpty == false else { return nil }
            let entity = bodyEmitters[nextBodyEmitter % bodyEmitters.count]
            nextBodyEmitter = (nextBodyEmitter + 1) % bodyEmitters.count
            return entity
        case .coach:
            return nil
        }
    }

    private static var monoSpatialComponent: SpatialAudioComponent {
        SpatialAudioComponent(
            gain: 0,
            directLevel: 0,
            reverbLevel: -96,
            directivity: .beam(focus: 0)
        )
    }
}

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
    var playbackDidFinish: ((TrainingAudioPlaybackHandle) -> Void)?
    var systemEventHandler: ((TrainingAudioSystemEvent) -> Void)?

    private let playbackDelegate = PlaybackDelegate()
    private var players: [TrainingAudioPlaybackHandle: AVAudioPlayer] = [:]
    private var channels: [TrainingAudioPlaybackHandle: TrainingAudioChannel] = [:]
    private let spatialScene = TrainingSpatialAudioScene()
    private var spatialPlayers: [TrainingAudioPlaybackHandle: AudioPlaybackController] = [:]
    private var spatialChannels: [TrainingAudioPlaybackHandle: TrainingAudioChannel] = [:]
    private var spatialResources: [SpatialResourceKey: AudioFileResource] = [:]
    private var nextHandleValue = 1
    private var currentMix = TrainingAudioMix.stage(.fit)
    private var sceneAttached = false
    private var playbackReady = false
    private var captureActive = false
    private var notificationObservers: [NotificationCenter.ObservationToken] = []

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
        removeAudioSystemObservers()
        detachSpatialScene()
        sceneAttached = false
        captureActive = false
        playbackReady = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func attachSpatialScene(worldRoot: Entity, bodyAnchor: Entity) {
        spatialScene.attach(worldRoot: worldRoot, bodyAnchor: bodyAnchor)
    }

    func detachSpatialScene() {
        let handles = Array(spatialPlayers.keys)
        for handle in handles { stop(handle) }
        spatialScene.detach()
        spatialResources.removeAll()
    }

    func apply(mix: TrainingAudioMix, fadeDuration: Duration) {
        currentMix = mix
        let seconds = Self.seconds(for: fadeDuration)
        for (handle, player) in players {
            guard let channel = channels[handle] else { continue }
            player.setVolume(mix.gain(for: channel).linearAmplitude, fadeDuration: seconds)
        }
        for (handle, player) in spatialPlayers {
            guard let channel = spatialChannels[handle] else { continue }
            player.fade(to: mix.gain(for: channel).decibels, duration: seconds)
        }
    }

    func play(_ request: TrainingAudioPlaybackRequest) -> TrainingAudioPlaybackHandle? {
        if let entity = spatialScene.playbackEntity(for: request) {
            return playSpatial(request, on: entity)
        }
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
        if let spatialPlayer = spatialPlayers.removeValue(forKey: handle) {
            spatialPlayer.completionHandler = nil
            spatialPlayer.stop()
            spatialChannels[handle] = nil
            return
        }
        players.removeValue(forKey: handle)?.stop()
        channels[handle] = nil
    }

    func stop(channels channelsToStop: Set<TrainingAudioChannel>) {
        let handles = channels.compactMap { handle, channel in
            channelsToStop.contains(channel) ? handle : nil
        } + spatialChannels.compactMap { handle, channel in
            channelsToStop.contains(channel) ? handle : nil
        }
        for handle in handles {
            stop(handle)
        }
    }

    func stopAll() {
        let handles = Array(players.keys) + Array(spatialPlayers.keys)
        for handle in handles {
            stop(handle)
        }
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
        captureActive = false
        playbackReady = false
        if sceneAttached {
            try configurePlaybackSession()
        }
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
        ) { [weak self] message in
            guard let event = TrainingAudioRouteChangeEventMapper.event(for: message.reason) else {
                return
            }
            self?.systemEventHandler?(event)
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
        playbackDidFinish?(handle)
    }

    private func playSpatial(
        _ request: TrainingAudioPlaybackRequest,
        on entity: Entity
    ) -> TrainingAudioPlaybackHandle? {
        do {
            if !playbackReady || captureActive { try configurePlaybackSession() }
            let key = SpatialResourceKey(resource: request.resource, loops: request.loops)
            let resource: AudioFileResource
            if let cached = spatialResources[key] {
                resource = cached
            } else {
                resource = try AudioFileResource.load(
                    contentsOf: request.url,
                    withName: request.resource.fileName,
                    configuration: .init(
                        loadingStrategy: .preload,
                        shouldLoop: request.loops
                    )
                )
                spatialResources[key] = resource
            }

            let handle = TrainingAudioPlaybackHandle(rawValue: nextHandleValue)
            nextHandleValue &+= 1
            let player = entity.playAudio(resource)
            player.gain = currentMix.gain(for: request.channel).decibels
            player.completionHandler = { [weak self] in
                self?.spatialPlayerDidFinish(handle)
            }
            spatialPlayers[handle] = player
            spatialChannels[handle] = request.channel
            return handle
        } catch {
            Self.logger.error(
                "Unable to spatially play \(request.resource.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func spatialPlayerDidFinish(_ handle: TrainingAudioPlaybackHandle) {
        spatialPlayers[handle] = nil
        spatialChannels[handle] = nil
        playbackDidFinish?(handle)
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

private extension TrainingAudioGain {
    var decibels: Double {
        switch self {
        case .muted: -96
        case let .decibels(value): Double(value)
        }
    }
}

private struct SpatialResourceKey: Hashable {
    let resource: TrainingAudioResourceID
    let loops: Bool
}

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: ((AVAudioPlayer) -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?(player)
    }
}

nonisolated enum TrainingAudioRouteChangeEventMapper {
    static func event(
        for reason: AVAudioSession.RouteChangeReason
    ) -> TrainingAudioSystemEvent? {
        reason == .categoryChange ? nil : .routeChanged
    }
}

struct AudioRouteDidChangeMessage: NotificationCenter.MainActorMessage {
    typealias Subject = AVAudioSession

    let reason: AVAudioSession.RouteChangeReason

    static var name: Notification.Name { AVAudioSession.routeChangeNotification }

    static func makeMessage(_ notification: Notification) -> Self? {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
            return nil
        }
        return Self(reason: reason)
    }

    static func makeNotification(_ message: Self) -> Notification {
        Notification(
            name: name,
            userInfo: [AVAudioSessionRouteChangeReasonKey: message.reason.rawValue]
        )
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

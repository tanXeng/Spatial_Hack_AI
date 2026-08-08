//
//  HandTrackingService.swift
//  Test
//
//  ARKit is intentionally isolated in this service. The rest of the app only
//  receives plain, Sendable marker and fist-pose samples.
//

#if os(visionOS)
import ARKit
#endif
import Foundation
import Observation
import QuartzCore
import simd

enum HandMarkerKind: String, CaseIterable, Sendable {
    case wrist
    case thumbTip
    case indexTip
    case middleTip
    case ringTip
    case littleTip
}

struct HandMarker: Identifiable, Equatable, Sendable {
    let side: HandSide
    let kind: HandMarkerKind
    let position: SIMD3<Float>

    var id: String {
        "\(side.rawValue).\(kind.rawValue)"
    }
}

/// A plain device-position sample used as a conservative head-motion proxy.
/// ARKit's `DeviceAnchor` remains private to this service.
struct DevicePoseSample: Equatable, Sendable {
    let position: SIMD3<Float>
    /// The headset's local right axis expressed in world coordinates. Defense
    /// freezes its horizontal projection during neutral calibration so
    /// left/right cues remain user-relative instead of world-X-relative.
    let rightDirection: SIMD3<Float>
    let capturedAt: TimeInterval
}

enum HandTrackingState: Equatable, Sendable {
    case idle
    case checkingSupport
    case simulatorUnavailable
    case unsupported
    case requestingAuthorization
    case denied
    case worldTrackingUnavailable
    case worldTracking
    case worldTrackingLost
    case waitingForHands
    case tracking(handCount: Int)
    case trackingLost
    case failed(message: String)

    var title: String {
        switch self {
        case .idle:
            "Ready"
        case .checkingSupport:
            "Checking hand tracking"
        case .simulatorUnavailable:
            "Simulator fallback"
        case .unsupported:
            "Hand tracking unavailable"
        case .requestingAuthorization:
            "Requesting permission"
        case .denied:
            "Hand tracking denied"
        case .worldTrackingUnavailable:
            "Head tracking unavailable"
        case .worldTracking:
            "Head tracking active"
        case .worldTrackingLost:
            "Head tracking lost — paused"
        case .waitingForHands:
            "Waiting for hands"
        case .tracking(let handCount):
            handCount == 1 ? "Tracking one hand" : "Tracking both hands"
        case .trackingLost:
            "Tracking lost — paused"
        case .failed:
            "Tracking error"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            "Enter the mixed training space when your area is clear."
        case .checkingSupport:
            "Checking this device for processed hand-joint tracking."
        case .simulatorUnavailable:
            "The mixed space and safety controls are available, but calibration, targets, and the live drill require Apple Vision Pro."
        case .unsupported:
            "This device does not support the required hand-tracking provider."
        case .requestingAuthorization:
            "Approve hand tracking to calibrate and run the local drill."
        case .denied:
            "Enable hand tracking for ShadowBox in Settings, then reopen the session."
        case .worldTrackingUnavailable:
            "This device does not support the processed device-position provider required by Defense Lab."
        case .worldTracking:
            "Processed device position is available locally for the stationary head-movement drill."
        case .worldTrackingLost:
            "The head-movement drill is paused until a current device position is available."
        case .waitingForHands:
            "Raise both hands into a comfortable guard."
        case .tracking:
            "Multi-knuckle fist centers and diagnostic markers are updating locally."
        case .trackingLost:
            "Markers were hidden for safety and scoring was neutralized. Return both hands to guard or exit."
        case .failed(let message):
            message
        }
    }

    var hasBothHands: Bool {
        if case .tracking(handCount: 2) = self {
            return true
        }
        return false
    }
}

@MainActor
@Observable
final class HandTrackingService {
    private static let trackingLossTimeout: TimeInterval = 0.5
    private static let sampleFreshness: TimeInterval = 0.20
    private static let offlineFrameInterval = 1.0 / 30.0

    private struct TimedHandPose {
        let pose: HandPose
        let timestamp: TimeInterval
    }

    @ObservationIgnored private(set) var samples: AsyncStream<HandSample>
    @ObservationIgnored private var sampleContinuation: AsyncStream<HandSample>.Continuation
    @ObservationIgnored private var lifecycleID = UUID()
    @ObservationIgnored private var isStarting = false
    #if os(visionOS)
    @ObservationIgnored private var pendingSession: ARKitSession?
    @ObservationIgnored private var activeSession: ARKitSession?
    #endif
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var devicePoseTask: Task<Void, Never>?
    @ObservationIgnored private var lastAnchorUpdateUptime: TimeInterval = 0
    @ObservationIgnored private var latestHandPoses: [HandSide: TimedHandPose] = [:]
    @ObservationIgnored private var activeRequiresHandTracking = true

    private(set) var state: HandTrackingState = .idle
    var isTrackingReady: Bool {
        guard !DeveloperConfig.isOfflineModeEnabled else { return true }
        return state.hasBothHands
    }

    var isHeadTrackingReady: Bool {
        guard !DeveloperConfig.isOfflineModeEnabled else { return latestDevicePose != nil }
        return latestDevicePose != nil
    }

    private(set) var markers: [HandMarker] = []
    private(set) var latestSample: HandSample?
    private(set) var latestDevicePose: DevicePoseSample?

    init() {
        let pair = AsyncStream<HandSample>.makeStream(bufferingPolicy: .bufferingNewest(1))
        samples = pair.stream
        sampleContinuation = pair.continuation
    }

    func start(requiresHandTracking: Bool = true) async {
        guard
            !isStarting,
            updateTask == nil,
            eventTask == nil,
            watchdogTask == nil,
            devicePoseTask == nil
        else {
            return
        }

        let lifecycleID = UUID()
        self.lifecycleID = lifecycleID
        isStarting = true
        defer {
            if self.lifecycleID == lifecycleID {
                isStarting = false
            }
        }

        state = .checkingSupport
        activeRequiresHandTracking = requiresHandTracking
        markers = []
        clearTrackedHands(publishSample: false)

        if DeveloperConfig.isOfflineModeEnabled {
            markers = []
            clearTrackedHands(publishSample: false)
            startOfflineTracking(requiresHandTracking: requiresHandTracking, lifecycleID: lifecycleID)
            return
        }

#if os(visionOS)
#if targetEnvironment(simulator)
        state = .simulatorUnavailable
#else
        let session = ARKitSession()
        let handProvider: HandTrackingProvider?
        if requiresHandTracking {
            guard HandTrackingProvider.isSupported else {
                state = .unsupported
                return
            }
            handProvider = HandTrackingProvider()
        } else {
            handProvider = nil
        }
        // Keep providers mutually exclusive for this MVP. ARKit reports
        // provider-state events as a collection; a hand-only or world-only
        // session makes every pause/error unambiguous and avoids a secondary
        // provider terminating an otherwise healthy active feature.
        let worldProvider = !requiresHandTracking && WorldTrackingProvider.isSupported
            ? WorldTrackingProvider()
            : nil
        if !requiresHandTracking, worldProvider == nil {
            state = .worldTrackingUnavailable
            return
        }
        pendingSession = session
        defer {
            if self.lifecycleID == lifecycleID, pendingSession === session {
                pendingSession = nil
            }
        }

        if requiresHandTracking {
            var authorization = await session.queryAuthorization(for: [.handTracking])[.handTracking] ?? .notDetermined
            guard isCurrent(lifecycleID) else {
                session.stop()
                return
            }

            if authorization == .notDetermined {
                state = .requestingAuthorization
                authorization = await session.requestAuthorization(for: [.handTracking])[.handTracking] ?? .denied
                guard isCurrent(lifecycleID) else {
                    session.stop()
                    return
                }
            }

            guard authorization == .allowed else {
                state = .denied
                return
            }
        }

        do {
            var providers: [any DataProvider] = []
            if let handProvider {
                providers.append(handProvider)
            }
            if let worldProvider {
                providers.append(worldProvider)
            }
            try await session.run(providers)
            guard isCurrent(lifecycleID) else {
                session.stop()
                return
            }

            pendingSession = nil
            activeSession = session
            lastAnchorUpdateUptime = ProcessInfo.processInfo.systemUptime
            state = requiresHandTracking ? .waitingForHands : .worldTrackingLost

            if let handProvider {
                updateTask = Task { [weak self] in
                    await self?.consumeAnchorUpdates(
                        from: handProvider,
                        lifecycleID: lifecycleID
                    )
                }
                watchdogTask = Task { [weak self] in
                    await self?.monitorAnchorUpdates(lifecycleID: lifecycleID)
                }
            }
            eventTask = Task { [weak self] in
                await self?.consumeSessionEvents(
                    from: session,
                    requiresHandTracking: requiresHandTracking,
                    lifecycleID: lifecycleID
                )
            }
            if let worldProvider {
                devicePoseTask = Task { [weak self] in
                    await self?.monitorDevicePose(
                        from: worldProvider,
                        lifecycleID: lifecycleID
                    )
                }
            }
        } catch {
            session.stop()
            guard isCurrent(lifecycleID) else { return }
            clearTrackedHands()
            state = .failed(message: error.localizedDescription)
        }
#endif
#else
        markers = []
        clearTrackedHands(publishSample: false)
        startOfflineTracking(
            requiresHandTracking: requiresHandTracking,
            lifecycleID: lifecycleID
        )
#endif
    }

    func stop() {
        lifecycleID = UUID()
        isStarting = false
        updateTask?.cancel()
        eventTask?.cancel()
        watchdogTask?.cancel()
        devicePoseTask?.cancel()
        updateTask = nil
        eventTask = nil
        watchdogTask = nil
        devicePoseTask = nil
#if os(visionOS)
        pendingSession?.stop()
        activeSession?.stop()
        pendingSession = nil
        activeSession = nil
#endif
        lastAnchorUpdateUptime = 0
        markers = []
        latestDevicePose = nil
        activeRequiresHandTracking = true
        clearTrackedHands()
        replaceSampleStream()
        state = .idle
    }

    private func startOfflineTracking(
        requiresHandTracking: Bool,
        lifecycleID: UUID
    ) {
        state = requiresHandTracking ? .tracking(handCount: 2) : .worldTracking
        lastAnchorUpdateUptime = ProcessInfo.processInfo.systemUptime
        updateTask = Task { [weak self] in
            await self?.emitOfflineHandSamples(
                requiresHandTracking: requiresHandTracking,
                lifecycleID: lifecycleID
            )
        }
        if !requiresHandTracking {
            devicePoseTask = Task { [weak self] in
                await self?.emitOfflineDevicePose(lifecycleID: lifecycleID)
            }
        }
    }

    /// A cancelled `AsyncStream` iterator terminates that stream permanently.
    /// Immersive views own the sole iterator, so closing one session must create
    /// a fresh channel before the next immersive view starts consuming samples.
    private func replaceSampleStream() {
        sampleContinuation.finish()
        let pair = AsyncStream<HandSample>.makeStream(bufferingPolicy: .bufferingNewest(1))
        samples = pair.stream
        sampleContinuation = pair.continuation
    }

    private func isCurrent(_ lifecycleID: UUID) -> Bool {
        self.lifecycleID == lifecycleID && !Task.isCancelled
    }

    private func emitOfflineHandSamples(
        requiresHandTracking: Bool,
        lifecycleID: UUID
    ) async {
        while isCurrent(lifecycleID) {
            let timestamp = ProcessInfo.processInfo.systemUptime
            guard isCurrent(lifecycleID) else { return }
            lastAnchorUpdateUptime = timestamp

            if requiresHandTracking {
                let elapsed = Float(timestamp)
                let phase = elapsed * 1.55
                let baseHeight = DeveloperConfig.offlineGuardHeight
                let baseZ: Float = -0.80
                let sway = 0.025 * sin(phase)
                let leftSway = sway * 0.35
                let rightSway = -sway * 0.35
                let leftUp = abs(sin(phase * 0.55)) * 0.012
                let leftForward = abs(sin(phase * 0.7)) * 0.05
                let rightUp = abs(cos(phase * 0.65)) * 0.012
                let rightForward = abs(cos(phase * 0.9)) * 0.05
                let left = SIMD3<Float>(
                    -DeveloperConfig.offlineGuardLateralOffset + leftSway,
                    baseHeight + leftUp,
                    baseZ + leftForward
                )
                let right = SIMD3<Float>(
                    DeveloperConfig.offlineGuardLateralOffset + rightSway,
                    baseHeight + rightUp,
                    baseZ + rightForward
                )

                latestHandPoses[.left] = TimedHandPose(
                    pose: HandPose(
                        fistCenter: left,
                        wrist: left + SIMD3<Float>(0, -0.09, 0.07),
                        trackedKnuckleCount: 6,
                        capturedAt: timestamp
                    ),
                    timestamp: timestamp
                )
                latestHandPoses[.right] = TimedHandPose(
                    pose: HandPose(
                        fistCenter: right,
                        wrist: right + SIMD3<Float>(0, -0.09, 0.07),
                        trackedKnuckleCount: 6,
                        capturedAt: timestamp
                    ),
                    timestamp: timestamp
                )

                markers = [
                    HandMarker(side: .left, kind: .wrist, position: left + SIMD3<Float>(0, -0.06, 0)),
                    HandMarker(side: .left, kind: .thumbTip, position: left + SIMD3<Float>(0.03, 0.02, 0)),
                    HandMarker(side: .left, kind: .indexTip, position: left + SIMD3<Float>(0.02, 0.04, 0)),
                    HandMarker(side: .left, kind: .middleTip, position: left),
                    HandMarker(side: .left, kind: .ringTip, position: left + SIMD3<Float>(-0.02, 0.01, 0)),
                    HandMarker(side: .left, kind: .littleTip, position: left + SIMD3<Float>(-0.03, -0.02, 0)),
                    HandMarker(side: .right, kind: .wrist, position: right + SIMD3<Float>(0, -0.06, 0)),
                    HandMarker(side: .right, kind: .thumbTip, position: right + SIMD3<Float>(-0.03, 0.02, 0)),
                    HandMarker(side: .right, kind: .indexTip, position: right + SIMD3<Float>(-0.02, 0.04, 0)),
                    HandMarker(side: .right, kind: .middleTip, position: right),
                    HandMarker(side: .right, kind: .ringTip, position: right + SIMD3<Float>(0.02, 0.01, 0)),
                    HandMarker(side: .right, kind: .littleTip, position: right + SIMD3<Float>(0.03, -0.02, 0)),
                ]
            } else {
                markers.removeAll()
                latestHandPoses.removeAll()
            }

            refreshTrackingState()
            publishCurrentSample()
            state = requiresHandTracking ? .tracking(handCount: 2) : .worldTracking
            try? await Task.sleep(for: .seconds(Self.offlineFrameInterval))
        }
    }

    private func refreshTrackingState() {
        let now = ProcessInfo.processInfo.systemUptime
        let handCount = HandSide.allCases.compactMap { freshPose(for: $0, at: now) }.count
        state = handCount == 0 ? .trackingLost : .tracking(handCount: handCount)
    }

    private func emitOfflineDevicePose(lifecycleID: UUID) async {
        while isCurrent(lifecycleID) {
            let timestamp = ProcessInfo.processInfo.systemUptime
            guard isCurrent(lifecycleID) else { return }
            let time = Float(timestamp)
            let drift = 0.015 * sin(time * 0.85)
            let headHeight: Float = 1.52
            let headZ: Float = -1.00
            latestDevicePose = DevicePoseSample(
                position: SIMD3<Float>(drift, headHeight, headZ),
                rightDirection: SIMD3<Float>(1.0, 0.0, 0.0),
                capturedAt: timestamp
            )
            state = .worldTracking
            try? await Task.sleep(for: .seconds(Self.offlineFrameInterval))
        }
    }

#if os(visionOS) && !targetEnvironment(simulator)
    private func consumeAnchorUpdates(
        from provider: HandTrackingProvider,
        lifecycleID: UUID
    ) async {
        for await update in provider.anchorUpdates {
            guard isCurrent(lifecycleID) else { return }
            lastAnchorUpdateUptime = ProcessInfo.processInfo.systemUptime

            if update.event == .removed {
                removeTrackedHand(for: update.anchor.chirality)
            } else {
                apply(update.anchor, capturedAt: update.timestamp)
            }
        }

        guard isCurrent(lifecycleID) else { return }
        terminateTracking(
            lifecycleID: lifecycleID,
            state: .failed(message: "Hand tracking stopped. Exit and re-enter the training space.")
        )
    }

    private func consumeSessionEvents(
        from session: ARKitSession,
        requiresHandTracking: Bool,
        lifecycleID: UUID
    ) async {
        for await event in session.events {
            guard isCurrent(lifecycleID) else { return }

            switch event {
            case .authorizationChanged(let type, let status):
                if requiresHandTracking,
                   type == .handTracking,
                   status == .denied {
                    terminateTracking(lifecycleID: lifecycleID, state: .denied)
                    return
                }

            case .dataProviderStateChanged(_, let newState, let error):
                if let error {
                    terminateTracking(
                        lifecycleID: lifecycleID,
                        state: .failed(message: error.localizedDescription)
                    )
                    return
                }

                switch newState {
                case .initialized:
                    break
                case .running:
                    if requiresHandTracking, markers.isEmpty {
                        state = .waitingForHands
                    } else if !requiresHandTracking,
                              latestDevicePose != nil {
                        state = .worldTracking
                    }
                case .paused:
                    markers = []
                    clearTrackedHands()
                    latestDevicePose = nil
                    state = requiresHandTracking ? .trackingLost : .worldTrackingLost
                case .stopped:
                    terminateTracking(
                        lifecycleID: lifecycleID,
                        state: .failed(message: requiresHandTracking
                            ? "Hand tracking stopped. Exit and re-enter the training space."
                            : "Head tracking stopped. Exit and re-enter Defense Lab.")
                    )
                    return
                @unknown default:
                    markers = []
                    clearTrackedHands()
                    latestDevicePose = nil
                    state = requiresHandTracking ? .trackingLost : .worldTrackingLost
                }

            @unknown default:
                break
            }
        }

        guard isCurrent(lifecycleID) else { return }
        terminateTracking(
            lifecycleID: lifecycleID,
            state: .failed(message: requiresHandTracking
                ? "The hand-tracking event stream stopped. Exit and re-enter the training space."
                : "The head-tracking event stream stopped. Exit and re-enter Defense Lab.")
        )
    }

    private func monitorAnchorUpdates(lifecycleID: UUID) async {
        while isCurrent(lifecycleID) {
            try? await Task.sleep(for: .milliseconds(100))
            guard isCurrent(lifecycleID) else { return }
            guard case .tracking = state else { continue }

            let elapsed = ProcessInfo.processInfo.systemUptime - lastAnchorUpdateUptime
            if elapsed >= Self.trackingLossTimeout {
                markers = []
                clearTrackedHands()
                state = .trackingLost
            }
        }
    }

    private func monitorDevicePose(
        from provider: WorldTrackingProvider,
        lifecycleID: UUID
    ) async {
        while isCurrent(lifecycleID) {
            guard provider.state == .running else {
                latestDevicePose = nil
                if !activeRequiresHandTracking {
                    state = .worldTrackingLost
                }
                try? await Task.sleep(for: .milliseconds(16))
                continue
            }

            let timestamp = CACurrentMediaTime()
            if let anchor = provider.queryDeviceAnchor(atTimestamp: timestamp),
               anchor.isTracked {
                let transform = anchor.originFromAnchorTransform
                latestDevicePose = DevicePoseSample(
                    position: SIMD3<Float>(
                        transform.columns.3.x,
                        transform.columns.3.y,
                        transform.columns.3.z
                    ),
                    rightDirection: SIMD3<Float>(
                        transform.columns.0.x,
                        transform.columns.0.y,
                        transform.columns.0.z
                    ),
                    capturedAt: timestamp
                )
                if !activeRequiresHandTracking {
                    state = .worldTracking
                }
            } else {
                latestDevicePose = nil
                if !activeRequiresHandTracking {
                    state = .worldTrackingLost
                }
            }

            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func terminateTracking(
        lifecycleID: UUID,
        state terminalState: HandTrackingState
    ) {
        guard self.lifecycleID == lifecycleID else { return }

        updateTask?.cancel()
        eventTask?.cancel()
        watchdogTask?.cancel()
        devicePoseTask?.cancel()
        updateTask = nil
        eventTask = nil
        watchdogTask = nil
        devicePoseTask = nil
#if os(visionOS)
        activeSession?.stop()
        activeSession = nil
#endif
        lastAnchorUpdateUptime = 0
        markers = []
        latestDevicePose = nil
        activeRequiresHandTracking = true
        clearTrackedHands()
        state = terminalState
    }

    private func apply(_ anchor: HandAnchor, capturedAt: TimeInterval) {
        guard capturedAt.isFinite,
              anchor.isTracked,
              let skeleton = anchor.handSkeleton else {
            removeTrackedHand(for: anchor.chirality)
            return
        }

        let side = side(for: anchor.chirality)
        markers.removeAll { $0.side == side }

        let knuckleNames: [HandSkeleton.JointName] = [
            .indexFingerKnuckle,
            .middleFingerKnuckle,
            .ringFingerKnuckle,
            .littleFingerKnuckle,
        ]
        let knuckles = knuckleNames.map {
            jointPosition($0, skeleton: skeleton, anchor: anchor)
        }
        let wrist = jointPosition(.wrist, skeleton: skeleton, anchor: anchor)
        let receivedAt = ProcessInfo.processInfo.systemUptime

        if let fistCenter = FistCenterEstimator.centroid(
            of: knuckles,
            minimumJointCount: DrillConfiguration.provisional.minimumFistJointCount
        ) {
            latestHandPoses[side] = TimedHandPose(
                pose: HandPose(
                    fistCenter: fistCenter,
                    wrist: wrist,
                    trackedKnuckleCount: knuckles.compactMap { $0 }.count,
                    capturedAt: capturedAt
                ),
                timestamp: receivedAt
            )
        } else {
            latestHandPoses.removeValue(forKey: side)
        }

        let jointMap: [(HandMarkerKind, HandSkeleton.JointName)] = [
            (.wrist, .wrist),
            (.thumbTip, .thumbTip),
            (.indexTip, .indexFingerTip),
            (.middleTip, .middleFingerTip),
            (.ringTip, .ringFingerTip),
            (.littleTip, .littleFingerTip),
        ]

        for (kind, jointName) in jointMap {
            guard let position = jointPosition(
                jointName,
                skeleton: skeleton,
                anchor: anchor
            ) else {
                continue
            }
            markers.append(HandMarker(side: side, kind: kind, position: position))
        }

        publishCurrentSample()
        refreshTrackingState()
    }

    private func removeTrackedHand(for chirality: HandAnchor.Chirality) {
        let side = side(for: chirality)
        markers.removeAll { $0.side == side }
        latestHandPoses.removeValue(forKey: side)
        publishCurrentSample()
        refreshTrackingState()
    }

    private func jointPosition(
        _ name: HandSkeleton.JointName,
        skeleton: HandSkeleton,
        anchor: HandAnchor
    ) -> SIMD3<Float>? {
        let joint = skeleton.joint(name)
        guard joint.isTracked else { return nil }

        let originFromJoint = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
        return SIMD3<Float>(
            originFromJoint.columns.3.x,
            originFromJoint.columns.3.y,
            originFromJoint.columns.3.z
        )
    }

    private func side(for chirality: HandAnchor.Chirality) -> HandSide {
        chirality == .left ? .left : .right
    }
#endif

    private func publishCurrentSample() {
        let now = ProcessInfo.processInfo.systemUptime

        for hand in HandSide.allCases where freshPose(for: hand, at: now) == nil {
            latestHandPoses.removeValue(forKey: hand)
            markers.removeAll { $0.side == hand }
        }

        let sample = HandSample(
            timestamp: now,
            left: freshPose(for: .left, at: now),
            right: freshPose(for: .right, at: now)
        )
        latestSample = sample
        sampleContinuation.yield(sample)
    }

    private func freshPose(for hand: HandSide, at timestamp: TimeInterval) -> HandPose? {
        guard timestamp.isFinite,
              let timedPose = latestHandPoses[hand],
              timedPose.timestamp.isFinite,
              timedPose.pose.capturedAt.isFinite else {
            return nil
        }

        let receiptAge = timestamp - timedPose.timestamp
        let captureAge = timestamp - timedPose.pose.capturedAt
        guard receiptAge >= 0,
              receiptAge <= Self.sampleFreshness,
              captureAge >= 0,
              captureAge <= Self.sampleFreshness else {
            return nil
        }
        return timedPose.pose
    }

    private func clearTrackedHands(publishSample: Bool = true) {
        latestHandPoses.removeAll()
        latestSample = nil

        if publishSample {
            let sample = HandSample(
                timestamp: ProcessInfo.processInfo.systemUptime,
                left: nil,
                right: nil
            )
            latestSample = sample
            sampleContinuation.yield(sample)
        }
    }
}

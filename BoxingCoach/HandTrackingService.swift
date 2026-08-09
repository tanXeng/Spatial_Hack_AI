import ARKit
import Foundation
import QuartzCore
import RealityKit
import simd

/// One arm's raw tracked joints, in **ARKit world space** (the immersive space origin).
///
/// This is deliberately raw — no smoothing, no shoulder estimation, no normalization. Turning
/// this into a full arm pose is `ArmPoseSolver`'s job, and keeping the two apart means the IK
/// can be retuned without touching the tracking layer.
struct HandObservation: Sendable {
    var side: BodySide
    var wristPosition: SIMD3<Float>
    var wristOrientation: simd_quatf

    /// The `forearmArm` joint, which sits near the elbow.
    ///
    /// visionOS *does* expose this (hierarchy: `wrist` → `forearmWrist` → `forearmArm`), which
    /// is useful for elbow estimation. Treat it as a strong hint rather than ground truth: it
    /// is extrapolated from the hand, so it degrades as the elbow leaves the cameras' view —
    /// exactly what happens at the end of a fully extended punch. `ArmPoseSolver` falls back to
    /// IK when this is `nil`, and blends toward IK when it disagrees with the arm's known length.
    var elbowHint: SIMD3<Float>?

    /// The point used as "the fist" for hit tests and scoring.
    var fistPosition: SIMD3<Float>
    var fistState: TrackedFistState
    var fistClosureRatio: Float

    /// ARKit's monotonic acquisition time for this hand anchor.
    var acquisitionTimestamp: TimeInterval

    /// Callback receipt time, retained only for latency telemetry and admission checks.
    var receiptTimestamp: TimeInterval

    /// Device pose queried at `acquisitionTimestamp`, not at callback time.
    var deviceTransform: simd_float4x4
    var deviceTimestamp: TimeInterval

    /// Compatibility name used by motion/scoring call sites. Freshness is acquisition-based.
    var timestamp: TimeInterval { acquisitionTimestamp }
}

/// A caller-owned cursor for detecting discontinuities in tracking evidence. Each capture or
/// calibration loop keeps its own observer so one consumer cannot acknowledge a reset for another.
nonisolated struct TrackingContinuityObserver: Sendable {
    private(set) var epoch: UInt64

    nonisolated init(epoch: UInt64) {
        self.epoch = epoch
    }

    /// Returns `true` exactly once for each newly observed continuity epoch.
    nonisolated mutating func observe(_ currentEpoch: UInt64) -> Bool {
        guard currentEpoch != epoch else { return false }
        epoch = currentEpoch
        return true
    }
}

nonisolated enum TrackingRuntimeState: String, Equatable, Sendable {
    case idle
    case requestingAuthorization
    case starting
    case running
    case degraded
    case paused
    case stopped
    case failed
}

nonisolated enum TrackingRuntimeAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case allowed
    case denied
}

nonisolated enum TrackingRuntimeProviderState: Equatable, Sendable {
    case initialized
    case running
    case paused
    case stopped
}

nonisolated enum TrackingRuntimeRejectionReason: Equatable, Sendable {
    case unsupported
    case authorizationDenied
    case authorizationRevoked
    case providerPaused
    case providerStopped
    case providerFailed(message: String)
    case sessionFailed(message: String)
    case worldTrackingUnavailable
    case reacquiring
    case anchorRemoved(side: BodySide)
    case untracked(side: BodySide)
    case missingSkeleton(side: BodySide)
    case missingRequiredJoint(side: BodySide, joint: String)
    case missingDevicePose
    case nonFiniteSample
    case invalidTimestamp
    case nonMonotonicSample(side: BodySide)
    case staleSample(age: TimeInterval)
    case sampleGap(duration: TimeInterval)
}

nonisolated enum TrackingRecoveryInstruction: String, Equatable, Sendable {
    case none = ""
    case keepHandsVisible = "Keep your hands visible and look forward while tracking stabilizes."
    case waitForProvider = "Stay in the immersive space while tracking resumes."
    case reviewAuthorization = "Allow hand tracking in Settings, then retry."
    case retryTracking = "Retry hand tracking."
}

nonisolated enum TrackingRuntimeEffect: Hashable, Sendable {
    case clearTrackingData
    case cancelListeners
    case stopSession
    case prepareProviders
    case bufferSample
    case admitSample
}

nonisolated struct TrackingRuntimeSnapshot: Equatable, Sendable {
    let state: TrackingRuntimeState
    let providerGeneration: UInt64
    let rejectionReason: TrackingRuntimeRejectionReason?
    let acceptedSampleStreak: Int
    let recoveryInstruction: TrackingRecoveryInstruction
    let lastAcceptedAcquisitionTimestamps: [BodySide: TimeInterval]

    nonisolated static let initial = TrackingRuntimeSnapshot(
        state: .idle,
        providerGeneration: 0,
        rejectionReason: nil,
        acceptedSampleStreak: 0,
        recoveryInstruction: .none,
        lastAcceptedAcquisitionTimestamps: [:]
    )
}

nonisolated enum TrackingRuntimeEvent: Sendable {
    case startRequested
    case retryRequested
    case authorizationCompleted(
        generation: UInt64,
        status: TrackingRuntimeAuthorizationStatus
    )
    case authorizationChanged(
        generation: UInt64,
        status: TrackingRuntimeAuthorizationStatus
    )
    case unsupported(generation: UInt64)
    case sessionStarted(generation: UInt64, worldTrackingAvailable: Bool)
    case startFailed(generation: UInt64, message: String)
    case startCancelled(generation: UInt64)
    case providerStateChanged(
        generation: UInt64,
        state: TrackingRuntimeProviderState,
        errorDescription: String?
    )
    case sampleAccepted(
        generation: UInt64,
        side: BodySide,
        acquisitionTimestamp: TimeInterval,
        receiptTimestamp: TimeInterval
    )
    case sampleRejected(generation: UInt64, reason: TrackingRuntimeRejectionReason)
    case stopRequested
}

nonisolated struct TrackingRuntimeTransition: Equatable, Sendable {
    let snapshot: TrackingRuntimeSnapshot
    let effects: Set<TrackingRuntimeEffect>
}

/// Pure lifecycle and sample-admission state machine. It deliberately has no ARKit dependency so
/// tracking loss, stale callbacks, and reacquisition can be verified without hardware.
nonisolated enum TrackingRuntimeReducer {
    nonisolated static let requiredAcceptedSampleStreak = 3
    nonisolated static let maximumAcquisitionAge: TimeInterval = 0.1
    nonisolated static let maximumSampleGap: TimeInterval = 0.20

    nonisolated static func isFreshForRecovery(
        acquisitionTimestamp: TimeInterval,
        at receiptTimestamp: TimeInterval
    ) -> Bool {
        guard acquisitionTimestamp.isFinite,
              receiptTimestamp.isFinite,
              acquisitionTimestamp >= 0,
              receiptTimestamp >= acquisitionTimestamp else { return false }
        return receiptTimestamp - acquisitionTimestamp <= maximumAcquisitionAge
    }

    nonisolated static func reduce(
        _ snapshot: TrackingRuntimeSnapshot,
        event: TrackingRuntimeEvent
    ) -> TrackingRuntimeTransition {
        switch event {
        case .startRequested:
            guard [.idle, .stopped, .failed].contains(snapshot.state) else {
                return unchanged(snapshot)
            }
            return prepareStart(from: snapshot)

        case .retryRequested:
            guard [.stopped, .failed].contains(snapshot.state) else {
                return unchanged(snapshot)
            }
            return prepareStart(from: snapshot)

        case let .authorizationCompleted(generation, status):
            guard generation == snapshot.providerGeneration,
                  snapshot.state == .requestingAuthorization else {
                return unchanged(snapshot)
            }
            switch status {
            case .allowed:
                return transition(
                    state: .starting,
                    generation: generation
                )
            case .notDetermined, .denied:
                return terminalFailure(
                    from: snapshot,
                    reason: .authorizationDenied,
                    recovery: .reviewAuthorization
                )
            }

        case let .authorizationChanged(generation, status):
            guard generation == snapshot.providerGeneration else {
                return unchanged(snapshot)
            }
            guard status != .allowed else { return unchanged(snapshot) }
            return terminalFailure(
                from: snapshot,
                reason: .authorizationRevoked,
                recovery: .reviewAuthorization
            )

        case let .unsupported(generation):
            guard generation == snapshot.providerGeneration else {
                return unchanged(snapshot)
            }
            return terminalFailure(
                from: snapshot,
                reason: .unsupported,
                recovery: .none
            )

        case let .sessionStarted(generation, worldTrackingAvailable):
            guard generation == snapshot.providerGeneration,
                  snapshot.state == .starting else {
                return unchanged(snapshot)
            }
            if worldTrackingAvailable {
                return transition(state: .running, generation: generation)
            }
            return terminalFailure(
                from: snapshot,
                reason: .worldTrackingUnavailable,
                recovery: .none
            )

        case let .startFailed(generation, message):
            guard generation == snapshot.providerGeneration else {
                return unchanged(snapshot)
            }
            return terminalFailure(
                from: snapshot,
                reason: .sessionFailed(message: message),
                recovery: .retryTracking
            )

        case let .startCancelled(generation):
            guard generation == snapshot.providerGeneration,
                  [.requestingAuthorization, .starting].contains(snapshot.state) else {
                return unchanged(snapshot)
            }
            return stopped(from: snapshot)

        case let .providerStateChanged(generation, providerState, errorDescription):
            guard generation == snapshot.providerGeneration else {
                return unchanged(snapshot)
            }
            if let errorDescription {
                return terminalFailure(
                    from: snapshot,
                    reason: .providerFailed(message: errorDescription),
                    recovery: .retryTracking
                )
            }
            switch providerState {
            case .initialized:
                return unchanged(snapshot)
            case .running:
                guard snapshot.state == .paused else { return unchanged(snapshot) }
                return transition(
                    state: .degraded,
                    generation: generation,
                    reason: .reacquiring,
                    recovery: .keepHandsVisible
                )
            case .paused:
                guard [.starting, .running, .degraded].contains(snapshot.state) else {
                    return unchanged(snapshot)
                }
                return transition(
                    state: .paused,
                    generation: generation,
                    reason: .providerPaused,
                    recovery: .waitForProvider,
                    effects: [.clearTrackingData]
                )
            case .stopped:
                return terminalFailure(
                    from: snapshot,
                    reason: .providerStopped,
                    recovery: .retryTracking
                )
            }

        case let .sampleRejected(generation, reason):
            guard generation == snapshot.providerGeneration,
                  [.running, .degraded].contains(snapshot.state) else {
                return unchanged(snapshot)
            }
            return transition(
                state: .degraded,
                generation: generation,
                reason: reason,
                recovery: .keepHandsVisible,
                effects: [.clearTrackingData]
            )

        case let .sampleAccepted(
            generation,
            side,
            acquisitionTimestamp,
            receiptTimestamp
        ):
            guard generation == snapshot.providerGeneration,
                  [.running, .degraded].contains(snapshot.state) else {
                return unchanged(snapshot)
            }
            guard isFreshForRecovery(
                acquisitionTimestamp: acquisitionTimestamp,
                at: receiptTimestamp
            ) else {
                guard acquisitionTimestamp.isFinite,
                      receiptTimestamp.isFinite,
                      acquisitionTimestamp >= 0,
                      receiptTimestamp >= acquisitionTimestamp else {
                    return sampleFailure(
                        snapshot,
                        reason: .invalidTimestamp
                    )
                }
                let age = receiptTimestamp - acquisitionTimestamp
                return sampleFailure(
                    snapshot,
                    reason: .staleSample(age: age)
                )
            }

            let timestamps = snapshot.lastAcceptedAcquisitionTimestamps
            if let mostRecent = timestamps.values.max() {
                let interval = acquisitionTimestamp - mostRecent
                guard interval >= 0 else {
                    return sampleFailure(snapshot, reason: .nonMonotonicSample(side: side))
                }
                guard interval <= maximumSampleGap else {
                    return sampleFailure(snapshot, reason: .sampleGap(duration: interval))
                }
            }

            if let previous = timestamps[side] {
                let interval = acquisitionTimestamp - previous
                guard interval > 0 else {
                    return sampleFailure(snapshot, reason: .nonMonotonicSample(side: side))
                }
                guard interval <= maximumSampleGap else {
                    return sampleFailure(snapshot, reason: .sampleGap(duration: interval))
                }
            }

            var updatedTimestamps = timestamps
            updatedTimestamps[side] = acquisitionTimestamp
            let streak = min(
                snapshot.acceptedSampleStreak + 1,
                requiredAcceptedSampleStreak
            )
            let hasReacquired = snapshot.state == .degraded
                && streak >= requiredAcceptedSampleStreak
            let effect: TrackingRuntimeEffect = snapshot.state == .degraded && !hasReacquired
                ? .bufferSample
                : .admitSample
            return TrackingRuntimeTransition(
                snapshot: TrackingRuntimeSnapshot(
                    state: hasReacquired ? .running : snapshot.state,
                    providerGeneration: generation,
                    rejectionReason: hasReacquired ? nil : snapshot.rejectionReason,
                    acceptedSampleStreak: streak,
                    recoveryInstruction: hasReacquired ? .none : snapshot.recoveryInstruction,
                    lastAcceptedAcquisitionTimestamps: updatedTimestamps
                ),
                effects: [effect]
            )

        case .stopRequested:
            guard snapshot.state != .stopped else { return unchanged(snapshot) }
            return stopped(from: snapshot)
        }
    }

    nonisolated private static func stopped(
        from snapshot: TrackingRuntimeSnapshot
    ) -> TrackingRuntimeTransition {
        TrackingRuntimeTransition(
            snapshot: TrackingRuntimeSnapshot(
                state: .stopped,
                providerGeneration: nextGeneration(after: snapshot.providerGeneration),
                rejectionReason: nil,
                acceptedSampleStreak: 0,
                recoveryInstruction: .none,
                lastAcceptedAcquisitionTimestamps: [:]
            ),
            effects: [.clearTrackingData, .cancelListeners, .stopSession]
        )
    }

    nonisolated private static func prepareStart(
        from snapshot: TrackingRuntimeSnapshot
    ) -> TrackingRuntimeTransition {
        TrackingRuntimeTransition(
            snapshot: TrackingRuntimeSnapshot(
                state: .requestingAuthorization,
                providerGeneration: nextGeneration(after: snapshot.providerGeneration),
                rejectionReason: nil,
                acceptedSampleStreak: 0,
                recoveryInstruction: .none,
                lastAcceptedAcquisitionTimestamps: [:]
            ),
            effects: [.clearTrackingData, .cancelListeners, .stopSession, .prepareProviders]
        )
    }

    nonisolated private static func terminalFailure(
        from snapshot: TrackingRuntimeSnapshot,
        reason: TrackingRuntimeRejectionReason,
        recovery: TrackingRecoveryInstruction
    ) -> TrackingRuntimeTransition {
        TrackingRuntimeTransition(
            snapshot: TrackingRuntimeSnapshot(
                state: .failed,
                providerGeneration: nextGeneration(after: snapshot.providerGeneration),
                rejectionReason: reason,
                acceptedSampleStreak: 0,
                recoveryInstruction: recovery,
                lastAcceptedAcquisitionTimestamps: [:]
            ),
            effects: [.clearTrackingData, .cancelListeners, .stopSession]
        )
    }

    nonisolated private static func sampleFailure(
        _ snapshot: TrackingRuntimeSnapshot,
        reason: TrackingRuntimeRejectionReason
    ) -> TrackingRuntimeTransition {
        transition(
            state: .degraded,
            generation: snapshot.providerGeneration,
            reason: reason,
            recovery: .keepHandsVisible,
            effects: [.clearTrackingData]
        )
    }

    nonisolated private static func transition(
        state: TrackingRuntimeState,
        generation: UInt64,
        reason: TrackingRuntimeRejectionReason? = nil,
        streak: Int = 0,
        recovery: TrackingRecoveryInstruction = .none,
        timestamps: [BodySide: TimeInterval] = [:],
        effects: Set<TrackingRuntimeEffect> = []
    ) -> TrackingRuntimeTransition {
        TrackingRuntimeTransition(
            snapshot: TrackingRuntimeSnapshot(
                state: state,
                providerGeneration: generation,
                rejectionReason: reason,
                acceptedSampleStreak: streak,
                recoveryInstruction: recovery,
                lastAcceptedAcquisitionTimestamps: timestamps
            ),
            effects: effects
        )
    }

    nonisolated private static func unchanged(
        _ snapshot: TrackingRuntimeSnapshot
    ) -> TrackingRuntimeTransition {
        TrackingRuntimeTransition(snapshot: snapshot, effects: [])
    }

    nonisolated private static func nextGeneration(after generation: UInt64) -> UInt64 {
        generation &+ 1
    }
}

nonisolated enum TrackedFistState: String, Codable, Sendable {
    case open
    case closed
    case uncertain
}

/// Deterministic hand-shape evidence. The ratios are normalized by palm width so calibration and
/// validation do not silently favor one hand size. An unavailable finger chain is omitted; fewer
/// than three complete chains can never claim an open or closed fist.
nonisolated enum FistStateClassifier {
    static func classify(
        fingertipToKnuckleRatios ratios: [Float],
        closedPrototype: Float? = nil,
        openPrototype: Float? = nil
    ) -> TrackedFistState {
        let valid = ratios.filter { $0.isFinite && $0 >= 0 }
        guard valid.count >= 3 else { return .uncertain }
        let mean = valid.reduce(0, +) / Float(valid.count)

        if let closedPrototype, let openPrototype,
           closedPrototype.isFinite, openPrototype.isFinite,
           closedPrototype < openPrototype {
            let span = openPrototype - closedPrototype
            if mean <= closedPrototype + span * 0.35 { return .closed }
            if mean >= closedPrototype + span * 0.65 { return .open }
            return .uncertain
        }

        if mean <= 1.25 { return .closed }
        if mean >= 1.55 { return .open }
        return .uncertain
    }
}

/// Pure hand-geometry helpers kept separate from ARKit so partial-joint behavior is testable.
/// A curled fist often hides fingertips from the cameras while its knuckles remain stable; fist
/// position must therefore not depend on every finger having a visible tip.
nonisolated enum HandObservationGeometry {
    static func fistCenter(knuckles: [SIMD3<Float>]) -> SIMD3<Float>? {
        let valid = knuckles.filter(\.isFinite)
        guard valid.count >= 3 else { return nil }
        return valid.reduce(SIMD3<Float>.zero, +) / Float(valid.count)
    }

    static func meanClosureRatio(_ ratios: [Float]) -> Float? {
        let valid = ratios.filter { $0.isFinite && $0 >= 0 }
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Float(valid.count)
    }
}

/// Tracks both hands and the device (head) via ARKit.
///
/// Exposes two levels of detail:
/// - `leftFistPosition` / `rightFistPosition` / `nearestFistPosition(to:)` — the simple fist API
///   that Reactive Strike uses for hit tests.
/// - `leftHand` / `rightHand` / `deviceTransform` — the full joint data Aura Punch needs to
///   reconstruct an arm.
@Observable
final class HandTrackingService {
    private(set) var runtimeSnapshot = TrackingRuntimeSnapshot.initial
    private(set) var statusMessage = "Hand tracking idle"
    private(set) var continuityEpoch: UInt64 = 0

    private(set) var leftHand: HandObservation?
    private(set) var rightHand: HandObservation?
    private var reacquisitionCandidates: [BodySide: HandObservation] = [:]
    private var fistPrototypes: [BodySide: (closed: Float, open: Float)] = [:]
    private var attemptCaptureCount = 0

    var runtimeState: TrackingRuntimeState { runtimeSnapshot.state }
    var providerGeneration: UInt64 { runtimeSnapshot.providerGeneration }
    var rejectionReason: TrackingRuntimeRejectionReason? { runtimeSnapshot.rejectionReason }
    var acceptedSampleStreak: Int { runtimeSnapshot.acceptedSampleStreak }
    var recoveryInstruction: TrackingRecoveryInstruction {
        runtimeSnapshot.recoveryInstruction
    }

    /// Whether a provider generation is active. Degraded and paused generations remain active but
    /// expose no samples until the reducer admits three fresh reacquisition updates.
    var isRunning: Bool {
        [.running, .degraded, .paused].contains(runtimeState)
    }

    /// Marks partial capture evidence so fail-closed resets can invalidate it immediately.
    func beginAttemptCapture() {
        attemptCaptureCount += 1
    }

    func endAttemptCapture() {
        attemptCaptureCount = max(0, attemptCaptureCount - 1)
    }

    /// Head pose in world space, from the device anchor. `nil` until world tracking settles.
    private(set) var deviceTransform: simd_float4x4?
    private(set) var deviceTimestamp: TimeInterval?

    var leftFistPosition: SIMD3<Float>? { observation(for: .left)?.fistPosition }
    var rightFistPosition: SIMD3<Float>? { observation(for: .right)?.fistPosition }

    /// True once both hands *and* the head have produced at least one usable sample. Aura Punch
    /// needs all three before it can place a shoulder, so it gates its countdown on this.
    var hasFullUpperBodyTracking: Bool {
        deviceTransform != nil && (leftHand != nil || rightHand != nil)
    }

    func observation(for side: BodySide) -> HandObservation? {
        switch side {
        case .left: leftHand
        case .right: rightHand
        }
    }

    func freshObservation(for side: BodySide, maxAge: TimeInterval = 0.1) -> HandObservation? {
        guard maxAge.isFinite, maxAge >= 0,
              let observation = observation(for: side) else { return nil }
        let age = CACurrentMediaTime() - observation.acquisitionTimestamp
        guard age >= 0, age <= maxAge else { return nil }
        return observation
    }

    func setFistCalibration(side: BodySide, closed: Float, open: Float) {
        guard closed.isFinite, open.isFinite, closed < open else { return }
        fistPrototypes[side] = (closed, open)
    }

    /// Rebuilt on every `start()` — see the note there. Never make these `let`.
    private var session = ARKitSession()
    private var handTracking = HandTrackingProvider()
    private var worldTracking = WorldTrackingProvider()
    private var anchorUpdateTask: Task<Void, Never>?
    private var sessionEventTask: Task<Void, Never>?
    private let startupIsCancelled: @MainActor @Sendable () -> Bool

    init(
        startupIsCancelled: @escaping @MainActor @Sendable () -> Bool = {
            Task.isCancelled
        }
    ) {
        self.startupIsCancelled = startupIsCancelled
    }

    /// Closest tracked fist tip to a world-space point, if any hand is tracked.
    func nearestFistPosition(to point: SIMD3<Float>) -> SIMD3<Float>? {
        let candidates = [leftFistPosition, rightFistPosition].compactMap { $0 }
        guard !candidates.isEmpty else { return nil }
        return candidates.min(by: { distance($0, point) < distance($1, point) })
    }

    func start() async {
        await start(with: .startRequested)
    }

    func retry() async {
        await start(with: .retryRequested)
    }

    func stop() {
        apply(TrackingRuntimeReducer.reduce(runtimeSnapshot, event: .stopRequested))
    }

    private func start(with event: TrackingRuntimeEvent) async {
        let preparation = TrackingRuntimeReducer.reduce(runtimeSnapshot, event: event)
        let shouldPrepareProviders = preparation.effects.contains(.prepareProviders)
        apply(preparation)
        guard shouldPrepareProviders else { return }

        let generation = providerGeneration
        guard !startupIsCancelled() else {
            apply(
                TrackingRuntimeReducer.reduce(
                    runtimeSnapshot,
                    event: .startCancelled(generation: generation)
                )
            )
            return
        }
        guard HandTrackingProvider.isSupported else {
            apply(
                TrackingRuntimeReducer.reduce(
                    runtimeSnapshot,
                    event: .unsupported(generation: generation)
                )
            )
            return
        }

        // Providers are single-use after stop. Every accepted start/retry owns fresh instances.
        let newSession = ARKitSession()
        let newHandTracking = HandTrackingProvider()
        let newWorldTracking = WorldTrackingProvider()
        session = newSession
        handTracking = newHandTracking
        worldTracking = newWorldTracking

        let authorization = await newSession.requestAuthorization(for: [.handTracking])
        guard !cancelStartIfNeeded(session: newSession, generation: generation) else {
            return
        }
        guard generation == providerGeneration,
              runtimeState == .requestingAuthorization else {
            newSession.stop()
            return
        }

        apply(
            TrackingRuntimeReducer.reduce(
                runtimeSnapshot,
                event: .authorizationCompleted(
                    generation: generation,
                    status: runtimeAuthorizationStatus(authorization[.handTracking])
                )
            )
        )
        guard generation == providerGeneration, runtimeState == .starting else { return }

        startSessionEventListener(
            on: newSession,
            handProvider: newHandTracking,
            worldProvider: newWorldTracking,
            generation: generation
        )

        let worldTrackingAvailable = WorldTrackingProvider.isSupported
        do {
            if worldTrackingAvailable {
                try await newSession.run([newHandTracking, newWorldTracking])
            } else {
                try await newSession.run([newHandTracking])
            }
            guard !cancelStartIfNeeded(session: newSession, generation: generation) else {
                return
            }
            guard generation == providerGeneration, runtimeState == .starting else {
                newSession.stop()
                return
            }

            apply(
                TrackingRuntimeReducer.reduce(
                    runtimeSnapshot,
                    event: .sessionStarted(
                        generation: generation,
                        worldTrackingAvailable: worldTrackingAvailable
                    )
                )
            )
            guard generation == providerGeneration else { return }
            startAnchorUpdateListener(on: newHandTracking, generation: generation)
        } catch {
            guard !cancelStartIfNeeded(session: newSession, generation: generation) else {
                return
            }
            guard generation == providerGeneration else {
                newSession.stop()
                return
            }
            apply(
                TrackingRuntimeReducer.reduce(
                    runtimeSnapshot,
                    event: .startFailed(
                        generation: generation,
                        message: error.localizedDescription
                    )
                )
            )
        }
    }

    private func cancelStartIfNeeded(
        session: ARKitSession,
        generation: UInt64
    ) -> Bool {
        guard startupIsCancelled() else { return false }
        session.stop()
        apply(
            TrackingRuntimeReducer.reduce(
                runtimeSnapshot,
                event: .startCancelled(generation: generation)
            )
        )
        return true
    }

    /// Anchor and session events are independent streams and therefore own independent tasks.
    private func startAnchorUpdateListener(
        on provider: HandTrackingProvider,
        generation: UInt64
    ) {
        anchorUpdateTask?.cancel()
        anchorUpdateTask = Task { [weak self] in
            for await update in provider.anchorUpdates {
                guard !Task.isCancelled, let self else { break }
                guard generation == self.providerGeneration else { break }
                self.handle(
                    update,
                    generation: generation,
                    receiptTimestamp: CACurrentMediaTime()
                )
            }
        }
    }

    private func startSessionEventListener(
        on session: ARKitSession,
        handProvider: HandTrackingProvider,
        worldProvider: WorldTrackingProvider,
        generation: UInt64
    ) {
        sessionEventTask?.cancel()
        sessionEventTask = Task { [weak self] in
            for await event in session.events {
                guard !Task.isCancelled, let self else { break }
                guard generation == self.providerGeneration else { break }
                self.handle(
                    event,
                    handProvider: handProvider,
                    worldProvider: worldProvider,
                    generation: generation
                )
            }
        }
    }

    private func handle(
        _ event: ARKitSession.Event,
        handProvider: HandTrackingProvider,
        worldProvider: WorldTrackingProvider,
        generation: UInt64
    ) {
        guard generation == providerGeneration else { return }
        switch event {
        case let .authorizationChanged(type, status):
            guard type == .handTracking else { return }
            apply(
                TrackingRuntimeReducer.reduce(
                    runtimeSnapshot,
                    event: .authorizationChanged(
                        generation: generation,
                        status: runtimeAuthorizationStatus(status)
                    )
                )
            )

        case let .dataProviderStateChanged(dataProviders, newState, error):
            let activeProviderIDs: Set<ObjectIdentifier> = [
                ObjectIdentifier(handProvider),
                ObjectIdentifier(worldProvider)
            ]
            guard dataProviders.contains(where: {
                activeProviderIDs.contains(ObjectIdentifier($0))
            }) else { return }
            apply(
                TrackingRuntimeReducer.reduce(
                    runtimeSnapshot,
                    event: .providerStateChanged(
                        generation: generation,
                        state: runtimeProviderState(newState),
                        errorDescription: error?.localizedDescription
                    )
                )
            )

        @unknown default:
            break
        }
    }

    private func handle(
        _ update: AnchorUpdate<HandAnchor>,
        generation: UInt64,
        receiptTimestamp: TimeInterval
    ) {
        let anchor = update.anchor
        guard let side = bodySide(for: anchor.chirality) else { return }
        guard update.event != .removed else {
            reject(.anchorRemoved(side: side), generation: generation)
            return
        }
        guard anchor.isTracked else {
            reject(.untracked(side: side), generation: generation)
            return
        }
        guard let skeleton = anchor.handSkeleton else {
            reject(.missingSkeleton(side: side), generation: generation)
            return
        }

        // Xcode 27's Anchor protocol exposes this ARKit acquisition timestamp. Callback receipt
        // time is intentionally not substituted for it.
        let acquisitionTimestamp = anchor.timestamp
        guard acquisitionTimestamp.isFinite,
              receiptTimestamp.isFinite,
              acquisitionTimestamp >= 0,
              receiptTimestamp >= acquisitionTimestamp else {
            reject(.invalidTimestamp, generation: generation)
            return
        }
        let originFromAnchor = anchor.originFromAnchorTransform

        func worldTransform(_ name: HandSkeleton.JointName) -> simd_float4x4? {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return nil }
            return originFromAnchor * joint.anchorFromJointTransform
        }

        guard let wristTransform = worldTransform(.wrist) else {
            reject(
                .missingRequiredJoint(side: side, joint: "wrist"),
                generation: generation
            )
            return
        }

        guard worldTracking.state == .running,
              let deviceAnchor = worldTracking.queryDeviceAnchor(
                atTimestamp: acquisitionTimestamp
              ),
              deviceAnchor.isTracked else {
            reject(.missingDevicePose, generation: generation)
            return
        }
        let matchedDeviceTransform = deviceAnchor.originFromAnchorTransform

        let fingerChains: [(HandSkeleton.JointName, HandSkeleton.JointName)] = [
            (.indexFingerKnuckle, .indexFingerTip),
            (.middleFingerKnuckle, .middleFingerTip),
            (.ringFingerKnuckle, .ringFingerTip),
            (.littleFingerKnuckle, .littleFingerTip)
        ]
        let knuckles = fingerChains.compactMap { knuckleName, _ in
            worldTransform(knuckleName)?.translation
        }.filter(\.isFinite)

        // Fingertips are optional: a curled fist often occludes them. Wrist is the only required
        // joint for this raw observation; missing optional chains make fist state uncertain.
        let fistTipCandidates: [HandSkeleton.JointName] = [
            .middleFingerTip,
            .indexFingerTip,
            .wrist
        ]
        let fistPosition: SIMD3<Float>
        if let fistCenter = HandObservationGeometry.fistCenter(knuckles: knuckles) {
            fistPosition = fistCenter
        } else if let tipTransform = fistTipCandidates.lazy.compactMap(worldTransform).first {
            fistPosition = tipTransform.translation
        } else {
            fistPosition = wristTransform.translation
        }

        let trackedChains = fingerChains.compactMap {
            knuckleName,
            tipName -> (SIMD3<Float>, SIMD3<Float>)? in
            guard let knuckle = worldTransform(knuckleName)?.translation,
                  let tip = worldTransform(tipName)?.translation,
                  knuckle.isFinite,
                  tip.isFinite else { return nil }
            return (knuckle, tip)
        }
        let indexKnuckle = worldTransform(.indexFingerKnuckle)?.translation
        let littleKnuckle = worldTransform(.littleFingerKnuckle)?.translation
        let palmWidth = indexKnuckle.flatMap { index in
            littleKnuckle.map { max(distance(index, $0), 0.001) }
        } ?? max(
            distance(
                knuckles.first ?? wristTransform.translation,
                knuckles.last ?? wristTransform.translation
            ),
            0.001
        )
        let ratios = trackedChains.map { distance($0.0, $0.1) / palmWidth }
        let closureRatio = HandObservationGeometry.meanClosureRatio(ratios) ?? 0
        let prototype = fistPrototypes[side]
        let wristOrientation = simd_quatf(rotationMatrix(wristTransform))
        let elbowHint = worldTransform(.forearmArm)?.translation

        guard wristTransform.isFinite,
              wristOrientation.vector.isFinite,
              fistPosition.isFinite,
              closureRatio.isFinite,
              elbowHint?.isFinite != false,
              matchedDeviceTransform.isFinite,
              simd_length(matchedDeviceTransform.translation) > 0.01 else {
            reject(.nonFiniteSample, generation: generation)
            return
        }

        let observation = HandObservation(
            side: side,
            wristPosition: wristTransform.translation,
            wristOrientation: wristOrientation,
            elbowHint: elbowHint,
            fistPosition: fistPosition,
            fistState: FistStateClassifier.classify(
                fingertipToKnuckleRatios: ratios,
                closedPrototype: prototype?.closed,
                openPrototype: prototype?.open
            ),
            fistClosureRatio: closureRatio,
            acquisitionTimestamp: acquisitionTimestamp,
            receiptTimestamp: receiptTimestamp,
            deviceTransform: matchedDeviceTransform,
            deviceTimestamp: acquisitionTimestamp
        )

        let wasRecovering = runtimeState == .degraded
        let admission = TrackingRuntimeReducer.reduce(
            runtimeSnapshot,
            event: .sampleAccepted(
                generation: generation,
                side: side,
                acquisitionTimestamp: acquisitionTimestamp,
                receiptTimestamp: receiptTimestamp
            )
        )
        apply(admission)
        if admission.effects.contains(.bufferSample) {
            reacquisitionCandidates[side] = observation
            return
        }
        guard admission.effects.contains(.admitSample),
              generation == providerGeneration else { return }

        if wasRecovering {
            reacquisitionCandidates[side] = observation
            for candidate in reacquisitionCandidates.values where
                TrackingRuntimeReducer.isFreshForRecovery(
                    acquisitionTimestamp: candidate.acquisitionTimestamp,
                    at: receiptTimestamp
                ) {
                publish(candidate)
            }
            reacquisitionCandidates.removeAll()
        } else {
            publish(observation)
        }
        deviceTransform = matchedDeviceTransform
        deviceTimestamp = acquisitionTimestamp
    }

    private func reject(
        _ reason: TrackingRuntimeRejectionReason,
        generation: UInt64
    ) {
        apply(
            TrackingRuntimeReducer.reduce(
                runtimeSnapshot,
                event: .sampleRejected(generation: generation, reason: reason)
            )
        )
    }

    private func apply(_ transition: TrackingRuntimeTransition) {
        runtimeSnapshot = transition.snapshot
        if transition.effects.contains(.clearTrackingData) {
            clearTrackingData()
        }
        if transition.effects.contains(.cancelListeners) {
            cancelListenerTasks()
        }
        if transition.effects.contains(.stopSession) {
            session.stop()
        }
        statusMessage = status(for: transition.snapshot)
    }

    private func cancelListenerTasks() {
        anchorUpdateTask?.cancel()
        anchorUpdateTask = nil
        sessionEventTask?.cancel()
        sessionEventTask = nil
    }

    private func clearTrackingData() {
        continuityEpoch &+= 1
        leftHand = nil
        rightHand = nil
        reacquisitionCandidates.removeAll()
        deviceTransform = nil
        deviceTimestamp = nil
        fistPrototypes.removeAll()
        attemptCaptureCount = 0
    }

    private func publish(_ observation: HandObservation) {
        switch observation.side {
        case .left: leftHand = observation
        case .right: rightHand = observation
        }
    }

    private func rotationMatrix(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }

    private func bodySide(for chirality: HandAnchor.Chirality) -> BodySide? {
        switch chirality {
        case .left: .left
        case .right: .right
        @unknown default: nil
        }
    }

    private func runtimeAuthorizationStatus(
        _ status: ARKitSession.AuthorizationStatus?
    ) -> TrackingRuntimeAuthorizationStatus {
        switch status {
        case .allowed: .allowed
        case .notDetermined: .notDetermined
        case .denied, nil: .denied
        @unknown default: .denied
        }
    }

    private func runtimeProviderState(
        _ state: DataProviderState
    ) -> TrackingRuntimeProviderState {
        switch state {
        case .initialized: .initialized
        case .running: .running
        case .paused: .paused
        case .stopped: .stopped
        @unknown default: .stopped
        }
    }

    private func status(for snapshot: TrackingRuntimeSnapshot) -> String {
        switch snapshot.state {
        case .idle:
            "Hand tracking idle"
        case .requestingAuthorization:
            "Requesting hand tracking permission"
        case .starting:
            "Starting hand tracking"
        case .running:
            "Hand tracking active"
        case .degraded:
            "Hand tracking degraded: \(reasonDescription(snapshot.rejectionReason))"
        case .paused:
            "Hand tracking paused: \(reasonDescription(snapshot.rejectionReason))"
        case .stopped:
            "Hand tracking stopped"
        case .failed:
            "Hand tracking failed: \(reasonDescription(snapshot.rejectionReason))"
        }
    }

    private func reasonDescription(_ reason: TrackingRuntimeRejectionReason?) -> String {
        switch reason {
        case .unsupported:
            "not supported on this device"
        case .authorizationDenied:
            "permission denied"
        case .authorizationRevoked:
            "permission was revoked"
        case .providerPaused:
            "the provider paused"
        case .providerStopped:
            "the provider stopped"
        case let .providerFailed(message), let .sessionFailed(message):
            message
        case .worldTrackingUnavailable:
            "head tracking is unavailable"
        case .reacquiring:
            "reacquiring fresh samples"
        case let .anchorRemoved(side):
            "\(side.rawValue) hand was removed"
        case let .untracked(side):
            "\(side.rawValue) hand is not tracked"
        case let .missingSkeleton(side):
            "\(side.rawValue) hand skeleton is unavailable"
        case let .missingRequiredJoint(side, joint):
            "\(side.rawValue) \(joint) is unavailable"
        case .missingDevicePose:
            "a matching head pose is unavailable"
        case .nonFiniteSample:
            "ARKit returned invalid geometry"
        case .invalidTimestamp:
            "ARKit returned an invalid timestamp"
        case let .nonMonotonicSample(side):
            "\(side.rawValue) hand time moved backwards"
        case .staleSample:
            "the acquired sample was stale"
        case .sampleGap:
            "the acquired sample followed a tracking gap"
        case nil:
            "unknown tracking state"
        }
    }
}

extension simd_float4x4 {
    /// Translation component (the 4th column).
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }

    nonisolated var isFinite: Bool {
        columns.0.isFinite
            && columns.1.isFinite
            && columns.2.isFinite
            && columns.3.isFinite
    }
}

extension SIMD3 where Scalar == Float {
    nonisolated var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

extension SIMD4 where Scalar == Float {
    nonisolated var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }
}

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

    /// `CACurrentMediaTime()` when this sample was produced.
    var timestamp: TimeInterval
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

/// Tracks both hands and the device (head) via ARKit.
///
/// Exposes two levels of detail:
/// - `leftFistPosition` / `rightFistPosition` / `nearestFistPosition(to:)` — the simple fist API
///   that Reactive Strike uses for hit tests.
/// - `leftHand` / `rightHand` / `deviceTransform` — the full joint data Aura Punch needs to
///   reconstruct an arm.
@Observable
final class HandTrackingService {
    private(set) var isRunning = false
    private(set) var statusMessage = "Hand tracking idle"

    private(set) var leftHand: HandObservation?
    private(set) var rightHand: HandObservation?

    /// Last good observation per side, kept briefly after ARKit drops the anchor so cheek-height
    /// guard in the headset's blind spot does not flicker to nil every frame.
    private var leftHandLastGood: HandObservation?
    private var rightHandLastGood: HandObservation?
    private var leftHandLastGoodTime: TimeInterval = 0
    private var rightHandLastGoodTime: TimeInterval = 0
    private var fistPrototypes: [BodySide: (closed: Float, open: Float)] = [:]

    /// How long to reuse the last tracked pose when ARKit momentarily loses a hand.
    private let staleHandDuration: TimeInterval = 0.2

    /// Head pose in world space, from the device anchor. `nil` until world tracking settles.
    private(set) var deviceTransform: simd_float4x4?

    var leftFistPosition: SIMD3<Float>? { observation(for: .left)?.fistPosition }
    var rightFistPosition: SIMD3<Float>? { observation(for: .right)?.fistPosition }

    /// True once both hands *and* the head have produced at least one usable sample. Aura Punch
    /// needs all three before it can place a shoulder, so it gates its countdown on this.
    var hasFullUpperBodyTracking: Bool {
        deviceTransform != nil && (leftHand != nil || rightHand != nil)
    }

    func observation(for side: BodySide) -> HandObservation? {
        let now = CACurrentMediaTime()
        switch side {
        case .left:
            if let leftHand { return leftHand }
            if now - leftHandLastGoodTime <= staleHandDuration { return leftHandLastGood }
            return nil
        case .right:
            if let rightHand { return rightHand }
            if now - rightHandLastGoodTime <= staleHandDuration { return rightHandLastGood }
            return nil
        }
    }

    func freshObservation(for side: BodySide, maxAge: TimeInterval = 0.1) -> HandObservation? {
        guard let observation = observation(for: side) else { return nil }
        let age = CACurrentMediaTime() - observation.timestamp
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
    private var updateTask: Task<Void, Never>?

    /// Guards against overlapping starts. The immersive scene, Reactive Strike, and Aura Punch all
    /// call `start()`, and the authorization `await` sits between the `isRunning` check and the
    /// flag being set — so without this, two callers arriving together would each stand up their
    /// own session and providers and then fight over the same hands.
    private var isStarting = false

    /// Bumped by every start and every stop, so a start that is still awaiting authorization can
    /// tell that it has been superseded — closing the immersive space right after opening it
    /// would otherwise let the cancelled start finish and mark a stopped session as running.
    private var startGeneration = 0

    /// Closest tracked fist tip to a world-space point, if any hand is tracked.
    func nearestFistPosition(to point: SIMD3<Float>) -> SIMD3<Float>? {
        let candidates = [leftFistPosition, rightFistPosition].compactMap { $0 }
        guard !candidates.isEmpty else { return nil }
        return candidates.min(by: { distance($0, point) < distance($1, point) })
    }

    func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        startGeneration += 1
        let generation = startGeneration
        defer { isStarting = false }

        guard HandTrackingProvider.isSupported else {
            statusMessage = "Hand tracking not supported on this device"
            return
        }

        // ARKit data providers are single-use: once their session stops they enter `.stopped` and
        // can never be run again. The immersive space is opened and closed every time the user
        // backs out of a technique, and closing it stops this service — so reusing the original
        // instances meant tracking worked exactly once per launch and every drill after the first
        // silently received no anchors at all. Build a fresh session and providers each start.
        let session = ARKitSession()
        let handTracking = HandTrackingProvider()
        let worldTracking = WorldTrackingProvider()
        self.session = session
        self.handTracking = handTracking
        self.worldTracking = worldTracking

        let auth = await session.requestAuthorization(for: [.handTracking])
        guard generation == startGeneration else {
            session.stop()
            return
        }
        guard auth[.handTracking] == .allowed else {
            statusMessage = "Hand tracking permission denied"
            return
        }

        do {
            // World tracking needs no separate authorization prompt — only scene reconstruction
            // and plane detection do. It is required here purely for the device (head) anchor.
            if WorldTrackingProvider.isSupported {
                try await session.run([handTracking, worldTracking])
            } else {
                try await session.run([handTracking])
                statusMessage = "World tracking unavailable — Aura Punch needs head tracking"
            }
            guard generation == startGeneration else {
                session.stop()
                return
            }
            isRunning = true
            if statusMessage.isEmpty || !statusMessage.hasPrefix("World tracking") {
                statusMessage = "Hand tracking active"
            }
            startListening(on: handTracking)
        } catch {
            statusMessage = "Failed to start hand tracking: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        // Supersede any start still waiting on authorization so it cannot revive this service
        // after the immersive space has already gone away.
        startGeneration += 1
        updateTask?.cancel()
        updateTask = nil
        session.stop()
        isRunning = false
        leftHand = nil
        rightHand = nil
        leftHandLastGood = nil
        rightHandLastGood = nil
        leftHandLastGoodTime = 0
        rightHandLastGoodTime = 0
        deviceTransform = nil
        fistPrototypes.removeAll()
        statusMessage = "Hand tracking stopped"
    }

    /// Consumes anchor updates from the provider this session was started with.
    ///
    /// Takes the provider explicitly rather than reading the property: a restart replaces it, and
    /// a listener that resolved `self.handTracking` later could attach to the wrong generation.
    private func startListening(on provider: HandTrackingProvider) {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            for await update in provider.anchorUpdates {
                if Task.isCancelled { break }
                guard let self else { break }
                self.handle(update.anchor)
            }
        }
    }

    private func handle(_ anchor: HandAnchor) {
        // Refresh the head pose alongside the hand so both describe the same instant. Sampling
        // them from different frames would shear the estimated shoulder against the tracked
        // wrist, which shows up as the ghost arm swimming when the user turns their head.
        refreshDeviceTransform()

        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            clear(chirality: anchor.chirality)
            return
        }

        let side: BodySide
        switch anchor.chirality {
        case .left: side = .left
        case .right: side = .right
        @unknown default: return
        }

        let originFromAnchor = anchor.originFromAnchorTransform

        /// World-space transform of a joint, or nil when that joint is not currently tracked.
        func worldTransform(_ name: HandSkeleton.JointName) -> simd_float4x4? {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { return nil }
            return originFromAnchor * joint.anchorFromJointTransform
        }

        // The wrist anchors the whole arm chain, so without it there is no usable observation.
        guard let wristTransform = worldTransform(.wrist) else {
            clear(chirality: anchor.chirality)
            return
        }

        let fingerChains: [(HandSkeleton.JointName, HandSkeleton.JointName)] = [
            (.indexFingerKnuckle, .indexFingerTip),
            (.middleFingerKnuckle, .middleFingerTip),
            (.ringFingerKnuckle, .ringFingerTip),
            (.littleFingerKnuckle, .littleFingerTip)
        ]
        let trackedChains = fingerChains.compactMap { knuckleName, tipName -> (SIMD3<Float>, SIMD3<Float>)? in
            guard let knuckle = worldTransform(knuckleName)?.translation,
                  let tip = worldTransform(tipName)?.translation else { return nil }
            return (knuckle, tip)
        }
        guard trackedChains.count >= 3 else {
            clear(chirality: anchor.chirality)
            return
        }
        let knuckles = trackedChains.map(\.0)
        let fistCenter = knuckles.reduce(SIMD3<Float>.zero, +) / Float(knuckles.count)
        let indexKnuckle = worldTransform(.indexFingerKnuckle)?.translation
        let littleKnuckle = worldTransform(.littleFingerKnuckle)?.translation
        let palmWidth = indexKnuckle.flatMap { index in
            littleKnuckle.map { max(distance(index, $0), 0.001) }
        } ?? max(distance(knuckles.first!, knuckles.last!), 0.001)
        let ratios = trackedChains.map { distance($0.0, $0.1) / palmWidth }
        let closureRatio = ratios.reduce(0, +) / Float(ratios.count)
        let prototype = fistPrototypes[side]

        let observation = HandObservation(
            side: side,
            wristPosition: wristTransform.translation,
            wristOrientation: simd_quatf(rotationMatrix(wristTransform)),
            elbowHint: worldTransform(.forearmArm)?.translation,
            fistPosition: fistCenter,
            fistState: FistStateClassifier.classify(
                fingertipToKnuckleRatios: ratios,
                closedPrototype: prototype?.closed,
                openPrototype: prototype?.open
            ),
            fistClosureRatio: closureRatio,
            timestamp: CACurrentMediaTime()
        )

        let now = CACurrentMediaTime()
        switch side {
        case .left:
            leftHand = observation
            leftHandLastGood = observation
            leftHandLastGoodTime = now
        case .right:
            rightHand = observation
            rightHandLastGood = observation
            rightHandLastGoodTime = now
        }
    }

    /// Pulls the current head pose. Unlike hands, the device anchor is a *query*, not a stream.
    private func refreshDeviceTransform() {
        guard worldTracking.state == .running,
              let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              anchor.isTracked
        else {
            deviceTransform = nil
            return
        }

        let transform = anchor.originFromAnchorTransform

        // World tracking is known to emit an identity/zero-translation pose for the first few
        // frames after startup. Accepting one snaps every estimated shoulder to the world
        // origin, which reads on-device as the ghost arms briefly collapsing to the floor.
        let translation = transform.translation
        guard translation.isFinite, simd_length(translation) > 0.01 else {
            deviceTransform = nil
            return
        }

        deviceTransform = transform
    }

    private func clear(chirality: HandAnchor.Chirality) {
        switch chirality {
        case .left:
            leftHand = nil
        case .right:
            rightHand = nil
        @unknown default:
            break
        }
    }

    private func rotationMatrix(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }
}

extension simd_float4x4 {
    /// Translation component (the 4th column).
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }
}

extension SIMD3 where Scalar == Float {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

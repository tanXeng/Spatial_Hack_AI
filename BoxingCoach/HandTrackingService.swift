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
    /// is better than CLAUDE.md assumed. Treat it as a strong hint rather than ground truth: it
    /// is extrapolated from the hand, so it degrades as the elbow leaves the cameras' view —
    /// exactly what happens at the end of a fully extended punch. `ArmPoseSolver` falls back to
    /// IK when this is `nil`, and blends toward IK when it disagrees with the arm's known length.
    var elbowHint: SIMD3<Float>?

    /// The point used as "the fist" for hit tests and scoring.
    var fistPosition: SIMD3<Float>

    /// `CACurrentMediaTime()` when this sample was produced.
    var timestamp: TimeInterval
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

    /// Head pose in world space, from the device anchor. `nil` until world tracking settles.
    private(set) var deviceTransform: simd_float4x4?

    var leftFistPosition: SIMD3<Float>? { leftHand?.fistPosition }
    var rightFistPosition: SIMD3<Float>? { rightHand?.fistPosition }

    /// True once both hands *and* the head have produced at least one usable sample. Aura Punch
    /// needs all three before it can place a shoulder, so it gates its countdown on this.
    var hasFullUpperBodyTracking: Bool {
        deviceTransform != nil && (leftHand != nil || rightHand != nil)
    }

    func observation(for side: BodySide) -> HandObservation? {
        side == .left ? leftHand : rightHand
    }

    private let session = ARKitSession()
    private let handTracking = HandTrackingProvider()
    private let worldTracking = WorldTrackingProvider()
    private var updateTask: Task<Void, Never>?

    /// Closest tracked fist tip to a world-space point, if any hand is tracked.
    func nearestFistPosition(to point: SIMD3<Float>) -> SIMD3<Float>? {
        let candidates = [leftFistPosition, rightFistPosition].compactMap { $0 }
        guard !candidates.isEmpty else { return nil }
        return candidates.min(by: { distance($0, point) < distance($1, point) })
    }

    func start() async {
        guard !isRunning else { return }

        guard HandTrackingProvider.isSupported else {
            statusMessage = "Hand tracking not supported on this device"
            return
        }

        let auth = await session.requestAuthorization(for: [.handTracking])
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
            isRunning = true
            if statusMessage.isEmpty || !statusMessage.hasPrefix("World tracking") {
                statusMessage = "Hand tracking active"
            }
            startListening()
        } catch {
            statusMessage = "Failed to start hand tracking: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        session.stop()
        isRunning = false
        leftHand = nil
        rightHand = nil
        deviceTransform = nil
        statusMessage = "Hand tracking stopped"
    }

    private func startListening() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self else { return }
            for await update in handTracking.anchorUpdates {
                if Task.isCancelled { break }
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

        // Prefer middle finger tip as a stable "punch point"; fall back to index tip / wrist.
        // Reactive Strike's hit tests depend on this ordering — do not reorder casually.
        let fistCandidates: [HandSkeleton.JointName] = [.middleFingerTip, .indexFingerTip, .wrist]
        let fistTransform = fistCandidates.lazy.compactMap(worldTransform).first ?? wristTransform

        let observation = HandObservation(
            side: side,
            wristPosition: wristTransform.translation,
            wristOrientation: simd_quatf(rotationMatrix(wristTransform)),
            elbowHint: worldTransform(.forearmArm)?.translation,
            fistPosition: fistTransform.translation,
            timestamp: CACurrentMediaTime()
        )

        switch side {
        case .left: leftHand = observation
        case .right: rightHand = observation
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

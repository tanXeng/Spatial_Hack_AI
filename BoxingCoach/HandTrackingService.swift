import ARKit
import Foundation
import RealityKit
import simd

/// Tracks both hands via ARKit and exposes knuckle/tip positions for punch hit tests.
@Observable
final class HandTrackingService {
    private(set) var isRunning = false
    private(set) var statusMessage = "Hand tracking idle"
    private(set) var leftFistPosition: SIMD3<Float>?
    private(set) var rightFistPosition: SIMD3<Float>?

    private let session = ARKitSession()
    private let handTracking = HandTrackingProvider()
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
            try await session.run([handTracking])
            isRunning = true
            statusMessage = "Hand tracking active"
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
        leftFistPosition = nil
        rightFistPosition = nil
        statusMessage = "Hand tracking stopped"
    }

    private func startListening() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self else { return }
            for await update in handTracking.anchorUpdates {
                if Task.isCancelled { break }
                await self.handle(update.anchor)
            }
        }
    }

    private func handle(_ anchor: HandAnchor) async {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            clear(chirality: anchor.chirality)
            return
        }

        // Prefer middle finger tip as a stable "punch point"; fall back to index tip / wrist.
        let jointNames: [HandSkeleton.JointName] = [
            .middleFingerTip,
            .indexFingerTip,
            .wrist
        ]

        var worldPosition: SIMD3<Float>?
        for name in jointNames {
            let joint = skeleton.joint(name)
            guard joint.isTracked else { continue }
            let transform = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
            worldPosition = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            break
        }

        switch anchor.chirality {
        case .left:
            leftFistPosition = worldPosition
        case .right:
            rightFistPosition = worldPosition
        @unknown default:
            break
        }
    }

    private func clear(chirality: HandAnchor.Chirality) {
        switch chirality {
        case .left:
            leftFistPosition = nil
        case .right:
            rightFistPosition = nil
        @unknown default:
            break
        }
    }
}

//
//  PoseSource.swift
//
//  A swappable abstraction over "where joint data comes from." Right now
//  only HandTrackingPoseSource exists (works today, no entitlement
//  needed). Once/if you get camera access, add a BodyPoseSource that
//  wraps Vision's VNDetectHumanBodyPose3DRequest fed by camera frames,
//  conform it to PoseSource, and change ONE line where the model is
//  constructed (search "SWAP POINT" below).
//
//  This file no longer opens its own ImmersiveSpace — it plugs into
//  whichever one your app already has (see BoxingCoachApp.swift).
//

import SwiftUI
import Observation
import ARKit
import RealityKit

// MARK: - Common joint vocabulary

enum JointID: Hashable, CaseIterable {
    // Available today via HandTrackingProvider:
    case leftWrist, rightWrist
    case leftForearmArm, rightForearmArm   // point toward the elbow, not the elbow itself

    // Reserved for when body/camera tracking is available:
    case leftElbow, rightElbow
    case leftShoulder, rightShoulder
    case waist
}

struct Joint {
    var position: SIMD3<Float> = .zero
    var rotationDegrees: SIMD3<Float> = .zero
    var isTracked: Bool = false
}

typealias PoseFrame = [JointID: Joint]

// MARK: - The swappable interface

protocol PoseSource {
    func start(onUpdate: @escaping (PoseFrame) -> Void) async throws
    func stop()
}

enum PoseSourceError: Error {
    case unsupported
}

// MARK: - Source #1: hand tracking (works today, no entitlement)

final class HandTrackingPoseSource: PoseSource {
    private let session = ARKitSession()
    private let provider = HandTrackingProvider()

    func start(onUpdate: @escaping (PoseFrame) -> Void) async throws {
        guard HandTrackingProvider.isSupported else {
            throw PoseSourceError.unsupported
        }

        try await session.run([provider])

        var latestFrame: PoseFrame = [:]

        for await update in provider.anchorUpdates {
            guard update.event == .added || update.event == .updated else { continue }
            let anchor = update.anchor
            guard let skeleton = anchor.handSkeleton else { continue }

            let wristTransform = anchor.originFromAnchorTransform
                * skeleton.joint(.wrist).anchorFromJointTransform
            let forearmTransform = anchor.originFromAnchorTransform
                * skeleton.joint(.forearmArm).anchorFromJointTransform

            let wristJoint = Joint(position: wristTransform.translation,
                                    rotationDegrees: wristTransform.eulerDegrees,
                                    isTracked: anchor.isTracked)
            let forearmJoint = Joint(position: forearmTransform.translation,
                                      rotationDegrees: forearmTransform.eulerDegrees,
                                      isTracked: anchor.isTracked)

            switch anchor.chirality {
            case .left:
                latestFrame[.leftWrist] = wristJoint
                latestFrame[.leftForearmArm] = forearmJoint
            case .right:
                latestFrame[.rightWrist] = wristJoint
                latestFrame[.rightForearmArm] = forearmJoint
            }

            onUpdate(latestFrame)
        }
    }

    func stop() {
        session.stop()
    }
}

// MARK: - Source #2: body tracking — STUB, fill in once you have camera access
//
// final class BodyPoseSource: PoseSource {
//     func start(onUpdate: @escaping (PoseFrame) -> Void) async {
//         // Pull camera frames (enterprise main-camera-access API),
//         // run VNDetectHumanBodyPose3DRequest per frame, map its
//         // .rightElbow/.rightShoulder/etc into JointID cases, call onUpdate.
//     }
// }

// MARK: - Model: owns the active source, publishes latest frame

@Observable
@MainActor
final class PoseTrackingModel {
    var frame: PoseFrame = [:]
    private(set) var isRunning = false

    // ---- SWAP POINT ----
    // When body tracking is ready, change this one line:
    //   private let source: PoseSource = BodyPoseSource()
    private let source: PoseSource = HandTrackingPoseSource()
    // ---------------------

    // Debug-only: prints tracked joints to the Xcode console so you can
    // verify tracking works even with no on-device visual yet.
    // Safe to delete once you have a real visual indicator.
    private var lastLogTime: Date = .distantPast

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        do {
            try await source.start { [weak self] newFrame in
                Task { @MainActor in
                    self?.frame = newFrame
                    self?.logIfNeeded(newFrame)
                }
            }
        } catch {
            print("Pose tracking failed to start: \(error)")
            isRunning = false
        }
    }

    func stop() {
        source.stop()
        isRunning = false
    }

    private func logIfNeeded(_ frame: PoseFrame) {
        let now = Date()
        guard now.timeIntervalSince(lastLogTime) > 0.5 else { return }
        lastLogTime = now

        let tracked = frame.filter { $0.value.isTracked }
        guard !tracked.isEmpty else {
            print("[Pose] no joints tracked yet")
            return
        }
        for (id, joint) in tracked {
            print(String(format: "[Pose] %@: (%.2f, %.2f, %.2f)",
                          "\(id)", joint.position.x, joint.position.y, joint.position.z))
        }
    }
}

// MARK: - Math helpers

extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }

    var eulerDegrees: SIMD3<Float> {
        let q = simd_quatf(self)
        let sinr_cosp = 2 * (q.vector.w * q.vector.x + q.vector.y * q.vector.z)
        let cosr_cosp = 1 - 2 * (q.vector.x * q.vector.x + q.vector.y * q.vector.y)
        let roll = atan2(sinr_cosp, cosr_cosp)

        let sinp = 2 * (q.vector.w * q.vector.y - q.vector.z * q.vector.x)
        let pitch = abs(sinp) >= 1 ? copysign(.pi / 2, sinp) : asin(sinp)

        let siny_cosp = 2 * (q.vector.w * q.vector.z + q.vector.x * q.vector.y)
        let cosy_cosp = 1 - 2 * (q.vector.y * q.vector.y + q.vector.z * q.vector.z)
        let yaw = atan2(siny_cosp, cosy_cosp)

        return SIMD3(roll, pitch, yaw) * (180 / .pi)
    }
}

// MARK: - Debug readout (embed this in ContentView, not a standalone screen)
//
// This is just a View now, not its own window/button — drop it into your
// existing ContentView so you can see live values while the immersive
// space (and hand tracking) is running.

struct PoseReadoutView: View {
    var frame: PoseFrame

    private let displayOrder: [(JointID, String)] = [
        (.rightWrist, "Right wrist"), (.rightForearmArm, "Right forearm"),
        (.leftWrist, "Left wrist"), (.leftForearmArm, "Left forearm"),
        (.rightElbow, "Right elbow"), (.leftElbow, "Left elbow"),
        (.rightShoulder, "Right shoulder"), (.leftShoulder, "Left shoulder"),
        (.waist, "Waist"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(displayOrder, id: \.0) { id, label in
                if let joint = frame[id] {
                    Text(String(format: "%@: pos(%.2f, %.2f, %.2f) rot(%.0f, %.0f, %.0f)",
                                label, joint.position.x, joint.position.y, joint.position.z,
                                joint.rotationDegrees.x, joint.rotationDegrees.y, joint.rotationDegrees.z))
                        .font(.caption.monospaced())
                } else {
                    Text("\(label): not available from current source")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

import RealityKit
import simd

#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
#endif

/// Visual treatment for a ghost arm.
///
/// The governing constraint: the silhouette **must not obscure the user's view of
/// their real arms**. That rules out an opaque limb. The treatment chosen here is an unlit,
/// low-opacity glow — unlit so it reads as a hologram rather than a physical object competing
/// with real lighting, and low-opacity so the user's actual arm stays visible straight through
/// it. Alignment is judged by how well the real arm sits *inside* the ghost.
enum SilhouetteTint: Sendable {
    /// The coach's demonstration arm.
    case demo
    /// The user's own reconstructed arm, drawn back to them so IK error is visible on-device.
    case mirror
    /// Demo arm at the moment of full extension.
    case emphasis

    /// `fileprivate` because `PlatformColor` is a private typealias — the tint is chosen by
    /// callers, but the concrete color type stays an implementation detail of this file.
    fileprivate var color: PlatformColor {
        switch self {
        case .demo: return PlatformColor(red: 0.30, green: 0.78, blue: 1.00, alpha: 1.0)
        case .mirror: return PlatformColor(red: 0.65, green: 0.65, blue: 0.72, alpha: 1.0)
        case .emphasis: return PlatformColor(red: 0.35, green: 1.00, blue: 0.65, alpha: 1.0)
        }
    }

    var opacity: Float {
        switch self {
        case .demo: return 0.42
        case .mirror: return 0.22
        case .emphasis: return 0.60
        }
    }
}

/// A translucent ghost arm — upper arm, forearm, and fist — posed from world-space joints.
///
/// The entity owns no motion logic of its own. It is told where the joints are and draws them;
/// deciding where they *should* be is `ArmPoseSolver`'s and `ReferencePunch`'s job.
@MainActor
final class ArmSilhouetteEntity {
    let root = Entity()

    private let upperArmSegment: ModelEntity
    private let forearmSegment: ModelEntity
    private let shoulderJoint: ModelEntity
    private let elbowJoint: ModelEntity
    private let fistJoint: ModelEntity

    private let side: BodySide
    private var tint: SilhouetteTint

    private let upperArmRadius: Float = 0.050
    private let forearmRadius: Float = 0.044
    private let fistRadius: Float = 0.052

    init(side: BodySide, tint: SilhouetteTint = .demo) {
        self.side = side
        self.tint = tint

        let material = Self.material(for: tint)

        // Segments are generated at unit height and stretched along their own Y axis when posed,
        // so the meshes are built once here rather than regenerated every frame.
        upperArmSegment = ModelEntity(
            mesh: .generateCylinder(height: 1.0, radius: upperArmRadius),
            materials: [material]
        )
        forearmSegment = ModelEntity(
            mesh: .generateCylinder(height: 1.0, radius: forearmRadius),
            materials: [material]
        )
        shoulderJoint = ModelEntity(
            mesh: .generateSphere(radius: upperArmRadius),
            materials: [material]
        )
        elbowJoint = ModelEntity(
            mesh: .generateSphere(radius: forearmRadius),
            materials: [material]
        )
        fistJoint = ModelEntity(
            mesh: .generateSphere(radius: fistRadius),
            materials: [material]
        )

        root.name = "ArmSilhouette-\(side.rawValue)"
        for part in [upperArmSegment, forearmSegment, shoulderJoint, elbowJoint, fistJoint] {
            root.addChild(part)
        }

        // Whole-limb transparency in one place. Setting alpha per-material instead would make
        // the overlapping joint spheres and segments double-blend at the seams, leaving visibly
        // darker rings at the elbow and shoulder.
        root.components.set(OpacityComponent(opacity: tint.opacity))
        root.isEnabled = false
    }

    func attach(to parent: Entity) {
        parent.addChild(root)
    }

    func removeFromScene() {
        root.removeFromParent()
    }

    var isVisible: Bool {
        get { root.isEnabled }
        set { root.isEnabled = newValue }
    }

    /// Restyles the arm in place — used to flash the demo arm at peak extension.
    func setTint(_ newTint: SilhouetteTint) {
        guard newTint.opacity != tint.opacity || newTint.color != tint.color else { return }
        tint = newTint
        let material = Self.material(for: newTint)
        for part in [upperArmSegment, forearmSegment, shoulderJoint, elbowJoint, fistJoint] {
            part.model?.materials = [material]
        }
        root.components.set(OpacityComponent(opacity: newTint.opacity))
    }

    /// Poses the arm from **world-space** joint positions.
    ///
    /// All placement uses `relativeTo: nil` so this stays correct regardless of where the scene
    /// root sits — the caller passes world coordinates and does not need to know the hierarchy.
    func pose(shoulder: SIMD3<Float>, elbow: SIMD3<Float>, fist: SIMD3<Float>) {
        guard shoulder.isFinite, elbow.isFinite, fist.isFinite else {
            root.isEnabled = false
            return
        }

        align(upperArmSegment, from: shoulder, to: elbow)
        align(forearmSegment, from: elbow, to: fist)

        shoulderJoint.setPosition(shoulder, relativeTo: nil)
        elbowJoint.setPosition(elbow, relativeTo: nil)
        fistJoint.setPosition(fist, relativeTo: nil)
    }

    /// Stretches a unit-height cylinder to span two points.
    private func align(_ entity: ModelEntity, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let delta = end - start
        let length = simd_length(delta)

        // A zero-length bone would produce a degenerate rotation; hide it instead.
        guard length > 1e-5 else {
            entity.isEnabled = false
            return
        }
        entity.isEnabled = true

        entity.setPosition((start + end) * 0.5, relativeTo: nil)
        entity.setOrientation(Self.rotation(fromUnitY: delta / length), relativeTo: nil)

        // Non-uniform scale on Y only: the cylinder's axis lengthens while its radius holds.
        // A uniform scale here would make the limb fatten as it extends.
        entity.scale = SIMD3(1, length, 1)
    }

    /// Rotation taking +Y (a generated cylinder's axis) onto `direction`.
    private static func rotation(fromUnitY direction: SIMD3<Float>) -> simd_quatf {
        let up = SIMD3<Float>(0, 1, 0)
        let dot = simd_dot(up, direction)

        // Already aligned.
        if dot > 0.9999 { return simd_quatf(angle: 0, axis: up) }

        // Exactly antiparallel — `simd_quatf(from:to:)` is undefined here because every axis
        // perpendicular to Y is a valid 180° rotation. Pick one explicitly.
        if dot < -0.9999 {
            return simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
        }

        return simd_quatf(from: up, to: direction)
    }

    private static func material(for tint: SilhouetteTint) -> UnlitMaterial {
        // Unlit keeps the ghost a constant brightness regardless of room lighting, so it stays
        // legible in a dim living room without blowing out in a bright one.
        var material = UnlitMaterial(color: tint.color)
        material.blending = .transparent(opacity: 1.0)
        return material
    }
}

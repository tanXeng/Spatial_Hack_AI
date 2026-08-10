import RealityKit
import simd

#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
#endif

/// Creates and removes simple sphere targets in Air Mode.
@MainActor
final class TargetController {
    private weak var root: Entity?
    private(set) var activeTarget: ModelEntity?
    private(set) var activeTargetPosition: SIMD3<Float>?
    private var pooledTarget: ModelEntity?
    private(set) var createdEntityCount = 0
    private var invalidEvidenceShown = false

    private let idleColor = PlatformColor(red: 1.0, green: 0.55, blue: 0.1, alpha: 1.0)
    private let hitColor = PlatformColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1.0)
    private let missColor = PlatformColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0)

    func attach(to root: Entity) {
        self.root = root
    }

    func detach() {
        removeActiveTarget()
        root = nil
    }

    @discardableResult
    func spawnTarget(
        at position: SIMD3<Float>,
        radius: Float
    ) -> ModelEntity {
        let entity = pooledTarget ?? makeTargetEntity()
        entity.model?.materials = [SimpleMaterial(color: idleColor, isMetallic: false)]
        entity.position = position
        entity.scale = SIMD3<Float>(repeating: radius)

        if entity.parent !== root {
            entity.removeFromParent()
            root?.addChild(entity)
        }

        activeTarget = entity
        activeTargetPosition = position
        invalidEvidenceShown = false
        return entity
    }

    private func makeTargetEntity() -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: 1)
        let material = SimpleMaterial(color: idleColor, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "PunchTarget"
        var accessibility = AccessibilityComponent()
        accessibility.isAccessibilityElement = true
        accessibility.label = LocalizedStringResource(
            stringLiteral: SpatialTrainingAccessibility.target.label
        )
        accessibility.value = LocalizedStringResource(
            stringLiteral: SpatialTrainingAccessibility.target.value
        )
        entity.components.set(accessibility)

        pooledTarget = entity
        createdEntityCount += 1
        return entity
    }

    func flash(result: AttemptResult) {
        guard let activeTarget else { return }
        let color = result == .hit ? hitColor : missColor
        activeTarget.model?.materials = [SimpleMaterial(color: color, isMetallic: false)]
    }

    /// Marks one semantically rejected evidence chain without turning it into a scored miss.
    /// Repeated reducer callbacks for the same target remain visually and sonically idempotent.
    @discardableResult
    func showInvalidEvidenceOnce() -> Bool {
        guard activeTarget != nil, !invalidEvidenceShown else { return false }
        invalidEvidenceShown = true
        flash(result: .miss)
        return true
    }

    func updateActiveTargetPosition(_ position: SIMD3<Float>) {
        guard let activeTarget else { return }
        activeTarget.position = position
        activeTargetPosition = position
    }

    func removeActiveTarget() {
        activeTarget?.removeFromParent()
        activeTarget = nil
        activeTargetPosition = nil
        invalidEvidenceShown = false
    }
}

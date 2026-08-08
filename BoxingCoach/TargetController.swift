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

    private(set) var comboTargets: [ModelEntity] = []
    private(set) var comboTargetPositions: [SIMD3<Float>] = []

    private let idleColor = PlatformColor(red: 1.0, green: 0.55, blue: 0.1, alpha: 1.0)
    private let hitColor = PlatformColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1.0)
    private let missColor = PlatformColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0)
    private let pendingColor = PlatformColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 0.6)

    func attach(to root: Entity) {
        self.root = root
    }

    @discardableResult
    func spawnTarget(
        at position: SIMD3<Float>,
        radius: Float
    ) -> ModelEntity {
        removeActiveTarget()

        let mesh = MeshResource.generateSphere(radius: radius)
        let material = SimpleMaterial(color: idleColor, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "ReactiveStrikeTarget"
        entity.position = position

        root?.addChild(entity)
        activeTarget = entity
        activeTargetPosition = position
        return entity
    }

    func spawnCombo(at positions: [SIMD3<Float>], radius: Float) {
        removeComboTargets()

        for (index, position) in positions.enumerated() {
            let mesh = MeshResource.generateSphere(radius: radius)
            let color = index == 0 ? idleColor : pendingColor
            let material = SimpleMaterial(color: color, isMetallic: false)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = "ComboTarget_\(index)"
            entity.position = position
            root?.addChild(entity)
            comboTargets.append(entity)
            comboTargetPositions.append(position)
        }
    }

    func activateComboTarget(at index: Int) {
        guard index < comboTargets.count else { return }
        for i in 0..<comboTargets.count {
            let color: PlatformColor
            if i < index {
                color = hitColor
            } else if i == index {
                color = idleColor
            } else {
                color = pendingColor
            }
            comboTargets[i].model?.materials = [SimpleMaterial(color: color, isMetallic: false)]
        }
    }

    func flashComboTarget(at index: Int, result: AttemptResult) {
        guard index < comboTargets.count else { return }
        let color = result == .hit ? hitColor : missColor
        comboTargets[index].model?.materials = [SimpleMaterial(color: color, isMetallic: false)]
    }

    func nearestComboTargetIndex(to point: SIMD3<Float>) -> (index: Int, distance: Float)? {
        guard !comboTargetPositions.isEmpty else { return nil }
        var bestIndex = 0
        var bestDist = distance(point, comboTargetPositions[0])
        for i in 1..<comboTargetPositions.count {
            let dist = distance(point, comboTargetPositions[i])
            if dist < bestDist {
                bestDist = dist
                bestIndex = i
            }
        }
        return (bestIndex, bestDist)
    }

    func flash(result: AttemptResult) {
        guard let activeTarget else { return }
        let color = result == .hit ? hitColor : missColor
        activeTarget.model?.materials = [SimpleMaterial(color: color, isMetallic: false)]
    }

    func removeActiveTarget() {
        activeTarget?.removeFromParent()
        activeTarget = nil
        activeTargetPosition = nil
    }

    func removeComboTargets() {
        for target in comboTargets {
            target.removeFromParent()
        }
        comboTargets.removeAll()
        comboTargetPositions.removeAll()
    }
}

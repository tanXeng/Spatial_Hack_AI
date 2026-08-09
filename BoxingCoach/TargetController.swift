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
    private var coachPathRoot: Entity?

    private let idleColor = PlatformColor(red: 1.0, green: 0.55, blue: 0.1, alpha: 1.0)
    private let hitColor = PlatformColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1.0)
    private let missColor = PlatformColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0)

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
        entity.name = "PunchTarget"
        entity.position = position

        root?.addChild(entity)
        activeTarget = entity
        activeTargetPosition = position
        return entity
    }

    func flash(result: AttemptResult) {
        guard let activeTarget else { return }
        let color = result == .hit ? hitColor : missColor
        activeTarget.model?.materials = [SimpleMaterial(color: color, isMetallic: false)]
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
    }

    func showCoachPath(from start: SIMD3<Float>, to end: SIMD3<Float>) {
        removeCoachPath()
        guard start.isFinite, end.isFinite else { return }
        let path = Entity()
        path.name = "GuidedCoachPath"
        let mesh = MeshResource.generateSphere(radius: 0.012)
        let material = SimpleMaterial(color: .cyan, isMetallic: false)
        for index in 0...12 {
            let t = Float(index) / 12
            let marker = ModelEntity(mesh: mesh, materials: [material])
            marker.position = start + (end - start) * t
            path.addChild(marker)
        }
        root?.addChild(path)
        coachPathRoot = path
    }

    func removeCoachPath() {
        coachPathRoot?.removeFromParent()
        coachPathRoot = nil
    }
}

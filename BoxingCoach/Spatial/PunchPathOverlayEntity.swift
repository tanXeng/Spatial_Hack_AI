import RealityKit
import simd

#if canImport(UIKit)
import UIKit
private typealias PathPlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PathPlatformColor = NSColor
#endif

/// Correction-only body-relative path overlay. It allocates only when a correction is selected,
/// never in a frame update, and caps each visible path to five points.
@MainActor
final class PunchPathOverlayEntity {
    let root = Entity()

    private let actualRoot = Entity()
    private let referenceRoot = Entity()
    private let dotMesh = MeshResource.generateSphere(radius: 0.012)
    private let actualMaterial: UnlitMaterial
    private let referenceMaterial: UnlitMaterial

    init() {
        actualMaterial = Self.material(
            color: PathPlatformColor(red: 1.0, green: 0.34, blue: 0.29, alpha: 1)
        )
        referenceMaterial = Self.material(
            color: PathPlatformColor(red: 0.20, green: 0.82, blue: 1.0, alpha: 1)
        )
        root.name = "CorrectionPathOverlay"
        actualRoot.name = "ActualPath-Coral-Measured"
        referenceRoot.name = "ReferencePath-Cyan-EstimatedFit"
        var accessibility = AccessibilityComponent()
        accessibility.isAccessibilityElement = true
        accessibility.label = "Correction path comparison"
        accessibility.value = "Actual athlete path in coral, measured. Fitted reference path in cyan, estimated."
        root.components.set(accessibility)
        root.addChild(actualRoot)
        root.addChild(referenceRoot)
        root.isEnabled = false
    }

    func attach(to parent: Entity) {
        parent.addChild(root)
    }

    func show(actual: [SIMD3<Float>], reference: [SIMD3<Float>]) {
        clearChildren(of: actualRoot)
        clearChildren(of: referenceRoot)
        add(path: actual.prefix(5), to: actualRoot, material: actualMaterial)
        add(path: reference.prefix(5), to: referenceRoot, material: referenceMaterial)
        root.isEnabled = !actualRoot.children.isEmpty && !referenceRoot.children.isEmpty
    }

    func hide() {
        root.isEnabled = false
    }

    func removeFromScene() {
        root.removeFromParent()
    }

    private func add(
        path: ArraySlice<SIMD3<Float>>,
        to parent: Entity,
        material: UnlitMaterial
    ) {
        for (index, position) in path.enumerated() where position.isFinite {
            let dot = ModelEntity(mesh: dotMesh, materials: [material])
            dot.name = "\(parent.name)-\(index)"
            dot.setPosition(position, relativeTo: nil)
            parent.addChild(dot)
        }
    }

    private func clearChildren(of entity: Entity) {
        for child in entity.children {
            child.removeFromParent()
        }
    }

    private static func material(color: PathPlatformColor) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: 0.86)
        return material
    }
}

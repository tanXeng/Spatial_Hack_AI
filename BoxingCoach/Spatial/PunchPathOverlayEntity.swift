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
        show(
            actual: actual.map {
                CorrectionPathSample(position: $0, provenance: .measured)
            },
            reference: reference.map {
                CorrectionPathSample(position: $0, provenance: .estimated)
            }
        )
    }

    func show(actual: [CorrectionPathSample], reference: [CorrectionPathSample]) {
        clearChildren(of: actualRoot)
        clearChildren(of: referenceRoot)
        add(path: actual.prefix(5).map(\.position), to: actualRoot, material: actualMaterial)
        add(path: reference.prefix(5).map(\.position), to: referenceRoot, material: referenceMaterial)
        var accessibility = root.components[AccessibilityComponent.self] ?? AccessibilityComponent()
        accessibility.isAccessibilityElement = true
        accessibility.label = "Correction path comparison"
        accessibility.value = actual.contains(where: { $0.provenance == .interpolated })
            ? "Actual athlete path in coral, including interpolated samples. Fitted reference path in cyan, estimated."
            : "Actual athlete path in coral, measured. Fitted reference path in cyan, estimated."
        root.components.set(accessibility)
        root.isEnabled = !actualRoot.children.isEmpty && !referenceRoot.children.isEmpty
    }

    func hide() {
        root.isEnabled = false
    }

    func clear() {
        clearChildren(of: actualRoot)
        clearChildren(of: referenceRoot)
        root.isEnabled = false
    }

    var visiblePointCount: Int {
        actualRoot.children.count + referenceRoot.children.count
    }

    func removeFromScene() {
        root.removeFromParent()
    }

    private func add(
        path: [SIMD3<Float>],
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
        // RealityKit's child collection is live. Snapshot it so removing one child
        // cannot shift the collection and leave the next private path point behind.
        for child in Array(entity.children) {
            child.removeFromParent()
        }
    }

    private static func material(color: PathPlatformColor) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: 0.86)
        return material
    }
}

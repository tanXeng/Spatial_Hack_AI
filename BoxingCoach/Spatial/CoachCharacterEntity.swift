import Foundation
import RealityKit
import simd

/// A rigged humanoid coach who demonstrates the selected punch before the ghost overlay takes over.
///
/// **Fails soft by design.** If the asset is missing, malformed, or a clip does not resolve, every
/// method here becomes a no-op and Aura Punch runs exactly as it did before the coach existed. A
/// missing model must never cost a demo, so nothing in this type throws into the session loop.
///
/// Asset provenance: Tripo exported one FBX per animation with the skinned mesh embedded only in
/// the jab file, all sharing an identical 65-bone Mixamo skeleton rooted at `mixamorig10:Hips`.
/// `Art/` holds those sources; `Resources/Coach/*.usdz` is the converted result — `coach.usdz`
/// carries the mesh plus `guard_idle`, and each `coach_<clip>.usdz` carries one animation and no
/// mesh. See the conversion notes in CLAUDE.md before regenerating them.
@MainActor
final class CoachCharacterEntity {
    /// Clip names as authored into the USDZ files.
    enum Clip {
        static let idle = "guard_idle"
    }

    /// The four punch clips that exist, and which of the coach's arms actually throws each one.
    ///
    /// Tripo produced one side per technique. That is enough for every case because the coach
    /// faces the user and mirrors — see `shouldReflect(clipSide:requestedSide:)`.
    private static let punchClips: [String: (file: String, clip: String, side: BodySide)] = [
        Technique.jab.id: ("coach_jab_left", "jab_left", .left),
        Technique.cross.id: ("coach_cross_right", "cross_right", .right),
        Technique.hook.id: ("coach_hook_right", "hook_right", .right),
        Technique.uppercut.id: ("coach_uppercut_right", "uppercut_right", .right)
    ]

    private static let baseAssetName = "coach"

    // MARK: Tuning
    //
    // These are the knobs most likely to need a pass on device. Nothing about them can be
    // verified in the simulator, which renders the scene but not the user's real body.

    /// How far ahead of the user the coach stands, in meters. Small on purpose: he stands *beside*
    /// the user, and this only nudges him forward enough to sit in peripheral vision rather than
    /// squarely in the user's blind spot.
    static var standoffDistance: Float = 0.45

    /// How far to the side the coach stands, in meters. Comfortably clear of the user's punching
    /// space — a straight punch travels forward, not 85 cm sideways.
    static var lateralOffset: Float = 0.85

    /// Yaw applied on top of the user's own facing.
    ///
    /// Zero, because the coach stands **shoulder to shoulder with the user and faces the same way**,
    /// like a partner on the next spot in a class. He is deliberately *not* a gym mirror: facing the
    /// user meant every demo had to be mirrored to read correctly, and that mirroring is what
    /// rendered him inside out. Side by side, the common cases need no reflection at all.
    static var facingYaw: Float = 0

    /// Model height in meters as authored, used to scale him to the user. Measured off the source
    /// FBX bounding box; only change this if the asset is re-exported at a different scale.
    static let authoredHeight: Float = 1.587

    /// Shoulder height as a fraction of total height, used to find the floor from the body frame,
    /// whose origin sits at the shoulder line rather than at the feet.
    private static let shoulderHeightFraction: Float = 0.83

    private(set) var isLoaded = false

    /// Positioning/reflection wrapper. Kept separate from the loaded model so the asset's own
    /// transform is never mutated and a reflection cannot accumulate across demos.
    private let container = Entity()
    private var model: Entity?
    private var activeController: AnimationPlaybackController?

    // MARK: Loading

    /// Loads the base model and folds every punch clip into one `AnimationLibraryComponent`.
    ///
    /// Returns `false` rather than throwing: a coach that fails to load is a missing coach, not a
    /// broken session.
    @discardableResult
    func load() async -> Bool {
        guard !isLoaded else { return true }

        let loaded: Entity
        do {
            loaded = try await Entity(named: Self.baseAssetName, in: Bundle.main)
        } catch {
            print("[Coach] base asset '\(Self.baseAssetName)' failed to load: \(error)")
            return false
        }

        var library = loaded.components[AnimationLibraryComponent.self] ?? AnimationLibraryComponent()

        // The base asset ships `guard_idle`; USD names the animation prim, but RealityKit does not
        // always surface that name, so fall back to the single available animation.
        if library.animations[Clip.idle] == nil, let idle = loaded.availableAnimations.first {
            library.animations[Clip.idle] = idle
        }

        // Each punch lives in its own animation-only USDZ built on the same skeleton, so the
        // resources bind to this model's joints by name.
        for (file, clip) in Self.punchClips.values.map({ ($0.file, $0.clip) }) {
            do {
                let holder = try await Entity(named: file, in: Bundle.main)
                if let animation = holder.availableAnimations.first {
                    library.animations[clip] = animation
                } else {
                    print("[Coach] '\(file)' loaded but exposed no animation")
                }
            } catch {
                print("[Coach] clip '\(file)' failed to load: \(error)")
            }
        }

        loaded.components.set(library)
        Self.makeDoubleSided(loaded)
        container.addChild(loaded)
        model = loaded
        isLoaded = true
        return true
    }

    /// Turns off back-face culling on every material in the hierarchy.
    ///
    /// Mirroring the coach is a negative X scale, and a negative scale reverses triangle winding.
    /// With the default `.back` culling that inverts which faces survive, so the renderer discards
    /// his outer surface and draws the inside of his skull and torso instead — the "I can see
    /// inside his face" artifact. Drawing both sides costs one character's worth of extra
    /// fragments and makes the reflected cases render solid.
    ///
    /// Applied unconditionally rather than only when reflected: `place` can flip the same loaded
    /// model either way between demos, and re-walking the material graph on every placement would
    /// be far more expensive than just leaving culling off.
    private static func makeDoubleSided(_ entity: Entity) {
        if var component = entity.components[ModelComponent.self] {
            component.materials = component.materials.map(disablingCulling)
            entity.components.set(component)
        }
        for child in entity.children {
            makeDoubleSided(child)
        }
    }

    /// `faceCulling` lives on each concrete material type rather than on the `Material` protocol,
    /// so there is no way to write this generically. Unrecognized materials pass through untouched.
    private static func disablingCulling(_ material: any Material) -> any Material {
        switch material {
        case var physical as PhysicallyBasedMaterial:
            physical.faceCulling = .none
            return physical
        case var shaderGraph as ShaderGraphMaterial:
            shaderGraph.faceCulling = .none
            return shaderGraph
        case var simple as SimpleMaterial:
            simple.faceCulling = .none
            return simple
        case var unlit as UnlitMaterial:
            unlit.faceCulling = .none
            return unlit
        default:
            return material
        }
    }

    // MARK: Scene

    func attach(to root: Entity) {
        guard container.parent !== root else { return }
        container.removeFromParent()
        root.addChild(container)
    }

    func removeFromScene() {
        container.removeFromParent()
    }

    var isVisible: Bool {
        get { container.isEnabled }
        set { container.isEnabled = newValue }
    }

    /// Where `place` actually put him. Exposed so the placement rules can be asserted without a
    /// device — the simulator renders the scene but has no real body to place him relative to.
    var worldPositionForTesting: SIMD3<Float> { container.transform.translation }

    /// Stands the coach on the floor beside the user, facing the same way, scaled to their height.
    ///
    /// `demoSide` decides which side of the user he takes: he stands on the **opposite** side so
    /// that the arm he is about to throw with is the one nearest the user. A right-hand cross
    /// demonstrated from the user's left puts the working arm between the two of them, in clear
    /// view; from the user's right it would be hidden behind his own torso.
    ///
    /// Everything is derived from the current `BodyFrame` and then written as a world transform, so
    /// the coach stays put once placed instead of drifting with every head movement.
    func place(
        using frame: BodyFrame,
        measurements: BodyMeasurements,
        demoSide: BodySide,
        reflected: Bool
    ) {
        guard isLoaded else { return }

        let height = max(measurements.height, 0.5)
        let scale = height / Self.authoredHeight

        // The body frame's origin is the shoulder line; the coach's feet belong on the floor.
        let shoulderHeight = height * Self.shoulderHeightFraction

        // Negative lateral is the user's left. A right-arm demo stands on the left, and vice versa.
        let lateralSign: Float = demoSide == .right ? -1 : 1
        let beside = frame.origin
            + frame.forward * Self.standoffDistance
            + frame.right * (Self.lateralOffset * lateralSign)
        let position = SIMD3<Float>(beside.x, frame.origin.y - shoulderHeight, beside.z)

        // Yaw the coach about world up to face the same direction the user is facing.
        let userYaw = atan2(frame.forward.x, frame.forward.z)
        let rotation = simd_quatf(angle: userYaw + Self.facingYaw, axis: SIMD3(0, 1, 0))

        container.transform = Transform(
            scale: SIMD3(repeating: scale),
            rotation: rotation,
            translation: position
        )

        // Reflection is applied on the container's X axis, which is the coach's own left-right axis
        // after the yaw above — so it mirrors him rather than moving him sideways.
        if reflected {
            container.transform.scale.x *= -1
        }
    }

    // MARK: Playback

    /// Whether the coach's `clipSide` arm needs mirroring to land on the user's `requestedSide`.
    ///
    /// The coach stands beside the user **facing the same way**, so his left arm is already on the
    /// same side of the world as the user's left arm — an unreflected left-arm clip reads as a left
    /// punch with no work at all. Reflection is therefore needed only when the clip is authored on
    /// the *other* side from the one being thrown. That is what lets four one-sided clips cover all
    /// eight technique/side combinations.
    ///
    /// Note this is the exact inverse of the rule used while the coach faced the user like a gym
    /// mirror. Facing him around without inverting this would put every demo on the wrong arm.
    static func shouldReflect(clipSide: BodySide, requestedSide: BodySide) -> Bool {
        clipSide != requestedSide
    }

    /// Resolves the clip for a technique, and whether it must be reflected for `side`.
    /// `nil` when no clip exists for the technique, which the caller treats as "skip the demo".
    static func resolveClip(
        technique: Technique,
        side: BodySide
    ) -> (clip: String, reflected: Bool)? {
        guard let entry = punchClips[technique.id] else { return nil }
        return (entry.clip, shouldReflect(clipSide: entry.side, requestedSide: side))
    }

    func playIdle() {
        guard let model, let animation = library(of: model)?.animations[Clip.idle] else { return }
        activeController = model.playAnimation(
            animation.repeat(),
            transitionDuration: 0.2
        )
    }

    /// Plays one punch and returns its duration, or `nil` if the clip is unavailable.
    /// The caller awaits the duration rather than this call blocking on playback.
    @discardableResult
    func play(clip: String) -> TimeInterval? {
        guard let model, let animation = library(of: model)?.animations[clip] else {
            print("[Coach] clip '\(clip)' not in library")
            return nil
        }
        let controller = model.playAnimation(animation, transitionDuration: 0.12)
        activeController = controller
        return controller.duration > 0 ? controller.duration : nil
    }

    func stop() {
        activeController?.stop(blendOutDuration: 0.15)
        activeController = nil
    }

    private func library(of entity: Entity) -> AnimationLibraryComponent? {
        entity.components[AnimationLibraryComponent.self]
    }
}

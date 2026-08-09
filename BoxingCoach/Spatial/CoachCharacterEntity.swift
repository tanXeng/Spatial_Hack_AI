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
    // These three are the knobs most likely to need a pass on device. Nothing about them can be
    // verified in the simulator, which renders the scene but not the user's real body.

    /// How far in front of the user the coach stands, in meters.
    static var standoffDistance: Float = 1.6

    /// Yaw applied so the coach faces the user. Mixamo characters face -Z once Blender's Z-up
    /// scene is converted to USD's Y-up, so a half turn puts him eye to eye.
    static var facingYaw: Float = .pi

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
        container.addChild(loaded)
        model = loaded
        isLoaded = true
        return true
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

    /// Stands the coach on the floor in front of the user, facing them, scaled to their height.
    ///
    /// Everything is derived from the current `BodyFrame` and then written as a world transform, so
    /// the coach stays put once placed instead of drifting with every head movement.
    func place(using frame: BodyFrame, measurements: BodyMeasurements, reflected: Bool) {
        guard isLoaded else { return }

        let height = max(measurements.height, 0.5)
        let scale = height / Self.authoredHeight

        // The body frame's origin is the shoulder line; the coach's feet belong on the floor.
        let shoulderHeight = height * Self.shoulderHeightFraction
        let ahead = frame.origin + frame.forward * Self.standoffDistance
        let position = SIMD3<Float>(ahead.x, frame.origin.y - shoulderHeight, ahead.z)

        // Yaw the coach about world up to face back down the user's forward axis.
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
    /// The coach faces the user, so without reflection his left limb reads on the user's right. To
    /// put the motion on the same side the user is about to throw, reflect exactly when the clip's
    /// own side matches the requested one. That is what lets four one-sided clips cover all eight
    /// technique/side combinations.
    static func shouldReflect(clipSide: BodySide, requestedSide: BodySide) -> Bool {
        clipSide == requestedSide
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

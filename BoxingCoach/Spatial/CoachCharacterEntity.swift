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
/// mesh. The checked-in assets are runtime inputs and are not regenerated during a normal build.
@MainActor
final class CoachCharacterEntity {
    /// Clip names as authored into the USDZ files.
    enum Clip {
        static let idle = "guard_idle"
    }

    /// One authored animation, and which of the coach's arms actually throws it.
    struct ClipEntry: Sendable, Equatable {
        let file: String
        let clip: String
        let side: BodySide
    }

    /// The punch clips that exist, per technique.
    ///
    /// **Hook and uppercut are authored on both sides.** They are the `.either`-hand techniques, so
    /// the guided follow-along alternates arms rep to rep and the coach alternates with it — with a
    /// real left-hand animation rather than a mirrored right one. Jab and cross are thrown with a
    /// stance-determined hand, so one authored side plus mirroring covers both stances.
    ///
    /// Having a genuine clip for a side is strictly better than mirroring it: no negative scale, so
    /// no reversed winding or inverted normals for those reps.
    private static let punchClips: [String: [ClipEntry]] = [
        Technique.jab.id: [
            ClipEntry(file: "coach_jab_left", clip: "jab_left", side: .left)
        ],
        Technique.cross.id: [
            ClipEntry(file: "coach_cross_right", clip: "cross_right", side: .right)
        ],
        Technique.hook.id: [
            ClipEntry(file: "coach_hook_left", clip: "hook_left", side: .left),
            ClipEntry(file: "coach_hook_right", clip: "hook_right", side: .right)
        ],
        Technique.uppercut.id: [
            ClipEntry(file: "coach_uppercut_left", clip: "uppercut_left", side: .left),
            ClipEntry(file: "coach_uppercut_right", clip: "uppercut_right", side: .right)
        ]
    ]

    /// Every distinct clip file, for loading. Flattened from `punchClips`, so adding a clip there
    /// is the only edit needed — this and `resolveClip` both follow.
    static var allClipEntries: [ClipEntry] {
        punchClips.values.flatMap { $0 }
    }

    private static let baseAssetName = "coach"

    // MARK: Tuning
    //
    // These are the knobs most likely to need a pass on device. Nothing about them can be
    // verified in the simulator, which renders the scene but not the user's real body.

    /// How far away the coach stands, in meters. Far enough that his whole body fits in view at
    /// once, and well clear of the user's punching space.
    static var viewingDistance: Float = 1.9

    /// How far off the user's forward axis he stands, in radians.
    ///
    /// This is the constant that decides whether he is actually *visible*. An earlier version
    /// specified forward and lateral offsets independently and put him at roughly 62° off axis —
    /// beside the user in the literal sense, but only findable by turning your head all the way to
    /// the side. Comfortable binocular attention is roughly ±30°, so 24° keeps him fully in view
    /// while looking straight ahead, while still reading as "next to me" rather than "in my way".
    static var viewingAngle: Float = 24 * .pi / 180

    /// Per-frame fraction of the remaining gap closed when following the user, at the session's
    /// ~90 Hz tick. 0.08 settles in about a sixth of a second: quick enough to feel attached to the
    /// user's turn, slow enough that head jitter does not vibrate a whole human-sized model.
    static var followSmoothing: Float = 0.08

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
    private var loadingTask: Task<Bool, Never>?

    /// Smoothed placement state. Kept here rather than read back off the container because the
    /// container's scale carries the reflection flip, which would corrupt any value recovered from
    /// its transform.
    private var currentPosition: SIMD3<Float> = .zero
    private var currentYaw: Float = 0
    private var hasPlacement = false

    // MARK: Loading

    /// Loads the base model and folds every punch clip into one `AnimationLibraryComponent`.
    ///
    /// Returns `false` rather than throwing: a coach that fails to load is a missing coach, not a
    /// broken session.
    @discardableResult
    func load() async -> Bool {
        guard !isLoaded else { return true }

        if let loadingTask {
            return await loadingTask.value
        }

        // App-start preloading and a quickly started Aura session can arrive at the same time.
        // Share one load instead of decoding and assembling the large USDZ set twice.
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performLoad()
        }
        loadingTask = task
        let loaded = await task.value
        loadingTask = nil
        return loaded
    }

    private func performLoad() async -> Bool {
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
        for entry in Self.allClipEntries {
            do {
                let holder = try await Entity(named: entry.file, in: Bundle.main)
                if let animation = holder.availableAnimations.first {
                    library.animations[entry.clip] = animation
                } else {
                    print("[Coach] '\(entry.file)' loaded but exposed no animation")
                }
            } catch {
                print("[Coach] clip '\(entry.file)' failed to load: \(error)")
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

    /// Where the coach belongs right now, given where the user is and which way they face.
    ///
    /// `demoSide` decides which side of the user he takes: he stands on the **opposite** side so
    /// that the arm he is about to throw with is the one nearest the user. A right-hand cross
    /// demonstrated from the user's left puts the working arm between the two of them, in clear
    /// view; from the user's right it would be hidden behind his own torso.
    private static func targetPlacement(
        frame: BodyFrame,
        measurements: BodyMeasurements,
        demoSide: BodySide
    ) -> (position: SIMD3<Float>, yaw: Float, scale: Float) {
        let height = max(measurements.height, 0.5)

        // Negative lateral is the user's left. A right-arm demo stands on the left, and vice versa.
        let lateralSign: Float = demoSide == .right ? -1 : 1
        let ahead = cos(Self.viewingAngle) * Self.viewingDistance
        let across = sin(Self.viewingAngle) * Self.viewingDistance * lateralSign

        let spot = frame.origin + frame.forward * ahead + frame.right * across

        // The body frame's origin is the shoulder line; the coach's feet belong on the floor.
        let shoulderHeight = height * Self.shoulderHeightFraction
        let position = SIMD3<Float>(spot.x, frame.origin.y - shoulderHeight, spot.z)

        // Yaw about world up so he faces the same direction the user is facing.
        let userYaw = atan2(frame.forward.x, frame.forward.z)

        return (position, userYaw + Self.facingYaw, height / Self.authoredHeight)
    }

    /// Snaps the coach to his spot immediately. Used for the first placement, where easing in from
    /// wherever the container happened to sit would read as him sliding across the room.
    func place(
        using frame: BodyFrame,
        measurements: BodyMeasurements,
        demoSide: BodySide,
        reflected: Bool
    ) {
        guard isLoaded else { return }
        let target = Self.targetPlacement(
            frame: frame,
            measurements: measurements,
            demoSide: demoSide
        )
        currentPosition = target.position
        currentYaw = target.yaw
        hasPlacement = true
        apply(scale: target.scale, reflected: reflected)
    }

    /// Eases the coach toward where he currently belongs. Call every frame while he is on screen.
    ///
    /// This is what makes him **turn with the user**: the target is recomputed from the live body
    /// frame, so as the user turns their head he orbits to hold the same angle off their forward
    /// axis and rotates to keep facing the same way they do. Holding the *angle* rather than a
    /// fixed world spot is the whole point — it is what keeps him in view no matter which way the
    /// user ends up facing.
    ///
    /// Smoothed rather than snapped, because `BodyFrame.forward` follows the head, and a model this
    /// size tracking raw head yaw one-to-one is unpleasant to stand next to.
    func follow(
        using frame: BodyFrame,
        measurements: BodyMeasurements,
        demoSide: BodySide,
        reflected: Bool
    ) {
        guard isLoaded else { return }
        guard hasPlacement else {
            place(
                using: frame,
                measurements: measurements,
                demoSide: demoSide,
                reflected: reflected
            )
            return
        }

        let target = Self.targetPlacement(
            frame: frame,
            measurements: measurements,
            demoSide: demoSide
        )
        let t = min(max(Self.followSmoothing, 0), 1)

        currentPosition += (target.position - currentPosition) * t
        // Interpolate the *shortest* way round. Lerping raw radians sends him the long way — a full
        // spin in place — whenever the user's yaw crosses the ±π seam.
        currentYaw += Self.shortestAngleDelta(from: currentYaw, to: target.yaw) * t

        apply(scale: target.scale, reflected: reflected)
    }

    /// Signed smallest rotation from `from` to `to`, wrapped into -π...π.
    static func shortestAngleDelta(from: Float, to: Float) -> Float {
        atan2(sin(to - from), cos(to - from))
    }

    private func apply(scale: Float, reflected: Bool) {
        var transform = Transform(
            scale: SIMD3(repeating: scale),
            rotation: simd_quatf(angle: currentYaw, axis: SIMD3(0, 1, 0)),
            translation: currentPosition
        )

        // Reflection is applied on the container's X axis, which is the coach's own left-right axis
        // after the yaw above — so it mirrors him rather than moving him sideways.
        if reflected {
            transform.scale.x *= -1
        }
        container.transform = transform
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
    ///
    /// **An authored clip for the requested side always wins**, and needs no reflection. Only when
    /// the technique has nothing on that side does this fall back to mirroring the other one. That
    /// ordering is what makes adding a second-side FBX an improvement rather than a no-op: hook and
    /// uppercut now play real animation on both arms and never take the negative-scale path.
    ///
    /// `nil` when no clip exists for the technique, which the caller treats as "skip the demo".
    static func resolveClip(
        technique: Technique,
        side: BodySide
    ) -> (clip: String, reflected: Bool)? {
        guard let entries = punchClips[technique.id], let fallback = entries.first else {
            return nil
        }
        if let exact = entries.first(where: { $0.side == side }) {
            return (exact.clip, false)
        }
        return (fallback.clip, shouldReflect(clipSide: fallback.side, requestedSide: side))
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

    /// Throws the same punch on a loop until something else is played or the coach is dismissed.
    ///
    /// The punch clips start and end at guard, so repeating one reads as a boxer working the same
    /// shot over and over — which is what the user watches while the ghost leads them through the
    /// guided reps. Returns `false` when the clip is unavailable, so the caller can fall back.
    @discardableResult
    func playLooping(clip: String) -> Bool {
        guard let model, let animation = library(of: model)?.animations[clip] else {
            print("[Coach] clip '\(clip)' not in library")
            return false
        }
        activeController = model.playAnimation(animation.repeat(), transitionDuration: 0.12)
        return true
    }

    func stop() {
        activeController?.stop(blendOutDuration: 0.15)
        activeController = nil
    }

    private func library(of entity: Entity) -> AnimationLibraryComponent? {
        entity.components[AnimationLibraryComponent.self]
    }
}

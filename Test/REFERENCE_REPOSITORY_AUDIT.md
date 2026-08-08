# Reference repository audit

**Snapshot:** 8 August 2026
**Scope:** repositories named in the supplied research note, with a detailed comparison of [`tanXeng/Spatial_Hack_AI`](https://github.com/tanXeng/Spatial_Hack_AI)
**Purpose:** decide what may inform ShadowBox, what must be independently implemented, and what should not enter the MVP.

This is an engineering and provenance audit, not legal advice. A public repository is readable; it is not automatically reusable. This documentation task did not clone a third-party repository, and no third-party source, asset, model, key, or dataset is approved for copying by this document.

## Labels

- **[E] Evidence:** directly observable in the linked repository, branch, documentation, or local ShadowBox source.
- **[I] Inference:** an engineering conclusion drawn from evidence; it still needs implementation or evaluation.
- **[D] Decision:** adopted, deferred, or rejected for this MVP.
- **[L] License condition:** reuse depends on a verified license and any asset/data-specific terms.
- **[V] Validation boundary:** source presence or compilation is not physical Apple Vision Pro validation.

## Executive decision

**[D] Adopt:** Apple platform patterns, native Swift/SwiftUI/RealityKit/ARKit architecture, one timestamped tracking pipeline, deterministic offline feedback, procedural guide visuals, small independently authored motion utilities, and Swift Testing.

**[D] Defer:** a licensed rigged coach, JSON-authored lesson content, iPhone full-body pose, image/object anchors for bag alignment, scene understanding, optional belt/Watch sensing, capture tooling, and Core ML. Each is gated by a concrete user need, platform entitlement, provenance, and device evaluation.

**[D] Reject for the current MVP:** copying unlicensed repository code/assets, treating head yaw as torso yaw, scoring inferred elbows/hips, authoritative hook/uppercut coaching, stale-pose polling, embedded cloud-model credentials, an always-online feedback dependency, a consumer passthrough-camera workaround, and heavyweight rendering/biomechanics frameworks without a measured requirement.

## `Spatial_Hack_AI`: latest-reference comparison

### Repository state

| Ref | Relationship and observed delta | What it means |
|---|---|---|
| [`main` at `b570f2e31b638e97fe59110f9909bcd20228bbc7`](https://github.com/tanXeng/Spatial_Hack_AI/tree/b570f2e31b638e97fe59110f9909bcd20228bbc7) | **[E]** Default-line snapshot; two-commit project state. | **[D]** This is the repository's current default state at the audit snapshot. It is the correct meaning of “current state,” not the unmerged feature work below. |
| [`feat/aura-punch` at `037e0ae0f1854638ace79b72a2a2996d5475548a`](https://github.com/tanXeng/Spatial_Hack_AI/tree/037e0ae0f1854638ace79b72a2a2996d5475548a) | **[E]** Direct child of the pinned main commit; unmerged; 15 files and approximately `+3,148/-57`. [Direct comparison](https://github.com/tanXeng/Spatial_Hack_AI/compare/b570f2e31b638e97fe59110f9909bcd20228bbc7...037e0ae0f1854638ace79b72a2a2996d5475548a) | **[D]** Useful as a design proposal, not authoritative current product state and not reusable source without permission. |
| [`aurapunch-ian` at `f500724f1550a7b58a9531fd6ab3157e82954174`](https://github.com/tanXeng/Spatial_Hack_AI/tree/f500724f1550a7b58a9531fd6ab3157e82954174) | **[E]** Orphan line with no main-branch merge base. | **[D]** Do not describe it as a later main revision or combine its delta with the feature-branch comparison. Review only as disconnected historical evidence. |

**[L]** The audited repository has no root `LICENSE`, no SPDX declarations, and no asset-attribution register. GitHub explains that a repository license defines how others may use code; without a license, default copyright applies. [GitHub licensing guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository), [no-license summary](https://choosealicense.com/no-permission/)

**[D]** Therefore ShadowBox may learn from public behavior and architectural ideas, but must not paste, translate, mechanically recreate, bundle, or redistribute its code or assets unless the rights holder grants suitable permission. Independently authored work must retain its own design notes, tests, and provenance.

### What the unmerged Aura branch actually adds

The branch describes a ghost arm/hand demonstrator; hand and world tracking; a head-yaw body frame; two-bone arm inverse kinematics; authored jab, cross, hook, and uppercut paths; a JSON content seam; constrained dynamic time warping (DTW); deterministic feedback; and an optional Claude network client **[E]**. Its own documentation also states that hardware tests were not completed and geometry thresholds were not calibrated **[E/V]**.

| Reference element | Audit | ShadowBox decision |
|---|---|---|
| Procedural ghost glove/arm | A legible spatial guide can be valuable without third-party art **[I]**. | **Adopted concept only.** ShadowBox now uses an original locally authored procedural glove/cuff; it remains shown guidance, not tracked anatomy. |
| Hands plus world tracking in one spatial session | Consistent timestamps and transforms reduce contradictory state **[I]**. | **Adopt.** One tracking owner routes plain samples to feature engines. |
| Head-yaw “body” coordinates | Device heading is observable; torso and pelvis heading are not **[E]**. | **Reject equivalence.** Use a clearly labelled boxer-relative frame and never report head yaw as torso/hip rotation. |
| Two-bone shoulder/elbow IK | It can make a reference character readable, but inferred joints are not measured joints **[I]**. | **Defer to visualization.** Never use inferred elbow/shoulder angles as AVP-only technique evidence. |
| Jab/cross/hook/uppercut authored paths | A path is instructional content, not biomechanical truth **[I]**. | **Adopt jab/cross only as provisional, independently authored hand guidance; qualified coach review remains a release gate for technique language. Defer hooks/uppercuts** until content, safety, trajectory, and device tests exist. |
| JSON lesson seam | Versioned external content can improve reviewability **[I]**. | **Defer.** Introduce only when several coach-reviewed lessons justify a schema and migration policy. |
| Constrained DTW | Useful for speed-independent geometric comparison when inputs and refusal states are explicit **[I]**. | **Adopted as an independently authored runtime diagnostic.** ShadowBox validates a complete trace, translates by guard, normalizes by reach, resamples by equal cumulative arc length, constrains comparison, and fails closed. It is session-only, separately labelled, and excluded from coaching and overall scoring. This is not a technique validator. |
| Deterministic coaching text | Specific offline feedback is auditable, fast, private, and testable **[I]**. | **Adopt.** One observable correction at a time; no professional-technique claim. |
| Optional Claude client and embedded key path | Network dependence, privacy, nondeterminism, cost, and extractable client secrets add risk without MVP value **[E/I]**. | **Reject.** No embedded model key, raw motion upload, or cloud dependency. Future models require a separately reviewed service boundary and consent. |
| Pose polling without a capture-age contract | A plausible stale pose can create false hits and misleading coaching **[I]**. | **Reject.** Consume timestamped updates, gate recency/tracking, and pause rather than score missing evidence. |
| Repository models/textures/assets | No verified asset manifest or reuse grant **[L]**. | **Reject.** Use procedural primitives or separately licensed/authored assets with an attribution register. |

### Claims the reference branch cannot validate

- **[V]** A branch claim that it compiles is not a signed install, headset run, tracking-accuracy result, comfort result, or safety acceptance.
- **[V]** A two-bone solution does not validate elbow, shoulder, torso, or hip scoring.
- **[V]** Four authored paths do not establish coaching authority for hooks or uppercuts.
- **[V]** DTW similarity does not establish correct boxing technique or learning efficacy.
- **[V]** Optional LLM prose does not make measurement more accurate.

## Broader reference stack

The supplied note is a discovery map, not a dependency list. Every item below remains subject to its own pinned revision, license, transitive dependency, asset, model-weight, and data-rights review.

### Platform and Swift foundations

| Sources | What is reliable to learn | Decision |
|---|---|---|
| [Swift](https://github.com/swiftlang/swift), [Swift Testing](https://github.com/swiftlang/swift-testing), [Apple introductory visionOS samples](https://developer.apple.com/documentation/visionos/introductory-visionos-samples), [tracking and visualizing hand movement](https://developer.apple.com/documentation/visionos/tracking-and-visualizing-hand-movement) | **[E]** Language, concurrency/testing conventions, and official platform usage. | **[D] Adopt official APIs and small testable domain types.** Swift is a scripting/language reference, not a boxing algorithm or permission to copy unrelated examples blindly. |
| [awesome-visionos](https://github.com/stevenpaulhoward/awesome-visionos), [visionosresources](https://github.com/timmitra/visionosresources), [Apple Sample Code Library](https://developer.apple.com/documentation/samplecode), [visionOS-Examples](https://github.com/jordibruin/visionOS-Examples) | **[E]** Indexes and example discovery. Each linked child has independent provenance. | **[D] Research only.** Follow links to primary Apple documentation and review each sample's license before reuse. Do not treat an index as a blanket license. |
| [Swift Numerics](https://github.com/apple/swift-numerics), [Swift Collections](https://github.com/apple/swift-collections), [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) | Potential numerical primitives, temporal containers, and state architecture. | **[D] Defer.** Native `simd`, arrays/ring buffers, `@Observable`, and SwiftUI are sufficient until profiling or state complexity demonstrates a gap. |

The supplied [`mihaelamj/cupertino-sample-code`](https://github.com/mihaelamj/cupertino-sample-code) URL returned `404` at this audit snapshot **[E]**. It is not treated as an available dependency or current mirror; use Apple's primary Sample Code Library and re-audit any relocated mirror before use.

### Spatial interaction, environment, and physics

| Sources | Suitable use | Decision |
|---|---|---|
| [RealityUI](https://github.com/maxxfrazer/RealityUI), [PlanePlopper](https://github.com/daniloc/PlanePlopper), [scene-understanding gist](https://gist.github.com/kkebo/caf4a9e7454ea1dcfe468d635e2ba175), [PhysicsTestApp gist](https://gist.github.com/pardeike/f353262a5c682d956f0a05caade08c4d) | Interaction, anchoring, scene understanding, and physics ideas. | **[D] Concept reference only.** The MVP uses standard gaze/pinch for controls and authored kinematic hit logic. Add plane/scene sensing only for a measured safety or placement need; audit the exact file/revision first. |
| RealityKit collision/physics APIs in [Apple documentation](https://developer.apple.com/documentation/realitykit) | Virtual collision and trigger behavior. | **[D] Adopt only for virtual behavior where it improves the product.** A virtual collision is not physical bag contact or punch force. |

### Rendering and content pipeline

| Sources | Suitable use | Decision |
|---|---|---|
| [Metal spatial rendering](https://github.com/metal-by-example/metal-spatial-rendering), [MetalSplatter](https://github.com/scier/MetalSplatter), [RealityRendererTest gist](https://gist.github.com/arthurschiller/0319824bd741c533d3d35d3aec92ee25) | Custom rendering or captured environments when RealityKit cannot meet a measured requirement. | **[D] Defer.** RealityKit is the MVP renderer. No custom Metal path or Gaussian-splat gym is justified by current user value. |
| [ShaderGraph parameter example](https://github.com/haikusw/schwa_ShaderGraphParameterAnimationExample), [MaterialX](https://github.com/AcademySoftwareFoundation/MaterialX), [OpenUSD](https://github.com/PixarAnimationStudios/OpenUSD), [RCP 3 ShaderGraph catalogue gist](https://gist.github.com/tomkrikorian/ab265be9112901f81a1614818dab783e) | Authoring concepts, pulses, trails, USD/MaterialX pipeline. | **[D] Defer and license-check.** Procedural high-contrast primitives are enough for the MVP; polish cannot outrank legibility, accessibility, or frame time. |

### Computer vision and full-body pose

| Sources | Boundary | Decision |
|---|---|---|
| [MediaPipe](https://github.com/google-ai-edge/mediapipe), [MediaPipe samples](https://github.com/google-ai-edge/mediapipe-samples), [OpenCV for visionOS](https://github.com/LightBuzz/OpenCV), [OpenPose](https://github.com/CMU-Perceptual-Computing-Lab/openpose), [tf-pose-estimation](https://github.com/ZheC/tf-pose-estimation), [TensorFlow pose detection/MoveNet](https://github.com/tensorflow/tfjs-models/tree/master/pose-detection) | These can process frames supplied by an entitled/authorized camera source; they do not create consumer Vision Pro passthrough access **[E]**. | **[D] Reject as an AVP camera bypass. Defer to an explicit iPhone/iPad companion research path.** Prefer Apple Vision on the companion first; compare alternatives only against a defined accuracy/latency need and model/data license. |

### Biomechanics and boxing projects

| Sources | Boundary | Decision |
|---|---|---|
| [OpenSim Core](https://github.com/opensim-org/opensim-core), [OpenSim models](https://github.com/opensim-org/opensim-models), [Simbody](https://github.com/simbody/simbody) | Scientific modeling of articulated dynamics under declared measurements and assumptions. They do not recover unobserved forces or joints from AVP hands alone **[E/I]**. | **[D] Research reference only.** Do not ship these heavyweight C++ stacks or surface inverse-dynamics claims in the MVP. Use them later only with synchronized full-body/contact evidence and specialist review. |
| [ROUND-12](https://github.com/MuneebAnsari/ROUND-12) | Older OpenCV/TensorFlow boxing-coach concept. | **[D] Inspiration only, not architecture or validation.** Modern platform/privacy constraints and scientific measurement contracts govern the implementation. |

### Capture and research recording

| Source | Suitable use | Decision |
|---|---|---|
| [RealityMixerVisionPro](https://github.com/fabio914/RealityMixerVisionPro) | Mixed-reality demo/research capture with a companion device. | **[D] Defer.** Recording creates participant consent, bystander, storage, transfer, deletion, and media-rights obligations. It is not part of the local-by-default MVP. |

## Dependency admission gate

Before any repository, package, model, asset, or snippet enters ShadowBox, record:

1. exact URL and immutable revision;
2. owner, license text, SPDX identifier, notices, and compatibility with distribution;
3. separate rights for code, sample assets, datasets, weights, and generated output;
4. transitive packages and binary artifacts;
5. the user problem that native APIs cannot adequately solve;
6. security/privacy surface, network behavior, and secret handling;
7. size, startup, frame-time, memory, and maintenance cost;
8. independent tests and a removal/fallback plan.

**[D]** If any permission layer is absent or contradictory, the item stays research-only. “Public,” “downloadable,” “MIT code,” or “open-access paper” does not automatically license bundled media, data, or weights.

## Prohibited repository-derived claims

- “Copied from” or “based on” `Spatial_Hack_AI` when only concepts were independently implemented.
- “Latest repo version” without naming the branch and immutable commit.
- “Validated elbow/torso/hip scoring,” “correct hook/uppercut technique,” or “professional coach equivalent.”
- “AI feedback” for deterministic local rules or an optional unevaluated LLM call.
- “Open source” for ShadowBox or a dependency without a verified compatible license and notices.
- “Camera body tracking on Vision Pro” based on OpenCV/MediaPipe availability alone.
- “Validated technique,” “coach-equivalent trajectory grading,” or learning efficacy from the current runtime-wired trajectory-shape diagnostic.
- “Headset tested,” “device-safe,” or “production ready” based on repository documentation, Simulator behavior, source review, or build output.

## Validation boundary

**[V]** The reconciled final-source snapshot has 27 application Swift files and
13 test Swift files; the in-place Defense/accessibility slice changed no counts.
Bilateral fit, tracking-gated Aura start, the original procedural guide,
deterministic coaching, the trajectory-shape diagnostic, fail-closed Defense
range handling, shared audio/visual Defense cue basis, and accessibility layout/
announcement paths are visible in current source. The quiet 05:38 snapshot
separately passed 111/111 tests and clean generic Simulator/unsigned arm64
builds; repository inspiration did not validate those results. That software
evidence does not establish signed installation, live hand-tracking behavior,
audio latency/localization, motion accuracy, comfort, accessibility, or safety
on Apple Vision Pro. Signed/device results remain pending the separately
documented gates in
[`RESEARCH_AND_ROADMAP.md`](RESEARCH_AND_ROADMAP.md).

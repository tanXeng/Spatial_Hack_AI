# ShadowBox implementation references

Reviewed through 2026-08-08. Primary Apple guidance and the installed visionOS 27
SDK interfaces take precedence over tutorial code, especially for beta APIs.

## Primary references

- [The Swift programming language](https://github.com/swiftlang/swift) —
  compiler and standard-library provenance. ShadowBox uses the Swift 6.4
  toolchain bundled with Xcode 27; the repository is a scripting/language
  reference, not a cloned source tree or package dependency.
- [Swift concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/) —
  actor isolation, structured task cancellation, and asynchronous sequences.
- [visionOS get started](https://developer.apple.com/visionos/get-started/) and
  [introductory visionOS samples](https://developer.apple.com/documentation/visionos/introductory-visionos-samples) —
  window-first app structure and spatial-scene examples.
- [Creating immersive spaces](https://developer.apple.com/documentation/visionos/creating-immersive-spaces-in-visionos-with-swiftui) —
  asynchronous open/dismiss flow and immersion-style structure. ShadowBox locks
  the drill to mixed immersion so passthrough stays visible.
- [Embedding controls in an immersive space](https://developer.apple.com/documentation/visionos/embedding-controls-in-an-immersive-space) —
  RealityKit view-attachment pattern. The MVP adds a compact in-space
  Stop & Exit fallback while retaining the normal window control.
- [Presenting windows and spaces](https://developer.apple.com/documentation/visionos/presenting-windows-and-spaces) —
  scene composition and presentation guidance. The primary ShadowBox controls
  use a single-instance window while the drill is a separate mixed space. The
  app requests that window before requesting immersive dismissal, following
  Apple's last-scene sequencing rule; the visible sequence still requires a
  headset test.
- [Tracking and visualizing hand movement](https://developer.apple.com/documentation/visionos/tracking-and-visualizing-hand-movement) —
  `ARKitSession`, `HandTrackingProvider`, authorization, chirality, joint
  tracking, anchor updates, and world-transform composition.
- [`AnchorUpdate.timestamp`](https://developer.apple.com/documentation/arkit/anchorupdate/timestamp) —
  monotonic update time used for per-hand motion and velocity calculations;
  receipt time remains separate for freshness and watchdog handling.
- [ARKit in visionOS](https://developer.apple.com/documentation/arkit/arkit-in-visionos) —
  privacy-preserving providers used to keep consumer hand and device tracking
  separate from raw-camera assumptions.
- [Accessing the main camera](https://developer.apple.com/documentation/visionos/accessing-the-main-camera) —
  confirms that forward-facing main-camera access is an enterprise capability,
  not an API used by this consumer MVP.
- [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons) —
  visionOS icon dimensions, layered presentation, legibility, and safe
  composition.

## Supplied learning references

- Owner-supplied systems research:
  `/Users/event/.codex/attachments/b2142437-926a-4f92-b59b-c867b334475a/pasted-text.txt` —
  used as a routing map across Vision Pro capabilities, spatial UX, motion
  analysis, biomechanics, ML, and source layout. Claims affecting the shipped
  MVP were checked against Apple documentation and the installed SDK. Its list
  of repositories did not authorize wholesale copying, new dependencies, or
  empty speculative architecture.
- [Hacking with Swift](https://www.hackingwithswift.com/) — generic Swift and
  SwiftUI state, task, and scene-lifecycle learning reference.
- [Explore SwiftUI](https://exploreswiftui.com/) — visual control and component
  reference for the compact setup/results window.
- [Step Into Vision](https://stepinto.vision/learn-visionos/) — supplemental
  hand-tracking, mixed-immersion, and attachment examples. Concepts are used
  only after checking the API against Apple documentation and the installed SDK.
- Local sample: `/Users/event/Downloads/IntroRealityKit/` — reviewed read-only
  for asynchronous `ModelEntity` loading, opacity, grounding shadow, and
  optional debug manipulation. Its unlicensed `GlassCube.usdz` is not copied.
  Its minimal immersive lifecycle is not reused because it lacks cancellation,
  dismissal, hand tracking, and error handling.
- [Spatial_Hack_AI at pinned commit `b570f2e`](https://github.com/tanXeng/Spatial_Hack_AI/tree/b570f2e31b638e97fe59110f9909bcd20228bbc7) —
  reviewed read-only as the owner-authorized reference for the current
  information hierarchy and UI layering. The remote repository was not cloned
  or modified. No declared license was identified at the pinned state, so no
  source code, authored asset, or other repository content was copied verbatim;
  the ShadowBox implementation is an independent SwiftUI/RealityKit build.

## How the references shape this MVP

- The normal SwiftUI window opens on three owner-defined pillars:
  Anthropometry, Aura Punch, and Reactive Strike. Reactive Strike exposes the
  six-pad Virtual Board, Physical Bag Preview, and Stationary Defense modes.
- Anthropometry supports a validated scalar boxer profile plus live guard and
  comfortable-reach calibration. Canonical height, arm span, arm lengths,
  shoulder width, and comfortable reach are stored locally; live joint and
  world-space calibration coordinates remain session-scoped.
- Bag configuration is also local scalar data only. No joint samples, world
  transforms, room map, camera data, participant trace, or training-result
  history is persisted or uploaded.
- Aura Punch is hand-only coaching. It evaluates fist-path progress, extension,
  speed, and the non-punching hand's guard; it makes no claim to observe or
  correct feet, hips, legs, torso, or whole-body posture.
- The Virtual Board is a deterministic six-pad jab/cross reaction drill.
  Logical geometry and plain Swift state determine cues and contacts;
  RealityKit appearance does not decide a hit.
- Stationary Defense uses device position only as a head-position proxy for
  slip-left, slip-right, and duck cues. It is a planted-feet MVP and does not
  score footwork, hip movement, balance, or professional defensive technique.
- Physical Bag Preview is a static, non-contact visualization. It does not align
  to, scan, or track a real bag; detect impact; estimate force or power; or use
  an iPhone/iPad companion, marker, shared coordinate system, or network link.
- ARKit remains isolated behind plain `Sendable` samples. Tracking loss, system
  inactivity, and terminal provider errors retain explicit pause or abort
  semantics, and a persistent exit path remains available in mixed immersion.
- No external package, network service, ML model, third-party authored binary
  asset, participant trace, or raw-camera access is added for this MVP.
- The unused immersive-video player and stock authored template scene were
  removed after the programmatic RealityKit entry path was verified. A new
  project-owned raster app icon is the only authored visual asset added in this
  pass.

Tutorial references are supplemental rather than authoritative. No source code
or binary asset was copied from them.

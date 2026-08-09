# CLAUDE.md

Context file for Claude Code. Keep this updated as decisions get made during the hackathon.

## Project Overview

**Name:** AI Ghost Coach (working title)

**Hackathon prompt:** "How might we allow athletes to learn and practice their sport with spatial computing & AI?"

**One-liner:** An Apple Vision Pro app that overlays a ghost silhouette onto the user's own body to teach beginner boxers correct punching technique, then scores their attempt and tells them how to improve.

**Platform:** visionOS (Apple Vision Pro). This is a spatial-first app — not a flat iOS port.

**Primary user:** A beginner boxer training at home with no coach and no gym access.

## Feature Set

All three features in `TrainingFeature` are now built.

| Feature | Status | Description |
|---|---|---|
| **Aura Punch** | **Built** | Ghost arm silhouette overlaid on the user's body demonstrates a punch; user replicates it; app scores technique and gives feedback. |
| Reactive Strike | Built | Spawns floating targets and times the user's reaction. Has three modes — see below. Owns `HandTrackingService` and the immersive scene root, and hosts `AuraPunchSession`. |
| Anthropometry | Built | Measures forward reach per arm and captures the guard pose. **Gates the app** — an uncalibrated launch opens straight into it and no other feature is reachable until it produces a measurement. Feeds both the Reactive Strike spawn volume and Aura Punch's `BodyMeasurements`. |

**Punching Bag no longer exists in any form.** It was briefly `ReactiveStrikeMode.bag`; the `target-fix` merge removed that case and `ReachProfile.bagZone` outright. Reactive Strike has two modes:

| Mode | Description |
|---|---|
| `.air` | Targets float in front of you. |
| `.combination` | Throw a stance-aware punch sequence, validated punch by punch. |

Both resolve to `ReachProfile.air`.

### Aura Punch — detailed spec

1. A silhouette of a person's **arms** is overlaid directly on top of the user's own body, aligned to their real limbs.
2. The silhouette performs the selected punch (e.g. a jab) to demonstrate correct technique.
3. The user then attempts the same punch, trying to match the silhouette's motion.
4. The app evaluates how closely the user's motion matched the reference and returns:
   - a **score**, and
   - **specific feedback** on what to improve (e.g. "your elbow flared out").

### Combination Mode — detailed spec

`Combination.swift` defines `PunchType` using conventional boxing numbering (1 jab, 2 cross, 3 lead hook, 4 rear hook, 5 lead uppercut, 6 rear uppercut) and a catalogue of `Combination` values (Jab-Cross, Double Jab-Cross, Jab-Cross-Hook, Jab-Cross-Hook-Cross, Jab-Cross-Uppercut-Cross).

`CombinationPunchValidator` is a pure state machine that validates one `CombinationTarget` at a time. It requires, in order:

1. The required fist near guard.
2. Meaningful outbound movement from guard with positive velocity toward the target.
3. Contact with the target **by the required fist** on a later sample.

The caller passes the required-hand fist and the other fist as separate arguments, so the validator never infers hand identity from target proximity — contact by the wrong hand is reported distinctly and never advances validation. `PunchType.requiredHand(for: stance)` resolves lead/rear against the user's stance.

## UI Flow

Navigation is a route enum owned by `TrainingFlowCoordinator`, rendered by `BoxingCoachRootView`. There is no Start Screen. **Calibration is the root on an uncalibrated launch**; the feature menu is the root thereafter.

```
launch (uncalibrated) → .experience(.calibration)   ← mandatory, Back hidden
                              ↓ Continue to Training
.features  ──────────→ [Anthropometry, Aura Punch, Reactive Strike]
   ├─ .auraSetup      → stance picker + technique picker (ForEach(Technique.all))
   ├─ .reactiveSetup  → mode picker (air / bag / combination)
   │     └─ .combinationSetup → stance picker + combination picker
   ├─ Anthropometry   → .experience(.calibration)   ← re-measure, Back shown
   └─ .experience(TrainingSelection) → ready → immersive drill → score + feedback
```

`TrainingSelection` is the committed choice — `.aura(technique:stance:)`, `.reactive(mode:combination:stance:)`, or `.calibration`.

`chooseFeature` refuses any non-Anthropometry feature while uncalibrated and bounces back to calibration. `TrainingFeature.isAvailable` is now `true` for everything; the `.unavailableFeature` route and `UnavailableFeatureView` were removed by the `target-fix` merge, which is safe because the gate makes them unreachable.

**`target-fix` deleted `TrainingFeature.anthropometry`; the merge kept it deliberately.** On that branch Anthropometry was still an inert "coming soon" card with nothing behind it. Here it is the calibration gate that `TrainingSelection.calibration` and every other feature depend on — removing the case breaks the app-entry flow.

### Scene management — read before touching navigation

`TrainingFlowCoordinator` **serializes every immersive-space transition**, and this is load-bearing. Selection and experience views only emit user intent; they never open a scene, dismiss one, or mutate a drill engine directly. Overlapping SwiftUI tasks previously left the app half-open.

Specific invariants that were each fixed after a real bug — do not undo them:

- The control scene is a single-instance `Window`, **not** a `WindowGroup`. A named `WindowGroup` creates a new window on every `openWindow(id:)`, which stacked duplicate control layers when both explicit and system-driven cleanup restored the UI. The scene ID is versioned (`BoxingCoachControlWindow.Single`) so visionOS won't restore pre-fix sessions.
- Starting a drill waits for **real scene readiness** (`immersiveSceneDidBecomeReady`, 5 s timeout), not a fixed sleep. The selection is applied to the engine only after the scene is usable, so a failed retry leaves the previous score intact instead of erasing it.
- Ending a drill waits for the restored window's actual `onAppear` (`waitForControlWindowReadiness`, 2 s timeout) before dismissing immersion. Dismissing early on a loaded device discards the final result — no scene exists yet to own it.
- `endExperience` calls `session.stopDrill()` **before** restoring the window. Leaving the engine alive during that wait let it record another hit or finish scoring after the user explicitly ended training.
- `finalizeImmersiveClosure` handles both explicit dismissal and the system taking the space away.

### Navigation chrome

`TrainingDetailScaffold` (in `UI/Shared/TrainingComponents.swift`) is the shared detail-screen wrapper: a **Back** button pinned in an `HStack` outside the `ScrollView`, then title/subtitle/content inside it.

That pinning is load-bearing, not styling: when the content stack outgrows the window, SwiftUI centres the overflow and pushes an unpinned nav bar outside the window's bounds, where it renders but is **not hit-tested** — the button looks present and is completely untappable.

All controls take a `controlsDisabled` flag driven by `flow.controlsDisabled` (true whenever a transition is in flight).

Still unbuilt: **home** and **settings**.

## Tech Stack

- **UI:** SwiftUI for 2D windows.
- **Spatial content:** RealityKit + Reality Composer Pro for the arm silhouette entity.
- **Session:** visionOS `ImmersiveSpace` in **mixed immersion** — the user must see their real room and their real arms for the overlay to make sense. Do not use full immersion for Aura Punch.
- **Tracking:** ARKit `HandTrackingProvider` for hand/wrist joints, plus `WorldTrackingProvider` for the device (head) anchor used as torso reference.
- **AI/scoring:** motion comparison against a reference trajectory (see below), with an LLM used to turn numeric scoring output into natural-language coaching feedback.

`Info.plist` **must** carry `NSHandsTrackingUsageDescription`. Without it `session.requestAuthorization(for: [.handTracking])` never returns `.allowed` and every drill dies at "Hand tracking permission denied" — with no build error to warn you.

## ⚠️ Key Technical Constraint — read before designing the silhouette

visionOS ARKit provides **hand skeleton tracking (wrist + finger joints per hand)** and the **head/device transform**. It does **not** provide full-body skeletal tracking — there is no direct shoulder or elbow joint feed the way there is on some other platforms.

This means the "arm silhouette overlaid on the user's body" has to be **constructed**, not read directly:

- Wrist position and orientation → available directly from hand tracking.
- Shoulder position → **estimated** from the head transform plus body measurements (this is exactly what the Anthropometry feature is for — it supplies arm length and shoulder width so the silhouette scales to the actual user).
- Elbow position → **solved via inverse kinematics** from the estimated shoulder and the tracked wrist.

Practical implications for Claude Code:
- `ArmPoseSolver` takes `(headTransform, wristTransform, bodyMeasurements) -> (shoulder, elbow, wrist)`. Keep the IK isolated there so it can be tuned independently.
- `ArmPoseSolver` is fed `BodyCalibration.measurements` — the measured reach rescales the arm chain, with the scale clamped to `0.80...1.25` of average adult so a bad measurement leaves the ghost inaccurate rather than visibly detached. Everything else (shoulder width, eye-to-shoulder offsets) is still average-adult.
- ARKit data providers are **single-use**: once their session stops they enter `.stopped` and can never run again. The immersive space opens and closes on every back-out, so `HandTrackingService.start()` builds a **fresh `ARKitSession` and fresh providers each time**. Reusing the originals meant tracking worked exactly once per launch and every drill after the first silently received no anchors.
- Hand-tracking update rate and occlusion (hands leaving the field of view mid-punch) materially affect quality. Dropped frames are handled explicitly.

Verify the current visionOS ARKit hand-tracking API surface against Apple's docs before writing tracking code — do not rely on memory for exact type and property names.

## Scoring Approach (Aura Punch)

1. Reference punch = a **time-series of wrist/elbow/shoulder positions** in body-relative space, normalized by the user's measurements so it's scale-invariant.
2. The user's attempt is recorded the same way.
3. Compared with **Dynamic Time Warping (DTW)** so a slower or faster punch isn't unfairly penalized — this grades form, not speed.
4. **Four** scored sub-metrics (`TechniqueScore.swift`):
   - **Extension** — did the punch reach full extension?
   - **Path** — did the fist travel a correct line vs. loop out?
   - **Elbow alignment** — did the elbow stay tucked or flare?
   - **Retraction** — did the hand return to guard afterward?
5. Sub-metric values feed the LLM, which generates natural-language coaching. **The LLM does not invent the score** — it explains scores computed deterministically. This keeps feedback trustworthy and reproducible on stage.

### Guard is coached, not scored

Guard was removed from the scored sub-metrics. `Scoring/GuardCoach.swift` now handles it **live**: `isGuardUp` returns `true` / `false` / `nil` (hand not visible — do **not** pause on `nil`). When the non-punching hand drops, both `AuraPunchSession` and `ReactiveStrikeSession` pause and show `GuardCoach.waitMessage` until it comes back up.

### Reach calibration — measure the hold, never the ramp

`BodyCalibration` (`Models/BodyCalibration.swift`) holds one measurement per launch: forward reach per arm plus the guard pose. It is created in `BoxingCoachApp.init` and handed to both `ReactiveStrikeSession` and `TrainingFlowCoordinator`, so there is exactly one instance. **In-memory only, deliberately** — a persisted measurement would apply one person's arms to whoever put the headset on next.

Two rules here were each fixed after targets spawned at roughly two-thirds of arm's length:

- **`ReachCalibration.settledForwardReach`** requires a *plateau*: the longest run of samples within `plateauTolerance` (1.5 cm) of the peak must span `plateauDuration` (0.30 s). The rule it replaced finalized 0.25 s after the fist first cleared guard and then took the 75th percentile — both halves measured the outbound ramp, and a punch needs ~0.3–0.5 s to reach lockout, so the window closed mid-flight. `robustForwardReach` survives only as the timeout fallback.
- **`ReachProfile.calibrated`** anchors `forwardMax` to the measurement and puts `forwardMin` at `reach * (1 - forwardBandFraction)` — 0.10 for Air, the only profile left. **Every target therefore lands in the last 10% of the user's reach**, so the drill always demands near-full extension, which is the technique being coached. A wide forward band let targets spawn well inside the user's range where a half-extended arm scores a hit. The fraction is proportional, not a fixed distance, so it means the same thing at any body size: 0.50 m reach → 0.45–0.50, 0.80 m reach → 0.72–0.80. The authored `forwardMin`/`forwardMax` literals are now only the uncalibrated fallback. Lateral bounds are not scaled at all — how wide a user punches has no dimensional relationship to how far forward they reach.

  Combination Mode is unaffected: it already passes `reachProfile.forwardMax` as `forwardBase` and applies its own per-punch multipliers (hook 0.88, uppercut 0.82) as deliberate punch geometry.

Also: the calibration cue spawns at `BodyMeasurements.averageAdult.armReach`, never at the profile's `forwardMax`. Air's 0.75 m far edge is past most people's reach, so cueing there made users lean, which moves `BodyFrame.origin` and corrupts the measurement being taken.

One measurement serves both Reactive Strike modes and Aura Punch — `mode.reachProfile.calibrated(...)` preserves each mode's shape, so there is no per-mode calibration cache and switching Air → Combination never re-measures.

### Uppercut extension is measured differently — do not "simplify" this

Most punches peak at maximum radial shoulder-to-fist distance. An uppercut does not: loading beside the hip is radially **farther** from the shoulder than the centreline finish at the chin.

`PunchExtensionSemantics.magnitude(samples:techniqueID:)` (in `MotionRecorder.swift`) is the single shared rule used by both recorded attempts and authored references:

- Uppercut → `orderedVerticalRise`, the largest upward displacement whose **low sample occurs before** its high sample. Order matters: a plain `maxY - minY` would credit a hand that starts high and merely drops to the hip without ever punching upward.
- Everything else → peak `reachFraction`.

The same asymmetry drives `ReferencePunch.peakSample` / `peakTime` / `shouldEmphasize(_:)`. Treating radial distance as the uppercut's peak made the guide hold at the hip and play the actual strike during "bring it back."

## Project Structure (as built)

```
BoxingCoach/
  BoxingCoachApp.swift             # BoxingCoachSceneID; single-instance Window + ImmersiveSpace
  AuraPunchSession.swift           # Guided follow-along → attempt → score → feedback
  ReactiveStrikeSession.swift      # Target drills; owns HandTrackingService + AuraPunchSession
  HandTrackingService.swift        # ARKit wrapper; fresh session/providers per start
  Combination.swift                # PunchType (1–6), Combination catalogue, CombinationTarget
  CombinationPunchValidator.swift  # Pure per-target punch validation state machine
  TargetController.swift  ReachProfile.swift  DrillMetrics.swift
  Models/
    Technique.swift                # Data-driven technique list + PunchHand
    BodyMeasurements.swift         # Proportions + Stance, BodySide
    BodyCalibration.swift          # One measured body per launch, shared by every feature
  Spatial/
    ArmSilhouetteEntity.swift      # RealityKit ghost arms
    ArmPoseSolver.swift            # head + wrist + measurements -> shoulder/elbow/fist
  Scoring/
    MotionRecorder.swift           # RecordedAttempt + PunchExtensionSemantics
    DTWComparator.swift  TechniqueScore.swift  FeedbackGenerator.swift
    GuardCoach.swift               # Live guard coaching (not scored)
  Resources/
    ReferencePunchLibrary.swift    # Hand-authored trajectories + JSON drop-in seam
  UI/
    Flow/
      BoxingCoachRootView.swift    # Window composition root; routes -> views
      TrainingFlowCoordinator.swift # Routes + serialized immersive transitions
    Selection/
      TrainingSelectionViews.swift # Feature, Reactive, Combination, Aura, Unavailable
    Experience/
      TrainingExperienceView.swift    # Ready / running / results
      BoxingCoachImmersiveView.swift  # RealityView root; reports readiness to the coordinator
      ImmersiveInstructionBanner.swift
    Shared/
      TrainingComponents.swift     # TrainingDetailScaffold, status/error cards, meters

BoxingCoachTests/
  BoxingCoachBaselineTests.swift  CombinationPunchValidatorTests.swift
  ReachProfileTests.swift  TrainingFlowCoordinatorTests.swift
```

There is no `Feature.swift` — the feature list is the `TrainingFeature` enum in `TrainingFlowCoordinator.swift`.

## Building

`xcode-select` points at CommandLineTools, so a bare `xcodebuild` fails. Override `DEVELOPER_DIR`:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project BoxingCoach.xcodeproj -scheme BoxingCoach \
  -destination 'generic/platform=visionOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Build for **device** (`generic/platform=visionOS`), not just the simulator — a simulator build skips everything inside `#if !targetEnvironment(simulator)`, which is most of `HandTrackingService`'s ARKit code.

Tests (`make test`, or directly):

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project BoxingCoach.xcodeproj -scheme BoxingCoach -configuration Debug \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=27.0' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Both targets use `PBXFileSystemSynchronizedRootGroup`, so **new files under `BoxingCoach/` or `BoxingCoachTests/` are picked up automatically** — no `project.pbxproj` edit needed when adding a source file.

## Coding Conventions

- Swift + SwiftUI + RealityKit idioms.
- `@Observable` throughout, not legacy `ObservableObject`.
- The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Pure data/math types that must be readable from off-main code need an explicit `nonisolated` — see `PunchType`, `Stance`, `BodySide`, `Technique`, `CombinationPunchValidator`.
- **Features and techniques are data, not screens.** Adding a technique or a combination should be a data change, not a new view.
- **Anthropometry is a stub.** `BodyMeasurements` has default values and the flow routes through `UnavailableFeatureView` — no measurement capture logic.
- Anything network/LLM-backed sits behind `FeedbackGenerating` with a mock implementation, so UI work isn't blocked and the demo has a fallback if conference wifi fails.
- Comment the IK and coordinate-space math heavily. Coordinate frames (world vs. head-relative vs. body-relative) are where this project is most likely to break, and teammates read this code cold.

## Priorities (in order)

1. Silhouette arms render aligned to the user's real arms and play a jab demo — this is the whole idea.
2. Full flow works without crashing: Features → setup → Session → Score.
3. Scoring produces a defensible number with sub-metrics, even if thresholds are hand-tuned.
4. LLM feedback layer.
5. Anything else — bonus only.

## Decided

- **Reference punch authoring** — hand-authored keyframes in `ReferencePunchLibrary`, resampled at 60 Hz with the elbow solved by the same IK used on live data. `recordedPunch(for:)` is the drop-in seam: a `ReferencePunches/<techniqueID>.json` in the bundle wins over the synthetic version automatically.
- **Ready-to-attempt signal** — no gesture. Guided follow-along, then a 3-2-1 countdown, then a fixed `attemptWindow` (3.0 s).
- **Demo reps** — 4 guided reps (`guidedRepetitions`), each played ~15% faster than the last down to a 0.55 floor. The ghost holds at full extension and again at guard until the user's fist reaches its actual position, so a slow first rep costs real time.
- **Alternating hands** — `.either`-hand techniques (hook, uppercut) alternate sides rep to rep. Which arm actually threw is inferred from the strongest technique-specific extension, not assumed.
- **Guard pauses the drill instead of costing points** (see above).
- **Calibration runs once per launch, before anything else.** Anthropometry gates the app rather than living as an optional menu item, and its result is in-memory only — every launch re-measures. See the calibration section above.
- **`@Observable`** — in use throughout.

## Open Questions / TODO

- [ ] **Feedback is offline-only today.** `ClaudeFeedbackGenerator` is written and current, but nothing constructs it — `AuraPunchSession.init` defaults to `MockFeedbackGenerator` and `ReactiveStrikeSession` never overrides it. Wiring it up needs an API key, and a key compiled into the binary is extractable by anyone with the `.app`.
- [ ] **Scoring thresholds are hand-tuned from geometry, not calibrated** against real attempts (`ScoringThresholds`). Same for the reference trajectories, `GuardCoach.dropThreshold` (0.46), and `ReachCalibration`'s plateau constants.
- [ ] **Calibration measures the arm chain only.** `shoulderWidth`, `eyeToShoulderDrop`, and `eyeToShoulderSetback` are still `averageAdult`, and the measured value is fist-forward-of-shoulder-line rather than true shoulder-to-fist. Good enough to place targets and normalize scoring; not a real anthropometric capture.
- [ ] **Calibration has only been verified in the simulator and by unit test.** The plateau detector's tolerance and duration need a real device pass — a user who never quite holds still falls through to the old percentile rule and gets an under-measured volume.
- [ ] Silhouette visual treatment — must not obscure the user's view of their real arms.
- [ ] Confirm deployment target visionOS version.

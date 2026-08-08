# CLAUDE.md

Context file for Claude Code. Keep this updated as decisions get made during the hackathon.

## Project Overview

**Name:** AI Ghost Coach (working title)

**Hackathon prompt:** "How might we allow athletes to learn and practice their sport with spatial computing & AI?"

**One-liner:** An Apple Vision Pro app that overlays a ghost silhouette onto the user's own body to teach beginner boxers correct punching technique, then scores their attempt and tells them how to improve.

**Platform:** visionOS (Apple Vision Pro). This is a spatial-first app — not a flat iOS port.

**Primary user:** A beginner boxer training at home with no coach and no gym access.

## Feature Set

Four features are planned. Two are built. Do not implement the others unless explicitly asked.

| Feature | Status | Description |
|---|---|---|
| **Aura Punch** | **Built** | Ghost arm silhouette overlaid on the user's body demonstrates a punch; user replicates it; app scores technique and gives feedback. |
| Reactive Strike | Built | Spawns floating targets and times the user's reaction. Shares `HandTrackingService` and the immersive scene root with Aura Punch — see `ReactiveStrikeSession`. |
| Punching Bag | Not yet — do not build | Virtual bag to strike. |
| Anthropometry | Not yet — do not build | Body measurement capture used to scale the silhouette to the user. Everything downstream already reads `BodyMeasurements`, so this only has to produce one. |

### Aura Punch — detailed spec

1. A silhouette of a person's **arms** is overlaid directly on top of the user's own body, aligned to their real limbs.
2. The silhouette performs the selected punch (e.g. a jab) to demonstrate correct technique.
3. The user then attempts the same punch, trying to match the silhouette's motion.
4. The app evaluates how closely the user's motion matched the reference and returns:
   - a **score**, and
   - **specific feedback** on what to improve (e.g. "your elbow flared out", "you dropped your guard hand").

## UI Flow

**As built** (`BoxingCoachContentView`) — there is no Start Screen and no Anthropometry prompt; the feature menu is the root:

```
Feature Menu  ───────→ [Anthropometry (coming soon), Aura Punch, Reactive Strike]
    ↓ (Aura Punch)
Technique Picker  ───→ [jab, cross, hook, uppercut, ...]  ← ForEach(Technique.all)
    ↓
Aura Punch Session  ─→ guided follow-along → countdown → attempt → score + feedback
```

Entering a session opens the mixed `ImmersiveSpace`; the 2D window stays up and drives it.

### Navigation — partially built
The detail screens carry a **Back** and an **Exit** button, pinned outside a `ScrollView`. That pinning is load-bearing, not styling: when the content stack outgrows the window, SwiftUI centres the overflow and pushes an unpinned nav bar outside the window's bounds, where it renders but is **not hit-tested** — the button looks present and is completely untappable.

Still unbuilt: **home** and **settings**, and the reusable `NavigationChrome` component. Nav is currently inline in `featureDetail`.

## Tech Stack

- **UI:** SwiftUI for 2D windows (Start, Home, Technique Selection, Anthropometry prompt, results).
- **Spatial content:** RealityKit + Reality Composer Pro for the arm silhouette entity.
- **Session:** visionOS `ImmersiveSpace` in **mixed immersion** — the user must see their real room and their real arms for the overlay to make sense. Do not use full immersion for Aura Punch.
- **Tracking:** ARKit `HandTrackingProvider` for hand/wrist joints, plus the device (head) transform for torso reference.
- **AI/scoring:** motion comparison against a reference trajectory (see below), with an LLM used to turn numeric scoring output into natural-language coaching feedback.

## ⚠️ Key Technical Constraint — read before designing the silhouette

visionOS ARKit provides **hand skeleton tracking (wrist + finger joints per hand)** and the **head/device transform**. It does **not** provide full-body skeletal tracking — there is no direct shoulder or elbow joint feed the way there is on some other platforms.

This means the "arm silhouette overlaid on the user's body" has to be **constructed**, not read directly:

- Wrist position and orientation → available directly from hand tracking.
- Shoulder position → **estimated** from the head transform plus body measurements (this is exactly what the Anthropometry feature is for — it supplies arm length and shoulder width so the silhouette scales to the actual user).
- Elbow position → **solved via inverse kinematics** from the estimated shoulder and the tracked wrist.

Practical implications for Claude Code:
- Build an `ArmPoseSolver` that takes `(headTransform, wristTransform, bodyMeasurements) -> (shoulder, elbow, wrist)` and keep the IK isolated there so it can be tuned independently.
- While Anthropometry is unimplemented, feed `ArmPoseSolver` **hardcoded average adult measurements** from a `BodyMeasurements` struct with sensible defaults. This keeps the pipeline complete and swappable later.
- Hand-tracking update rate and occlusion (hands leaving the field of view mid-punch) will materially affect quality. Handle dropped-tracking frames explicitly rather than assuming continuous data.

Verify the current visionOS ARKit hand-tracking API surface against Apple's docs before writing the tracking layer — do not rely on memory for exact type and property names.

## Scoring Approach (Aura Punch)

Recommended approach for a hackathon timeframe:

1. Record the reference punch as a **time-series of wrist/elbow/shoulder positions** in body-relative space (normalized by the user's measurements so it's scale-invariant).
2. Record the user's attempt the same way.
3. Compare with **Dynamic Time Warping (DTW)** so a slower or faster punch isn't unfairly penalized — you're grading form, not speed (unless speed is an explicit sub-metric).
4. Break the score into a few named sub-metrics so feedback can be specific rather than a single opaque number. Suggested:
   - **Extension** — did the punch reach full extension?
   - **Path** — did the fist travel in a straight line (jab/cross) vs. loop out?
   - **Elbow alignment** — did the elbow stay tucked or flare?
   - **Guard** — did the non-punching hand stay up near the chin?
   - **Retraction** — did the hand return to guard afterward?
5. Feed the sub-metric values to the LLM to generate natural-language coaching feedback. **The LLM should not invent the score** — it explains scores computed deterministically. This keeps feedback trustworthy and reproducible on stage.

## Project Structure (as built)

```
BoxingCoach/
  BoxingCoachApp.swift             # WindowGroup + ImmersiveSpace setup
  BoxingCoachContentView.swift     # Every 2D screen — menu, pickers, results
  BoxingCoachImmersiveView.swift   # RealityView root; reports open/close to the session
  AuraPunchSession.swift           # Guided follow-along → attempt → score → feedback
  ReactiveStrikeSession.swift      # Target drill; owns HandTrackingService + AuraPunchSession
  HandTrackingService.swift        # ARKit wrapper, handles dropped frames
  TargetController.swift  ReachProfile.swift  DrillMetrics.swift
  Models/
    Technique.swift                # Data-driven technique list + PunchHand
    BodyMeasurements.swift         # Defaults now, Anthropometry-populated later
  Spatial/
    ArmSilhouetteEntity.swift      # RealityKit ghost arms
    ArmPoseSolver.swift            # head + wrist + measurements -> shoulder/elbow/fist
  Scoring/
    MotionRecorder.swift  DTWComparator.swift  TechniqueScore.swift  FeedbackGenerator.swift
  Resources/
    ReferencePunchLibrary.swift    # Hand-authored trajectories + JSON drop-in seam
```

No `Navigation/` or `Screens/` split — the 2D UI is one file. There is no `Feature.swift`; the feature list is a private enum inside `BoxingCoachContentView`.

## Building

`xcode-select` points at CommandLineTools, so a bare `xcodebuild` fails. Override `DEVELOPER_DIR`:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project BoxingCoach.xcodeproj -scheme BoxingCoach \
  -destination 'generic/platform=visionOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Build for **device** (`generic/platform=visionOS`), not just the simulator — a simulator build skips everything inside `#if !targetEnvironment(simulator)`, which is most of `HandTrackingService`'s ARKit code.

## Coding Conventions

- Swift + SwiftUI + RealityKit idioms.
- Prefer `@Observable` over legacy `ObservableObject` — but confirm the deployment target first, since this depends on the visionOS/Swift version.
- **Features and techniques are data, not screens.** Define all four features in `Feature.swift` with an `isImplemented` flag; unimplemented ones render as visibly disabled / "coming soon" cards. Adding a technique should be a data change, not a new view.
- **Anthropometry is a stub.** Build the prompt screen and the `BodyMeasurements` struct with default values, and wire the flow through it — but no measurement capture logic.
- Isolate anything network/LLM-backed behind a protocol with a mock implementation (e.g. `FeedbackGenerating`), so UI work isn't blocked and the demo has a fallback if conference wifi fails.
- Comment the IK and coordinate-space math heavily. Coordinate frames (world vs. head-relative vs. body-relative) are where this project is most likely to break, and teammates will be reading this code cold.

## Priorities (in order)

1. Silhouette arms render aligned to the user's real arms and play a jab demo — this is the whole idea, and everything else is decoration without it.
2. Full flow works without crashing: Start → Home → Technique → Anthropometry stub → Session → Score.
3. Scoring produces a defensible number with sub-metrics, even if thresholds are hand-tuned.
4. LLM feedback layer.
5. Anything else (the other three features) — bonus only.

## Decided

- **Reference punch authoring** — hand-authored keyframes in `ReferencePunchLibrary`, resampled at 60 Hz with the elbow solved by the same IK used on live data. `recordedPunch(for:)` is the drop-in seam: a `ReferencePunches/<techniqueID>.json` in the bundle wins over the synthetic version automatically.
- **Ready-to-attempt signal** — no gesture. Guided follow-along, then a 3-2-1 countdown, then a fixed `attemptWindow`.
- **Demo reps** — 4 guided reps (`guidedRepetitions`), each played ~15% faster than the last down to a 0.55 floor. The ghost holds at full extension and again at guard until the user's fist reaches its actual position, so a slow first rep costs real time.
- **`@Observable`** — in use throughout.

## Open Questions / TODO

- [ ] **Feedback is offline-only today.** `ClaudeFeedbackGenerator` is written and current, but nothing constructs it — `AuraPunchSession.init` defaults to `MockFeedbackGenerator` and `ReactiveStrikeSession` never overrides it. Wiring it up needs an API key, and a key compiled into the binary is extractable by anyone with the `.app`.
- [ ] **Scoring thresholds are hand-tuned from geometry, not calibrated** against real attempts (`ScoringThresholds`). Same for the reference trajectories.
- [ ] **`BodyMeasurements` is assumed, not measured** — everyone gets `averageAdult` (0.66 m reach). Normalization divides by that assumed reach, so a shorter-armed user reads below full extension even at true lockout and loses Extension points they cannot recover. This is the biggest source of unfairness in the score, and the reason Anthropometry matters.
- [ ] Silhouette visual treatment — must not obscure the user's view of their real arms.
- [ ] Confirm deployment target visionOS version.

# Boxing Coach — AI Ghost Coach

An Apple Vision Pro app that teaches beginner boxers correct punching technique. A translucent
ghost arm is overlaid on your own body, demonstrates a punch, then watches you copy it and tells
you what to fix.

Built for the "learn and practice your sport with spatial computing & AI" hackathon prompt.
Product spec and scope decisions live in [`CLAUDE.md`](CLAUDE.md) — this file explains **how the
code is put together**.

---

## Status

| Feature | State |
|---|---|
| **Aura Punch** | **Built.** Demo → attempt → score → coaching feedback. |
| Reactive Strike | Built (pre-existing team base). Floating targets, reaction-time drill. |
| Anthropometry | Stub. `BodyMeasurements.averageAdult` feeds the pipeline; no capture logic. |
| Punching Bag | Not started. |

**Compiles clean** for visionOS 27.0 (zero errors, zero warnings). **Not yet run on device** — the
scoring thresholds in particular are derived from geometry, not from watching anyone actually
punch, so expect to tune them.

---

## Building

`xcode-select` on the dev machine points at CommandLineTools, so a bare `xcodebuild` fails.
Override `DEVELOPER_DIR` rather than running `sudo xcode-select`:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project BoxingCoach.xcodeproj -scheme BoxingCoach \
  -destination 'generic/platform=visionOS Simulator' -configuration Debug build
```

The Xcode project uses **synchronized file groups** — dropping a `.swift` file anywhere under
`BoxingCoach/` compiles it automatically. Never hand-edit `project.pbxproj` to add a file.

> ⚠️ Hand tracking does not work in the simulator. The flow will reach "Hold your guard up…" and
> time out after 8 seconds. Aura Punch has to be tested on a device.

---

## The core problem

visionOS gives you the **head** and the **hands**. It does not give you a torso or a shoulder.
But a punch is judged on the shoulder and the elbow — so most of the arm has to be *reconstructed*
rather than read.

```
ARKit gives us:          We need:
  head transform    →      shoulder   (estimated from head + body measurements)
  wrist joint       →      elbow      (solved with two-bone IK)
  forearmArm joint  →      wrist      (tracked directly)
  fist point        →      fist       (tracked directly)
```

**One correction to the spec:** visionOS *does* expose `.forearmWrist` and `.forearmArm` joints
(hierarchy `wrist` → `forearmWrist` → `forearmArm`), so the elbow isn't completely unavailable.
But `forearmArm` is extrapolated from the hand, not observed — its *distance* from the shoulder
drifts, and using it directly makes the ghost's bones visibly stretch and shrink.

So `ArmPoseSolver` splits the job by what each input is actually good at:

- **The tracked joint picks the direction** the elbow bends (it's reliable for that).
- **IK picks the distance** along that direction (guarantees bones keep their length).

When `forearmArm` isn't tracked — common at full extension, when the elbow leaves the downward
cameras' view — it falls back to an anatomical pole (elbow hangs below and slightly behind).

---

## Pipeline

```
HandTrackingService     ARKit wrapper. Hands + device anchor, dropouts surfaced not hidden.
        ↓
ArmPoseSolver           head+wrist+measurements → shoulder/elbow/wrist/fist, then normalize
        ↓
   ┌────┴────────────────────────────┐
   ↓                                 ↓
ArmSilhouetteEntity            MotionRecorder
(ghost arm renders the         (captures the user's attempt,
 reference on your body)        interpolates short gaps, trims idle)
                                     ↓
                               DTWComparator     (time-warped shape match)
                                     ↓
                               TechniqueScorer   (5 sub-metrics → 0–100)
                                     ↓
                               FeedbackGenerating (numbers → coaching prose)
```

`AuraPunchSession` drives the state machine: `acquiring → demonstrating → countdown → attempting
→ scoring → results`.

### Coordinate spaces — read this before touching the math

Three frames, and mixing them up is the most likely way to break this feature. Every conversion
goes through `BodyFrame`; don't hand-roll one elsewhere.

| Space | Origin | Axes |
|---|---|---|
| **World** | ARKit immersive origin | +Y up, entities face **−Z** (RealityKit convention) |
| **Body** | center of the shoulder line | +X user's right, +Y up, **+Z forward** |
| **Normalized** | the punching shoulder | body axes ÷ arm reach — dimensionless |

⚠️ **Body-space +Z is forward — the opposite of RealityKit's −Z.** This is deliberate: "a jab
travels in +Z" is far easier to reason about in scoring code. The flip happens in exactly one
place (`BodyFrame.toBody` / `toWorld`).

The body frame uses **head yaw only**. Pitch and roll are discarded on purpose — during a punch
drill the user looks down at their hands constantly, and inheriting that pitch would swing the
estimated shoulders forward every time they glanced down.

Normalized space is what makes one authored trajectory work for everyone: re-origining on the
shoulder means walking across the room doesn't change the score, and dividing by arm reach
(default `0.32 + 0.26 + 0.08 = 0.66 m`) means a 1.6 m user and a 1.95 m user produce comparable
numbers.

---

## Scoring

Deterministic and geometric. Five named sub-metrics rather than one opaque number, because
"68/100" tells a beginner nothing they can act on:

| Sub-metric | Weight | Measures |
|---|---|---|
| Extension | 0.25 | Did the punch reach full reach? (only *under*-extension is penalized) |
| Path | 0.25 | Did the fist follow the right line? (DTW distance) |
| Elbow | 0.20 | Did the elbow stay tucked instead of flaring? |
| Guard | 0.15 | Did the other hand stay at the chin? |
| Retraction | 0.15 | Did the hand come back to guard? |

**Why DTW:** a beginner's jab is often slower than the reference. Comparing frame *k* to frame
*k* would score a technically perfect but slow punch as badly wrong. DTW stretches the time axis
so what gets graded is the **shape of the path** — the form — not the tempo. A Sakoe-Chiba band
(0.34 of the longer sequence) stops it matching one frozen frame against half the reference,
which would let someone score well by holding still.

Two deliberate refusals to guess:

- A metric whose data wasn't tracked scores `nil`, not `0`, and is excluded from the weighted
  mean. A hand at your hip and a hand outside the camera's view produce identical data; calling
  the second one a dropped guard would be inventing a fault.
- An attempt that was <60% tracked, shorter than 8 samples, or under 0.08 s is **not scored at
  all**. A confident number built on interpolation is worse than admitting the capture failed.

Grades: 88+ Excellent · 74–88 Solid · 58–74 Developing · below that Needs work.

---

## Coaching feedback

`FeedbackGenerating` has two implementations:

- **`MockFeedbackGenerator`** — offline, deterministic, instant. **This is the default.** A live
  demo that hangs waiting on conference wifi is worse than one with less eloquent coaching.
- **`ClaudeFeedbackGenerator`** — Claude Opus 5 via the Messages API over raw `URLSession` (Swift
  has no official Anthropic SDK). Uses structured outputs so the reply is schema-checked JSON,
  `effort: low` because the user is standing there waiting, and a 12 s timeout that falls back to
  the mock on *any* failure.

**The model never decides the score.** It receives numbers computed geometrically and writes prose
about them. That split is what makes the feedback trustworthy — the same attempt always produces
the same score, and a model that could move the number could also flatter you into a bad habit.

> ⚠️ **Enabling Claude puts an API key inside the app binary**, where anyone with the `.app` can
> extract it and spend against your account. Acceptable for a hackathon demo on a device you
> control; for anything else, put the call behind a server you own. **Never commit a key.**

---

## Tuning knobs

Everything hand-tuned lives in one place per concern:

| What | Where |
|---|---|
| Score thresholds (`good`/`bad` error bands) | `ScoringThresholds` in `Scoring/TechniqueScore.swift` |
| Sub-metric weights | `SubMetricKind.weight` |
| Body proportions | `BodyMeasurements.averageAdult` |
| Punch trajectories | `ReferencePunchLibrary.keyframes(for:side:)` |
| Demo reps / capture window | `AuraPunchSession.demoRepetitions`, `.attemptWindow` |
| Ghost color and opacity | `SilhouetteTint` in `Spatial/ArmSilhouetteEntity.swift` |

**The thresholds are the highest-value thing to fix.** They're derived from geometry, not
calibrated against real attempts. Each sub-metric also reports its raw `measured` error, so you
can recalibrate from logged attempts without re-recording anything.

### Swapping in a recorded reference punch

The trajectories are hand-authored from boxing fundamentals so the pipeline works with no capture
session. To replace one with a real boxer's motion, export `[MotionSample]` as JSON to
`ReferencePunches/<techniqueID>.json` in the bundle — `ReferencePunchLibrary` picks it up
automatically and the synthetic version is bypassed. No code change.

Adding a whole new punch is a data change too: append to `Technique.all` and add a `case` in
`keyframes(for:side:)`. No new views.

---

## Project layout

```
BoxingCoach/
  BoxingCoachApp.swift            WindowGroup + mixed ImmersiveSpace
  BoxingCoachContentView.swift    All 2D UI (feature cards → picker → panel → results)
  BoxingCoachImmersiveView.swift  RealityView; hands the scene root to the session
  AuraPunchSession.swift          Aura Punch state machine
  HandTrackingService.swift       ARKit: hands + device anchor
  ReactiveStrikeSession.swift     Reactive Strike drill; also owns `auraPunch`
  Models/         BodyMeasurements, Technique
  Spatial/        ArmPoseSolver, ArmSilhouetteEntity
  Scoring/        MotionRecorder, DTWComparator, TechniqueScore, FeedbackGenerator
  Resources/      ReferencePunchLibrary
```

**Aura Punch shares Reactive Strike's `HandTrackingService` and scene root** rather than standing
up its own — two ARKit sessions competing for the same providers is a good way to get neither.
Only one drill runs at a time, so there's no contention.

### A concurrency gotcha

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so **every type is MainActor-isolated
by default**, including plain structs. Pure data and math types that need to be read from
off-main code (the network-backed feedback generator) must be marked `nonisolated` explicitly —
`Sendable` conformance alone is not enough. If you see *"main actor-isolated property … cannot be
referenced from a nonisolated context"*, that's this.

---

## Known gaps

- **No Anthropometry prompt screen.** `CLAUDE.md` places one between technique selection and the
  session; the existing UI models Anthropometry as a top-level feature card instead, so the flow
  step was not added. `BodyMeasurements.averageAdult` feeds the solver and is a one-line swap.
- **Thresholds uncalibrated** (above).
- **Recorded reference punches aren't mirrored** across stance — the loader passes the requested
  side through without flipping the data. Only matters once real recordings exist.
- **Hook and uppercut trajectories are piecewise-linear** between keyframes. Fine for a demo;
  add keyframes if the arc looks faceted.
- **Nothing has been run on hardware.** Everything below the tracking layer is exercised by the
  compiler only.

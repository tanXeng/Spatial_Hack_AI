# CLAUDE.md

Context file for Claude Code. Keep this updated as decisions get made during the hackathon.

## Project Overview

**Name:** AI Ghost Coach (working title)

**Hackathon prompt:** "How might we allow athletes to learn and practice their sport with spatial computing & AI?"

**One-liner:** An Apple Vision Pro app that overlays a ghost silhouette onto the user's own body to teach beginner boxers correct punching technique, then scores their attempt and tells them how to improve.

**Platform:** visionOS (Apple Vision Pro). This is a spatial-first app — not a flat iOS port.

**Primary user:** A beginner boxer training at home with no coach and no gym access.

## Feature Set

Four features are planned. **Only Aura Punch is being built right now.** The other three are scoped here so the architecture leaves room for them — do not implement them unless explicitly asked.

| Feature | Status | Description |
|---|---|---|
| **Aura Punch** | **BUILD THIS NOW** | Ghost arm silhouette overlaid on the user's body demonstrates a punch; user replicates it; app scores technique and gives feedback. |
| Reaction Time Test | Not yet — do not build | Timed reaction drills. |
| Punching Bag | Not yet — do not build | Virtual bag to strike. |
| Anthropometry | Not yet — do not build | Body measurement capture used to scale the silhouette to the user. |

### Aura Punch — detailed spec

1. A silhouette of a person's **arms** is overlaid directly on top of the user's own body, aligned to their real limbs.
2. The silhouette performs the selected punch (e.g. a jab) to demonstrate correct technique.
3. The user then attempts the same punch, trying to match the silhouette's motion.
4. The app evaluates how closely the user's motion matched the reference and returns:
   - a **score**, and
   - **specific feedback** on what to improve (e.g. "your elbow flared out", "you dropped your guard hand").

## UI Flow

```
Start Screen
    ↓
Home Page  ──────────→ [feature cards: Aura Punch, Reaction Time, Punching Bag, Anthropometry]
    ↓ (Aura Punch)
Technique Selection  ─→ [jab, cross, hook, uppercut, ...]
    ↓
Anthropometry Prompt  ─→ "Hold still while we take your measurements"
    ↓                     ⚠️ DO NOT IMPLEMENT THE ACTUAL MEASUREMENT LOGIC YET.
    ↓                     Build the screen as a stub/placeholder that can be skipped
    ↓                     or auto-advances, so the flow is demoable end-to-end.
Aura Punch Session  ──→ demo → user attempt → score + feedback
```

### Persistent navigation
Every page needs **back**, **home**, and **settings** buttons. Build this once as a reusable SwiftUI component (e.g. `NavigationChrome` or a `.ghostCoachChrome()` view modifier) and apply it everywhere — do not re-implement per screen.

- **Back** — pop one level in the navigation stack.
- **Home** — return to Home Page, clearing the stack.
- **Settings** — opens settings (can be a stub sheet for now).

Exception: the Start Screen has no back button.

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

## Suggested Project Structure

```
GhostCoach/
  App/
    GhostCoachApp.swift            # WindowGroup + ImmersiveSpace setup
  Navigation/
    AppRoute.swift                 # Navigation enum/stack
    NavigationChrome.swift         # Reusable back / home / settings overlay
  Screens/
    StartScreen/
    HomeScreen/                    # Feature cards
    TechniqueSelection/            # jab, cross, hook, ...
    AnthropometryPrompt/           # STUB — screen only, no measurement logic
    AuraPunchSession/              # Immersive session UI + results
    Settings/                      # Stub
  Spatial/
    ArmSilhouetteEntity.swift      # RealityKit ghost arms
    ArmPoseSolver.swift            # head + wrist + measurements -> shoulder/elbow/wrist
    HandTrackingService.swift      # ARKit wrapper, handles dropped frames
  Scoring/
    MotionRecorder.swift           # Captures user attempt as time series
    DTWComparator.swift            # Reference vs. attempt
    TechniqueScore.swift           # Sub-metric breakdown
    FeedbackGenerator.swift        # LLM -> natural language coaching
  Models/
    Feature.swift                  # Data-driven feature list (all four defined here)
    Technique.swift                # Data-driven technique list
    BodyMeasurements.swift         # Defaults now, Anthropometry-populated later
  Resources/
    ReferencePunches/              # Reference motion data per technique
  CLAUDE.md
```

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

## Open Questions / TODO

- [ ] Confirm deployment target visionOS version — affects `@Observable`, ImmersiveSpace and ARKit APIs.
- [ ] How do we author the **reference punch** data? Record a team member wearing the device, or hand-author the trajectory? Recording is faster and more authentic.
- [ ] Silhouette visual treatment — translucent glow? outline only? It must not obscure the user's view of their real arms.
- [ ] How does the user signal "I'm ready to attempt"? Pinch gesture, voice, or auto-start after the demo?
- [ ] How many demo reps before the user attempts?
- [ ] What sub-metric thresholds map to what score? Needs calibration against real attempts.
- [ ] Decide whether feedback LLM calls run live on-device or are pre-generated for the demo (safer on conference wifi).

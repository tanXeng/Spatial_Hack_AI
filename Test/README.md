# ShadowBox

ShadowBox is a controller-free, mixed-reality boxing fundamentals MVP for Apple
Vision Pro. It fits spatial guidance to the boxer, demonstrates a straight-hand
path, and transfers that motion into short reaction drills with immediate,
explainable feedback.

> **Fit → Learn → React.** Personalize reach and guard, follow the Aura guide,
> then apply the movement on a six-pad board or a stationary head-motion drill.

## What works in this MVP

“Implemented” means wired in the current source snapshot. The quiet 05:38
snapshot passed 111/111 recursively discovered tests plus clean generic
Simulator and unsigned arm64 visionOS builds. Signing, installation, live
tracking, comfort, and audio playback/localization on Apple Vision Pro are
still pending.

| Pillar | Implemented experience | Measurement boundary |
|---|---|---|
| Anthropometry | Validated local body profile, live guard, and two controlled functional-reach repetitions per hand | Each hand is checked independently; only the minimum accepted left/right reach scalar may persist. Profile values do not change ARKit accuracy and all world coordinates expire with the immersive session |
| Aura Punch | Original procedural ghost glove and path, three jab/cross repetitions, path/extension/other-hand-guard scoring, and a separate trajectory-shape diagnostic | The trajectory diagnostic is speed-independent, arc-length-density-normalized, fail-closed, session-only, and excluded from coaching and the overall score. Hands only; no elbow, shoulder, torso, hip, leg, footwork, force, or professional-technique inference |
| Reactive Strike | Six-pad jab/cross board, static non-contact bag preview, and planted-feet slip/duck prompts | Board uses deterministic hand geometry. Defense uses headset position as a head proxy, pauses on excessive range during cues or gaps, and requires neutral plus explicit resume/fresh countdown; the real bag is not detected or tracked |

Every training space is explicitly mixed so the room remains visible. Entry is
gated by a clear-area acknowledgement, and Stop & Exit is available in both the
window and immersive space. Tracking loss hides active visuals and pauses or
clears partial recognition instead of manufacturing a score.

Aura cannot start unless both hands are currently tracked. Defense uses the
same calibrated user-relative horizontal basis for its visual and spatial-audio
cues; tracking/system interruptions and safety-range pauses are reported
separately. The main window is resizable, home/detail content scrolls at large
accessibility sizes, and important pause, fatal, cue, and completion changes
post accessibility announcements. These are source-wired behaviors pending
physical-device and assistive-technology acceptance.

Hand calibration and Board placement retain a documented world-axis assumption:
choose one comfortable forward direction before calibration and keep facing it
for that immersive session. Orientation-independent placement is not claimed.

The locally persisted level 1–5 setting changes presentation pace and Aura path
density only; reach, target size, thresholds, scoring, and safety do not change.
An opt-in deterministic advisor may propose one adjacent level after a complete,
uninterrupted set, but it never changes the level automatically and is not ML.
Execution-pace ratios remain internal, unscored, and undisplayed.

Five original WAV earcons are routed through a scene-owned RealityKit spatial-
audio player for cue, clean hit, miss, pause, and set completion. Sound can be
muted from the window or in-space controls. Playback and localization on a
physical headset remain pending, and Apple Vision Pro has no native Core
Haptics support.

## Why it is different

- One live calibration reshapes guidance and targets around the user's own
  guard and comfortable reach.
- Aura shows a movement before asking the user to reproduce it.
- Feedback is deterministic and separated into understandable components; no
  opaque “AI score” or fabricated force value is used.
- Motion processing is local. The MVP persists only validated boxer/bag
  profiles and the explicit difficulty, sound, and recommendation-opt-in
  preferences. Evidence, recommendations, attempts/results, camera footage,
  joint traces, room geometry, and world transforms are not persisted.
- Limitations are part of the product contract, not hidden implementation notes.

The evidence-backed competitor and user-fit assessment is in
[PRODUCT_STRATEGY.md](PRODUCT_STRATEGY.md).

## Architecture

```text
Test/
├── App/           composition root, route state, and local UI preferences
├── Domain/        training vocabulary, profile checks, and adaptive rules
├── Motion/        samples, calibration QA, geometry, and trajectory diagnostic
├── Spatial/       ARKit providers and conversion to plain Sendable values
├── Reality/       mixed-space orchestration, entities, and spatial audio
├── Persistence/   approved local profile storage
├── Resources/     five original WAV feedback resources
└── Features/      Home, Profile, Aura, and Reactive presentation/state

TestTests/
├── Features/      feature-engine and target behavior
├── Motion/        deterministic geometry/recognition tests
├── Spatial/       tracking-state/DTO tests
├── Persistence/   validation and storage tests
└── Smoke/         shipped route catalog
```

At this reconciled final-source snapshot the app target contains **27 Swift
files** and the test target contains **13 Swift files**. The in-place final
Defense/accessibility slice did not change those counts.

There is at most one `ARKitSession` at a time and exactly one consumer of the newest-only
hand-sample stream. Hand-required modes run `HandTrackingProvider` only;
Stationary Defense runs `WorldTrackingProvider` only; the static bag preview
starts neither. ARKit and RealityKit types never enter the deterministic motion
engines.

See [ARCHITECTURE.md](ARCHITECTURE.md) for ownership, dependency rules,
coordinate/time conventions, and explicit technical debt.

## Build and run

Required local environment:

- Xcode 27 beta at `/Applications/Xcode-beta.app`
- visionOS 27 SDK and Apple Vision Pro visionOS 27 Simulator
- Project `Test.xcodeproj`, scheme `Test`

```bash
cd /Users/event/Desktop/Hacklings/Spatial_Hack_AI/Test

/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  build \
  -project Test.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /private/tmp/ShadowBoxSimulatorBuild \
  CODE_SIGNING_ALLOWED=NO

/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  test \
  -project Test.xcodeproj \
  -scheme Test \
  -destination 'platform=visionOS Simulator,id=875B7D3B-237E-46C3-9820-9B4A150544D9' \
  -derivedDataPath /private/tmp/ShadowBoxTests \
  -resultBundlePath /private/tmp/ShadowBoxTests.xcresult \
  CODE_SIGNING_ALLOWED=NO

/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  build \
  -project Test.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -destination 'generic/platform=visionOS' \
  -derivedDataPath /private/tmp/ShadowBoxDeviceBuild \
  CODE_SIGNING_ALLOWED=NO
```

The Simulator validates the window, routing, safe fallbacks, and deterministic
tests, but does not prove live hand/head behavior. A generic device build only
compiles the physical ARKit path; it does not sign, install, authorize, or
validate a headset session. Follow [SETUP.md](SETUP.md) and the physical-device
checklist in [SESSION_LOG.md](SESSION_LOG.md) before making accuracy or safety-
performance claims.

Current-source verification at the quiet 05:38 snapshot: **111/111 tests
passed**, with 0 failures, skips, expected failures, runtime warnings, build
errors, or build warnings. Fresh generic visionOS Simulator and unsigned arm64
visionOS builds both succeeded with 0 errors or warnings. Each xcresult's
analyzer-warning field is 0; a separate Xcode Analyze action was not run. The
app bundles include `Assets.car`,
`PrivacyInfo.xcprivacy`, and all five WAVs. Exact result bundles and commands are
recorded in [SESSION_LOG.md](SESSION_LOG.md). Older release-candidate evidence
is historical only. Signed installation, live tracking, headset comfort,
accessibility acceptance, and spatial-audio runtime acceptance remain open.

## Non-negotiable limitations

This source does **not** provide raw passthrough-camera access, full-body pose,
hooks/uppercuts, footwork or hip analysis, real-bag alignment/contact, force or
power measurement, injury prevention, medical advice, ML inference, networking,
accounts, persistent workout history, native AVP haptics, or professional
technique validation.

For any future headset run, use only controlled, submaximal straight extensions
in a clear area, with no bag or partner, while stationary and planted. Do not
use full-speed or maximum-effort punches. Apple Vision Pro and this app are not
protective equipment.

## Project records

- [SETUP.md](SETUP.md) — operator runbook and troubleshooting
- [ARCHITECTURE.md](ARCHITECTURE.md) — source ownership and invariants
- [PRODUCT_STRATEGY.md](PRODUCT_STRATEGY.md) — current market/user-fit audit
- [JUDGE_DEMO.md](JUDGE_DEMO.md) — truthful four-minute demo and fallback runbook
- [RESEARCH_AND_ROADMAP.md](RESEARCH_AND_ROADMAP.md) — evidence-led product roadmap
- [REFERENCE_REPOSITORY_AUDIT.md](REFERENCE_REPOSITORY_AUDIT.md) — repository provenance and adoption decisions
- [BOXING_RESEARCH_AUDIT.md](BOXING_RESEARCH_AUDIT.md) — study, dataset, and measurement boundaries
- [REFERENCES.md](REFERENCES.md) — Apple, Swift, learning, and provenance sources
- [DECISIONS.md](DECISIONS.md) — scope, safety, data, and technical decisions
- [SESSION_LOG.md](SESSION_LOG.md) — commands, results, open device acceptance
- [TOOLCHAIN.md](TOOLCHAIN.md) — exact local environment and destinations
- [Boxing_ML_Datasets_and_Documentation.docx](Boxing_ML_Datasets_and_Documentation.docx) — separate research inventory; no ML model is integrated in this MVP

`ShadowBox_MVP_Handover.md`, its DOCX companion, and
`ShadowBox_ChatGPT_Desktop_Kickoff_Prompt.txt` are historical setup artifacts.
They are superseded by this README, `SETUP.md`, the latest decisions,
and the latest `SESSION_LOG.md`; they are not current implementation instructions.

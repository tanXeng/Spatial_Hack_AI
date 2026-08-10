# Boxing Coach

Boxing Coach is a local-first Apple Vision Pro training app. The active Xcode project and every
runtime source file live at the repository root. Documentation, experiments, archived projects,
and local test material belong under the git-ignored `local/` directory.

## Build from the root

Requirements: Xcode 27 beta or newer with the visionOS 27 SDK.

```sh
make
```

If command-line tools are not pointed at Xcode beta:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer make
```

Useful targets:

- `make build` — unsigned visionOS Simulator build
- `make build-device` — unsigned generic visionOS device compile check
- `make test` — run the unit suite on the visionOS 27 Apple Vision Pro simulator

Open `BoxingCoach.xcodeproj` and select the `BoxingCoach` scheme to run on Apple Vision Pro.
ARKit hand tracking is unavailable in the simulator, so live punch validation requires hardware.

## OpenAI voice routing

The AI voice coach routes speech to pre-recorded clips. Common phrases work offline via keyword
matching; an OpenAI API key enables smarter routing for varied phrasing.

1. Copy `Secrets.xcconfig.example` to `Secrets.xcconfig`
2. Set `OPENAI_API_KEY = sk-...` in that file
3. Rebuild the app

`Secrets.xcconfig` is gitignored — never commit your real key.

## Project architecture

```text
BoxingCoach/
├── Models/        stance, technique, and body-measurement domain models
├── Resources/     locally authored reference punch trajectories
├── Scoring/       motion recording, path comparison, scoring, and feedback
├── Spatial/       body-relative arm solving and silhouette rendering
├── UI/
│   ├── Flow/      typed navigation and immersive-space lifecycle
│   ├── Selection/ feature, mode, stance, and technique setup
│   ├── Experience/ live guidance, controls, scores, and results
│   └── Shared/    reusable status, error, progress, and metric components
├── *Session.swift
├── Combination*.swift
└── HandTrackingService.swift
```

`BoxingCoach.xcodeproj`, `Info.plist`, and the `BoxingCoach/` source tree are the complete active
app. The project uses Xcode synchronized groups, so new source files inside `BoxingCoach/` are
included without manually changing `project.pbxproj`.

The selection window is dismissed after a training engine starts, leaving only the spatial drill
and a compact **End Training** control in view. Completion, tracking errors, early ending, and
system-driven immersive dismissal restore the window before closing immersion so results and
actionable errors remain available. Immersion closes only after the single control window reports
that it has appeared, avoiding timing-dependent loss of the last result.

## Training and tracking behavior

Aura Punch begins with a full-body coach demonstration, then hands off to the interactive ghost
follow-along. The coach stands beside the boxer, demonstrates on the requested arm, and fails soft
to the existing ghost workflow if an animation asset cannot load. Aura Punch exposes one Uppercut
drill that alternates hands each repetition. Its mirrored
reference paths load beside the hip, drive diagonally inward, and peak at the body centreline.
Legacy `left-uppercut` and `right-uppercut` identifiers resolve to this unified technique.

Reactive Strike begins by capturing both guard positions, then measures a stable left-arm
extension followed by a stable right-arm extension. Competition uses this exact ordered workflow
instead of a separate calibration path. The completed bilateral result is saved to the player and
also becomes the shared launch-wide calibration used by regular Reactive Strike, Combo, and Aura
Punch. Targets use the shorter comfortable reach so every target remains available to either hand.
Calibration and target placement use the live head-derived body frame rather than world Z or a
fixed room height, so the drill is invariant to where the user stands or faces.

Combination Mode adds five numbered combinations with Orthodox/Southpaw hand mapping. It shows
one target at a time and accepts a step only after the required physical hand leaves guard with
outward velocity, reaches the target, and retracts before the next step. Wrong-hand contact and a
stationary extended fist do not advance the sequence; wrong-hand contact ends that repetition as
a miss.

visionOS provides tracked hands and processed forearm joints, plus the headset pose. It does not
provide direct shoulder or full-body tracking. Boxing Coach therefore estimates each shoulder
from the headset pose and local body measurements, then uses the tracked forearm as an elbow-bend
hint. This supports body-relative path, extension, elbow, guard, and retraction scoring, but it
cannot directly evaluate shoulder roll, hip rotation, foot placement, or impact force.

The unit target covers calibration geometry, Air Mode bounds, stance and combination validation,
flow routing, legacy uppercut lookup, and the mirrored uppercut trajectory. Live hand tracking and
punch feel still require an Apple Vision Pro; the simulator cannot supply ARKit hand anchors.

## Repository policy

Git contains only buildable source, Xcode metadata, runtime resources, `.gitignore`, `Makefile`,
and this README. The entire `local/` directory is ignored. ShadowBox is archived locally at
`local/ShadowBox-archive/` and is not part of the active project or Git history going forward.

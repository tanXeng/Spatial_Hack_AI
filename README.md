# Boxing Coach

Boxing Coach is a local-first Apple Vision Pro training app. The active Xcode project and every
runtime source file live at the repository root. Documentation, experiments, archived projects,
and local test material belong under the git-ignored `local/` directory.

## Build from the root

Requirements: Xcode 27 beta or newer with the visionOS 27 SDK. The app deployment target is visionOS 26.

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
- `make test` — run the unit suite on Apple Vision Pro (`SIMULATOR_OS=27.0` by default)

Open `BoxingCoach.xcodeproj` and select the `BoxingCoach` scheme to run on Apple Vision Pro.
ARKit hand tracking is unavailable in the simulator, so live punch validation requires hardware.

## Project architecture

```text
BoxingCoach/
├── EventEdition/  event domain, SwiftData, recovery, exports, and kiosk UI
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

The app launches into a neutral event handoff screen (or first-run host setup), never a previous
participant profile. Event rules are frozen with a SHA-256 digest when the competition opens.
Profiles, attempts, award snapshots, and checksum-protected recovery data remain local to the
Vision Pro. Players create and reopen profiles using a unique player name within the active event;
host tools are available directly on the device.

The selection window is dismissed after a training engine starts, leaving only the spatial drill
and a compact **End Training** control in view. Completion, tracking errors, early ending, and
system-driven immersive dismissal restore the window before closing immersion so results and
actionable errors remain available. Immersion closes only after the single control window reports
that it has appeared, avoiding timing-dependent loss of the last result.

## Training and tracking behavior

Event Edition teaches and ranks one controlled five-repetition jab–cross challenge. Each punch
can earn 30 contact points, 0–10 centre-accuracy points, and 10 guard-return points, for a locked
500-point maximum. Speed and reaction time are excluded from scoring, eligibility, ties, and
awards. Only complete, confidently tracked, opted-in official attempts can rank; the best of two
official attempts is used.

Event runs calibrate open hands, relaxed fists, per-hand guard, and comfortable reach. The fist
point is the centroid of at least three tracked knuckles, not a fingertip fallback. A stale hand or
head sample pauses the challenge after 100 ms, removes the target, discards the partial punch,
and requires 0.5 seconds back in guard plus explicit Resume. Swept segment collision prevents a
fast punch from tunnelling through the target between samples.

Final results are committed exactly once by run UUID before the results route appears. SwiftData
uses explicit saves with CloudKit disabled. Public CSV omits private history; full event JSON
contains immutable event/result snapshots but no anchors, video,
room mesh, or raw joint streams. On-device Foundation Models may rewrite the already-selected
single correction; validation and a two-second timeout always fall back to deterministic copy and
the model can never change points or ranking.

Aura Punch exposes one Uppercut drill that alternates hands each repetition. Its mirrored
reference paths load beside the hip, drive diagonally inward, and peak at the body centreline.
Legacy `left-uppercut` and `right-uppercut` identifiers resolve to this unified technique.

Reactive Strike begins by capturing both guard positions and, when needed, measuring a stable
outward extension from each arm. It uses the shorter comfortable reach so every target remains
available to either hand. Calibration and target placement use the live head-derived body frame
rather than world Z or a fixed room height, so the drill is invariant to where the user stands or
faces. Air Mode and Combination Mode use body-relative target placement after reach calibration.

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

The unit target covers event validation, scoring boundaries, ranking/ties/awards, persistence,
exact-once saves, recovery checksums, name-only player lookup, export privacy, calibrated fist evidence,
tracking pause recovery, swept collisions, calibration geometry, Air Mode bounds, stance and
combination validation, flow routing, legacy uppercut lookup, and the mirrored uppercut trajectory.
Live hand tracking and
punch feel still require an Apple Vision Pro; the simulator cannot supply ARKit hand anchors.

## Repository policy

Git contains only buildable source, Xcode metadata, runtime resources, `.gitignore`, `Makefile`,
and this README. The entire `local/` directory is ignored. ShadowBox is archived locally at
`local/ShadowBox-archive/` and is not part of the active project or Git history going forward.

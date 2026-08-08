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

Open `BoxingCoach.xcodeproj` and select the `BoxingCoach` scheme to run on Apple Vision Pro.
ARKit hand tracking is unavailable in the simulator, so live punch validation requires hardware.

## Project architecture

```text
BoxingCoach/
├── Models/       stance, technique, and body-measurement domain models
├── Resources/    locally authored reference punch trajectories
├── Scoring/      motion recording, path comparison, scoring, and feedback
├── Spatial/      body-relative arm solving and silhouette rendering
├── *Session.swift
├── HandTrackingService.swift
└── BoxingCoach*View.swift
```

`BoxingCoach.xcodeproj`, `Info.plist`, and the `BoxingCoach/` source tree are the complete active
app. The project uses Xcode synchronized groups, so new source files inside `BoxingCoach/` are
included without manually changing `project.pbxproj`.

## Uppercut and tracking behavior

Aura Punch exposes separate left- and right-hand uppercut drills. Both reference paths curve
inward and peak at the user's estimated body centerline; the endpoint is derived from shoulder
width and arm reach rather than a fixed lateral offset.

visionOS provides tracked hands and processed forearm joints, plus the headset pose. It does not
provide direct shoulder or full-body tracking. Boxing Coach therefore estimates each shoulder
from the headset pose and local body measurements, then uses the tracked forearm as an elbow-bend
hint. This supports body-relative path, extension, elbow, guard, and retraction scoring, but it
cannot directly evaluate shoulder roll, hip rotation, foot placement, or impact force.

## Repository policy

Git contains only buildable source, Xcode metadata, runtime resources, `.gitignore`, `Makefile`,
and this README. The entire `local/` directory is ignored. ShadowBox is archived locally at
`local/ShadowBox-archive/` and is not part of the active project or Git history going forward.

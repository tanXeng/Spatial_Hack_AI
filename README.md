# ShadowBox

ShadowBox is a local-first Apple Vision Pro boxing trainer. The active Xcode project and every
source file required to build it live at the repository root; design notes, experiments, legacy
projects, and tests stay under the git-ignored `local/` directory.

## Build from the root

Requirements: Xcode 27 beta or newer with the visionOS 27 SDK.

```sh
make
```

If `xcodebuild` is not using the installed Xcode application:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer make
```

Useful targets:

- `make build` — unsigned visionOS Simulator build
- `make build-offline` — simulator build with deterministic offline tracking enabled
- `make build-device` — unsigned generic visionOS device compile check

Open `ShadowBox.xcodeproj` and select the `ShadowBox` scheme to run on Apple Vision Pro. ARKit
hand tracking is not available in the simulator, so live punch validation requires hardware.

## Active architecture

```text
ShadowBox/
├── App/             app entry point, navigation, developer/offline configuration
├── Domain/          persisted profile and training-domain models
├── Features/
│   ├── Aura/        Aura Punch guide, capture, scoring, and feedback
│   ├── Home/        feature selection and session controls
│   ├── Profile/     local boxer/body profile editing
│   └── Reactive/    punch board, bag preview, and defense drills
├── Motion/          calibration, punch detection, and trajectory alignment
├── Persistence/     local-only profile storage
├── Reality/         RealityKit immersive scene and spatial feedback
├── Resources/       bundled local audio
└── Spatial/         ARKit hand and device-pose service
```

The project uses Xcode synchronized groups, so source files under `ShadowBox/` are included
without manually editing `project.pbxproj`.

## Aura Punch

Aura Punch currently supports:

- stance-aware jab and cross;
- separate left- and right-hand uppercuts;
- a curved, inward uppercut path whose endpoint is derived from the bilateral guard center rather
  than inheriting a full left/right guard offset;
- path, extension, return-to-guard, and non-punching-hand guard scoring;
- uppercut forearm-alignment scoring when visionOS supplies the processed forearm joints;
- shoulder-referenced path compensation using a local shoulder-width profile and headset pose.

## Tracking boundary

visionOS does **not** provide full-body or direct shoulder tracking. ShadowBox therefore does not
claim to measure shoulder technique directly. It combines:

- `HandTrackingProvider` for hands, wrists, and processed `forearmWrist`/`forearmArm` joints; and
- `WorldTrackingProvider` for Apple Vision Pro's device pose.

The app estimates left and right shoulder reference points below the headset using the locally
stored shoulder width. That estimate keeps Aura paths body-relative during small movements and
centers uppercuts, while the forearm joints provide a limited uppercut-alignment cue. Shoulder
roll, hip rotation, foot placement, force, and full-body boxing form remain outside the observable
capabilities of the current implementation.

Apple references: [ARKit in visionOS](https://developer.apple.com/documentation/arkit/arkit-in-visionos),
[HandTrackingProvider](https://developer.apple.com/documentation/arkit/handtrackingprovider), and
[HandSkeleton joint names](https://developer.apple.com/documentation/arkit/handskeleton/jointname).

## Repository policy

Only buildable source, project metadata, bundled runtime resources, this README, and the root
Makefile belong in Git. Keep research, handoff notes, generated reports, scratch code, legacy
projects, and local tests under `local/`; `.gitignore` excludes that directory except for
`local/.keep`.

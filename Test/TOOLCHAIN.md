# ShadowBox toolchain record

Updated on 2026-08-08 (Asia/Singapore).

## Host and Apple tools

- macOS: 26.6 (build 25G72)
- Handover lock: Xcode 27 beta 4
- Installed project toolchain: `/Applications/Xcode-beta.app`
- Installed Xcode: 27.0 (build 27A5228h)
- Beta-4 mapping: not independently confirmed by local application metadata
- Swift compiler: 6.4
- visionOS SDK: 27.0
- Current project deployment target: visionOS 27.0
- Final deployment target: unresolved pending organizer-headset compatibility
- Reality Composer Pro: 3.0 (build 80.0.1.500.1), standalone app
- Blender: 5.2.0, arm64

Reality Composer Pro and Blender are recorded for handover completeness. The
current MVP has no runtime, package, or authored-asset dependency on either.

The system command-line selection still points to `/Applications/Xcode.app`,
Xcode 26.6 (build 17F113), whose license is not accepted. Repeatable commands
therefore invoke the beta executable directly:

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -version
```

If the owner later wants plain `xcodebuild`, `swift`, and Apple `git` to use the
beta globally, the owner can make this administrator change:

```bash
sudo xcode-select --switch /Applications/Xcode-beta.app/Contents/Developer
```

Codex did not change the global developer directory.

## Project identity

- Repository: `/Users/event/Desktop/Hacklings/Spatial_Hack_AI/Test`
- Project: `Test.xcodeproj`
- Target: `Test`
- Scheme: `Test`
- Product/module: `Test`
- User-facing title: ShadowBox
- Bundle identifier: `NTU.Test`
- Signing style: automatic
- Development Team currently stored in the project: `7M7RWKA8PG`
- Baseline commit before implementation: `3d6a228 Initial Commit`

The bundle identifier and Development Team must be confirmed by the owner
before installing on physical hardware.

## Available destinations and physical-build record

- Apple Vision Pro Simulator, visionOS 27.0
- Simulator ID: `875B7D3B-237E-46C3-9820-9B4A150544D9`
- An older visionOS 2.5 simulator is installed but is incompatible with the
  current 27.0 deployment target.
- Organizer Vision Pro OS: unknown
- Primary headset tester: not assigned
- Last verified signed physical-device install: none
- Historical core-MVP unsigned architecture build: passed on 2026-08-07 for
  that older source only
- Historical three-pillar release-candidate build: recorded on 2026-08-08 for
  that older source only; not current verification
- No paired physical Apple Vision Pro was detected on 2026-08-08; the only
  physical destination is Xcode's generic `Any visionOS Device` placeholder.

## Current-source verification

- Final-source count at reconciliation: 27 app Swift files and 13 test Swift
  files. The in-place Defense safety/accessibility slice did not change counts.
- Source inspection confirms fail-closed Defense range handling, tracking-gated
  Aura start, shared Defense audio/visual cue basis, resizable/scroll-safe UI,
  and state announcements; none is a build or headset acceptance result.
- Recursive visionOS Simulator suite: **111/111 passed**, 0 failures, 0 skips,
  0 expected failures, 0 runtime warnings; build results report 0 errors and
  0 warnings, and the xcresult analyzer-warning field is 0. No standalone Xcode
  Analyze action was run. Result bundle:
  `/private/tmp/ShadowBoxFinal111Tests.xcresult`.
- Fresh generic visionOS Simulator build: **succeeded**, 0 errors and 0
  warnings; xcresult analyzer-warning field 0. Result bundle:
  `/private/tmp/ShadowBoxFinal111Simulator.xcresult`.
- Fresh unsigned generic arm64 visionOS build: **succeeded**, 0 errors and 0
  warnings; xcresult analyzer-warning field 0. Result bundle:
  `/private/tmp/ShadowBoxFinal111Device.xcresult`.
- Both app bundles contain `Assets.car`, `PrivacyInfo.xcprivacy`, and all five
  original WAV resources.
- Signed installation and physical-headset validation: **not run**.
- Live hand/world authorization and tracking: **not run**.
- Bilateral fit/target placement on headset: **not run**.
- Five-WAV spatial-audio load, latency, localization, overlap, and mute on
  headset: **not run**.
- Native AVP haptics: unsupported; no haptic test/claim applies.

The older three-pillar release-candidate command/result is retained in the
dated `SESSION_LOG.md` and D-028 only as historical evidence. D-029 supersedes
its use as a current status. Do not create a new “RC” label or quote a test/build
result from an older snapshot. The definitive software evidence is the quiet
05:38 result set above; later source changes require a fresh aggregate run.

## Prior core-MVP verification evidence

The commands below predate the three-pillar expansion. Their results remain
useful historical evidence for the earlier two-mitt core, but they must not be
reported as final validation of the current profile, Aura Punch, six-pad board,
bag-preview, or defense flows.

Generic Simulator build — **passed**:

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project Test.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /private/tmp/ShadowBoxMVPBuild8 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Simulator test run — **22 passed, 0 failed**:

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project Test.xcodeproj \
  -scheme Test \
  -destination 'platform=visionOS Simulator,id=875B7D3B-237E-46C3-9820-9B4A150544D9' \
  -derivedDataPath /private/tmp/ShadowBoxMVPTestBuild9 \
  -resultBundlePath /private/tmp/ShadowBoxMVPTests9.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

Result bundle: `/private/tmp/ShadowBoxMVPTests9.xcresult`.

Generic physical visionOS architecture build — **passed**:

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project Test.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -destination 'generic/platform=visionOS' \
  -derivedDataPath /private/tmp/ShadowBoxMVPDeviceBuild8 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The device-architecture build confirms that the physical-only ARKit and
RealityKit symbols compile. It does not sign, install, request authorization,
or validate live tracking on a headset. The only build warning was the benign
AppIntents metadata skip because the app has no AppIntents dependency.

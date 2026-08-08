# ShadowBox setup and operator runbook

This runbook covers the three-pillar ShadowBox visionOS MVP: Anthropometry,
Aura Punch, and Reactive Strike. It uses only Apple SDK and Swift standard-
library dependencies, including SwiftUI, RealityKit, ARKit, Observation,
Foundation, UIKit accessibility, QuartzCore timing, `simd`, UserDefaults, and
Swift Testing. It has no external package, network, ML-model, camera-frame, or
authored-scene dependency. Five original WAV files are bundled for a small
RealityKit spatial-feedback layer; Apple Vision Pro has no native Core Haptics.

## Verified local environment

- Project / target / scheme / module: `Test`
- User-facing title: `ShadowBox`
- Bundle identifier currently stored in the project: `NTU.Test`
- Deployment target: visionOS 27.0
- Xcode: `/Applications/Xcode-beta.app`, 27.0 build 27A5228h
- Swift compiler: 6.4; project language mode: Swift 5
- Simulator: Apple Vision Pro, visionOS 27.0
- Simulator ID: `875B7D3B-237E-46C3-9820-9B4A150544D9`
- Physical Vision Pro: not paired or validated in the latest local audit

Current final-source snapshot: 27 app Swift files and 13 test Swift files,
including the in-place Defense safety/accessibility slice. At the quiet 05:38
snapshot, 111/111 tests passed and fresh generic Simulator/unsigned arm64
visionOS builds succeeded, all with zero reported errors or warnings. Each
xcresult's analyzer-warning field is 0; a separate Xcode Analyze action was not
run. The built bundles contain `Assets.car`, `PrivacyInfo.xcprivacy`, and
all five WAVs. Signed install, headset tracking, on-device audio localization,
comfort, and accessibility acceptance remain open. Do not reuse the older
release-candidate count as current evidence.

Current result bundles:

- tests: `/private/tmp/ShadowBoxFinal111Tests.xcresult`;
- generic Simulator: `/private/tmp/ShadowBoxFinal111Simulator.xcresult`;
- generic visionOS device architecture: `/private/tmp/ShadowBoxFinal111Device.xcresult`.

The system developer selector points at a different Xcode installation whose
license is not accepted. Use the full Xcode-beta executable paths below.

## Open and inspect the app

1. Launch `/Applications/Xcode-beta.app`.
2. Open `/Users/event/Desktop/Hacklings/Spatial_Hack_AI/Test/Test.xcodeproj`.
3. Select scheme **Test** and the visionOS 27 **Apple Vision Pro** Simulator.
4. Run the app.
5. Confirm the first window shows exactly three product pillars:
   **Anthropometry**, **Aura Punch**, and **Reactive Strike**.
6. Open each route and confirm limitations and mode-specific safety are visible
   before entering immersion.

Expected Simulator behavior:

- The normal setup/results window and mixed immersive space can render.
- The app reports a clear Simulator fallback for live tracking.
- Hand-required calibration, Aura following, and board scoring cannot be
  validated because the Simulator does not supply the physical hand stream.
- Stationary Defense cannot validate a physical device anchor.
- The Physical Bag route remains a static, non-contact visual preview.
- Stop & Exit and route/state handling remain inspectable.
- Spatial-audio resources and mute state may be inspected as software behavior,
  but Simulator output is not physical-headset localization/latency evidence.

## Repeatable command-line validation

Run every command from `/Users/event/Desktop/Hacklings/Spatial_Hack_AI/Test`.
Use unique Derived Data and
result-bundle paths if a prior bundle already exists.

### Generic Simulator build

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  build \
  -project Test.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /private/tmp/ShadowBoxSimulatorBuild \
  CODE_SIGNING_ALLOWED=NO
```

### Recursively discovered Swift Testing suite

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  test \
  -project Test.xcodeproj \
  -scheme Test \
  -destination 'platform=visionOS Simulator,id=875B7D3B-237E-46C3-9820-9B4A150544D9' \
  -derivedDataPath /private/tmp/ShadowBoxTests \
  -resultBundlePath /private/tmp/ShadowBoxTests.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

### Unsigned physical-device architecture compile

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  build \
  -project Test.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -destination 'generic/platform=visionOS' \
  -derivedDataPath /private/tmp/ShadowBoxDeviceBuild \
  CODE_SIGNING_ALLOWED=NO
```

The device command proves only that physical-only APIs compile for arm64 xros.
It does not sign, install, request authorization, or prove live behavior.
`SESSION_LOG.md` records the most recent exact evidence and supersedes old paths.

## Pair and run on Apple Vision Pro

Prepare a clear arm-swing area with safe floor and overhead clearance. Remove
bags, partners, furniture, pets, bystanders, fragile objects, and trip hazards
from reach. Stop for discomfort or uncertain tracking.

1. Record the organizer headset's visionOS version. Do not lower the project
   target until compatibility is an explicit recorded decision.
2. Enable Developer Mode on Vision Pro.
3. Keep Mac and headset on the same trusted local network with Bluetooth on.
4. In Xcode beta, open **Window → Devices and Simulators** and pair the headset.
5. In **Test → Signing & Capabilities**, confirm that Development Team
   `7M7RWKA8PG` belongs to the owner and that `NTU.Test` is available. Record any
   approved replacement in `TOOLCHAIN.md` and `DECISIONS.md` first.
6. Select the paired headset and run.
7. For Anthropometry, Aura, and Board, approve hand tracking when requested.
   Defense uses world/device tracking only and must not depend on hand
   permission. Bag Preview starts no ARKit provider.
8. Execute every open physical acceptance item in `SESSION_LOG.md` before using
   “validated,” “accurate,” or safety-performance language.

## Headset user journeys

### 1. Anthropometry — fit

1. Enter plausible height, arm span, left/right arm length, shoulder width,
   stance, and dominant hand; save locally.
2. Read and check the mode-specific clear-area acknowledgement.
3. Enter the mixed space and raise both hands.
4. Face one comfortable forward direction and keep that orientation for the
   entire calibration and drill session.
5. Hold a comfortable guard continuously for two seconds.
6. Extend and return one hand twice with controlled, submaximal motion while the
   other stays near guard; then complete two repetitions with the other hand.
7. If a hand's pair exceeds the provisional repeatability allowance, begin a
   fresh pair rather than stretching farther or loosening thresholds.
8. Exit. Only the minimum accepted left/right reach scalar can be added to the
   profile; per-hand repetitions, guard positions, direction, and other
   world-space calibration must not survive the immersive session.

Entered measurements create a body profile and conservative estimate. Live
calibration personalizes target geometry. Neither changes Apple's underlying
tracking accuracy or constitutes a clinical measurement.

### 2. Aura Punch — learn

1. Complete a fresh live guard/reach calibration in the current space.
2. Choose Jab or Cross.
3. Watch the original procedural ghost glove travel out and back along the path
   markers.
4. Confirm **Watch Guide & Follow 3 Repetitions** stays disabled until both
   hands are tracked; do not bypass that start gate.
5. Start at guard, trace the path, extend comfortably, keep the other hand near
   guard, and return.
6. Complete three repetitions, then review the overall guide score, path,
   extension control/depth, other-hand guard, tracking interruptions, and—only
   when every trace passes validation—the separate trajectory-shape diagnostic.

Execution pace is calculated internally only. It is not displayed, rewarded,
or included in the overall score. The trajectory diagnostic normalizes
translation/reach and resamples both paths at equal arc-length density before a
constrained comparison. It fails closed on gaps or invalid paths, remains
session-only, and does not affect coaching text or the overall score.

Aura is hand-only. It cannot see elbow/shoulder mechanics, torso rotation, hips,
legs, feet, balance, impact, force, or professional form.

### 3. Reactive Board — react

1. Complete fresh live calibration.
2. Start the 60-second board round.
3. Use the stance-mapped jab/cross hand for the illuminated pad and return to
   guard.
4. If tracking pauses, stop moving and hold both hands at calibrated guard to
   resume; interrupted cues are cancelled, not converted to misses.
5. Review hits, spatial misses, wrong hand, timeout, interruptions, response,
   and observed/censored guard returns separately. Internal pace is not shown or
   rewarded.

### 4. Stationary Defense — move the head only

1. Keep both feet planted and calibrate a still neutral headset position.
2. Run the six-cue slip-left, slip-right, duck, or mixed drill.
3. Move conservatively and return to neutral before the next cue.
4. Exit to review completed head motions, wrong direction, late return,
   timeouts, cancellations, response time, tracking/system interruptions, and
   safety-range pauses separately.

If displacement exceeds the controlled range during either a cue or an
inter-cue gap, the drill cancels active evidence and pauses. Stop moving, return
to the calibrated neutral zone, then choose **Resume at Neutral**. Resume is
refused away from neutral and always begins a fresh countdown/cue; the unsafe
return path cannot score.

Defense uses headset position as a head proxy. It does not observe feet, hips,
torso, neck, balance, opponent contact, or whether the movement is good boxing
technique. Visual prompts dissolve before reaching the headset. Visual and
spatial-audio cue positions share the same calibrated user-relative basis.

### 5. Physical Bag Preview — configure, do not strike

1. Store plausible bag type, dimensions, and target-layout scalars.
2. Enter only to inspect the stationary virtual proxy.
3. Do not hit or touch a physical bag while wearing Vision Pro.

This route performs no bag recognition, alignment, anchoring, drift correction,
phone/tablet pairing, contact detection, or impact measurement.

### Shared level, recommendation, and sound controls

- Level 1–5 changes presentation pace and Aura path-marker density only. Reach,
  target size, recognition thresholds, score weights, and safety stay fixed.
- The optional next-level advisor is deterministic, uses only complete
  session evidence, proposes at most one adjacent level, and requires the user
  to apply it. It is not Core ML and does not learn from the boxer.
- The difficulty, sound toggle, and recommendation opt-in persist locally.
  Recommendation instances, evidence, and attempt/results data do not.
- Five original WAVs cover cue, clean hit, miss, pause, and set completion.
  Use the window or in-space mute control if venue playback is distracting.
  Audio never changes scoring and never carries the only safety information.

## Troubleshooting

### Plain `xcodebuild`, `swift`, or Apple `git` reports a license error

Use the full Xcode-beta commands above. The owner may later switch the global
developer directory, but this project does not require that administrator
change.

### No physical destination appears

- Confirm Developer Mode, device trust, network, Bluetooth, and an unlocked
  headset.
- Reopen Devices and Simulators.
- Confirm headset OS compatibility with the 27.0 target.

### Signing fails

- Confirm the stored team belongs to the owner.
- Choose a unique bundle identifier for that team.
- Keep `NSHandsTrackingUsageDescription` for hand-required modes.

### Hand permission is denied

Anthropometry, Aura, and Board must fail clearly and require permission before
re-entry. Defense must remain independently available because it requests only
the world/device provider. Do not fake hand input or silently keep scoring.

### Tracking disappears or freezes

Stop moving. The app should hide stale visuals, clear partial motion, and pause
active scoring. Re-establish guard/neutral as instructed. Use Stop & Exit for a
terminal provider error.

### Spatial sound is absent or confusing

Use the in-space **Mute sound** action or the window toggle and continue only if
visual/text cues remain clear. A load error should be visible; it must not
affect scoring. Do not describe Simulator output as verified headset spatial
audio, and do not describe any sound as native AVP haptics.

### Accessibility acceptance

- Resize the main window down to its content minimum and larger than default;
  verify no control becomes unreachable.
- Test the home and feature screens at accessibility Dynamic Type sizes; cards
  and detail content must scroll rather than clip.
- With VoiceOver enabled, verify pause/fatal error, cue/result, and completion
  announcements without relying on audio earcons alone.
- Treat source presence or Simulator speech as inspection only; record
  physical-headset assistive-technology acceptance separately.

### Calibration restarts

That is intentional after non-finite data, reversed timestamps, a sample gap,
missing hands, excessive guard motion, a system interruption, or immersive
exit. Do not lengthen thresholds merely to conceal tracking instability.

## Safety and data contract

- Vision Pro and ShadowBox are not protective equipment.
- No bag, partner, stepping, spinning, jumping, or backward movement is allowed
  in the current MVP drills.
- Use only stationary, controlled, submaximal straight extensions. Do not use
  full-speed or maximum-effort punches while wearing Vision Pro.
- For hand calibration, Aura, and Board, choose one forward direction before
  calibration and do not reorient during that immersive session.
- All metrics are relative practice feedback, not force, power, impact,
  biomechanical, medical, injury-prevention, or professional evaluation.
- Local persistence is limited to validated boxer/bag profiles plus the
  difficulty, sound, and recommendation-opt-in preferences.
- Joint/head traces, room data, world transforms, calibration coordinates,
  recommendation instances/evidence, attempt/results history, images, and video
  are not persisted or uploaded.
- Recording participant traces later requires informed consent, a retention
  policy, access controls, and a new recorded decision.

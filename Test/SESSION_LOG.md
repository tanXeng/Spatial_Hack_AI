# ShadowBox session log

## 2026-08-07 — Documentation review, M0 audit, and M1 setup

### Documentation reviewed

- `ShadowBox_MVP_Handover.md` (authoritative handover)
- `ShadowBox_MVP_ChatGPT_Desktop_Handover.docx` (all 14 rendered pages)
- `ShadowBox_ChatGPT_Desktop_Kickoff_Prompt.txt`

The initial handover limited implementation to M1: mixed immersion, live
diagnostic hand markers, one programmatic mitt, explicit failure/fallback
states, and no scoring or ML.

### M0 audit

- Repository: `/Users/event/Desktop/Hacklings/Spatial_Hack_AI/Test`
- Branch: `main`
- Last baseline commit: `3d6a228 Initial Commit`
- Actual project/target/scheme: `Test`
- Bundle identifier: `NTU.Test`
- Development Team in project: `7M7RWKA8PG` (owner must confirm)
- Xcode beta: 27.0, build 27A5228h
- visionOS 27.0 Simulator found and buildable
- Baseline generic Simulator build passed before M1 edits
- No paired physical Vision Pro detected
- The starting app was the full-immersion video template, not M1

The tracked baseline was clean, but the worktree already contained five
untracked handover/report artifacts. Codex did not stage or commit any files.

### Initial M1 changes

- Replaced full immersion with an explicitly mixed `ImmersiveSpace`.
- Stopped loading the stock sky-dome/video scene from the app entry path.
- Added a safety-first Start/Stop window and visible tracking state.
- Added `NSHandsTrackingUsageDescription`.
- Added `HandTrackingService` as the only ARKit boundary.
- Added wrist and five fingertip markers for each tracked hand.
- Added one red programmatic diagnostic mitt.
- Added explicit Simulator, unsupported, denied, waiting, tracking-lost, and
  runtime-error states.
- Added focused marker and presentation-state tests.
- Added `TOOLCHAIN.md`, `DECISIONS.md`, and this log.

### Initial verification evidence

- visionOS 27.0 Simulator Debug build: passed
- Generic visionOS device-architecture Debug build: passed
- Simulator tests: 4 passed, 0 failed, 0 skipped
- Simulator launch: passed
- Start/safety/status window visual inspection: passed
- Hand-tracking privacy key in source plist: present
- Physical-device install and hand-marker observation: not run

Only the benign “no AppIntents.framework dependency” metadata warning appeared.

### Initial milestone status

M1 was implemented and simulator-validated, but not physically validated. It
was not marked complete because no Apple Vision Pro was paired.

## 2026-08-07 — Owner-authorized full software MVP

### Scope change

The owner supplied the Swift repository, Apple visionOS samples, hand-tracking
and immersive-control references, Step Into Vision, Explore SwiftUI, Hacking
with Swift, and `/Users/event/Downloads/IntroRealityKit/`, then explicitly asked
for the comprehensive implementation with an MVP acceptable for now. D-011
records this override of the initial software-only M1 boundary. No ML, network,
avatar, footwork, raw-camera, or persistent participant-data feature was added.

### Reference and local-sample review

- Used the Xcode-bundled Swift 6.4 toolchain; did not clone or package the Swift
  compiler repository.
- Kept Apple's window-first, mixed-immersive-space, `ARKitSession`,
  `HandTrackingProvider`, and RealityKit attachment patterns.
- Reviewed IntroRealityKit's async authored-model loading, opacity, grounding
  shadow, and optional debug manipulation patterns.
- Did not copy its unlicensed `GlassCube.usdz`, project settings, or unsafe
  minimal immersive lifecycle.

### Implemented software MVP

- Safety acknowledgement gates entry; the app/headset protective-equipment
  disclaimer is visible.
- A pinned window control and an in-space Stop & Exit attachment remain
  available without scrolling.
- The app supports orthodox and southpaw hand mapping.
- Guard calibration requires two visible, stable hands for two seconds.
- Reach calibration requires a straight same-hand extension of at least 0.32 m,
  the other hand near guard, and a return to guard within the capture window.
- Two programmatic mitts are placed inside measured comfortable reach.
- Mitts stay hidden before calibration; active target size matches the logical
  collision sphere, and visual feedback never changes scoring geometry.
- A deterministic per-hand state machine uses actual ARKit anchor-update times
  and consecutive swept segments for jab/cross contact.
- Target contacts, valid spatial misses, wrong-hand attempts, timeouts,
  tracking-cancelled cues, tracking interruptions, response time, relative hand
  speed, guard return, censored guard returns, and paused time are separated.
- Tracking loss freezes scoring and active time; resumption requires both hands
  held at calibrated guard.
- System inactivity pauses active training. Permission/provider/session terminal
  failures abort the drill into an explicit failure state.
- System interruptions cancel partial calibration instead of resuming stale
  measurements. Leaving immersion invalidates all world-space calibration.
- Finishing a round exits immersion automatically and preserves the in-memory
  results for review in the normal window.
- Every app-controlled exit requests that visionOS open or reorder the single
  main window before requesting immersive dismissal. Closed-window restoration
  remains a headset test. Transition gating protects the completed summary from
  late actions.
- Closing immersion always clears the prior hazard acknowledgement; re-entry
  requires a fresh confirmation.
- The in-space attachment includes tracking/cue/feedback text and posts system
  accessibility announcements for cues and outcomes.
- The scene manifest supports the window-plus-immersive configuration; the
  primary control window itself is single-instance.
- Samples remain in memory through a newest-only `AsyncStream`; no sample or
  result is persisted or uploaded. The completed summary exists temporarily in
  memory for the immediate results screen.

### Historical core-MVP software verification evidence

Simulator build command/result:

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

Result: **passed**.

Simulator test command/result:

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project Test.xcodeproj \
  -scheme Test \
  -destination 'platform=visionOS Simulator,id=875B7D3B-237E-46C3-9820-9B4A150544D9' \
  -derivedDataPath /private/tmp/ShadowBoxMVPTestBuild9 \
  -resultBundlePath /private/tmp/ShadowBoxMVPTests9.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

Result: **22 passed, 0 failed**. Coverage includes stance mapping, finite
multi-knuckle centroids, swept collision and tunneling, target clearance,
first-contact emission, spatial misses, duplicate suppression, pre-cue punch
isolation, cached-pose timing, slow/sideways rejection, exact cue expiry,
tracking-gap re-arming, southpaw mapping, expanded result aggregation, marker
identity, fallback presentation, session-scoped calibration, interrupted guard
and reach-stage calibration, terminal tracking failure, and results retention
and mutation protection after exit.

Generic physical-device architecture command/result:

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

Result: **passed**. This compiles the real-device ARKit path; it does not sign,
install, authorize hand tracking, or validate a headset session.

Simulator launch/visual result: **passed**. The fixed-size setup window rendered
without clipping; the disclaimer and hazard acknowledgement were legible; entry
remained disabled until acknowledgement; the pinned action remained visible.
The Simulator intentionally reports that the live drill requires Apple Vision
Pro.

### Historical core-MVP status and next smallest task

The software MVP is implemented and simulator-tested. Physical acceptance is
still open. The next smallest task is to pair the organizer Vision Pro, confirm
its OS/signing team, then execute the checklist below without changing constants
until observations are recorded.

### Physical-device acceptance checklist

- [ ] Record organizer Vision Pro OS and confirm visionOS 27.0 compatibility.
- [ ] Enable Developer Mode and pair the headset in Xcode 27 beta.
- [ ] Confirm bundle identifier `NTU.Test` and Development Team
      `7M7RWKA8PG`, or document approved replacements.
- [ ] Assign and record the primary headset tester.
- [ ] Install and open the app in a clear arm-swing area with safe floor and
      overhead clearance.
- [ ] Confirm mixed passthrough remains visible for the entire flow.
- [ ] Confirm window Stop and in-space Stop & Exit are both reachable.
- [ ] Close the main window during a safe idle/calibrated state, use in-space
      Stop & Exit, and confirm the main window returns before immersion closes.
- [ ] Confirm jab/cross mitts are comfortably forward, below overreach, and do
      not invite stepping, leaning, or collision with the control panel.
- [ ] Confirm cyan/blue left and orange/purple right markers update smoothly.
- [ ] Hide each hand and confirm its stale markers and fist center disappear.
- [ ] Lose one/both hands during countdown and round; confirm active time and
      scoring freeze and the active cue is cancelled rather than missed.
- [ ] Return both hands to guard; confirm the deliberate hold is required before
      resumption.
- [ ] Exercise both stances and verify jab/cross hand mapping.
- [ ] Complete the 60-second round and sanity-check timeouts, wrong-hand count,
      spatial misses, hit response, relative hand speed, guard return, censored
      guard returns, cancelled cues, tracking interruptions, and paused time
      independently.
- [ ] Confirm round completion exits immersion and leaves the results available
      in the normal window; re-entry must require fresh calibration.
- [ ] With VoiceOver, confirm cue, hit/miss, and tracking text/announcements are
      understandable without relying on mitt color.
- [ ] Background/interrupt the app and confirm active round time stays frozen.
- [ ] Deny/revoke hand permission where practical and confirm the terminal error
      requires exit/re-entry.
- [ ] Record comfort, target-placement, false-hit, missed-hit, pause, and exit
      observations before tuning any provisional constant.

Safety: use no bag or partner, keep the area clear, stop for discomfort, and do
not retain participant traces without informed consent and a recorded decision.

## 2026-08-07 — Owner-authorized three-pillar Boxing Trainer expansion

### Scope and reference boundary

The owner replaced the two-mitt-only product structure with a first screen that
offers Anthropometry, Aura Punch, and Reactive Strike. Reactive Strike contains
a six-pad Virtual Board, Physical Bag Preview, and Stationary Defense. The UI
hierarchy of `Spatial_Hack_AI` was reviewed read-only at pinned commit
`b570f2e31b638e97fe59110f9909bcd20228bbc7`. The remote repository was not
cloned or modified. No declared license was identified at that state, and no
source or authored asset was copied verbatim.

### Implemented three-pillar MVP boundary

- Anthropometry now has a validated boxer profile and live guard/comfortable-
  reach calibration. Only plausible scalar profile values are stored locally;
  live joints and world coordinates remain in memory for the current immersive
  session.
- Aura Punch provides hand-only guidance for punch path, extension, speed, and
  the other hand's guard.
- Virtual Board provides deterministic jab/cross cues across six virtual pads.
- Stationary Defense provides slip-left, slip-right, and duck cues using device
  position as a head-position proxy, with planted feet.
- Physical Bag Preview stores only validated scalar bag configuration and shows
  a static, non-contact visualization. It does not register, track, or score
  strikes against a real bag.
- There is no iPhone/iPad companion, real-bag alignment, object scan, marker,
  shared coordinate system, contact/impact detection, force/power estimate,
  footwork tracking, hip tracking, or whole-body posture assessment.
- No joint sample, world transform, room data, motion trace, raw camera data, or
  result history is persisted or uploaded.

### Expansion checkpoint verification evidence

Generic visionOS Simulator build command/result:

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project Test.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /private/tmp/BoxingTrainerBuild2 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Result: **passed**.

- At this checkpoint, the expanded Simulator test run was **pending**; the
  8 August release-candidate entry below supersedes that state.
- At this checkpoint, the expanded generic physical-device architecture build
  was **pending**; the 8 August release-candidate entry below supersedes it.
- Signed install, permission flow, and physical-headset session: **not run**.

The earlier 22-test run and device-architecture build above validate the prior
two-mitt core only. They are retained as historical evidence and do not validate
the new profile, Aura Punch, six-pad board, bag-preview, or defense flows.

Current safety boundary: use the bag mode as a non-contact preview only; do not
strike or touch a physical bag while wearing the headset. Keep feet planted in
Stationary Defense, maintain clear floor and overhead space, and stop for
discomfort or tracking uncertainty.

## 2026-08-08 — Three-pillar release-candidate integration and audit

> **Historical source snapshot only.** The results in this dated section apply
> to the then-current release-candidate source. They are superseded as current
> verification by D-029 and the current-source reconciliation later in this log.

### Product and architecture outcome

- The normal window now presents the intended three-pillar journey:
  Anthropometry, Aura Punch, and Reactive Strike. Reactive Strike exposes the
  six-pad Board, static Bag Preview, and planted-feet Defense.
- `Test/` is organized by App, Domain, Motion, Spatial, Reality, Persistence,
  and implemented feature ownership. Feature presentation is split into real
  Home/Profile/Aura/Reactive files; `ContentView.swift` is 515 lines rather
  than the earlier approximately 1,360-line aggregate.
- `ImmersiveView` remains the one hand-sample router. The unused
  `RoundEngine.consume(_:)` iterator was removed.
- Hand-required routes start only `HandTrackingProvider`; Defense starts only
  `WorldTrackingProvider`; Bag Preview starts no provider or ARKit session.
- `HandTrackingService.stop()` now replaces its newest-only `AsyncStream`, so
  cancellation of one immersive view cannot silently break the next entry.
- Aura results now expose path, extension, relative peak speed, other-hand
  guard, and explicit completion-with-guard-return. The UI also discloses the
  current forward-orientation constraint before hand-led entry.
- Only validated boxer/bag scalar configuration persists locally. No network
  path, ML inference, camera frame, room map, joint/head trace, world transform,
  workout history, or result-history persistence exists.

Repository hygiene:

- Added repository-owned shared scheme
  `Test.xcodeproj/xcshareddata/xcschemes/Test.xcscheme`.
- Removed tracked, ignored scheme-management user state; preserved ignored
  local workspace UI state.
- Removed unused `AVPlayerView.swift`, `AVPlayerViewModel.swift`,
  `Immersive.usda`, `Ground.usda`, `SkyDome.usdz`, and
  `DefaultAttenuationMap.exr`. These are recoverable from baseline commit
  `3d6a228` if a licensed lesson/scene is designed later.
- Added the project-owned 1024×1024 layered icon raster at
  `Test/Assets.xcassets/AppIcon.solidimagestack/Back.solidimagestacklayer/Content.imageset/ShadowBoxIcon.png`.

### Release-candidate test evidence

Command:

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project Test.xcodeproj \
  -scheme Test \
  -destination 'platform=visionOS Simulator,id=875B7D3B-237E-46C3-9820-9B4A150544D9' \
  -derivedDataPath /private/tmp/ShadowBoxReleaseCandidate2Tests \
  -resultBundlePath /private/tmp/ShadowBoxReleaseCandidate2Tests.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

Result: **passed — 54 tests, 0 failures, 0 skips, 0 expected failures** on
Apple Vision Pro visionOS 27.0 Simulator, arm64. `xcresulttool` reported no
runtime warnings. Coverage includes profile validation/persistence, stance
mapping, fist centroid and swept geometry, punch recognition, sample freshness,
calibration continuity, six-pad routing, Aura scoring/lifecycle, Defense
orientation/timing, interruption/result lifetimes, and sample-stream re-entry.
The Aura pause test also asserts that guide presentation is disabled during a
tracking/system pause and restored only after an eligible resume.

Result bundle:
`/private/tmp/ShadowBoxReleaseCandidate2Tests.xcresult`.

### Final generic Simulator build

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild build \
  -project Test.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /private/tmp/ShadowBoxReleaseCandidate2Simulator \
  CODE_SIGNING_ALLOWED=NO
```

Result: **passed**. The app bundle contains executables, `Assets.car`, and
metadata only; none of the removed stock scene/video resources are packaged.
The built plist contains display name `ShadowBox`, visionOS minimum 27.0, the
hand-tracking usage description, and mixed immersive scene configuration.

The final app was installed and launched in the Simulator. Screenshot:
`/private/tmp/ShadowBoxReleaseCandidate2Home.png`. Visual inspection passed: the
three-card home is centered, legible, unclipped, and retains its material
hierarchy in the simulated room.

### Final unsigned physical-device architecture build

```bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild build \
  -project Test.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -destination 'generic/platform=visionOS' \
  -derivedDataPath /private/tmp/ShadowBoxReleaseCandidate2Device \
  CODE_SIGNING_ALLOWED=NO
```

Result: **passed** for arm64 xros 27.0. The only final-build warning was the
benign AppIntents metadata skip because the target has no AppIntents dependency.
This does not prove signing, installation, authorization, tracking accuracy, or
runtime behavior on Vision Pro.

### Product/user/market fit audit

`PRODUCT_STRATEGY.md` records the current evidence/hypothesis boundary,
competitor comparison, primary and poor-fit users, four-minute judge narrative,
measurable adoption/reliability gates, and stop/pivot conditions. Current
positioning is a calibrated, controller-free spatial fundamentals lab for
Vision Pro owners and supervised demos—not mass-market fitness, force
measurement, full-body analysis, medical technology, or an AI coach.

### Open three-pillar physical acceptance

- [ ] Record headset OS, Development Team, bundle identifier, and primary tester.
- [ ] Confirm the app remains mixed/passthrough and both Stop & Exit paths are
      reachable in every route.
- [ ] Confirm the safety acknowledgement gates entry and the forward-facing
      instruction is understandable before calibration.
- [ ] Anthropometry: verify both stances, two-second still guard, comfortable
      reach/return, continuity reset, scalar persistence, and world-coordinate
      invalidation on exit.
- [ ] Aura: verify guide placement, three repetitions of the selected jab or
      cross, tracking-loss pause, guard-return gating, path/extension/other-hand-
      guard results, and the optional complete-coverage trajectory diagnostic;
      verify both Continue to Punch Board and Stop & Exit preserve the summary.
- [ ] Board: verify all six pads, stance-mapped jab/cross cues, swept contacts,
      wrong-hand/spatial-miss/timeout separation, guard-return censorship,
      interruption counts, and 60-second active-time accounting.
- [ ] Defense: deny hand permission first and confirm the world-only route still
      starts; verify still neutral calibration, user-relative slips, duck,
      oversized/wrong-direction/late-return outcomes, stale-pose pause, and
      headset comfort while feet remain planted.
- [ ] Bag Preview: confirm it requests no tracking permission, remains a static
      non-contact proxy, and cannot be mistaken for real-bag alignment/scoring.
- [ ] Exercise second entry after Stop & Exit and confirm hand samples resume;
      then repeat after tracking loss and a system interruption.
- [ ] Run VoiceOver through navigation, safety gating, cues, pause/errors, and
      result review.
- [ ] Record false positives/negatives, orientation sensitivity, comfort, and
      threshold observations without retaining participant traces.

Signed installation, permission-flow evidence, live headset validation, user
interviews, retention, willingness-to-pay, and training efficacy remain open.
No “validated accuracy,” “safe performance,” “AI coach,” force, professional-
technique, or first-place claim is authorized by the software evidence above.

## 2026-08-08 — Current-source documentation reconciliation

### Why this entry exists

The dated release-candidate result above remains historical evidence for its
own source snapshot. Subsequent bilateral-fit, intensity, ghost-guide,
trajectory, audio, persistence/privacy, and test changes mean it is no longer a
current release-candidate claim. Historical entries were preserved rather than
rewritten; D-029 supersedes their use as current verification.

### Source facts reconciled

- Final app target: **27 Swift files** after the in-place Defense/accessibility
  slice.
- Final test target: **13 Swift files** after that slice.
- Functional fit: two controlled extension-and-return repetitions per hand;
  independent per-hand acceptance; the minimum accepted left/right scalar is
  the only live-fit value eligible for profile persistence.
- Aura: original procedural ghost glove; three jab/cross repetitions; path,
  extension, and other-hand guard determine the overall score/coaching.
- Execution pace: internal only; not displayed, rewarded, used in coaching, or
  included in overall/Board scoring.
- Trajectory shape: runtime-wired, translation/reach normalized, equal arc-
  length-density resampled, constrained, fail-closed, session-only, shown only
  with complete set coverage, and excluded from coaching/overall scoring.
- Level 1–5: presentation pace and Aura path density only; opt-in deterministic
  next-level proposals require explicit user application and are not ML.
- Audio: five original WAV resources routed through a scene-owned RealityKit
  spatial player; window/in-space mute; no native AVP haptics.
- Local persistence allowlist: boxer profile, bag profile, level, sound, and
  recommendation opt-in only. Evidence, recommendations, repetitions, traces,
  diagnostics, attempts/results, transforms, and room data remain non-persistent.
- Safety: stationary, planted, controlled, submaximal straight extensions only;
  no full-speed/maximum-effort punches, hooks/uppercuts, partner, or physical
  bag while wearing Vision Pro.
- Aura start: refused unless both hands are currently tracked.
- Defense safety: excessive range during cues or inter-cue gaps cancels
  evidence and pauses; neutral plus explicit resume starts a fresh
  countdown/cue. Tracking/system and safety-range pauses are separate result
  fields, and visual/audio cues share one calibrated user-relative basis.
- Accessibility: content-minimum resizable window, scroll-safe accessibility-
  size home/detail layouts, and announcements for important fatal, pause,
  cue/result, transfer, and completion states.
- Reference provenance: main `b570f2e31b638e97fe59110f9909bcd20228bbc7`;
  unmerged direct-child feature commit
  `037e0ae0f1854638ace79b72a2a2996d5475548a`; orphan
  `f500724f1550a7b58a9531fd6ab3157e82954174`; no verified license/asset
  attribution, so concepts only and independently authored implementation.

### Final software verification and open device acceptance

- [x] Final recursive Simulator suite: **111/111 passed**, 0 failed, 0 skipped,
      0 expected failures, 0 runtime warnings; build results report 0 errors and
      0 warnings, and the xcresult analyzer-warning field is 0. No standalone
      Xcode Analyze action was run. Result bundle:
      `/private/tmp/ShadowBoxFinal111Tests.xcresult`.
- [x] Fresh generic visionOS Simulator build: **succeeded**, 0 errors and
      0 warnings; xcresult analyzer-warning field 0. Result bundle:
      `/private/tmp/ShadowBoxFinal111Simulator.xcresult`.
- [x] Fresh unsigned generic arm64 visionOS build: **succeeded**, 0 errors and
      0 warnings; xcresult analyzer-warning field 0. Result bundle:
      `/private/tmp/ShadowBoxFinal111Device.xcresult`.
- [x] Bundle inspection: `Assets.car`, `PrivacyInfo.xcprivacy`, and all five
      original WAV resources are present.
- [x] Final source file counts after the in-place Defense/accessibility slice:
      **27 app / 13 test Swift files**. This is inventory, not a pass result.
- [ ] Signed physical-device install/launch: **not run**.
- [ ] Hand/world permission and live tracking acceptance: **not run**.
- [ ] Bilateral target-placement/repeatability on headset: **not run**.
- [ ] Aura trajectory-diagnostic calibration against physical/reference paths:
      **not run**.
- [ ] Five-resource audio load, latency, localization, overlap, mute, and
      accessibility on headset: **not run**.
- [ ] Defense excessive-range/neutral-resume/fresh-countdown acceptance and
      cue audio/visual alignment on headset: **not run**.
- [ ] Dynamic Type, window-resize, VoiceOver announcement, and focus acceptance
      on physical headset: **not run**.
- [ ] Comfort, safety, false-hit/miss, interruption, and exit acceptance:
      **not run**.

### Documentation reconciled

`README.md`, `SETUP.md`, `PRODUCT_STRATEGY.md`, `ARCHITECTURE.md`,
`DECISIONS.md`, `SESSION_LOG.md`, `TOOLCHAIN.md`,
`RESEARCH_AND_ROADMAP.md`, `REFERENCE_REPOSITORY_AUDIT.md`,
`BOXING_RESEARCH_AUDIT.md`, and `JUDGE_DEMO.md` were selected for reconciliation.
This reconciliation changed documentation only. D-038 and the checked entries
above record the separately completed final software verification; they do not
provide headset, audio-runtime, accessibility, efficacy, or safety evidence.

# ShadowBox — Codex project state and next steps

Updated: 2026-08-08 (Asia/Singapore)

This is the concise handoff for the current ShadowBox workspace. Detailed
architecture, decisions, evidence, research, and operating instructions remain
in the linked project records at the end of this file.

## Current status

ShadowBox is a controller-free, mixed-reality boxing-fundamentals MVP for Apple
Vision Pro. Its current product loop is:

> **Fit → Learn → React**

1. **Anthropometry** records a validated local boxer profile and performs live
   guard plus bilateral functional-reach calibration.
2. **Aura Punch** demonstrates a calibrated jab or cross path and evaluates
   three controlled repetitions.
3. **Reactive Strike** provides a six-pad Board, a static non-contact Bag
   Preview, and planted-feet Defense prompts.

The source is a credible software release candidate, but it is **not yet a
physically validated Vision Pro release**.

### Definitive software evidence

The quiet 05:38 source snapshot produced:

- **111/111 tests passed** on the visionOS 27 Apple Vision Pro Simulator;
- 0 failures, skips, expected failures, or runtime warnings;
- 0 build errors and 0 build warnings;
- xcresult analyzer-warning field 0; no standalone Xcode Analyze action run;
- clean generic visionOS Simulator build;
- clean unsigned generic arm64 visionOS build;
- `Assets.car`, `PrivacyInfo.xcprivacy`, and all five WAV files in both bundles;
- 27 application Swift files and 13 test Swift files;
- `git diff --check` passing.

Result bundles are currently stored under `/private/tmp` and are therefore
machine-local and ephemeral:

- `/private/tmp/ShadowBoxFinal111Tests.xcresult`
- `/private/tmp/ShadowBoxFinal111Simulator.xcresult`
- `/private/tmp/ShadowBoxFinal111Device.xcresult`

No source files changed after that snapshot. Later changes were documentation
only, including this file.

## Implemented user experience

### Home and safety

- Three primary pillars: Anthropometry, Aura Punch, and Reactive Strike.
- Explicit mixed passthrough so the room remains visible.
- Clear-area and hazard acknowledgement before immersive entry.
- Stationary, planted, controlled, submaximal movement contract.
- Stop & Exit available from the normal window and immersive space.
- Tracking loss hides unsafe active visuals and pauses or clears recognition.
- Resizable window, scroll-safe large-text layouts, and important VoiceOver
  announcements.

### Anthropometry and functional fit

- Metric or imperial manual profile fields with internal-consistency guidance.
- Manual dimensions do **not** claim to improve ARKit tracking accuracy.
- Live still-guard capture.
- Two controlled extension-and-return repetitions per hand.
- Independent left/right reach, direction, and projected reference pace.
- Conservative shorter accepted reach per hand for live target placement.
- Only the minimum uncapped accepted bilateral reach scalar may persist.
- World coordinates, directions, capture repetitions, and traces expire with
  the immersive session.

### Aura Punch

- Jab or cross selection with stance-aware hand mapping.
- Original procedural ghost glove and path.
- Three guided repetitions.
- Overall coaching uses path adherence, extension control, and other-hand guard.
- Execution pace remains internal, unscored, and undisplayed.
- Optional trajectory-shape diagnostic is arc-length-density normalized,
  fail-closed, session-only, shown only with complete repetition coverage, and
  excluded from coaching and the overall score.
- Aura cannot start without both hands currently tracked.
- Completed Aura can continue directly into Board without discarding the live
  hand calibration.

### Reactive Board

- Six calibrated pads with stance-aware jab/cross routing.
- Swept-segment contact detection to reduce tunnelling.
- Separate hit, spatial miss, wrong-hand, timeout, and guard-return outcomes.
- Tracking and system interruptions invalidate adaptive evidence rather than
  manufacturing a clean result.

### Defense

- Uses `WorldTrackingProvider` device position as a conservative headset/head
  movement proxy.
- Supports stationary slip-left, slip-right, and duck cues.
- Visual and spatial-audio cues use the same calibrated user-relative basis.
- Excessive displacement during a cue or inter-cue gap cancels evidence and
  pauses the drill.
- The user must return to neutral and explicitly resume into a fresh countdown.
- Tracking/system interruptions and safety-range pauses are reported separately.

### Bag Preview

- Static configurable bag-zone visualization only.
- Starts no ARKit provider.
- Does not recognize, align with, track, or score a physical bag.

### Difficulty and feedback

- Persisted levels 1–5 change presentation pace and Aura path density only.
- Reach, target size, recognition thresholds, scoring, and safety remain fixed.
- Opt-in deterministic recommendations may suggest one adjacent level after a
  complete valid set.
- Recommendations are explainable, require explicit acceptance, and are not ML.
- Five original mono spatial-feedback sounds: cue, clean hit, miss, pause, and
  set completion.
- Sound can be muted in the window or immersive controls.
- Apple Vision Pro has no native haptic implementation in this project.

## Persistence and privacy contract

The local persistence allowlist is:

- validated boxer profile;
- validated bag profile;
- preferred difficulty level;
- sound enabled;
- recommendation opt-in.

The app does not persist motion samples, joint traces, trajectories, world
transforms, room geometry, attempts/results, recommendations, images, video, or
health data. Any workout history or model-data collection requires a new
schema, explicit consent, retention/delete controls, and a recorded decision.

## Architecture invariants

- One normal window and one mixed `ImmersiveSpace`.
- At most one active `ARKitSession`.
- Exactly one consumer of `HandTrackingService.samples`.
- Anthropometry, Aura, and Board use `HandTrackingProvider` only.
- Defense uses `WorldTrackingProvider` only.
- Bag Preview starts no provider.
- `ImmersiveView` owns lifecycle and sample routing.
- Feature engines consume plain timestamped values and remain deterministic.
- RealityKit entities are presentation; they never determine scoring truth.
- ARKit/RealityKit types do not enter the pure motion engines.
- Difficulty and content may never weaken geometry, freshness, scoring, or
  movement-safety invariants.
- The procedural ghost glove remains a safe fallback for future authored assets.

## Current limitations and prohibited claims

Do not claim that the current app provides:

- physical-headset-validated accuracy, comfort, or safety;
- force, power, effective mass, impact, or calorie measurement;
- torso, waist, hip, knee, footwork, balance, or full-body tracking;
- hook, uppercut, pivot, step, partner, or physical-bag coaching;
- professional technique certification, injury prevention, or medical advice;
- a true AI/ML coach or self-learning model;
- a full 3D sparring partner;
- native Vision Pro haptics;
- persistent workout history or proven training efficacy.

Current movement is limited to stationary, controlled, submaximal straight
extensions and planted head-motion rehearsal in a clear area. Do not test with
a physical bag or partner while wearing Vision Pro. The app and headset are not
protective equipment.

## Release blockers

- No paired physical Vision Pro has completed acceptance.
- Organizer-headset visionOS version is unknown; deployment target is visionOS
  27.0.
- Development Team `7M7RWKA8PG` and bundle ID `NTU.Test` must be confirmed or
  replaced before signed installation.
- Only unsigned Debug architecture builds are verified.
- No Release archive, TestFlight upload, or App Store validation has run.
- Product/target/module names remain internally `Test`; user-facing title is
  ShadowBox.
- The complete implementation remains uncommitted relative to baseline commit
  `3d6a228 Initial Commit`. Do not clean or reset this worktree.
- No user, coach, retention, willingness-to-pay, or efficacy study is complete.

## Physical test checklist

Use an adult tester, a cleared well-lit area, planted feet, controlled effort,
no bag or partner, and ideally a second person observing the room.

Stop immediately for discomfort, nausea, headache, headset movement, tracking
instability, unexpected people/objects, boundary change, or unreachable exit UI.

### Install and entry

- [ ] Record headset model/OS, Xcode build, Development Team, bundle ID, date,
      and tester.
- [ ] Signed app installs and launches.
- [ ] Hand permission wording is understandable.
- [ ] Defense can start with hand permission unavailable.
- [ ] Every immersive route remains mixed/passthrough.
- [ ] Safety acknowledgement gates entry.
- [ ] Both Stop & Exit paths are reachable.

### Anthropometry

- [ ] Orthodox and southpaw mappings are correct.
- [ ] Still-guard capture is comfortable and stable.
- [ ] Two left and two right controlled reach repetitions are required.
- [ ] Tracking gaps reset partial capture rather than accepting stale data.
- [ ] Left/right target placement is comfortable and visibly personalized.
- [ ] Profile scalar persists; world calibration expires on exit.

### Aura and Board

- [ ] Aura refuses to start when either hand is unavailable.
- [ ] Ghost guide is correctly placed and never invites contact with a surface.
- [ ] Tracking loss hides the guide and pauses the repetition.
- [ ] Three selected-punch repetitions complete with understandable feedback.
- [ ] Continue to Punch Board retains calibration in the same immersive session.
- [ ] All six pads are reachable without stepping or maximum extension.
- [ ] Intended-hand, wrong-hand, spatial-miss, timeout, and guard-return behavior
      match observation.
- [ ] Stop & Exit preserves the completed summary for window review.

### Defense

- [ ] Neutral calibration is comfortable and user-relative directions are
      correct at the chosen facing orientation.
- [ ] Visual and spatial-audio directions agree.
- [ ] Excessive motion during a cue and between cues pauses the drill.
- [ ] Return to neutral plus explicit Resume starts a fresh countdown.
- [ ] The unsafe return path cannot score.
- [ ] Feet remain planted and the headset remains secure.

### Audio, accessibility, and lifecycle

- [ ] All five sounds load, localize, overlap correctly, and respect mute.
- [ ] Pause/system interruption/exit stops unsafe cues and audio correctly.
- [ ] VoiceOver announces navigation, cues, pauses, fatal errors, transfers, and
      completion without disruptive duplication.
- [ ] Largest text size remains navigable and scrollable.
- [ ] Stop & Exit followed by a second immersive entry restores live samples.
- [ ] Test recovery after tracking loss and app interruption.

## Test observation template

Record observations, not raw participant traces:

```text
Date/time:
Tester initials or non-identifying ID:
Vision Pro model and visionOS:
App build/commit:
Route and selected level:
Facing direction / room notes:

Expected behavior:
Observed behavior:
Reproduction steps:
Frequency:
Tracking status shown by app:
Audio / visual / accessibility impact:
Comfort or safety impact:
Stop & Exit reachable: yes / no
Screenshot or screen recording reference, if consented:

Suggested severity:
P0 = crash, data loss, unsafe/unreachable exit
P1 = blocks a core route or produces misleading feedback
P2 = degraded but usable
P3 = cosmetic
```

Do not retain identifiable participant video, audio, health information, or
motion traces without explicit consent and a documented retention plan.

## Best next steps

### P0 — preserve and prove the current foundation

1. Create a release branch and commit/tag the verified snapshot after owner
   authorization.
2. Confirm signing identity, unique bundle ID, and headset OS compatibility.
3. Execute the physical checklist above and log every failure/observation.
4. Fix only physical P0/P1 issues; rerun the full suite and both architectures.
5. Freeze the exact signed demo build and retain its commit, Xcode version,
   device OS, result bundles, and backup recording.

### P1 — integrate one authored 3D trainer

1. Create `Packages/ShadowBoxRealityContent`, a Reality Composer Pro Swift
   package.
2. Commission or license one stylized trainer with one skeleton and stable
   named attachment points.
3. Start with baked, coach-reviewed clips: idle guard, slow/normal jab and cross,
   return guard, slip left/right, duck, correction, encouragement, completion.
4. Add `TrainerAssetRepository`, `TrainerAnimator`, and
   `TrainerSceneController` under `Test/Reality/Coach`.
5. Load asynchronously before countdown and cache one trainer instance.
6. Integrate the trainer into Aura demonstration only; preserve the procedural
   glove fallback.
7. Keep animations presentation-only; existing engines retain scoring truth.
8. Profile draw calls, geometry, materials, animation, memory, and thermal
   behavior using RealityKit Trace on the headset.

Every asset needs a provenance entry with creator/vendor, source URL, full
license, purchase/assignment proof, redistribution/modification rights,
attribution, performer/voice/likeness releases, modifications, and hashes.

### P1 — add a data-driven training-content layer

Add these boundaries without moving safety logic into JSON:

```text
Test/Domain/TrainingContent/
Test/Training/
Test/Features/Library/
Test/Persistence/ProgressRepository.swift
Test/Reality/Coach/
Test/Resources/TrainingContent/
```

Implement in this order:

1. `AuraRunSpec`, `BoardRunSpec`, and `DefenseRunSpec` with current defaults.
2. Strict `LessonManifest` and `ContentPackManifest` models.
3. `ContentManifestLoader`, `ContentManifestValidator`, and bundled catalog.
4. `TrainingSessionCoordinator` as the sole lesson-transition owner.
5. Replace the hard-coded Aura-to-Board transition with coordinator actions.
6. Add Today, Training Library, duration, focus, and lesson-detail views.
7. Ship a bundled, coach-reviewed 12-session Foundations program.

Manifests may select approved punch/order, repetitions within bounds, coaching
focus, rest, trainer action, voice, captions, and presentation theme. They may
not define raw coordinates, reach, target radii, scoring weights, tracking
freshness, maximum displacement, or unsupported techniques.

### P1 — make it a daily companion

- Lead the home experience with a **Today's Training** card while preserving
  the three existing pillars as the manual library.
- Offer Ready, Make it lighter, Choose another session, and Rest today.
- Compose 3-, 7-, and 12-minute sessions from reusable blocks.
- Begin with a 12-session Foundations curriculum covering guard, jab, cross,
  recovery, Board transfer, and stationary Defense.
- Use staged guidance: Guided → Practice → Challenge → fixed Checkpoint.
- Keep daily recommendations deterministic, explainable, and user-overridable.
- Treat rest/light sessions as valid; do not use punitive streak loss.

### P2 — optional local progress

- Add a separate, opt-in `ProgressRepository`; do not expand `UserDefaults` or
  `TrainingProfileStore` into a workout database.
- Persist only date bucket, duration, versioned lesson, difficulty, completion,
  aggregate skill summaries, and interruption counts.
- Provide history-off mode, delete-all, export, documented retention, and schema
  migrations.
- Use rolling comparable checkpoints, not peak-speed rewards.
- Label progress Introduced, Guided, Practiced, or Consistent in ShadowBox—not
  Mastered or Certified.

### P3 — only after device and user evidence

- Coach voice/captions and alternate presentation styles.
- Pad-holder and predictable non-contact partner roles.
- Managed downloadable content packs containing data/assets only.
- Additional coach-reviewed straight-punch combinations.
- iPhone full-body companion and waist-IMU research as separate sensor tiers.
- Core ML only after consented expert-labelled data, participant-separated
  evaluation, uncertainty/abstention, opt-out, and deterministic baselines.
- Bounded sparring only after demonstrator and pad-holder modes prove safe,
  useful, comfortable, and technically credible.

## Suggested first content pack

1. Orientation and conservative fit
2. Jab path
3. Jab guard recovery
4. Jab Board transfer
5. Cross path
6. Cross guard recovery
7. Cross Board transfer
8. Alternating straight punches
9. Lead-hand accuracy
10. Rear-hand accuracy
11. Stationary slip/duck recognition
12. Fixed-condition checkpoint and reflection

Reusable daily templates: Technique Reset, Precision Day, Reaction Day,
Defense Light, Mixed Fundamentals, and Checkpoint.

## Working rules for future Codex sessions

- Read `README.md`, `ARCHITECTURE.md`, `DECISIONS.md`, `SESSION_LOG.md`, and this
  file before editing.
- Preserve the current dirty worktree; never reset, clean, or overwrite user
  changes.
- Do not stage, commit, rename the project, change signing, or push without
  explicit owner authorization.
- Use `/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild`.
- Keep one mixed immersive space, one active ARKit session, and one hand-sample
  consumer.
- Keep ARKit in `Spatial`, RealityKit in `Reality`, and deterministic motion
  logic free of either framework.
- Use `apply_patch` for source/document edits.
- Add tests for every engine, state, persistence, migration, content-validation,
  and safety change.
- After source changes, rerun the full recursive Simulator suite plus generic
  Simulator and generic visionOS builds, then inspect xcresult error/warning
  fields rather than trusting only process exit status.
- Never describe a generic build or Simulator result as physical-device proof.
- Keep limitations visible in UI and documentation.

## Build commands

```bash
cd /Users/event/Desktop/Hacklings/Spatial_Hack_AI/Test

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
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /private/tmp/ShadowBoxSimulatorBuild \
  -resultBundlePath /private/tmp/ShadowBoxSimulatorBuild.xcresult \
  CODE_SIGNING_ALLOWED=NO

/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  build \
  -project Test.xcodeproj \
  -scheme Test \
  -configuration Debug \
  -destination 'generic/platform=visionOS' \
  -derivedDataPath /private/tmp/ShadowBoxDeviceBuild \
  -resultBundlePath /private/tmp/ShadowBoxDeviceBuild.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

## Project records

- [README.md](README.md) — product and verified-current overview
- [SETUP.md](SETUP.md) — environment, build, run, and troubleshooting
- [ARCHITECTURE.md](ARCHITECTURE.md) — runtime graph and invariants
- [DECISIONS.md](DECISIONS.md) — decision log; D-038 is current evidence
- [SESSION_LOG.md](SESSION_LOG.md) — commands, results, and device checklist
- [TOOLCHAIN.md](TOOLCHAIN.md) — exact local Apple toolchain
- [PRODUCT_STRATEGY.md](PRODUCT_STRATEGY.md) — user/market-fit position
- [JUDGE_DEMO.md](JUDGE_DEMO.md) — truthful four-minute demo and fallback
- [RESEARCH_AND_ROADMAP.md](RESEARCH_AND_ROADMAP.md) — evidence-led roadmap
- [REFERENCE_REPOSITORY_AUDIT.md](REFERENCE_REPOSITORY_AUDIT.md) — external
  repository provenance and adoption decisions
- [BOXING_RESEARCH_AUDIT.md](BOXING_RESEARCH_AUDIT.md) — boxing evidence and
  measurement boundaries
- [Design/Audio/README.md](Design/Audio/README.md) — original feedback audio
- [Design/AppIcon/README.md](Design/AppIcon/README.md) — original icon pipeline

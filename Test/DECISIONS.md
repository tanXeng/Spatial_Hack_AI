# ShadowBox decision log

## D-001 — Source of truth and later owner instructions

`ShadowBox_MVP_Handover.md` is authoritative when it conflicts with the Word
handover. The Word document still supplies stronger record-keeping and test
matrix guidance. A later explicit owner instruction can expand the handover;
such an expansion is recorded below before implementation.

## D-002 — Keep the existing project identity

The repository contains `Test.xcodeproj`, scheme `Test`, target `Test`, and
module `Test`. They are not being renamed during the MVP because a rename would
create broad project churn. The user-facing title is ShadowBox.

## D-003 — Keep the current visionOS 27.0 target

The project was created with a 27.0 deployment target and the matching 27.0
Simulator is installed. The target remains unchanged until the organizer
headset OS and required compatibility are known. Lowering it to the provisional
26.0 handover value requires a separate compatibility decision.

## D-004 — Do not change the global Xcode selector automatically

Builds invoke the tools inside `Xcode-beta.app` directly. The owner can switch
`xcode-select` later with administrator privileges.

## D-005 — Historical M1 boundary, superseded for software scope

The initial implementation was intentionally limited to the handover's M1
diagnostic milestone: mixed passthrough, hand markers, one programmatic mitt,
and explicit fallback states. D-011 supersedes that software-only scope after
the owner explicitly requested the broader MVP. Physical M1 acceptance remains
outstanding and is not implied by the later software work.

## D-006 — Diagnostic hand representation

Each tracked hand exposes wrist plus thumb, index, middle, ring, and little
fingertip markers. A fist center is calculated only when at least three of four
knuckle joints are finite and tracked. Left and right anchors keep independent
ARKit anchor-update timestamps, while a separate receipt clock governs
freshness and watchdog behavior. One hand's update therefore cannot manufacture
velocity for the other. ARKit types do not leave `HandTrackingService`.

## D-007 — Programmatic mitt prototypes

The expanded MVP uses separate programmatic jab and cross mitts. Their logical
centers are derived from the user's measured guard, measured comfortable reach,
and straight-punch direction. RealityKit color, opacity, and scale are feedback
only; deterministic Swift geometry owns hit evaluation.

## D-008 — Safe tracking loss and terminal failure

Stale or removed anchors hide that hand's markers and fist center. Losing either
required hand during a countdown or round cancels the active cue, freezes active
time and scoring, and requires both hands to hold the calibrated guard before
resuming. Permission denial, provider stop, event-stream end, and unrecoverable
session error abort the drill into an explicit failure state instead of silently
resuming.

## D-009 — Local ephemeral tracking only

The service processes joint transforms in memory. It does not persist or upload
camera data, joint samples, participant traces, results, or identifiers. A
completed round summary exists only in app memory for the immediate results
screen. Persisting test traces or summaries later requires participant consent
and a new owner decision.

## D-010 — Historical template-preservation decision, superseded

The first implementation pass preserved the stock immersive-video player and
authored scene while the ShadowBox entry path was being stabilized. D-025
supersedes that temporary choice after source search and repeated builds proved
the files were unused.

## D-011 — Owner-authorized full software MVP

On 2026-08-07 the owner supplied Swift, Apple visionOS, Step Into Vision,
Explore SwiftUI, Hacking with Swift, and local IntroRealityKit references and
asked to make the entire implementation comprehensive, with an MVP acceptable
for now. This explicitly authorizes software implementation beyond M1:
stance-aware calibration, jab/cross cues, a 60-second round, deterministic hit
evaluation, tracking pause/resume, and non-clinical results. It does not waive
the physical-headset validation gate or authorize ML, networking, avatars,
footwork, or participant-trace retention.

## D-012 — Deterministic provisional drill model

The drill uses plain Swift state and swept segment-to-sphere intersection. It
requires a stable two-second guard, then one straight extension of at least
0.32 m that returns to guard while the other hand stays near guard. The target
uses 82% of measured reach. A punch requires a fresh per-hand timestamp,
observed guard, at least 0.11 m guard departure, at least 0.12 m forward travel,
at least 0.45 m/s outward speed, and a 70% forward-direction ratio. Target and
fist radii are 0.09 m and 0.035 m. These constants are deliberately centralized
and provisional pending physical tuning; they are not biomechanical, force,
power, protection, or medical measurements.

## D-013 — Calibration occurs inside mixed immersion

Live hand anchors are owned by the immersive scene, so guard and reach
calibration occur after entering the explicitly mixed space. This is a conscious
reordering of any window-only calibration wording in the source handover. The
safety acknowledgement remains required before entry.

## D-014 — Persistent safety controls and single-window ownership

The normal window keeps a pinned Enter/Stop button outside scrollable content.
The mixed space also contains a compact `ViewAttachmentComponent` with a
Stop & Exit action, positioned below the punch targets. The scene manifest
supports multiple scenes as visionOS requires for the window-plus-immersive
configuration, while the primary controls use a single-instance `Window`
instead of a duplicable `WindowGroup`. The immersive scene owns the tracking
sample consumer, scene-phase pause/resume, and round engine. Before any
app-controlled immersive exit, the app requests that visionOS open or reorder
the single main window, then requests immersive dismissal. This follows Apple's
last-scene sequencing guidance; actual closed-window restoration remains a
physical-headset acceptance check.

## D-015 — Interruption and timing semantics

System inactivity/backgrounding pauses an active countdown or round. Each hand
pose keeps its anchor capture time; the aggregate sample time is only a publish
time. Contacts are accepted only when their interpolated capture time lies
inside the cue window. A maximum-sample-interval delivery grace prevents a clock
tick from racing a valid final anchor, but the mitt stops looking active at the
exact cue deadline. A valid straight extension that does not contact the target
is resolved as a spatial miss when retraction begins; an absent attempt resolves
as a timeout. Guard-return success requires a post-attempt pose captured by the
deadline. Interrupted cues are reported separately rather than counted as
misses.

## D-016 — Session-scoped calibration and results handoff

Guard and target coordinates are valid only for the immersive session in which
they were measured. Leaving that session always invalidates calibration and
hides the mitts until fresh calibration. Completing a round automatically exits
the immersive space so results can be reviewed in the normal window; the
non-sensitive summary remains in memory until the user prepares another round
or closes the app. Completion enters a transition state before dismissal so
late Stop or “Train Another Round” actions cannot erase the summary.

## D-017 — Accessible cue fallback

The in-space attachment exposes tracking, round phase, expected punch, feedback,
and Stop & Exit as text. Cue and outcome changes also post system accessibility
announcements. These supplement visual mitt color and do not alter drill timing
or scoring.

## D-018 — Validation boundary

When this decision was recorded, the earlier two-mitt core could be described as
simulator-tested and successfully compiled for the physical visionOS
architecture. D-024 governs the later three-pillar expansion; the older evidence
must not be generalized to its new modes. Neither version may be described as
physically validated until a paired Apple Vision Pro confirms passthrough,
control availability, comfort, target placement, live tracking, pause, resume,
and exit. The organizer headset OS, tester, signing identity, and final
deployment target remain unresolved.

## D-019 — Owner-authorized three-pillar product structure

The current Boxing Trainer expansion opens on three primary choices:
Anthropometry, Aura Punch, and Reactive Strike. Reactive Strike contains a
six-pad Virtual Board, Physical Bag Preview, and Stationary Defense. This later
owner instruction supersedes D-011's two-mitt drill as the current software
product structure. It does not supersede the mixed-immersion safety controls,
ephemeral tracking boundary, or physical-headset validation gate.

## D-020 — Pinned read-only UI reference and provenance boundary

`https://github.com/tanXeng/Spatial_Hack_AI` at commit
`b570f2e31b638e97fe59110f9909bcd20228bbc7` is the pinned reference for
information hierarchy and UI-layer format. It was reviewed read-only; Codex did
not clone, modify, or write to the remote repository. No declared license was
identified at that pinned state. Accordingly, no source code, authored asset,
or other repository content is copied verbatim. The current interface and
feature implementation are independently authored in SwiftUI and RealityKit.

## D-021 — Scalar local configuration may persist

D-009 continues to prohibit persistence of live tracking and participant
traces, but the owner-authorized product now permits validated configuration
scalars to persist as local JSON in `UserDefaults`. A boxer profile contains
canonical metre values for height, arm span, left/right arm length, shoulder
width, and optional measured comfortable reach, plus stance/dominant-hand
labels. A bag profile contains only its type, target layout, and scalar
dimensions. Corrupt or implausible values are rejected and reset. Joint samples,
world transforms, room data, raw camera data, round results, and motion traces
are never persisted. Guard and other world-space calibration coordinates are
still invalidated when the immersive session ends.

## D-022 — Implemented coaching boundaries are deliberately narrow

- Anthropometry provides a functional scalar profile and live guard/reach
  calibration; it is not a clinical measurement and does not change ARKit's
  underlying tracking accuracy.
- Aura Punch coaches hands only: fist path, extension, speed, and the other
  hand's guard. It does not observe or score feet, legs, hips, torso, or
  whole-body posture.
- Virtual Board is a deterministic six-pad reaction drill for jab/cross cues.
- Stationary Defense uses the device position as a head-position proxy for
  slip-left, slip-right, and duck cues. The user keeps their feet planted; the
  MVP does not claim footwork, hip-motion, balance, or professional-technique
  assessment.
- Physical Bag Preview is a static, non-contact visualization only. It neither
  aligns to nor tracks a real bag, and it performs no contact, impact, force, or
  power measurement.

## D-023 — Companion, physical-contact, and whole-body features are deferred

This MVP has no iPhone/iPad companion, marker-based bag registration, shared
coordinate session, object scan, networking, force sensing, physical-bag strike
mode, footwork tracking, hip tracking, or body/posture scoring. Adding any of
those capabilities requires a later owner decision, appropriate privacy and
safety design, and physical-hardware validation. Product language must not imply
that the current hand/head proxies provide those absent capabilities.

## D-024 — Current expansion verification boundary

The latest three-pillar source has an evidenced unsigned generic visionOS
Simulator build. Final expanded simulator tests, a current generic physical
visionOS architecture build, signed installation, and headset validation remain
pending. The 22-test and physical-architecture results recorded for the earlier
two-mitt core remain historical evidence only and must not be reported as final
validation of the expanded modes.

## D-025 — Research-shaped architecture without speculative layers

The owner-supplied research is treated as a capability and architecture map,
not as an instruction to import every referenced repository or framework. The
MVP now has physical ownership folders for App, Domain, Motion, Spatial,
Reality, Persistence, and implemented feature UI/state. `ContentView` was split
into real Profile, Aura, and Reactive panel files. No TCA, package target,
networking, Core ML, audio, empty `ML/`, or empty `Biomechanics/` layer was
added. Motion remains deterministic and independent of ARKit/RealityKit types.

The unused `AVPlayerView`/`AVPlayerViewModel` pair and stock `Immersive.usda`,
`Ground.usda`, `SkyDome.usdz`, and `DefaultAttenuationMap.exr` assets were
removed. They had no runtime caller, media URL, product provenance, or test
coverage and added more than one megabyte to the bundle. They remain recoverable
from baseline commit `3d6a228` if a separately licensed video lesson is designed
later.

## D-026 — Provider permissions match the active feature

There is still at most one `ARKitSession`, but the session runs only the provider
required by the selected experience. Anthropometry, Aura Punch, and Virtual
Board run `HandTrackingProvider`. Stationary Defense runs
`WorldTrackingProvider` and therefore does not depend on hand authorization.
Physical Bag Preview starts no provider because its MVP placement is static.
This mutually exclusive design makes provider-state events unambiguous and
avoids unrelated permissions or provider failures.

World queries occur only while `WorldTrackingProvider.state == .running`.
Hand-pose freshness must satisfy both receipt age and the anchor's own capture
age; calibration rejects non-finite and non-increasing samples and restarts
after a continuity gap.

## D-027 — Product position and judge claim discipline

ShadowBox is positioned as a premium, controller-free spatial technique lab for
Vision Pro owners and supervised coached demos. Its present wedge is the
closed-loop sequence **Fit → Learn → React**: personal geometry, embodied hand-
path instruction, then reaction practice with explainable local feedback. It is
not positioned as mass-market fitness, a fight simulator, force measurement,
full-body biomechanics, medical technology, or an AI coach.

`PRODUCT_STRATEGY.md` separates external evidence, build evidence, and
hypotheses; defines measurable device, reliability, user-value, and market
gates; and supplies stop/pivot conditions. No commercial, accuracy, retention,
or technique-efficacy claim may move from hypothesis to fact without those
tests.

## D-028 — Expanded software verification is complete; hardware validation is not

D-024's pending software-verification state is superseded. On 8 August 2026,
the recursively discovered visionOS Simulator suite passed **54 tests with 0
failures and 0 skips**. A fresh generic visionOS Simulator build and a fresh
unsigned arm64 physical-visionOS architecture build also passed from the same
release-candidate source. The current shared `Test` scheme is repository-owned,
and the application bundle contains no removed stock scene/video resources.

This evidence validates compilation and deterministic software behavior only.
There is still no paired headset, signed install, permission-flow run, live
hand/head session, comfort study, accuracy study, or efficacy study. Product
copy must continue to describe thresholds as provisional and physical-device
acceptance as open.

## D-029 — Current verification supersedes release-candidate status

D-028 remains a historical record of the source snapshot that produced its
54-test release-candidate result. It is no longer current verification evidence
after the bilateral fit, training-intensity, procedural-guide, trajectory,
audio, privacy-manifest, and related test changes.

At this decision snapshot the tree contains 27 app Swift files and 13 test Swift
files before any separately pending final Defense-only change. The current
recursive test count, generic Simulator build, and unsigned arm64 build are
**pending final rerun**. No number or pass result may be inferred from file
presence or the older result bundle. Signed installation, permission flow, live
tracking, device comfort, and on-headset audio remain pending.

## D-030 — Bilateral functional fit supersedes the one-repetition reach model

D-012's one-repetition reach description is historical. The current source
requires two controlled extension-and-return repetitions per hand, completed
one hand's pair at a time while the other remains near guard. Each hand is
evaluated independently. Its shorter repetition is accepted only when the pair
differs by no more than the larger of the provisional 5 cm floor and 12% of the
shorter reach.

Hand-specific guard, direction, reach, and projected reference pace remain
available only inside the current immersive session. The sole live-fit scalar
eligible for local profile persistence is the minimum uncapped accepted
left/right reach. Per-hand repetitions, reports, pace evidence, and world-space
state are not persisted. This is a repeatability/placement rule—not anatomy,
clinical measurement, or device-accuracy evidence.

## D-031 — Presentation level and next-set advice are deterministic, not ML

The app stores a user-selected level 1–5, sound enabled state, and
recommendation opt-in locally. Level changes presentation pace and Aura path-
point density only; reach, target size, motion thresholds, score weights, and
safety do not change.

`TrainingIntensityAdvisor` is an opt-in deterministic rule set over aggregate,
complete-set evidence. It holds after interruptions or insufficient evidence,
proposes at most one adjacent level, explains the reason, and requires explicit
user application. It does not learn, run Core ML, or change a level
automatically. Evidence and recommendation instances remain session/app memory
and are not persisted.

Relative execution pace may be calculated internally, but it is not displayed,
rewarded, used in coaching, used by the recommendation policy, or included in
Aura/Board scoring. “Presentation pace” in the level UI is a setting, not a
measured punch score. Board/Defense response-time ratios may inform a next-level
proposal; they remain timing evidence rather than punch-speed or technique
scores.

## D-032 — Aura uses an original procedural glove and a separate trajectory diagnostic

The Aura visual is an independently authored procedural ghost glove constructed
from RealityKit primitives. It does not bundle a third-party model or imply an
observed elbow, shoulder, torso, or hip.

Aura's coaching/overall score remains path 45%, extension control 30%, and
other-hand guard 25%. A runtime-wired trajectory-shape diagnostic is separate:
it validates complete contiguous out-and-back paths, translates by guard,
normalizes by reach, resamples both polylines to equal cumulative-arc-length
density, and applies banded constrained DTW. Invalid inputs return no value, and
a set value appears only when every repetition is valid. It is session-only,
speed-independent, excluded from coaching/overall scoring, and must be labelled
a hand-path diagnostic—not technique or biomechanics.

## D-033 — Spatial audio is source-wired; native AVP haptics do not exist

Five original WAV files—cue, clean hit, miss, pause, and set completion—are
preloaded and played from scene-owned RealityKit spatial-audio entities.
Logical drill state remains scoring truth. The user can mute sound in the
window and immersive controls, and the preference persists locally. Load or
playback failure cannot change scoring or carry the only safety information.

Resource presence/source wiring is not headset acceptance. Physical playback,
latency, localization, overlap, mute, accessibility, and thermal behavior are
pending. Apple Vision Pro has no native Core Haptics support; audio/visual
feedback must not be described as headset haptics.

## D-034 — Current persistence allowlist is exact

D-021 remains the origin of scalar-profile persistence but is expanded by the
explicit preference decisions above. The current local persistence allowlist is
only:

- validated boxer profile, including the optional conservative reach scalar;
- validated bag profile;
- level 1–5;
- sound enabled;
- recommendation opt-in.

Recommendation instances/evidence, Board/Aura/Defense attempts and results,
functional-fit repetitions/reports, trajectory traces/diagnostics, ARKit
samples, world transforms, calibration coordinates, room data, images, and
video remain non-persistent. Any history, trace, or model-data collection needs
a new schema, consent/retention design, and recorded decision.

## D-035 — Controlled submaximal stationary safety is the only current headset envelope

Apple's safety guidance not to run or make sudden movements requires a narrower
product/test envelope than unconstrained boxing. Any future headset validation
uses a well-lit cleared area, planted stationary stance, and controlled,
submaximal jab/cross extensions only. Full-speed or maximum-effort punches,
hooks/uppercuts, steps, pivots, spins, partner work, and physical-bag contact are
outside the current scope. Tracking loss, boundary change, discomfort, headset
slip, or obstacle/person entry causes pause or Stop & Exit.

This decision is a conservative risk boundary, not proof that Vision Pro boxing
is safe or that the app/headset provides protection.

## D-036 — Latest `Spatial_Hack_AI` provenance and concept-only adoption

The external reference's default main remains pinned at
`b570f2e31b638e97fe59110f9909bcd20228bbc7`. The unmerged
`feat/aura-punch` commit `037e0ae0f1854638ace79b72a2a2996d5475548a`
is its direct child (15 changed files, approximately `+3,148/-57`), while
`aurapunch-ian` at `f500724f1550a7b58a9531fd6ab3157e82954174`
is an orphan line. None is silently treated as the current default branch.

No repository root license/SPDX or asset-attribution register was verified.
ShadowBox therefore uses independently authored implementations and adopts only
concepts: a procedural guide, one timestamped tracking owner, fail-closed
constrained trajectory comparison, and deterministic offline feedback. A
licensed rigged coach, JSON lesson schema, visualization-only IK, and hooks/
uppercuts remain deferred. Head-yaw-as-torso, inferred-joint scoring, stale-pose
polling, embedded cloud-model keys/clients, and unattributed assets are rejected.
`REFERENCE_REPOSITORY_AUDIT.md` is the detailed provenance record.

## D-037 — Final source slice fails closed and remains verification-pending

D-029's pre-slice count remains numerically unchanged: the reconciled final
source has 27 app Swift files and 13 test Swift files because the final
Defense/accessibility work edited existing files. Aggregate recursive tests,
generic Simulator/arm64 builds, signing, headset behavior, audio runtime, and
assistive-technology acceptance remain pending; focused or source inspection
evidence must not be substituted for that aggregate record.

Defense now treats excessive displacement during both active cues and
inter-cue gaps as a safety-range interruption: active evidence is cancelled,
adaptive evidence is invalidated, and the drill pauses. A return to the
calibrated neutral radius plus an explicit user resume is required, followed by
a fresh countdown/cue; the unsafe return path cannot score. Results report
tracking/system interruptions separately from safety-range pauses. Rendered
and spatial-audio Defense cues share one calibrated user-relative cue basis.

Aura start is refused unless both hands are currently tracked. The main window
is content-minimum resizable; accessibility-size home cards and feature content
are scroll-safe; important fatal, pause, cue/result, transfer, and completion
states post accessibility announcements. These are source contracts, not
claims of device safety, accessibility certification, or completed validation.

## D-038 — Quiet 05:38 snapshot is the definitive current software evidence

D-037's aggregate-verification placeholder is superseded. The quiet 05:38
final-source snapshot produced this exact evidence:

- `/private/tmp/ShadowBoxFinal111Tests.xcresult`: 111/111 recursively
  discovered tests passed; 0 failed, skipped, or expected failures; 0 runtime
  warnings; build results report 0 errors and warnings, and the xcresult
  analyzer-warning field is 0;
- `/private/tmp/ShadowBoxFinal111Simulator.xcresult`: generic visionOS
  Simulator build succeeded with 0 errors and warnings; xcresult
  analyzer-warning field 0;
- `/private/tmp/ShadowBoxFinal111Device.xcresult`: unsigned generic arm64
  visionOS build succeeded with 0 errors and warnings; xcresult
  analyzer-warning field 0.

No standalone Xcode Analyze action was run; these analyzer values are metadata
fields from the recorded Test/Build actions.

Both app bundles contain `Assets.car`, `PrivacyInfo.xcprivacy`, and all five
original WAV resources. D-028 remains historical evidence for its older source
only and must not be quoted as current. This decision establishes software
compilation and deterministic-test evidence; it does not establish signing,
installation, authorization, live tracking, headset accuracy/comfort/safety,
spatial-audio localization/latency, accessibility acceptance, or efficacy.

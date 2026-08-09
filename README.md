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

## Product flow

The app opens on the normal feature selector. Aura Punch and Reactive Strike remain available as
unranked training. A compact **Join Competition** button in the top-right opens an optional local
competition sheet; there is no host setup, password, PIN, account, avatar, or cloud service.

A player enters only a name. Unicode case, width, and diacritic normalization reopen the same local
player automatically. New players calibrate the comfortable forward reach of both arms. That
body-relative measurement is reused on later joins and can be replaced with **Recalibrate Reach**.
Guard positions are still recaptured before every run because guard depends on the current pose. If
a saved reach cannot safely place targets beyond the new guard, gameplay stops and the sheet asks
the player to recalibrate.

Competition contains exactly two independent boards:

- **Reactive Strike** — eight targets.
- **Combo** — five repetitions of the fixed `1–2–3–2` sequence, with Orthodox or Southpaw chosen
  only when entering Combo and remembered for the next run.

Players may submit unlimited complete runs; each board ranks their best result. Aura Punch never
appears on a competition board. An overflow action on the leaderboard can reset all local players,
calibrations, and results after destructive confirmation, but reset is unavailable during a run or save.

## Competition scoring

Both modes produce an integer score from 0 through 100. Correctness contributes 80 points and
centre accuracy contributes 20 using linear normalization inside the existing target radius.
Missed or invalid steps earn zero in both components. Speed never changes the score.

Reactive Strike ranks by score, valid hits, lower mean centre error, then lower average reaction
time. Combo ranks by score, completed repetitions, valid required-hand/outbound/contact/retraction
steps, lower mean centre error, then lower active elapsed time. Exact metric ties share a rank;
normalized player name is used only for stable display order. Cancelled, partial, stale-tracking,
and technical-failure sessions are never submitted.

Competition data uses a fresh versioned SwiftData schema named `BoxingCoachCompetitionV1`, with
CloudKit disabled. Submission UUIDs make finalization exact-once. The previous Event Edition schema
is intentionally not migrated, so the two boards begin empty.

## Training and tracking behavior

Aura Punch exposes one Uppercut drill that alternates hands each repetition. Its mirrored reference
paths load beside the hip, drive diagonally inward, and peak at the body centreline. The target-fix
capture continues through retraction, while outbound-only attempts retain the intended fallback.

Reactive Strike captures both guard positions and, when needed, measures a held outward extension
from each arm instead of finalizing while the fist is still moving. It uses the shorter comfortable
reach so targets remain available to either hand, and places reactive targets in the final 10% of
that measured range. Calibration and target placement use the live head-derived body frame rather
than world Z or fixed room height, keeping the drill invariant as the user moves or turns.

Combination Mode presents one target at a time and accepts a step only after the stance-derived
physical hand leaves guard with outward velocity, reaches the target, and retracts. Wrong-hand
contact and a stationary extended fist do not advance the sequence. Competition fixes this sequence
to `1–2–3–2`; unranked training retains the normal combination chooser.

visionOS provides tracked hands and processed forearm joints, plus the headset pose. It does not
provide direct shoulder or full-body tracking. Boxing Coach estimates each shoulder from the headset
pose and local body measurements, then uses the tracked forearm as an elbow-bend hint. It cannot
directly evaluate shoulder roll, hip rotation, foot placement, or impact force.

The selection window is dismissed only after the immersive scene becomes ready. Completion, error,
early ending, and system dismissal restore the single control window before immersion closes. The
immersive view keeps a visible, accessible **End Training** action and paired visual/text feedback.

## Project architecture

```text
BoxingCoach/
├── Competition/  player identity, fresh SwiftData schema, scoring, store, and compact sheet UI
├── Models/       stance, technique, and body-measurement models
├── Resources/    locally authored reference punch trajectories
├── Scoring/      motion recording, path comparison, scoring, and feedback
├── Spatial/      body-relative arm solving and silhouette rendering
├── UI/           typed flow, setup, immersive lifecycle, and shared components
├── *Session.swift
├── Combination*.swift
└── HandTrackingService.swift
```

The project uses Xcode synchronized groups, so new source and test files inside the synchronized
folders do not require hand-editing `project.pbxproj`.

The unit target covers competition name lookup, bilateral reach persistence, exact-once saves,
reset protection, 0–100 scoring, invalid steps, best-result selection, speed tie-breaks, joint ranks,
target-fix Aura regressions, body-relative calibration, combination validation, and flow routing.
Simulator tests do not prove live hand tracking, translation/yaw comfort, or punch feel; those remain
Vision Pro acceptance items.

## Repository policy

Git contains only buildable source, Xcode metadata, runtime resources, `.gitignore`, `Makefile`, and
this README. The entire `local/` directory is ignored. ShadowBox is archived locally at
`local/ShadowBox-archive/` and is not active source.

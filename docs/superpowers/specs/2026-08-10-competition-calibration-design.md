# Competition Calibration Workflow Design

## Context

The `monday-morning` merge introduced a shared `BodyCalibration` and a dedicated
`ReactiveStrikeSession.startCalibration()` loop. The standalone Anthropometry route uses that
loop, but `.competitionCalibration` still clears calibration and starts the normal drill loop.
That loop requires an existing measured reach, so Competition calibration fails before it can
measure either arm.

The current reach sampler also cues “left arm first” while processing both hands concurrently.
Consequently, a right-hand extension can be accepted first even though the user is told to start
with the left.

## Goals

- Use one calibration implementation for standalone and Competition calibration.
- Enforce the visible workflow: capture guard, measure left reach, then measure right reach.
- Replace the launch-wide calibration only after both arms complete successfully.
- Persist the same bilateral reach to the active Competition player.
- Feed that result into Reactive Strike Competition, Combo Competition, and non-competition
  training for the remainder of the launch.
- Preserve body-relative measurement, settled-hold detection, conservative reach selection, and
  the existing Competition persistence model.

## Non-goals

- Changing target scoring, punch validation, leaderboard ranking, or competition duration.
- Persisting guard positions across app launches. Guard positions remain current-launch body-frame
  data; only bilateral reach remains in the player record.
- Changing the authored reach profile or calibration thresholds.

## Architecture

`ReactiveStrikeSession` will expose standalone and Competition calibration entry points that both
delegate to one internal starter and one measurement loop. The Competition entry point selects
the existing user-paced timing policy, while the standalone entry point retains bounded retries.
The normal target/combination drill loop will no longer act as a calibration implementation.

The shared loop will perform these states in order:

1. Capture stable left and right guard positions in the live head-derived body frame.
2. Confirm the left fist at guard, then accept samples only from the left hand until its settled
   forward reach is valid.
3. Prompt for the right hand, confirm it at guard, and accept samples only from the right hand.
   Any right-arm movement made during the left stage is discarded.
4. Validate that both measurements form a plausible `BilateralReach`.
5. Atomically store both reaches and both guard positions in the shared `BodyCalibration` and mark
   the session finished.

Each arm uses the existing candidate validation, plateau detector, and robust timeout fallback.
Standalone calibration gives each hand the existing 14-second settled-hold window before using
the robust fallback; Competition calibration remains cancellable and has no automatic deadline.
The active hand must produce three fresh samples inside the existing combination guard radius
before its extension samples are accepted. A failed or cancelled attempt does not publish a
partial dictionary and does not overwrite the last complete shared calibration.

## Data flow

```text
Competition player selection
  -> TrainingSelection.competitionCalibration
  -> shared ordered calibration loop
  -> BodyCalibration.store(left, right, guards)
  -> CompetitionStore.reconcileCompletedRun
  -> CompetitionPlayer.reach
  -> configureCompetition(Reactive Strike or Combo)
  -> calibrated ReachProfile using min(left, right)
```

Because `BoxingCoachApp` injects the same `BodyCalibration` into `ReactiveStrikeSession` and
`TrainingFlowCoordinator`, a successful Competition calibration also becomes the active
launch-wide calibration. Aura Punch receives its scaled `BodyMeasurements` from that same object,
and regular Reactive Strike modes derive their profiles from the same conservative bilateral
reach.

When an existing player is selected, the player-sync path applies that player’s persisted
bilateral reach to the shared calibration. A player-identity change clears the prior player’s
launch-local guards before applying the new reach, forcing fresh guard acquisition. When the same
player completes recalibration, the newly captured guards remain paired with the new reach.
Persisted player data never supplies stale guard or world-space poses.

## Failure and cancellation behavior

- Missing authorization, tracking, body frame, or a complete bilateral result produces the
  existing actionable session error and no player update.
- End Training cancels the owned task and removes the calibration cue.
- Early right-hand extension cannot advance the sequence; the user is prompted to return it to
  guard before the right stage.
- `CompetitionStore` saves only a finished, non-stopped session containing a valid bilateral
  result.
- A failed ranked run that detects unsafe guard clearance keeps the existing recalibration route.

## Tests and verification

Add deterministic regression coverage for:

- right-hand samples being rejected before left-hand completion;
- the progression from left guard/measurement to right guard/measurement;
- Competition calibration dispatching to the dedicated calibration workflow rather than the
  target drill workflow;
- atomic shared calibration replacement only after a complete bilateral result;
- persisted Competition reach flowing into both Reactive Strike and Combo profiles;
- Competition calibration also updating the shared launch-wide measurements;
- player handoff clearing the previous player’s launch-local guards while applying the new
  player’s persisted reach.

Run the focused tests during implementation, followed by `make test`, `make build`, and
`make build-device`. Live hand ordering, target placement, and comfort remain Apple Vision Pro
acceptance items because Simulator cannot provide ARKit hand anchors.

## Publishing scope

The implementation and regression tests will be committed on the existing `monday-morning`
branch. After verification, the branch—including its eight commits that are currently ahead of
`origin/monday-morning`—will be pushed to that remote branch. No unrelated files will be staged.

# ShadowBoxMVP - ChatGPT Desktop Implementation Handover

> **HISTORICAL / SUPERSEDED (8 August 2026):** This document records the
> original M1 kickoff and is no longer the product or engineering source of
> truth. Use `README.md`, `SETUP.md`, decisions D-019/D-025/D-026/D-027, and
> the latest `SESSION_LOG.md`. The DOCX companion is historical as well.

**Version:** 1.0
**Prepared:** 7 August 2026
**Starting milestone:** M1 - mixed immersive space, live hand markers, one programmatic mitt

## 1. Purpose

This file is the source of truth for handing the local visionOS repository to ChatGPT Desktop after the hackathon setup is complete. The coding assistant must inspect the installed SDK, implement one small milestone, build, report evidence, and stop. It must not redesign the product or change the beta-locked toolchain.

## 2. How to use this file

1. Keep this file in the repository root.
2. Open the new ChatGPT Desktop app and select **Codex**.
3. Open the local repository and grant only the required folder/developer-tool access.
4. Keep Xcode open for project settings, Simulator, signing and Vision Pro deployment.
5. Paste the kickoff prompt at the end of this file.
6. Review small diffs and build after every coherent slice.
7. Commit manually only after a stable build.
8. End each session by updating `SESSION_LOG.md`.

Fallback: ChatGPT Classic can use **Work with Apps** with Xcode for focused open-file edits. It should not be treated as whole-repository context; the integration includes the last 200 lines of open panes and selected neighboring text.

## 3. Locked environment

| Component | Decision |
|---|---|
| Xcode | 27 beta 4 |
| Base SDK | visionOS 27 |
| Deployment target | visionOS 26.0 provisional; use 27.0 only if organiser hardware/API requires it |
| Language/UI | Swift + SwiftUI |
| Spatial content | RealityKit |
| Tracking | ARKit |
| Reality Composer Pro | 3 beta 4; optional after M1 |
| Blender | 5.2; optional asset creation |
| Apple Immersive Video Utility | Not used by the real-time MVP |
| Keynote | Pitch deck after a stable demo |
| External packages | None without explicit approval |
| Data | Local only |

Do not update the toolchain after the first successful physical-device build.

## 4. Setup exit criteria

- [ ] `xcodebuild -version` reports the intended Xcode 27 beta 4 build.
- [ ] visionOS component and Simulator runtime are installed.
- [ ] The project builds in Simulator.
- [ ] Vision Pro is paired and Developer Mode is enabled.
- [ ] The app installs on the headset.
- [ ] A mixed `ImmersiveSpace` opens with passthrough visible.
- [ ] The repository has a clean baseline commit.
- [ ] `TOOLCHAIN.md`, `SESSION_LOG.md` and this handover exist.

## 5. MVP statement

A 60-second mixed-reality mitt drill recognises jab and cross, gives immediate feedback, pauses safely on tracking loss, and shows a basic round summary.

### User flow

1. Start from a SwiftUI window and confirm the training area is clear.
2. Select orthodox or southpaw manually.
3. Hold guard for two seconds and extend one comfortable straight punch.
4. Enter mixed immersion with passthrough visible.
5. Complete a deterministic jab/cross mitt sequence.
6. Review hit rate, response time and guard-return consistency.

### In scope

- Two floating mitt targets, programmatic first.
- Manual stance mapping.
- Guard and reach calibration.
- Live hand diagnostics and multi-knuckle fist-centre estimation.
- Swept segment-to-sphere hit testing.
- Hit, miss, response time, relative speed and guard-return metrics.
- Safe pause after tracking loss.
- Local debug traces and round results.

### Out of scope

- Full trainer avatar.
- Free sparring or autonomous combat AI.
- Hooks, uppercuts, body shots, footwork or full-body biomechanics.
- Machine learning.
- Cloud backend, accounts, multiplayer or subscriptions.
- Physical bag or real partner interaction.
- Apple Immersive Video.
- Medical or laboratory-grade claims.

## 6. Safety and privacy

- Keep passthrough visible throughout the round.
- Require a clear arm-swing area and hazard check.
- Keep targets mainly in the forward semicircle.
- No running, jumping, spinning, chasing or rapid backward movement.
- No physical bag or real partner while wearing the headset.
- Pause/neutralise after sustained tracking loss.
- Provide an obvious Stop/Exit path.
- State that the app and headset are not protective equipment.
- Use processed ARKit data; do not request raw camera access.
- Store traces locally and only when debug recording is enabled.
- Do not upload participant traces or room data.
- Use relative performance labels, not clinical claims.

## 7. Architecture

```text
ARKitSession + HandTrackingProvider
                |
                v
       HandTrackingService
                |
        AsyncStream<HandSample>
                |
                v
          PunchDetector
                |
            PunchEvent
                |
                v
         TargetEvaluator
                |
                v
           RoundEngine
        /               \
RealityKit feedback   SwiftUI results
```

Rules:

- ARKit types stop at `HandTrackingService`.
- RealityKit visuals are not scoring truth.
- Use mathematical swept hit testing between consecutive samples.
- Use monotonic timing.
- Do not block rendering with filtering/scoring.
- Honour Swift concurrency diagnostics.
- Verify every beta API against the installed SDK before implementation.

Suggested repository structure:

```text
ShadowBoxMVP/
├── App/
├── UI/
├── Spatial/
├── Tracking/
├── Boxing/
└── ShadowBoxMVPTests/
```

## 8. Milestones

| ID | Milestone | Exit evidence |
|---|---|---|
| M0 | Toolchain health | Blank app builds and installs; mixed space opens |
| M1 | Tracking visibility | One mitt plus live hand markers; loss is visible |
| M2 | Fist centre/replay | Stable fist centre and optional local trace replay |
| M3 | Calibration | Stance, guard and reach-derived target placement |
| M4 | One hittable target | Swept hit test and one-event-per-punch behaviour |
| M5 | Jab/cross round | Deterministic sequence, timing and safe pause |
| M6 | Results/resilience | Summary, graceful errors and exit flow |
| M7 | Visual polish | Authored mitt, audio and pitch-ready demo |

## 9. First assignment: M1 only

The assistant should:

- Inspect the project, SDK, scheme and immersive template.
- Add/confirm a minimal Start view and mixed `ImmersiveSpace`.
- Add the required hand-tracking privacy description.
- Create a tracking service using actual installed SDK symbols.
- Render a small, documented set of hand-joint markers on physical Vision Pro.
- Create one programmatic prototype mitt.
- Handle Simulator/no-tracking states without crashing.
- Build and report exact evidence.

M1 is done when the repository builds, the mixed space works, one mitt appears, live markers update on-device, tracking loss is safe, and no scoring/avatar/package has been added.

Stop after M1 until the physical headset behaviour has been observed.

## 10. AI operating contract

- Inspect this file, `TOOLCHAIN.md`, git status and project settings before editing.
- Use the installed SDK and verify beta API signatures locally.
- Make small, reversible diffs.
- Add no dependency, backend or network permission without approval.
- Build for evidence; never claim a physical-device test that did not occur.
- Preserve safety rules and MVP scope.
- Do not commit automatically.
- End with changed files, validation, untested steps, known issues and one next task.

## 11. Baseline commands

```bash
pwd
git status --short
xcodebuild -version
xcodebuild -list -project ShadowBoxMVP.xcodeproj
xcodebuild -showdestinations \
  -project ShadowBoxMVP.xcodeproj \
  -scheme ShadowBoxMVP

# Use a destination that the command above actually returned:
xcodebuild \
  -project ShadowBoxMVP.xcodeproj \
  -scheme ShadowBoxMVP \
  -destination 'id=<DESTINATION_ID>' \
  build
```

Use `-workspace` instead of `-project` if the repository uses a workspace. Do not hard-code a Simulator name until the installed runtime reports it.

## 12. Required project records

### TOOLCHAIN.md

```text
Xcode: 27 beta 4
Xcode build: <xcodebuild -version>
Swift: <swift --version>
Base SDK: visionOS 27
Deployment target: visionOS 26.0 or 27.0
macOS: <sw_vers -productVersion>
Vision Pro OS: <exact organiser device version>
Reality Composer Pro: 3 beta 4
Blender: 5.2
Last verified physical-device build: <date / commit / tester>
```

### SESSION_LOG.md

```text
## Session <date / initials / commit>
Goal:
Environment:
Changes:
Validation command/result:
Simulator observations:
Physical-device observations:
Known issues/unverified:
Next smallest task:
```

## 13. Kickoff prompt

```text
You are taking over implementation of ShadowBoxMVP, a visionOS mixed-reality boxing training MVP.

Open and read these repository files first:
- ShadowBox_MVP_Handover.md
- TOOLCHAIN.md
- DECISIONS.md, if present
- SESSION_LOG.md, if present

Treat the handover as the product and engineering source of truth. The environment is beta-locked to Xcode 27 beta 4 and the installed visionOS SDK. Do not update the toolchain, deployment target, project format, packages or dependencies unless a documented blocker requires my approval.

Before editing:
1. Inspect the repository, git status, project/scheme names and current build settings.
2. Run and report xcodebuild -version.
3. Show available destinations or otherwise identify a safe Simulator build destination.
4. Summarise what already exists and identify the smallest change set for milestone M1.
5. Verify every ARKit/RealityKit API against the installed SDK; do not rely on remembered beta symbols.

Then implement only M1:
- minimal Start view and mixed ImmersiveSpace
- required hand-tracking privacy description
- live hand-joint diagnostic markers with explicit unsupported/authorisation/error handling
- one programmatic prototype mitt in front of the user
- graceful Simulator behaviour when live hand tracking is unavailable

Constraints:
- no punch recognition or scoring
- no full trainer avatar
- no external packages
- no networking or cloud storage
- no Reality Composer Pro dependency for M1
- keep ARKit code isolated from future boxing logic
- preserve Swift concurrency correctness
- do not commit

Validation:
- build the selected scheme using the installed Xcode
- report the exact command, destination and outcome
- distinguish Simulator validation from physical Vision Pro validation

Deliver at the end:
- concise implementation summary
- changed files
- build/test evidence
- physical-device steps I must perform
- known issues or SDK uncertainties
- the single next recommended task, then stop.
```

## 14. End-of-session prompt

```text
Prepare an end-of-session handover for ShadowBoxMVP.

Report:
1. What changed and why.
2. Exact files changed.
3. Build/test commands and outcomes.
4. What was tested in Simulator versus physical Vision Pro.
5. Known bugs, warnings and SDK uncertainties.
6. Any temporary code or debug flags that remain.
7. The current milestone status against its definition of done.
8. The single next smallest task.

Update SESSION_LOG.md with this evidence. Update DECISIONS.md or ShadowBox_MVP_Handover.md only when an actual source-of-truth decision changed. Do not commit unless I explicitly ask.
```

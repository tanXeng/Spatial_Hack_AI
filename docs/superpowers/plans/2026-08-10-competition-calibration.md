# Competition Calibration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Competition use the same strictly left-then-right reach calibration as standalone training, then propagate the completed result to the player and the shared launch-wide calibration.

**Architecture:** Add a small pure ordered-calibration state type, then make both calibration entry points delegate to one `ReactiveStrikeSession` loop that measures only the active hand. Keep `BodyCalibration` as the atomic launch-wide source of truth, persist its completed bilateral reach through `CompetitionStore`, and clear launch-local guards when player identity changes.

**Tech Stack:** Swift 5 language mode with Swift 6.4 compiler, SwiftUI Observation, RealityKit, visionOS 27, XCTest, Xcode synchronized groups.

## Global Constraints

- Use native visionOS ARKit/RealityKit and the existing head-derived body frame; do not introduce fixed world-axis calibration.
- Capture a stable bilateral guard, then measure left reach before right reach.
- Require three fresh in-guard samples before accepting an arm's extension samples.
- Give standalone calibration a 14-second settled-hold window per hand; Competition calibration remains user-paced and cancellable.
- Publish calibration atomically only after both plausible reaches complete.
- Persist bilateral reach, but keep guard positions current-launch only.
- Use the shorter of the two valid reaches for both Competition target profiles.
- Preserve unrelated committed work on `monday-morning` and stage only files named by each task.
- Treat live hand ordering, placement, comfort, and tracking recovery as Apple Vision Pro acceptance items.

## File map

- Create `BoxingCoach/Models/OrderedReachCalibration.swift`: pure left-then-right state and completion rules.
- Create `BoxingCoachTests/OrderedReachCalibrationTests.swift`: deterministic order and completion tests.
- Modify `BoxingCoach/ReactiveStrikeSession.swift`: shared calibration entry points, ordered live sampling, atomic store, and propagation.
- Modify `BoxingCoach/UI/Flow/TrainingFlowCoordinator.swift`: dispatch Competition calibration to the dedicated calibration entry point.
- Modify `BoxingCoach/UI/Flow/BoxingCoachRootView.swift`: clear launch-local guards on player identity changes.
- Modify `BoxingCoachTests/TrainingFlowCoordinatorTests.swift`: regression test for Competition workflow dispatch and atomic replacement.
- Modify `BoxingCoachTests/CompetitionDomainTests.swift`: regression tests for both Competition modes and player handoff.
- Modify `README.md`: document the ordered workflow and shared Competition result.

---

### Task 1: Ordered bilateral calibration state

**Files:**
- Create: `BoxingCoach/Models/OrderedReachCalibration.swift`
- Create: `BoxingCoachTests/OrderedReachCalibrationTests.swift`

**Interfaces:**
- Consumes: `BodySide` and `ReachCalibration.plausibleForwardRange`.
- Produces: `OrderedReachCalibration`, `OrderedReachCalibration.Stage`, `activeSide`, `confirmGuard(for:)`, `acceptSettledReach(_:for:)`, and `completedReaches`.

- [ ] **Step 1: Write the failing order test**

Create `BoxingCoachTests/OrderedReachCalibrationTests.swift`:

```swift
import XCTest
@testable import BoxingCoach

final class OrderedReachCalibrationTests: XCTestCase {
    func testRequiresLeftGuardAndReachBeforeRightCanAdvance() {
        var sequence = OrderedReachCalibration()

        XCTAssertEqual(sequence.stage, .awaitingGuard(.left))
        XCTAssertEqual(sequence.activeSide, .left)
        XCTAssertFalse(sequence.confirmGuard(for: .right))
        XCTAssertFalse(sequence.acceptSettledReach(0.68, for: .right))

        XCTAssertTrue(sequence.confirmGuard(for: .left))
        XCTAssertEqual(sequence.stage, .measuring(.left))
        XCTAssertFalse(sequence.acceptSettledReach(0.68, for: .right))
        XCTAssertNil(sequence.completedReaches)

        XCTAssertTrue(sequence.acceptSettledReach(0.64, for: .left))
        XCTAssertEqual(sequence.stage, .awaitingGuard(.right))
        XCTAssertEqual(sequence.activeSide, .right)
    }

    func testCompletesOnlyAfterAValidRightReach() throws {
        var sequence = OrderedReachCalibration()
        XCTAssertTrue(sequence.confirmGuard(for: .left))
        XCTAssertTrue(sequence.acceptSettledReach(0.64, for: .left))
        XCTAssertTrue(sequence.confirmGuard(for: .right))

        XCTAssertFalse(sequence.acceptSettledReach(.infinity, for: .right))
        XCTAssertNil(sequence.completedReaches)
        XCTAssertTrue(sequence.acceptSettledReach(0.69, for: .right))

        let reaches = try XCTUnwrap(sequence.completedReaches)
        XCTAssertEqual(reaches[.left], 0.64)
        XCTAssertEqual(reaches[.right], 0.69)
        XCTAssertEqual(sequence.stage, .complete)
        XCTAssertNil(sequence.activeSide)
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild -project BoxingCoach.xcodeproj -scheme BoxingCoach -configuration Debug \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=27.0' \
  -derivedDataPath /private/tmp/BoxingCoachDerivedData/ordered-calibration \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:BoxingCoachTests/OrderedReachCalibrationTests test
```

Expected: compilation fails because `OrderedReachCalibration` does not exist.

- [ ] **Step 3: Implement the minimal pure state type**

Create `BoxingCoach/Models/OrderedReachCalibration.swift`:

```swift
import Foundation

nonisolated struct OrderedReachCalibration: Sendable {
    enum Stage: Equatable, Sendable {
        case awaitingGuard(BodySide)
        case measuring(BodySide)
        case complete
    }

    private(set) var stage: Stage = .awaitingGuard(.left)
    private(set) var reaches: [BodySide: Float] = [:]

    var activeSide: BodySide? {
        switch stage {
        case .awaitingGuard(let side), .measuring(let side): return side
        case .complete: return nil
        }
    }

    var completedReaches: [BodySide: Float]? {
        guard stage == .complete,
              ReachCalibration.conservativeBilateralReach(reaches) != nil
        else { return nil }
        return reaches
    }

    @discardableResult
    mutating func confirmGuard(for side: BodySide) -> Bool {
        guard case .awaitingGuard(let expected) = stage, expected == side else { return false }
        stage = .measuring(side)
        return true
    }

    @discardableResult
    mutating func acceptSettledReach(_ reach: Float, for side: BodySide) -> Bool {
        guard case .measuring(let expected) = stage,
              expected == side,
              ReachCalibration.plausibleForwardRange.contains(reach)
        else { return false }

        reaches[side] = reach
        stage = side == .left ? .awaitingGuard(.right) : .complete
        return true
    }
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Step 2 command again.

Expected: `OrderedReachCalibrationTests` passes with zero failures.

- [ ] **Step 5: Commit the ordered state**

```bash
git add BoxingCoach/Models/OrderedReachCalibration.swift BoxingCoachTests/OrderedReachCalibrationTests.swift
git diff --cached --check
git commit -m "Enforce ordered bilateral calibration"
```

---

### Task 2: Shared standalone and Competition calibration engine

**Files:**
- Modify: `BoxingCoach/ReactiveStrikeSession.swift:79-168,228-275,345-621`
- Modify: `BoxingCoach/UI/Flow/TrainingFlowCoordinator.swift:276-289`
- Modify: `BoxingCoachTests/TrainingFlowCoordinatorTests.swift:22-226`

**Interfaces:**
- Consumes: `OrderedReachCalibration` from Task 1 and the existing `BodyCalibration.store(reaches:guardPositionsBody:)`.
- Produces: `ReactiveStrikeSession.startCompetitionCalibration()`, the shared private `startCalibration(capturingCompetitionEvidence:)`, `waitForCalibrationGuard(for:guardPosition:)`, and `measureSettledReach(for:guardPosition:)`.

- [ ] **Step 1: Write the failing Competition dispatch test**

Add this test to `TrainingFlowCoordinatorTests`:

```swift
func testCompetitionCalibrationUsesDedicatedAtomicCalibrationWorkflow() async {
    let calibration = BodyCalibration.calibratedFixture
    let session = ReactiveStrikeSession(calibration: calibration)
    let flow = TrainingFlowCoordinator(calibration: calibration)
    let selection = TrainingSelection.competitionCalibration(playerID: UUID())
    flow.navigate(to: .experience(selection))
    flow.immersiveSceneDidBecomeReady(session: session)
    var openCallCount = 0
    var hideCallCount = 0

    await flow.startExperience(
        selection,
        session: session,
        supportsMultipleScenes: true,
        openImmersive: { _ in
            openCallCount += 1
            return .opened
        },
        dismissImmersive: {},
        hideControlWindow: { hideCallCount += 1 }
    )

    XCTAssertEqual(openCallCount, 0)
    XCTAssertEqual(hideCallCount, 1)
    XCTAssertEqual(session.phase, .calibrating)
    XCTAssertTrue(calibration.isCalibrated, "A replacement must not erase the last complete result before both arms succeed")
    session.stopDrill()
}
```

- [ ] **Step 2: Run the coordinator test and verify RED**

Run:

```bash
xcodebuild -project BoxingCoach.xcodeproj -scheme BoxingCoach -configuration Debug \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=27.0' \
  -derivedDataPath /private/tmp/BoxingCoachDerivedData/coordinator-calibration \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:BoxingCoachTests/TrainingFlowCoordinatorTests/testCompetitionCalibrationUsesDedicatedAtomicCalibrationWorkflow test
```

Expected: the assertion that `calibration.isCalibrated` is true fails because the current Competition configuration invalidates it before starting the wrong drill loop.

- [ ] **Step 3: Replace the split calibration launch APIs with one shared starter**

In `ReactiveStrikeSession`, remove `calibrationOnly`, `configureCompetitionCalibration()`, both `configureReachCalibration` overloads, the `calibrationOnly` branch in `runDrillLoop()`, and its reset assignments. Replace the current public calibration starter with:

```swift
func startCalibration() {
    startCalibration(capturingCompetitionEvidence: false)
}

func startCompetitionCalibration() {
    startCalibration(capturingCompetitionEvidence: true)
}

private func startCalibration(capturingCompetitionEvidence: Bool) {
    guard phase != .running, phase != .calibrating else { return }

    configure(mode: .air, combination: nil, stance: stance)
    self.capturesCompetitionEvidence = capturingCompetitionEvidence
    config.targetCount = CompetitionMode.reactiveStrike.totalSteps
    config.hitRadius = CompetitionScorer.targetRadius
    competitionSteps.removeAll(keepingCapacity: true)
    competitionTrackingStatus = .complete
    competitionActiveElapsedTime = nil
    competitionStartedAt = nil
    competitionPausedDuration = 0
    competitionRequiresRecalibration = false
    wasStoppedBeforeCompletion = false
    guardPositionsBody.removeAll()
    metrics.reset()
    phase = .calibrating
    lastFeedback = "Raise both hands into guard"
    errorMessage = nil
    isTrackingPaused = false
    trackingReadyToResume = false
    trackingResumeRequested = false
    coachAudio.play(id: .guardUp)

    drillTask?.cancel()
    drillTask = Task { [weak self] in
        await self?.runCalibrationLoop()
    }
}
```

Do not call `calibration.invalidate()` here. `runCalibrationLoop()` remains the only writer and calls `BodyCalibration.store` only after receiving a complete bilateral dictionary.

- [ ] **Step 4: Dispatch Competition to the shared calibration starter**

Replace the `.competitionCalibration` branch in `TrainingFlowCoordinator.startExperience` with:

```swift
case .competitionCalibration:
    session.startCompetitionCalibration()
```

Leave ranked `.competition` runs on `configureCompetition`, `resetForNewRound`, and `startDrill`.

- [ ] **Step 5: Implement strictly ordered live sampling**

Replace `calibrateReach(using:)` with a loop over `OrderedReachCalibration` and add the two focused helpers:

```swift
private func calibrateReach(
    using guards: [BodySide: SIMD3<Float>]
) async -> [BodySide: Float]? {
    var initialFrame = currentBodyFrame()
    while initialFrame == nil,
          capturesCompetitionEvidence,
          !Task.isCancelled,
          phase == .calibrating {
        try? await Task.sleep(for: .milliseconds(25))
        initialFrame = currentBodyFrame()
    }
    guard let frame = initialFrame else { return nil }

    let cueBodyPosition = SIMD3<Float>(0, 0.02, BodyMeasurements.averageAdult.armReach)
    targets.spawnTarget(
        at: frame.toWorld(cueBodyPosition),
        radius: config.targetRadius * 1.25
    )
    defer { targets.removeActiveTarget() }

    var sequence = OrderedReachCalibration()
    while let side = sequence.activeSide, phase == .calibrating, !Task.isCancelled {
        guard let guardPosition = guards[side] else { return nil }
        if side == .right {
            lastFeedback = "Return your right hand to guard"
        }
        guard await waitForCalibrationGuard(for: side, guardPosition: guardPosition),
              sequence.confirmGuard(for: side)
        else { return nil }

        if side == .left {
            lastFeedback = "Keep a relaxed closed fist, punch out, and hold — left arm first"
            coachAudio.play(id: .calibrateReach)
        } else {
            lastFeedback = "Keep your fist closed, then punch out and hold with your right arm"
            coachAudio.play(id: .extendOtherArm)
        }

        guard let reach = await measureSettledReach(for: side, guardPosition: guardPosition),
              sequence.acceptSettledReach(reach, for: side)
        else { return nil }
    }

    guard let reaches = sequence.completedReaches else { return nil }
    lastFeedback = "Reach calibrated"
    coachAudio.play(id: .reachCalibrated)
    targets.flash(result: .hit)
    try? await Task.sleep(for: .milliseconds(180))
    return reaches
}

private func waitForCalibrationGuard(
    for side: BodySide,
    guardPosition: SIMD3<Float>
) async -> Bool {
    let deadline: Date? = capturesCompetitionEvidence ? nil : Date().addingTimeInterval(5)
    var consecutiveFreshSamples = 0
    var lastTimestamp: TimeInterval?

    while !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true, phase == .calibrating {
        if let frame = currentBodyFrame(),
           let observation = hands.observation(for: side),
           observation.timestamp > (lastTimestamp ?? -.infinity) {
            lastTimestamp = observation.timestamp
            let isAtGuard = CombinationPunchValidator.isRetracted(
                fist: frame.toBody(observation.fistPosition),
                guardPosition: guardPosition,
                radius: CombinationPunchValidator.guardRadius
            )
            consecutiveFreshSamples = isAtGuard ? consecutiveFreshSamples + 1 : 0
            if consecutiveFreshSamples >= 3 { return true }
        }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return false
}

private func measureSettledReach(
    for side: BodySide,
    guardPosition: SIMD3<Float>
) async -> Float? {
    let deadline: Date? = capturesCompetitionEvidence ? nil : Date().addingTimeInterval(14)
    var acceptedSamples: [ReachSample] = []
    var lastAcceptedTimestamp: TimeInterval?
    var lastProcessedTimestamp: TimeInterval?

    while !Task.isCancelled, deadline.map({ Date() < $0 }) ?? true, phase == .calibrating {
        if let frame = currentBodyFrame(),
           let observation = hands.observation(for: side),
           observation.timestamp > (lastProcessedTimestamp ?? -.infinity) {
            lastProcessedTimestamp = observation.timestamp
            let fistBody = frame.toBody(observation.fistPosition)
            if let candidate = ReachCalibration.candidateForwardReach(
                guardPosition: guardPosition,
                fistPosition: fistBody
            ) {
                if let previous = lastAcceptedTimestamp,
                   observation.timestamp - previous > 0.5 {
                    acceptedSamples.removeAll(keepingCapacity: true)
                }
                acceptedSamples.append(ReachSample(forward: candidate, time: observation.timestamp))
                lastAcceptedTimestamp = observation.timestamp
                if let settled = ReachCalibration.settledForwardReach(from: acceptedSamples) {
                    return settled
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(16))
    }

    guard !Task.isCancelled else { return nil }
    return ReachCalibration.robustForwardReach(from: acceptedSamples.map(\.forward))
}
```

- [ ] **Step 6: Run focused calibration tests and verify GREEN**

Run the Task 1 focused command, then the Task 2 Step 2 command.

Expected: both test selections pass with zero failures.

- [ ] **Step 7: Commit the shared engine**

```bash
git add BoxingCoach/ReactiveStrikeSession.swift BoxingCoach/UI/Flow/TrainingFlowCoordinator.swift BoxingCoachTests/TrainingFlowCoordinatorTests.swift
git diff --cached --check
git commit -m "Reuse calibration workflow in competition"
```

---

### Task 3: Competition-wide propagation and participant handoff

**Files:**
- Modify: `BoxingCoach/ReactiveStrikeSession.swift:170-215`
- Modify: `BoxingCoach/UI/Flow/BoxingCoachRootView.swift:122-143,339-342`
- Modify: `BoxingCoachTests/CompetitionDomainTests.swift:4-54`
- Modify: `README.md:76-83`

**Interfaces:**
- Consumes: `BilateralReach.bySide`, shared `BodyCalibration`, and `CompetitionPlayer.id`.
- Produces: `applyPersistedCompetitionReach(_:clearingGuards:)` with a default `false` argument and identity-aware root synchronization.

- [ ] **Step 1: Write failing profile and handoff tests**

Add these tests to `CompetitionDomainTests`:

```swift
@MainActor
func testConfigureCompetitionImmediatelyUsesPassedReachForBothModes() throws {
    let calibration = BodyCalibration.calibratedFixture
    let session = ReactiveStrikeSession(calibration: calibration)
    let reach = try XCTUnwrap(BilateralReach(left: 0.58, right: 0.72))

    session.configureCompetition(mode: .reactiveStrike, stance: .orthodox, reach: reach)
    XCTAssertEqual(session.reachProfile.forwardMax, 0.58, accuracy: 0.0001)
    XCTAssertEqual(calibration.reaches, reach.bySide)

    session.configureCompetition(mode: .combination, stance: .southpaw, reach: reach)
    XCTAssertEqual(session.reachProfile.forwardMax, 0.58, accuracy: 0.0001)
    XCTAssertEqual(calibration.measurements.armReach, 0.58, accuracy: 0.0001)
}

@MainActor
func testPlayerHandoffAppliesReachAndClearsLaunchLocalGuards() throws {
    let calibration = BodyCalibration.calibratedFixture
    let session = ReactiveStrikeSession(calibration: calibration)
    let reach = try XCTUnwrap(BilateralReach(left: 0.61, right: 0.67))
    XCTAssertFalse(calibration.guardPositionsBody.isEmpty)

    session.applyPersistedCompetitionReach(reach, clearingGuards: true)

    XCTAssertEqual(calibration.reaches, reach.bySide)
    XCTAssertTrue(calibration.guardPositionsBody.isEmpty)
    session.configure(mode: .air, combination: nil, stance: .orthodox)
    XCTAssertEqual(session.reachProfile.forwardMax, 0.61, accuracy: 0.0001)
}
```

- [ ] **Step 2: Run the focused domain tests and verify RED**

Run:

```bash
xcodebuild -project BoxingCoach.xcodeproj -scheme BoxingCoach -configuration Debug \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=27.0' \
  -derivedDataPath /private/tmp/BoxingCoachDerivedData/competition-propagation \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:BoxingCoachTests/CompetitionDomainTests/testConfigureCompetitionImmediatelyUsesPassedReachForBothModes \
  -only-testing:BoxingCoachTests/CompetitionDomainTests/testPlayerHandoffAppliesReachAndClearsLaunchLocalGuards test
```

Expected: the first test reports the old calibration's `forwardMax`, and the second test does not compile because `clearingGuards` is not yet accepted.

- [ ] **Step 3: Apply reach before deriving Competition profiles**

At the start of `configureCompetition(mode:stance:reach:)`, store the selected player's reach before calling `configure`:

```swift
let retainedGuards = calibration.guardPositionsBody
calibration.store(reaches: reach.bySide, guardPositionsBody: retainedGuards)
let reactiveMode: ReactiveStrikeMode = mode == .combination ? .combination : .air
configure(
    mode: reactiveMode,
    combination: mode == .combination ? .jabCrossHookCross : nil,
    stance: stance
)
```

Remove the later duplicate `calibration.store` block. This makes `configure` derive `reachProfile` from the passed Competition reach immediately.

- [ ] **Step 4: Make persisted player sync explicitly clear guards on handoff**

Change the session method to:

```swift
func applyPersistedCompetitionReach(
    _ reach: BilateralReach?,
    clearingGuards: Bool = false
) {
    guard phase != .running, phase != .calibrating else { return }
    let retainedGuards: [BodySide: SIMD3<Float>] = clearingGuards
        ? [:]
        : calibration.guardPositionsBody
    if clearingGuards {
        guardPositionsBody.removeAll()
    }
    if let reach {
        calibration.store(reaches: reach.bySide, guardPositionsBody: retainedGuards)
    } else {
        calibration.invalidate()
    }
    reachProfile = reach.map {
        ReachProfile.air.calibrated(measuredForwardReach: $0.conservative)
    } ?? .air
}
```

Update the root view's player change handler and sync helper:

```swift
.onChange(of: competitionStore.currentPlayer) { oldPlayer, newPlayer in
    guard oldPlayer?.id != newPlayer?.id
            || oldPlayer?.reach != newPlayer?.reach
            || oldPlayer?.calibrationVersion != newPlayer?.calibrationVersion
    else { return }
    syncPlayerCalibration(
        newPlayer,
        clearingGuards: oldPlayer?.id != newPlayer?.id
    )
}
```

```swift
private func syncPlayerCalibration(
    _ player: CompetitionPlayer?,
    clearingGuards: Bool = false
) {
    let reach = player?.hasCurrentCalibration == true ? player?.reach : nil
    session.applyPersistedCompetitionReach(reach, clearingGuards: clearingGuards)
}
```

In the startup `.task` call, pass `clearingGuards: true` when applying a restored player to an otherwise uncalibrated session.

- [ ] **Step 5: Document the shared ordered behavior**

Replace the first Reactive Strike calibration paragraph in `README.md` with:

```markdown
Reactive Strike begins by capturing both guard positions, then measures a stable left-arm
extension followed by a stable right-arm extension. Competition uses this exact ordered workflow
instead of a separate calibration path. The completed bilateral result is saved to the player and
also becomes the shared launch-wide calibration used by regular Reactive Strike, Combo, and Aura
Punch. Targets use the shorter comfortable reach so every target remains available to either hand.
Calibration and target placement use the live head-derived body frame rather than world Z or a
fixed room height, so the drill is invariant to where the user stands or faces.
```

- [ ] **Step 6: Run focused propagation tests and verify GREEN**

Run the Task 3 Step 2 command, then:

```bash
xcodebuild -project BoxingCoach.xcodeproj -scheme BoxingCoach -configuration Debug \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=27.0' \
  -derivedDataPath /private/tmp/BoxingCoachDerivedData/competition-persistence \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:BoxingCoachTests/CompetitionPersistenceTests \
  -only-testing:BoxingCoachTests/TrainingFlowCoordinatorTests test
```

Expected: all selected domain, persistence, and flow tests pass with zero failures.

- [ ] **Step 7: Commit propagation and documentation**

```bash
git add BoxingCoach/ReactiveStrikeSession.swift BoxingCoach/UI/Flow/BoxingCoachRootView.swift BoxingCoachTests/CompetitionDomainTests.swift README.md
git diff --cached --check
git commit -m "Propagate competition calibration"
```

---

### Task 4: Full verification and branch push

**Files:**
- Verify only; no planned file edits.

**Interfaces:**
- Consumes: completed Tasks 1-3 and the repository Makefile targets.
- Produces: fresh simulator tests, simulator compile, device compile, and updated `origin/monday-morning`.

- [ ] **Step 1: Run the complete unit suite**

```bash
make test
```

Expected: exit code 0 and zero failing tests.

- [ ] **Step 2: Run the simulator build**

```bash
make build
```

Expected: exit code 0 with `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the unsigned device compile**

```bash
make build-device
```

Expected: exit code 0 with `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Audit exact publishing scope**

```bash
git status --short --branch
git diff origin/monday-morning..HEAD --check
git log --oneline --decorate origin/monday-morning..HEAD
```

Expected: a clean worktree, no whitespace errors, and only the reviewed existing commits plus the design, plan, and calibration implementation commits.

- [ ] **Step 5: Push the requested branch**

```bash
git push -u origin monday-morning
```

Expected: exit code 0 and `monday-morning` updated on `origin`.

- [ ] **Step 6: Confirm remote synchronization**

```bash
git status --short --branch
git rev-list --left-right --count origin/monday-morning...monday-morning
```

Expected: the branch reports no ahead/behind count and `0 0`.

- [ ] **Step 7: Record device acceptance limitations in the handoff**

Report that automated checks cover state, persistence, simulator compilation, and device-SDK compilation. Explicitly leave live left-then-right tracking, placement, comfort, occlusion recovery, and perceived punch feel pending an Apple Vision Pro run.

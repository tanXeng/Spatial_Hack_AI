import Foundation
import simd
import SwiftData
import Testing
@testable import BoxingCoach

@Suite("Coaching cycle review regressions round two")
struct CoachingCycleReviewRound2Tests {
    @Test(
        "Reinforcement proof remains attainable at the top of the score scale",
        arguments: [Float(92), 93, 99, 100]
    )
    func strongBaselineCanTerminateHonestly(baseline: Float) throws {
        var cycle = CoachingCycleSession(
            track: .technicalCamp,
            technique: .jab,
            stance: .orthodox
        )
        try advanceToBaseline(&cycle)
        try admitRound(into: &cycle, path: baseline)

        #expect(cycle.correction?.kind == .reinforce)
        #expect(cycle.correctionPlan?.targetImprovement == 0)

        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        try admitRound(into: &cycle, path: baseline)

        #expect(cycle.proofMetric?.delta == 0)
        #expect(cycle.proofDisposition == .reinforced)
        #expect(cycle.proofMeetsTarget)
        #expect(cycle.presentation.instruction == "The selected metric held at its strong baseline.")

        try cycle.continueFromProof()
        #expect(cycle.stage == .transfer)
    }

    @Test("Reinforcement never turns a regression into success")
    func strongBaselineRegressionRetries() throws {
        var cycle = CoachingCycleSession(
            track: .technicalCamp,
            technique: .jab,
            stance: .orthodox
        )
        try advanceToBaseline(&cycle)
        try admitRound(into: &cycle, path: 99)
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        try admitRound(into: &cycle, path: 98)

        #expect(cycle.proofDisposition == .retry)
        #expect(!cycle.proofMeetsTarget)
        #expect(throws: CoachingCycleError.proofThresholdNotMet) {
            try cycle.continueFromProof()
        }
    }

    @Test("Completed result publishes the exact authoritative round and selected proof")
    func resultUsesOnlyAuthoritativeRoundProof() throws {
        var cycle = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try advanceToBaseline(&cycle)
        try admitRound(into: &cycle, path: 60)
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        try admitRound(into: &cycle, path: 68)
        try cycle.continueFromProof()

        let authoritativeProof = try #require(cycle.proof)
        let selectedProof = try #require(cycle.proofMetric)
        try cycle.completeTransfer(at: Date(timeIntervalSince1970: 100))
        let result = try #require(cycle.result)

        #expect(
            result.proof.baseline.attempts.map(\.evidence.identity.id)
                == authoritativeProof.baseline.attempts.map(\.evidence.identity.id)
        )
        #expect(
            result.proof.retest.attempts.map(\.evidence.identity.id)
                == authoritativeProof.retest.attempts.map(\.evidence.identity.id)
        )
        #expect(result.proof.metricDelta(for: selectedProof.kind) == selectedProof.delta)
        #expect(result.selectedProof == selectedProof)
    }

    @Test("Voice pause owns Fit and Transfer through response completion and fresh guard")
    func voicePauseFreezesEveryCycleStage() throws {
        let captureID = UUID(uuidString: "00000000-0000-0000-0000-00000000A501")!
        var owner = CoachVoiceCyclePauseOwner()
        var fit = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )

        #expect(owner.observe(.captureBegan(captureID)) == .pauseTraining)
        fit.trainingDidPause()
        #expect(throws: CoachingCycleError.trainingPaused) {
            try fit.completeFit(reach: BilateralReach(left: 0.62, right: 0.66)!)
        }
        #expect(fit.stage == .fit)
        #expect(owner.observe(.captureReleased(captureID)) == .holdTraining)
        #expect(owner.observe(.responseCompleted(captureID)) == .beginFreshGuardRecovery)
        #expect(owner.observe(.freshGuardRecovered(captureID)) == .resumeTraining)
        fit.trainingDidResume()
        try fit.completeFit(reach: BilateralReach(left: 0.62, right: 0.66)!)

        var transfer = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try advanceToTransfer(&transfer)
        #expect(owner.observe(.captureBegan(captureID)) == .pauseTraining)
        transfer.trainingDidPause()
        #expect(throws: CoachingCycleError.trainingPaused) {
            try transfer.completeTransfer(at: Date(timeIntervalSince1970: 100))
        }
        #expect(transfer.stage == .transfer)
        #expect(owner.observe(.responseCancelled(captureID)) == .beginFreshGuardRecovery)
        #expect(owner.observe(.freshGuardRecovered(captureID)) == .resumeTraining)
        transfer.trainingDidResume()
        try transfer.completeTransfer(at: Date(timeIntervalSince1970: 100))
        #expect(transfer.stage == .complete)
    }

    @Test("Voice lifecycle rejects stale terminal events and never resumes at capture release")
    func voicePauseOwnerRejectsStaleCallbacks() {
        let current = UUID(uuidString: "00000000-0000-0000-0000-00000000A502")!
        let stale = UUID(uuidString: "00000000-0000-0000-0000-00000000A503")!
        var owner = CoachVoiceCyclePauseOwner()

        #expect(owner.observe(.captureBegan(current)) == .pauseTraining)
        #expect(owner.observe(.captureReleased(current)) == .holdTraining)
        #expect(owner.observe(.responseCompleted(stale)) == .ignore)
        #expect(owner.isTrainingPaused)
        #expect(owner.observe(.freshGuardRecovered(current)) == .ignore)
        #expect(owner.observe(.responseCompleted(current)) == .beginFreshGuardRecovery)
        #expect(owner.observe(.freshGuardRecovered(current)) == .resumeTraining)
        #expect(!owner.isTrainingPaused)
    }

    @Test("Closing training abandons voice pause ownership before the next cycle")
    func voicePauseOwnerCanBeResetAfterShutdown() {
        let abandoned = UUID(uuidString: "00000000-0000-0000-0000-00000000A504")!
        let next = UUID(uuidString: "00000000-0000-0000-0000-00000000A505")!
        var owner = CoachVoiceCyclePauseOwner()

        #expect(owner.observe(.captureBegan(abandoned)) == .pauseTraining)
        #expect(owner.observe(.responseCancelled(abandoned)) == .beginFreshGuardRecovery)
        #expect(owner.isTrainingPaused)

        owner.reset()

        #expect(!owner.isTrainingPaused)
        #expect(owner.observe(.captureBegan(next)) == .pauseTraining)
    }

    @Test("Aura guard recovery resets on provider generation and continuity epoch")
    func recoveryBindsConsecutiveSamplesToTrackingIdentity() {
        var gate = AuraGuardRecoveryGate()

        let first = gate.observe(recoverySample(generation: 4, epoch: 7, time: 1))
        let second = gate.observe(recoverySample(generation: 4, epoch: 7, time: 2))
        let third = gate.observe(recoverySample(generation: 4, epoch: 7, time: 3))
        #expect(!first)
        #expect(!second)
        #expect(third)

        let changedGeneration = gate.observe(recoverySample(generation: 5, epoch: 7, time: 4))
        #expect(!changedGeneration)
        #expect(gate.consecutiveStableSamples == 1)
        let changedEpoch = gate.observe(recoverySample(generation: 5, epoch: 8, time: 5))
        #expect(!changedEpoch)
        #expect(gate.consecutiveStableSamples == 1)
        let duplicate = gate.observe(recoverySample(generation: 5, epoch: 8, time: 5))
        #expect(!duplicate)
        #expect(gate.consecutiveStableSamples == 1)
        let next = gate.observe(recoverySample(generation: 5, epoch: 8, time: 6))
        let final = gate.observe(recoverySample(generation: 5, epoch: 8, time: 7))
        #expect(!next)
        #expect(final)
    }

    @Test("Ask Coach supports quick tap toggle and hold without double activation")
    func pushToTalkInteractionIsAccessibleAndDeterministic() {
        var policy = CoachPushToTalkInteractionPolicy()

        policy.pointerDidBegin()
        #expect(policy.accessibilityActivate(isVoiceActive: false) == .beginCapture)
        #expect(policy.pointerDidEnd(isVoiceActive: true) == .none)

        policy.pointerDidBegin()
        #expect(policy.accessibilityActivate(isVoiceActive: true) == .endCapture)
        #expect(policy.pointerDidEnd(isVoiceActive: false) == .none)

        policy.pointerDidBegin()
        #expect(policy.holdThresholdDidElapse(isVoiceActive: false) == .beginCapture)
        #expect(policy.accessibilityActivate(isVoiceActive: true) == .none)
        #expect(policy.pointerDidEnd(isVoiceActive: true) == .endCapture)
        #expect(policy.accessibilityActivate(isVoiceActive: false) == .none)
    }

    @Test("An unscorable attempt explicitly destroys its partial reducer evidence")
    func scorerNilClearsPartialAttempt() throws {
        var cycle = CoachingCycleSession(
            track: .firstRound,
            technique: .jab,
            stance: .orthodox
        )
        try advanceToBaseline(&cycle)
        cycle.beginPartialAttempt()
        #expect(cycle.hasPartialAttempt)

        AuraScoringAdmissionPolicy.scorerRejectedAttempt(cycle: &cycle)

        #expect(!cycle.hasPartialAttempt)
        #expect(cycle.baselineAttempts.isEmpty)
        #expect(cycle.stage == .baseline)
    }

    @Test(
        "Short and long fitted reach personalize both hero punch paths within measured reach",
        arguments: [Technique.jab, .uppercut]
    )
    func fittedReachChangesPathAndLanding(technique: Technique) {
        let measurements = BodyMeasurements.averageAdult
        let shortReach: Float = 0.48
        let longReach: Float = 0.72
        let short = ReferencePunchLibrary.punch(
            for: technique,
            stance: .orthodox,
            measurements: measurements,
            conservativeReach: shortReach
        )
        let long = ReferencePunchLibrary.punch(
            for: technique,
            stance: .orthodox,
            measurements: measurements,
            conservativeReach: longReach
        )

        #expect(short.samples.map(\.fist) != long.samples.map(\.fist))
        #expect(short.sample(at: short.peakTime)?.fist != long.sample(at: long.peakTime)?.fist)
        #expect((short.samples.map(\.reachFraction).max() ?? .infinity) * measurements.armReach <= shortReach + 1e-5)
        #expect((long.samples.map(\.reachFraction).max() ?? .infinity) * measurements.armReach <= longReach + 1e-5)
    }

    @Test("Uppercut extension overlay uses the same ordered rise selected by the scorer")
    func uppercutExtensionGeometryMatchesScorer() throws {
        let actual = uppercutSamples(lowY: -0.20, highY: 0.46, trackedHigh: false)
        let reference = uppercutSamples(lowY: -0.28, highY: 0.62, trackedHigh: true)
        let attempt = RecordedAttempt(samples: actual, trackedFraction: 0.875, duration: 0.7)
        let referencePunch = ReferencePunch(
            techniqueID: Technique.uppercut.id,
            side: .left,
            samples: reference
        )
        let score = try #require(TechniqueScorer().score(
            attempt: attempt,
            reference: referencePunch,
            technique: .uppercut,
            thrownSide: .left,
            stance: .orthodox
        ))
        let geometry = try #require(CorrectionOverlayGeometry.selection(
            focus: .extensionReach,
            actual: actual,
            reference: reference,
            techniqueID: Technique.uppercut.id
        ))

        let expectedShortfall = max(
            0,
            PunchExtensionSemantics.magnitude(samples: reference, techniqueID: Technique.uppercut.id)
                - PunchExtensionSemantics.magnitude(samples: actual, techniqueID: Technique.uppercut.id)
        )
        #expect(score.metric(.extensionReach)?.measured == expectedShortfall)
        #expect(geometry.actual.map(\.position) == [actual[1].fist, actual[6].fist])
        #expect(geometry.reference.map(\.position) == [reference[1].fist, reference[6].fist])
        #expect(geometry.actual.map(\.provenance) == [.measured, .interpolated])
    }

    @Test("Retraction overlay uses the exact final guard error scored")
    func retractionGeometryMatchesScorer() throws {
        let reference = jabSamples(final: SIMD3(0, 0.18, 0.30))
        let actual = jabSamples(final: SIMD3(0.15, 0.25, 0.42))
        let attempt = RecordedAttempt(samples: actual, trackedFraction: 1, duration: 0.7)
        let referencePunch = ReferencePunch(
            techniqueID: Technique.jab.id,
            side: .left,
            samples: reference
        )
        let score = try #require(TechniqueScorer().score(
            attempt: attempt,
            reference: referencePunch,
            technique: .jab,
            thrownSide: .left,
            stance: .orthodox
        ))
        let geometry = try #require(CorrectionOverlayGeometry.selection(
            focus: .retraction,
            actual: actual,
            reference: reference,
            techniqueID: Technique.jab.id
        ))

        #expect(score.metric(.retraction)?.measured == simd_distance(actual.last!.fist, reference.last!.fist))
        #expect(geometry.actual.map(\.position) == [actual.last!.fist])
        #expect(geometry.reference.map(\.position) == [reference.last!.fist])
        #expect(geometry.actual.map(\.provenance) == [.measured])
        #expect(geometry.reference.map(\.provenance) == [.estimated])
    }

    @Test("One idempotent athlete-memory transaction reconstructs all six proof attempts")
    @MainActor
    func coachingCyclePersistenceIsReconstructableAndIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CoachingCyclePersistence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("athlete-memory.store")
        let expected: (
            player: CompetitionPlayer,
            result: CoachingCycleResult,
            reach: BilateralReach
        )

        do {
            let container = try CompetitionModelContainer.make(storeURL: storeURL)
            let repository = SwiftDataCompetitionRepository(container: container)
            let store = CompetitionStore(repository: repository, now: {
                Date(timeIntervalSince1970: 200)
            })
            await store.join(name: "Ada")
            let player = try #require(store.currentPlayer)
            var cycle = CoachingCycleSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000C601")!,
                track: .technicalCamp,
                technique: .uppercut,
                stance: .southpaw
            )
            try advanceToBaseline(&cycle)
            try admitRound(into: &cycle, path: 58)
            try cycle.beginCorrectiveDrill()
            try cycle.completeCorrectiveDrill()
            try admitRound(into: &cycle, path: 68)
            try cycle.continueFromProof()
            try cycle.completeTransfer(at: Date(timeIntervalSince1970: 190))
            let result = try #require(cycle.result)
            let reach = try #require(cycle.fittedReach)

            try await store.persistCoachingCycle(result, fittedReach: reach)
            try await store.persistCoachingCycle(result, fittedReach: reach)
            expected = (player, result, reach)
        }

        let relaunchedContainer = try CompetitionModelContainer.make(storeURL: storeURL)
        let relaunched = SwiftDataCompetitionRepository(container: relaunchedContainer)
        let saved = try #require(try await relaunched.coachingCycle(id: expected.result.id))
        #expect(saved.id == expected.result.id)
        #expect(saved.athleteID == expected.player.id)
        #expect(saved.trackID == TrainingTrack.technicalCamp.id)
        #expect(saved.techniqueID == Technique.uppercut.id)
        #expect(saved.stance == .southpaw)
        #expect(saved.fittedReach == expected.reach)
        #expect(saved.attempts.count == 6)
        #expect(saved.attempts.map(\.stage) == [
            .baseline, .baseline, .baseline, .retest, .retest, .retest,
        ])
        #expect(saved.attempts.map(\.ordinal) == [1, 2, 3, 1, 2, 3])
        #expect(saved.attempts.allSatisfy {
            $0.cycleID == expected.result.id
                && $0.stance == .southpaw
                && $0.referenceVersion == 1
                && $0.scoringVersion == 1
                && $0.calibrationVersion == 1
                && $0.metrics.contains {
                    $0.kind == .path && $0.quality == .measured
                }
                && $0.metrics.contains {
                    $0.kind == .elbow && $0.quality == .inferred
                }
        })
        #expect(saved.baselineAttemptIDs == Array(saved.attempts.prefix(3).map(\.id)))
        #expect(saved.retestAttemptIDs == Array(saved.attempts.suffix(3).map(\.id)))
        #expect(saved.attempts.prefix(3).map(\.proofPeerAttemptID)
                == saved.attempts.suffix(3).map(\.id))
        #expect(saved.selectedFocus == expected.result.selectedProof.kind)
        #expect(saved.selectedBaseline == expected.result.selectedProof.baseline)
        #expect(saved.selectedRetest == expected.result.selectedProof.retest)
        #expect(saved.selectedDelta == expected.result.selectedProof.delta)
        #expect(saved.proofDisposition == expected.result.proofDisposition)
        #expect(saved.correctionCode == expected.result.selectedProof.correctionCode.rawValue)
        #expect(try await relaunched.techniqueAttempts(
            athleteID: expected.player.id,
            techniqueID: Technique.uppercut.id
        ).count == 6)
    }

    @Test("Coaching memory adds schema V3 and migrates an existing V2 store")
    @MainActor
    func coachingCyclePersistenceMigratesV2Store() async throws {
        #expect(CompetitionSchemaV3.versionIdentifier == Schema.Version(3, 0, 0))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CoachingCycleSchemaMigration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("athlete-memory.store")
        let athleteID = UUID(uuidString: "00000000-0000-0000-0000-00000000C602")!

        do {
            let v2Schema = Schema(versionedSchema: CompetitionSchemaV2.self)
            let configuration = ModelConfiguration(
                "CoachingCycleMigrationV2",
                schema: v2Schema,
                url: storeURL,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: v2Schema,
                configurations: [configuration]
            )
            let context = ModelContext(container)
            context.insert(CompetitionSchemaV2.CompetitionPlayerRecord(
                CompetitionPlayer(
                    id: athleteID,
                    name: "Existing Athlete",
                    normalizedName: "existing athlete",
                    rememberedStance: .orthodox,
                    reach: nil,
                    calibrationVersion: nil,
                    calibratedAt: nil,
                    createdAt: Date(timeIntervalSince1970: 1),
                    lastSeenAt: Date(timeIntervalSince1970: 2)
                )
            ))
            try context.save()
        }

        let migratedContainer = try CompetitionModelContainer.make(storeURL: storeURL)
        let migrated = SwiftDataCompetitionRepository(container: migratedContainer)
        #expect(try await migrated.player(id: athleteID)?.name == "Existing Athlete")
        #expect(try await migrated.coachingCycle(id: UUID()) == nil)
    }

    @Test(
        "Live Aura boundary completes, persists, and closes correction and reinforcement cycles",
        arguments: [
            LiveAuraScenario(technique: .jab, baselineNeedsCorrection: true),
            LiveAuraScenario(technique: .uppercut, baselineNeedsCorrection: true),
            LiveAuraScenario(technique: .jab, baselineNeedsCorrection: false),
        ]
    )
    @MainActor
    func liveAuraBoundaryCompletesAndPersists(scenario: LiveAuraScenario) async throws {
        let technique = scenario.technique
        let container = try CompetitionModelContainer.make(inMemory: true)
        let repository = SwiftDataCompetitionRepository(container: container)
        let store = CompetitionStore(repository: repository)
        if scenario.baselineNeedsCorrection {
            await store.join(name: "Live Aura")
        }

        let tracking = LiveAuraTrackingHarness()
        let clock = LiveAuraClockHarness(tracking: tracking)
        let audio = LiveAuraAudioHarness()
        let captures = LiveAuraCaptureHarness(
            cycleTechnique: technique,
            baselineNeedsCorrection: scenario.baselineNeedsCorrection
        )
        let aura = AuraPunchSession(
            hands: tracking,
            feedbackGenerator: MockFeedbackGenerator(),
            audienceTrack: .beginner,
            coachAudio: audio,
            clock: clock,
            captureOverride: { request in
                captures.capture(request)
            }
        )
        aura.technique = technique
        aura.stance = .orthodox
        aura.track = .firstRound
        aura.persistedReach = BilateralReach(left: 0.56, right: 0.68)!
        aura.followHoldTimeout = 0

        let interruptions = LiveAuraInterruptionHarness(
            session: aura,
            tracking: tracking
        )
        var visibleProofDetails: [String] = []
        clock.onSleep = {
            interruptions.clockDidSleep()
            if aura.learningStage == .proof {
                visibleProofDetails.append(aura.coachingDetail)
            }
        }

        var completionCount = 0
        aura.cycleDidComplete = { result, reach in
            completionCount += 1
            try await store.persistStandaloneCoachingCycle(result, fittedReach: reach)
        }

        aura.start()
        for _ in 0..<20_000 where aura.phase != .results && aura.errorMessage == nil {
            await Task.yield()
        }

        #expect(aura.errorMessage == nil)
        #expect(aura.phase == .results)
        #expect(aura.learningStage == .complete)
        #expect(completionCount == 1)
        #expect(interruptions.fitVoicePauseCompleted)
        #expect(interruptions.transferVoicePauseCompleted)
        #expect(interruptions.learningTrackingRecoveryCompleted)
        #expect(interruptions.drillTrackingRecoveryCompleted)
        #expect(!audio.played.contains(.calibrateReach))
        #expect(aura.coachingDetail == "Your proof is saved locally")

        let result = try #require(aura.cycleResult)
        let player = try #require(store.currentPlayer)
        let saved = try #require(try await repository.coachingCycle(id: result.id))
        #expect(saved.athleteID == player.id)
        #expect(saved.techniqueID == technique.id)
        #expect(saved.attempts.count == 6)
        if scenario.baselineNeedsCorrection {
            #expect(saved.selectedDelta > 0)
            #expect(saved.proofDisposition == .improved)
        } else {
            #expect(saved.selectedDelta == 0)
            #expect(saved.proofDisposition == .reinforced)
            let proofDetail = try #require(visibleProofDetails.last)
            #expect(proofDetail.localizedCaseInsensitiveContains("held"))
            #expect(!proofDetail.localizedCaseInsensitiveContains("improved"))
            let instruction = AuraImmersiveInstructionPolicy.instruction(
                phase: .scoring,
                coachingHeadline: "PROOF",
                coachingDetail: proofDetail,
                cyclePresentation: aura.cyclePresentation,
                trackingPaused: false,
                trainingPaused: false,
                statusMessage: proofDetail
            )
            #expect(instruction.accessibilityValue.localizedCaseInsensitiveContains("held"))
            #expect(!instruction.accessibilityValue.localizedCaseInsensitiveContains("improved"))
        }
        #expect(captures.scoredCaptureCount == 6)
        #expect(captures.transferCaptureCount == 2)

        aura.reset()
        #expect(aura.phase == .idle)
        #expect(aura.cycleResult == nil)
        #expect(aura.correctionOverlay == nil)
        #expect(aura.coachingHeadline == "GET READY")
        #expect(aura.coachingDetail == "Raise your guard to begin")
        #expect(aura.currentDemoRep == 0)
        #expect(aura.currentScoredPunch == 0)
        #expect(aura.liveReach == 0)
        #expect(aura.statusMessage == "Ready")
    }

    @Test("Aura cannot publish Results when no persistence transaction is installed")
    @MainActor
    func liveAuraRequiresPersistenceBeforeResults() async {
        let tracking = LiveAuraTrackingHarness()
        let clock = LiveAuraClockHarness(tracking: tracking)
        let captures = LiveAuraCaptureHarness(
            cycleTechnique: .jab,
            baselineNeedsCorrection: false
        )
        let aura = AuraPunchSession(
            hands: tracking,
            feedbackGenerator: MockFeedbackGenerator(),
            audienceTrack: .beginner,
            coachAudio: LiveAuraAudioHarness(),
            clock: clock,
            captureOverride: { request in captures.capture(request) }
        )
        aura.technique = .jab
        aura.stance = .orthodox
        aura.track = .firstRound
        aura.persistedReach = BilateralReach(left: 0.56, right: 0.68)!
        aura.followHoldTimeout = 0
        aura.cycleDidComplete = nil

        aura.start()
        for _ in 0..<20_000 where aura.phase != .results && aura.errorMessage == nil {
            await Task.yield()
        }

        #expect(aura.phase != .results)
        #expect(aura.errorMessage == "Athlete memory is unavailable, so this proof was not saved.")
        #expect(!aura.coachingDetail.localizedCaseInsensitiveContains("saved locally"))
    }

    private func advanceToBaseline(_ cycle: inout CoachingCycleSession) throws {
        try cycle.completeFit(reach: BilateralReach(left: 0.62, right: 0.66)!)
        for _ in 0..<4 { try cycle.completeLearningStep() }
        for _ in 0..<cycle.track.guidedRehearsalCount {
            try cycle.completeGuidedRehearsal()
        }
    }

    private func advanceToTransfer(_ cycle: inout CoachingCycleSession) throws {
        try advanceToBaseline(&cycle)
        try admitRound(into: &cycle, path: 60)
        try cycle.beginCorrectiveDrill()
        try cycle.completeCorrectiveDrill()
        try admitRound(into: &cycle, path: 68)
        try cycle.continueFromProof()
    }

    private func recoverySample(
        generation: UInt64,
        epoch: UInt64,
        time: TimeInterval
    ) -> AuraGuardRecoveryGate.Sample {
        AuraGuardRecoveryGate.Sample(
            providerGeneration: generation,
            continuityEpoch: epoch,
            pairTimestamp: time,
            observationsFresh: true,
            freshClosedAndGuarded: true
        )
    }

    private func uppercutSamples(
        lowY: Float,
        highY: Float,
        trackedHigh: Bool
    ) -> [MotionSample] {
        let y: [Float] = [0.05, lowY, -0.10, 0.02, 0.18, 0.34, highY, 0.20]
        return y.enumerated().map { index, value in
            MotionSample(
                time: TimeInterval(index) * 0.1,
                fist: SIMD3(-0.08, value, 0.45 + Float(index) * 0.01),
                elbow: SIMD3(-0.18, value - 0.12, 0.24),
                guardHand: SIMD3(0.18, 0.18, 0.28),
                isTracked: index == 6 ? trackedHigh : true
            )
        }
    }

    private func jabSamples(final: SIMD3<Float>) -> [MotionSample] {
        let outbound: [SIMD3<Float>] = [
            SIMD3(0, 0.18, 0.30),
            SIMD3(0, 0.17, 0.42),
            SIMD3(0, 0.16, 0.58),
            SIMD3(0, 0.15, 0.78),
            SIMD3(0, 0.15, 0.95),
            SIMD3(0, 0.16, 0.72),
            SIMD3(0, 0.17, 0.48),
            final,
        ]
        return outbound.enumerated().map { index, fist in
            MotionSample(
                time: TimeInterval(index) * 0.1,
                fist: fist,
                elbow: fist * 0.6,
                guardHand: SIMD3(0.18, 0.18, 0.28),
                isTracked: true
            )
        }
    }

    private func admitRound(
        into cycle: inout CoachingCycleSession,
        path: Float
    ) throws {
        for repetition in 1...CoachingCycleSession.requiredAttempts {
            let side = AuraPunchSideSequence.side(
                forRepetition: repetition,
                technique: cycle.technique,
                stance: cycle.stance
            )
            try cycle.admit(makeAttempt(
                path: path,
                technique: cycle.technique,
                stance: cycle.stance,
                side: side
            ))
        }
    }

    private func makeAttempt(
        path: Float,
        technique: Technique,
        stance: Stance,
        side: BodySide
    ) throws -> CoachingAttemptEvidence {
        let punch = try ValidatedPunchEvidence(
            technique: technique,
            stance: stance,
            side: side,
            generation: 7,
            startedAt: 10,
            landedAt: 10.2,
            returnedAt: 10.5,
            outboundTravel: 0.5,
            landingError: 0.03,
            returnError: 0.04,
            trackedFraction: 0.96,
            quality: .measured
        )
        let score = TechniqueScore(
            techniqueID: technique.id,
            overall: path,
            metrics: [
                SubMetric(
                    kind: .path,
                    score: path,
                    measured: 0.08,
                    detail: "Path deviation",
                    quality: .measured
                ),
                SubMetric(
                    kind: .elbow,
                    score: 100,
                    measured: 0,
                    detail: "Estimated elbow alignment",
                    quality: .inferred
                ),
            ],
            trackedFraction: 0.96,
            duration: 0.5
        )
        let evidence = try TechniqueAttemptEvidence(
            punch: punch,
            score: score,
            metricQuality: [.path: .measured, .elbow: .inferred]
        )
        let actual = [
            MotionSample(
                time: 0,
                fist: SIMD3(0, 0, 0.2),
                elbow: SIMD3(0, 0, 0.1),
                guardHand: SIMD3(0, 0.2, 0.1),
                isTracked: true
            ),
            MotionSample(
                time: 0.2,
                fist: SIMD3(0, 0, 0.9),
                elbow: SIMD3(0, 0, 0.5),
                guardHand: SIMD3(0, 0.2, 0.1),
                isTracked: true
            ),
        ]
        return try CoachingAttemptEvidence(
            evidence: evidence,
            actualSamples: actual,
            referenceSamples: actual
        )
    }
}

nonisolated struct LiveAuraScenario: Sendable {
    let technique: Technique
    let baselineNeedsCorrection: Bool
}

@MainActor
private final class LiveAuraTrackingHarness: AuraHandTracking {
    private(set) var providerGeneration: UInt64 = 11
    private(set) var continuityEpoch: UInt64 = 23
    private(set) var statusMessage = "Scripted tracking ready"
    private(set) var deviceTransform: simd_float4x4?
    private(set) var leftHand: HandObservation?
    private(set) var rightHand: HandObservation?
    private var observationsAvailable = true

    var isRunning: Bool { true }
    var hasFullUpperBodyTracking: Bool {
        observationsAvailable && deviceTransform != nil && leftHand != nil && rightHand != nil
    }

    init() {
        var head = matrix_identity_float4x4
        head.columns.3 = SIMD4(0, 1.65, 0, 1)
        deviceTransform = head
        let solver = ArmPoseSolver()
        let frame = solver.bodyFrame(headTransform: head)!
        leftHand = Self.observation(
            side: .left,
            position: frame.toWorld(SIMD3(-0.22, 0.20, 0.25)),
            time: 100
        )
        rightHand = Self.observation(
            side: .right,
            position: frame.toWorld(SIMD3(0.22, 0.20, 0.25)),
            time: 100
        )
    }

    func start() async {}
    func beginAttemptCapture() {}
    func endAttemptCapture() {}

    func observation(for side: BodySide) -> HandObservation? {
        guard observationsAvailable else { return nil }
        return side == .left ? leftHand : rightHand
    }

    func freshObservation(
        for side: BodySide,
        maxAge: TimeInterval
    ) -> HandObservation? {
        observation(for: side)
    }

    func advance(to time: TimeInterval) {
        if !observationsAvailable {
            observationsAvailable = true
        }
        leftHand?.acquisitionTimestamp = time
        leftHand?.receiptTimestamp = time
        leftHand?.deviceTimestamp = time
        rightHand?.acquisitionTimestamp = time
        rightHand?.receiptTimestamp = time
        rightHand?.deviceTimestamp = time
    }

    func interruptContinuityForOneTick() {
        observationsAvailable = false
        continuityEpoch &+= 1
    }

    private static func observation(
        side: BodySide,
        position: SIMD3<Float>,
        time: TimeInterval
    ) -> HandObservation {
        HandObservation(
            side: side,
            wristPosition: position,
            wristOrientation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
            elbowHint: nil,
            fistPosition: position,
            fistState: .closed,
            fistClosureRatio: 1,
            acquisitionTimestamp: time,
            receiptTimestamp: time,
            deviceTransform: matrix_identity_float4x4,
            deviceTimestamp: time
        )
    }
}

@MainActor
private final class LiveAuraClockHarness: AuraSessionClock {
    private(set) var now: TimeInterval = 100
    var onSleep: (() -> Void)?
    private let tracking: LiveAuraTrackingHarness

    init(tracking: LiveAuraTrackingHarness) {
        self.tracking = tracking
    }

    func sleep(for duration: Duration) async {
        let components = duration.components
        now += Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        tracking.advance(to: now)
        onSleep?()
        await Task.yield()
    }
}

@MainActor
private final class LiveAuraAudioHarness: CoachAudioPlaying {
    private(set) var played: [CoachClipID] = []

    func prepare() {}
    func play(id: CoachClipID) { played.append(id) }
    func stop() {}
}

@MainActor
private final class LiveAuraCaptureHarness {
    private let cycleTechnique: Technique
    private let baselineNeedsCorrection: Bool
    private(set) var scoredCaptureCount = 0
    private(set) var transferCaptureCount = 0

    init(cycleTechnique: Technique, baselineNeedsCorrection: Bool) {
        self.cycleTechnique = cycleTechnique
        self.baselineNeedsCorrection = baselineNeedsCorrection
    }

    func capture(_ request: AuraPunchCaptureRequest) -> AuraCapturedPunch? {
        let isScoredCapture = scoredCaptureCount < 6
            && request.technique == cycleTechnique
        let isBaseline = isScoredCapture && scoredCaptureCount < 3
        if isScoredCapture {
            scoredCaptureCount += 1
        } else {
            transferCaptureCount += 1
        }

        var samples = request.reference.samples
        if isBaseline, baselineNeedsCorrection {
            samples = samples.map { sample in
                MotionSample(
                    time: sample.time,
                    fist: sample.fist + SIMD3(0.24, 0, 0),
                    elbow: sample.elbow + SIMD3(0.20, 0, 0),
                    guardHand: sample.guardHand,
                    isTracked: true
                )
            }
        }
        let attempt = RecordedAttempt(
            samples: samples,
            trackedFraction: 1,
            duration: request.reference.duration
        )
        guard let punch = try? ValidatedPunchEvidence(
            technique: request.technique,
            stance: request.stance,
            side: request.side,
            generation: request.providerGeneration,
            startedAt: 100,
            landedAt: 100.2,
            returnedAt: 100.5,
            outboundTravel: 0.5,
            landingError: 0.02,
            returnError: 0.03,
            trackedFraction: 1,
            quality: .measured
        ) else { return nil }
        return AuraCapturedPunch(side: request.side, attempt: attempt, punch: punch)
    }
}

@MainActor
private final class LiveAuraInterruptionHarness {
    private weak var session: AuraPunchSession?
    private let tracking: LiveAuraTrackingHarness
    private let fitCaptureID = UUID(uuidString: "00000000-0000-0000-0000-00000000F801")!
    private let transferCaptureID = UUID(uuidString: "00000000-0000-0000-0000-00000000F802")!
    private var fitPauseStarted = false
    private var fitResponseFinished = false
    private var transferPauseStarted = false
    private var transferResponseFinished = false
    private var learningTrackingInterrupted = false
    private var drillTrackingInterrupted = false

    var fitVoicePauseCompleted: Bool {
        fitResponseFinished && session?.isTrainingPaused == false
    }
    var transferVoicePauseCompleted: Bool {
        transferResponseFinished && session?.isTrainingPaused == false
    }
    var learningTrackingRecoveryCompleted: Bool {
        learningTrackingInterrupted && session?.isTrackingPaused == false
    }
    var drillTrackingRecoveryCompleted: Bool {
        drillTrackingInterrupted && session?.isTrackingPaused == false
    }

    init(session: AuraPunchSession, tracking: LiveAuraTrackingHarness) {
        self.session = session
        self.tracking = tracking
    }

    func clockDidSleep() {
        guard let session else { return }
        if session.learningStage == .fit {
            if !fitPauseStarted {
                fitPauseStarted = true
                session.handleCoachVoiceCycle(.captureBegan(fitCaptureID))
            } else if session.isTrainingPaused, !fitResponseFinished {
                fitResponseFinished = true
                session.handleCoachVoiceCycle(.captureReleased(fitCaptureID))
                session.handleCoachVoiceCycle(.responseCompleted(fitCaptureID))
            }
            return
        }
        if [.learnWatch, .learnOutbound, .learnLanding, .learnReturn, .guidedRehearsal]
            .contains(session.learningStage),
           !session.isTrainingPaused,
           !learningTrackingInterrupted {
            learningTrackingInterrupted = true
            tracking.interruptContinuityForOneTick()
            return
        }
        if session.learningStage == .correctiveDrill,
           !session.isTrainingPaused,
           !drillTrackingInterrupted {
            drillTrackingInterrupted = true
            tracking.interruptContinuityForOneTick()
            return
        }
        if session.learningStage == .transfer {
            if !transferPauseStarted {
                transferPauseStarted = true
                session.handleCoachVoiceCycle(.captureBegan(transferCaptureID))
            } else if session.isTrainingPaused, !transferResponseFinished {
                transferResponseFinished = true
                session.handleCoachVoiceCycle(.captureReleased(transferCaptureID))
                session.handleCoachVoiceCycle(.responseCancelled(transferCaptureID))
            }
        }
    }
}

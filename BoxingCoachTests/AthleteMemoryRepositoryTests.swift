import Foundation
import SwiftData
import Testing
@testable import BoxingCoach

@Suite("Athlete memory repository contract")
@MainActor
struct AthleteMemoryRepositoryTests {
    @Test(
        "Events and duplicate-name participants stay event-scoped",
        arguments: RepositoryBackend.allCases
    )
    func eventAndParticipantContract(_ backend: RepositoryBackend) throws {
        let repository = try makeRepository(backend)
        let event = makeEvent(id: id(1), openedAt: 10)
        let first = makeParticipant(
            id: id(11),
            eventID: event.id,
            name: "Alex",
            code: "0007"
        )
        let second = makeParticipant(
            id: id(12),
            eventID: event.id,
            name: "Alex",
            code: "0008"
        )

        #expect(try repository.activeEvent() == nil)
        #expect(try repository.createEvent(event) == event)
        #expect(try repository.createEvent(event) == event)
        #expect(try repository.saveParticipant(first) == first)
        #expect(try repository.saveParticipant(second) == second)
        #expect(try repository.participant(eventID: event.id, displayCode: "0007") == first)
        #expect(try repository.participants(eventID: event.id).map(\.id) == [first.id, second.id])

        let closed = try repository.closeEvent(id: event.id, at: date(100))
        #expect(closed.status == .closed)
        #expect(try repository.activeEvent() == nil)
        #expect(try repository.archivedEvents() == [closed])
        #expect(throws: AthleteMemoryRepositoryError.eventClosed) {
            _ = try repository.saveParticipant(makeParticipant(
                id: id(13),
                eventID: event.id,
                name: "Blair",
                code: "0009"
            ))
        }
    }

    @Test(
        "Memory rebuilds only from valid version-compatible immutable attempts",
        arguments: RepositoryBackend.allCases
    )
    func rebuildableVersionedSkillMemory(_ backend: RepositoryBackend) throws {
        let repository = try makeRepository(backend)
        let event = makeEvent(id: id(2), openedAt: 10)
        let participant = makeParticipant(
            id: id(20),
            eventID: event.id,
            name: "Casey",
            code: "0020"
        )
        _ = try repository.createEvent(event)
        _ = try repository.saveParticipant(participant)
        let key = makeMemoryKey(eventID: event.id, athleteID: participant.id)
        let cycle1 = id(30)
        let cycle2 = id(31)
        let baseline1 = makeAttempt(
            id: id(41),
            participant: participant,
            cycleID: cycle1,
            stage: .baseline,
            score: 60,
            metrics: [
                makeMetric("path", 50, .measured),
                makeMetric("elbow", nil, .unavailable)
            ],
            correctionCode: "extend-fully",
            completedAt: 20
        )
        let retest1 = makeAttempt(
            id: id(42),
            participant: participant,
            cycleID: cycle1,
            stage: .retest,
            score: 72,
            metrics: [
                makeMetric("path", 72, .inferred),
                makeMetric("elbow", nil, .unavailable)
            ],
            correctionCode: "extend-fully",
            baselineAttemptID: baseline1.id,
            completedAt: 30
        )
        let baseline2 = makeAttempt(
            id: id(43),
            participant: participant,
            cycleID: cycle2,
            stage: .baseline,
            score: 92,
            metrics: [
                makeMetric("path", 92, .measured),
                makeMetric("elbow", 58, .measured)
            ],
            correctionCode: "straight-path",
            completedAt: 40
        )
        let latestTrace = makeTrace(attemptID: id(44), offset: 0.2)
        let retest2 = makeAttempt(
            id: id(44),
            participant: participant,
            cycleID: cycle2,
            stage: .retest,
            score: 86,
            metrics: [
                makeMetric("path", 86, .measured),
                makeMetric("elbow", 65, .inferred)
            ],
            correctionCode: "straight-path",
            baselineAttemptID: baseline2.id,
            completedAt: 50,
            trace: latestTrace
        )

        for attempt in [baseline1, retest1, baseline2, retest2] {
            #expect(try repository.insertAttempt(attempt) == attempt)
        }
        #expect(try repository.insertAttempt(baseline1) == baseline1)

        let rebuilt = try #require(try repository.rebuildMemory(for: key))
        #expect(rebuilt.key == key)
        #expect(rebuilt.attemptCount == 4)
        #expect(rebuilt.latestAttempt?.id == retest2.id)
        #expect(rebuilt.bestAttempt?.id == baseline2.id)
        #expect(rebuilt.rollingLastThreeScore == (72 + 92 + 86) / 3)
        #expect(rebuilt.latestMetric(kind: "path") == makeMetric("path", 86, .measured))
        #expect(rebuilt.bestMetric(kind: "path") == makeMetric("path", 92, .measured))
        #expect(rebuilt.latestMetric(kind: "elbow") == makeMetric("elbow", 65, .inferred))
        #expect(rebuilt.correctionFocus == "straight-path")
        #expect(rebuilt.correctionFocusStreak == 2)
        #expect(rebuilt.lastProofDelta == TechniqueProofDelta(
            baselineAttemptID: baseline2.id,
            retestAttemptID: retest2.id,
            coachingCycleID: cycle2,
            scoreDelta: -6,
            correctionCode: "straight-path",
            completedAt: retest2.completedAt
        ))
        #expect(rebuilt.pastSelfTrace == latestTrace)
        #expect(try repository.memory(for: key) == rebuilt)
        #expect(try repository.attempts(for: key) == [baseline1, retest1, baseline2, retest2])

        let invalid = makeAttempt(
            id: id(45),
            participant: participant,
            cycleID: id(32),
            stage: .practice,
            score: 99,
            metrics: [makeMetric("path", 99, .measured)],
            correctionCode: nil,
            completedAt: 60,
            isValid: false,
            wrongHand: true
        )
        _ = try repository.insertAttempt(invalid)
        #expect(try repository.attempts(for: key).last == invalid)
        #expect(try repository.memory(for: key)?.attemptCount == 4)
        #expect(try repository.memory(for: key)?.bestAttempt?.id == baseline2.id)

        let southpawKey = makeMemoryKey(
            eventID: event.id,
            athleteID: participant.id,
            stance: .southpaw
        )
        let southpaw = makeAttempt(
            id: id(46),
            participant: participant,
            cycleID: id(33),
            stage: .baseline,
            score: 70,
            metrics: [makeMetric("path", 70, .measured)],
            correctionCode: "straight-path",
            completedAt: 70,
            stance: .southpaw
        )
        _ = try repository.insertAttempt(southpaw)
        #expect(try repository.memory(for: southpawKey)?.attemptCount == 1)
        #expect(try repository.memory(for: key)?.attemptCount == 4)

        let incompatibleRetest = makeAttempt(
            id: id(47),
            participant: participant,
            cycleID: cycle2,
            stage: .retest,
            score: 95,
            metrics: [makeMetric("path", 95, .measured)],
            correctionCode: "straight-path",
            baselineAttemptID: baseline2.id,
            completedAt: 80,
            stance: .southpaw
        )
        #expect(throws: AthleteMemoryRepositoryError.incompatibleProof) {
            _ = try repository.insertAttempt(incompatibleRetest)
        }
        #expect(try repository.attempts(for: southpawKey) == [southpaw])

        let incompatibleAvailability = makeAttempt(
            id: id(48),
            participant: participant,
            cycleID: cycle2,
            stage: .retest,
            score: 96,
            metrics: [makeMetric("path", 96, .measured)],
            correctionCode: "straight-path",
            baselineAttemptID: baseline2.id,
            completedAt: 90
        )
        #expect(throws: AthleteMemoryRepositoryError.incompatibleProof) {
            _ = try repository.insertAttempt(incompatibleAvailability)
        }

        let incompatibleCorrection = makeAttempt(
            id: id(49),
            participant: participant,
            cycleID: cycle2,
            stage: .retest,
            score: 97,
            metrics: [
                makeMetric("path", 97, .measured),
                makeMetric("elbow", 70, .measured)
            ],
            correctionCode: "extend-fully",
            baselineAttemptID: baseline2.id,
            completedAt: 91
        )
        #expect(throws: AthleteMemoryRepositoryError.incompatibleProof) {
            _ = try repository.insertAttempt(incompatibleCorrection)
        }
        #expect(try repository.attempts(for: key) == [
            baseline1,
            retest1,
            baseline2,
            retest2,
            invalid
        ])
    }

    @Test(
        "Runs, submissions, and awards are idempotent and reject cross-event references",
        arguments: RepositoryBackend.allCases
    )
    func eventOwnedResultContract(_ backend: RepositoryBackend) throws {
        let repository = try makeRepository(backend)
        let event = makeEvent(id: id(3), openedAt: 10)
        let participant = makeParticipant(
            id: id(60),
            eventID: event.id,
            name: "Drew",
            code: "0060"
        )
        _ = try repository.createEvent(event)
        _ = try repository.saveParticipant(participant)
        let attempt = makeAttempt(
            id: id(61),
            participant: participant,
            cycleID: id(62),
            stage: .baseline,
            score: 81,
            metrics: [makeMetric("path", 81, .measured)],
            correctionCode: "straight-path",
            completedAt: 30
        )
        let run = PendingTrainingRun(
            id: attempt.id,
            athleteID: participant.id,
            eventID: event.id,
            techniqueID: attempt.techniqueID,
            requestedAt: date(20)
        )!

        let reserved = try repository.reserveRun(run)
        #expect(reserved.status == .reserved)
        #expect(try repository.reserveRun(run) == reserved)
        let active = try repository.startRun(id: run.id, at: date(21))
        #expect(active.status == .active)
        #expect(active.startedAt == date(21))
        #expect(throws: AthleteMemoryRepositoryError.invalidRunTransition) {
            _ = try repository.commitRun(id: run.id, at: date(22))
        }

        _ = try repository.insertAttempt(attempt)
        let completed = try repository.completeRun(id: run.id, attemptID: attempt.id)
        #expect(completed.status == .completedAwaitingCommit)
        #expect(completed.attemptID == attempt.id)
        let committed = try repository.commitRun(id: run.id, at: date(31))
        #expect(committed.status == .committed)
        #expect(committed.updatedAt == date(31))
        #expect(try repository.run(id: run.id) == committed)
        #expect(throws: AthleteMemoryRepositoryError.invalidRunTransition) {
            _ = try repository.abortRun(id: run.id, at: date(32))
        }

        let submission = makeSubmission(id: id(71), participant: participant, event: event)
        #expect(try repository.submit(submission) == submission)
        #expect(try repository.submit(submission) == submission)
        #expect(try repository.submissions(eventID: event.id) == [submission])

        let award = EventAward(
            id: id(72),
            eventID: event.id,
            athleteID: participant.id,
            publicHandleSnapshot: participant.publicHandle!,
            kind: .personalBest,
            attemptID: attempt.id,
            awardedAt: date(32)
        )!
        #expect(try repository.saveAward(award) == award)
        #expect(try repository.saveAward(award) == award)
        #expect(try repository.awards(eventID: event.id) == [award])

        let wrongEventSubmission = makeSubmission(
            id: id(73),
            participant: participant,
            event: makeEvent(id: id(4), openedAt: 10)
        )
        #expect(throws: AthleteMemoryRepositoryError.submissionMismatch) {
            _ = try repository.submit(wrongEventSubmission)
        }

        _ = try repository.closeEvent(id: event.id, at: date(100))
        #expect(throws: AthleteMemoryRepositoryError.eventClosed) {
            _ = try repository.submit(makeSubmission(
                id: id(74),
                participant: participant,
                event: event
            ))
        }
    }

    @Test("File-backed SwiftData memory rebuilds from attempts after cache loss and reopen")
    func fileBackedMemoryRebuildsAfterCacheLoss() throws {
        try FileBackedMemoryFixture.use { storeURL in
            let event = makeEvent(id: id(5), openedAt: 10)
            let participant = makeParticipant(
                id: id(80),
                eventID: event.id,
                name: "Ellis",
                code: "0080"
            )
            let attempt = makeAttempt(
                id: id(81),
                participant: participant,
                cycleID: id(82),
                stage: .baseline,
                score: 77,
                metrics: [makeMetric("path", 77, .inferred)],
                correctionCode: "straight-path",
                completedAt: 30,
                trace: makeTrace(attemptID: id(81), offset: 0.1)
            )
            let key = makeMemoryKey(eventID: event.id, athleteID: participant.id)

            try autoreleasepool {
                let container = try CompetitionModelContainer.make(storeURL: storeURL)
                let repository = SwiftDataAthleteMemoryRepository(container: container)
                _ = try repository.createEvent(event)
                _ = try repository.saveParticipant(participant)
                _ = try repository.insertAttempt(attempt)
                #expect(try repository.memory(for: key)?.attemptCount == 1)
            }
            try autoreleasepool {
                let container = try CompetitionModelContainer.make(storeURL: storeURL)
                let context = ModelContext(container)
                let records = try context.fetch(
                    FetchDescriptor<CompetitionSchemaV2.AthleteSkillMemoryRecord>()
                )
                #expect(records.count == 1)
                records.forEach(context.delete)
                try context.save()
            }
            try autoreleasepool {
                let container = try CompetitionModelContainer.make(storeURL: storeURL)
                let repository = SwiftDataAthleteMemoryRepository(container: container)
                #expect(try repository.memory(for: key) == nil)
                #expect(try repository.attempts(for: key) == [attempt])
                let rebuilt = try #require(try repository.rebuildMemory(for: key))
                #expect(rebuilt.attemptCount == 1)
                #expect(rebuilt.latestMetric(kind: "path") == makeMetric("path", 77, .inferred))
                #expect(rebuilt.pastSelfTrace == attempt.pastSelfTrace)
            }
        }
    }

    @Test("A failed file-backed write rolls back without deleting persisted ownership")
    func fileBackedSaveFailureRollsBackWithoutDataLoss() throws {
        try FileBackedMemoryFixture.use { storeURL in
            let event = makeEvent(id: id(6), openedAt: 10)
            let participant = makeParticipant(
                id: id(90),
                eventID: event.id,
                name: "Finley",
                code: "0090"
            )
            let attempt = makeAttempt(
                id: id(91),
                participant: participant,
                cycleID: id(92),
                stage: .baseline,
                score: 83,
                metrics: [makeMetric("path", 83, .measured)],
                correctionCode: "straight-path",
                completedAt: 30
            )
            let key = makeMemoryKey(eventID: event.id, athleteID: participant.id)

            try autoreleasepool {
                let container = try CompetitionModelContainer.make(storeURL: storeURL)
                let repository = SwiftDataAthleteMemoryRepository(container: container)
                _ = try repository.createEvent(event)
                _ = try repository.saveParticipant(participant)
            }
            try autoreleasepool {
                let container = try CompetitionModelContainer.make(
                    storeURL: storeURL,
                    allowsSave: false
                )
                let repository = SwiftDataAthleteMemoryRepository(container: container)
                #expect(throws: AthleteMemoryRepositoryError.saveFailed) {
                    _ = try repository.insertAttempt(attempt)
                }
                #expect(try repository.attempts(for: key).isEmpty)
                #expect(try repository.memory(for: key) == nil)
            }
            try autoreleasepool {
                let container = try CompetitionModelContainer.make(storeURL: storeURL)
                let repository = SwiftDataAthleteMemoryRepository(container: container)
                #expect(try repository.activeEvent() == event)
                #expect(try repository.participant(
                    eventID: event.id,
                    displayCode: "0090"
                ) == participant)
                #expect(try repository.attempts(for: key).isEmpty)
                #expect(try repository.memory(for: key) == nil)
                #expect(try repository.insertAttempt(attempt) == attempt)
            }
        }
    }

    private func makeRepository(
        _ backend: RepositoryBackend
    ) throws -> any AthleteMemoryRepository {
        switch backend {
        case .inMemory:
            return InMemoryAthleteMemoryRepository()
        case .swiftData:
            return SwiftDataAthleteMemoryRepository(
                container: try CompetitionModelContainer.make(inMemory: true)
            )
        }
    }
}

@MainActor
private enum FileBackedMemoryFixture {
    static func use(_ body: (URL) throws -> Void) throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AthleteMemoryRepositoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        do {
            try body(directoryURL.appendingPathComponent("memory.store"))
            try FileManager.default.removeItem(at: directoryURL)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }
}

enum RepositoryBackend: CaseIterable, CustomTestStringConvertible {
    case inMemory
    case swiftData

    var testDescription: String {
        switch self {
        case .inMemory: "in-memory"
        case .swiftData: "SwiftData"
        }
    }
}

@MainActor
private func makeEvent(id: UUID, openedAt: TimeInterval) -> EventEdition {
    EventEdition(
        id: id,
        title: "Open Gym",
        status: .open,
        openedAt: date(openedAt),
        closedAt: nil,
        scoringVersion: 2,
        calibrationVersion: 1
    )!
}

@MainActor
private func makeParticipant(
    id: UUID,
    eventID: UUID,
    name: String,
    code: String,
    stance: Stance = .orthodox
) -> CompetitionPlayer {
    let handle = ParticipantPublicHandle.reserving(
        eventID: eventID,
        displayName: name,
        displayCode: code,
        against: []
    )!
    return CompetitionPlayer(
        id: id,
        name: name,
        normalizedName: CompetitionName.normalized(name),
        rememberedStance: stance,
        reach: BilateralReach(left: 0.64, right: 0.68),
        calibrationVersion: 1,
        calibratedAt: date(8),
        createdAt: date(5),
        lastSeenAt: date(9),
        experienceLevel: .beginner,
        publicHandle: handle
    )
}

@MainActor
private func makeMemoryKey(
    eventID: UUID,
    athleteID: UUID,
    stance: Stance = .orthodox
) -> AthleteSkillMemoryKey {
    AthleteSkillMemoryKey(
        eventID: eventID,
        athleteID: athleteID,
        techniqueID: Technique.jab.id,
        stance: stance,
        referenceVersion: 3,
        scoringVersion: 2,
        calibrationVersion: 1
    )!
}

@MainActor
private func makeAttempt(
    id: UUID,
    participant: CompetitionPlayer,
    cycleID: UUID,
    stage: TechniqueAttemptStage,
    score: Float,
    metrics: [TechniqueMetricSnapshot],
    correctionCode: String?,
    baselineAttemptID: UUID? = nil,
    completedAt: TimeInterval,
    trace: PastSelfTrace? = nil,
    isValid: Bool = true,
    wrongHand: Bool = false,
    stance: Stance = .orthodox
) -> TechniqueAttemptSnapshot {
    TechniqueAttemptSnapshot(
        id: id,
        athleteID: participant.id,
        eventID: participant.eventID,
        coachingCycleID: cycleID,
        stage: stage,
        techniqueID: Technique.jab.id,
        stance: stance,
        score: score,
        metrics: metrics,
        trackedFraction: 0.92,
        duration: 0.5,
        isValid: isValid,
        wrongHand: wrongHand,
        scoringVersion: 2,
        referenceVersion: 3,
        calibrationVersion: 1,
        correctionCode: correctionCode,
        baselineAttemptID: baselineAttemptID,
        startedAt: date(completedAt - 1),
        completedAt: date(completedAt),
        pastSelfTrace: trace,
        publicHandleSnapshot: participant.publicHandle
    )!
}

private func makeMetric(
    _ kind: String,
    _ score: Float?,
    _ provenance: TechniqueMetricProvenance
) -> TechniqueMetricSnapshot {
    TechniqueMetricSnapshot(kind: kind, score: score, provenance: provenance)!
}

private func makeTrace(attemptID: UUID, offset: Float) -> PastSelfTrace {
    PastSelfTrace(
        attemptID: attemptID,
        coordinateSpace: .normalizedBody,
        samples: [
            NormalizedTraceSample(time: 0, position: SIMD3(offset, 0, 0)),
            NormalizedTraceSample(time: 1, position: SIMD3(offset + 0.5, 0.1, 0.2))
        ]
    )!
}

@MainActor
private func makeSubmission(
    id: UUID,
    participant: CompetitionPlayer,
    event: EventEdition
) -> CompetitionSubmission {
    CompetitionSubmission(
        id: id,
        playerID: participant.id,
        playerName: participant.name,
        normalizedPlayerName: participant.normalizedName,
        mode: .reactiveStrike,
        score: 88,
        validSteps: 7,
        totalSteps: 8,
        completedRepetitions: 0,
        meanCentreErrorMeters: 0.02,
        speedTieBreakSeconds: 0.31,
        startedAt: date(40),
        endedAt: date(50),
        trackingStatus: .complete,
        eventID: event.id,
        scoringVersion: event.scoringVersion,
        calibrationVersion: participant.calibrationVersion,
        publicHandleSnapshot: participant.publicHandle
    )
}

private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func id(_ suffix: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix))
}

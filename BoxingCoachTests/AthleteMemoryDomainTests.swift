import Foundation
import simd
import Testing
@testable import BoxingCoach

@Suite("Athlete memory domain")
struct AthleteMemoryDomainTests {
    @Test("An event edition closes once and preserves its scoring contract")
    func eventEditionClosesOnce() throws {
        let openedAt = Date(timeIntervalSince1970: 100)
        let event = try #require(EventEdition(
            id: UUID(),
            title: "Summer Open",
            status: .open,
            openedAt: openedAt,
            closedAt: nil,
            scoringVersion: 2,
            calibrationVersion: 1
        ))

        #expect(event.isOpen)
        #expect(event.scoringVersion == 2)
        #expect(event.closing(at: openedAt.addingTimeInterval(-1)) == nil)

        let closed = try #require(event.closing(at: openedAt.addingTimeInterval(60)))
        #expect(closed.status == .closed)
        #expect(closed.closedAt == openedAt.addingTimeInterval(60))
        #expect(closed.closing(at: openedAt.addingTimeInterval(120)) == nil)
    }

    @Test("Decoding rejects event editions whose status and close timestamp disagree")
    func decodedEventEditionRevalidatesCloseState() throws {
        let openedAt = Date(timeIntervalSince1970: 100)
        let openWithClose = EventEditionPayload(
            id: UUID(),
            title: "Summer Open",
            status: .open,
            openedAt: openedAt,
            closedAt: openedAt.addingTimeInterval(60),
            scoringVersion: 2,
            calibrationVersion: 1
        )
        let closedWithoutClose = EventEditionPayload(
            id: UUID(),
            title: "Summer Open",
            status: .closed,
            openedAt: openedAt,
            closedAt: nil,
            scoringVersion: 2,
            calibrationVersion: 1
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventEdition.self, from: encoded(openWithClose))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventEdition.self, from: encoded(closedWithoutClose))
        }
    }

    @Test("Past-self traces accept only finite normalized body samples and retain at most 32")
    func pastSelfTraceEnforcesSafeCoordinateContract() throws {
        let samples = (0..<65).map { index in
            NormalizedTraceSample(
                time: Float(index) / 64,
                position: SIMD3(Float(index) / 64, 0.25, 0.75)
            )
        }

        let trace = try #require(PastSelfTrace(
            attemptID: UUID(),
            coordinateSpace: .normalizedBody,
            samples: samples
        ))
        #expect(trace.samples.count == PastSelfTrace.maximumSampleCount)
        #expect(trace.samples.first == samples.first)
        #expect(trace.samples.last == samples.last)

        #expect(PastSelfTrace(
            attemptID: UUID(),
            coordinateSpace: .world,
            samples: samples
        ) == nil)
        #expect(PastSelfTrace(
            attemptID: UUID(),
            coordinateSpace: .head,
            samples: samples
        ) == nil)
        #expect(PastSelfTrace(
            attemptID: UUID(),
            coordinateSpace: .normalizedBody,
            samples: [NormalizedTraceSample(time: 0, position: SIMD3(.nan, 0, 0))]
        ) == nil)
    }

    @Test("Decoding cannot bypass past-self trace validation")
    func decodedPastSelfTraceRejectsNonfiniteSamples() throws {
        let payload = TracePayload(
            attemptID: UUID(),
            samples: [NormalizedTraceSample(time: 0, position: SIMD3(.nan, 0, 0))]
        )
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let data = try encoder.encode(payload)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        #expect(throws: DecodingError.self) {
            try decoder.decode(PastSelfTrace.self, from: data)
        }
    }

    @Test("Attempt identity survives memory storage, run completion, and Codable round trips")
    func attemptIdentityIsStable() throws {
        let athleteID = UUID()
        let attemptID = UUID()
        let attempt = try #require(TechniqueAttemptSnapshot(
            id: attemptID,
            athleteID: athleteID,
            eventID: nil,
            techniqueID: Technique.jab.id,
            score: 84,
            scoringVersion: 2,
            calibrationVersion: 1,
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            publicHandleSnapshot: nil
        ))
        let memory = try #require(AthleteSkillMemory(
            athleteID: athleteID,
            techniqueID: Technique.jab.id,
            experienceLevel: .beginner,
            attempts: [attempt],
            pastSelfTrace: nil,
            updatedAt: attempt.completedAt
        ))

        let decoded = try JSONDecoder().decode(
            TechniqueAttemptSnapshot.self,
            from: JSONEncoder().encode(attempt)
        )
        #expect(decoded == attempt)
        #expect(memory.bestAttempt?.id == attemptID)

        let pending = try #require(PendingTrainingRun(
            id: UUID(),
            athleteID: athleteID,
            eventID: nil,
            techniqueID: Technique.jab.id,
            requestedAt: Date(timeIntervalSince1970: 9)
        ))
        let active = try #require(pending.starting(at: Date(timeIntervalSince1970: 10)))
        let completed = try #require(active.completing(with: attempt))
        #expect(completed.attemptID == attemptID)
        #expect(completed.runID == pending.id)
    }

    @Test("Decoding rejects attempts with invalid scores, versions, or timestamps")
    func decodedAttemptRevalidatesAllFields() throws {
        let athleteID = UUID()
        let startedAt = Date(timeIntervalSince1970: 10)
        let completedAt = Date(timeIntervalSince1970: 11)
        let invalidScore = AttemptPayload(
            id: UUID(),
            athleteID: athleteID,
            eventID: nil,
            techniqueID: Technique.jab.id,
            score: 101,
            scoringVersion: 2,
            calibrationVersion: 1,
            startedAt: startedAt,
            completedAt: completedAt,
            publicHandleSnapshot: nil
        )
        let invalidScoringVersion = AttemptPayload(
            id: UUID(),
            athleteID: athleteID,
            eventID: nil,
            techniqueID: Technique.jab.id,
            score: 80,
            scoringVersion: 0,
            calibrationVersion: 1,
            startedAt: startedAt,
            completedAt: completedAt,
            publicHandleSnapshot: nil
        )
        let invalidCalibrationVersion = AttemptPayload(
            id: UUID(),
            athleteID: athleteID,
            eventID: nil,
            techniqueID: Technique.jab.id,
            score: 80,
            scoringVersion: 2,
            calibrationVersion: 0,
            startedAt: startedAt,
            completedAt: completedAt,
            publicHandleSnapshot: nil
        )
        let backwardsTime = AttemptPayload(
            id: UUID(),
            athleteID: athleteID,
            eventID: nil,
            techniqueID: Technique.jab.id,
            score: 80,
            scoringVersion: 2,
            calibrationVersion: 1,
            startedAt: completedAt,
            completedAt: startedAt,
            publicHandleSnapshot: nil
        )

        for payload in [invalidScore, invalidScoringVersion, invalidCalibrationVersion, backwardsTime] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(TechniqueAttemptSnapshot.self, from: encoded(payload))
            }
        }
    }

    @Test("Decoding cannot bypass skill-memory key version validation")
    func decodedMemoryKeyRevalidatesVersions() throws {
        let payload = MemoryKeyPayload(
            eventID: UUID(),
            athleteID: UUID(),
            techniqueID: Technique.jab.id,
            stance: .orthodox,
            referenceVersion: 0,
            scoringVersion: 2,
            calibrationVersion: 1
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AthleteSkillMemoryKey.self, from: encoded(payload))
        }
    }

    @Test("Decoding rejects skill memory containing another athlete's attempt")
    func decodedMemoryRevalidatesAttemptMembership() throws {
        let attempt = try #require(TechniqueAttemptSnapshot(
            id: UUID(),
            athleteID: UUID(),
            eventID: nil,
            techniqueID: Technique.jab.id,
            score: 84,
            scoringVersion: 2,
            calibrationVersion: 1,
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11),
            publicHandleSnapshot: nil
        ))
        let payload = MemoryPayload(
            athleteID: UUID(),
            techniqueID: Technique.jab.id,
            experienceLevel: .beginner,
            attempts: [attempt],
            pastSelfTrace: nil,
            updatedAt: attempt.completedAt
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AthleteSkillMemory.self, from: encoded(payload))
        }
    }

    @Test("Typed runs reject backwards time and mismatched attempts")
    func typedRunTransitionsValidateIdentityAndTime() throws {
        let athleteID = UUID()
        let pending = try #require(PendingTrainingRun(
            id: UUID(),
            athleteID: athleteID,
            eventID: nil,
            techniqueID: Technique.cross.id,
            requestedAt: Date(timeIntervalSince1970: 20)
        ))
        #expect(pending.starting(at: Date(timeIntervalSince1970: 19)) == nil)

        let active = try #require(pending.starting(at: Date(timeIntervalSince1970: 21)))
        let wrongTechnique = try #require(TechniqueAttemptSnapshot(
            id: UUID(),
            athleteID: athleteID,
            eventID: nil,
            techniqueID: Technique.jab.id,
            score: 70,
            scoringVersion: 2,
            calibrationVersion: nil,
            startedAt: Date(timeIntervalSince1970: 21),
            completedAt: Date(timeIntervalSince1970: 22),
            publicHandleSnapshot: nil
        ))
        #expect(active.completing(with: wrongTechnique) == nil)
        #expect(active.cancelling(at: Date(timeIntervalSince1970: 20)) == nil)
        #expect(active.cancelling(at: Date(timeIntervalSince1970: 22))?.runID == pending.id)
    }

    @Test("Decoding rejects pending and active runs that could not be constructed")
    func decodedPendingAndActiveRunsRevalidateTransitions() throws {
        let requestedAt = Date(timeIntervalSince1970: 20)
        let invalidPending = PendingRunPayload(
            id: UUID(),
            athleteID: UUID(),
            eventID: nil,
            techniqueID: "",
            requestedAt: requestedAt
        )
        let backwardsActive = ActiveRunPayload(
            id: UUID(),
            athleteID: UUID(),
            eventID: nil,
            techniqueID: Technique.jab.id,
            requestedAt: requestedAt,
            startedAt: requestedAt.addingTimeInterval(-1)
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PendingTrainingRun.self, from: encoded(invalidPending))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ActiveTrainingRun.self, from: encoded(backwardsActive))
        }
    }

    @Test("Decoding rejects completed and cancelled runs with backwards terminal timestamps")
    func decodedTerminalRunsRevalidateTransitions() throws {
        let startedAt = Date(timeIntervalSince1970: 20)
        let backwardsCompleted = CompletedRunPayload(
            runID: UUID(),
            athleteID: UUID(),
            eventID: nil,
            techniqueID: Technique.jab.id,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(-1),
            attemptID: UUID()
        )
        let backwardsCancelled = CancelledRunPayload(
            runID: UUID(),
            athleteID: UUID(),
            eventID: nil,
            techniqueID: Technique.jab.id,
            startedAt: startedAt,
            cancelledAt: startedAt.addingTimeInterval(-1)
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CompletedTrainingRun.self, from: encoded(backwardsCompleted))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CancelledTrainingRun.self, from: encoded(backwardsCancelled))
        }
    }

    @Test("Decoding rejects an award whose public handle belongs to another event")
    func decodedAwardRevalidatesEventProvenance() throws {
        let handleEventID = UUID()
        let handle = try #require(ParticipantPublicHandle.reserving(
            eventID: handleEventID,
            displayName: "Alex",
            displayCode: "0042",
            against: []
        ))
        let payload = AwardPayload(
            id: UUID(),
            eventID: UUID(),
            athleteID: UUID(),
            publicHandleSnapshot: handle,
            kind: .personalBest,
            attemptID: UUID(),
            awardedAt: Date(timeIntervalSince1970: 30)
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventAward.self, from: encoded(payload))
        }
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private struct EventEditionPayload: Encodable {
        let id: UUID
        let title: String
        let status: EventEditionStatus
        let openedAt: Date
        let closedAt: Date?
        let scoringVersion: Int
        let calibrationVersion: Int
    }

    private struct TracePayload: Encodable {
        let attemptID: UUID
        let samples: [NormalizedTraceSample]
    }

    private struct AttemptPayload: Encodable {
        let id: UUID
        let athleteID: UUID
        let eventID: UUID?
        let techniqueID: String
        let score: Float
        let scoringVersion: Int
        let calibrationVersion: Int?
        let startedAt: Date
        let completedAt: Date
        let publicHandleSnapshot: ParticipantPublicHandle?
    }

    private struct MemoryPayload: Encodable {
        let athleteID: UUID
        let techniqueID: String
        let experienceLevel: ExperienceLevel
        let attempts: [TechniqueAttemptSnapshot]
        let pastSelfTrace: PastSelfTrace?
        let updatedAt: Date
    }

    private struct MemoryKeyPayload: Encodable {
        let eventID: UUID?
        let athleteID: UUID
        let techniqueID: String
        let stance: Stance
        let referenceVersion: Int
        let scoringVersion: Int
        let calibrationVersion: Int?
    }

    private struct PendingRunPayload: Encodable {
        let id: UUID
        let athleteID: UUID
        let eventID: UUID?
        let techniqueID: String
        let requestedAt: Date
    }

    private struct ActiveRunPayload: Encodable {
        let id: UUID
        let athleteID: UUID
        let eventID: UUID?
        let techniqueID: String
        let requestedAt: Date
        let startedAt: Date
    }

    private struct CompletedRunPayload: Encodable {
        let runID: UUID
        let athleteID: UUID
        let eventID: UUID?
        let techniqueID: String
        let startedAt: Date
        let completedAt: Date
        let attemptID: UUID
    }

    private struct CancelledRunPayload: Encodable {
        let runID: UUID
        let athleteID: UUID
        let eventID: UUID?
        let techniqueID: String
        let startedAt: Date
        let cancelledAt: Date
    }

    private struct AwardPayload: Encodable {
        let id: UUID
        let eventID: UUID
        let athleteID: UUID
        let publicHandleSnapshot: ParticipantPublicHandle
        let kind: EventAwardKind
        let attemptID: UUID?
        let awardedAt: Date
    }
}

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

        let pending = PendingTrainingRun(
            id: UUID(),
            athleteID: athleteID,
            eventID: nil,
            techniqueID: Technique.jab.id,
            requestedAt: Date(timeIntervalSince1970: 9)
        )
        let active = try #require(pending.starting(at: Date(timeIntervalSince1970: 10)))
        let completed = try #require(active.completing(with: attempt))
        #expect(completed.attemptID == attemptID)
        #expect(completed.runID == pending.id)
    }

    @Test("Typed runs reject backwards time and mismatched attempts")
    func typedRunTransitionsValidateIdentityAndTime() throws {
        let athleteID = UUID()
        let pending = PendingTrainingRun(
            id: UUID(),
            athleteID: athleteID,
            eventID: nil,
            techniqueID: Technique.cross.id,
            requestedAt: Date(timeIntervalSince1970: 20)
        )
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

    private struct TracePayload: Encodable {
        let attemptID: UUID
        let samples: [NormalizedTraceSample]
    }
}

import Foundation
import simd
import Testing
@testable import BoxingCoach

@Suite("Tracking evidence contracts")
struct TrackingEvidenceTests {
    @Test("A tracked finite hand becomes immutable accepted evidence")
    func validHandRetainsProvenance() throws {
        let hand = try makeHand(
            side: .left,
            timestamp: 12.0,
            generation: 4,
            quality: .measured
        )

        #expect(hand.side == .left)
        #expect(hand.fistState == .closed)
        #expect(hand.quality == .measured)
        #expect(hand.elbowQuality == .inferred)
        requireDurableValueContract(hand)
    }

    @Test("Untracked hands cannot become accepted evidence")
    func untrackedHandIsRejected() {
        #expect {
            try makeHand(side: .right, isTracked: false)
        } throws: { error in
            error as? TrackingRejectionReason == .untracked(side: .right)
        }
    }

    @Test("Nonfinite hand geometry cannot become accepted evidence")
    func nonfiniteHandIsRejected() {
        #expect {
            try makeHand(
                side: .left,
                wristPosition: SIMD3(.nan, 0, 0)
            )
        } throws: { error in
            error as? TrackingRejectionReason == .nonFinite(field: "wristPosition")
        }
    }

    @Test("Fresh coherent snapshots preserve measured and inferred metadata")
    func validSnapshotRetainsQuality() throws {
        let hand = try makeHand(timestamp: 20.01, generation: 8, quality: .measured)
        let snapshot = try ValidatedTrackingSnapshot(
            generation: 8,
            capturedAt: 20.02,
            now: 20.03,
            devicePosition: SIMD3(0, 1.7, 0),
            deviceOrientation: SIMD4(0, 0, 0, 1),
            deviceTimestamp: 20,
            deviceQuality: .inferred,
            hands: [hand],
            maximumAge: 0.1,
            maximumSkew: 0.03
        )

        #expect(snapshot.deviceQuality == .inferred)
        #expect(snapshot.hand(for: .left) == hand)
        requireConcurrentValueContract(snapshot)
    }

    @Test("Serialized snapshots are untrusted until readmitted at a supplied current time")
    func serializedSnapshotRequiresCurrentReadmission() throws {
        let hand = try makeHand(timestamp: 70, generation: 12)
        let snapshot = try ValidatedTrackingSnapshot(
            generation: 12,
            capturedAt: 70,
            now: 70,
            devicePosition: .zero,
            deviceOrientation: SIMD4(0, 0, 0, 1),
            deviceTimestamp: 70,
            deviceQuality: .measured,
            hands: [hand]
        )
        let payload = UntrustedTrackingSnapshot(snapshot)
        let decoded = try JSONDecoder().decode(
            UntrustedTrackingSnapshot.self,
            from: JSONEncoder().encode(payload)
        )

        #expect {
            try decoded.validated(now: 70.2)
        } throws: { error in
            guard case .stale = error as? TrackingRejectionReason else { return false }
            return true
        }
    }

    @Test("Stale snapshots cannot become accepted evidence")
    func staleSnapshotIsRejected() throws {
        let hand = try makeHand(timestamp: 9, generation: 2)

        #expect {
            try ValidatedTrackingSnapshot(
                generation: 2,
                capturedAt: 9,
                now: 10,
                devicePosition: .zero,
                deviceOrientation: SIMD4(0, 0, 0, 1),
                deviceTimestamp: 9,
                deviceQuality: .measured,
                hands: [hand],
                maximumAge: 0.1,
                maximumSkew: 0.03
            )
        } throws: { error in
            guard case .stale = error as? TrackingRejectionReason else { return false }
            return true
        }
    }

    @Test("Snapshot admission limits cannot be relaxed beyond the tracking policy")
    func snapshotAdmissionLimitsHaveHardCeilings() throws {
        let hand = try makeHand(timestamp: 10, generation: 2)

        #expect {
            try ValidatedTrackingSnapshot(
                generation: 2,
                capturedAt: 10,
                now: 10,
                devicePosition: .zero,
                deviceOrientation: SIMD4(0, 0, 0, 1),
                deviceTimestamp: 10,
                deviceQuality: .measured,
                hands: [hand],
                maximumAge: 0.101
            )
        } throws: { error in
            error as? TrackingRejectionReason == .invalidRange(field: "maximumAge")
        }

        #expect {
            try ValidatedTrackingSnapshot(
                generation: 2,
                capturedAt: 10,
                now: 10,
                devicePosition: .zero,
                deviceOrientation: SIMD4(0, 0, 0, 1),
                deviceTimestamp: 10,
                deviceQuality: .measured,
                hands: [hand],
                maximumSkew: 0.034
            )
        } throws: { error in
            error as? TrackingRejectionReason == .invalidRange(field: "maximumSkew")
        }
    }

    @Test("Snapshot admission checks every timestamp against its admission time")
    func snapshotAdmissionRejectsFutureAndIndividuallyStaleSamples() throws {
        let currentHand = try makeHand(timestamp: 10, generation: 2)
        let futureHand = try makeHand(timestamp: 10.01, generation: 2)
        let staleHand = try makeHand(timestamp: 9, generation: 2)

        #expect {
            try ValidatedTrackingSnapshot(
                generation: 2,
                capturedAt: 10.01,
                now: 10,
                devicePosition: .zero,
                deviceOrientation: SIMD4(0, 0, 0, 1),
                deviceTimestamp: 10,
                deviceQuality: .measured,
                hands: [currentHand]
            )
        } throws: { error in
            error as? TrackingRejectionReason == .invalidRange(field: "capturedAt")
        }

        #expect {
            try ValidatedTrackingSnapshot(
                generation: 2,
                capturedAt: 10,
                now: 10,
                devicePosition: .zero,
                deviceOrientation: SIMD4(0, 0, 0, 1),
                deviceTimestamp: 10.01,
                deviceQuality: .measured,
                hands: [currentHand]
            )
        } throws: { error in
            error as? TrackingRejectionReason == .invalidRange(field: "deviceTimestamp")
        }

        #expect {
            try ValidatedTrackingSnapshot(
                generation: 2,
                capturedAt: 10,
                now: 10,
                devicePosition: .zero,
                deviceOrientation: SIMD4(0, 0, 0, 1),
                deviceTimestamp: 10,
                deviceQuality: .measured,
                hands: [futureHand]
            )
        } throws: { error in
            error as? TrackingRejectionReason == .invalidRange(field: "handTimestamp.left")
        }

        #expect {
            try ValidatedTrackingSnapshot(
                generation: 2,
                capturedAt: 10,
                now: 10,
                devicePosition: .zero,
                deviceOrientation: SIMD4(0, 0, 0, 1),
                deviceTimestamp: 10,
                deviceQuality: .measured,
                hands: [staleHand]
            )
        } throws: { error in
            guard case .stale = error as? TrackingRejectionReason else { return false }
            return true
        }

        #expect {
            try ValidatedTrackingSnapshot(
                generation: 2,
                capturedAt: 10,
                now: 10,
                devicePosition: .zero,
                deviceOrientation: SIMD4(0, 0, 0, 1),
                deviceTimestamp: 9,
                deviceQuality: .measured,
                hands: [currentHand]
            )
        } throws: { error in
            guard case .stale = error as? TrackingRejectionReason else { return false }
            return true
        }

        #expect {
            let matchingStaleHand = try makeHand(timestamp: 9, generation: 2)
            try ValidatedTrackingSnapshot(
                generation: 2,
                capturedAt: 10,
                now: 10,
                devicePosition: .zero,
                deviceOrientation: SIMD4(0, 0, 0, 1),
                deviceTimestamp: 9,
                deviceQuality: .measured,
                hands: [matchingStaleHand]
            )
        } throws: { error in
            guard case .stale = error as? TrackingRejectionReason else { return false }
            return true
        }
    }

    @Test("Over-skewed device and hand samples cannot become accepted evidence")
    func skewedSnapshotIsRejected() throws {
        let hand = try makeHand(timestamp: 30.08, generation: 3)

        #expect {
            try ValidatedTrackingSnapshot(
                generation: 3,
                capturedAt: 30.08,
                now: 30.08,
                devicePosition: .zero,
                deviceOrientation: SIMD4(0, 0, 0, 1),
                deviceTimestamp: 30,
                deviceQuality: .measured,
                hands: [hand],
                maximumAge: 0.1,
                maximumSkew: 0.03
            )
        } throws: { error in
            guard case .overSkewed = error as? TrackingRejectionReason else { return false }
            return true
        }
    }

    @Test("Snapshots cannot mix tracking generations")
    func generationMismatchIsRejected() throws {
        let oldHand = try makeHand(timestamp: 40, generation: 6)

        #expect {
            try ValidatedTrackingSnapshot(
                generation: 7,
                capturedAt: 40,
                now: 40,
                devicePosition: .zero,
                deviceOrientation: SIMD4(0, 0, 0, 1),
                deviceTimestamp: 40,
                deviceQuality: .measured,
                hands: [oldHand]
            )
        } throws: { error in
            error as? TrackingRejectionReason == .generationMismatch(expected: 7, actual: 6)
        }
    }

    @Test("Punch evidence rejects nonfinite derived measurements")
    func nonfinitePunchEvidenceIsRejected() {
        #expect {
            try makePunchEvidence(trackedFraction: .nan)
        } throws: { error in
            error as? TrackingRejectionReason == .nonFinite(field: "trackedFraction")
        }
    }

    @Test("Punch evidence carries technique, stance, side, and provenance")
    func validPunchEvidenceRetainsDomainIdentity() throws {
        let evidence = try makePunchEvidence()

        #expect(evidence.technique == .jab)
        #expect(evidence.stance == .orthodox)
        #expect(evidence.side == .left)
        #expect(evidence.quality == .measured)
        requireDurableValueContract(evidence)
    }

    @Test("Decoding cannot bypass validated tracking admission")
    func decodingInvalidEvidenceIsRejected() throws {
        let hand = try makeHand()
        let invalidHandData = try replacingJSONValue(
            in: JSONEncoder().encode(hand),
            key: "fistClosureRatio",
            with: 2.0
        )
        #expect {
            try JSONDecoder().decode(ValidatedHandObservation.self, from: invalidHandData)
        } throws: { error in
            error as? TrackingRejectionReason == .invalidRange(field: "fistClosureRatio")
        }

        let punch = try makePunchEvidence()
        let invalidPunchData = try replacingJSONValue(
            in: JSONEncoder().encode(punch),
            key: "trackedFraction",
            with: -1.0
        )
        #expect {
            try JSONDecoder().decode(ValidatedPunchEvidence.self, from: invalidPunchData)
        } throws: { error in
            error as? TrackingRejectionReason == .invalidRange(field: "trackedFraction")
        }

        let snapshotHand = try makeHand(timestamp: 70, generation: 12)
        let snapshot = try ValidatedTrackingSnapshot(
            generation: 12,
            capturedAt: 70,
            now: 70,
            devicePosition: .zero,
            deviceOrientation: SIMD4(0, 0, 0, 1),
            deviceTimestamp: 70,
            deviceQuality: .measured,
            hands: [snapshotHand]
        )
        let invalidSnapshotData = try replacingJSONValue(
            in: JSONEncoder().encode(UntrustedTrackingSnapshot(snapshot)),
            key: "generation",
            with: 13.0
        )
        let decodedSnapshot = try JSONDecoder().decode(
            UntrustedTrackingSnapshot.self,
            from: invalidSnapshotData
        )
        #expect {
            try decodedSnapshot.validated(now: 70)
        } throws: { error in
            error as? TrackingRejectionReason == .generationMismatch(expected: 13, actual: 12)
        }
    }

    private func makeHand(
        side: BodySide = .left,
        isTracked: Bool = true,
        wristPosition: SIMD3<Float> = SIMD3(-0.2, 1.2, -0.4),
        timestamp: TimeInterval = 1,
        generation: UInt64 = 1,
        quality: MeasurementQuality = .measured
    ) throws -> ValidatedHandObservation {
        try ValidatedHandObservation(
            side: side,
            isTracked: isTracked,
            wristPosition: wristPosition,
            wristOrientation: SIMD4(0, 0, 0, 1),
            elbowPosition: SIMD3(-0.25, 1.1, -0.2),
            elbowQuality: .inferred,
            fistPosition: SIMD3(-0.2, 1.2, -0.5),
            fistState: .closed,
            fistClosureRatio: 0.9,
            timestamp: timestamp,
            generation: generation,
            quality: quality
        )
    }

    private func makePunchEvidence(
        trackedFraction: Float = 0.95
    ) throws -> ValidatedPunchEvidence {
        try ValidatedPunchEvidence(
            technique: .jab,
            stance: .orthodox,
            side: .left,
            generation: 5,
            startedAt: 50,
            landedAt: 50.2,
            returnedAt: 50.5,
            outboundTravel: 0.48,
            landingError: 0.02,
            returnError: 0.04,
            trackedFraction: trackedFraction,
            quality: .measured
        )
    }

    private func requireDurableValueContract<T: Codable & Hashable & Sendable>(_ value: T) {
        _ = value
    }

    private func requireConcurrentValueContract<T: Hashable & Sendable>(_ value: T) {
        _ = value
    }

    private func replacingJSONValue(
        in data: Data,
        key: String,
        with value: Double
    ) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }
}

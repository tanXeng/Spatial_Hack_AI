import XCTest
import simd
@testable import BoxingCoach

final class BoxingCoachTechniqueTests: XCTestCase {
    func testUppercutIsOneAlternatingTechniqueWithLegacyLookup() {
        let uppercuts = Technique.all.filter { $0.id.contains("uppercut") }

        XCTAssertEqual(uppercuts, [.uppercut])
        XCTAssertEqual(Technique.uppercut.hand.rawValue, PunchHand.either.rawValue)
        XCTAssertEqual(Technique.technique(id: "uppercut"), .uppercut)
        XCTAssertEqual(Technique.technique(id: "left-uppercut"), .uppercut)
        XCTAssertEqual(Technique.technique(id: "right-uppercut"), .uppercut)
    }

    func testUppercutReferenceMirrorsItsHipToCentrelinePath() throws {
        let left = ReferencePunchLibrary.punch(
            for: .uppercut,
            stance: .orthodox,
            measurements: .averageAdult,
            side: .left
        )
        let right = ReferencePunchLibrary.punch(
            for: .uppercut,
            stance: .orthodox,
            measurements: .averageAdult,
            side: .right
        )

        XCTAssertEqual(left.samples.count, right.samples.count)
        XCTAssertGreaterThan(left.samples.count, 10)

        for (leftSample, rightSample) in zip(left.samples, right.samples) {
            XCTAssertEqual(leftSample.fist.x, -rightSample.fist.x, accuracy: 1e-5)
            XCTAssertEqual(leftSample.fist.y, rightSample.fist.y, accuracy: 1e-5)
            XCTAssertEqual(leftSample.fist.z, rightSample.fist.z, accuracy: 1e-5)
        }

        let lowest = try XCTUnwrap(left.samples.min(by: { $0.fist.y < $1.fist.y }))
        let highest = try XCTUnwrap(left.samples.max(by: { $0.fist.y < $1.fist.y }))
        XCTAssertLessThan(lowest.fist.y, -0.5, "The uppercut should load down near the hip")
        XCTAssertGreaterThan(highest.fist.y, 0.3, "The uppercut should finish near chin height")
        XCTAssertGreaterThan(
            highest.fist.x,
            lowest.fist.x,
            "A left uppercut should travel inward toward the centreline as it rises"
        )

        let guidedPeak = try XCTUnwrap(left.sample(at: left.peakTime))
        XCTAssertEqual(guidedPeak.fist.y, highest.fist.y, accuracy: 1e-5)
        XCTAssertGreaterThan(
            left.peakTime,
            lowest.time,
            "The guide must hold at the upward landing, not at the hip load"
        )
        XCTAssertFalse(
            left.shouldEmphasize(lowest),
            "The radially longer hip load must not receive landing emphasis"
        )
        XCTAssertTrue(left.shouldEmphasize(guidedPeak))
    }

    /// A user who drops their hand to the hip and never punches must score **zero** extension,
    /// even though that load is radially further from the shoulder than a real uppercut finish.
    /// This is the entire reason `PunchExtensionSemantics` measures ordered vertical rise for this
    /// technique instead of peak radial reach.
    ///
    /// The trap is authored into the *attempt* here rather than borrowed from the reference. It
    /// used to be taken from the reference's own guard→hip prefix, which worked only because the
    /// authored finish sat unrealistically close to the user (radial 0.62 against the hip's 0.65).
    /// Moving that finish out to a viewable target distance — see `PunchTargetGeometryTests` —
    /// made the reference's finish the radially furthest point, as it should be. The semantics
    /// still have to hold for a real attempt, so the fixture now carries the trap explicitly.
    func testUppercutExtensionRequiresAnOrderedRiseAfterTheHipLoad() throws {
        let reference = ReferencePunchLibrary.punch(
            for: .uppercut,
            stance: .orthodox,
            measurements: .averageAdult,
            side: .left
        )

        // Guard, then a deep drop beside the hip, and nothing else. Radially this beats the
        // reference's landing; vertically it never rises at all.
        let elbow = SIMD3<Float>(0.20, -0.45, -0.05)
        let guardHand = SIMD3<Float>(-0.18, -0.15, 0.23)
        let loadOnlySamples: [MotionSample] = stride(from: 0.0, through: 0.20, by: 1.0 / 60.0)
            .map { time in
                let t = Float(time / 0.20)
                return MotionSample(
                    time: time,
                    fist: simd_mix(
                        SIMD3<Float>(0.15, 0.18, 0.30),
                        SIMD3<Float>(0.05, -0.80, 0.18),
                        SIMD3(repeating: t)
                    ),
                    elbow: elbow,
                    guardHand: guardHand,
                    isTracked: true
                )
            }
        let loadOnly = RecordedAttempt(
            samples: loadOnlySamples,
            trackedFraction: 1,
            duration: (loadOnlySamples.last?.time ?? 0) - (loadOnlySamples.first?.time ?? 0)
        )

        XCTAssertGreaterThan(
            loadOnly.peakReach,
            reference.peakReach,
            "This fixture must preserve the radial-peak trap at the hip"
        )
        XCTAssertEqual(
            loadOnly.extensionMagnitude(for: Technique.uppercut.id),
            0,
            accuracy: 1e-5,
            "Dropping from guard to the hip without rising is not uppercut extension"
        )
        XCTAssertGreaterThan(reference.extensionMagnitude, 0.9)

        let score = try XCTUnwrap(
            TechniqueScorer().score(
                attempt: loadOnly,
                reference: reference,
                technique: .uppercut,
                thrownSide: .left,
                stance: .orthodox
            )
        )
        let extensionMetric = try XCTUnwrap(score.metric(.extensionReach))
        XCTAssertEqual(extensionMetric.score ?? -1, 0, accuracy: 1e-5)
    }

    func testNonUppercutExtensionKeepsRadialPeakReach() {
        let reference = ReferencePunchLibrary.punch(
            for: .jab,
            stance: .orthodox,
            measurements: .averageAdult,
            side: .left
        )
        let attempt = RecordedAttempt(
            samples: reference.samples,
            trackedFraction: 1,
            duration: reference.duration
        )

        XCTAssertEqual(reference.extensionMagnitude, reference.peakReach, accuracy: 1e-6)
        XCTAssertEqual(
            attempt.extensionMagnitude(for: Technique.jab.id),
            attempt.peakReach,
            accuracy: 1e-6
        )
    }

    func testRecorderKeepsTheUppercutLandingAfterTheRadiallyLongerLoad() throws {
        let reference = ReferencePunchLibrary.punch(
            for: .uppercut,
            stance: .orthodox,
            measurements: .averageAdult,
            side: .left
        )
        let recorder = MotionRecorder()
        recorder.begin(at: 0)
        for sample in reference.samples {
            recorder.record(sample)
        }

        let attempt = recorder.finish()
        let referenceLandingHeight = try XCTUnwrap(reference.samples.map(\.fist.y).max())
        let capturedLandingHeight = try XCTUnwrap(attempt.samples.map(\.fist.y).max())

        XCTAssertEqual(capturedLandingHeight, referenceLandingHeight, accuracy: 1e-5)
        XCTAssertGreaterThan(attempt.extensionMagnitude(for: Technique.uppercut.id), 0.9)
    }

    func testFullReferenceJabScoresHighly() throws {
        let reference = ReferencePunchLibrary.punch(
            for: .jab,
            stance: .orthodox,
            measurements: .averageAdult,
            side: .left
        )
        let attempt = RecordedAttempt(
            samples: reference.samples,
            trackedFraction: 1,
            duration: reference.duration
        )

        let score = try XCTUnwrap(
            TechniqueScorer().score(
                attempt: attempt,
                reference: reference,
                technique: .jab,
                thrownSide: .left,
                stance: .orthodox
            )
        )

        XCTAssertGreaterThanOrEqual(score.overall, 74)
        XCTAssertNotNil(score.metric(.retraction)?.score)
    }

    func testOutboundOnlyAttemptDoesNotTankScoreOnRetraction() throws {
        let reference = ReferencePunchLibrary.punch(
            for: .jab,
            stance: .orthodox,
            measurements: .averageAdult,
            side: .left
        )
        let outboundSamples = reference.outboundSamples
        XCTAssertGreaterThan(outboundSamples.count, 8)

        let attempt = RecordedAttempt(
            samples: outboundSamples,
            trackedFraction: 1,
            duration: (outboundSamples.last?.time ?? 0) - (outboundSamples.first?.time ?? 0)
        )

        XCTAssertTrue(attempt.endsNearExtension())

        let score = try XCTUnwrap(
            TechniqueScorer().score(
                attempt: attempt,
                reference: reference,
                technique: .jab,
                thrownSide: .left,
                stance: .orthodox
            )
        )

        let retraction = try XCTUnwrap(score.metric(.retraction))
        XCTAssertNil(retraction.score)
        XCTAssertEqual(retraction.detail, "Retraction not captured")
        XCTAssertGreaterThanOrEqual(score.overall, 60)
    }
}

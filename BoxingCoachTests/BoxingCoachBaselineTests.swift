import XCTest
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

    func testUppercutExtensionRequiresAnOrderedRiseAfterTheHipLoad() throws {
        let reference = ReferencePunchLibrary.punch(
            for: .uppercut,
            stance: .orthodox,
            measurements: .averageAdult,
            side: .left
        )
        let loadIndex = try XCTUnwrap(
            reference.samples.indices.min(by: {
                reference.samples[$0].fist.y < reference.samples[$1].fist.y
            })
        )
        let loadOnlySamples = Array(reference.samples[...loadIndex])
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
}

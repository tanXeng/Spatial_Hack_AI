//
//  FunctionalCalibrationReportTests.swift
//  TestTests
//

import Testing
@testable import Test

struct FunctionalCalibrationReportTests {
    @Test
    func reportCollectsTwoScalarCapturesBeforeGrading() {
        let empty = FunctionalCalibrationReport.evaluate(reachMeters: [])
        #expect(empty.captureCount == 0)
        #expect(empty.grade == .collecting)
        #expect(empty.conservativeReachMeters == nil)

        let first = FunctionalCalibrationReport.evaluate(reachMeters: [0.42])
        #expect(first.captureCount == 1)
        #expect(first.grade == .collecting)
        #expect(first.absoluteSpreadMeters == nil)
    }

    @Test
    func consistentReportUsesShorterCapture() {
        let report = FunctionalCalibrationReport.evaluate(
            reachMeters: [0.44, 0.41]
        )

        #expect(report.grade == .consistent)
        #expect(report.captureCount == 2)
        #expect(abs((report.conservativeReachMeters ?? 0) - 0.41) < 0.0001)
        #expect(abs((report.absoluteSpreadMeters ?? 0) - 0.03) < 0.0001)
        #expect(report.relativeSpread != nil)
        #expect(report.permittedSpreadMeters == 0.05)
    }

    @Test
    func reportRejectsSpreadBeyondLargerProvisionalAllowance() {
        let absoluteFloorFailure = FunctionalCalibrationReport.evaluate(
            reachMeters: [0.40, 0.46]
        )
        #expect(absoluteFloorFailure.grade == .freshCaptureNeeded)
        #expect(absoluteFloorFailure.conservativeReachMeters == nil)

        // At this reach, 12% (7.2 cm) is larger than the 5 cm floor.
        let relativeAllowancePass = FunctionalCalibrationReport.evaluate(
            reachMeters: [0.60, 0.67]
        )
        #expect(relativeAllowancePass.grade == .consistent)
        #expect(abs((relativeAllowancePass.permittedSpreadMeters ?? 0) - 0.072) < 0.0001)

        let relativeAllowanceFailure = FunctionalCalibrationReport.evaluate(
            reachMeters: [0.60, 0.68]
        )
        #expect(relativeAllowanceFailure.grade == .freshCaptureNeeded)
    }
}

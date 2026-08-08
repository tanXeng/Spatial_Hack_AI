//
//  AnthropometryAssessmentTests.swift
//  TestTests
//

import Testing
@testable import Test

@MainActor
struct AnthropometryAssessmentTests {
    @Test
    func internallyConsistentMeasurementsProduceStrongGrade() {
        let profile = BoxerProfile(
            heightMeters: 1.75,
            armSpanMeters: 1.80,
            leftArmLengthMeters: 0.70,
            rightArmLengthMeters: 0.70,
            shoulderWidthMeters: 0.40
        )

        let assessment = profile.anthropometryAssessment

        #expect(assessment.qualityGrade == .strong)
        #expect(assessment.checks.count == AnthropometryCheckKind.allCases.count)
        #expect(assessment.checks.allSatisfy { $0.level == .consistent })
        #expect(abs(assessment.reconstructedArmSpanMeters - 1.80) < 0.000_001)
        #expect(abs(assessment.armSpanClosureErrorMeters) < 0.000_001)
        #expect(abs(assessment.armLengthAsymmetryMeters) < 0.000_001)
        #expect(abs(assessment.conservativeReachMeters - 0.70) < 0.000_001)
        #expect(abs(assessment.reachUncertaintyMeters - 0.02) < 0.000_001)
    }

    @Test
    func moderateClosureDisagreementIsUsableAndIncreasesUncertainty() {
        let profile = BoxerProfile(
            heightMeters: 1.75,
            armSpanMeters: 1.88,
            leftArmLengthMeters: 0.70,
            rightArmLengthMeters: 0.70,
            shoulderWidthMeters: 0.40
        )

        let assessment = profile.anthropometryAssessment

        #expect(assessment.qualityGrade == .usable)
        #expect(assessment.check(.armSpanClosure).level == .caution)
        #expect(assessment.check(.sideAsymmetry).level == .consistent)
        #expect(abs(assessment.armSpanClosureErrorMeters - 0.08) < 0.000_001)
        #expect(abs(assessment.conservativeReachMeters - 0.70) < 0.000_001)
        #expect(abs(assessment.reachUncertaintyMeters - 0.06) < 0.000_001)
    }

    @Test
    func sideDifferenceUsesShorterSideAndRequestsReview() {
        let profile = BoxerProfile(
            heightMeters: 1.76,
            armSpanMeters: 1.76,
            leftArmLengthMeters: 0.60,
            rightArmLengthMeters: 0.72,
            shoulderWidthMeters: 0.44
        )

        let assessment = profile.anthropometryAssessment

        #expect(assessment.qualityGrade == .recheck)
        #expect(assessment.check(.armSpanClosure).level == .consistent)
        #expect(assessment.check(.sideAsymmetry).level == .recheck)
        #expect(abs(assessment.armLengthAsymmetryMeters - 0.12) < 0.000_001)
        #expect(abs(assessment.conservativeReachMeters - 0.60) < 0.000_001)
        #expect(abs(assessment.reachUncertaintyMeters - 0.08) < 0.000_001)
    }

    @Test
    func broadRatioReviewDoesNotRewriteUnusualMeasurements() throws {
        let profile = BoxerProfile(
            heightMeters: 2.00,
            armSpanMeters: 1.45,
            leftArmLengthMeters: 0.55,
            rightArmLengthMeters: 0.55,
            shoulderWidthMeters: 0.35
        )

        #expect(try profile.validated() == profile)

        let assessment = profile.anthropometryAssessment
        #expect(assessment.qualityGrade == .recheck)
        #expect(assessment.check(.armSpanToHeight).level == .recheck)
        #expect(assessment.check(.armLengthToHeight).level == .caution)
        #expect(abs(assessment.armSpanToHeightRatio - 0.725) < 0.000_001)
        #expect(abs(assessment.reconstructedArmSpanMeters - profile.armSpanMeters) < 0.000_001)
    }

    @Test
    func conservativeReachSelectsShortestIndependentProxy() {
        let profile = BoxerProfile(
            heightMeters: 1.80,
            armSpanMeters: 1.70,
            leftArmLengthMeters: 0.72,
            rightArmLengthMeters: 0.74,
            shoulderWidthMeters: 0.40
        )

        let assessment = profile.anthropometryAssessment

        // Span-derived reach is (1.70 - 0.40) / 2 = 0.65 m.
        #expect(abs(assessment.conservativeReachMeters - 0.65) < 0.000_001)
        #expect(assessment.conservativeReachMeters < profile.leftArmLengthMeters)
        #expect(assessment.conservativeReachMeters < profile.rightArmLengthMeters)
    }

    @Test
    func uncertaintyIsBoundedForNoisyButAcceptedProfile() throws {
        let profile = BoxerProfile(
            heightMeters: 1.70,
            armSpanMeters: 1.76,
            leftArmLengthMeters: 0.61,
            rightArmLengthMeters: 0.78,
            shoulderWidthMeters: 0.58
        )

        #expect(try profile.validated() == profile)
        #expect(abs(profile.anthropometryAssessment.reachUncertaintyMeters - 0.15) < 0.000_001)
    }

    @Test
    func assessmentIsDeterministicAndDoesNotDependOnLiveReach() {
        let manualOnly = BoxerProfile(
            heightMeters: 1.76,
            armSpanMeters: 1.81,
            leftArmLengthMeters: 0.69,
            rightArmLengthMeters: 0.71,
            shoulderWidthMeters: 0.44
        )
        var liveCalibrated = manualOnly
        liveCalibrated.measuredComfortableReachMeters = 0.56

        #expect(manualOnly.anthropometryAssessment == manualOnly.anthropometryAssessment)
        #expect(manualOnly.anthropometryAssessment == liveCalibrated.anthropometryAssessment)
    }
}

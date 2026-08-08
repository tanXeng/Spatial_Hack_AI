//
//  AuraPunchEngine.swift
//  Test
//
//  Deterministic, hand-only guidance and scoring for a short Aura Punch set.
//  The engine consumes explicit ticks and hand samples; it never owns an
//  AsyncStream or makes full-body technique claims.
//

import Foundation
import Observation
import simd

enum AuraPunchPhase: Equatable, Sendable {
    case idle
    case demonstrating
    case following
    case paused
    case completed
}

struct AuraPunchGuide: Equatable, Sendable {
    let punch: PunchKind
    let hand: HandSide
    let guardPosition: SIMD3<Float>
    let targetPosition: SIMD3<Float>

    var pathLength: Float {
        let points = sampledOutboundPath(pointCount: 33)
        return zip(points, points.dropFirst()).reduce(0) {
            $0 + simd_length($1.1 - $1.0)
        }
    }

    private var uppercutControlPosition: SIMD3<Float> {
        var control = guardPosition + (targetPosition - guardPosition) * 0.42
        // Keep this coordinate-frame agnostic. The calibrated guard/target
        // delta already contains the user's inward and forward directions;
        // assigning world X directly would break when the user faces another
        // direction in the room.
        control.y = min(guardPosition.y, targetPosition.y) - 0.055
        return control
    }

    func outboundPosition(at progress: Float) -> SIMD3<Float> {
        let t = min(1, max(0, progress))
        switch punch {
        case .jab, .cross:
            return guardPosition + (targetPosition - guardPosition) * t
        case .leftUppercut, .rightUppercut:
            // Quadratic Bézier: move inward beneath the centerline, then rise
            // through the target. The endpoint is body-centered by
            // CalibrationProfile.targetPosition(for:configuration:).
            let inverse = 1 - t
            return guardPosition * (inverse * inverse)
                + uppercutControlPosition * (2 * inverse * t)
                + targetPosition * (t * t)
        }
    }

    /// Maps a complete 0...1 demonstration cycle to an out-and-back path.
    func position(at progress: Double) -> SIMD3<Float> {
        let boundedProgress = Float(min(1, max(0, progress)))
        let outboundProgress = boundedProgress <= 0.5
            ? boundedProgress * 2
            : (1 - boundedProgress) * 2
        return outboundPosition(at: outboundProgress)
    }

    func sampledPath(pointCount: Int = 25) -> [SIMD3<Float>] {
        let resolvedCount = max(2, pointCount)
        return (0..<resolvedCount).map { index in
            position(at: Double(index) / Double(resolvedCount - 1))
        }
    }

    func sampledOutboundPath(pointCount: Int = 25) -> [SIMD3<Float>] {
        let resolvedCount = max(2, pointCount)
        return (0..<resolvedCount).map { index in
            outboundPosition(
                at: Float(index) / Float(resolvedCount - 1)
            )
        }
    }

    func match(_ position: SIMD3<Float>) -> (distance: Float, progress: Float) {
        let points = sampledOutboundPath(pointCount: 33)
        var bestDistance = Float.greatestFiniteMagnitude
        var bestProgress: Float = 0

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let segment = end - start
            let lengthSquared = simd_length_squared(segment)
            let fraction: Float
            if lengthSquared > Float.ulpOfOne {
                fraction = min(
                    1,
                    max(0, simd_dot(position - start, segment) / lengthSquared)
                )
            } else {
                fraction = 0
            }
            let closest = start + segment * fraction
            let distance = simd_length(position - closest)
            if distance < bestDistance {
                bestDistance = distance
                bestProgress = (Float(index) + fraction)
                    / Float(points.count - 1)
            }
        }
        return (bestDistance, bestProgress)
    }

    var departureDirection: SIMD3<Float> {
        let direction = outboundPosition(at: 0.12) - guardPosition
        let length = simd_length(direction)
        return length > 0.000_1 ? direction / length : SIMD3<Float>(0, 0, -1)
    }
}

struct AuraPunchRepetitionResult: Identifiable, Equatable, Sendable {
    let repetition: Int
    let punch: PunchKind
    let expectedHand: HandSide
    let startedAt: TimeInterval
    let completedAt: TimeInterval
    let averagePathDeviation: Float
    let pathScore: Double
    let extensionRatio: Double
    let extensionScore: Double
    let peakSpeed: Float
    let relativePeakSpeed: Double
    let speedScore: Double
    let otherHandGuardScore: Double
    /// Uppercut-only cue based on visionOS's processed forearm joints.
    let forearmAlignmentScore: Double?
    /// Fraction of captured frames that could be normalized against the
    /// estimated shoulder anchor derived from the device pose.
    let shoulderReferenceCoverage: Double
    /// Speed-invariant, fail-closed comparison of this observed fist trace to
    /// the current calibrated guide. Diagnostic only; never part of scoring.
    let trajectoryShapeScore: Double?
    let overallScore: Double

    var id: Int { repetition }
}

struct AuraPunchSummary: Equatable, Sendable {
    let punch: PunchKind
    let expectedHand: HandSide
    let difficulty: TrainingDifficulty
    let completedRepetitions: Int
    let repetitionGoal: Int
    let averageScore: Double
    let averagePathScore: Double
    /// Bounded guide-depth control score. Unlike the raw ratio, this preserves
    /// the penalty for both underextension and overextension in summaries.
    let averageExtensionScore: Double
    /// Raw peak depth relative to the guide, retained as a diagnostic ratio.
    let averageExtensionRatio: Double
    let averageRelativePeakSpeed: Double
    let averageOtherHandGuardScore: Double
    let averageForearmAlignmentScore: Double?
    let averageShoulderReferenceCoverage: Double
    let averageTrajectoryShapeScore: Double?

    init(
        results: [AuraPunchRepetitionResult],
        repetitionGoal: Int,
        difficulty: TrainingDifficulty = .defaultValue,
        trackingInterruptions: Int = 0
    ) {
        precondition(!results.isEmpty)
        punch = results[0].punch
        expectedHand = results[0].expectedHand
        self.difficulty = difficulty
        completedRepetitions = results.count
        self.repetitionGoal = repetitionGoal
        self.trackingInterruptions = trackingInterruptions
        averageScore = Self.average(results.map(\.overallScore))
        averagePathScore = Self.average(results.map(\.pathScore))
        averageExtensionScore = Self.average(results.map(\.extensionScore))
        averageExtensionRatio = Self.average(results.map(\.extensionRatio))
        averageRelativePeakSpeed = Self.average(results.map(\.relativePeakSpeed))
        averageOtherHandGuardScore = Self.average(
            results.map(\.otherHandGuardScore)
        )
        let forearmScores = results.compactMap(\.forearmAlignmentScore)
        averageForearmAlignmentScore = forearmScores.isEmpty
            ? nil
            : Self.average(forearmScores)
        averageShoulderReferenceCoverage = Self.average(
            results.map(\.shoulderReferenceCoverage)
        )
        let trajectoryScores = results.compactMap(\.trajectoryShapeScore)
        // A set-level diagnostic is available only with complete coverage.
        // Never let one accepted trace stand in for repetitions that failed
        // the continuity/sample validation contract.
        averageTrajectoryShapeScore = trajectoryScores.count == results.count
            ? Self.average(trajectoryScores)
            : nil
    }

    let trackingInterruptions: Int

    private static func average(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }
}

@MainActor
@Observable
final class AuraPunchEngine {
    private struct AttemptCapture {
        let startedAt: TimeInterval
        var previousPosition: SIMD3<Float>
        var previousTimestamp: TimeInterval
        var pathDeviationTotal: Float = 0
        var pathPointCount = 0
        var maximumExtensionRatio: Float = 0
        var peakSpeed: Float = 0
        var otherHandDeviationTotal: Float = 0
        var otherHandSampleCount = 0
        var trajectorySamples: [FistTrajectorySample] = []
        var initialShoulderPosition: SIMD3<Float>?
        var shoulderReferencedSampleCount = 0
        var forearmAlignmentTotal: Float = 0
        var forearmAlignmentSampleCount = 0
    }

    let configuration: DrillConfiguration
    let repetitionGoal = 3
    let demonstrationDuration: TimeInterval

    var selectedPunch: PunchKind {
        didSet {
            guard selectedPunch != oldValue, phase != .idle else { return }
            stop(preservingCompletedResults: false)
            instruction = "Punch selection changed. Start a fresh Aura Punch set."
        }
    }

    private(set) var phase: AuraPunchPhase = .idle
    private(set) var instruction = "Choose a punch, then start Aura Punch."
    private(set) var feedback: String?
    private(set) var guideProgress: Double = 0
    private(set) var repetitionResults: [AuraPunchRepetitionResult] = []
    private(set) var summary: AuraPunchSummary?
    private(set) var calibrationProfile: CalibrationProfile?
    private(set) var activeDifficulty: TrainingDifficulty = .defaultValue
    private(set) var trackingInterruptionCount = 0

    @ObservationIgnored private var demonstrationStartedAt: TimeInterval?
    @ObservationIgnored private var phaseBeforePause: AuraPunchPhase?
    @ObservationIgnored private var guardObserved = false
    @ObservationIgnored private var previousExpectedPose: HandPose?
    @ObservationIgnored private var activeCapture: AttemptCapture?
    @ObservationIgnored private var shoulderWidthMeters: Float = 0.38

    init(
        selectedPunch: PunchKind = .jab,
        configuration: DrillConfiguration? = nil,
        demonstrationDuration: TimeInterval = 2.0
    ) {
        self.selectedPunch = selectedPunch
        self.configuration = configuration ?? .provisional
        self.demonstrationDuration = max(0.1, demonstrationDuration)
    }

    var results: [AuraPunchRepetitionResult] {
        repetitionResults
    }

    var guide: AuraPunchGuide? {
        guard let calibrationProfile else { return nil }
        let hand = calibrationProfile.hand(for: selectedPunch)
        return AuraPunchGuide(
            punch: selectedPunch,
            hand: hand,
            guardPosition: calibrationProfile.guardPosition(for: hand),
            targetPosition: calibrationProfile.targetPosition(
                for: selectedPunch,
                configuration: configuration
            )
        )
    }

    var expectedHand: HandSide? {
        guide?.hand
    }

    var currentGuidePosition: SIMD3<Float>? {
        guidePosition(at: guideProgress)
    }

    var activeDemonstrationDuration: TimeInterval {
        demonstrationDuration
            * activeDifficulty.presentation.auraDemonstrationMultiplier
    }

    var activePathPointCount: Int {
        activeDifficulty.presentation.auraPathPointCount
    }

    /// Visual guidance is an active-motion affordance. It must disappear while
    /// paused so tracking loss or a system interruption never leaves a target
    /// that invites an unobserved punch.
    var shouldPresentGuide: Bool {
        phase == .demonstrating || phase == .following
    }

    func guidePosition(at progress: Double) -> SIMD3<Float>? {
        guide?.position(at: progress)
    }

    func guidePath(pointCount: Int = 25) -> [SIMD3<Float>] {
        guide?.sampledPath(pointCount: pointCount) ?? []
    }

    func pathDeviation(of position: SIMD3<Float>) -> Float? {
        guard let guide else { return nil }
        return guide.match(position).distance
    }

    func start(
        using profile: CalibrationProfile,
        at timestamp: TimeInterval,
        difficulty: TrainingDifficulty = .defaultValue,
        shoulderWidthMeters: Double? = nil,
        trackingReady: Bool = true
    ) {
        guard trackingReady else {
            instruction = "Both hands must be tracked before Aura Punch can start."
            feedback = "Return both hands to guard, then start the guide."
            return
        }

        calibrationProfile = profile
        self.shoulderWidthMeters = Float(
            min(0.75, max(0.18, shoulderWidthMeters ?? 0.38))
        )
        activeDifficulty = difficulty
        trackingInterruptionCount = 0
        repetitionResults = []
        summary = nil
        guideProgress = 0
        feedback = nil
        demonstrationStartedAt = timestamp
        phaseBeforePause = nil
        resetPartialRepetition(requireFreshGuard: true)

        guard let guide, guide.pathLength > Float.ulpOfOne else {
            stop(preservingCompletedResults: false)
            feedback = "Aura Punch needs a valid hand-reach calibration."
            return
        }

        phase = .demonstrating
        instruction = "Watch the \(selectedPunch.title.lowercased()) hand guide travel out and back."
    }

    func tick(at timestamp: TimeInterval) {
        guard phase == .demonstrating,
              let demonstrationStartedAt else {
            return
        }

        let elapsed = max(0, timestamp - demonstrationStartedAt)
        guideProgress = min(1, elapsed / activeDemonstrationDuration)

        guard guideProgress >= 1 else { return }

        phase = .following
        resetPartialRepetition(requireFreshGuard: true)
        instruction = "Start at guard, trace the hand guide, then return the fist to guard."
        feedback = "Show the expected hand at its calibrated guard to begin."
    }

    func ingest(
        _ sample: HandSample,
        devicePose: DevicePoseSample? = nil
    ) {
        guard phase == .following, let guide else { return }

        guard let expectedPose = sample.pose(for: guide.hand) else {
            resetPartialRepetition(requireFreshGuard: true)
            instruction = "Make the expected hand visible and return it to guard."
            feedback = "Partial repetition cleared because the punch hand was not tracked."
            return
        }

        if let previousExpectedPose,
           expectedPose.capturedAt <= previousExpectedPose.capturedAt {
            return
        }

        if let priorExpectedPose = previousExpectedPose,
           expectedPose.capturedAt - priorExpectedPose.capturedAt
                > configuration.maximumSampleInterval {
            let position = expectedPose.fistCenter
            let isAtGuard = simd_length(position - guide.guardPosition)
                <= configuration.guardReturnRadius
            resetPartialRepetition(requireFreshGuard: true)
            previousExpectedPose = expectedPose
            guardObserved = isAtGuard
            instruction = isAtGuard
                ? "Tracking continuity restarted at guard. Follow the guide when ready."
                : "Tracking continuity was lost. Return the expected hand to guard."
            feedback = "The partial repetition was cleared after a tracking gap."
            return
        }

        let position = expectedPose.fistCenter
        let distanceToGuard = simd_length(position - guide.guardPosition)
        let isAtGuard = distanceToGuard <= configuration.guardReturnRadius

        if var capture = activeCapture {
            add(
                position: position,
                timestamp: expectedPose.capturedAt,
                otherHandPose: sample.pose(for: Self.otherHand(guide.hand)),
                expectedHandPose: expectedPose,
                devicePose: devicePose,
                guide: guide,
                to: &capture
            )
            activeCapture = capture
            previousExpectedPose = expectedPose

            guard isAtGuard else { return }

            if capture.maximumExtensionRatio >= minimumCompletionExtensionRatio(
                for: guide
            ) {
                completeRepetition(capture, completedAt: expectedPose.capturedAt, guide: guide)
            } else {
                activeCapture = nil
                guardObserved = true
                feedback = "Extend farther along the guide before returning to guard."
                instruction = "That motion was not counted. Begin the next attempt from guard."
            }
            return
        }

        guard guardObserved else {
            previousExpectedPose = expectedPose
            if isAtGuard {
                guardObserved = true
                feedback = "Guard observed. Follow the \(selectedPunch.rawValue) guide when ready."
                instruction = "Extend along the guide and return to guard to record the repetition."
            } else {
                feedback = "Place the expected hand at its calibrated guard."
            }
            return
        }

        guard !isAtGuard else {
            previousExpectedPose = expectedPose
            return
        }

        let outwardProjection = simd_dot(
            position - guide.guardPosition,
            guide.departureDirection
        )
        let requiredDeparture = configuration.minimumGuardDeparture
            * configuration.minimumForwardRatio

        guard distanceToGuard >= configuration.minimumGuardDeparture,
              outwardProjection >= requiredDeparture else {
            previousExpectedPose = expectedPose
            feedback = "Move the punch hand forward along the guide."
            return
        }

        var capture = AttemptCapture(
            startedAt: previousExpectedPose?.capturedAt ?? expectedPose.capturedAt,
            previousPosition: previousExpectedPose?.fistCenter ?? guide.guardPosition,
            previousTimestamp: previousExpectedPose?.capturedAt ?? expectedPose.capturedAt
        )
        addInitialPoint(
            capture.previousPosition,
            guide: guide,
            to: &capture
        )
        add(
            position: position,
            timestamp: expectedPose.capturedAt,
            otherHandPose: sample.pose(for: Self.otherHand(guide.hand)),
            expectedHandPose: expectedPose,
            devicePose: devicePose,
            guide: guide,
            to: &capture
        )
        activeCapture = capture
        previousExpectedPose = expectedPose
        instruction = "Continue through the guide, then bring the fist back to guard."
        feedback = nil
    }

    func pause(reason: String) {
        guard phase == .demonstrating || phase == .following else { return }

        trackingInterruptionCount += 1
        phaseBeforePause = phase
        phase = .paused
        resetPartialRepetition(requireFreshGuard: true)
        instruction = "Aura Punch paused."
        feedback = reason.isEmpty ? "Training paused." : reason
    }

    func resume(at timestamp: TimeInterval) {
        guard phase == .paused, let phaseBeforePause else { return }

        self.phaseBeforePause = nil
        resetPartialRepetition(requireFreshGuard: true)

        switch phaseBeforePause {
        case .demonstrating:
            demonstrationStartedAt = timestamp
                - guideProgress * activeDemonstrationDuration
            phase = .demonstrating
            instruction = "Continue watching the out-and-back hand guide."
            feedback = nil
        case .following:
            phase = .following
            instruction = "Return the expected hand to guard before continuing."
            feedback = "The partial repetition was cleared during the pause."
        default:
            stop(preservingCompletedResults: false)
        }
    }

    func stop(preservingCompletedResults: Bool = true) {
        if preservingCompletedResults,
           phase == .completed,
           summary != nil {
            return
        }
        phase = .idle
        instruction = "Choose a punch, then start Aura Punch."
        feedback = nil
        guideProgress = 0
        repetitionResults = []
        summary = nil
        calibrationProfile = nil
        demonstrationStartedAt = nil
        phaseBeforePause = nil
        resetPartialRepetition(requireFreshGuard: true)
    }

    /// Calibration is tied to an immersive-space origin and never survives it.
    /// A finished summary remains available for the normal-window results view.
    func leaveImmersiveSpace() {
        let completedResults = repetitionResults
        let completedSummary = summary
        let shouldPreserveResults = phase == .completed && completedSummary != nil

        stop(preservingCompletedResults: false)

        guard shouldPreserveResults else { return }
        repetitionResults = completedResults
        summary = completedSummary
        guideProgress = 1
        phase = .completed
        instruction = "Training space closed. Review the hand-path results."
    }

    private func addInitialPoint(
        _ position: SIMD3<Float>,
        guide: AuraPunchGuide,
        to capture: inout AttemptCapture
    ) {
        capture.pathDeviationTotal += guide.match(position).distance
        capture.pathPointCount += 1
        capture.trajectorySamples.append(FistTrajectorySample(
            timestamp: capture.previousTimestamp,
            position: position
        ))
    }

    private func add(
        position: SIMD3<Float>,
        timestamp: TimeInterval,
        otherHandPose: HandPose?,
        expectedHandPose: HandPose,
        devicePose: DevicePoseSample?,
        guide: AuraPunchGuide,
        to capture: inout AttemptCapture
    ) {
        var scoringPosition = position
        var shoulderDelta = SIMD3<Float>.zero
        if let shoulder = Self.estimatedShoulderPosition(
            for: guide.hand,
            devicePose: devicePose,
            shoulderWidthMeters: shoulderWidthMeters
        ) {
            if capture.initialShoulderPosition == nil {
                capture.initialShoulderPosition = shoulder
            }
            if let initialShoulderPosition = capture.initialShoulderPosition {
                shoulderDelta = shoulder - initialShoulderPosition
                scoringPosition -= shoulderDelta
                capture.shoulderReferencedSampleCount += 1
            }
        }

        let match = guide.match(scoringPosition)
        let deviation = match.distance
        capture.pathDeviationTotal += deviation
        capture.pathPointCount += 1
        if capture.trajectorySamples.count < 512 {
            capture.trajectorySamples.append(FistTrajectorySample(
                timestamp: timestamp,
                position: scoringPosition
            ))
        }

        capture.maximumExtensionRatio = max(
            capture.maximumExtensionRatio,
            match.progress
        )

        let deltaTime = timestamp - capture.previousTimestamp
        if deltaTime > 0,
           deltaTime <= configuration.maximumSampleInterval {
            let velocity = (scoringPosition - capture.previousPosition)
                / Float(deltaTime)
            let pathSpeed = simd_length(velocity)
            capture.peakSpeed = max(capture.peakSpeed, pathSpeed)
        }

        if guide.punch.isUppercut,
           match.progress >= 0.45,
           let forearmArm = expectedHandPose.forearmArm,
           let forearmWrist = expectedHandPose.forearmWrist {
            let forearm = forearmWrist - forearmArm
            let forearmLength = simd_length(forearm)
            if forearmLength > 0.000_1 {
                let upwardAlignment = simd_dot(
                    forearm / forearmLength,
                    SIMD3<Float>(0, 1, 0)
                )
                capture.forearmAlignmentTotal += max(-1, min(1, upwardAlignment))
                capture.forearmAlignmentSampleCount += 1
            }
        }

        let otherGuard = calibrationProfile?.guardPosition(
            for: Self.otherHand(guide.hand)
        )
        let missingPenalty = configuration.guardReturnRadius * 2
        var otherDeviation = missingPenalty
        if let otherHandPose, let otherGuard {
            let otherHandAge = timestamp - otherHandPose.capturedAt
            if otherHandAge >= 0,
               otherHandAge <= configuration.maximumSampleInterval {
                otherDeviation = simd_length(
                    (otherHandPose.fistCenter - shoulderDelta) - otherGuard
                )
            }
        }
        capture.otherHandDeviationTotal += otherDeviation
        capture.otherHandSampleCount += 1
        capture.previousPosition = scoringPosition
        capture.previousTimestamp = timestamp
    }

    private func completeRepetition(
        _ capture: AttemptCapture,
        completedAt: TimeInterval,
        guide: AuraPunchGuide
    ) {
        let pathPointCount = max(1, capture.pathPointCount)
        let averagePathDeviation = capture.pathDeviationTotal
            / Float(pathPointCount)
        let pathTolerance = max(
            0.06,
            max(configuration.targetRadius * 1.5, guide.pathLength * 0.25)
        )
        let pathScore = Self.clampedUnit(
            1 - Double(averagePathDeviation / pathTolerance)
        )

        let extensionRatio = Double(max(0, capture.maximumExtensionRatio))
        let extensionScore = Self.clampedUnit(
            1 - abs(extensionRatio - 1) / 0.50
        )

        let referenceSpeed = max(
            calibrationProfile?.referenceProjectedPace(for: guide.hand) ?? 0,
            configuration.minimumReferenceSpeed
        )
        let relativePeakSpeed = Double(capture.peakSpeed / referenceSpeed)
        let speedScore = Self.clampedUnit(relativePeakSpeed)

        let otherSampleCount = max(1, capture.otherHandSampleCount)
        let averageOtherDeviation = capture.otherHandDeviationTotal
            / Float(otherSampleCount)
        let guardTolerance = max(0.08, configuration.guardReturnRadius * 2)
        let otherHandGuardScore = Self.clampedUnit(
            1 - Double(averageOtherDeviation / guardTolerance)
        )
        let shoulderReferenceCoverage = Self.clampedUnit(
            Double(capture.shoulderReferencedSampleCount)
                / Double(pathPointCount)
        )
        let forearmAlignmentScore: Double?
        if guide.punch.isUppercut,
           capture.forearmAlignmentSampleCount >= 2 {
            let averageAlignment = capture.forearmAlignmentTotal
                / Float(capture.forearmAlignmentSampleCount)
            forearmAlignmentScore = Self.clampedUnit(
                (Double(averageAlignment) - 0.15) / 0.75
            )
        } else {
            forearmAlignmentScore = nil
        }
        let trajectoryShapeScore = trajectoryDiagnostic(
            for: capture,
            guide: guide
        )?.shapeScore

        // Pace is retained as a diagnostic ratio, but it is deliberately not
        // rewarded. Vision Pro safety calls for controlled movement, and the
        // hand-specific reference exists to describe pace, not incentivize it.
        let overallScore: Double
        if let forearmAlignmentScore {
            overallScore = pathScore * 0.35
                + extensionScore * 0.25
                + otherHandGuardScore * 0.20
                + forearmAlignmentScore * 0.20
        } else {
            overallScore = pathScore * 0.45
                + extensionScore * 0.30
                + otherHandGuardScore * 0.25
        }

        let result = AuraPunchRepetitionResult(
            repetition: repetitionResults.count + 1,
            punch: selectedPunch,
            expectedHand: guide.hand,
            startedAt: capture.startedAt,
            completedAt: completedAt,
            averagePathDeviation: averagePathDeviation,
            pathScore: pathScore,
            extensionRatio: extensionRatio,
            extensionScore: extensionScore,
            peakSpeed: capture.peakSpeed,
            relativePeakSpeed: relativePeakSpeed,
            speedScore: speedScore,
            otherHandGuardScore: otherHandGuardScore,
            forearmAlignmentScore: forearmAlignmentScore,
            shoulderReferenceCoverage: shoulderReferenceCoverage,
            trajectoryShapeScore: trajectoryShapeScore,
            overallScore: overallScore
        )
        repetitionResults.append(result)
        activeCapture = nil
        guardObserved = true

        guard repetitionResults.count >= repetitionGoal else {
            let percent = Int((overallScore * 100).rounded())
            instruction = "Repetition \(repetitionResults.count) of \(repetitionGoal) recorded. Begin the next one from guard."
            feedback = feedbackText(score: overallScore, percent: percent)
            return
        }

        summary = AuraPunchSummary(
            results: repetitionResults,
            repetitionGoal: repetitionGoal,
            difficulty: activeDifficulty,
            trackingInterruptions: trackingInterruptionCount
        )
        phase = .completed
        let averagePercent = Int(((summary?.averageScore ?? 0) * 100).rounded())
        instruction = "Aura Punch set complete. Review the hand-path metrics."
        feedback = "Three repetitions complete · \(averagePercent)% average score."
        activeCapture = nil
        previousExpectedPose = nil
    }

    private func trajectoryDiagnostic(
        for capture: AttemptCapture,
        guide: AuraPunchGuide
    ) -> TrajectoryShapeDiagnostic? {
        let reference = guide.sampledPath(pointCount: 25).enumerated().map {
            FistTrajectorySample(
                timestamp: Double($0.offset) * 0.02,
                position: $0.element
            )
        }
        let result = FistTrajectoryAlignment.compare(
            reference: reference,
            referenceGuard: guide.guardPosition,
            referenceReach: guide.pathLength,
            attempt: capture.trajectorySamples,
            attemptGuard: guide.guardPosition,
            attemptReach: guide.pathLength,
            configuration: TrajectoryAlignmentConfiguration(
                maximumSampleGap: configuration.maximumSampleInterval
            )
        )
        guard case .success(let diagnostic) = result else { return nil }
        return diagnostic
    }

    private func feedbackText(score: Double, percent: Int) -> String {
        if score >= 0.85 {
            return "Clean hand path · \(percent)%"
        }
        if score >= 0.65 {
            return "Repetition recorded · \(percent)%"
        }
        return "Keep the guide line and guard hand steady · \(percent)%"
    }

    private func minimumCompletionExtensionRatio(
        for guide: AuraPunchGuide
    ) -> Float {
        let absoluteMinimum = configuration.minimumPunchTravel
            / max(guide.pathLength, Float.ulpOfOne)
        return min(0.95, max(0.72, absoluteMinimum))
    }

    private func resetPartialRepetition(requireFreshGuard: Bool) {
        activeCapture = nil
        previousExpectedPose = nil
        if requireFreshGuard {
            guardObserved = false
        }
    }

    private static func otherHand(_ hand: HandSide) -> HandSide {
        hand == .left ? .right : .left
    }

    private static func clampedUnit(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    /// visionOS doesn't expose a shoulder joint. This reference estimates the
    /// shoulder from the headset pose and configured shoulder width so guide
    /// placement and path comparison remain body-relative during small torso
    /// translations. It must never be presented as a measured shoulder pose.
    private static func estimatedShoulderPosition(
        for hand: HandSide,
        devicePose: DevicePoseSample?,
        shoulderWidthMeters: Float
    ) -> SIMD3<Float>? {
        guard let devicePose else { return nil }
        var right = devicePose.rightDirection
        right.y = 0
        let rightLength = simd_length(right)
        guard rightLength.isFinite, rightLength > 0.000_1 else { return nil }
        right /= rightLength

        let shoulderCenter = devicePose.position + SIMD3<Float>(0, -0.235, 0)
        let side: Float = hand == .left ? -1 : 1
        return shoulderCenter + right * (shoulderWidthMeters * 0.5 * side)
    }

}

//
//  BoardTargetTests.swift
//  TestTests
//

import Foundation
import Testing
import simd
@testable import Test

@MainActor
struct BoardTargetTests {
    @Test
    func boardContainsSixTargetsInAlternatingJabCrossOrder() {
        let engine = RoundEngine(configuration: testConfiguration())

        #expect(engine.boardTargetCount == 6)
        #expect(
            (0..<engine.boardTargetCount).map(engine.expectedPunch(forBoardTarget:))
                == [.jab, .cross, .jab, .cross, .jab, .cross]
        )

        // The cue sequence intentionally wraps around the board.
        #expect(engine.expectedPunch(forBoardTarget: 6) == .jab)
        #expect(engine.expectedPunch(forBoardTarget: 7) == .cross)
        #expect(engine.expectedPunch(forBoardTarget: -1) == .cross)
    }

    @Test
    func calibratedBoardPositionsAreFiniteAndPairwiseDistinct() {
        let engine = calibratedEngine()
        let positions = (0..<engine.boardTargetCount).map(engine.boardTargetPosition(at:))

        #expect(engine.isCalibrated)
        #expect(positions.count == 6)

        for position in positions {
            #expect(position.x.isFinite)
            #expect(position.y.isFinite)
            #expect(position.z.isFinite)
        }

        for firstIndex in positions.indices {
            for secondIndex in positions.indices where secondIndex > firstIndex {
                #expect(
                    simd_distance(positions[firstIndex], positions[secondIndex]) > 0.0001
                )
            }
        }
    }

    @Test
    func onlyTheCurrentCueRoutesToTheActiveBoardPad() async throws {
        var configuration = testConfiguration()
        configuration.countdownDuration = 0
        configuration.roundDuration = 3
        configuration.cueDuration = 1
        let engine = calibratedEngine(configuration: configuration)

        engine.startRound()
        defer { engine.stop() }

        for _ in 0..<20 where !engine.cueIsVisuallyActive {
            try await Task.sleep(for: .milliseconds(25))
        }

        let cue = try #require(engine.activeCue)
        #expect(engine.cueIsVisuallyActive)

        let activeIndex = cue.sequenceIndex % engine.boardTargetCount
        #expect(engine.expectedPunch(forBoardTarget: activeIndex) == cue.expectedPunch)

        for index in 0..<engine.boardTargetCount {
            let expectedState: MittVisualState = index == activeIndex ? .active : .inactive
            #expect(engine.visualState(forBoardTarget: index) == expectedState)
        }
    }

    private func calibratedEngine(
        configuration: DrillConfiguration? = nil
    ) -> RoundEngine {
        let engine = RoundEngine(configuration: configuration ?? testConfiguration())
        let start: TimeInterval = 100

        engine.setTrackingState(.tracking(handCount: 2))
        engine.startGuardCalibration()
        engine.ingest(sample(timestamp: start))
        engine.ingest(sample(timestamp: start + 0.11))
        #expect(engine.phase == .awaitingReach)

        engine.startReachCalibration()
        engine.ingest(sample(timestamp: start + 0.20))
        engine.ingest(sample(
            timestamp: start + 0.25,
            left: leftGuard + SIMD3<Float>(0, 0, -0.20)
        ))
        engine.ingest(sample(timestamp: start + 0.30))
        engine.ingest(sample(
            timestamp: start + 0.35,
            left: leftGuard + SIMD3<Float>(0, 0, -0.19)
        ))
        engine.ingest(sample(timestamp: start + 0.40))
        engine.ingest(sample(
            timestamp: start + 0.45,
            right: rightGuard + SIMD3<Float>(0, 0, -0.21)
        ))
        engine.ingest(sample(timestamp: start + 0.50))
        engine.ingest(sample(
            timestamp: start + 0.55,
            right: rightGuard + SIMD3<Float>(0, 0, -0.20)
        ))
        engine.ingest(sample(timestamp: start + 0.60))
        #expect(engine.phase == .ready)
        return engine
    }

    private func testConfiguration() -> DrillConfiguration {
        var configuration = DrillConfiguration.provisional
        configuration.guardHoldDuration = 0.10
        configuration.reachCaptureDuration = 0.30
        configuration.minimumComfortableReach = 0.12
        configuration.maximumGuardSpeed = 0.50
        configuration.resumeGuardHoldDuration = 0.05
        return configuration
    }

    private var leftGuard: SIMD3<Float> {
        SIMD3<Float>(-0.10, 1.30, -0.35)
    }

    private var rightGuard: SIMD3<Float> {
        SIMD3<Float>(0.10, 1.30, -0.35)
    }

    private func sample(
        timestamp: TimeInterval,
        left: SIMD3<Float>? = nil,
        right: SIMD3<Float>? = nil
    ) -> HandSample {
        let leftPosition = left ?? leftGuard
        let rightPosition = right ?? rightGuard
        return HandSample(
            timestamp: timestamp,
            left: HandPose(
                fistCenter: leftPosition,
                wrist: nil,
                trackedKnuckleCount: 4,
                capturedAt: timestamp
            ),
            right: HandPose(
                fistCenter: rightPosition,
                wrist: nil,
                trackedKnuckleCount: 4,
                capturedAt: timestamp
            )
        )
    }
}

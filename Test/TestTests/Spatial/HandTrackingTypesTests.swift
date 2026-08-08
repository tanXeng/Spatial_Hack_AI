//
//  HandTrackingTypesTests.swift
//  TestTests
//

import Testing
@testable import Test

@MainActor
struct HandTrackingTypesTests {
    @Test
    func markerIdentifierIncludesSideAndJoint() {
        let marker = HandMarker(
            side: .left,
            kind: .indexKnuckle,
            position: SIMD3<Float>(0.1, 0.2, -0.3)
        )

        #expect(marker.id == "left.indexKnuckle")
    }

    /// Fingertip joints stop being reported by a closed fist, so drawing them
    /// made a correct boxing guard look untracked.
    @Test
    func diagnosticMarkersFollowTheFistRatherThanFingertips() {
        #expect(HandMarkerKind.allCases.count == 5)
        #expect(!HandMarkerKind.allCases.contains { $0.rawValue.hasSuffix("Tip") })
    }

    @Test
    func trackedHandCountDistinguishesOneHandFromNone() {
        #expect(HandTrackingState.tracking(handCount: 2).trackedHandCount == 2)
        #expect(HandTrackingState.tracking(handCount: 1).trackedHandCount == 1)
        #expect(HandTrackingState.trackingLost.trackedHandCount == 0)
        #expect(HandTrackingState.waitingForHands.trackedHandCount == 0)
    }

    @Test
    func trackingLossIsPresentedAsPaused() {
        #expect(HandTrackingState.trackingLost.title == "Tracking lost — paused")
        #expect(HandTrackingState.trackingLost.detail.contains("hidden for safety"))
    }

    @Test
    func simulatorFallbackExplainsTheDeviceRequirement() {
        #expect(HandTrackingState.simulatorUnavailable.title == "Simulator fallback")
        #expect(HandTrackingState.simulatorUnavailable.detail.contains("Apple Vision Pro"))
    }

    @Test
    func stoppingAfterConsumerCancellationCreatesAUsableStreamForReentry() async {
        let service = HandTrackingService()
        let firstSessionStream = service.samples
        let firstConsumer = Task {
            for await _ in firstSessionStream {}
        }

        await Task.yield()
        firstConsumer.cancel()
        await firstConsumer.value

        service.stop()
        let reentryStream = service.samples

        // A subsequent stop publishes one final empty sample to the current
        // session before finishing it. Receiving that sample proves re-entry
        // did not inherit the first consumer's permanently cancelled stream.
        service.stop()
        var iterator = reentryStream.makeAsyncIterator()
        let finalSample = await iterator.next()

        #expect(finalSample != nil)
        #expect(finalSample?.left == nil)
        #expect(finalSample?.right == nil)
        #expect(await iterator.next() == nil)
    }
}

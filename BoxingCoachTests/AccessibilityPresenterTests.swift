import CoreGraphics
import Testing
@testable import BoxingCoach

@Suite("Training accessibility presentation")
struct AccessibilityPresenterTests {
    @Test("Announcements are semantic, deduplicated, and rate limited")
    func announcementGatePreventsFeedbackFloods() {
        var gate = TrainingAccessibilityAnnouncementGate(minimumInterval: 1.5)

        #expect(gate.announcement(for: .stage("BASELINE"), at: 10) == "Stage: Baseline")
        #expect(gate.announcement(for: .stage("BASELINE"), at: 10.2) == nil)
        #expect(gate.announcement(for: .trackingPaused, at: 10.3) == nil)
        #expect(gate.announcement(for: .trackingPaused, at: 11.6) == "Tracking paused. Return both fists to guard.")
        #expect(gate.announcement(for: .trackingRecovered, at: 13.2) == "Tracking restored.")
        #expect(gate.announcement(for: .proof("Path improved by 12"), at: 14.8) == "Proof: Path improved by 12")
        #expect(gate.announcement(for: .result("Round complete, 820 points"), at: 16.4) == "Round complete, 820 points")
    }

    @Test("Correction proof and result transitions are never lost behind stage throttling")
    func priorityAnnouncementsAreNotDropped() {
        var gate = TrainingAccessibilityAnnouncementGate(minimumInterval: 1.5)

        #expect(gate.announcement(for: .stage("CORRECT"), at: 10) == "Stage: Correct")
        #expect(gate.announcement(for: .correction("Keep the elbow tucked"), at: 10.1)
            == "Correction: Keep the elbow tucked")
        #expect(gate.announcement(for: .proof("Path improved by 12 points"), at: 10.2)
            == "Proof: Path improved by 12 points")
        #expect(gate.announcement(for: .result("Round complete"), at: 10.3)
            == "Round complete")
    }

    @Test("Each modal and terminal transition has a deterministic focus destination")
    func focusDestinationsAreExplicit() {
        #expect(TrainingAccessibility.focus(after: .permissionDismissed) == .askCoach)
        #expect(TrainingAccessibility.focus(after: .permissionFailed) == .permissionRecovery)
        #expect(TrainingAccessibility.focus(after: .resultPresented) == .resultPrimaryAction)
        #expect(TrainingAccessibility.focus(after: .participantHandoff) == .joinCompetition)
    }

    @Test("Voice permission completion chooses the live focus target")
    func voicePermissionFocusIsDeterministic() {
        let permission = CoachVoiceLifecycleState.needsPermission(
            id: CoachVoiceCaptureID(rawValue: 1),
            origin: .controlWindow
        )

        #expect(TrainingAccessibility.focusAfterVoiceTransition(
            from: permission,
            to: .denied
        ) == .permissionRecovery)
        #expect(TrainingAccessibility.focusAfterVoiceTransition(
            from: permission,
            to: .ready
        ) == .askCoach)
        #expect(TrainingAccessibility.focusAfterVoiceTransition(
            from: .ready,
            to: .interrupted
        ) == nil)
    }

    @Test("Proof announcements state the metric and signed local delta")
    func proofAnnouncementIsActionable() {
        let proof = CoachingProofMetric(
            kind: .path,
            baseline: 60,
            retest: 72,
            delta: 12,
            trackedFraction: 1,
            correctionCode: .path,
            evidenceLabel: .measured,
            sourceBadge: "Measured locally · Offline coach"
        )

        #expect(TrainingAccessibility.proofAnnouncement(for: proof) == "Path improved by 12 points")
    }

    @Test("Reduced motion and stable-anchor preferences select nonmoving alternatives")
    func adaptivePreferencesHaveSafeAlternatives() {
        #expect(TrainingAccessibility.motion(reduceMotion: false) == .spatial)
        #expect(TrainingAccessibility.motion(reduceMotion: true) == .crossfade)
        #expect(TrainingAccessibility.anchor(prefersHeadAnchoredGuidance: false) == .bodyRelative)
        #expect(TrainingAccessibility.anchor(prefersHeadAnchoredGuidance: true) == .headAnchored)
        #expect(TrainingAccessibility.minimumControlHitRegion == 60)
    }

    @Test("Every audio preset has a visible and spoken state")
    func audioPresetsRemainNonvisual() {
        for preset in TrainingAudioPreset.allCases {
            #expect(!preset.title.isEmpty)
            #expect(!preset.accessibilityDescription.isEmpty)
            #expect(!preset.symbolName.isEmpty)
        }
    }

    @Test("Spatial target and fitted arm expose explicit nonvisual meaning")
    func spatialAccessibilityCopyIsAuthored() {
        #expect(SpatialTrainingAccessibility.target.label == "Punch target")
        #expect(SpatialTrainingAccessibility.target.value.contains("orange"))
        #expect(SpatialTrainingAccessibility.fittedArm.label == "Estimated punch guide")
        #expect(SpatialTrainingAccessibility.fittedArm.value.contains("estimated"))
    }
}

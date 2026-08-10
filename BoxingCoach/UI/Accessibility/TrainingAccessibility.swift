import Foundation

nonisolated enum TrainingAccessibilityEvent: Equatable, Sendable {
    case stage(String)
    case trackingPaused
    case trackingRecovered
    case correction(String)
    case proof(String)
    case result(String)

    var announcement: String {
        switch self {
        case .stage(let stage):
            "Stage: \(stage.localizedCapitalized)"
        case .trackingPaused:
            "Tracking paused. Return both fists to guard."
        case .trackingRecovered:
            "Tracking restored."
        case .correction(let correction):
            "Correction: \(correction)"
        case .proof(let proof):
            "Proof: \(proof)"
        case .result(let result):
            result
        }
    }

    var bypassesThrottle: Bool {
        switch self {
        case .correction, .proof, .result:
            true
        case .stage, .trackingPaused, .trackingRecovered:
            false
        }
    }
}

nonisolated struct TrainingAccessibilityAnnouncementGate: Sendable {
    private let minimumInterval: TimeInterval
    private var lastEvent: TrainingAccessibilityEvent?
    private var lastAnnouncementAt: TimeInterval?

    init(minimumInterval: TimeInterval = 1.5) {
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func announcement(
        for event: TrainingAccessibilityEvent,
        at time: TimeInterval
    ) -> String? {
        guard time.isFinite else { return nil }
        if event == lastEvent { return nil }
        if !event.bypassesThrottle,
           let lastAnnouncementAt,
           time - lastAnnouncementAt < minimumInterval {
            return nil
        }
        lastEvent = event
        lastAnnouncementAt = time
        return event.announcement
    }
}

nonisolated enum TrainingAccessibilityTransition: Sendable {
    case permissionDismissed
    case permissionFailed
    case resultPresented
    case participantHandoff
}

nonisolated enum TrainingAccessibilityFocusDestination: Hashable, Sendable {
    case askCoach
    case permissionRecovery
    case resultPrimaryAction
    case joinCompetition
}

nonisolated enum TrainingAccessibilityMotion: Equatable, Sendable {
    case spatial
    case crossfade
}

nonisolated enum TrainingAccessibilityAnchor: Equatable, Sendable {
    case bodyRelative
    case headAnchored
}

nonisolated enum TrainingAccessibility {
    static func focus(
        after transition: TrainingAccessibilityTransition
    ) -> TrainingAccessibilityFocusDestination {
        switch transition {
        case .permissionDismissed:
            .askCoach
        case .permissionFailed:
            .permissionRecovery
        case .resultPresented:
            .resultPrimaryAction
        case .participantHandoff:
            .joinCompetition
        }
    }

    static func focusAfterVoiceTransition(
        from oldState: CoachVoiceLifecycleState,
        to newState: CoachVoiceLifecycleState
    ) -> TrainingAccessibilityFocusDestination? {
        guard case .needsPermission = oldState,
              case .needsPermission = newState else {
            guard case .needsPermission = oldState else { return nil }
            return newState == .denied ? .permissionRecovery : .askCoach
        }
        return nil
    }

    static func proofAnnouncement(for proof: CoachingProofMetric) -> String {
        let roundedDelta = Int(proof.delta.rounded())
        if roundedDelta > 0 {
            return "\(proof.kind.title) improved by \(roundedDelta) points"
        }
        if roundedDelta < 0 {
            return "\(proof.kind.title) decreased by \(abs(roundedDelta)) points"
        }
        return "\(proof.kind.title) held steady"
    }

    static func motion(reduceMotion: Bool) -> TrainingAccessibilityMotion {
        reduceMotion ? .crossfade : .spatial
    }

    static func anchor(
        prefersHeadAnchoredGuidance: Bool
    ) -> TrainingAccessibilityAnchor {
        prefersHeadAnchoredGuidance ? .headAnchored : .bodyRelative
    }
}

nonisolated struct SpatialAccessibilityCopy: Equatable, Sendable {
    let label: String
    let value: String
}

nonisolated enum SpatialTrainingAccessibility {
    static let target = SpatialAccessibilityCopy(
        label: "Punch target",
        value: "Orange target. A valid punch turns it green; rejected or missed evidence turns it coral."
    )

    static let fittedArm = SpatialAccessibilityCopy(
        label: "Estimated punch guide",
        value: "Cyan fitted arm guide. Shoulder and elbow placement are estimated from headset and hand tracking."
    )
}

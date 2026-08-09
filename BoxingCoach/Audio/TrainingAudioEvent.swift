import Foundation

nonisolated enum TrainingAudioStage: String, CaseIterable, Sendable {
    case fit
    case learn
    case baseline
    case correct
    case prove
    case transfer
    case compete
    case celebrate

    var caption: String {
        switch self {
        case .fit:
            "Fit your training space."
        case .learn:
            "Learn the movement."
        case .baseline:
            "Set your baseline."
        case .correct:
            "Focus on one correction."
        case .prove:
            "Prove the improvement."
        case .transfer:
            "Transfer the skill into combinations."
        case .compete:
            "Competition round ready."
        case .celebrate:
            "Training complete."
        }
    }
}

nonisolated enum TrainingImpactQuality: String, Sendable {
    case clean
    case solid
    case light

    var caption: String {
        switch self {
        case .clean:
            "Clean impact."
        case .solid:
            "Solid impact."
        case .light:
            "Light but valid impact."
        }
    }
}

nonisolated enum TrainingTrackingPauseReason: String, Sendable {
    case handsUnavailable
    case staleSamples
    case providerStopped
    case unsafePosition
}

nonisolated enum TrainingCoachCueKind: Int, Sendable, Comparable {
    case result = 1
    case phaseInstruction = 2
    case voiceResponse = 3
    case safety = 4

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct TrainingCoachCue: Equatable, Sendable {
    let kind: TrainingCoachCueKind
    let clip: CoachClipID
    let caption: String

    init(kind: TrainingCoachCueKind, clip: CoachClipID, caption: String) {
        self.kind = kind
        self.clip = clip
        self.caption = caption
    }
}

nonisolated enum TrainingAudioSystemEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded
    case routeChanged
    case mediaServicesWereReset
}

nonisolated enum TrainingAudioSessionDeactivation: Equatable, Sendable {
    case appInitiated
    case systemInterruption
}

nonisolated enum TrainingAudioSceneOwner: Hashable, Sendable {
    case controlWindow
    case immersiveSpace
}

nonisolated enum TrainingAudioSystemEventMapper {
    static func event(
        for deactivation: TrainingAudioSessionDeactivation
    ) -> TrainingAudioSystemEvent? {
        switch deactivation {
        case .appInitiated:
            nil
        case .systemInterruption:
            .interruptionBegan
        }
    }
}

nonisolated enum TrainingAudioEvent: Equatable, Sendable {
    case sceneDidAttach(TrainingAudioSceneOwner)
    case experienceDidEnter(TrainingAudioStage)
    case targetDidAppear(position: SIMD3<Float>)
    case validatedImpact(position: SIMD3<Float>, quality: TrainingImpactQuality)
    case coachCue(TrainingCoachCue)
    case trackingDidPause(TrainingTrackingPauseReason)
    case trackingDidResume
    case voiceCaptureDidBegin(origin: TrainingAudioSceneOwner)
    case voiceCaptureDidEnd
    case audioSystemEvent(TrainingAudioSystemEvent)
    case audioRecoveryConfirmed
    case trainingWillBegin
    case trainingDidStop(preservingVoiceCapture: Bool)
    case sceneDidDetach(TrainingAudioSceneOwner)
}

nonisolated enum TrainingAudioChannel: String, CaseIterable, Hashable, Sendable {
    case coach
    case ambience
    case crowd
    case impact
    case status
}

nonisolated enum TrainingAudioResourceID: Hashable, Sendable {
    case coach(CoachClipID)
    case gymAmbience
    case competitionCrowd
    case cleanImpact1
    case cleanImpact2
    case cleanImpact3
    case rejectedImpact
    case trackingLost
    case trackingRestored
    case startBell
    case endBell
    case improvementSting
    case winnerSwell

    var fileName: String {
        switch self {
        case let .coach(clip):
            clip.rawValue
        case .gymAmbience:
            "gym_ambience"
        case .competitionCrowd:
            "competition_crowd"
        case .cleanImpact1:
            "clean_impact_1"
        case .cleanImpact2:
            "clean_impact_2"
        case .cleanImpact3:
            "clean_impact_3"
        case .rejectedImpact:
            "rejected_hit"
        case .trackingLost:
            "tracking_lost"
        case .trackingRestored:
            "tracking_restored"
        case .startBell:
            "start_bell"
        case .endBell:
            "end_bell"
        case .improvementSting:
            "improvement_sting"
        case .winnerSwell:
            "winner_swell"
        }
    }

    /// The complete locally authored, non-verbal ring inventory plus calibration cues.
    static let sonicRingResources: [Self] = [
        .coach(.calibrateReach),
        .coach(.extendOtherArm),
        .coach(.reachCalibrated),
        .gymAmbience,
        .competitionCrowd,
        .startBell,
        .endBell,
        .cleanImpact1,
        .cleanImpact2,
        .cleanImpact3,
        .rejectedImpact,
        .trackingLost,
        .trackingRestored,
        .improvementSting,
        .winnerSwell
    ]

    static let cleanImpactVariants: [Self] = [
        .cleanImpact1,
        .cleanImpact2,
        .cleanImpact3
    ]

    var isLoopingBed: Bool {
        self == .gymAmbience || self == .competitionCrowd
    }
}

nonisolated enum TrainingAudioGain: Equatable, Sendable {
    case muted
    case decibels(Float)

    var linearAmplitude: Float {
        switch self {
        case .muted:
            0
        case let .decibels(value):
            powf(10, value / 20)
        }
    }

    func capped(at maximumDecibels: Float) -> Self {
        switch self {
        case .muted:
            .muted
        case let .decibels(value):
            .decibels(min(value, maximumDecibels))
        }
    }
}

nonisolated struct TrainingAudioMix: Equatable, Sendable {
    let coach: TrainingAudioGain
    let ambience: TrainingAudioGain
    let crowd: TrainingAudioGain
    let impact: TrainingAudioGain
    let status: TrainingAudioGain

    init(
        coach: TrainingAudioGain,
        ambience: TrainingAudioGain,
        crowd: TrainingAudioGain,
        impact: TrainingAudioGain,
        status: TrainingAudioGain
    ) {
        self.coach = coach
        self.ambience = ambience
        self.crowd = crowd
        self.impact = impact
        self.status = status
    }

    static let silent = Self(
        coach: .muted,
        ambience: .muted,
        crowd: .muted,
        impact: .muted,
        status: .muted
    )

    static func stage(_ stage: TrainingAudioStage) -> Self {
        let ambience: TrainingAudioGain
        let crowd: TrainingAudioGain
        switch stage {
        case .fit:
            ambience = .decibels(-24)
            crowd = .muted
        case .learn:
            ambience = .decibels(-22)
            crowd = .muted
        case .baseline:
            ambience = .decibels(-26)
            crowd = .muted
        case .correct:
            ambience = .decibels(-32)
            crowd = .muted
        case .prove, .transfer:
            ambience = .decibels(-24)
            crowd = .muted
        case .compete:
            ambience = .decibels(-28)
            crowd = .decibels(-24)
        case .celebrate:
            ambience = .decibels(-30)
            crowd = .decibels(-14)
        }

        return Self(
            coach: .decibels(0),
            ambience: ambience,
            crowd: crowd,
            impact: .decibels(-3),
            status: .decibels(0)
        )
    }

    func ducked(for priority: TrainingCoachCueKind) -> Self {
        switch priority {
        case .safety, .voiceResponse:
            Self(
                coach: coach,
                ambience: ambience.capped(at: -40),
                crowd: .muted,
                impact: .muted,
                status: status
            )
        case .phaseInstruction:
            Self(
                coach: coach,
                ambience: ambience.capped(at: -32),
                crowd: crowd.capped(at: -38),
                impact: impact.capped(at: -12),
                status: status
            )
        case .result:
            Self(
                coach: coach,
                ambience: ambience.capped(at: -30),
                crowd: crowd.capped(at: -34),
                impact: impact.capped(at: -6),
                status: status
            )
        }
    }

    static let trackingPaused = Self(
        coach: .decibels(0),
        ambience: .decibels(-38),
        crowd: .muted,
        impact: .muted,
        status: .decibels(0)
    )

    static let voiceCapture = Self(
        coach: .muted,
        ambience: .decibels(-40),
        crowd: .muted,
        impact: .muted,
        status: .muted
    )
}

nonisolated struct TrainingAudioPlaybackHandle: Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

nonisolated struct TrainingAudioPlaybackRequest: Equatable, Sendable {
    let resource: TrainingAudioResourceID
    let url: URL
    let channel: TrainingAudioChannel
    let loops: Bool
    let position: SIMD3<Float>?
    let generation: UInt64
}

nonisolated enum TrainingAudioCoordinatorStatus: Equatable, Sendable {
    case detached
    case ready
    case trackingPaused
    case capturePreparing
    case capturing
    case awaitingExplicitRecovery
    case unavailable
}

nonisolated struct TrainingAudioPresentationState: Equatable, Sendable {
    var status: TrainingAudioCoordinatorStatus
    var stage: TrainingAudioStage
    var caption: String?
    var targetPosition: SIMD3<Float>?
    var mix: TrainingAudioMix
    var activePriority: TrainingCoachCueKind?
    var isCapturing: Bool
    var requiresExplicitRecovery: Bool

    static let detached = Self(
        status: .detached,
        stage: .fit,
        caption: nil,
        targetPosition: nil,
        mix: .silent,
        activePriority: nil,
        isCapturing: false,
        requiresExplicitRecovery: false
    )
}

nonisolated enum TrainingAudioEventOutcome: Equatable, Sendable {
    case handled
    case captureReady
    case deferredUntilCaptureEnds
    case missingResource(TrainingAudioResourceID)
    case suppressed(by: TrainingCoachCueKind)
    case ignoredWhileDetached
    case staleGeneration
    case backendUnavailable
}

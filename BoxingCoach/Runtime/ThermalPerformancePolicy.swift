import Foundation

nonisolated enum ThermalPerformanceLevel: CaseIterable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

nonisolated struct ThermalPerformanceProfile: Equatable, Sendable {
    let crowdEnabled: Bool
    let particlesEnabled: Bool
    let nonessentialUpdateDivisor: Int
    let trackingIntegrityPreserved: Bool
    let caption: String?

    var isReduced: Bool { caption != nil }

    func applying(to mix: TrainingAudioMix) -> TrainingAudioMix {
        TrainingAudioMix(
            coach: mix.coach,
            ambience: mix.ambience,
            crowd: crowdEnabled ? mix.crowd : .muted,
            impact: mix.impact,
            status: mix.status
        )
    }
}

nonisolated enum ThermalPerformancePolicy {
    static func profile(for level: ThermalPerformanceLevel) -> ThermalPerformanceProfile {
        switch level {
        case .nominal:
            ThermalPerformanceProfile(
                crowdEnabled: true,
                particlesEnabled: true,
                nonessentialUpdateDivisor: 1,
                trackingIntegrityPreserved: true,
                caption: nil
            )
        case .fair:
            ThermalPerformanceProfile(
                crowdEnabled: false,
                particlesEnabled: true,
                nonessentialUpdateDivisor: 1,
                trackingIntegrityPreserved: true,
                caption: "Reduced effects to keep tracking responsive."
            )
        case .serious:
            ThermalPerformanceProfile(
                crowdEnabled: false,
                particlesEnabled: false,
                nonessentialUpdateDivisor: 2,
                trackingIntegrityPreserved: true,
                caption: "Reduced effects to keep tracking responsive."
            )
        case .critical:
            ThermalPerformanceProfile(
                crowdEnabled: false,
                particlesEnabled: false,
                nonessentialUpdateDivisor: 4,
                trackingIntegrityPreserved: true,
                caption: "Reduced effects to keep tracking responsive."
            )
        }
    }
}

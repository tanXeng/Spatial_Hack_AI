import Testing
@testable import BoxingCoach

@Suite("Thermal performance policy")
struct ThermalPerformancePolicyTests {
    @Test("Degradation removes nonessential effects before tracking integrity", arguments: [
        (ThermalPerformanceLevel.nominal, true, true, 1, false),
        (.fair, false, true, 1, true),
        (.serious, false, false, 2, true),
        (.critical, false, false, 4, true),
    ])
    func degradationOrder(
        level: ThermalPerformanceLevel,
        crowdEnabled: Bool,
        particlesEnabled: Bool,
        nonessentialUpdateDivisor: Int,
        reduced: Bool
    ) {
        let profile = ThermalPerformancePolicy.profile(for: level)

        #expect(profile.crowdEnabled == crowdEnabled)
        #expect(profile.particlesEnabled == particlesEnabled)
        #expect(profile.nonessentialUpdateDivisor == nonessentialUpdateDivisor)
        #expect(profile.trackingIntegrityPreserved)
        #expect(profile.isReduced == reduced)
        #expect(profile.caption == (reduced ? "Reduced effects to keep tracking responsive." : nil))
    }

    @Test("Reduced thermal mix never changes coach or safety status gain")
    func audioReductionKeepsEssentialChannels() {
        let source = TrainingAudioMix.stage(.celebrate)
        let reduced = ThermalPerformancePolicy.profile(for: .critical).applying(to: source)

        #expect(reduced.coach == source.coach)
        #expect(reduced.status == source.status)
        #expect(reduced.crowd == .muted)
        #expect(reduced.impact == source.impact)
    }
}

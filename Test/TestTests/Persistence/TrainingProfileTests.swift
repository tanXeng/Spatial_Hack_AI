//
//  TrainingProfileTests.swift
//  TestTests
//

import Foundation
import Testing
@testable import Test

@MainActor
struct TrainingProfileTests {
    @Test
    func boxerValidationRejectsNonFiniteAndImplausibleMeasurements() {
        let profile = validBoxer()
        #expect((try? profile.validated()) == profile)
        #expect(abs(profile.averageArmLengthMeters - 0.70) < 0.000_001)
        #expect(abs(profile.estimatedReachMeters - 0.685) < 0.000_001)

        var nonFinite = profile
        nonFinite.heightMeters = .nan
        #expect(throws: TrainingProfileValidationError.self) {
            try nonFinite.validated()
        }

        var implausible = profile
        implausible.armSpanMeters = 2.65
        #expect(throws: TrainingProfileValidationError.self) {
            try implausible.validated()
        }

        var invalidChoice = profile
        invalidChoice.stanceRawValue = "switch"
        #expect(throws: TrainingProfileValidationError.self) {
            try invalidChoice.validated()
        }
    }

    @Test
    func metricAndImperialConversionsRoundTripCanonicalMeters() throws {
        for unit in MeasurementUnit.allCases {
            let displayValue = unit.displayLength(fromMeters: 1.8288)
            let roundTrip = unit.meters(fromDisplayLength: displayValue)
            #expect(abs(roundTrip - 1.8288) < 0.000_000_1)
        }

        #expect(abs(MeasurementUnit.metric.meters(fromDisplayLength: 182.88) - 1.8288) < 0.000_000_1)
        #expect(abs(MeasurementUnit.imperial.meters(fromDisplayLength: 72) - 1.8288) < 0.000_000_1)

        var imperial = validBoxer()
        imperial.preferredMeasurementUnit = .imperial
        let data = try JSONEncoder().encode(imperial)
        #expect(try JSONDecoder().decode(BoxerProfile.self, from: data) == imperial)
    }

    @Test
    func editedBodyMeasurementsInvalidateAStoredLiveReach() {
        var stored = validBoxer()
        stored.measuredComfortableReachMeters = 0.56

        var unchanged = stored
        unchanged.measuredComfortableReachMeters = nil
        #expect(stored.hasEquivalentBodyMeasurements(to: unchanged))

        var corrected = unchanged
        corrected.leftArmLengthMeters += 0.02
        #expect(!stored.hasEquivalentBodyMeasurements(to: corrected))
    }

    @Test
    func storePersistsProfilesAndMeasuredReachLocally() throws {
        let fixture = makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let keys = TrainingProfileStoreKeys(
            boxerProfile: "test.boxer",
            bagProfile: "test.bag"
        )

        let store = TrainingProfileStore(defaults: fixture.defaults, keys: keys)
        #expect(!store.hasProfile)
        #expect(store.saveBoxer(validBoxer()))
        #expect(store.saveBag(validBag()))
        #expect(store.recordMeasuredComfortableReach(0.56))
        #expect(store.hasProfile)
        #expect(abs((store.boxerProfile?.effectiveReachMeters ?? 0) - 0.56) < 0.000_001)

        let reloaded = TrainingProfileStore(defaults: fixture.defaults, keys: keys)
        #expect(reloaded.boxerProfile == store.boxerProfile)
        #expect(reloaded.bagProfile == store.bagProfile)
        #expect(reloaded.lastError == nil)

        reloaded.resetBoxer()
        reloaded.resetBag()
        #expect(!reloaded.hasProfile)
        #expect(reloaded.bagProfile == nil)
        #expect(fixture.defaults.data(forKey: keys.boxerProfile) == nil)
        #expect(fixture.defaults.data(forKey: keys.bagProfile) == nil)
    }

    @Test
    func corruptStoredDataIsRemovedAndStoreCanRecover() {
        let fixture = makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let keys = TrainingProfileStoreKeys(
            boxerProfile: "test.corrupt.boxer",
            bagProfile: "test.corrupt.bag"
        )
        fixture.defaults.set(Data("not-json".utf8), forKey: keys.boxerProfile)

        let store = TrainingProfileStore(defaults: fixture.defaults, keys: keys)
        #expect(!store.hasProfile)
        #expect(store.lastError?.contains("invalid and has been reset") == true)
        #expect(fixture.defaults.data(forKey: keys.boxerProfile) == nil)

        #expect(store.saveBoxer(validBoxer()))
        #expect(store.hasProfile)
        #expect(store.lastError == nil)
    }

    @Test
    func bagValidationUsesTypeSpecificPlausibilityBounds() {
        #expect((try? validBag().validated()) == validBag())

        var nonFinite = validBag()
        nonFinite.diameterMeters = .infinity
        #expect(throws: TrainingProfileValidationError.self) {
            try nonFinite.validated()
        }

        var implausibleReflexBag = validBag()
        implausibleReflexBag.type = .reflex
        implausibleReflexBag.diameterMeters = 0.70
        #expect(throws: TrainingProfileValidationError.self) {
            try implausibleReflexBag.validated()
        }

        var unnamed = validBag()
        unnamed.name = "   "
        #expect(throws: TrainingProfileValidationError.self) {
            try unnamed.validated()
        }
    }

    private func validBoxer() -> BoxerProfile {
        BoxerProfile(
            heightMeters: 1.76,
            armSpanMeters: 1.81,
            leftArmLengthMeters: 0.69,
            rightArmLengthMeters: 0.71,
            shoulderWidthMeters: 0.44
        )
    }

    private func validBag() -> BagProfile {
        BagProfile(
            name: "Home heavy bag",
            type: .hanging,
            targetLayout: .fourTarget,
            heightMeters: 1.20,
            diameterMeters: 0.36
        )
    }

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "TrainingProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

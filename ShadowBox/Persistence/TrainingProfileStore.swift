//
//  TrainingProfileStore.swift
//  Test
//
//  Local persistence for explicit configuration scalars only. This store never
//  accepts or writes joint samples, world transforms, room data, or traces.
//

import Foundation
import Observation

struct TrainingProfileStoreKeys: Equatable, Sendable {
    var boxerProfile: String
    var bagProfile: String

    nonisolated static let standard = TrainingProfileStoreKeys(
        boxerProfile: "shadowbox.training.boxer-profile.v1",
        bagProfile: "shadowbox.training.bag-profile.v1"
    )
}

@MainActor
@Observable
final class TrainingProfileStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: TrainingProfileStoreKeys
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    private(set) var boxerProfile: BoxerProfile?
    private(set) var bagProfile: BagProfile?
    private(set) var lastError: String?

    var hasProfile: Bool {
        boxerProfile != nil
    }

    init(
        defaults: UserDefaults = .standard,
        keys: TrainingProfileStoreKeys = .standard
    ) {
        self.defaults = defaults
        self.keys = keys
        loadPersistedProfiles()
    }

    @discardableResult
    func saveBoxer(_ profile: BoxerProfile) -> Bool {
        do {
            let validated = try profile.validated()
            let data = try encoder.encode(validated)
            defaults.set(data, forKey: keys.boxerProfile)
            boxerProfile = validated
            lastError = nil
            return true
        } catch {
            lastError = "Boxer profile was not saved: \(error.localizedDescription)"
            return false
        }
    }

    func resetBoxer() {
        defaults.removeObject(forKey: keys.boxerProfile)
        boxerProfile = nil
        lastError = nil
    }

    @discardableResult
    func saveBag(_ profile: BagProfile) -> Bool {
        do {
            let validated = try profile.validated()
            let data = try encoder.encode(validated)
            defaults.set(data, forKey: keys.bagProfile)
            bagProfile = validated
            lastError = nil
            return true
        } catch {
            lastError = "Bag profile was not saved: \(error.localizedDescription)"
            return false
        }
    }

    func resetBag() {
        defaults.removeObject(forKey: keys.bagProfile)
        bagProfile = nil
        lastError = nil
    }

    /// Records only the scalar distance produced by live calibration. The
    /// associated hand/world coordinates remain session-scoped elsewhere.
    @discardableResult
    func recordMeasuredComfortableReach(_ meters: Double) -> Bool {
        guard var profile = boxerProfile else {
            lastError = "Create a boxer profile before recording comfortable reach."
            return false
        }

        profile.measuredComfortableReachMeters = meters
        return saveBoxer(profile)
    }

    private func loadPersistedProfiles() {
        var recoveryMessages: [String] = []

        if let data = defaults.data(forKey: keys.boxerProfile) {
            do {
                boxerProfile = try decoder.decode(BoxerProfile.self, from: data)
                    .validated()
            } catch {
                boxerProfile = nil
                defaults.removeObject(forKey: keys.boxerProfile)
                recoveryMessages.append(
                    "Stored boxer profile was invalid and has been reset: \(error.localizedDescription)"
                )
            }
        }

        if let data = defaults.data(forKey: keys.bagProfile) {
            do {
                bagProfile = try decoder.decode(BagProfile.self, from: data)
                    .validated()
            } catch {
                bagProfile = nil
                defaults.removeObject(forKey: keys.bagProfile)
                recoveryMessages.append(
                    "Stored bag profile was invalid and has been reset: \(error.localizedDescription)"
                )
            }
        }

        lastError = recoveryMessages.isEmpty
            ? nil
            : recoveryMessages.joined(separator: " ")
    }
}

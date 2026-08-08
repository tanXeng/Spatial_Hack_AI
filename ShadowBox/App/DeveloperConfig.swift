//
//  DeveloperConfig.swift
//  ShadowBox
//
//  Developer-only runtime switches for local/offline workflows.
//

import Foundation

enum DeveloperConfig {
    private static let offlineModeEnvironmentKey = "SHADOWBOX_OFFLINE_MODE"
    private static let offlineModeDefaultsKey = "shadowbox.developer.offline-mode.v1"

    /// Turns on local/offline behavior when set to any truthy string
    /// (`1`, `true`, `yes`) in the process environment.
    static var isOfflineModeEnabled: Bool {
        let envValue = ProcessInfo.processInfo.environment[offlineModeEnvironmentKey]
        switch envValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            break
        }

        return UserDefaults.standard.bool(forKey: offlineModeDefaultsKey)
    }

    /// Deterministic fallback calibration used when offline mode bypasses
    /// anthropometry/live functional-reach capture.
    static let offlineCalibrationComfortableReach: Float = 0.48
    static let offlineCalibrationForwardReachFraction: Float = 0.82
    static let offlineReferenceSpeed: Float = 0.80
    static let offlineGuardHeight: Float = 1.35
    static let offlineGuardLateralOffset: Float = 0.14
}

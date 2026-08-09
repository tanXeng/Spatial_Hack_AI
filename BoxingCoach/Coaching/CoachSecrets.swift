import Foundation

/// Public, non-secret configuration for optional team-hosted coaching.
nonisolated enum CoachSecrets {
    static let relayURLInfoKey = "COACH_RELAY_URL"

    static var relayEndpoint: URL? {
        relayEndpoint(in: Bundle.main.infoDictionary ?? [:])
    }

    /// Provider credentials are intentionally not part of this boundary. A build can enable
    /// network coaching only by supplying an HTTPS relay URL without embedded credentials.
    static func relayEndpoint(in infoDictionary: [String: Any]) -> URL? {
        guard let rawValue = infoDictionary[relayURLInfoKey] as? String else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            !trimmed.hasPrefix("$("),
            let url = URL(string: trimmed),
            url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false,
            url.user == nil,
            url.password == nil
        else {
            return nil
        }
        return url
    }
}

nonisolated struct CoachVoiceContext: Sendable, Equatable {
    var feature: TrainingFeature
    var auraPhase: AuraPunchPhase?
    var drillPhase: DrillPhase?
    var techniqueName: String?

    static let idle = CoachVoiceContext(feature: .auraPunch)
}

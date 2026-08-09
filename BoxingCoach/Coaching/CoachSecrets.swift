import Foundation

nonisolated enum OpenAIKeySource: Equatable, Sendable {
    case inApp
    case buildConfig
    case none
}

nonisolated enum CoachSecrets {
    static let userDefaultsKey = "com.boxingcoach.openaiAPIKey"

    /// In-app stored key takes priority over build-time `Secrets.xcconfig` → Info.plist.
    static var openAIAPIKey: String? {
        if let inApp = validatedKey(from: storedInAppKey) {
            return inApp
        }
        return validatedKey(from: plistRawValue)
    }

    static var hasOpenAIKey: Bool {
        openAIAPIKey != nil
    }

    static var openAIKeySource: OpenAIKeySource {
        if validatedKey(from: storedInAppKey) != nil {
            return .inApp
        }
        if validatedKey(from: plistRawValue) != nil {
            return .buildConfig
        }
        return .none
    }

    static func setOpenAIAPIKey(_ key: String?) {
        guard let key, let validated = validatedKey(from: key) else {
            userDefaults.removeObject(forKey: userDefaultsKey)
            return
        }
        userDefaults.set(validated, forKey: userDefaultsKey)
    }

    // MARK: - Private

    private static var userDefaults: UserDefaults {
        #if DEBUG
        if let suiteName = testingDefaultsSuiteName,
           let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        #endif
        return .standard
    }

    private static var storedInAppKey: String? {
        userDefaults.string(forKey: userDefaultsKey)
    }

    private static var plistRawValue: String? {
        Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String
    }

    static func validatedKey(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("$("),
              trimmed != "sk-your-key-here"
        else { return nil }
        return trimmed
    }

    #if DEBUG
    /// Isolated suite for unit tests; nil uses standard UserDefaults.
    static var testingDefaultsSuiteName: String?
    #endif
}

nonisolated struct CoachVoiceContext: Sendable, Equatable {
    var feature: TrainingFeature
    var auraPhase: AuraPunchPhase?
    var drillPhase: DrillPhase?
    var techniqueName: String?

    static let idle = CoachVoiceContext(feature: .auraPunch)
}

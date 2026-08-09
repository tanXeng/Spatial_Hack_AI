import Foundation
import Testing
@testable import BoxingCoach

@Suite("Coach production configuration")
struct CoachSecretsTests {
    @Test("Provider credentials cannot become app configuration")
    func providerCredentialsAreIgnored() {
        let endpoint = CoachSecrets.relayEndpoint(in: [
            "OPENAI_API_KEY": "sk-must-not-be-readable",
            "ANTHROPIC_API_KEY": "must-not-be-readable"
        ])

        #expect(endpoint == nil)
    }

    @Test("Only a secure team relay URL enables network coaching")
    func relayEndpointRequiresHTTPS() {
        #expect(
            CoachSecrets.relayEndpoint(in: [
                CoachSecrets.relayURLInfoKey: "https://coach-relay.example/v1/feedback"
            ]) == URL(string: "https://coach-relay.example/v1/feedback")
        )
        #expect(
            CoachSecrets.relayEndpoint(in: [
                CoachSecrets.relayURLInfoKey: "http://coach-relay.example/v1/feedback"
            ]) == nil
        )
        #expect(
            CoachSecrets.relayEndpoint(in: [
                CoachSecrets.relayURLInfoKey: "https://user:secret@coach-relay.example/v1/feedback"
            ]) == nil
        )
    }

    @Test("Built app contains no provider-key configuration field")
    func builtAppHasNoProviderKeyField() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") == nil)
        #expect(Bundle.main.object(forInfoDictionaryKey: "ANTHROPIC_API_KEY") == nil)
    }
}

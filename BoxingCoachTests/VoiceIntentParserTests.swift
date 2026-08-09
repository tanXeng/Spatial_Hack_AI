import Testing
@testable import BoxingCoach

@Suite("Exact local voice grammar")
struct VoiceIntentParserTests {
    @Test("Every allow-listed alias maps to one distinct intent", arguments: VoiceAliasCase.all)
    func approvedAliasMapsExactly(testCase: VoiceAliasCase) {
        let utterance = VoiceUtterance(
            transcript: testCase.phrase,
            localeIdentifier: "en-SG",
            isFinal: true,
            confidence: .high
        )
        let context = VoiceCommandContext(
            state: testCase.allowedState,
            capabilities: Set(VoiceCommandCapability.allCases)
        )

        let result = VoiceIntentParser().parse(utterance, in: context)

        #expect(
            result == .accepted(
                VoiceIntentMatch(
                    intent: testCase.intent,
                    normalizedPhrase: testCase.normalizedPhrase,
                    confidence: .high
                )
            )
        )
    }

    @Test("Case punctuation whitespace width and apostrophes normalize", arguments: VoiceNormalizationCase.all)
    func normalizationIsDeterministic(testCase: VoiceNormalizationCase) {
        let result = VoiceIntentParser().parse(
            VoiceUtterance(
                transcript: testCase.transcript,
                localeIdentifier: "en_US",
                isFinal: true,
                confidence: .medium
            ),
            in: VoiceCommandContext(
                state: testCase.allowedState,
                capabilities: Set(VoiceCommandCapability.allCases)
            )
        )

        #expect(
            result == .accepted(
                VoiceIntentMatch(
                    intent: testCase.intent,
                    normalizedPhrase: testCase.normalizedPhrase,
                    confidence: .medium
                )
            )
        )
    }

    @Test("Only complete final utterances can produce an intent")
    func partialUtteranceIsRejected() {
        let result = parse(
            "pause",
            isFinal: false,
            state: .learn,
            capabilities: [.pause]
        )

        #expect(
            result == rejection(
                phrase: "pause",
                confidence: .high,
                reason: .incompleteUtterance,
                recovery: "Finish speaking one command, then try again."
            )
        )
    }

    @Test("Low-confidence final utterances cannot produce an intent")
    func lowConfidenceUtteranceIsRejected() {
        let result = parse(
            "pause",
            confidence: .low,
            state: .learn,
            capabilities: [.pause]
        )

        #expect(
            result == rejection(
                phrase: "pause",
                confidence: .low,
                reason: .lowConfidence,
                recovery: "I didn't catch that clearly. Try again or use the visible controls."
            )
        )
    }

    @Test("Two complete commands in one utterance are ambiguous")
    func multipleCommandsAreRejectedAsAmbiguous() {
        let result = parse(
            "pause, and then resume!",
            state: .learn,
            capabilities: Set(VoiceCommandCapability.allCases)
        )

        #expect(
            result == rejection(
                phrase: "pause and then resume",
                confidence: .high,
                reason: .ambiguous,
                recovery: "I heard more than one command. Say one command at a time."
            )
        )
    }

    @Test("Substring and polite-wrapper collisions never route", arguments: VoiceUnsupportedCase.all)
    func wholePhraseMatchingRejectsSubstrings(testCase: VoiceUnsupportedCase) {
        let result = parse(
            testCase.transcript,
            state: .results,
            capabilities: Set(VoiceCommandCapability.allCases)
        )

        #expect(
            result == rejection(
                phrase: testCase.normalizedPhrase,
                confidence: .high,
                reason: .unrecognized,
                recovery: "I didn't recognize that command. Say \"help\" for available commands."
            )
        )
    }

    @Test("Empty and punctuation-only input returns accessible recovery", arguments: ["", "   ", "?!…"])
    func emptyInputIsRejected(transcript: String) {
        let result = parse(
            transcript,
            state: .idle,
            capabilities: Set(VoiceCommandCapability.allCases)
        )

        #expect(
            result == rejection(
                phrase: "",
                confidence: .high,
                reason: .emptyInput,
                recovery: "I didn't hear a command. Say \"help\" for available commands."
            )
        )
    }

    @Test("English locale variants are accepted", arguments: ["en", "en-US", "en_GB", "EN-sg"])
    func englishLocaleVariantsAreAccepted(localeIdentifier: String) {
        let result = VoiceIntentParser().parse(
            VoiceUtterance(
                transcript: "help",
                localeIdentifier: localeIdentifier,
                isFinal: true,
                confidence: .high
            ),
            in: VoiceCommandContext(state: .idle, capabilities: [.help])
        )

        #expect(result.acceptedIntent == .help)
    }

    @Test("Unsupported locales never produce a command", arguments: ["", "fr-FR", "zh-Hans", "es_US"])
    func unsupportedLocaleIsRejected(localeIdentifier: String) {
        let result = VoiceIntentParser().parse(
            VoiceUtterance(
                transcript: "help",
                localeIdentifier: localeIdentifier,
                isFinal: true,
                confidence: .high
            ),
            in: VoiceCommandContext(state: .idle, capabilities: [.help])
        )

        #expect(
            result == rejection(
                phrase: "help",
                confidence: .high,
                reason: .unsupportedLocale,
                recovery: "Voice commands are available in English. Use the visible controls to continue."
            )
        )
    }

    @Test("Every intent is rejected outside its allowed state", arguments: VoiceGateCase.all)
    func everyIntentIsStateGated(testCase: VoiceGateCase) {
        let result = parse(
            testCase.phrase,
            state: .ranked,
            capabilities: Set(VoiceCommandCapability.allCases)
        )

        #expect(
            result == rejection(
                phrase: testCase.phrase,
                confidence: .high,
                reason: .unavailableInState(intent: testCase.intent, state: .ranked),
                recovery: "That command isn't available right now. Say \"help\" for available commands."
            )
        )
    }

    @Test("Every intent requires its explicit session capability", arguments: VoiceGateCase.all)
    func everyIntentIsCapabilityGated(testCase: VoiceGateCase) {
        let result = parse(
            testCase.phrase,
            state: testCase.allowedState,
            capabilities: []
        )

        #expect(
            result == rejection(
                phrase: testCase.phrase,
                confidence: .high,
                reason: .unavailableCapability(intent: testCase.intent),
                recovery: "That action isn't available in this training mode. Use the visible controls or say \"help\"."
            )
        )
    }

    @Test("Bare stop is reversible pause and never end")
    func stopMeansPauseOnly() {
        let result = parse("stop", state: .learn, capabilities: [.pause, .requestEnd])

        #expect(result.acceptedIntent == .pause)
        #expect(result.acceptedIntent != .requestEnd)
        #expect(result.acceptedIntent != .confirmEnd)
    }

    @Test("End request and confirmation remain separate state-gated intents")
    func endingRequiresExplicitConfirmation() {
        let request = parse(
            "end training",
            state: .learn,
            capabilities: [.requestEnd, .confirmEnd]
        )
        let prematureConfirmation = parse(
            "confirm end",
            state: .learn,
            capabilities: [.requestEnd, .confirmEnd]
        )
        let confirmation = parse(
            "confirm end",
            state: .awaitingEndConfirmation,
            capabilities: [.confirmEnd]
        )

        #expect(request.acceptedIntent == .requestEnd)
        #expect(prematureConfirmation.acceptedIntent == nil)
        #expect(confirmation.acceptedIntent == .confirmEnd)
    }

    @Test("Parser results and contexts are immutable Sendable values")
    func grammarBoundaryIsSendable() {
        requireSendable(VoiceIntent.self)
        requireSendable(VoiceRecognitionConfidence.self)
        requireSendable(VoiceUtterance.self)
        requireSendable(VoiceCommandState.self)
        requireSendable(VoiceCommandCapability.self)
        requireSendable(VoiceCommandContext.self)
        requireSendable(VoiceIntentMatch.self)
        requireSendable(VoiceIntentRejection.self)
        requireSendable(VoiceIntentParseResult.self)
        requireSendable(VoiceIntentParser.self)

        let context = VoiceCommandContext(state: .idle, capabilities: [.help])
        let utterance = VoiceUtterance(
            transcript: "help",
            localeIdentifier: "en-US",
            isFinal: true,
            confidence: .high
        )
        let parser = VoiceIntentParser()

        #expect(parser.parse(utterance, in: context) == parser.parse(utterance, in: context))
        #expect(context == VoiceCommandContext(state: .idle, capabilities: [.help]))
    }

    private func parse(
        _ transcript: String,
        localeIdentifier: String = "en-US",
        isFinal: Bool = true,
        confidence: VoiceRecognitionConfidence = .high,
        state: VoiceCommandState,
        capabilities: Set<VoiceCommandCapability>
    ) -> VoiceIntentParseResult {
        VoiceIntentParser().parse(
            VoiceUtterance(
                transcript: transcript,
                localeIdentifier: localeIdentifier,
                isFinal: isFinal,
                confidence: confidence
            ),
            in: VoiceCommandContext(state: state, capabilities: capabilities)
        )
    }

    private func rejection(
        phrase: String,
        confidence: VoiceRecognitionConfidence,
        reason: VoiceIntentRejectionReason,
        recovery: String
    ) -> VoiceIntentParseResult {
        .rejected(
            VoiceIntentRejection(
                normalizedPhrase: phrase,
                confidence: confidence,
                reason: reason,
                recoveryMessage: recovery
            )
        )
    }
}

nonisolated struct VoiceAliasCase: Sendable, CustomTestStringConvertible {
    let phrase: String
    let normalizedPhrase: String
    let intent: VoiceIntent
    let allowedState: VoiceCommandState

    init(
        _ phrase: String,
        normalized normalizedPhrase: String? = nil,
        intent: VoiceIntent,
        state: VoiceCommandState
    ) {
        self.phrase = phrase
        self.normalizedPhrase = normalizedPhrase ?? phrase
        self.intent = intent
        self.allowedState = state
    }

    var testDescription: String { "\(intent): \(phrase)" }

    static let all: [Self] = [
        .init("pause", intent: .pause, state: .learn),
        .init("pause training", intent: .pause, state: .learn),
        .init("hold on", intent: .pause, state: .baseline),
        .init("wait", intent: .pause, state: .correction),
        .init("stop", intent: .pause, state: .transfer),
        .init("resume", intent: .resume, state: .trackingPaused),
        .init("resume training", intent: .resume, state: .trackingPaused),
        .init("continue", intent: .resume, state: .trackingPaused),
        .init("continue training", intent: .resume, state: .trackingPaused),
        .init("end training", intent: .requestEnd, state: .learn),
        .init("end session", intent: .requestEnd, state: .baseline),
        .init("finish training", intent: .requestEnd, state: .correction),
        .init("quit training", intent: .requestEnd, state: .transfer),
        .init("confirm end", intent: .confirmEnd, state: .awaitingEndConfirmation),
        .init("cancel", intent: .cancelEnd, state: .awaitingEndConfirmation),
        .init("keep training", intent: .cancelEnd, state: .awaitingEndConfirmation),
        .init("repeat", intent: .repeatDemo, state: .learn),
        .init("repeat demo", intent: .repeatDemo, state: .learn),
        .init("show demo again", intent: .repeatDemo, state: .correction),
        .init("show that again", intent: .repeatDemo, state: .learn),
        .init("slower", intent: .slower, state: .learn),
        .init("slow down", intent: .slower, state: .correction),
        .init("show it slower", intent: .slower, state: .learn),
        .init("normal speed", intent: .normalPace, state: .learn),
        .init("reset speed", intent: .normalPace, state: .correction),
        .init("faster", intent: .faster, state: .learn),
        .init("speed up", intent: .faster, state: .correction),
        .init("show it faster", intent: .faster, state: .learn),
        .init("next", intent: .next, state: .learn),
        .init("next step", intent: .next, state: .correction),
        .init("move on", intent: .next, state: .results),
        .init("what should i fix", intent: .correction, state: .correction),
        .init("how was that", intent: .correction, state: .retest),
        .init("what can i improve", intent: .correction, state: .results),
        .init("why guard", intent: .guardExplanation, state: .learn),
        .init("why keep my hands up", intent: .guardExplanation, state: .baseline),
        .init("where is the target", intent: .targetHelp, state: .learn),
        .init("how do i hit the target", intent: .targetHelp, state: .transfer),
        .init("how many reps", intent: .progress, state: .baseline),
        .init("how many punches", intent: .progress, state: .retest),
        .init("help", intent: .help, state: .idle),
        .init("voice commands", intent: .help, state: .learn),
        .init("what can i say", intent: .help, state: .results),
        .init("score", intent: .score, state: .results),
        .init("my score", intent: .score, state: .results),
        .init("what is my score", intent: .score, state: .results),
        .init("what was my score", intent: .score, state: .results),
        .init("what's my score", normalized: "whats my score", intent: .score, state: .results),
        .init("why", intent: .why, state: .correction),
        .init("why that correction", intent: .why, state: .correction),
        .init("why did i get that score", intent: .why, state: .results),
        .init("why does that matter", intent: .why, state: .retest),
        .init("leaderboard", intent: .leaderboard, state: .idle),
        .init("show leaderboard", intent: .leaderboard, state: .results),
        .init("show the leaderboard", intent: .leaderboard, state: .idle),
        .init("where do i rank", intent: .leaderboard, state: .results),
        .init("next boxer", intent: .participantHandoff, state: .results),
        .init("ready for next boxer", intent: .participantHandoff, state: .results),
        .init("switch participant", intent: .participantHandoff, state: .results),
        .init("change participant", intent: .participantHandoff, state: .results)
    ]
}

nonisolated struct VoiceNormalizationCase: Sendable, CustomTestStringConvertible {
    let transcript: String
    let normalizedPhrase: String
    let intent: VoiceIntent
    let allowedState: VoiceCommandState

    var testDescription: String { transcript }

    static let all: [Self] = [
        .init(
            transcript: "  PAUSE TRAINING!!! ",
            normalizedPhrase: "pause training",
            intent: .pause,
            allowedState: .learn
        ),
        .init(
            transcript: "What’s my score?",
            normalizedPhrase: "whats my score",
            intent: .score,
            allowedState: .results
        ),
        .init(
            transcript: "ＳＨＯＷ—ＴＨＡＴ AGAIN",
            normalizedPhrase: "show that again",
            intent: .repeatDemo,
            allowedState: .learn
        ),
        .init(
            transcript: "\ncontinue\ttraining.\n",
            normalizedPhrase: "continue training",
            intent: .resume,
            allowedState: .trackingPaused
        ),
        .init(
            transcript: "WHY   KEEP MY HANDS UP?!",
            normalizedPhrase: "why keep my hands up",
            intent: .guardExplanation,
            allowedState: .baseline
        )
    ]
}

nonisolated struct VoiceUnsupportedCase: Sendable, CustomTestStringConvertible {
    let transcript: String
    let normalizedPhrase: String

    var testDescription: String { transcript }

    static let all: [Self] = [
        .init(transcript: "unstoppable", normalizedPhrase: "unstoppable"),
        .init(transcript: "please pause training now", normalizedPhrase: "please pause training now"),
        .init(transcript: "scoreboard", normalizedPhrase: "scoreboard"),
        .init(transcript: "next boxer please", normalizedPhrase: "next boxer please"),
        .init(transcript: "show me the target", normalizedPhrase: "show me the target"),
        .init(transcript: "cancel training", normalizedPhrase: "cancel training")
    ]
}

nonisolated struct VoiceGateCase: Sendable, CustomTestStringConvertible {
    let intent: VoiceIntent
    let phrase: String
    let allowedState: VoiceCommandState

    var testDescription: String { "\(intent)" }

    static let all: [Self] = [
        .init(intent: .pause, phrase: "pause", allowedState: .learn),
        .init(intent: .resume, phrase: "resume", allowedState: .trackingPaused),
        .init(intent: .requestEnd, phrase: "end training", allowedState: .learn),
        .init(intent: .confirmEnd, phrase: "confirm end", allowedState: .awaitingEndConfirmation),
        .init(intent: .cancelEnd, phrase: "cancel", allowedState: .awaitingEndConfirmation),
        .init(intent: .repeatDemo, phrase: "repeat", allowedState: .learn),
        .init(intent: .slower, phrase: "slower", allowedState: .learn),
        .init(intent: .normalPace, phrase: "normal speed", allowedState: .learn),
        .init(intent: .faster, phrase: "faster", allowedState: .learn),
        .init(intent: .next, phrase: "next", allowedState: .learn),
        .init(intent: .correction, phrase: "what should i fix", allowedState: .correction),
        .init(intent: .guardExplanation, phrase: "why guard", allowedState: .learn),
        .init(intent: .targetHelp, phrase: "where is the target", allowedState: .learn),
        .init(intent: .progress, phrase: "how many reps", allowedState: .baseline),
        .init(intent: .help, phrase: "help", allowedState: .idle),
        .init(intent: .score, phrase: "score", allowedState: .results),
        .init(intent: .why, phrase: "why", allowedState: .correction),
        .init(intent: .leaderboard, phrase: "leaderboard", allowedState: .idle),
        .init(intent: .participantHandoff, phrase: "next boxer", allowedState: .results)
    ]
}

private nonisolated func requireSendable<T: Sendable>(_ type: T.Type) {}

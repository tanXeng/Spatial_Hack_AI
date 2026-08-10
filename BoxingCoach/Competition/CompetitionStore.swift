import Foundation

nonisolated enum CompetitionSheetRoute: Hashable, Identifiable, Sendable {
    case nameEntry
    case calibrationRequired
    case modes
    case stance
    case leaderboard(CompetitionMode)
    case result(UUID)
    case error

    var id: String { "competition-sheet" }
}

nonisolated enum CompetitionRunKind: Hashable, Sendable {
    case calibration
    case ranked(CompetitionMode)
}

nonisolated struct ActiveCompetitionRun: Hashable, Sendable {
    let id: UUID
    let playerID: UUID
    let kind: CompetitionRunKind
    let startedAt: Date
}

nonisolated enum CompetitionStoreError: LocalizedError, Equatable, Sendable {
    case noPlayer
    case calibrationRequired
    case runAlreadyActive
    case incompleteRun
    case unsafeGuardClearance
    case resetBlocked
    case wrapped(String)

    var errorDescription: String? {
        switch self {
        case .noPlayer: return "Enter a player name before joining the competition."
        case .calibrationRequired: return "Calibrate both arms before choosing a competition mode."
        case .runAlreadyActive: return "Finish the active competition run before starting another."
        case .incompleteRun: return "That run was not complete, so no leaderboard result was saved."
        case .unsafeGuardClearance: return "Your saved reach no longer clears your current guard. Recalibrate before competing."
        case .resetBlocked: return "Finish the active run or save before resetting the competition."
        case .wrapped(let message): return message
        }
    }
}

@Observable
@MainActor
final class CompetitionStore {
    private(set) var sheetRoute: CompetitionSheetRoute?
    private(set) var currentPlayer: CompetitionPlayer?
    private(set) var latestSubmission: CompetitionSubmission?
    private(set) var audiencePublicHandle: ParticipantPublicHandle?
    private(set) var reactiveStandings: [CompetitionStanding] = []
    private(set) var combinationStandings: [CompetitionStanding] = []
    private(set) var activeRun: ActiveCompetitionRun?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var coachingCyclePersistenceScope: CoachingCyclePersistenceScope
    var nameDraft = ""
    var selectedStance: Stance = .orthodox

    private let repository: any CompetitionRepository
    private let now: () -> Date
    private var didBootstrap = false
    private let audienceEventID = UUID()

    init(
        repository: any CompetitionRepository,
        startupError: String? = nil,
        coachingCyclePersistenceScope: CoachingCyclePersistenceScope = .durable,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
        self.coachingCyclePersistenceScope = coachingCyclePersistenceScope
        errorMessage = startupError
    }

    static func live(
        makePersistentRepository: @MainActor () throws -> any CompetitionRepository = {
            let container = try CompetitionModelContainer.make(inMemory: false)
            return CompetitionLiveRepositoryFactory.makeLiveRepository(
                container: container
            )
        },
        makeSessionRepository: @MainActor () -> any CompetitionRepository = {
            InMemoryCompetitionRepository()
        }
    ) -> CompetitionStore {
        do {
            return CompetitionStore(
                repository: try makePersistentRepository(),
                coachingCyclePersistenceScope: .durable
            )
        } catch {
            return CompetitionStore(
                repository: makeSessionRepository(),
                startupError: "Saved competition data is unavailable. Results will last only until the app closes.",
                coachingCyclePersistenceScope: .sessionOnly
            )
        }
    }

    static func preview(
        route: CompetitionSheetRoute = .nameEntry,
        player: CompetitionPlayer? = nil,
        reactiveStandings: [CompetitionStanding] = [],
        combinationStandings: [CompetitionStanding] = [],
        errorMessage: String? = nil,
        latestSubmission: CompetitionSubmission? = nil
    ) -> CompetitionStore {
        let store = CompetitionStore(repository: InMemoryCompetitionRepository())
        store.sheetRoute = route
        store.currentPlayer = player
        store.selectedStance = player?.rememberedStance ?? .orthodox
        store.reactiveStandings = reactiveStandings
        store.combinationStandings = combinationStandings
        store.errorMessage = errorMessage
        store.latestSubmission = latestSubmission
        return store
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = await reloadBoards()
    }

    func open() {
        errorMessage = nil
        if let currentPlayer {
            selectedStance = currentPlayer.rememberedStance
            sheetRoute = currentPlayer.hasCurrentCalibration ? .modes : .calibrationRequired
        } else {
            sheetRoute = .nameEntry
        }
    }

    func dismiss() {
        guard activeRun == nil, !isSaving else { return }
        sheetRoute = nil
        errorMessage = nil
    }

    func join(name rawName: String) async {
        guard !isLoading, !isSaving, activeRun == nil else {
            present(CompetitionStoreError.runAlreadyActive)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let name = try CompetitionName.display(rawName)
            let normalized = CompetitionName.normalized(name)
            var player: CompetitionPlayer
            if let existing = try await repository.player(normalizedName: normalized) {
                player = existing
                player.name = name
                player.lastSeenAt = now()
            } else {
                let timestamp = now()
                player = CompetitionPlayer(
                    id: UUID(),
                    name: name,
                    normalizedName: normalized,
                    rememberedStance: .orthodox,
                    reach: nil,
                    calibrationVersion: nil,
                    calibratedAt: nil,
                    createdAt: timestamp,
                    lastSeenAt: timestamp
                )
            }
            try await repository.save(player: player)
            currentPlayer = player
            audiencePublicHandle = Self.makeAudienceHandle(
                eventID: audienceEventID,
                playerID: player.id
            )
            selectedStance = player.rememberedStance
            nameDraft = player.name
            errorMessage = nil
            sheetRoute = player.hasCurrentCalibration ? .modes : .calibrationRequired
        } catch {
            present(error)
        }
    }

    func showNameEntry() {
        guard activeRun == nil else { return }
        nameDraft = currentPlayer?.name ?? ""
        errorMessage = nil
        sheetRoute = .nameEntry
    }

    func prepareCalibration() -> TrainingSelection? {
        guard let player = currentPlayer else {
            present(CompetitionStoreError.noPlayer)
            return nil
        }
        guard !isLoading, !isSaving, activeRun == nil else {
            present(CompetitionStoreError.runAlreadyActive)
            return nil
        }
        let run = ActiveCompetitionRun(
            id: UUID(),
            playerID: player.id,
            kind: .calibration,
            startedAt: now()
        )
        activeRun = run
        errorMessage = nil
        sheetRoute = nil
        return .competitionCalibration(playerID: player.id)
    }

    func chooseMode(_ mode: CompetitionMode) async -> TrainingSelection? {
        guard !isLoading, !isSaving, activeRun == nil else {
            present(CompetitionStoreError.runAlreadyActive)
            return nil
        }
        guard let player = currentPlayer else {
            present(CompetitionStoreError.noPlayer)
            return nil
        }
        guard player.hasCurrentCalibration else {
            present(CompetitionStoreError.calibrationRequired)
            sheetRoute = .calibrationRequired
            return nil
        }
        if mode == .combination {
            selectedStance = player.rememberedStance
            sheetRoute = .stance
            return nil
        }
        return await prepareRankedRun(mode: mode, stance: player.rememberedStance)
    }

    func startCombination(stance: Stance) async -> TrainingSelection? {
        await prepareRankedRun(mode: .combination, stance: stance)
    }

    func showModes() {
        guard currentPlayer != nil, activeRun == nil else { return }
        errorMessage = nil
        sheetRoute = currentPlayer?.hasCurrentCalibration == true ? .modes : .calibrationRequired
    }

    func showLeaderboard(_ mode: CompetitionMode) {
        errorMessage = nil
        sheetRoute = .leaderboard(mode)
    }

    func cancelActiveRun(message: String) {
        activeRun = nil
        errorMessage = message
        sheetRoute = currentPlayer?.hasCurrentCalibration == true ? .modes : .calibrationRequired
    }

    func reconcileCompletedRun(session: ReactiveStrikeSession) async {
        guard let run = activeRun, !isSaving else { return }
        guard session.phase == .finished
                || session.errorMessage != nil
                || session.competitionRequiresRecalibration
                || session.lastFeedback == "Drill stopped"
        else {
            return
        }
        isSaving = true
        defer { isSaving = false }

        do {
            guard var player = try await repository.player(id: run.playerID) else {
                throw CompetitionStoreError.noPlayer
            }

            switch run.kind {
            case .calibration:
                guard session.phase == .finished,
                      !session.wasStoppedBeforeCompletion,
                      let reach = BilateralReach(session.latestCalibratedReaches)
                else { throw CompetitionStoreError.incompleteRun }
                player.reach = reach
                player.calibrationVersion = CompetitionPlayer.calibrationVersion
                player.calibratedAt = now()
                player.lastSeenAt = now()
                try await repository.save(player: player)
                currentPlayer = player
                activeRun = nil
                errorMessage = nil
                sheetRoute = .modes

            case .ranked(let mode):
                guard !session.wasStoppedBeforeCompletion else {
                    throw CompetitionStoreError.incompleteRun
                }
                if session.competitionRequiresRecalibration {
                    player.reach = nil
                    player.calibrationVersion = nil
                    player.calibratedAt = nil
                    try await repository.save(player: player)
                    currentPlayer = player
                    activeRun = nil
                    throw CompetitionStoreError.unsafeGuardClearance
                }
                guard session.phase == .finished,
                      session.errorMessage == nil,
                      let evidence = evidence(for: mode, session: session),
                      let submission = CompetitionScorer.submission(
                        id: run.id,
                        player: player,
                        evidence: evidence,
                        startedAt: run.startedAt,
                        endedAt: now()
                      )
                else { throw CompetitionStoreError.incompleteRun }
                latestSubmission = try await repository.submit(submission)
                activeRun = nil
                errorMessage = nil
                await reloadBoards()
                sheetRoute = .result(submission.id)
            }
        } catch {
            activeRun = nil
            present(error)
            if case CompetitionStoreError.unsafeGuardClearance = error {
                sheetRoute = .calibrationRequired
            } else if currentPlayer?.hasCurrentCalibration == true {
                sheetRoute = .modes
            } else {
                sheetRoute = .calibrationRequired
            }
        }
    }

    func resetConfirmed() async {
        guard activeRun == nil, !isSaving else {
            present(CompetitionStoreError.resetBlocked)
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.reset()
            currentPlayer = nil
            audiencePublicHandle = nil
            latestSubmission = nil
            reactiveStandings = []
            combinationStandings = []
            nameDraft = ""
            selectedStance = .orthodox
            errorMessage = nil
            sheetRoute = .nameEntry
        } catch {
            present(error)
        }
    }

    func standings(for mode: CompetitionMode) -> [CompetitionStanding] {
        mode == .reactiveStrike ? reactiveStandings : combinationStandings
    }

    private static func makeAudienceHandle(
        eventID: UUID,
        playerID: UUID
    ) -> ParticipantPublicHandle? {
        let numeric = playerID.uuidString.utf8.reduce(0) { partial, byte in
            (partial * 31 + Int(byte)) % 10_000
        }
        return ParticipantPublicHandle.reserving(
            eventID: eventID,
            displayName: "Boxer",
            displayCode: String(format: "%04d", numeric),
            against: []
        )
    }

    /// Persists the six original admitted attempts and the fitted reach at the deterministic Aura
    /// completion boundary. No aggregate score is assigned a punch identity.
    func persistCoachingCycle(
        _ result: CoachingCycleResult,
        fittedReach: BilateralReach
    ) async throws {
        guard let player = currentPlayer else { throw CompetitionStoreError.noPlayer }
        currentPlayer = try await persistCoachingCycle(
            result,
            fittedReach: fittedReach,
            for: player
        )
    }

    /// Gives standalone Aura a durable, non-identifying participant instead of silently dropping
    /// its proof on a fresh launch. The participant is published only after the cycle transaction
    /// succeeds, so visible "saved" state always has a matching durable record.
    @discardableResult
    func persistStandaloneCoachingCycle(
        _ result: CoachingCycleResult,
        fittedReach: BilateralReach
    ) async throws -> CoachingCyclePersistenceScope {
        let localName = "Local Athlete"
        let normalizedName = CompetitionName.normalized(localName)
        let timestamp = now()
        let player: CompetitionPlayer
        if let currentPlayer {
            player = currentPlayer
        } else {
            player = try await repository.player(normalizedName: normalizedName) ?? CompetitionPlayer(
                id: UUID(),
                name: localName,
                normalizedName: normalizedName,
                rememberedStance: result.stance,
                reach: nil,
                calibrationVersion: nil,
                calibratedAt: nil,
                createdAt: timestamp,
                lastSeenAt: timestamp
            )
        }
        let persisted = try await persistCoachingCycle(
            result,
            fittedReach: fittedReach,
            for: player
        )
        currentPlayer = persisted
        selectedStance = persisted.rememberedStance
        return coachingCyclePersistenceScope
    }

    private func persistCoachingCycle(
        _ result: CoachingCycleResult,
        fittedReach: BilateralReach,
        for participant: CompetitionPlayer
    ) async throws -> CompetitionPlayer {
        var player = participant
        player.rememberedStance = result.stance
        let roundProof = result.proof

        let admitted = roundProof.baseline.attempts + roundProof.retest.attempts
        guard admitted.count == CoachingCycleSession.requiredAttempts * 2 else {
            throw CompetitionStoreError.incompleteRun
        }
        let snapshots = try admitted.map { attempt -> TechniqueAttemptSnapshot in
            let evidence = attempt.evidence
            guard let scoringVersion = Int(exactly: evidence.identity.scoringVersion),
                  let calibrationVersion = Int(exactly: evidence.identity.calibrationVersion),
                  let snapshot = TechniqueAttemptSnapshot(
                    id: evidence.identity.id,
                    athleteID: player.id,
                    eventID: player.publicHandle?.eventID,
                    techniqueID: result.technique.id,
                    score: evidence.score.overall,
                    scoringVersion: scoringVersion,
                    calibrationVersion: calibrationVersion,
                    startedAt: result.completedAt.addingTimeInterval(-evidence.score.duration),
                    completedAt: result.completedAt,
                    publicHandleSnapshot: player.publicHandle
                  )
            else { throw CompetitionStoreError.incompleteRun }
            return snapshot
        }

        let existing = try await repository.techniqueAttempts(
            athleteID: player.id,
            techniqueID: result.technique.id
        )
        var attemptsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for snapshot in snapshots {
            if let existing = attemptsByID[snapshot.id], existing != snapshot {
                throw CompetitionStoreError.incompleteRun
            }
            attemptsByID[snapshot.id] = snapshot
        }
        let stored = attemptsByID.values.sorted { $0.completedAt < $1.completedAt }
        let trace = roundProof.retest.attempts.last.flatMap(Self.pastSelfTrace)
        let updatedAt = max(now(), result.completedAt)
        guard let memory = AthleteSkillMemory(
            athleteID: player.id,
            techniqueID: result.technique.id,
            experienceLevel: player.experienceLevel,
            attempts: stored,
            pastSelfTrace: trace,
            updatedAt: updatedAt
        ) else { throw CompetitionStoreError.incompleteRun }
        player.reach = fittedReach
        player.calibrationVersion = CompetitionPlayer.calibrationVersion
        player.calibratedAt = updatedAt
        player.lastSeenAt = updatedAt
        let cycleSnapshot = try CoachingCycleSnapshot(
            result: result,
            athleteID: player.id,
            eventID: player.publicHandle?.eventID,
            fittedReach: fittedReach
        )
        let transaction = try CoachingCycleMemoryTransaction(
            player: player,
            legacyAttempts: snapshots,
            skillMemory: memory,
            cycle: cycleSnapshot
        )
        try await repository.save(coachingCycle: transaction)
        return player
    }

    private func prepareRankedRun(
        mode: CompetitionMode,
        stance: Stance
    ) async -> TrainingSelection? {
        guard activeRun == nil, !isLoading, !isSaving else {
            present(CompetitionStoreError.runAlreadyActive)
            return nil
        }
        guard var player = currentPlayer, let reach = player.reach else {
            present(CompetitionStoreError.calibrationRequired)
            sheetRoute = .calibrationRequired
            return nil
        }
        player.rememberedStance = stance
        player.lastSeenAt = now()
        let run = ActiveCompetitionRun(
            id: UUID(),
            playerID: player.id,
            kind: .ranked(mode),
            startedAt: now()
        )
        // Reserve the run before persistence suspends. A second tap therefore observes an active
        // operation instead of starting a competing save and immersive transition.
        activeRun = run
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.save(player: player)
            currentPlayer = player
            selectedStance = stance
            errorMessage = nil
            sheetRoute = nil
            return .competition(
                playerID: player.id,
                mode: mode,
                stance: stance,
                reach: reach
            )
        } catch {
            activeRun = nil
            present(error)
            return nil
        }
    }

    private static func pastSelfTrace(
        from attempt: CoachingAttemptEvidence
    ) -> PastSelfTrace? {
        guard let firstTime = attempt.actualSamples.first?.time,
              let lastTime = attempt.actualSamples.last?.time
        else { return nil }
        let duration = max(lastTime - firstTime, 1e-6)
        let samples = attempt.actualSamples.map { sample in
            NormalizedTraceSample(
                time: Float((sample.time - firstTime) / duration),
                position: sample.fist
            )
        }
        return PastSelfTrace(
            attemptID: attempt.evidence.identity.id,
            coordinateSpace: .normalizedBody,
            samples: samples
        )
    }

    private func evidence(
        for mode: CompetitionMode,
        session: ReactiveStrikeSession
    ) -> CompetitionEvidence? {
        switch mode {
        case .reactiveStrike:
            let attempts = session.metrics.attempts
            guard attempts.count == mode.totalSteps else { return nil }
            let steps = attempts.enumerated().map { index, attempt in
                CompetitionStepEvidence(
                    index: index,
                    valid: attempt.result == .hit,
                    centreErrorMeters: attempt.result == .hit ? attempt.distanceAtHit : nil,
                    reactionTime: attempt.result == .hit ? attempt.reactionTime : nil,
                    requiredHand: nil,
                    returnedToGuard: attempt.result == .hit
                )
            }
            return CompetitionEvidence(
                mode: mode,
                steps: steps,
                completedRepetitions: 0,
                activeElapsedTime: nil,
                trackingStatus: session.competitionTrackingStatus
            )

        case .combination:
            guard session.competitionSteps.count == mode.totalSteps else { return nil }
            return CompetitionEvidence(
                mode: mode,
                steps: session.competitionSteps,
                completedRepetitions: session.comboRepsCompleted,
                activeElapsedTime: session.competitionActiveElapsedTime,
                trackingStatus: session.competitionTrackingStatus
            )
        }
    }

    @discardableResult
    private func reloadBoards() async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let submissions = try await repository.submissions()
            reactiveStandings = CompetitionLeaderboard.standings(
                mode: .reactiveStrike,
                submissions: submissions
            )
            combinationStandings = CompetitionLeaderboard.standings(
                mode: .combination,
                submissions: submissions
            )
            errorMessage = nil
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func present(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

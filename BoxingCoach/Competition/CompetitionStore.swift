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
    private(set) var reactiveStandings: [CompetitionStanding] = []
    private(set) var combinationStandings: [CompetitionStanding] = []
    private(set) var activeRun: ActiveCompetitionRun?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    var nameDraft = ""
    var selectedStance: Stance = .orthodox

    private let repository: any CompetitionRepository
    private let now: () -> Date
    private var didBootstrap = false

    init(
        repository: any CompetitionRepository,
        startupError: String? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
        errorMessage = startupError
    }

    static func live() -> CompetitionStore {
        do {
            let container = try CompetitionModelContainer.make(inMemory: false)
            return CompetitionStore(repository: CompetitionLiveRepositoryFactory.makeLiveRepository(
                container: container
            ))
        } catch {
            return CompetitionStore(
                repository: InMemoryCompetitionRepository(),
                startupError: "Saved competition data is unavailable. Results will last only until the app closes."
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

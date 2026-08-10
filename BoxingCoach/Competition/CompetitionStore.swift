import Foundation

nonisolated enum CompetitionSheetRoute: Hashable, Identifiable, Sendable {
    case welcome
    case nameEntry
    case codeEntry
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
    case durableMemoryRequired
    case wrapped(String)

    var errorDescription: String? {
        switch self {
        case .noPlayer: return "Enter a player name before joining the competition."
        case .calibrationRequired: return "Calibrate both arms before choosing a competition mode."
        case .runAlreadyActive: return "Finish the active competition run before starting another."
        case .incompleteRun: return "That run was not complete, so no leaderboard result was saved."
        case .unsafeGuardClearance: return "Your saved reach no longer clears your current guard. Recalibrate before competing."
        case .resetBlocked: return "Finish the active run or save before resetting the competition."
        case .durableMemoryRequired:
            return "Aura proof needs durable athlete memory. Restore local storage, then try again."
        case .wrapped(let message): return message
        }
    }
}

struct RecoveredAuraResult: Equatable, Sendable {
    let runID: UUID
    let selection: TrainingSelection
    let snapshot: CoachingCycleSnapshot
}

nonisolated enum CoachingCyclePersistenceOutcome: Equatable, Sendable {
    case idle
    case reserved(UUID)
    case active(UUID)
    case staged(UUID)
    case committed(UUID)
    case aborted(UUID)
    case failed(String)
}

@Observable
@MainActor
final class CompetitionStore {
    /// Reserved persistence key outside the user-enterable competition-name alphabet.
    static let standaloneAuraNormalizedName = "boxcoach://standalone-aura"

    private(set) var sheetRoute: CompetitionSheetRoute?
    private(set) var currentEvent: EventEdition?
    private(set) var currentPlayer: CompetitionPlayer?
    private(set) var latestSubmission: CompetitionSubmission?
    private(set) var reactiveStandings: [CompetitionStanding] = []
    private(set) var combinationStandings: [CompetitionStanding] = []
    private(set) var activeRun: ActiveCompetitionRun?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var coachingCyclePersistenceScope: CoachingCyclePersistenceScope
    private(set) var coachingCyclePersistenceOutcome: CoachingCyclePersistenceOutcome = .idle
    private(set) var latestCoachingCycle: CoachingCycleSnapshot?
    private(set) var recoveredAuraResult: RecoveredAuraResult?
    var nameDraft = ""
    var codeDraft = ""
    var selectedStance: Stance = .orthodox
    var selectedExperienceLevel: ExperienceLevel = .beginner

    var currentTrainingTrack: TrainingTrack? {
        guard let currentPlayer else { return nil }
        return currentPlayer.experienceLevel == .beginner ? .firstRound : .technicalCamp
    }

    private let repository: any CompetitionRepository
    private let now: () -> Date
    private let postParticipantCommitRefresh: @MainActor () async throws -> Void
    private var didBootstrap = false
    private var activeAuraRunID: UUID?
    private var completionOwnedAuraRunIDs: Set<UUID> = []

    init(
        repository: any CompetitionRepository,
        startupError: String? = nil,
        coachingCyclePersistenceScope: CoachingCyclePersistenceScope = .durable,
        postParticipantCommitRefresh: @escaping @MainActor () async throws -> Void = {},
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.now = now
        self.postParticipantCommitRefresh = postParticipantCommitRefresh
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
        do {
            currentEvent = try await repository.activeEvent()
            if currentEvent == nil {
                currentEvent = try await repository.create(event: try makeEvent())
            }
            try await reconcileDurableCoachingRuns()
            didBootstrap = await reloadBoards()
        } catch {
            present(error)
        }
    }

    func open() {
        errorMessage = nil
        if let currentPlayer {
            selectedStance = currentPlayer.rememberedStance
            sheetRoute = currentPlayer.hasCurrentCalibration ? .modes : .calibrationRequired
        } else {
            sheetRoute = .welcome
        }
    }

    func showWelcome() {
        guard activeRun == nil else { return }
        errorMessage = nil
        sheetRoute = .welcome
    }

    func showCodeEntry() {
        guard activeRun == nil else { return }
        codeDraft = ""
        errorMessage = nil
        sheetRoute = .codeEntry
    }

    func dismiss() {
        guard activeRun == nil, !isSaving else { return }
        sheetRoute = nil
        errorMessage = nil
    }

    func join(name rawName: String) async {
        await createParticipant(
            name: rawName,
            experienceLevel: selectedExperienceLevel,
            stance: selectedStance
        )
    }

    func createParticipant(
        name rawName: String,
        experienceLevel: ExperienceLevel,
        stance: Stance
    ) async {
        guard !isLoading, !isSaving, activeRun == nil else {
            present(CompetitionStoreError.runAlreadyActive)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let name = try CompetitionName.display(rawName)
            let event = try await requireActiveEvent()
            let player = try await repository.createParticipant(
                eventID: event.id,
                displayName: name,
                experienceLevel: experienceLevel,
                stance: stance,
                at: now()
            )
            currentPlayer = player
            selectedStance = player.rememberedStance
            selectedExperienceLevel = player.experienceLevel
            nameDraft = player.name
            errorMessage = nil
            sheetRoute = player.hasCurrentCalibration ? .modes : .calibrationRequired
            do {
                try await postParticipantCommitRefresh()
            } catch {
                errorMessage = "Profile saved. Some event details could not be refreshed."
            }
        } catch {
            present(error)
        }
    }

    func rejoin(code rawCode: String) async {
        guard !isLoading, !isSaving, activeRun == nil else {
            present(CompetitionStoreError.runAlreadyActive)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard code.count == 4,
                  code.unicodeScalars.allSatisfy({ (48...57).contains($0.value) })
            else {
                throw CompetitionStoreError.wrapped("Enter the four-digit code shown on your profile.")
            }
            let event = try await requireActiveEvent()
            guard var player = try await repository.participant(
                eventID: event.id,
                displayCode: code
            ) else {
                throw CompetitionStoreError.wrapped("No participant in this event has code \(code).")
            }
            player.lastSeenAt = now()
            player = try await repository.saveParticipant(player)
            currentPlayer = player
            selectedStance = player.rememberedStance
            selectedExperienceLevel = player.experienceLevel
            nameDraft = player.name
            codeDraft = code
            latestSubmission = nil
            errorMessage = nil
            sheetRoute = player.hasCurrentCalibration ? .modes : .calibrationRequired
        } catch {
            present(error)
        }
    }

    func handoffToWelcome() async {
        currentPlayer = nil
        latestSubmission = nil
        latestCoachingCycle = nil
        recoveredAuraResult = nil
        coachingCyclePersistenceOutcome = .idle
        activeRun = nil
        activeAuraRunID = nil
        nameDraft = ""
        codeDraft = ""
        selectedStance = .orthodox
        selectedExperienceLevel = .beginner
        errorMessage = nil
        sheetRoute = .welcome
    }

    func showNameEntry() {
        guard activeRun == nil else { return }
        nameDraft = ""
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
                currentPlayer = try await repository.saveParticipant(player)
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
                    currentPlayer = try await repository.saveParticipant(player)
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
            currentEvent = nil
            latestSubmission = nil
            activeAuraRunID = nil
            latestCoachingCycle = nil
            recoveredAuraResult = nil
            coachingCyclePersistenceOutcome = .idle
            reactiveStandings = []
            combinationStandings = []
            nameDraft = ""
            codeDraft = ""
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

    func acknowledgeAuraResultDelivery(id: UUID) async {
        do {
            try await repository.acknowledgeAuraResultDelivery(runID: id, at: now())
            if recoveredAuraResult?.runID == id { recoveredAuraResult = nil }
        } catch {
            coachingCyclePersistenceOutcome = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func reserveAuraRun(
        _ selection: TrainingSelection,
        id: UUID = UUID()
    ) async throws -> UUID {
        guard case .aura(_, let technique, _) = selection else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        guard coachingCyclePersistenceScope == .durable else {
            throw CompetitionStoreError.durableMemoryRequired
        }
        if let activeAuraRunID,
           let existing = try await repository.trainingRun(id: activeAuraRunID),
           existing.status == .reserved || existing.status == .active
        {
            throw CompetitionStoreError.runAlreadyActive
        }
        let player = try await standaloneAuraParticipant(for: selection)
        guard let pending = PendingTrainingRun(
            id: id,
            athleteID: player.id,
            eventID: player.eventID,
            techniqueID: technique.id,
            requestedAt: now()
        ) else { throw AthleteMemoryRepositoryError.invalidRunTransition }
        guard case .aura(let track, _, let stance) = selection else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        let reserved = try await repository.reserveTrainingRun(
            pending,
            descriptor: .aura(
                runID: id,
                track: track,
                technique: technique,
                stance: stance
            )
        )
        activeAuraRunID = reserved.id
        latestCoachingCycle = nil
        recoveredAuraResult = nil
        coachingCyclePersistenceOutcome = .reserved(reserved.id)
        return reserved.id
    }

    func activateAuraRun(id: UUID) async throws {
        guard activeAuraRunID == id else {
            throw AthleteMemoryRepositoryError.runParticipantMismatch
        }
        let active = try await repository.activateTrainingRun(id: id, at: now())
        coachingCyclePersistenceOutcome = .active(active.id)
    }

    func abortAuraRun(id: UUID) async {
        do {
            let aborted = try await repository.abortTrainingRun(id: id, at: now())
            coachingCyclePersistenceOutcome = .aborted(aborted.id)
            if activeAuraRunID == id { activeAuraRunID = nil }
        } catch {
            coachingCyclePersistenceOutcome = .failed(error.localizedDescription)
        }
    }

    func markAuraCompletionStarted(id: UUID) {
        completionOwnedAuraRunIDs.insert(id)
    }

    func abortSceneOwnedAuraRunIfNeeded(id: UUID) async {
        guard !completionOwnedAuraRunIDs.contains(id) else { return }
        do {
            guard let descriptor = try await repository.trainingRunDescriptor(id: id),
                  descriptor.kind == .auraCoaching,
                  let run = try await repository.trainingRun(id: id),
                  run.status == .reserved || run.status == .active
            else { return }
            await abortAuraRun(id: id)
        } catch {
            coachingCyclePersistenceOutcome = .failed(error.localizedDescription)
        }
    }

    func stageReservedAuraCoachingCycle(
        _ result: CoachingCycleResult,
        fittedReach: BilateralReach,
        runID: UUID
    ) async throws {
        guard result.id == runID,
              activeAuraRunID == runID,
              let run = try await repository.trainingRun(id: runID),
              let participant = try await repository.player(id: run.athleteID),
              participant.id == run.athleteID,
              participant.eventID == run.eventID,
              result.technique.id == run.techniqueID
        else { throw AthleteMemoryRepositoryError.runParticipantMismatch }
        let transaction = try await makeCoachingCycleTransaction(
            result,
            fittedReach: fittedReach,
            for: participant
        )
        _ = try await repository.stageCoachingCycle(runID: runID, transaction: transaction)
        coachingCyclePersistenceOutcome = .staged(runID)
    }

    @discardableResult
    func persistReservedAuraCoachingCycle(
        _ result: CoachingCycleResult,
        fittedReach: BilateralReach,
        runID: UUID
    ) async throws -> CoachingCyclePersistenceScope {
        do {
            try await stageReservedAuraCoachingCycle(
                result,
                fittedReach: fittedReach,
                runID: runID
            )
            let staged = try await repository.trainingRun(id: runID)
            let commitDate = max(now(), staged?.completedAt ?? now())
            let committed = try await repository.commitCoachingCycle(
                runID: runID,
                at: commitDate
            )
            coachingCyclePersistenceOutcome = .committed(committed.id)
            latestCoachingCycle = try await repository.coachingCycle(id: committed.id)
            activeAuraRunID = committed.id
            completionOwnedAuraRunIDs.remove(committed.id)
            if currentPlayer?.id == committed.athleteID {
                currentPlayer = try await repository.player(id: committed.athleteID)
            }
            return coachingCyclePersistenceScope
        } catch {
            if let run = try? await repository.trainingRun(id: runID),
               run.status == .completedAwaitingCommit {
                do {
                    let committed = try await repository.commitCoachingCycle(
                        runID: runID,
                        at: max(now(), run.completedAt ?? now())
                    )
                    coachingCyclePersistenceOutcome = .committed(committed.id)
                    latestCoachingCycle = try await repository.coachingCycle(id: committed.id)
                    completionOwnedAuraRunIDs.remove(committed.id)
                    return coachingCyclePersistenceScope
                } catch {
                    coachingCyclePersistenceOutcome = .failed(error.localizedDescription)
                    throw error
                }
            }
            completionOwnedAuraRunIDs.remove(runID)
            coachingCyclePersistenceOutcome = .failed(error.localizedDescription)
            throw error
        }
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
    /// its proof. This identity is deliberately separate from `currentPlayer`: a person entering
    /// Aura after a competition participant must never append coaching evidence to that participant.
    @discardableResult
    func persistStandaloneCoachingCycle(
        _ result: CoachingCycleResult,
        fittedReach: BilateralReach
    ) async throws -> CoachingCyclePersistenceScope {
        if let activeAuraRunID {
            return try await persistReservedAuraCoachingCycle(
                result,
                fittedReach: fittedReach,
                runID: activeAuraRunID
            )
        }
        let localName = "Local Athlete"
        let normalizedName = Self.standaloneAuraNormalizedName
        let timestamp = now()
        let player = try await repository.player(normalizedName: normalizedName) ?? CompetitionPlayer(
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
        _ = try await persistCoachingCycle(
            result,
            fittedReach: fittedReach,
            for: player
        )
        return coachingCyclePersistenceScope
    }

    private func persistCoachingCycle(
        _ result: CoachingCycleResult,
        fittedReach: BilateralReach,
        for participant: CompetitionPlayer
    ) async throws -> CompetitionPlayer {
        let transaction = try await makeCoachingCycleTransaction(
            result,
            fittedReach: fittedReach,
            for: participant
        )
        try await repository.save(coachingCycle: transaction)
        return transaction.player
    }

    private func makeCoachingCycleTransaction(
        _ result: CoachingCycleResult,
        fittedReach: BilateralReach,
        for participant: CompetitionPlayer
    ) async throws -> CoachingCycleMemoryTransaction {
        var player = participant
        player.rememberedStance = result.stance
        let baseline = result.proof.baseline.attempts
        let retest = result.proof.retest.attempts
        guard baseline.count == CoachingCycleSession.requiredAttempts,
              retest.count == CoachingCycleSession.requiredAttempts
        else { throw CompetitionStoreError.incompleteRun }

        let baselineIDs = baseline.map(\.evidence.identity.id)
        let ordered = baseline.enumerated().map { ($0.offset, CoachingAttemptStage.baseline, $0.element) }
            + retest.enumerated().map { ($0.offset, CoachingAttemptStage.retest, $0.element) }
        let lastEvidenceTime = ordered.map { $0.2.evidence.punch.returnedAt }.max()
            ?? result.completedAt.timeIntervalSinceReferenceDate
        let snapshots = try ordered.map { index, stage, attempt -> TechniqueAttemptSnapshot in
            let evidence = attempt.evidence
            let metricSnapshots = try evidence.score.metrics.map { metric -> TechniqueMetricSnapshot in
                guard let quality = evidence.quality(for: metric.kind) else {
                    throw LearningEvidenceRejectionReason.missingMetricQuality(metric.kind)
                }
                let provenance: TechniqueMetricProvenance = switch quality {
                case .measured: .measured
                case .inferred: .inferred
                }
                guard let snapshot = TechniqueMetricSnapshot(
                    kind: metric.kind.rawValue,
                    score: metric.score,
                    provenance: provenance
                ) else { throw CompetitionStoreError.incompleteRun }
                return snapshot
            }
            guard let scoringVersion = Int(exactly: evidence.identity.scoringVersion),
                  let referenceVersion = Int(exactly: evidence.identity.referenceVersion),
                  let calibrationVersion = Int(exactly: evidence.identity.calibrationVersion),
                  let snapshot = TechniqueAttemptSnapshot(
                    id: evidence.identity.id,
                    athleteID: player.id,
                    eventID: player.eventID,
                    coachingCycleID: result.id,
                    stage: stage == .baseline ? .baseline : .retest,
                    cycleOrdinal: index + 1,
                    techniqueID: result.technique.id,
                    stance: result.stance,
                    score: evidence.score.overall,
                    metrics: metricSnapshots,
                    trackedFraction: evidence.score.trackedFraction,
                    duration: evidence.score.duration,
                    isValid: !evidence.score.wrongHand,
                    wrongHand: evidence.score.wrongHand,
                    scoringVersion: scoringVersion,
                    referenceVersion: referenceVersion,
                    calibrationVersion: calibrationVersion,
                    correctionCode: result.selectedProof.correctionCode.rawValue,
                    baselineAttemptID: stage == .retest ? baselineIDs[index] : nil,
                    startedAt: result.completedAt.addingTimeInterval(
                        evidence.punch.returnedAt - lastEvidenceTime - evidence.score.duration
                    ),
                    completedAt: result.completedAt.addingTimeInterval(
                        evidence.punch.returnedAt - lastEvidenceTime
                    ),
                    pastSelfTrace: stage == .retest ? Self.pastSelfTrace(from: attempt) : nil,
                    publicHandleSnapshot: player.publicHandle
                  )
            else { throw CompetitionStoreError.incompleteRun }
            return snapshot
        }

        let existing = try await repository.techniqueAttempts(
            athleteID: player.id,
            techniqueID: result.technique.id
        )
        guard let key = snapshots.first?.memoryKey else {
            throw CompetitionStoreError.incompleteRun
        }
        var attemptsByID = Dictionary(uniqueKeysWithValues: existing
            .filter { $0.memoryKey == key }
            .map { ($0.id, $0) })
        for snapshot in snapshots {
            if let existing = attemptsByID[snapshot.id], existing != snapshot {
                throw AthleteMemoryRepositoryError.attemptParticipantMismatch
            }
            attemptsByID[snapshot.id] = snapshot
        }
        let stored = attemptsByID.values.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt < $1.completedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let updatedAt = max(now(), result.completedAt)
        guard let memory = AthleteSkillMemory(
            athleteID: player.id,
            techniqueID: result.technique.id,
            experienceLevel: player.experienceLevel,
            attempts: stored,
            pastSelfTrace: retest.last.flatMap(Self.pastSelfTrace),
            updatedAt: updatedAt
        ) else { throw CompetitionStoreError.incompleteRun }
        player.reach = fittedReach
        player.calibrationVersion = CompetitionPlayer.calibrationVersion
        player.calibratedAt = updatedAt
        player.lastSeenAt = updatedAt
        return try CoachingCycleMemoryTransaction(
            player: player,
            legacyAttempts: snapshots,
            skillMemory: memory,
            cycle: CoachingCycleSnapshot(
                result: result,
                athleteID: player.id,
                eventID: player.eventID,
                fittedReach: fittedReach
            )
        )
    }

    private func standaloneAuraParticipant(
        for selection: TrainingSelection
    ) async throws -> CompetitionPlayer {
        guard case .aura(let track, _, let stance) = selection else {
            throw AthleteMemoryRepositoryError.invalidRunTransition
        }
        let timestamp = now()
        var player = try await repository.player(normalizedName: Self.standaloneAuraNormalizedName)
            ?? CompetitionPlayer(
                id: UUID(),
                name: "Local Athlete",
                normalizedName: Self.standaloneAuraNormalizedName,
                rememberedStance: stance,
                reach: nil,
                calibrationVersion: nil,
                calibratedAt: nil,
                createdAt: timestamp,
                lastSeenAt: timestamp,
                experienceLevel: track == .firstRound ? .beginner : .advanced
            )
        player.rememberedStance = stance
        player.lastSeenAt = timestamp
        player = CompetitionPlayer(
            id: player.id,
            name: player.name,
            normalizedName: player.normalizedName,
            rememberedStance: player.rememberedStance,
            reach: player.reach,
            calibrationVersion: player.calibrationVersion,
            calibratedAt: player.calibratedAt,
            createdAt: player.createdAt,
            lastSeenAt: player.lastSeenAt,
            experienceLevel: track == .firstRound ? .beginner : .advanced,
            publicHandle: player.publicHandle
        )
        try await repository.save(player: player)
        return player
    }

    private func reconcileDurableCoachingRuns() async throws {
        for run in try await repository.trainingRuns() {
            guard let descriptor = try await repository.trainingRunDescriptor(id: run.id) else {
                throw AthleteMemoryRepositoryError.corruptData
            }
            guard descriptor.kind == .auraCoaching else {
                // Ranked and explicitly migrated legacy reservations remain Task 6's ownership.
                continue
            }
            switch run.status {
            case .completedAwaitingCommit:
                let commitDate = max(now(), run.completedAt ?? now())
                let committed = try await repository.commitCoachingCycle(
                    runID: run.id,
                    at: commitDate
                )
                coachingCyclePersistenceOutcome = .committed(committed.id)
                latestCoachingCycle = try await repository.coachingCycle(id: committed.id)
                if !(try await repository.isAuraResultDeliveryAcknowledged(runID: run.id)) {
                    recoveredAuraResult = try recoveredResult(
                        descriptor: descriptor,
                        snapshot: latestCoachingCycle
                    )
                }
            case .reserved, .active:
                let aborted = try await repository.abortTrainingRun(id: run.id, at: now())
                coachingCyclePersistenceOutcome = .aborted(aborted.id)
            case .committed:
                guard let cycle = try await repository.coachingCycle(id: run.id) else {
                    throw AthleteMemoryRepositoryError.corruptData
                }
                latestCoachingCycle = cycle
                if !(try await repository.isAuraResultDeliveryAcknowledged(runID: run.id)) {
                    recoveredAuraResult = try recoveredResult(
                        descriptor: descriptor,
                        snapshot: cycle
                    )
                }
                coachingCyclePersistenceOutcome = .committed(run.id)
            case .aborted:
                break
            }
        }
    }

    private func recoveredResult(
        descriptor: DurableTrainingRunDescriptor,
        snapshot: CoachingCycleSnapshot?
    ) throws -> RecoveredAuraResult {
        guard descriptor.kind == .auraCoaching,
              let track = descriptor.track,
              let stance = descriptor.stance,
              let techniqueID = descriptor.techniqueID,
              let technique = Technique.technique(id: techniqueID),
              let snapshot,
              snapshot.id == descriptor.runID,
              snapshot.trackID == track.id,
              snapshot.techniqueID == technique.id,
              snapshot.stance == stance
        else { throw AthleteMemoryRepositoryError.corruptData }
        return RecoveredAuraResult(
            runID: descriptor.runID,
            selection: .aura(track: track, technique: technique, stance: stance),
            snapshot: snapshot
        )
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
            currentPlayer = try await repository.saveParticipant(player)
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
            guard let eventID = currentEvent?.id else {
                reactiveStandings = []
                combinationStandings = []
                return true
            }
            let submissions = try await repository.submissions(eventID: eventID)
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

    private func requireActiveEvent() async throws -> EventEdition {
        if let currentEvent, currentEvent.isOpen { return currentEvent }
        if let event = try await repository.activeEvent() {
            currentEvent = event
            return event
        }
        let event = try makeEvent()
        let created = try await repository.create(event: event)
        currentEvent = created
        return created
    }

    private func makeEvent() throws -> EventEdition {
        guard let event = EventEdition(
            id: UUID(),
            title: "Boxing Coach Event",
            status: .open,
            openedAt: now(),
            closedAt: nil,
            scoringVersion: CompetitionScorer.scoringVersion,
            calibrationVersion: CompetitionPlayer.calibrationVersion
        ) else { throw AthleteMemoryRepositoryError.invalidEvent }
        return event
    }
}

@MainActor
enum ParticipantHandoffCoordinator {
    nonisolated struct Presentation: Equatable, Sendable {
        nonisolated enum Focus: Equatable, Sendable { case startTraining }
        let announcement: String
        let focus: Focus
    }

    static func perform(
        store: CompetitionStore,
        flow: TrainingFlowCoordinator,
        session: ReactiveStrikeSession
    ) async -> Presentation {
        flow.participantDidChange(session: session)
        flow.navigate(to: .features)
        await store.handoffToWelcome()
        return Presentation(
            announcement: "Ready for the next boxer.",
            focus: .startTraining
        )
    }
}

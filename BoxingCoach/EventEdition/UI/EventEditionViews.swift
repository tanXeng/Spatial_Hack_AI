import Accessibility
import SwiftUI

struct EventEditionPage<Content: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(
        eyebrow: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(eyebrow)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.cyan)
                        .accessibilityAddTraits(.isHeader)
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }
}

struct EventEditionCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct EventAvatarView: View {
    let id: String
    var size: CGFloat = 52

    private var choice: AvatarChoice {
        AvatarChoice.all.first(where: { $0.id == id }) ?? AvatarChoice.all[0]
    }

    var body: some View {
        Image(systemName: choice.symbolName)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(avatarColor(choice.colorName))
            .frame(width: size, height: size)
            .background(avatarColor(choice.colorName).opacity(0.16), in: Circle())
            .accessibilityLabel("Player avatar")
    }

    private func avatarColor(_ name: String) -> Color {
        switch name {
        case "cyan": .cyan
        case "mint": .mint
        case "amber", "yellow": .yellow
        case "indigo": .indigo
        case "coral", "red": .red
        case "purple": .purple
        case "green": .green
        case "blue": .blue
        case "orange": .orange
        default: .teal
        }
    }
}

struct HostSetupView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    @State private var draft = EventDraft.defaultEvent
    @State private var draftEventID: UUID?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var archivedEvents: [EventSnapshot] = []
    @State private var showsArchivedEvents = false
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        EventEditionPage(
            eyebrow: "HOST SETUP",
            title: "Create today’s boxing challenge",
            subtitle: "Event data and player profiles stay on this Vision Pro."
        ) {
            EventEditionCard {
                TextField("Event name", text: $draft.title)
                    .textContentType(.organizationName)
                    .accessibilityLabel("Event name")
                TextField("Time zone", text: $draft.timeZoneIdentifier)
                    .accessibilityLabel("Time zone identifier")
            }

            EventRulesSummary()

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityFocused($errorFocused)
            }

            if let draftEventID {
                Button("Open Competition") { activate(draftEventID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                Text("The draft is saved. Opening permanently locks today’s rules and scoring version.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button("Create Event") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                Button("Open Archived Events") { showsArchivedEvents = true }
                    .disabled(archivedEvents.isEmpty)
            }
        }
        .task {
            archivedEvents = ((try? await store.allEvents()) ?? []).filter {
                $0.status == .closed || $0.status == .archived
            }
        }
        .sheet(isPresented: $showsArchivedEvents) {
            NavigationStack {
                List(archivedEvents) { event in
                    VStack(alignment: .leading) {
                        Text(event.title).font(.headline)
                        Text("\(event.status.rawValue.capitalized) · \((event.closedAt ?? event.createdAt).formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Archived Events")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsArchivedEvents = false }
                    }
                }
            }
        }
    }

    private func create() {
        isWorking = true
        errorMessage = nil
        Task {
            do { draftEventID = try await store.createEvent(draft) }
            catch { show(error) }
            isWorking = false
        }
    }

    private func activate(_ id: UUID) {
        isWorking = true
        Task {
            do {
                try await store.activateEvent(id: id)
                flow.navigate(to: .welcome)
            } catch { show(error) }
            isWorking = false
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        errorFocused = true
    }
}

struct EventRulesSummary: View {
    var body: some View {
        EventEditionCard {
            Label("Five controlled 1–2 combinations", systemImage: "5.circle.fill")
            Label("Best of two official attempts", systemImage: "medal.fill")
            Label("Maximum score: 500", systemImage: "gauge.with.dots.needle.67percent")
            Label("Speed does not affect rank", systemImage: "tortoise.fill")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rules. Five controlled jab cross combinations. Best of two official attempts. Maximum score 500. Speed does not affect rank.")
    }
}

struct EventWelcomeView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow

    var body: some View {
        EventEditionPage(
            eyebrow: statusText,
            title: "Boxing Coach",
            subtitle: "Learn a controlled jab, cross, and 1–2 in mixed reality."
        ) {
            if let message = store.handoffMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.mint)
                    .onAppear { Task { try? await Task.sleep(for: .seconds(4)); store.consumeHandoffMessage() } }
            }

            if case .failed(let message) = store.loadState {
                EventEditionCard {
                    Label("Saved event data is unavailable", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.headline)
                    Text(message)
                    Text("Participant actions remain disabled. Nothing was deleted.")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await store.bootstrap() } }
                    Button("Open Recovery") { }
                        .disabled(true)
                }
            } else if store.loadState == .loading {
                ProgressView("Loading today’s event…")
            } else {
                Button("I’m a New Participant") { flow.navigate(to: .newParticipant) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.activeEvent?.status != .open)
                Button("I Have a Profile") { flow.navigate(to: .returningParticipant) }
                    .buttonStyle(.bordered)
                Button("View Today’s Leaderboard") {
                    if let id = store.activeEvent?.id { flow.navigate(to: .leaderboard(id)) }
                }
                Button("Practice Without Saving") { flow.navigate(to: .features) }
                Divider()
                Button("Host Tools", systemImage: "slider.horizontal.3") {
                    if let id = store.activeEvent?.id { flow.navigate(to: .hostDashboard(id)) }
                }
                .disabled(store.activeEvent == nil)
                Text("Profiles and scores stay on this Vision Pro.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        guard let event = store.activeEvent else { return "THE HOST IS PREPARING TODAY’S EVENT" }
        return "\(event.title.uppercased()) · \(event.status == .open ? "COMPETITION OPEN" : "COMPETITION CLOSED")"
    }
}

struct NewParticipantView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    @State private var alias = ""
    @State private var avatarIndex = 0
    @State private var stance: Stance = .orthodox
    @State private var isPublic = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    @AccessibilityFocusState private var errorFocused: Bool
    private enum Field { case alias }

    var body: some View {
        EventEditionPage(eyebrow: "PLAYER CHECK-IN", title: "Create Your Player Card") {
            EventEditionCard {
                TextField("Nickname", text: $alias)
                    .focused($focusedField, equals: .alias)
                    .textContentType(.nickname)
                HStack {
                    EventAvatarView(id: AvatarChoice.all[avatarIndex].id)
                    VStack(alignment: .leading) {
                        Text("Choose an Avatar").font(.headline)
                        Button("Show Another") { avatarIndex = (avatarIndex + 1) % AvatarChoice.all.count }
                    }
                }
                Picker("Your stance", selection: $stance) {
                    Text("Left foot forward · Orthodox").tag(Stance.orthodox)
                    Text("Right foot forward · Southpaw").tag(Stance.southpaw)
                }
                .pickerStyle(.segmented)
                Text("Not sure? Orthodox is a safe starting choice and can be changed later.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Player names are unique within today’s event. Use the same name to reopen this player card.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Show my nickname and best score on today’s leaderboard", isOn: $isPublic)
                Text("Only your nickname, avatar, competitor number, and best challenge result will be public.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            errorView
            Button("Create Profile") { create() }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            Button("Back") { flow.navigate(to: .welcome) }
            Button("Practice Without Saving") { flow.navigate(to: .features) }
        }
    }

    @ViewBuilder private var errorView: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityFocused($errorFocused)
        }
    }

    private func create() {
        isWorking = true
        Task {
            do {
                let id = try await store.createParticipant(ParticipantDraft(
                    alias: alias,
                    avatarID: AvatarChoice.all[avatarIndex].id,
                    stance: stance,
                    isLeaderboardPublic: isPublic
                ))
                flow.navigate(to: .participantHome(id))
            } catch {
                errorMessage = error.localizedDescription
                if error is EventInputError { focusedField = .alias }
                errorFocused = true
            }
            isWorking = false
        }
    }
}

struct ReturningParticipantView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    @State private var alias = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        EventEditionPage(eyebrow: "WELCOME BACK", title: "Open Your Player Card") {
            EventEditionCard {
                TextField("Nickname", text: $alias).textContentType(.nickname)
                Text("Enter the player name used at check-in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).accessibilityFocused($errorFocused)
            }
            Button("Open Profile") { openProfile() }
                .buttonStyle(.borderedProminent).disabled(isWorking)
            Button("Back") { flow.navigate(to: .welcome) }
        }
    }

    private func openProfile() {
        isWorking = true
        Task {
            do {
                let id = try await store.openParticipant(alias: alias)
                flow.navigate(to: .participantHome(id))
            } catch {
                errorMessage = error.localizedDescription
                errorFocused = true
            }
            isWorking = false
        }
    }

}

struct ParticipantHomeView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    @Environment(ReactiveStrikeSession.self) private var session
    let participantID: UUID
    @State private var attemptsRemaining = ChallengeRulesV1.maxOfficialAttempts
    @State private var bestScore: Int?

    var body: some View {
        EventEditionPage(eyebrow: "PLAYER HOME", title: "Welcome, \(participant.alias)") {
            EventEditionCard {
                HStack {
                    EventAvatarView(id: participant.avatarID, size: 68)
                    VStack(alignment: .leading) {
                        Text("\(participant.stance.title) · Competitor \(participant.competitorLabel)")
                        Text(bestScore.map { "Best Challenge: \($0) / 500" } ?? "No Official Score Yet")
                            .font(.headline)
                        Text("Official Attempts Remaining: \(attemptsRemaining)")
                    }
                }
            }
            Button(primaryTitle) { startPrimary() }.buttonStyle(.borderedProminent)
                .disabled(store.activeEvent?.status != .open)
            Button("Practice Again") { begin(.controlledOneTwoPractice) }
            Button("My Progress") { flow.navigate(to: .profile(participantID)) }
            Button("Today’s Leaderboard") {
                if let id = store.activeEvent?.id { flow.navigate(to: .leaderboard(id)) }
            }
            Button("Change Stance") { changeStance() }
            Toggle("Show my result on the leaderboard", isOn: privacyBinding)
            Button("Experimental Punch Lab") { flow.navigate(to: .experimentalLab) }
            Divider()
            Button("Finish for Next Participant") { handoff() }
        }
        .task(id: participantID) { await refresh() }
    }

    private var participant: ParticipantSnapshot {
        store.activeParticipant ?? ParticipantSnapshot(
            id: participantID,
            eventID: store.activeEvent?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            entryID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            alias: "Player", normalizedAlias: "player", avatarID: AvatarChoice.all[0].id,
            stance: .orthodox, competitorNumber: 0, isLeaderboardPublic: false,
            lessonCompletedAt: nil, coachOverrideAt: nil, createdAt: .now, lastSeenAt: .now, archived: false
        )
    }

    private var primaryTitle: String {
        if participant.lessonCompletedAt == nil { return "Start Guided Lesson" }
        return attemptsRemaining > 0 ? "Start Official Challenge" : "Practice the 1–2"
    }

    private var privacyBinding: Binding<Bool> {
        Binding(get: { participant.isLeaderboardPublic }, set: { value in
            Task { try? await store.updateParticipantPrivacy(value) }
        })
    }

    private func startPrimary() {
        if participant.lessonCompletedAt == nil { flow.navigate(to: .lessonOverview(participantID)) }
        else { begin(attemptsRemaining > 0 ? .controlledOneTwoOfficial : .controlledOneTwoPractice) }
    }

    private func begin(_ plan: TrainingPlan) { flow.navigate(to: .safetyPreflight(participantID, plan)) }

    private func changeStance() {
        Task {
            try? await store.updateParticipantStance(participant.stance == .orthodox ? .southpaw : .orthodox)
        }
    }

    private func refresh() async {
        attemptsRemaining = (try? await store.officialAttemptsRemaining()) ?? attemptsRemaining
        let runs = (try? await store.runsForActiveParticipant()) ?? []
        bestScore = runs.filter { $0.plan == .controlledOneTwoOfficial && $0.status == .completed }
            .map(ChallengeScorer.score).map(\.totalPoints).max()
    }

    private func handoff() {
        store.clearActiveParticipant()
        flow.participantHandoff(session: session)
    }
}

struct LessonOverviewView: View {
    @Environment(TrainingFlowCoordinator.self) private var flow
    let participantID: UUID
    var body: some View {
        EventEditionPage(eyebrow: "GUIDED LESSON", title: "Your 6-Minute Boxing Lesson") {
            EventEditionCard {
                Label("Set your guard and comfortable reach", systemImage: "1.circle.fill")
                Label("Learn jab and cross", systemImage: "2.circle.fill")
                Label("Practice a controlled 1–2", systemImage: "3.circle.fill")
            }
            Text("Boxing Coach tracks processed hand positions and headset pose. It does not directly measure feet, hips, torso rotation, impact force, power, or complete boxing form.")
                .foregroundStyle(.secondary)
            Button("Check My Space") { flow.navigate(to: .safetyPreflight(participantID, .guidedCore)) }
                .buttonStyle(.borderedProminent)
            Button("Not Now") { flow.navigate(to: .participantHome(participantID)) }
            Button("Observe Only") { flow.navigate(to: .safetyPreflight(participantID, .observeOnly)) }
        }
    }
}

struct SafetyPreflightView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    let participantID: UUID
    let plan: TrainingPlan
    @State private var confirmed = false

    var body: some View {
        EventEditionPage(eyebrow: "SAFETY CHECK", title: "Make Room to Move Safely") {
            EventEditionCard {
                checklist("Clear an arm’s-length space around you.")
                checklist("Move people, pets, furniture, glass, mirrors, and fans away.")
                checklist("Secure the battery cable and adjust the headset until it feels stable.")
                checklist("Use bare hands. Do not hit a person, bag, wall, or object.")
                checklist("Keep your feet planted and move slowly at a comfortable pace.")
            }
            Toggle("I checked the area and can extend both arms without touching anything.", isOn: $confirmed)
            Text("Press the Digital Crown at any time to leave the immersive experience. Stop immediately if you feel discomfort.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Continue") {
                store.setSafetyConfirmation(true)
                flow.navigate(to: .permissionPreflight(participantID, plan))
            }
            .buttonStyle(.borderedProminent).disabled(!confirmed)
            Button("Back") { flow.navigate(to: .participantHome(participantID)) }
        }
    }

    private func checklist(_ text: String) -> some View { Label(text, systemImage: "checkmark.circle") }
}

struct PermissionPreflightView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    let participantID: UUID
    let plan: TrainingPlan

    var body: some View {
        EventEditionPage(eyebrow: "PRIVACY & PERMISSION", title: "Allow Hand Tracking") {
            Text("Boxing Coach uses processed hand and headset positions on this device to place virtual targets, recognize controlled movements, and create your training results. It does not record camera video or raw eye data.")
            EventEditionCard {
                Label("Processed positions only", systemImage: "hand.raised.fill")
                Label("No camera video recording", systemImage: "video.slash.fill")
                Label("Results stay on this device", systemImage: "lock.fill")
            }
            Button("Continue and Request Access") {
                guard store.hasSafetyConfirmation else { return }
                flow.navigate(to: .eventExperience(UUID(), plan))
            }
            .buttonStyle(.borderedProminent)
            Button("Back") { flow.navigate(to: .safetyPreflight(participantID, plan)) }
        }
    }
}

struct EventRunExperienceView: View {
    @Environment(EventStore.self) private var store
    @Environment(ReactiveStrikeSession.self) private var session
    @Environment(TrainingFlowCoordinator.self) private var flow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.dismissWindow) private var dismissWindow
    let runID: UUID
    let plan: TrainingPlan
    @State private var startedAt: Date?
    @State private var officialOrdinal: Int?
    @State private var isSaving = false
    @State private var didFinalize = false
    @State private var errorMessage: String?

    var body: some View {
        EventEditionPage(
            eyebrow: plan == .controlledOneTwoOfficial ? "OFFICIAL CHALLENGE" : "TRAINING SESSION",
            title: plan == .controlledOneTwoOfficial ? "Today’s Controlled 1–2 Challenge" : "Controlled Jab–Cross",
            subtitle: "Throw five controlled jab–cross combinations. Speed does not affect your points or rank."
        ) {
            EventRulesSummary()
            if isSaving { ProgressView("Saving Your Session…") }
            if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            if session.phase == .finished && !isSaving {
                Button("Save Session") { Task { await finalize() } }.buttonStyle(.borderedProminent)
            } else {
                Button("Start \(plan == .controlledOneTwoOfficial ? "Official Attempt" : "Session")") {
                    Task { await start() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(startedAt != nil || flow.controlsDisabled)
            }
            Text("Challenge Points are game points based on observable hand movement. They are not a measure of power, complete boxing technique, fitness, or fighting ability.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Back") { flow.navigate(to: .participantHome(store.activeParticipant?.id ?? UUID())) }
                .disabled(startedAt != nil && !didFinalize)
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .finished, startedAt != nil, !didFinalize { Task { await finalize() } }
        }
    }

    private func start() async {
        guard let event = store.activeEvent, let participant = store.activeParticipant else { return }
        do {
            session.guided.start(plan: plan)
            let remaining = try await store.officialAttemptsRemaining()
            officialOrdinal = plan == .controlledOneTwoOfficial
                ? event.maxOfficialAttempts - remaining + 1
                : nil
            let start = Date()
            await flow.startEventExperience(
                runID: runID,
                plan: plan,
                stance: participant.stance,
                session: session,
                supportsMultipleScenes: supportsMultipleWindows,
                prepareRun: {
                    try await store.beginRun(TrainingRunContext(
                        runID: runID, eventID: event.id, participantID: participant.id,
                        entryID: participant.entryID, aliasSnapshot: participant.alias,
                        avatarIDSnapshot: participant.avatarID, plan: plan, stance: participant.stance,
                        startedAt: start, officialOrdinal: officialOrdinal, rulesDigest: event.rulesDigest
                    ))
                    startedAt = start
                },
                openImmersive: openImmersive,
                dismissImmersive: { await dismissImmersiveSpace() },
                hideControlWindow: { dismissWindow(id: BoxingCoachSceneID.controlWindow) }
            )
            if let message = flow.presentationError { errorMessage = message }
        } catch { errorMessage = error.localizedDescription }
    }

    private func finalize() async {
        guard !didFinalize,
              let start = startedAt,
              let event = store.activeEvent,
              let participant = store.activeParticipant else { return }
        isSaving = true
        session.guided.beginSaving()
        let complete: Bool
        if plan == .guidedCore || plan == .observeOnly {
            complete = !session.lessonStages.isEmpty
                && session.lastFeedback != "Drill stopped"
                && session.errorMessage == nil
        } else {
            complete = session.challengeRepetitions.count == ChallengeRulesV1.repetitionCount
                && session.lastFeedback != "Drill stopped"
                && session.errorMessage == nil
        }
        let status: TrainingRunStatus = session.errorMessage == nil
            ? (complete ? .completed : .partial)
            : .technicalFailure
        let eligibility: EligibilityReason
        if plan != .controlledOneTwoOfficial { eligibility = .unofficial }
        else if status == .technicalFailure { eligibility = .technicalFailure }
        else if !complete { eligibility = .partialResult }
        else { eligibility = participant.isLeaderboardPublic ? .eligible : .privateResult }
        let provisional = TrainingRunSnapshot(
            id: runID, eventID: event.id, participantID: participant.id,
            entryID: participant.entryID, aliasSnapshot: participant.alias,
            avatarIDSnapshot: participant.avatarID, plan: plan, status: status,
            stance: participant.stance, startedAt: start, endedAt: Date(),
            officialOrdinal: complete ? officialOrdinal : nil, rulesDigest: event.rulesDigest,
            lessonStages: session.lessonStages,
            challengeRepetitions: session.challengeRepetitions,
            trackingSummary: complete
                ? (plan == .observeOnly ? "Lesson observed without punch capture" : "Fresh required-hand samples captured")
                : "Session incomplete",
            optedIntoLeaderboard: participant.isLeaderboardPublic,
            eligibilityReason: eligibility
        )
        let correction: SelectedCorrection
        if plan == .guidedCore,
           let evidence = session.lessonStages.reversed()
            .flatMap(\.metrics)
            .first(where: { $0.id == "selected-correction" })?.evidence {
            correction = SelectedCorrection(
                id: "guided-next-focus",
                evidence: evidence,
                sentence: evidence
            )
        } else {
            correction = ChallengeCorrectionSelector.select(score: ChallengeScorer.score(provisional))
        }
        let snapshot = TrainingRunSnapshot(
            id: provisional.id, eventID: provisional.eventID, participantID: provisional.participantID,
            entryID: provisional.entryID, aliasSnapshot: provisional.aliasSnapshot,
            avatarIDSnapshot: provisional.avatarIDSnapshot, plan: provisional.plan,
            status: provisional.status, stance: provisional.stance, startedAt: provisional.startedAt,
            endedAt: provisional.endedAt, officialOrdinal: provisional.officialOrdinal,
            rulesDigest: provisional.rulesDigest, lessonStages: provisional.lessonStages,
            challengeRepetitions: provisional.challengeRepetitions,
            technicalDiscardCount: session.guided.technicalDiscardCount,
            trackingSummary: provisional.trackingSummary,
            selectedCorrectionID: correction.id,
            narrationSource: "deterministic-facts",
            optedIntoLeaderboard: provisional.optedIntoLeaderboard,
            eligibilityReason: provisional.eligibilityReason,
            voided: provisional.voided
        )
        do {
            _ = try await store.finalizeRun(snapshot)
            if plan == .guidedCore && complete { try await store.markLessonCompleted() }
            didFinalize = true
            session.guided.complete(runID: runID)
            flow.navigate(to: .eventResults(runID))
        } catch { errorMessage = error.localizedDescription }
        isSaving = false
    }

    private func openImmersive(_ id: String) async -> ImmersiveOpenOutcome {
        switch await openImmersiveSpace(id: id) {
        case .opened: .opened
        case .userCancelled: .cancelled
        case .error: .failed("Could not open the immersive training space.")
        @unknown default: .failed("Could not open the immersive training space.")
        }
    }
}

struct EventResultView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    @Environment(ReactiveStrikeSession.self) private var session
    let runID: UUID
    @State private var run: TrainingRunSnapshot?
    @State private var narration: CoachingNarration?

    var body: some View {
        EventEditionPage(eyebrow: "SESSION SAVED", title: resultTitle) {
            if let run {
                let score = ChallengeScorer.score(run)
                if run.plan == .guidedCore || run.plan == .observeOnly {
                    EventEditionCard {
                        Text(run.plan == .observeOnly ? "Lesson Observed" : "Jab, cross, and 1–2 completed")
                            .font(.title2.bold())
                        LabeledMetricRow(title: "Saved lesson stages", value: "\(run.lessonStages.count)")
                        Text("Measurements marked unavailable were not treated as faults.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    EventEditionCard {
                        Text("\(score.totalPoints) / 500 Challenge Points").font(.largeTitle.bold())
                        LabeledMetricRow(title: "Clean Contacts", value: "\(score.contactPoints) / 300")
                        LabeledMetricRow(title: "Centre Accuracy", value: "\(score.accuracyPoints) / 100")
                        LabeledMetricRow(title: "Guard Return", value: "\(score.guardPoints) / 100")
                        Text(run.eligibilityReason.displayText).foregroundStyle(.secondary)
                        Text("Speed did not affect this result.").font(.footnote)
                    }
                }
                if let narration {
                    EventEditionCard {
                        Text("Next focus").font(.headline)
                        Text(narration.sentence)
                        if narration.source == .deterministic {
                            Text("On-device coach unavailable · deterministic guidance")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("View Leaderboard") { flow.navigate(to: .leaderboard(run.eventID)) }.buttonStyle(.borderedProminent)
                Button("View My Progress") {
                    if let id = run.participantID { flow.navigate(to: .profile(id)) }
                }
                Button("Finish for Next Participant") { finish() }
            } else { ProgressView("Loading saved result…") }
        }
        .task {
            run = try? await store.run(id: runID)
            if let run {
                if run.plan == .observeOnly { return }
                let correction: SelectedCorrection
                if run.plan == .guidedCore,
                   let evidence = run.lessonStages.reversed()
                    .flatMap(\.metrics)
                    .first(where: { $0.id == "selected-correction" })?.evidence {
                    correction = SelectedCorrection(
                        id: run.selectedCorrectionID ?? "guided-next-focus",
                        evidence: evidence,
                        sentence: evidence
                    )
                } else {
                    correction = ChallengeCorrectionSelector.select(score: ChallengeScorer.score(run))
                }
                narration = await ConstrainedCoachingNarrator.live.narrate(CoachingFactSet(
                    correctionID: run.selectedCorrectionID ?? correction.id,
                    evidence: correction.evidence,
                    confidence: run.challengeRepetitions.isEmpty ? 0 : 1,
                    approvedVocabulary: ["controlled", "hand", "guard", "centre", "jab", "cross"],
                    deterministicFallback: correction.sentence
                ))
            }
        }
    }

    private var resultTitle: String {
        guard let run else { return "Loading your result" }
        return run.plan == .guidedCore ? "Lesson Complete" : "Challenge Saved"
    }

    private func finish() {
        store.clearActiveParticipant()
        flow.participantHandoff(session: session)
    }
}

struct EventProfileView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    let participantID: UUID
    @State private var runs: [TrainingRunSnapshot] = []

    var body: some View {
        EventEditionPage(eyebrow: "MY PROGRESS", title: store.activeParticipant?.alias ?? "Player") {
            if let participant = store.activeParticipant {
                EventEditionCard {
                    Text("\(participant.stance.title) · Competitor \(participant.competitorLabel)")
                    Text(participant.lessonCompletedAt == nil ? "Guided lesson not completed" : "Guided lesson completed")
                    Text(participant.isLeaderboardPublic ? "Leaderboard: Public" : "Leaderboard: Private")
                }
            }
            if runs.isEmpty {
                ContentUnavailableView("No Saved Sessions Yet", systemImage: "clock", description: Text("Complete the guided lesson to create your first snapshot."))
            } else {
                ForEach(runs.prefix(5)) { run in
                    EventEditionCard {
                        Text(run.plan.displayName).font(.headline)
                        Text(run.endedAt.formatted(date: .abbreviated, time: .shortened))
                        Text("\(ChallengeScorer.score(run).totalPoints) points · \(run.status.rawValue)")
                    }
                }
            }
            Button("Start Another Session") { flow.navigate(to: .participantHome(participantID)) }.buttonStyle(.borderedProminent)
        }
        .task { runs = (try? await store.runsForActiveParticipant()) ?? [] }
    }
}

struct EventLeaderboardView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    let eventID: UUID
    @State private var category: LeaderboardCategory = .overall
    @State private var entries: [LeaderboardEntry] = []

    var body: some View {
        EventEditionPage(eyebrow: store.activeEvent?.status == .closed ? "COMPETITION CLOSED" : "LIVE LEADERBOARD", title: store.activeEvent?.title ?? "Today’s Standings") {
            Picker("Leaderboard category", selection: $category) {
                ForEach(LeaderboardCategory.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if entries.isEmpty {
                ContentUnavailableView("No Ranked Scores Yet", systemImage: "trophy", description: Text("Complete the five-rep Controlled 1–2 Challenge and opt in to join."))
            } else {
                ForEach(entries) { entry in
                    HStack(spacing: 14) {
                        Text("#\(entry.rank)").font(.title2.bold()).frame(width: 48)
                        EventAvatarView(id: entry.avatarID)
                        VStack(alignment: .leading) {
                            Text(entry.alias).font(.headline)
                            Text("\(entry.competitorLabel) · \(entry.officialAttemptsCompleted) official attempt\(entry.officialAttemptsCompleted == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(value(entry)).font(.title2.monospacedDigit().bold())
                    }
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Scores are stored locally on this Vision Pro.").font(.footnote).foregroundStyle(.secondary)
            Button(store.activeParticipant == nil ? "Back to Welcome" : "Back to Player Home") {
                if let id = store.activeParticipant?.id { flow.navigate(to: .participantHome(id)) }
                else { flow.navigate(to: .welcome) }
            }
        }
        .task(id: category) { entries = (try? await store.leaderboard(eventID: eventID, category: category)) ?? [] }
    }

    private func value(_ entry: LeaderboardEntry) -> String {
        switch category {
        case .overall: "\(entry.totalPoints)"
        case .cleanSequence: "\(entry.contactPoints)"
        case .centreAccuracy: "\(entry.accuracyPoints)"
        case .guardDiscipline: "\(entry.guardPoints)"
        case .mostImproved: entry.improvementPoints.map { "+\($0)" } ?? "—"
        }
    }
}

struct HostDashboardView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    @Environment(ReactiveStrikeSession.self) private var session
    let eventID: UUID
    @State private var standings: [LeaderboardEntry] = []
    @State private var publicCSV: String?
    @State private var fullJSON: String?

    var body: some View {
        EventEditionPage(eyebrow: "HOST DASHBOARD", title: store.activeEvent?.title ?? "Event") {
            EventEditionCard {
                LabeledMetricRow(title: "Status", value: store.activeEvent?.status.rawValue.capitalized ?? "Unavailable")
                LabeledMetricRow(title: "Ranked participants", value: "\(standings.count)")
                LabeledMetricRow(title: "Current top score", value: standings.first.map { "\($0.totalPoints)" } ?? "—")
                LabeledMetricRow(title: "Current run", value: store.activeRunID == nil ? "None" : "Active")
                LabeledMetricRow(title: "Pending save", value: store.pendingSave == nil ? "None" : "Needs attention")
            }
            Button("Start Next Participant") {
                store.clearActiveParticipant()
                flow.participantHandoff(session: session)
            }
            .buttonStyle(.borderedProminent)
            Button("Open Presentation Leaderboard") { flow.navigate(to: .leaderboard(eventID)) }
            if let publicCSV {
                ShareLink("Export Public CSV", item: publicCSV)
            }
            if let fullJSON {
                ShareLink("Export Full Event JSON", item: fullJSON)
            }
            Button("Close Competition and Reveal Winners") { flow.navigate(to: .closeEventReview(eventID)) }
                .disabled(store.activeEvent?.status != .open || store.activeRunID != nil || store.pendingSave != nil)
            Button("Back") { flow.navigate(to: .welcome) }
        }
        .task {
            standings = (try? await store.leaderboard(eventID: eventID, category: .overall)) ?? []
            publicCSV = try? await store.publicCSV(eventID: eventID)
            if let data = try? await store.fullEventJSON(eventID: eventID) {
                fullJSON = String(data: data, encoding: .utf8)
            }
        }
    }
}

struct CloseEventReviewView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    let eventID: UUID
    @State private var isClosing = false
    @State private var errorMessage: String?

    var body: some View {
        EventEditionPage(eyebrow: "FINAL REVIEW", title: "Close Competition?") {
            EventEditionCard {
                Text("Closing freezes official submissions and creates immutable award snapshots.")
                Text("Active runs and unresolved saves must be completed first.")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            Button("Close Competition and Reveal Winners", role: .destructive) { close() }
                .buttonStyle(.borderedProminent).disabled(isClosing)
            Button("Keep Competition Open") { flow.navigate(to: .hostDashboard(eventID)) }
        }
    }

    private func close() {
        isClosing = true
        Task {
            do { _ = try await store.closeAndDeclareWinners(eventID: eventID); flow.navigate(to: .winnerReveal(eventID)) }
            catch { errorMessage = error.localizedDescription }
            isClosing = false
        }
    }
}

struct WinnerRevealView: View {
    @Environment(EventStore.self) private var store
    @Environment(TrainingFlowCoordinator.self) private var flow
    let eventID: UUID
    @State private var entries: [LeaderboardEntry] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        EventEditionPage(eyebrow: "TODAY’S WINNERS", title: store.activeEvent?.title ?? "Boxing Coach") {
            ForEach(entries.prefix(3)) { entry in
                EventEditionCard {
                    HStack {
                        Text(entry.rank == 1 ? "🥇" : entry.rank == 2 ? "🥈" : "🥉").font(.largeTitle)
                        EventAvatarView(id: entry.avatarID, size: 64)
                        VStack(alignment: .leading) {
                            Text(entry.alias).font(.title2.bold())
                            Text("Rank \(entry.rank) · \(entry.totalPoints) points")
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
            if entries.isEmpty { ContentUnavailableView("No Winners Yet", systemImage: "medal", description: Text("No eligible public scores were recorded.")) }
            Text("Thank you to everyone who trained today").font(.title2.bold())
            Button("View Full Standings") { flow.navigate(to: .leaderboard(eventID)) }.buttonStyle(.borderedProminent)
            Button("Return to Welcome") { flow.navigate(to: .welcome) }
        }
        .task { entries = (try? await store.leaderboard(eventID: eventID, category: .overall)) ?? [] }
    }
}

private extension TrainingPlan {
    var displayName: String {
        switch self {
        case .guidedCore: "Guided Core Lesson"
        case .controlledOneTwoPractice: "Controlled 1–2 Practice"
        case .controlledOneTwoOfficial: "Official Controlled 1–2"
        case .observeOnly: "Observe Only"
        case .experimental: "Experimental Punch Lab"
        }
    }
}

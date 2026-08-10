import Accessibility
import SwiftUI

struct CompetitionSheetView: View {
    @Environment(CompetitionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onStart: (TrainingSelection) -> Void

    @State private var confirmsReset = false
    @AccessibilityFocusState private var focus: FocusTarget?

    private enum FocusTarget: Hashable {
        case name
        case heading
        case leaderboard
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let message = store.errorMessage {
                        TrainingErrorCard(message: message)
                    }
                    routeContent
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(28)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        store.dismiss()
                        dismiss()
                    }
                    .disabled(store.activeRun != nil || store.isSaving)
                }
                if case .leaderboard = store.sheetRoute {
                    ToolbarItem(placement: .primaryAction) {
                        resetMenu
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .task(id: store.sheetRoute) {
            try? await Task.sleep(for: .milliseconds(120))
            switch store.sheetRoute {
            case .nameEntry: focus = .name
            case .leaderboard: focus = .leaderboard
            default: focus = .heading
            }
        }
        .onChange(of: store.errorMessage) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
            focus = store.sheetRoute == .nameEntry ? .name : .heading
        }
        .confirmationDialog(
            "Reset Competition?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Reset Players and Results", role: .destructive) {
                Task { await store.resetConfirmed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently clears player names, reach calibrations, and both leaderboards on this Vision Pro.")
        }
    }

    private var title: String {
        switch store.sheetRoute {
        case .nameEntry: return "Join Competition"
        case .calibrationRequired: return "Reach Calibration"
        case .modes: return "Choose a Board"
        case .stance: return "Combo Stance"
        case .leaderboard: return "Leaderboard"
        case .result: return "Result Saved"
        case .error: return "Competition"
        case nil: return "Competition"
        }
    }

    @ViewBuilder
    private var routeContent: some View {
        switch store.sheetRoute {
        case .nameEntry:
            nameEntry
        case .calibrationRequired:
            calibrationRequired
        case .modes:
            modeSelection
        case .stance:
            stanceSelection
        case .leaderboard(let mode):
            leaderboard(mode)
        case .result:
            result
        case .error, nil:
            ContentUnavailableView(
                "Competition Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(store.errorMessage ?? "Close this sheet and try again.")
            )
        }
    }

    private var nameEntry: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeading(
                "What should the leaderboard call you?",
                detail: "Entering the same name reopens your saved reach and stance automatically."
            )
            @Bindable var bindableStore = store
            TextField("Player name", text: $bindableStore.nameDraft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.continue)
                .onSubmit(join)
                .accessibilityLabel("Player name")
                .accessibilityHint("Enter two to twenty-four letters, numbers, spaces, hyphens, or underscores")
                .accessibilityFocused($focus, equals: .name)
                .disabled(store.isLoading)

            Button("Continue", systemImage: "arrow.right") { join() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isLoading)
                .frame(minHeight: 44)

            if store.isLoading {
                ProgressView("Finding player…")
            }
        }
    }

    private var calibrationRequired: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeading(
                store.currentPlayer?.hasCurrentCalibration == true
                    ? "Update your comfortable reach"
                    : "Calibrate once for fair targets",
                detail: "You’ll extend each arm only as far as comfortable. Measurements stay body-relative and local to this device."
            )

            Label("Guard position is recaptured before every run.", systemImage: "hand.raised.fill")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Start Reach Calibration", systemImage: "ruler") {
                if let selection = store.prepareCalibration() { onStart(selection) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minHeight: 44)
            .disabled(store.isLoading || store.isSaving || store.activeRun != nil)

            Button("Use a Different Player") { store.showNameEntry() }
                .frame(minHeight: 44)
        }
    }

    private var modeSelection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeading(
                "Welcome, \(store.currentPlayer?.name ?? "boxer")",
                detail: "Choose either board. You can submit as many complete runs as you like; only your best result ranks."
            )

            ForEach(CompetitionMode.allCases) { mode in
                Button {
                    Task {
                        if let selection = await store.chooseMode(mode) { onStart(selection) }
                    }
                } label: {
                    CompetitionModeRow(mode: mode)
                }
                .buttonStyle(.plain)
                .disabled(store.isLoading || store.isSaving || store.activeRun != nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Compete in \(mode.title), \(mode.subtitle)")
                .accessibilityHint("Starts setup for this leaderboard")
            }

            ViewThatFits(in: .horizontal) {
                HStack { modeUtilities }
                VStack(alignment: .leading) { modeUtilities }
            }

            if store.isSaving {
                ProgressView("Preparing competition…")
            }
        }
    }

    @ViewBuilder
    private var modeUtilities: some View {
        Button("View Leaderboards", systemImage: "trophy") {
            store.showLeaderboard(.reactiveStrike)
        }
        .frame(minHeight: 44)
        .disabled(store.isLoading || store.isSaving || store.activeRun != nil)
        Button("Recalibrate Reach", systemImage: "ruler") {
            if let selection = store.prepareCalibration() { onStart(selection) }
        }
        .frame(minHeight: 44)
        .disabled(store.isLoading || store.isSaving || store.activeRun != nil)
        Button("Change Player", systemImage: "person.2") { store.showNameEntry() }
            .frame(minHeight: 44)
            .disabled(store.isLoading || store.isSaving || store.activeRun != nil)
    }

    private var stanceSelection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeading(
                "Choose your Combo stance",
                detail: "Every run uses five repetitions of 1–2–3–2. Your choice is remembered for next time."
            )

            Picker("Stance", selection: Binding(
                get: { store.selectedStance },
                set: { store.selectedStance = $0 }
            )) {
                ForEach(Stance.allCases) { stance in Text(stance.title).tag(stance) }
            }
            .pickerStyle(.segmented)

            Text(store.selectedStance.footDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Start 1–2–3–2 Combo", systemImage: "figure.boxing") {
                Task {
                    if let selection = await store.startCombination(stance: store.selectedStance) {
                        onStart(selection)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minHeight: 44)
            .disabled(store.isLoading || store.isSaving || store.activeRun != nil)

            Button("Back to Modes") { store.showModes() }
                .frame(minHeight: 44)
                .disabled(store.isLoading || store.isSaving || store.activeRun != nil)
        }
    }

    private func leaderboard(_ mode: CompetitionMode) -> some View {
        leaderboardBoard(mode)
    }

    private func leaderboardBoard(_ mode: CompetitionMode) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Leaderboard", selection: Binding(
                get: { mode },
                set: { store.showLeaderboard($0) }
            )) {
                Text("Reactive Strike").tag(CompetitionMode.reactiveStrike)
                Text("Combo").tag(CompetitionMode.combination)
            }
            .pickerStyle(.segmented)
            .accessibilityFocused($focus, equals: .leaderboard)

            let standings = store.standings(for: mode)
            if standings.isEmpty {
                ContentUnavailableView(
                    "No \(mode.title) Results Yet",
                    systemImage: "trophy",
                    description: Text("Complete the first ranked run to fill this board.")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(standings) { standing in
                        CompetitionStandingRow(standing: standing)
                    }
                }
            }

            Button("Back to Modes") { store.showModes() }
                .frame(minHeight: 44)
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let submission = store.latestSubmission {
                Label("Competition result saved", systemImage: "trophy.fill")
                    .font(.headline)
                    .accessibilityLabel("Competition result saved")
                sheetHeading(
                    "\(submission.score) points",
                    detail: "Saved to the \(submission.mode.title) leaderboard for \(submission.playerName)."
                )

                LabeledMetricRow(
                    title: submission.mode == .reactiveStrike ? "Valid hits" : "Valid steps",
                    value: "\(submission.validSteps) / \(submission.totalSteps)"
                )
                if submission.mode == .combination {
                    LabeledMetricRow(
                        title: "Completed repetitions",
                        value: "\(submission.completedRepetitions) / 5"
                    )
                }
                if let speed = submission.speedTieBreakSeconds {
                    LabeledMetricRow(
                        title: submission.mode == .reactiveStrike ? "Average reaction" : "Active time",
                        value: String(format: "%.2f s", speed),
                        spokenValue: String(format: "%.2f seconds", speed)
                    )
                }

                Button("View \(submission.mode.title) Leaderboard", systemImage: "trophy") {
                    store.showLeaderboard(submission.mode)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minHeight: 44)
            }

            Button("Compete Again") { store.showModes() }
                .frame(minHeight: 44)
        }
    }

    private var resetMenu: some View {
        Menu {
            Button("Reset Competition", systemImage: "trash", role: .destructive) {
                confirmsReset = true
            }
            .disabled(store.activeRun != nil || store.isSaving)
        } label: {
            Label("Competition Options", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel("Competition options")
        .accessibilityHint("Contains the reset competition action")
    }

    private func sheetHeading(_ text: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.title2.bold())
            Text(detail).font(.body).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityFocused($focus, equals: .heading)
    }

    private func join() {
        Task { await store.join(name: store.nameDraft) }
    }
}

private struct CompetitionModeRow: View {
    let mode: CompetitionMode

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: mode == .reactiveStrike ? "scope" : "list.number")
                .font(.title2)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title).font(.headline)
                Text(mode.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct CompetitionStandingRow: View {
    let standing: CompetitionStanding

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                rank
                name
                Spacer()
                score
                speed
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    rank
                    name
                    Spacer()
                    score
                }
                speed
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var rank: some View {
        Text("#\(standing.rank)")
            .font(.headline.monospacedDigit())
            .frame(minWidth: 42, alignment: .leading)
    }

    private var name: some View {
        Text(standing.submission.playerName).font(.headline)
    }

    private var score: some View {
        Text("\(standing.submission.score)").font(.title3.bold().monospacedDigit())
    }

    private var speed: some View {
        Text(speedText).font(.caption).foregroundStyle(.secondary)
    }

    private var speedText: String {
        guard let seconds = standing.submission.speedTieBreakSeconds else { return "No speed tie-break" }
        return standing.submission.mode == .reactiveStrike
            ? String(format: "%.0f ms avg", seconds * 1000)
            : String(format: "%.2f s", seconds)
    }

    private var accessibilitySummary: String {
        "Rank \(standing.rank), \(standing.submission.playerName), score \(standing.submission.score), \(speedText)"
    }
}

#Preview("Name Entry") {
    CompetitionSheetView(onStart: { _ in })
        .environment(CompetitionStore.preview(route: .nameEntry))
}

#Preview("Calibration Required") {
    CompetitionSheetView(onStart: { _ in })
        .environment(CompetitionStore.preview(route: .calibrationRequired, player: .previewUncalibrated))
}

#Preview("Mode Selection") {
    CompetitionSheetView(onStart: { _ in })
        .environment(CompetitionStore.preview(route: .modes, player: .previewCalibrated))
}

#Preview("Empty Leaderboard") {
    CompetitionSheetView(onStart: { _ in })
        .environment(CompetitionStore.preview(route: .leaderboard(.reactiveStrike), player: .previewCalibrated))
}

#Preview("Populated Leaderboard") {
    CompetitionSheetView(onStart: { _ in })
        .environment(CompetitionStore.preview(
            route: .leaderboard(.reactiveStrike),
            player: .previewCalibrated,
            reactiveStandings: [CompetitionStanding(rank: 1, submission: .previewResult)]
        ))
}

#Preview("Saved Result") {
    CompetitionSheetView(onStart: { _ in })
        .environment(CompetitionStore.preview(
            route: .result(CompetitionSubmission.previewResult.id),
            player: .previewCalibrated,
            latestSubmission: .previewResult
        ))
}

#Preview("Error") {
    CompetitionSheetView(onStart: { _ in })
        .environment(CompetitionStore.preview(
            route: .calibrationRequired,
            player: .previewUncalibrated,
            errorMessage: "Your saved reach no longer clears your current guard."
        ))
}

private extension CompetitionPlayer {
    static let previewUncalibrated = CompetitionPlayer(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        name: "Jordan",
        normalizedName: "jordan",
        rememberedStance: .orthodox,
        reach: nil,
        calibrationVersion: nil,
        calibratedAt: nil,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    static let previewCalibrated = CompetitionPlayer(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
        name: "Jordan",
        normalizedName: "jordan",
        rememberedStance: .southpaw,
        reach: BilateralReach(left: 0.68, right: 0.70),
        calibrationVersion: CompetitionPlayer.calibrationVersion,
        calibratedAt: Date(timeIntervalSince1970: 1_700_000_000),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private extension CompetitionSubmission {
    static let previewResult = CompetitionSubmission(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
        playerID: CompetitionPlayer.previewCalibrated.id,
        playerName: CompetitionPlayer.previewCalibrated.name,
        normalizedPlayerName: CompetitionPlayer.previewCalibrated.normalizedName,
        mode: .reactiveStrike,
        score: 92,
        validSteps: 8,
        totalSteps: 8,
        completedRepetitions: 0,
        meanCentreErrorMeters: 0.03,
        speedTieBreakSeconds: 0.34,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_000_030),
        trackingStatus: .complete
    )
}

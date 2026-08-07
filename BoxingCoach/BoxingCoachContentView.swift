import SwiftUI

private enum TrainingFeature: String, CaseIterable, Identifiable {
    case anthropometry
    case auraPunch
    case reactiveStrike

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropometry: return "Anthropometry"
        case .auraPunch: return "Aura Punch"
        case .reactiveStrike: return "Reactive Strike"
        }
    }

    var subtitle: String {
        switch self {
        case .anthropometry: return "Calibrate height, reach, and guard"
        case .auraPunch: return "Follow a spatial punch guide"
        case .reactiveStrike: return "Hit floating targets on reaction"
        }
    }

    var isAvailable: Bool {
        self == .reactiveStrike || self == .auraPunch
    }
}

struct BoxingCoachContentView: View {
    @Environment(ReactiveStrikeSession.self) private var session
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    @State private var selectedFeature: TrainingFeature?
    @State private var selectedMode: ReactiveStrikeMode?
    @State private var selectedTechnique: Technique?
    @State private var immersiveOpened = false
    @State private var isBusy = false

    var body: some View {
        Group {
            if let selectedFeature {
                featureDetail(selectedFeature)
            } else {
                featureMenu
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 520)
    }

    private var featureMenu: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Boxing Coach")
                    .font(.largeTitle.bold())
                Text("Choose a training feature")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(TrainingFeature.allCases) { feature in
                    Button {
                        selectedFeature = feature
                        selectedMode = nil
                        selectedTechnique = nil
                    } label: {
                        featureRow(feature)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func featureRow(_ feature: TrainingFeature) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(feature.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(feature.isAvailable ? "Available" : "Soon")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    feature.isAvailable ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.18),
                    in: Capsule()
                )
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .opacity(feature.isAvailable ? 1 : 0.75)
    }

    @ViewBuilder
    private func featureDetail(_ feature: TrainingFeature) -> some View {
        VStack(spacing: 20) {
            HStack {
                Button {
                    goBack()
                } label: {
                    Label(backLabel, systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            VStack(spacing: 8) {
                Text(detailTitle(for: feature))
                    .font(.largeTitle.bold())
                Text(detailSubtitle(for: feature))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            switch feature {
            case .reactiveStrike:
                if let selectedMode {
                    reactiveStrikePanel(mode: selectedMode)
                } else {
                    reactiveStrikeModePicker
                }
            case .auraPunch:
                if let selectedTechnique {
                    auraPunchPanel(technique: selectedTechnique)
                } else {
                    techniquePicker
                }
            case .anthropometry:
                comingSoonPanel(feature)
            }
        }
    }

    private var reactiveStrikeModePicker: some View {
        VStack(spacing: 12) {
            ForEach(ReactiveStrikeMode.allCases) { mode in
                Button {
                    selectedMode = mode
                    session.selectMode(mode)
                    session.clearError()
                } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(mode.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func reactiveStrikePanel(mode: ReactiveStrikeMode) -> some View {
        VStack(spacing: 16) {
            Text(mode.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(statusLine)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

            if session.phase == .finished {
                resultsCard
            }

            if let error = session.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(session.phase == .finished ? "Run Again" : "Start Drill") {
                    Task { await startDrillFlow() }
                }
                .disabled(session.phase == .running || isBusy)
                .buttonStyle(.borderedProminent)

                if immersiveOpened {
                    Button("End") {
                        Task { await closeImmersiveSpace() }
                    }
                    .disabled(isBusy)
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var techniquePicker: some View {
        VStack(spacing: 12) {
            ForEach(Technique.all) { technique in
                Button {
                    selectedTechnique = technique
                    session.auraPunch.technique = technique
                    session.auraPunch.reset()
                } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(technique.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(technique.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .disabled(!technique.isImplemented)
                .opacity(technique.isImplemented ? 1 : 0.5)
            }
        }
    }

    private func auraPunchPanel(technique: Technique) -> some View {
        let aura = session.auraPunch

        return VStack(spacing: 16) {
            Text(technique.name)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(auraStatusLine)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

            if aura.phase == .attempting {
                // Live extension meter — shows the punch developing while it happens.
                ProgressView(value: Double(min(max(aura.liveReach, 0), 1)))
                    .tint(.accentColor)
            }

            if aura.phase == .results, let score = aura.score {
                auraScoreCard(score)
                if let feedback = aura.feedback {
                    auraFeedbackCard(feedback)
                }
            }

            if let error = aura.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(aura.phase == .results ? "Try Again" : "Start Rep") {
                    Task { await startAuraPunchFlow() }
                }
                .disabled(aura.isRunning || isBusy)
                .buttonStyle(.borderedProminent)

                if immersiveOpened {
                    Button("End") {
                        Task { await closeImmersiveSpace() }
                    }
                    .disabled(isBusy)
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func auraScoreCard(_ score: TechniqueScore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Score")
                .font(.headline)

            labeledRow("Overall", "\(Int(score.overall.rounded())) · \(score.grade)")

            Divider()

            // Sub-metrics rather than one opaque number — "68/100" tells a beginner nothing they
            // can act on, but a low Elbow row points straight at what to fix.
            ForEach(score.metrics) { metric in
                labeledRow(
                    metric.kind.title,
                    metric.score.map { "\(Int($0.rounded()))" } ?? "Not tracked"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func auraFeedbackCard(_ feedback: CoachingFeedback) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Coach")
                    .font(.headline)
                Spacer()
                if feedback.isOffline {
                    Text("Offline")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                }
            }

            Text(feedback.headline)
                .font(.body.weight(.medium))
            Text(feedback.primaryFix)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(feedback.encouragement)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func comingSoonPanel(_ feature: TrainingFeature) -> some View {
        VStack(spacing: 12) {
            Text("Coming soon")
                .font(.title2.bold())
            Text("\(feature.title) is planned for later. For this hackathon demo, use Reactive Strike.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Back to Features") {
                selectedFeature = nil
                selectedMode = nil
                selectedTechnique = nil
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Results")
                .font(.headline)

            labeledRow("Hits", "\(session.metrics.hitCount)")
            labeledRow("Misses", "\(session.metrics.missCount)")
            labeledRow("Accuracy", String(format: "%.0f%%", session.metrics.accuracy * 100))

            if let avg = session.metrics.averageReactionTime {
                labeledRow("Avg reaction", String(format: "%.0f ms", avg * 1000))
            }

            if let speed = session.metrics.averageEstimatedSpeed {
                labeledRow("Avg est. speed", String(format: "%.2f m/s", speed))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var backLabel: String {
        if selectedFeature == .reactiveStrike, selectedMode != nil {
            return "Modes"
        }
        if selectedFeature == .auraPunch, selectedTechnique != nil {
            return "Techniques"
        }
        return "Features"
    }

    private func detailTitle(for feature: TrainingFeature) -> String {
        if feature == .reactiveStrike, selectedMode == nil {
            return "Reactive Strike"
        }
        if feature == .auraPunch, selectedTechnique == nil {
            return "Aura Punch"
        }
        return feature.title
    }

    private func detailSubtitle(for feature: TrainingFeature) -> String {
        if feature == .reactiveStrike, selectedMode == nil {
            return "Choose Air Mode or Bag Mode"
        }
        if feature == .auraPunch, selectedTechnique == nil {
            return "Choose a punch to learn"
        }
        return feature.subtitle
    }

    private var auraStatusLine: String {
        let aura = session.auraPunch
        switch aura.phase {
        case .idle:
            return "Stand facing forward with both hands up, then tap Start Rep"
        case .results:
            return aura.statusMessage
        default:
            return aura.statusMessage
        }
    }

    private var statusLine: String {
        if session.phase == .running {
            return "\(session.progressLabel) · \(session.lastFeedback)"
        }
        if session.phase == .finished {
            return "Round complete"
        }
        return "Tap Start Drill to begin"
    }

    private func labeledRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.body)
    }

    private func goBack() {
        if selectedFeature == .reactiveStrike, selectedMode != nil {
            if immersiveOpened {
                Task { await closeImmersiveSpace() }
            }
            selectedMode = nil
            session.clearError()
            return
        }

        if selectedFeature == .auraPunch, selectedTechnique != nil {
            if immersiveOpened {
                Task { await closeImmersiveSpace() }
            }
            selectedTechnique = nil
            session.auraPunch.reset()
            session.clearError()
            return
        }

        if immersiveOpened {
            Task { await closeImmersiveSpace() }
        }
        selectedFeature = nil
        selectedMode = nil
        selectedTechnique = nil
        session.auraPunch.reset()
        session.clearError()
    }

    private func startDrillFlow() async {
        isBusy = true
        defer { isBusy = false }

        if session.phase == .finished {
            session.resetForNewRound()
        }

        if let selectedMode {
            session.selectMode(selectedMode)
        }

        guard await ensureImmersiveSpace() else { return }

        session.startDrill()
    }

    private func startAuraPunchFlow() async {
        isBusy = true
        defer { isBusy = false }

        session.auraPunch.reset()
        if let selectedTechnique {
            session.auraPunch.technique = selectedTechnique
        }

        guard await ensureImmersiveSpace() else { return }

        session.auraPunch.start()
    }

    /// Opens the mixed immersive space if it isn't already up. Returns false when the caller
    /// should abort — the error has already been reported to the user.
    private func ensureImmersiveSpace() async -> Bool {
        guard !immersiveOpened else { return true }

        guard supportsMultipleWindows else {
            session.reportError("Multiple scenes disabled — enable UIApplicationSupportsMultipleScenes")
            return false
        }

        switch await openImmersiveSpace(id: session.immersiveSpaceID) {
        case .opened:
            immersiveOpened = true
            session.clearError()
            return true
        case .userCancelled:
            immersiveOpened = false
            session.reportError("Immersive space cancelled")
            return false
        case .error:
            immersiveOpened = false
            session.reportError("Could not open immersive space (system error)")
            return false
        @unknown default:
            immersiveOpened = false
            session.reportError("Could not open immersive space (unknown result)")
            return false
        }
    }

    private func closeImmersiveSpace() async {
        isBusy = true
        defer { isBusy = false }
        session.stopDrill()
        await dismissImmersiveSpace()
        immersiveOpened = false
    }
}

#Preview {
    BoxingCoachContentView()
        .environment(ReactiveStrikeSession())
}

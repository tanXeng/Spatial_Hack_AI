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
        self == .reactiveStrike
    }
}

struct BoxingCoachContentView: View {
    @Environment(ReactiveStrikeSession.self) private var session
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    @State private var selectedFeature: TrainingFeature?
    @State private var selectedMode: ReactiveStrikeMode?
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

            if feature.isAvailable {
                if let selectedMode {
                    reactiveStrikePanel(mode: selectedMode)
                } else {
                    reactiveStrikeModePicker
                }
            } else {
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
        return "Features"
    }

    private func detailTitle(for feature: TrainingFeature) -> String {
        if feature == .reactiveStrike, selectedMode == nil {
            return "Reactive Strike"
        }
        return feature.title
    }

    private func detailSubtitle(for feature: TrainingFeature) -> String {
        if feature == .reactiveStrike, selectedMode == nil {
            return "Choose Air Mode or Bag Mode"
        }
        return feature.subtitle
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

        if immersiveOpened {
            Task { await closeImmersiveSpace() }
        }
        selectedFeature = nil
        selectedMode = nil
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

        if !immersiveOpened {
            guard supportsMultipleWindows else {
                session.reportError("Multiple scenes disabled — enable UIApplicationSupportsMultipleScenes")
                return
            }

            switch await openImmersiveSpace(id: session.immersiveSpaceID) {
            case .opened:
                immersiveOpened = true
                session.clearError()
            case .userCancelled:
                immersiveOpened = false
                session.reportError("Immersive space cancelled")
                return
            case .error:
                immersiveOpened = false
                session.reportError("Could not open immersive space (system error)")
                return
            @unknown default:
                immersiveOpened = false
                session.reportError("Could not open immersive space (unknown result)")
                return
            }
        }

        session.startDrill()
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

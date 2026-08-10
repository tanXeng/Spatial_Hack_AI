import SwiftUI

struct FeatureSelectionView: View {
    let controlsDisabled: Bool
    let onSelect: (TrainingFeature) -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Boxing Coach")
                    .font(.largeTitle.bold())
                Text("Choose a training feature")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(TrainingFeature.allCases) { feature in
                        Button {
                            onSelect(feature)
                        } label: {
                            featureRow(feature)
                        }
                        .buttonStyle(.plain)
                        .disabled(controlsDisabled)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(feature.title), \(feature.subtitle), \(feature.isAvailable ? "Available" : "Coming soon")"
                        )
                        .accessibilityHint(
                            feature.isAvailable ? "Opens training setup" : "Opens feature availability information"
                        )
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

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
                .accessibilityHidden(true)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .opacity(feature.isAvailable ? 1 : 0.75)
    }
}

struct ReactiveSetupView: View {
    let controlsDisabled: Bool
    let onSelect: (ReactiveStrikeMode) -> Void
    let onBack: () -> Void

    var body: some View {
        TrainingDetailScaffold(
            backLabel: "Features",
            title: "Reactive Strike",
            subtitle: "Choose a target drill or a coached combination",
            controlsDisabled: controlsDisabled,
            onBack: onBack
        ) {
            VStack(spacing: 12) {
                ForEach(ReactiveStrikeMode.allCases) { mode in
                    Button {
                        onSelect(mode)
                    } label: {
                        selectionRow(title: mode.title, subtitle: mode.subtitle)
                    }
                    .buttonStyle(.plain)
                    .disabled(controlsDisabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(mode.title), \(mode.subtitle)")
                    .accessibilityHint("Opens the training experience")
                }
            }
        }
    }
}

struct CombinationSetupView: View {
    let stance: Stance
    let controlsDisabled: Bool
    let onStanceChange: (Stance) -> Void
    let onSelect: (Combination) -> Void
    let onBack: () -> Void

    var body: some View {
        TrainingDetailScaffold(
            backLabel: "Modes",
            title: "Combination Mode",
            subtitle: "Choose your stance and combination",
            controlsDisabled: controlsDisabled,
            onBack: onBack
        ) {
            VStack(spacing: 20) {
                StancePickerCard(
                    stance: stance,
                    controlsDisabled: controlsDisabled,
                    onStanceChange: onStanceChange
                )

                VStack(spacing: 12) {
                    ForEach(Combination.all) { combination in
                        Button {
                            onSelect(combination)
                        } label: {
                            selectionRow(
                                title: "\(combination.numberNotation) · \(combination.name)",
                                subtitle: combination.summary
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(controlsDisabled)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(combination.numberNotation), \(combination.name), \(combination.summary)"
                        )
                        .accessibilityHint("Opens the combination training experience")
                    }
                }
            }
        }
    }
}

struct CompetitionSetupView: View {
    let playerName: String
    let errorMessage: String?
    let controlsDisabled: Bool
    let onSelect: (CompetitionMode) -> Void
    let onLeaderboard: () -> Void
    let onRecalibrate: () -> Void
    let onChangePlayer: () -> Void
    let onBack: () -> Void

    var body: some View {
        TrainingDetailScaffold(
            backLabel: "Home",
            title: "Competition",
            subtitle: "\(playerName) · Choose a ranked challenge",
            controlsDisabled: controlsDisabled,
            onBack: onBack
        ) {
            VStack(spacing: 12) {
                if let errorMessage {
                    TrainingErrorCard(message: errorMessage)
                }

                ForEach(CompetitionMode.allCases) { mode in
                    Button {
                        onSelect(mode)
                    } label: {
                        selectionRow(title: mode.title, subtitle: mode.subtitle)
                    }
                    .buttonStyle(.plain)
                    .disabled(controlsDisabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(mode.title), \(mode.subtitle)")
                    .accessibilityHint("Opens the ranked challenge setup")
                }

                ViewThatFits(in: .horizontal) {
                    HStack { utilityButtons }
                    VStack { utilityButtons }
                }
            }
        }
    }

    @ViewBuilder
    private var utilityButtons: some View {
        Button("View Leaderboards", systemImage: "trophy") { onLeaderboard() }
            .frame(minHeight: 44)
            .disabled(controlsDisabled)
        Button("Recalibrate Reach", systemImage: "ruler") { onRecalibrate() }
            .frame(minHeight: 44)
            .disabled(controlsDisabled)
        Button("Change Player", systemImage: "person.2") { onChangePlayer() }
            .frame(minHeight: 44)
            .disabled(controlsDisabled)
    }
}

struct AuraSetupView: View {
    let stance: Stance
    let controlsDisabled: Bool
    let onStanceChange: (Stance) -> Void
    let onSelect: (Technique) -> Void
    let onBack: () -> Void

    var body: some View {
        TrainingDetailScaffold(
            backLabel: "Features",
            title: "Aura Punch",
            subtitle: "Choose your stance and a punch to learn",
            controlsDisabled: controlsDisabled,
            onBack: onBack
        ) {
            VStack(spacing: 20) {
                StancePickerCard(
                    stance: stance,
                    controlsDisabled: controlsDisabled,
                    onStanceChange: onStanceChange
                )

                VStack(spacing: 12) {
                    ForEach(Technique.all) { technique in
                        Button {
                            onSelect(technique)
                        } label: {
                            techniqueRow(technique)
                        }
                        .buttonStyle(.plain)
                        .disabled(controlsDisabled || !technique.isImplemented)
                        .opacity(technique.isImplemented ? 1 : 0.5)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(technique.name), \(technique.summary), \(technique.hand.requirementDescription(for: stance))"
                        )
                        .accessibilityHint(
                            technique.isImplemented ? "Opens the training experience" : "Coming soon"
                        )
                    }
                }
            }
        }
    }

    private func techniqueRow(_ technique: Technique) -> some View {
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

            Text(technique.hand.requirementDescription(for: stance))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.18), in: Capsule())
                .accessibilityHidden(true)

            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private func selectionRow(title: String, subtitle: String) -> some View {
    HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
    .padding(18)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
}

#Preview("Competition Setup") {
    CompetitionSetupView(
        playerName: "Alex",
        errorMessage: nil,
        controlsDisabled: false,
        onSelect: { _ in },
        onLeaderboard: {},
        onRecalibrate: {},
        onChangePlayer: {},
        onBack: {}
    )
    .padding(32)
}

#Preview("Competition Setup Error") {
    CompetitionSetupView(
        playerName: "Alex",
        errorMessage: "That run was not complete, so no leaderboard result was saved.",
        controlsDisabled: false,
        onSelect: { _ in },
        onLeaderboard: {},
        onRecalibrate: {},
        onChangePlayer: {},
        onBack: {}
    )
    .padding(32)
}

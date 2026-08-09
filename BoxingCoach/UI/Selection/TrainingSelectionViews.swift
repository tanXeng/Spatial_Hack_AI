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

struct AuraTrackSetupView: View {
    let controlsDisabled: Bool
    let onSelect: (TrainingTrack) -> Void
    let onBack: () -> Void

    private let tracks: [TrainingTrack] = [.firstRound, .technicalCamp]

    var body: some View {
        TrainingDetailScaffold(
            backLabel: "Features",
            title: "Choose Your Track",
            subtitle: "Your track changes coaching pace and wording, never scoring",
            controlsDisabled: controlsDisabled,
            onBack: onBack
        ) {
            VStack(spacing: 12) {
                ForEach(tracks) { track in
                    Button {
                        onSelect(track)
                    } label: {
                        selectionRow(
                            title: track.title,
                            subtitle: track.introCopy
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(controlsDisabled)
                    .frame(minHeight: 60)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(track.title), \(track.introCopy)")
                    .accessibilityHint("Chooses this coaching track, then opens technique selection")
                    .accessibilityInputLabels([track.title])
                }
            }
        }
    }
}

struct AuraSetupView: View {
    let track: TrainingTrack
    let stance: Stance
    let controlsDisabled: Bool
    let onStanceChange: (Stance) -> Void
    let onSelect: (Technique) -> Void
    let onBack: () -> Void

    var body: some View {
        TrainingDetailScaffold(
            backLabel: "Tracks",
            title: "Aura Punch",
            subtitle: "\(track.title) · Choose your stance and a punch to learn",
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
                        .frame(minHeight: 60)
                        .opacity(technique.isImplemented ? 1 : 0.5)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(technique.name), \(technique.summary), \(technique.hand.requirementDescription(for: stance))"
                        )
                        .accessibilityHint(
                            technique.isImplemented ? "Opens the training experience" : "Coming soon"
                        )
                        .accessibilityInputLabels([technique.name])
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

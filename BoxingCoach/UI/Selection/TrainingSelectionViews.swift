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
            subtitle: "Choose Air Mode or Bag Mode",
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
                VStack(alignment: .leading, spacing: 10) {
                    Text("Stance")
                        .font(.headline)

                    Picker(
                        "Stance",
                        selection: Binding(
                            get: { stance },
                            set: { onStanceChange($0) }
                        )
                    ) {
                        ForEach(Stance.allCases) { stance in
                            Text(stance.title).tag(stance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(controlsDisabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

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

struct UnavailableFeatureView: View {
    let feature: TrainingFeature
    let controlsDisabled: Bool
    let onBack: () -> Void

    var body: some View {
        TrainingDetailScaffold(
            backLabel: "Features",
            title: feature.title,
            subtitle: feature.subtitle,
            controlsDisabled: controlsDisabled,
            onBack: onBack
        ) {
            VStack(spacing: 12) {
                Text("Coming soon")
                    .font(.title2.bold())
                Text("\(feature.title) is planned for later. For this demo, use Aura Punch or Reactive Strike.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Back to Features") {
                    onBack()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controlsDisabled)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
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

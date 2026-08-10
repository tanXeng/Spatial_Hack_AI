import SwiftUI

struct TrainingDetailScaffold<Content: View>: View {
    let backLabel: String
    let title: String
    let subtitle: String
    let controlsDisabled: Bool
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button {
                    onBack()
                } label: {
                    Label(backLabel, systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .frame(
                    minWidth: TrainingAccessibility.minimumControlHitRegion,
                    minHeight: TrainingAccessibility.minimumControlHitRegion
                )
                .disabled(controlsDisabled)

                Spacer()
            }

            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text(title)
                            .font(.largeTitle.bold())
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    content()
                }
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

struct TrainingStatusCard: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("Training status")
            .accessibilityValue(message)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct TrainingErrorCard: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(TrainingPalette.invalidCoral)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("Training error")
            .accessibilityValue(message)
    }
}

struct RuntimeRecoveryCard: View {
    let presentation: RuntimeRecoveryPresentation
    let controlsDisabled: Bool
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Label(presentation.title, systemImage: "arrow.clockwise.circle.fill")
                    .font(.headline)

                Text(presentation.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            if let label = presentation.primaryActionLabel, let action {
                Button(label, action: action)
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 60, minHeight: 60)
                    .disabled(controlsDisabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PunchExtensionMeter: View {
    let value: Float

    private var clampedValue: Double {
        Double(min(max(value, 0), 1))
    }

    var body: some View {
        ProgressView(value: clampedValue)
            .tint(.accentColor)
            .accessibilityLabel("Punch extension")
            .accessibilityValue("\(Int((clampedValue * 100).rounded())) percent")
    }
}

struct LabeledMetricRow: View {
    let title: String
    let value: String
    var spokenValue: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.body)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue ?? value)
    }
}

struct StancePickerCard: View {
    let stance: Stance
    let controlsDisabled: Bool
    let onStanceChange: (Stance) -> Void

    var body: some View {
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

            Text(stance.footDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

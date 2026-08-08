import SwiftUI

struct TrainingDetailScaffold<Content: View>: View {
    let backLabel: String
    let title: String
    let subtitle: String
    let controlsDisabled: Bool
    let onBack: () -> Void
    let onExit: () -> Void
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
                .disabled(controlsDisabled)

                Spacer()

                Button("Exit", systemImage: "xmark.circle") {
                    onExit()
                }
                .buttonStyle(.bordered)
                .disabled(controlsDisabled)
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
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("Training error")
            .accessibilityValue(message)
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

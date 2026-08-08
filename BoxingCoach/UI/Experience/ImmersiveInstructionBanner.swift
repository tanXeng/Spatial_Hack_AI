import SwiftUI

struct ImmersiveInstruction: Equatable {
    let stage: String
    let message: String
    let symbol: String
}

/// A narrow, head-anchored cue that explains what the user should do without recreating the
/// selection window inside the immersive experience.
struct ImmersiveInstructionBanner: View {
    let instruction: ImmersiveInstruction

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: instruction.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(instruction.stage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)

                Text(instruction.message)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .frame(width: 480, alignment: .leading)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(instruction.stage)
        .accessibilityValue(instruction.message)
        .accessibilityAddTraits(.updatesFrequently)
        .animation(.easeInOut(duration: 0.2), value: instruction)
    }
}

#Preview {
    ImmersiveInstructionBanner(
        instruction: ImmersiveInstruction(
            stage: "FOLLOW THE SAMPLE",
            message: "Rep 1 of 4: follow the ghost out",
            symbol: "eye.fill"
        )
    )
    .padding(40)
}

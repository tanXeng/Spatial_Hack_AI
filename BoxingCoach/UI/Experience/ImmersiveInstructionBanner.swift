import SwiftUI

struct ImmersiveInstruction: Equatable {
    let stage: String
    let message: String
    let symbol: String
}

enum ImmersiveInstructionBannerStyle {
    case compact
    case prominent
}

/// A narrow, head-anchored cue that explains what the user should do without recreating the
/// selection window inside the immersive experience.
struct ImmersiveInstructionBanner: View {
    let instruction: ImmersiveInstruction
    var style: ImmersiveInstructionBannerStyle = .compact

    var body: some View {
        HStack(spacing: iconSpacing) {
            Image(systemName: instruction.symbol)
                .font(iconFont)
                .foregroundStyle(.tint)
                .frame(width: iconFrame)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(instruction.stage)
                    .font(stageFont)
                    .foregroundStyle(.secondary)
                    .tracking(0.8)

                Text(instruction.message)
                    .font(messageFont)
                    .lineLimit(messageLineLimit)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(width: bannerWidth, alignment: .leading)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(instruction.stage)
        .accessibilityValue(instruction.message)
        .accessibilityAddTraits(.updatesFrequently)
        .animation(.easeInOut(duration: 0.2), value: instruction)
    }

    private var bannerWidth: CGFloat {
        style == .prominent ? 620 : 480
    }

    private var cornerRadius: CGFloat {
        style == .prominent ? 20 : 18
    }

    private var horizontalPadding: CGFloat {
        style == .prominent ? 24 : 20
    }

    private var verticalPadding: CGFloat {
        style == .prominent ? 16 : 11
    }

    private var iconSpacing: CGFloat {
        style == .prominent ? 16 : 14
    }

    private var iconFrame: CGFloat {
        style == .prominent ? 36 : 28
    }

    private var iconFont: Font {
        style == .prominent ? .title2.weight(.semibold) : .title3.weight(.semibold)
    }

    private var stageFont: Font {
        style == .prominent ? .subheadline.weight(.bold) : .caption.weight(.bold)
    }

    private var messageFont: Font {
        style == .prominent ? .title3 : .headline
    }

    private var messageLineLimit: Int {
        style == .prominent ? 3 : 2
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

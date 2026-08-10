import SwiftUI

struct ImmersiveInstruction: Equatable {
    let stage: String
    let message: String
    let symbol: String
    var action: String? = nil
    var progress: String? = nil
    var metric: String? = nil
    var source: String? = nil
}

enum ImmersiveInstructionBannerStyle {
    case compact
    case prominent
    case coaching
}

enum ImmersiveInstructionBannerLayout {
    static func messageLineLimit(
        for style: ImmersiveInstructionBannerStyle,
        isAccessibilitySize: Bool
    ) -> Int? {
        guard !isAccessibilitySize else { return nil }
        switch style {
        case .compact: return 3
        case .prominent, .coaching: return 4
        }
    }
}

/// A narrow, head-anchored cue that explains what the user should do without recreating the
/// selection window inside the immersive experience.
struct ImmersiveInstructionBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let instruction: ImmersiveInstruction
    var style: ImmersiveInstructionBannerStyle = .compact

    var body: some View {
        Group {
            if style == .coaching {
                coachingBody
            } else {
                standardBody
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(width: bannerWidth, alignment: .leading)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(instruction.stage)
        .accessibilityValue(instruction.accessibilityValue)
        .accessibilityAddTraits(.updatesFrequently)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: instruction)
    }

    private var standardBody: some View {
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
                    .fixedSize(horizontal: false, vertical: true)

                supportingDetails
            }

            Spacer(minLength: 8)
        }
    }

    private var coachingBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: instruction.symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text(instruction.stage)
                    .font(.largeTitle.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }

            Text(instruction.message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(messageLineLimit)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            supportingDetails
        }
    }

    @ViewBuilder
    private var supportingDetails: some View {
        if let progress = instruction.progress {
            Text(progress)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        if let metric = instruction.metric {
            Text(metric)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.cyan)
        }
        if let source = instruction.source {
            Text(source)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        if let action = instruction.action {
            Label(action, systemImage: "arrow.right.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
        }
    }

    private var bannerWidth: CGFloat {
        switch style {
        case .compact: return 480
        case .prominent: return 620
        case .coaching: return 720
        }
    }

    private var cornerRadius: CGFloat {
        style == .compact ? 18 : 20
    }

    private var horizontalPadding: CGFloat {
        switch style {
        case .compact: return 20
        case .prominent: return 24
        case .coaching: return 28
        }
    }

    private var verticalPadding: CGFloat {
        switch style {
        case .compact: return 11
        case .prominent: return 16
        case .coaching: return 22
        }
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

    private var messageLineLimit: Int? {
        ImmersiveInstructionBannerLayout.messageLineLimit(
            for: style,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }
}

#Preview {
    ImmersiveInstructionBanner(
        instruction: ImmersiveInstruction(
            stage: "FOLLOW THE HOLOGRAM",
            message: "Rep 1 of 4 — extend with the hologram",
            symbol: "eye.fill"
        ),
        style: .coaching
    )
    .padding(40)
}

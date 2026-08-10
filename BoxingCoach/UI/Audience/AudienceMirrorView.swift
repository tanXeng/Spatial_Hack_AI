import SwiftUI

struct AudienceMirrorView: View {
    @Environment(ReactiveStrikeSession.self) private var session
    @Environment(TrainingFlowCoordinator.self) private var flow
    @Environment(CompetitionStore.self) private var competitionStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let presentation = AudienceMirrorPresenter.presentation(for: state)
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.055)
                .ignoresSafeArea()

            ViewThatFits(in: .vertical) {
                content(presentation, spacing: 28)
                ScrollView { content(presentation, spacing: 18) }
            }
            .padding(48)
        }
        .accessibilityElement(children: .contain)
    }

    private var state: TrainingPresentationState {
        TrainingPresentationPolicy.liveState(
            flow: flow,
            session: session,
            competitionStore: competitionStore
        )
    }

    private func content(
        _ presentation: AudienceMirrorPresentation,
        spacing: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(presentation.stage)
                .font(.system(.largeTitle, design: .rounded, weight: .black))
                .foregroundStyle(.orange)
                .accessibilityAddTraits(.isHeader)

            Text(presentation.instruction)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if let source = presentation.coachingSource {
                Text(source)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.76))
            }

            if let progress = presentation.progress {
                publicMetric("Progress", progress)
            }
            if let proof = presentation.proofMetric {
                publicMetric("Proof", proof)
            }

            HStack(spacing: 24) {
                if let score = presentation.score { publicMetric("Score", score) }
                if let rank = presentation.rank { publicMetric("Standing", rank) }
            }

            Spacer(minLength: 0)

            if let identity = presentation.publicIdentity {
                Label(identity, systemImage: "person.crop.circle")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .accessibilityLabel("Event-local participant \(identity)")
            } else {
                Text("No private profile, transcript, or motion data is shown.")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(36)
        .background(
            reduceTransparency ? Color.black : Color.black.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 32)
        )
    }

    private func publicMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.64))
            Text(value)
                .font(.title2.monospacedDigit().bold())
                .foregroundStyle(.cyan)
        }
        .accessibilityElement(children: .combine)
    }
}

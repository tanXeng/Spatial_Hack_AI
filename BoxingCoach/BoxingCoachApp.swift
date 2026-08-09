import SwiftUI

enum BoxingCoachSceneID {
    // Versioned once to prevent visionOS from restoring WindowGroup sessions created by builds
    // before the control scene became single-instance.
    static let controlWindow = "BoxingCoachControlWindow.Single"
    static let immersiveSpace = "ReactiveStrike"
}

@main
struct BoxingCoachApp: App {
    @State private var session: ReactiveStrikeSession
    @State private var flow = TrainingFlowCoordinator()
    @State private var competitionStore = CompetitionStore.live()

    init() {
        _session = State(initialValue: ReactiveStrikeSession(
            feedbackGenerator: FeedbackGenerator.production()
        ))
    }

    var body: some Scene {
        // `Window` is intentionally single-instance. A named `WindowGroup` creates another
        // window each time `openWindow(id:)` is called, which stacked duplicate control layers
        // when both explicit and system-driven immersive cleanup restored the UI.
        Window("Boxing Coach", id: BoxingCoachSceneID.controlWindow) {
            BoxingCoachRootView()
                .environment(session)
                .environment(flow)
                .environment(competitionStore)
        }

        ImmersiveSpace(id: BoxingCoachSceneID.immersiveSpace) {
            BoxingCoachImmersiveView()
                .environment(session)
                .environment(flow)
                .environment(competitionStore)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

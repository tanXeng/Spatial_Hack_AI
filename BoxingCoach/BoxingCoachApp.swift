import SwiftUI

enum BoxingCoachSceneID {
    static let controlWindow = "BoxingCoachControlWindow"
    static let immersiveSpace = "ReactiveStrike"
}

@main
struct BoxingCoachApp: App {
    @State private var session = ReactiveStrikeSession()
    @State private var flow = TrainingFlowCoordinator()

    var body: some Scene {
        WindowGroup(id: BoxingCoachSceneID.controlWindow) {
            BoxingCoachRootView()
                .environment(session)
                .environment(flow)
        }

        ImmersiveSpace(id: BoxingCoachSceneID.immersiveSpace) {
            BoxingCoachImmersiveView()
                .environment(session)
                .environment(flow)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

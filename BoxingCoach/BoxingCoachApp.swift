import SwiftUI

enum BoxingCoachSceneID {
    static let immersiveSpace = "ReactiveStrike"
}

@main
struct BoxingCoachApp: App {
    @State private var session = ReactiveStrikeSession()

    var body: some Scene {
        WindowGroup {
            BoxingCoachContentView()
                .environment(session)
        }

        ImmersiveSpace(id: BoxingCoachSceneID.immersiveSpace) {
            BoxingCoachImmersiveView()
                .environment(session)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

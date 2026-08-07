import RealityKit
import SwiftUI

/// Mixed immersive scene hosting Air Mode targets and the Reactive Strike drill loop.
struct BoxingCoachImmersiveView: View {
    @Environment(ReactiveStrikeSession.self) private var session

    var body: some View {
        RealityView { content in
            let root = Entity()
            root.name = "ReactiveStrikeRoot"
            content.add(root)
            session.attachSceneRoot(root)
        }
        .task {
            // Start hand tracking as soon as the space opens; drill starts from the window UI.
            await session.hands.start()
        }
        .onDisappear {
            session.stopDrill()
            session.hands.stop()
        }
    }
}

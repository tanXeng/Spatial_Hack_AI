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
            session.immersiveSpaceDidOpen()
            await session.hands.start()
        }
        .onDisappear {
            // Reports the close however it happened — our own button, or the system taking the
            // space away — so the window UI can never believe a dismissed space is still up.
            session.immersiveSpaceDidClose()
            session.stopDrill()
            session.hands.stop()
        }
    }
}

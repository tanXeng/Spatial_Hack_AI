import RealityKit
import SwiftUI

/// Mixed immersive scene hosting spatial targets and Aura Punch silhouettes.
/// Window navigation and scene transitions remain in `TrainingFlowCoordinator`.
struct BoxingCoachImmersiveView: View {
    @Environment(ReactiveStrikeSession.self) private var session
    @Environment(TrainingFlowCoordinator.self) private var flow

    var body: some View {
        RealityView { content in
            let root = Entity()
            root.name = "BoxingCoachTrainingRoot"
            content.add(root)
            session.attachSceneRoot(root)
            flow.immersiveSceneDidBecomeReady(session: session)
        }
        .onDisappear {
            // Idempotent whether closure was requested by the coordinator or by the system.
            flow.immersiveSceneDidClose(session: session)
        }
    }
}

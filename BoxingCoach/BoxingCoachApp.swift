import SwiftUI

enum BoxingCoachSceneID {
    // Versioned once to prevent visionOS from restoring WindowGroup sessions created by builds
    // before the control scene became single-instance.
    static let controlWindow = "BoxingCoachControlWindow.Single"
    static let immersiveSpace = "ReactiveStrike"
}

@main
struct BoxingCoachApp: App {
    // One measurement per launch, shared by every feature. Created first so both the session and
    // the coordinator observe the same instance.
    @State private var calibration: BodyCalibration
    @State private var session: ReactiveStrikeSession
    @State private var flow: TrainingFlowCoordinator

    init() {
        let calibration = BodyCalibration()
        _calibration = State(initialValue: calibration)
        _session = State(initialValue: ReactiveStrikeSession(calibration: calibration))
        _flow = State(initialValue: TrainingFlowCoordinator(calibration: calibration))
    }

    var body: some Scene {
        // `Window` is intentionally single-instance. A named `WindowGroup` creates another
        // window each time `openWindow(id:)` is called, which stacked duplicate control layers
        // when both explicit and system-driven immersive cleanup restored the UI.
        Window("Boxing Coach", id: BoxingCoachSceneID.controlWindow) {
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

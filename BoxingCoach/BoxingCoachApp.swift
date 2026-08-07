//
//  BoxingCoachApp.swift
//  BoxingCoach
//
//  Created by Tan Xeng Ian on 7/8/26.
//
import SwiftUI

@main
struct BoxingCoachApp: App {
    @State private var appModel = AppModel()
    @State private var avPlayerViewModel = AVPlayerViewModel()
    @State private var poseModel = PoseTrackingModel()   // NEW

    var body: some Scene {
        WindowGroup {
            if avPlayerViewModel.isPlaying {
                AVPlayerView(viewModel: avPlayerViewModel)
            } else {
                ContentView()
                    .environment(appModel)
                    .environment(poseModel)   // NEW — so ContentView can show PoseReadoutView
            }
        }
        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .environment(poseModel)   // NEW
                .onAppear {
                    appModel.immersiveSpaceState = .open
                    avPlayerViewModel.play()
                    Task {                 // NEW — start hand tracking once the space is open
                        await poseModel.start()
                    }
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                    avPlayerViewModel.reset()
                    poseModel.stop()   // NEW — otherwise start() no-ops if the space reopens
                }
        }
        .immersionStyle(selection: .constant(.progressive), in: .progressive)
    }
}

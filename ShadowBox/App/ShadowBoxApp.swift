//
//  ShadowBoxApp.swift
//  ShadowBox
//
//  Created by Event on 7/8/26.
//

import SwiftUI

@main
struct ShadowBoxApp: App {
    @State private var appModel = AppModel()
    @State private var handTracking = HandTrackingService()
    @State private var roundEngine = RoundEngine()
    @State private var profileStore = TrainingProfileStore()
    @State private var auraPunch = AuraPunchEngine()
    @State private var defense = DefenseEngine()
    @State private var trainingSettings = TrainingSessionSettings(
        defaults: .standard
    )

    var body: some Scene {
        #if os(visionOS)
        Window("ShadowBox", id: "main") {
            ContentView()
                .environment(appModel)
                .environment(handTracking)
                .environment(roundEngine)
                .environment(profileStore)
                .environment(auraPunch)
                .environment(defense)
                .environment(trainingSettings)
        }
        .defaultSize(width: 700, height: 780)
        .windowResizability(.contentMinSize)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .environment(handTracking)
                .environment(roundEngine)
                .environment(profileStore)
                .environment(auraPunch)
                .environment(defense)
                .environment(trainingSettings)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                    appModel.immersiveSpaceError = nil
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        #else
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(handTracking)
                .environment(roundEngine)
                .environment(profileStore)
                .environment(auraPunch)
                .environment(defense)
                .environment(trainingSettings)
        }
        #endif
    }
}

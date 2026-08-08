//
//  ToggleImmersiveSpaceButton.swift
//  Test
//

import SwiftUI

struct ToggleImmersiveSpaceButton: View {
    let experience: ImmersiveExperience
    let entryAllowed: Bool

    @Environment(AppModel.self) private var appModel
    @Environment(RoundEngine.self) private var roundEngine
    @Environment(AuraPunchEngine.self) private var auraPunch
    @Environment(DefenseEngine.self) private var defense
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        Button {
            Task { @MainActor in
                switch appModel.immersiveSpaceState {
                case .open:
                    appModel.immersiveSpaceState = .inTransition
                    stopActiveExperience()
                    await dismissImmersiveSpace()
                    // onDisappear is the single source of truth for `.closed`.

                case .closed:
                    appModel.immersiveSpaceState = .inTransition
                    appModel.immersiveSpaceError = nil
                    appModel.activeExperience = experience
                    switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
                    case .opened:
                        appModel.lastExperience = experience
                        // Preserve completed results if opening is cancelled or
                        // fails; only reset the selected experience once its
                        // new space actually exists.
                        prepareFreshEntryIfNeeded()
                        // onAppear is the single source of truth for `.open`.
                        break
                    case .userCancelled:
                        appModel.immersiveSpaceState = .closed
                        appModel.activeExperience = nil
                    case .error:
                        appModel.immersiveSpaceError = "The mixed immersive space could not be opened."
                        appModel.immersiveSpaceState = .closed
                        appModel.activeExperience = nil
                    @unknown default:
                        appModel.immersiveSpaceError = "The system returned an unknown immersive-space result."
                        appModel.immersiveSpaceState = .closed
                        appModel.activeExperience = nil
                    }

                case .inTransition:
                    break
                }
            }
        } label: {
            Label(
                appModel.immersiveSpaceState == .open
                    ? "Stop and Exit"
                    : "Enter \(experienceTitle)",
                systemImage: appModel.immersiveSpaceState == .open
                    ? "stop.circle.fill"
                    : "vision.pro"
            )
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(
            appModel.immersiveSpaceState == .inTransition
                || (appModel.immersiveSpaceState == .closed && !entryAllowed)
        )
        .animation(.none, value: 0)
        .fontWeight(.semibold)
    }

    private var experienceTitle: String {
        switch experience {
        case .anthropometryCalibration:
            "Live Calibration"
        case .auraPunch:
            "Aura Punch"
        case .reactiveBoard:
            "Punch Board"
        case .bagPreview:
            "Bag Preview"
        case .defense:
            "Defense Lab"
        }
    }

    private func prepareFreshEntryIfNeeded() {
        switch experience {
        case .anthropometryCalibration, .reactiveBoard:
            if roundEngine.phase == .finished {
                roundEngine.prepareAnotherRound()
            }
        case .auraPunch:
            if roundEngine.phase == .finished {
                roundEngine.prepareAnotherRound()
            }
            if auraPunch.phase == .completed {
                auraPunch.stop(preservingCompletedResults: false)
            }
        case .defense:
            if defense.phase == .completed {
                defense.stop(preservingCompletedResults: false)
            }
        case .bagPreview:
            break
        }
    }

    private func stopActiveExperience() {
        switch appModel.activeExperience {
        case .auraPunch:
            auraPunch.stop()
        case .defense:
            defense.stop()
        case .anthropometryCalibration, .reactiveBoard, .bagPreview, nil:
            roundEngine.stop()
        }
    }
}

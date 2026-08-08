//
//  AppModel.swift
//  Test
//
//  Created by Event on 7/8/26.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"

    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    var immersiveSpaceState = ImmersiveSpaceState.closed
    var immersiveSpaceError: String?
    /// The window chooses an experience before opening the single mixed space.
    /// Keeping this selection outside RealityKit lets the immersive view route
    /// presentation without creating competing ARKit sessions.
    var activeExperience: ImmersiveExperience?
    /// Restores the correct window route if visionOS recreates the main window
    /// during or after an immersive session. This is session state only.
    var lastExperience: ImmersiveExperience?

    var activeExperienceTitle: String {
        switch activeExperience {
        case .anthropometryCalibration:
            "Body & Reach Setup"
        case .auraPunch:
            "Aura Punch"
        case .reactiveBoard:
            "Virtual Punch Board"
        case .bagPreview:
            "Physical Bag Preview"
        case .defense:
            "Defense — Head Movement"
        case nil:
            "Training"
        }
    }
}

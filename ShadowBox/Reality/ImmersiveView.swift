//
//  ImmersiveView.swift
//  Test
//

import SwiftUI
import RealityKit
import UIKit
import simd

#if os(visionOS)

struct ImmersiveView: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var appModel
    @Environment(HandTrackingService.self) private var handTracking
    @Environment(RoundEngine.self) private var roundEngine
    @Environment(TrainingProfileStore.self) private var profileStore
    @Environment(AuraPunchEngine.self) private var auraPunch
    @Environment(DefenseEngine.self) private var defense
    @Environment(TrainingSessionSettings.self) private var trainingSettings
    @State private var presentationTimestamp = ProcessInfo.processInfo.systemUptime
    @State private var auraPausedForSystemInterruption = false
    @State private var spatialFeedback = SpatialFeedbackPlayer()

    private let sceneRootName = "shadowbox.mvp.root"
    private let markerPrefix = "shadowbox.marker."
    private let fistPrefix = "shadowbox.fist."
    private let boardPadPrefix = "shadowbox.board.pad."
    private let boardBackdropName = "shadowbox.board.backdrop"
    private let auraGuideName = "shadowbox.aura.guide"
    private let auraPathPrefix = "shadowbox.aura.path."
    private let auraPathPointCount = 15
    private let bagBodyName = "shadowbox.bag.body"
    private let bagPadPrefix = "shadowbox.bag.pad."
    private let maximumBagPadCount = 6
    private let defenseCueName = "shadowbox.defense.cue"

    var body: some View {
        RealityView { content in
            let root = Entity()
            root.name = sceneRootName
            root.addChild(makeBoardBackdrop())
            for index in 0..<roundEngine.boardTargetCount {
                root.addChild(makeBoardPad(index: index))
            }
            root.addChild(makeAuraGuide())
            for index in 0..<auraPathPointCount {
                root.addChild(makeAuraPathPoint(index: index))
            }
            root.addChild(makeBagBody())
            for index in 0..<maximumBagPadCount {
                root.addChild(makeBagPad(index: index))
            }
            root.addChild(makeDefenseCue())
            root.addChild(makeSafetyControls())
            spatialFeedback.prepare(in: root)
            content.add(root)
        } update: { content in
            guard let root = content.entities.first(where: { $0.name == sceneRootName }) else {
                return
            }

            updateBoard(in: root)
            updateAuraGuide(in: root)
            updateBagPreview(in: root)
            updateDefenseCue(in: root)
            updateDiagnosticMarkers(in: root)
            updateFistCenters(in: root)
        }
        .task {
            guard appModel.activeExperience != .bagPreview else { return }
            await handTracking.start(
                requiresHandTracking: appModel.activeExperience != .defense
            )
        }
        .task {
            // `samples` intentionally has one consumer. Routing here prevents
            // several feature tasks from racing over the same AsyncStream.
            for await sample in handTracking.samples {
                guard !Task.isCancelled else { return }
                roundEngine.ingest(sample)
                if appModel.activeExperience == .auraPunch {
                    auraPunch.ingest(
                        sample,
                        devicePose: handTracking.latestDevicePose
                    )
                }
            }
        }
        .task {
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                presentationTimestamp = now

                if appModel.activeExperience == .auraPunch {
                    auraPunch.tick(at: now)
                }

                if appModel.activeExperience == .defense {
                    if let devicePose = handTracking.latestDevicePose {
                        defense.ingestDevicePosition(
                            devicePose.position,
                            rightDirection: devicePose.rightDirection,
                            capturedAt: devicePose.capturedAt
                        )
                    }
                    defense.tick(at: now)
                }

                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        .onChange(of: handTracking.state, initial: true) { _, newState in
            roundEngine.setTrackingState(newState)

            if appModel.activeExperience == .auraPunch,
               !newState.hasBothHands,
               (auraPunch.phase == .demonstrating || auraPunch.phase == .following) {
                if scenePhase == .active {
                    auraPausedForSystemInterruption = false
                }
                auraPunch.pause(reason: newState.detail)
            }

            if appModel.activeExperience == .auraPunch,
               newState.hasBothHands,
               scenePhase == .active,
               auraPausedForSystemInterruption,
               auraPunch.phase == .paused {
                auraPunch.resume(at: ProcessInfo.processInfo.systemUptime)
                auraPausedForSystemInterruption = false
            }

            if appModel.activeExperience == .defense,
               handTracking.latestDevicePose == nil {
                defense.pause(
                    reason: .trackingUnavailable,
                    at: ProcessInfo.processInfo.systemUptime
                )
            }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            if newPhase == .active {
                roundEngine.resumeFromSystemInterruption()
                if appModel.activeExperience == .auraPunch,
                   handTracking.state.hasBothHands,
                   auraPausedForSystemInterruption,
                   auraPunch.phase == .paused {
                    auraPunch.resume(at: ProcessInfo.processInfo.systemUptime)
                    auraPausedForSystemInterruption = false
                }
                if appModel.activeExperience == .defense,
                   case .paused(reason: .systemInterruption) = defense.phase {
                    defense.resume(at: ProcessInfo.processInfo.systemUptime)
                }
            } else {
                spatialFeedback.stop()
                roundEngine.pauseForSystemInterruption()
                if appModel.activeExperience == .auraPunch {
                    switch auraPunch.phase {
                    case .demonstrating, .following:
                        auraPausedForSystemInterruption = true
                        auraPunch.pause(reason: "System interruption")
                    case .paused:
                        // Tracking and scene notifications may arrive in
                        // either order. Preserve auto-recovery intent when the
                        // scene becomes inactive after tracking paused Aura.
                        auraPausedForSystemInterruption = true
                    case .idle, .completed:
                        break
                    }
                }
                if appModel.activeExperience == .defense {
                    defense.pause(
                        reason: .systemInterruption,
                        at: ProcessInfo.processInfo.systemUptime
                    )
                }
            }
        }
        .onChange(of: roundEngine.phase) { _, newPhase in
            if case .failed(let message) = newPhase {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Drill unavailable. \(message) Stop and exit the training space."
                )
            }
            if newPhase == .finished {
                playFeedback(.setComplete)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Punch Board complete. Returning to the results window."
                )
            }
            if newPhase == .finished,
               appModel.activeExperience == .reactiveBoard,
               appModel.immersiveSpaceState != .inTransition {
                requestAutomaticExit()
            }
        }
        .onChange(of: roundEngine.calibration) { _, calibration in
            guard calibration != nil,
                  let bilateralConservativeReach = roundEngine
                    .conservativeBilateralProfileReachMeters,
                  profileStore.hasProfile else { return }
            _ = profileStore.recordMeasuredComfortableReach(
                Double(bilateralConservativeReach)
            )
        }
        .onChange(of: auraPunch.phase) { _, newPhase in
            switch newPhase {
            case .demonstrating, .following:
                playFeedback(
                    .cue,
                    at: auraPunch.currentGuidePosition
                        ?? auraPunch.guide?.targetPosition
                )
            case .paused:
                playFeedback(.paused)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Aura Punch paused. \(auraPunch.feedback ?? auraPunch.instruction)"
                )
            case .completed:
                playFeedback(.setComplete)
            case .idle:
                break
            }
            if newPhase == .following {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Guide complete. Follow the path and return to guard."
                )
            }
            if newPhase == .completed,
               appModel.activeExperience == .auraPunch {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Aura Punch complete. Continue to the Punch Board or stop and review."
                )
            }
        }
        .onChange(of: auraPunch.repetitionResults.count) { oldCount, newCount in
            guard newCount > oldCount,
                  newCount < auraPunch.repetitionGoal,
                  auraPunch.phase != .completed,
                  let result = auraPunch.repetitionResults.last else { return }
            let sound: TrainingFeedbackSound
            if result.overallScore >= 0.85 {
                sound = .cleanHit
            } else if result.overallScore >= 0.65 {
                sound = .cue
            } else {
                sound = .miss
            }
            playFeedback(sound, at: auraPunch.guide?.targetPosition)
            let percent = Int((result.overallScore * 100).rounded())
            UIAccessibility.post(
                notification: .announcement,
                argument: "Aura repetition \(newCount) of \(auraPunch.repetitionGoal), guide score \(percent) percent. \(auraPunch.feedback ?? "")"
            )
        }
        .onChange(of: defense.phase) { _, newPhase in
            switch newPhase {
            case .paused:
                playFeedback(.paused)
            case .completed:
                playFeedback(.setComplete)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Defense set complete. Returning to the results window."
                )
            case .idle, .calibratingNeutral, .ready, .countdown, .active:
                break
            }
            if newPhase == .completed,
               appModel.activeExperience == .defense,
               appModel.immersiveSpaceState != .inTransition {
                requestAutomaticExit()
            }
        }
        .onChange(of: defense.currentCue?.id) { _, _ in
            guard let movement = defense.currentCue?.expectedMovement else { return }
            playFeedback(.cue, at: defenseAudioPosition(for: movement))
            UIAccessibility.post(
                notification: .announcement,
                argument: movement.title
            )
        }
        .onChange(of: defense.feedback) { _, newFeedback in
            if case .cue = newFeedback { return }
            switch newFeedback {
            case .success:
                playFeedback(.cleanHit)
            case .wrongDirection, .didNotReturn, .timeout:
                playFeedback(.miss)
            case .paused:
                break // The phase observer owns the single pause earcon.
            case .neutral, .cue, .returnToNeutral:
                break
            }
            guard let text = newFeedback.text else { return }
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        .onChange(of: roundEngine.activeCue?.id) { _, _ in
            guard roundEngine.cueIsVisuallyActive,
                  let cue = roundEngine.activeCue else { return }
            playFeedback(.cue, at: cue.center)
            UIAccessibility.post(
                notification: .announcement,
                argument: "\(cue.expectedPunch.title) cue"
            )
        }
        .onChange(of: roundEngine.feedback) { _, newFeedback in
            switch newFeedback {
            case .hit:
                playFeedback(.cleanHit, at: resolvedBoardAudioPosition)
            case .miss, .wrong:
                playFeedback(.miss, at: resolvedBoardAudioPosition)
            case .paused:
                playFeedback(.paused)
            case .neutral:
                break
            }
            if case .paused = newFeedback,
               case .failed = roundEngine.phase {
                return
            }
            guard let text = newFeedback.text else { return }
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        .onDisappear {
            roundEngine.leaveImmersiveSpace()
            auraPunch.leaveImmersiveSpace()
            defense.leaveImmersiveSpace()
            handTracking.stop()
            spatialFeedback.detachFromScene()
            auraPausedForSystemInterruption = false
            appModel.lastExperience = appModel.activeExperience
            appModel.activeExperience = nil
        }
    }

    private func requestAutomaticExit() {
        appModel.immersiveSpaceState = .inTransition
        openWindow(id: "main")
        Task {
            if trainingSettings.soundFeedbackEnabled {
                // Targets are already disabled in their completed state. This
                // short non-blocking tail lets the original completion earcon
                // finish before RealityKit tears down its emitter.
                try? await Task.sleep(for: .milliseconds(520))
            }
            await dismissImmersiveSpace()
        }
    }

    private var resolvedBoardAudioPosition: SIMD3<Float>? {
        roundEngine.lastResolvedBoardIndex.map {
            roundEngine.boardTargetPosition(at: $0)
        }
    }

    private func defenseAudioPosition(
        for movement: DefenseDrill
    ) -> SIMD3<Float>? {
        guard let neutral = defense.neutralPosition else { return nil }
        return DefenseSpatialBasis(
            rightDirection: defense.neutralRightDirection
        ).cuePosition(
            neutral: neutral,
            movement: movement,
            forwardDistance: 0.55,
            lateralMagnitude: 0.28
        )
    }

    private func playFeedback(
        _ sound: TrainingFeedbackSound,
        at position: SIMD3<Float>? = nil
    ) {
        guard scenePhase == .active else { return }
        spatialFeedback.play(
            sound,
            at: position,
            enabled: trainingSettings.soundFeedbackEnabled
        )
    }

    // MARK: - Aura Punch layer

    private func makeAuraGuide() -> ModelEntity {
        // A lightweight, original procedural ghost glove. It is intentionally
        // abstract: no unlicensed avatar asset and no implied elbow/torso pose.
        let mesh = MeshResource.generateSphere(radius: 0.040)
        let material = SimpleMaterial(
            color: UIColor.systemCyan.withAlphaComponent(0.78),
            isMetallic: true
        )
        let guide = ModelEntity(mesh: mesh, materials: [material])
        guide.name = auraGuideName
        guide.scale = SIMD3<Float>(1.08, 0.86, 1.30)

        let cuff = ModelEntity(
            mesh: .generateCylinder(height: 0.040, radius: 0.028),
            materials: [
                SimpleMaterial(
                    color: UIColor.systemPurple.withAlphaComponent(0.62),
                    isMetallic: false
                )
            ]
        )
        cuff.name = "shadowbox.aura.guide.cuff"
        cuff.position = SIMD3<Float>(0, 0, 0.052)
        cuff.orientation = simd_quatf(
            angle: .pi / 2,
            axis: SIMD3<Float>(1, 0, 0)
        )
        guide.addChild(cuff)
        guide.isEnabled = false
        guide.components.set(OpacityComponent(opacity: 0.74))
        return guide
    }

    private func makeAuraPathPoint(index: Int) -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: 0.009)
        let material = SimpleMaterial(
            color: UIColor.systemPurple.withAlphaComponent(0.68),
            isMetallic: false
        )
        let point = ModelEntity(mesh: mesh, materials: [material])
        point.name = auraPathName(index)
        point.isEnabled = false
        point.components.set(OpacityComponent(opacity: 0.48))
        return point
    }

    private func updateAuraGuide(in root: Entity) {
        let isAuraExperience = appModel.activeExperience == .auraPunch
        let guide = auraPunch.guide
        let shouldShow = isAuraExperience
            && guide != nil
            && auraPunch.shouldPresentGuide

        if let entity = root.findEntity(named: auraGuideName) as? ModelEntity {
            entity.isEnabled = shouldShow
            if let guide, shouldShow {
                entity.position = auraPunch.phase == .demonstrating
                    ? (auraPunch.currentGuidePosition ?? guide.guardPosition)
                    : guide.targetPosition
                let color: UIColor = guide.hand == .left ? .systemCyan : .systemOrange
                entity.model?.materials = [
                    SimpleMaterial(color: color.withAlphaComponent(0.78), isMetallic: true)
                ]
            }
        }

        let visiblePointCount = min(
            auraPathPointCount,
            max(2, auraPunch.activePathPointCount)
        )
        for index in 0..<auraPathPointCount {
            guard let point = root.findEntity(named: auraPathName(index)) as? ModelEntity else {
                continue
            }
            let isVisiblePoint = index < visiblePointCount
            point.isEnabled = shouldShow && isVisiblePoint
            guard let guide, shouldShow, isVisiblePoint else { continue }

            let isEndpoint = index == visiblePointCount - 1
            point.scale = SIMD3<Float>(repeating: isEndpoint ? 2 : 1)
            point.components.set(OpacityComponent(opacity: isEndpoint ? 0.9 : 0.48))
            let progress = Float(index) / Float(max(1, visiblePointCount - 1))
            point.position = guide.outboundPosition(at: progress)
        }
    }

    // MARK: - Non-contact physical-bag preview layer

    private func makeBagBody() -> ModelEntity {
        let mesh = MeshResource.generateCylinder(height: 1, radius: 0.5)
        let material = SimpleMaterial(
            color: .systemGray,
            isMetallic: false
        )
        let bag = ModelEntity(mesh: mesh, materials: [material])
        bag.name = bagBodyName
        bag.isEnabled = false
        bag.components.set(OpacityComponent(opacity: 0.26))
        return bag
    }

    private func makeBagPad(index: Int) -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: 0.065)
        let color: UIColor = index.isMultiple(of: 2) ? .systemYellow : .systemCyan
        let material = SimpleMaterial(color: color.withAlphaComponent(0.78), isMetallic: false)
        let pad = ModelEntity(mesh: mesh, materials: [material])
        pad.name = bagPadName(index)
        pad.scale = SIMD3<Float>(1, 1, 0.22)
        pad.isEnabled = false
        pad.components.set(OpacityComponent(opacity: 0.68))
        return pad
    }

    private func updateBagPreview(in root: Entity) {
        guard appModel.activeExperience == .bagPreview,
              let profile = profileStore.bagProfile,
              let body = root.findEntity(named: bagBodyName) as? ModelEntity else {
            root.findEntity(named: bagBodyName)?.isEnabled = false
            for index in 0..<maximumBagPadCount {
                root.findEntity(named: bagPadName(index))?.isEnabled = false
            }
            return
        }

        let height = Float(profile.heightMeters)
        let diameter = Float(profile.diameterMeters)
        if !body.isEnabled {
            if let devicePosition = handTracking.latestDevicePose?.position {
                body.position = devicePosition + SIMD3<Float>(0, -0.12, -1.0)
            } else {
                body.position = SIMD3<Float>(0, max(0.85, height * 0.55), -1.0)
            }
        }
        body.scale = SIMD3<Float>(diameter, height, diameter)
        body.isEnabled = true

        let offsets = bagPadOffsets(for: profile.targetLayout)
        for index in 0..<maximumBagPadCount {
            guard let pad = root.findEntity(named: bagPadName(index)) as? ModelEntity else {
                continue
            }
            guard index < offsets.count else {
                pad.isEnabled = false
                continue
            }

            let offset = offsets[index]
            pad.position = body.position + SIMD3<Float>(
                offset.x * diameter,
                offset.y * height,
                diameter * 0.52
            )
            let scale = min(1.25, max(0.65, diameter / 0.36))
            pad.scale = SIMD3<Float>(scale, scale, 0.22)
            pad.isEnabled = true
        }
    }

    private func bagPadOffsets(for layout: BagTargetLayout) -> [SIMD2<Float>] {
        switch layout {
        case .twoTarget:
            [SIMD2<Float>(-0.24, 0.12), SIMD2<Float>(0.24, 0.12)]
        case .fourTarget:
            [
                SIMD2<Float>(-0.24, 0.17), SIMD2<Float>(0.24, 0.17),
                SIMD2<Float>(-0.24, -0.13), SIMD2<Float>(0.24, -0.13),
            ]
        case .sixTarget:
            [
                SIMD2<Float>(-0.24, 0.24), SIMD2<Float>(0.24, 0.24),
                SIMD2<Float>(-0.24, 0.02), SIMD2<Float>(0.24, 0.02),
                SIMD2<Float>(-0.24, -0.20), SIMD2<Float>(0.24, -0.20),
            ]
        }
    }

    // MARK: - Head-movement defense layer

    private func makeDefenseCue() -> ModelEntity {
        let mesh = MeshResource.generateBox(width: 1, height: 1, depth: 0.045, cornerRadius: 0.025)
        let material = SimpleMaterial(
            color: UIColor.systemMint.withAlphaComponent(0.65),
            isMetallic: false
        )
        let cue = ModelEntity(mesh: mesh, materials: [material])
        cue.name = defenseCueName
        cue.isEnabled = false
        cue.components.set(OpacityComponent(opacity: 0.55))
        return cue
    }

    private func updateDefenseCue(in root: Entity) {
        guard let entity = root.findEntity(named: defenseCueName) as? ModelEntity else {
            return
        }
        guard appModel.activeExperience == .defense,
              let cue = defense.currentCue,
              let neutral = defense.neutralPosition else {
            entity.isEnabled = false
            return
        }

        let progress = Float(cue.visualProgress(at: presentationTimestamp))
        let basis = DefenseSpatialBasis(
            rightDirection: defense.neutralRightDirection
        )
        let approachDistance = 1.20 + (0.65 - 1.20) * progress
        entity.position = basis.cuePosition(
            neutral: neutral,
            movement: cue.expectedMovement,
            forwardDistance: approachDistance,
            lateralMagnitude: 0.10,
            duckVerticalOffset: -0.01
        )
        entity.scale = switch cue.expectedMovement {
        case .duck:
            SIMD3<Float>(0.56, 0.085, 1)
        case .slipLeft, .slipRight:
            SIMD3<Float>(0.13, 0.44, 1)
        case .mixed:
            SIMD3<Float>(0.40, 0.12, 1)
        }
        entity.components.set(
            OpacityComponent(opacity: max(0.08, 0.58 * (1 - progress)))
        )
        entity.isEnabled = true
    }

    private func auraPathName(_ index: Int) -> String {
        auraPathPrefix + String(index)
    }

    private func bagPadName(_ index: Int) -> String {
        bagPadPrefix + String(index)
    }

    private func makeBoardPad(index: Int) -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: roundEngine.configuration.targetRadius)
        let material = SimpleMaterial(color: .systemRed, isMetallic: false)
        let pad = ModelEntity(mesh: mesh, materials: [material])

        pad.name = boardPadName(index)
        pad.position = roundEngine.boardTargetPosition(at: index)
        pad.scale = SIMD3<Float>(1, 1, 0.35)
        pad.isEnabled = false
        pad.components.set(OpacityComponent(opacity: 0.32))
        return pad
    }

    private func makeBoardBackdrop() -> ModelEntity {
        let mesh = MeshResource.generateBox(
            width: 0.52,
            height: 0.46,
            depth: 0.025,
            cornerRadius: 0.035
        )
        let material = SimpleMaterial(
            color: UIColor.systemGray.withAlphaComponent(0.45),
            isMetallic: false
        )
        let backdrop = ModelEntity(mesh: mesh, materials: [material])
        backdrop.name = boardBackdropName
        backdrop.isEnabled = false
        backdrop.components.set(OpacityComponent(opacity: 0.22))
        return backdrop
    }

    private func makeSafetyControls() -> Entity {
        let controls = Entity()
        controls.name = "shadowbox.safety-controls"
        controls.position = SIMD3<Float>(0, 0.90, -0.60)
        controls.components.set(ViewAttachmentComponent(
            rootView: ImmersiveSafetyControls(
                appModel: appModel,
                handTracking: handTracking,
                roundEngine: roundEngine,
                profileStore: profileStore,
                auraPunch: auraPunch,
                defense: defense,
                trainingSettings: trainingSettings,
                feedbackPlayer: spatialFeedback
            )
        ))
        return controls
    }

    private func updateBoard(in root: Entity) {
        let boardIsVisible = appModel.activeExperience == .reactiveBoard
            && roundEngine.isCalibrated
        let positions = (0..<roundEngine.boardTargetCount).map {
            roundEngine.boardTargetPosition(at: $0)
        }

        if let backdrop = root.findEntity(named: boardBackdropName) as? ModelEntity {
            backdrop.isEnabled = boardIsVisible
            if boardIsVisible, !positions.isEmpty {
                backdrop.position = positions.reduce(.zero, +) / Float(positions.count)
                    + SIMD3<Float>(0, 0, -0.035)
            }
        }

        for index in 0..<roundEngine.boardTargetCount {
            guard let pad = root.findEntity(named: boardPadName(index)) as? ModelEntity else {
                continue
            }
            pad.isEnabled = boardIsVisible
            guard boardIsVisible else { continue }

            let state = roundEngine.visualState(forBoardTarget: index)
            let appearance: (UIColor, Float, Float) = switch state {
            case .inactive:
                (.systemIndigo, 0.28, 1.0)
            case .active:
                (.systemYellow, 1.0, 1.08)
            case .hit:
                (.systemGreen, 1.0, 1.13)
            case .miss:
                (.systemRed, 1.0, 1.08)
            case .paused:
                (.systemGray, 0.18, 1.0)
            }

            pad.position = positions[index]
            pad.scale = SIMD3<Float>(appearance.2, appearance.2, 0.35)
            pad.model?.materials = [
                SimpleMaterial(color: appearance.0, isMetallic: false)
            ]
            pad.components.set(OpacityComponent(opacity: appearance.1))
        }
    }

    private func updateDiagnosticMarkers(in root: Entity) {
        let showsHands = appModel.activeExperience != .bagPreview
            && appModel.activeExperience != .defense
        let activeNames = showsHands
            ? Set(handTracking.markers.map { markerName(for: $0) })
            : Set<String>()

        for child in root.children where child.name.hasPrefix(markerPrefix) {
            child.isEnabled = activeNames.contains(child.name)
        }

        guard showsHands else { return }

        for marker in handTracking.markers {
            let name = markerName(for: marker)
            let entity: ModelEntity

            if let existing = root.findEntity(named: name) as? ModelEntity {
                entity = existing
            } else {
                entity = makeMarker(for: marker)
                entity.name = name
                root.addChild(entity)
            }

            entity.position = marker.position
            entity.isEnabled = true
        }
    }

    private func updateFistCenters(in root: Entity) {
        let showsHands = appModel.activeExperience != .bagPreview
            && appModel.activeExperience != .defense

        for hand in HandSide.allCases {
            let name = fistName(for: hand)
            guard showsHands,
                  let pose = handTracking.latestSample?.pose(for: hand) else {
                root.findEntity(named: name)?.isEnabled = false
                continue
            }

            let entity: ModelEntity
            if let existing = root.findEntity(named: name) as? ModelEntity {
                entity = existing
            } else {
                entity = makeFistCenter(for: hand)
                entity.name = name
                root.addChild(entity)
            }

            entity.position = pose.fistCenter
            entity.isEnabled = true
        }
    }

    private func makeMarker(for marker: HandMarker) -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: 0.012)
        let color: UIColor = marker.side == .left ? .systemCyan : .systemOrange
        let material = SimpleMaterial(color: color, isMetallic: false)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private func makeFistCenter(for hand: HandSide) -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: roundEngine.configuration.fistRadius)
        let color: UIColor = hand == .left ? .systemBlue : .systemPurple
        let material = SimpleMaterial(color: color, isMetallic: true)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private func boardPadName(_ index: Int) -> String {
        boardPadPrefix + String(index)
    }

    private func markerName(for marker: HandMarker) -> String {
        markerPrefix + marker.id
    }

    private func fistName(for hand: HandSide) -> String {
        fistPrefix + hand.rawValue
    }
}

@MainActor
private struct ImmersiveSafetyControls: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    let appModel: AppModel
    let handTracking: HandTrackingService
    let roundEngine: RoundEngine
    let profileStore: TrainingProfileStore
    let auraPunch: AuraPunchEngine
    let defense: DefenseEngine
    let trainingSettings: TrainingSessionSettings
    let feedbackPlayer: SpatialFeedbackPlayer

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(appModel.activeExperienceTitle)
                    .font(.headline)
                Text(experienceStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(trackingStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let audioError = feedbackPlayer.preparationError {
                    Label(audioError, systemImage: "speaker.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if let cueText {
                    Text(cueText)
                        .font(.caption.bold())
                }
            }

            VStack(spacing: 8) {
                if appModel.activeExperience == .auraPunch,
                   auraPunch.phase == .completed,
                   roundEngine.canStartRound {
                    Button("Continue to Punch Board") {
                        guard roundEngine.canStartRound,
                              handTracking.state.hasBothHands else {
                            UIAccessibility.post(
                                notification: .announcement,
                                argument: "Both hands must be tracked before the Punch Board can start."
                            )
                            return
                        }
                        roundEngine.startRound(
                            difficulty: trainingSettings.difficulty
                        )
                        guard roundEngine.isRoundActive else {
                            UIAccessibility.post(
                                notification: .announcement,
                                argument: "The Punch Board did not start. Keep both hands at guard and try again."
                            )
                            return
                        }
                        appModel.activeExperience = .reactiveBoard
                        appModel.lastExperience = .reactiveBoard
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Punch Board transfer round starting."
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }

                if appModel.activeExperience == .auraPunch,
                   auraPunch.phase == .paused {
                    Button("Resume Aura") {
                        auraPunch.resume(at: ProcessInfo.processInfo.systemUptime)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!handTracking.state.hasBothHands)
                }

                if appModel.activeExperience == .defense,
                   case .paused = defense.phase {
                    Button("Resume at Neutral") {
                        defense.resume(at: ProcessInfo.processInfo.systemUptime)
                    }
                    .buttonStyle(.bordered)
                    .disabled(handTracking.latestDevicePose == nil)
                }

                Button {
                    trainingSettings.setSoundFeedbackEnabled(
                        !trainingSettings.soundFeedbackEnabled
                    )
                    if !trainingSettings.soundFeedbackEnabled {
                        feedbackPlayer.stop()
                    }
                } label: {
                    Label(
                        trainingSettings.soundFeedbackEnabled ? "Mute sound" : "Enable sound",
                        systemImage: trainingSettings.soundFeedbackEnabled
                            ? "speaker.slash"
                            : "speaker.wave.2"
                    )
                }
                .buttonStyle(.bordered)

                Button("Stop & Exit", role: .destructive) {
                    guard appModel.immersiveSpaceState != .inTransition else { return }
                    stopActiveExperience()
                    appModel.immersiveSpaceState = .inTransition
                    openWindow(id: "main")
                    Task {
                        await dismissImmersiveSpace()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.immersiveSpaceState == .inTransition)
            }
        }
        .padding(14)
        .glassBackgroundEffect()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Boxing Trainer safety controls")
    }

    private var experienceStatus: String {
        switch appModel.activeExperience {
        case .anthropometryCalibration, .reactiveBoard:
            roundEngine.phase.title
        case .auraPunch:
            switch auraPunch.phase {
            case .idle: "Calibrate, then start the guide"
            case .demonstrating: "Watch the out-and-back guide"
            case .following: "Follow the guide and return to guard"
            case .paused: "Aura Punch paused"
            case .completed: "Aura Punch complete"
            }
        case .bagPreview:
            profileStore.bagProfile.map { "Static preview: \($0.name)" }
                ?? "No bag profile"
        case .defense:
            switch defense.phase {
            case .idle: "Calibrate a neutral head position"
            case .calibratingNeutral: "Hold neutral"
            case .ready: "Defense set ready"
            case .countdown(let seconds): "Starting in \(seconds)"
            case .active: "Head-movement cue active"
            case .paused: "Defense paused"
            case .completed: "Defense set complete"
            }
        case nil:
            "Mixed passthrough"
        }
    }

    private var trackingStatus: String {
        if appModel.activeExperience == .defense {
            return handTracking.latestDevicePose == nil
                ? "Waiting for head-position proxy"
                : "Head-position proxy available"
        }
        if appModel.activeExperience == .bagPreview {
            return "Preview only — do not make contact"
        }
        return handTracking.state.title
    }

    private var cueText: String? {
        switch appModel.activeExperience {
        case .reactiveBoard:
            if roundEngine.cueIsVisuallyActive,
               let cue = roundEngine.activeCue {
                return "Cue: \(cue.expectedPunch.title)"
            }
            return roundEngine.feedback.text
        case .auraPunch:
            return auraPunch.feedback ?? auraPunch.instruction
        case .bagPreview:
            return "Stationary visual alignment only"
        case .defense:
            return defense.feedback.text ?? defense.instruction
        case .anthropometryCalibration:
            return roundEngine.instruction
        case nil:
            return nil
        }
    }

    private func stopActiveExperience() {
        switch appModel.activeExperience {
        case .auraPunch:
            auraPunch.stop()
        case .defense:
            defense.stop()
        case .anthropometryCalibration, .reactiveBoard, .bagPreview, nil:
            if roundEngine.phase != .finished {
                roundEngine.stop()
            }
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
        .environment(HandTrackingService())
        .environment(RoundEngine())
        .environment(TrainingProfileStore())
        .environment(AuraPunchEngine())
        .environment(DefenseEngine())
        .environment(TrainingSessionSettings())
}

#else

struct ImmersiveView: View {
    var body: some View {
        Text("Mixed immersive space is available only on visionOS.")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding()
            .multilineTextAlignment(.center)
    }
}

#endif

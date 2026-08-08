//
//  SpatialFeedbackPlayer.swift
//  Test
//
//  Small, scene-owned RealityKit audio boundary. The training engines emit
//  state; this renderer owns playback and never changes scoring.
//

import Foundation
import Observation
import RealityKit
import simd

enum TrainingFeedbackSound: CaseIterable, Hashable, Sendable {
    case cue
    case cleanHit
    case miss
    case paused
    case setComplete

    fileprivate var filename: String {
        switch self {
        case .cue: "coach-cue.wav"
        case .cleanHit: "clean-hit.wav"
        case .miss: "miss.wav"
        case .paused: "paused.wav"
        case .setComplete: "set-complete.wav"
        }
    }
}

@MainActor
@Observable
final class SpatialFeedbackPlayer {
    @ObservationIgnored private let cueEmitter = Entity()
    @ObservationIgnored private let resultEmitter = Entity()
    @ObservationIgnored private var resources: [TrainingFeedbackSound: AudioFileResource] = [:]
    @ObservationIgnored private var cueController: AudioPlaybackController?
    @ObservationIgnored private var resultController: AudioPlaybackController?

    private(set) var preparationError: String?

    func prepare(in root: Entity) {
        for (emitter, name) in [
            (cueEmitter, "shadowbox.feedback.cue-emitter"),
            (resultEmitter, "shadowbox.feedback.result-emitter"),
        ] {
            emitter.name = name
            emitter.position = SIMD3<Float>(0, 1.25, -0.65)
            emitter.components.set(SpatialAudioComponent())
            if emitter.parent !== root {
                emitter.removeFromParent()
                root.addChild(emitter)
            }
        }

        guard resources.isEmpty else { return }

        do {
            resources = try Dictionary(
                uniqueKeysWithValues: TrainingFeedbackSound.allCases.map { sound in
                    let resource = try AudioFileResource.load(
                        named: sound.filename,
                        in: .main,
                        configuration: .init(loadingStrategy: .preload)
                    )
                    return (sound, resource)
                }
            )
            preparationError = nil
        } catch {
            resources = [:]
            preparationError = "Spatial feedback audio could not be loaded: \(error.localizedDescription)"
        }
    }

    func play(
        _ sound: TrainingFeedbackSound,
        at position: SIMD3<Float>? = nil,
        enabled: Bool
    ) {
        guard enabled, let resource = resources[sound] else { return }
        let emitter = sound == .cue ? cueEmitter : resultEmitter
        if let position {
            emitter.position = position
        }
        if sound == .cue {
            cueController?.stop()
            cueController = emitter.playAudio(resource)
        } else {
            resultController?.stop()
            resultController = emitter.playAudio(resource)
        }
    }

    func stop() {
        cueController?.stop()
        resultController?.stop()
        cueController = nil
        resultController = nil
    }

    func detachFromScene() {
        stop()
        cueEmitter.removeFromParent()
        resultEmitter.removeFromParent()
    }
}

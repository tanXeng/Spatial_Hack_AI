import Foundation
import os

/// Generates and plays live coach speech via OpenAI TTS (milestones + PTT answers).
@MainActor
final class CoachLiveVoiceService {
    private static let logger = Logger(subsystem: "com.josephkwokpersonalteam.BoxingCoach", category: "CoachLiveVoice")

    private let audioPlayer = CoachAudioPlayer()
    private var ttsClient = OpenAITTSClient()
    private let cache = CoachTTSCache()
    private var speakTasks: [Task<Void, Never>] = []

    func prepare() {
        audioPlayer.prepare()
    }

    func prefetchMilestones(_ milestones: [CoachClipID]) async {
        guard CoachSecrets.hasOpenAIKey else { return }
        for milestone in milestones {
            guard let text = CoachMilestoneScripts.text(for: milestone) else { continue }
            do {
                _ = try await audioData(for: text)
            } catch {
                Self.logger.error("Prefetch failed for \(milestone.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func speakMilestone(_ milestone: CoachClipID) {
        guard let text = CoachMilestoneScripts.text(for: milestone) else { return }
        let task = Task { [weak self] in
            await self?.speakText(text, waitForCompletion: false)
        }
        speakTasks.append(task)
        trimFinishedTasks()
    }

    @discardableResult
    func speakText(_ text: String) async -> String? {
        await speakText(text, waitForCompletion: true)
    }

    func stop() {
        speakTasks.forEach { $0.cancel() }
        speakTasks.removeAll()
        audioPlayer.stop()
    }

    func shutdown() {
        stop()
        audioPlayer.restorePlaybackMode()
    }

    private func speakText(_ text: String, waitForCompletion: Bool) async -> String? {
        guard CoachSecrets.hasOpenAIKey else {
            Self.logger.error("Skipping speech — no OpenAI API key")
            return "OpenAI API key is missing. Add it to Secrets.xcconfig and rebuild."
        }

        do {
            let data = try await audioData(for: text)
            if waitForCompletion {
                await audioPlayer.playAndWait(data: data)
            } else {
                audioPlayer.play(data: data)
            }
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.logger.error("speakText failed: \(message, privacy: .public)")
            return message
        }
    }

    private func audioData(for text: String) async throws -> Data {
        let voice = OpenAITTSClient.defaultVoice
        if let cached = cache.cachedAudio(for: text, voice: voice) {
            return cached
        }
        let data = try await ttsClient.synthesize(text: text, voice: voice)
        cache.store(data, for: text, voice: voice)
        return data
    }

    private func trimFinishedTasks() {
        speakTasks.removeAll { $0.isCancelled }
        if speakTasks.count > 4 {
            speakTasks.removeFirst(speakTasks.count - 4)
        }
    }
}

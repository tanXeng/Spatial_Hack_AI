import CryptoKit
import Foundation

/// Disk cache for synthesized TTS audio keyed by voice + script text.
nonisolated struct CoachTTSCache {
    private let directory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = base.appendingPathComponent("CoachTTS", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cachedAudio(for text: String, voice: String) -> Data? {
        let url = fileURL(for: text, voice: voice)
        return try? Data(contentsOf: url)
    }

    func store(_ data: Data, for text: String, voice: String) {
        let url = fileURL(for: text, voice: voice)
        try? data.write(to: url, options: .atomic)
    }

    func cacheKey(for text: String, voice: String) -> String {
        let digest = SHA256.hash(data: Data("\(voice)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for text: String, voice: String) -> URL {
        directory.appendingPathComponent(cacheKey(for: text, voice: voice)).appendingPathExtension("mp3")
    }
}

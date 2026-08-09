import CryptoKit
import Foundation

nonisolated struct EventRecoveryPayload: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let event: EventSnapshot
    let participants: [ParticipantSnapshot]
    let runs: [TrainingRunSnapshot]
    let awards: [AwardSnapshot]
}

nonisolated struct RecoveryEnvelope: Codable, Sendable, Equatable {
    let payload: Data
    let checksum: String
}

actor RecoverySnapshotStore {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func live() throws -> RecoverySnapshotStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return RecoverySnapshotStore(
            fileURL: support
                .appending(path: "BoxingCoach", directoryHint: .isDirectory)
                .appending(path: "Recovery", directoryHint: .isDirectory)
                .appending(path: "latest.json")
        )
    }

    func write(_ payload: EventRecoveryPayload) async throws {
        try await RecoveryFileIO.write(payload, to: fileURL)
    }

    func load() async throws -> EventRecoveryPayload? {
        try await RecoveryFileIO.load(from: fileURL)
    }
}

nonisolated enum RecoveryFileIO {
    @concurrent
    static func write(_ value: EventRecoveryPayload, to fileURL: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let envelope = RecoveryEnvelope(payload: payload, checksum: checksum)
        let encoded = try encoder.encode(envelope)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    @concurrent
    static func load(from fileURL: URL) async throws -> EventRecoveryPayload? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(RecoveryEnvelope.self, from: data)
        let actual = SHA256.hash(data: envelope.payload).map { String(format: "%02x", $0) }.joined()
        guard actual == envelope.checksum else { throw TrainingRepositoryError.corruptedSnapshot }
        return try decoder.decode(EventRecoveryPayload.self, from: envelope.payload)
    }
}


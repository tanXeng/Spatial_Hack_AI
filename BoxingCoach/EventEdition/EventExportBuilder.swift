import Foundation

nonisolated enum EventExportBuilder {
    static func publicCSV(
        event: EventSnapshot,
        entries: [LeaderboardEntry],
        runs: [TrainingRunSnapshot]
    ) -> String {
        let runByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        let header = "event,rank,alias,competitor_number,total_points,contact_points,accuracy_points,guard_points,official_attempts,completion_time"
        let rows = entries.map { entry in
            [
                event.title,
                String(entry.rank),
                entry.alias,
                String(entry.competitorNumber),
                String(entry.totalPoints),
                String(entry.contactPoints),
                String(entry.accuracyPoints),
                String(entry.guardPoints),
                String(entry.officialAttemptsCompleted),
                runByID[entry.runID]?.endedAt.ISO8601Format() ?? ""
            ].map(csvField).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    static func fullEventJSON(
        event: EventSnapshot,
        participants: [ParticipantSnapshot],
        runs: [TrainingRunSnapshot],
        awards: [AwardSnapshot]
    ) throws -> Data {
        let payload = EventRecoveryPayload(
            schemaVersion: 1,
            generatedAt: .now,
            event: event,
            participants: participants,
            runs: runs,
            awards: awards
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    private static func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}


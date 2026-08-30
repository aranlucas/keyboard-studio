import Foundation

public struct CodexActivity: Codable, Equatable, Identifiable, Sendable {
    public var id: String { threadID }
    public let threadID: String
    public let summary: String
    public let compactSummary: String?
    public let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case summary
        case compactSummary = "compact_summary"
        case updatedAt = "updated_at"
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(updatedAt) / 1000)
    }
}

public struct CodexRuntimeStatus: Codable, Equatable, Sendable {
    public let activeTaskCount: Int
    public let lastCompletedAt: Int64?
    public let lastInterruptedAt: Int64?

    public init(
        activeTaskCount: Int = 0,
        lastCompletedAt: Int64? = nil,
        lastInterruptedAt: Int64? = nil
    ) {
        self.activeTaskCount = activeTaskCount
        self.lastCompletedAt = lastCompletedAt
        self.lastInterruptedAt = lastInterruptedAt
    }

    public var lastAttentionAt: Int64? {
        [lastCompletedAt, lastInterruptedAt].compactMap { $0 }.max()
    }
}

public enum CodexActivityError: Error, LocalizedError, Sendable {
    case databaseMissing(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .databaseMissing(path): "Codex activity database was not found at \(path)."
        case let .queryFailed(message): "Could not read Codex activity: \(message)"
        }
    }
}

public actor CodexActivityService {
    public let databaseURL: URL
    public let sessionsURL: URL
    private var lifecycleCache: [String: LifecycleCacheEntry] = [:]

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        databaseURL = homeDirectory
            .appending(path: ".codex/sqlite/codex-thread-summaries-dev.db")
        sessionsURL = homeDirectory.appending(path: ".codex/sessions")
    }

    public func recent(limit: Int = 30) throws -> [CodexActivity] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CodexActivityError.databaseMissing(databaseURL.path)
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        let safeLimit = max(1, min(limit, 100))
        process.arguments = [
            "-readonly",
            "-json",
            databaseURL.path,
            "SELECT thread_id, summary, compact_summary, updated_at FROM thread_turn_summaries ORDER BY updated_at DESC LIMIT \(safeLimit);",
        ]

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CodexActivityError.queryFailed(error.localizedDescription)
        }

        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw CodexActivityError.queryFailed(String(decoding: errorData, as: UTF8.self))
        }

        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        do {
            return try JSONDecoder().decode([CodexActivity].self, from: data)
        } catch {
            throw CodexActivityError.queryFailed("Unexpected sqlite3 JSON: \(error.localizedDescription)")
        }
    }

    public func runtimeStatus(
        now: Date = Date(),
        recentWindow: TimeInterval = 24 * 60 * 60
    ) -> CodexRuntimeStatus {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return CodexRuntimeStatus()
        }

        let cutoff = now.addingTimeInterval(-recentWindow)
        var activeTaskCount = 0
        var lastCompletedAt: Int64?
        var lastInterruptedAt: Int64?

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ),
                values.isRegularFile == true,
                let modifiedAt = values.contentModificationDate,
                modifiedAt >= cutoff,
                let event = lastLifecycleEvent(in: fileURL, modifiedAt: modifiedAt)
            else {
                continue
            }

            switch event.kind {
            case .started:
                activeTaskCount += 1
            case .completed:
                lastCompletedAt = max(lastCompletedAt ?? 0, event.timestamp)
            case .interrupted:
                lastInterruptedAt = max(lastInterruptedAt ?? 0, event.timestamp)
            }
        }

        return CodexRuntimeStatus(
            activeTaskCount: activeTaskCount,
            lastCompletedAt: lastCompletedAt,
            lastInterruptedAt: lastInterruptedAt
        )
    }

    public static func decodeLastLifecycleEvent(from data: Data) -> CodexLifecycleEvent? {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard line.range(of: Data("\"task_started\"".utf8)) != nil
                || line.range(of: Data("\"task_complete\"".utf8)) != nil
                || line.range(of: Data("\"turn_aborted\"".utf8)) != nil
            else {
                continue
            }
            guard let record = try? JSONDecoder().decode(RolloutLifecycleRecord.self, from: Data(line)),
                  record.type == "event_msg",
                  let payloadType = record.payload.type
            else {
                continue
            }

            let kind: CodexLifecycleEvent.Kind
            switch payloadType {
            case "task_started": kind = .started
            case "task_complete": kind = .completed
            case "turn_aborted": kind = .interrupted
            default: continue
            }

            let timestamp = record.payload.completedAt
                ?? record.payload.startedAt
                ?? record.timestamp.flatMap(Self.parseISO8601Seconds)
            guard let timestamp else { continue }
            return CodexLifecycleEvent(kind: kind, timestamp: timestamp)
        }
        return nil
    }

    private func lastLifecycleEvent(in fileURL: URL, modifiedAt: Date) -> CodexLifecycleEvent? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let endOffset = (try? handle.seekToEnd()) ?? 0
        let cacheKey = fileURL.path

        if let cached = lifecycleCache[cacheKey], cached.fileSize == endOffset {
            return cached.event
        }

        if let cached = lifecycleCache[cacheKey], endOffset > cached.fileSize {
            do {
                try handle.seek(toOffset: cached.fileSize)
                let appendedData = try handle.readToEnd() ?? Data()
                let event = Self.decodeLastLifecycleEvent(from: appendedData) ?? cached.event
                lifecycleCache[cacheKey] = LifecycleCacheEntry(
                    modifiedAt: modifiedAt,
                    fileSize: endOffset,
                    event: event
                )
                return event
            } catch {
                // Fall through to a complete backward scan.
            }
        }

        let event = Self.scanBackwardForLifecycleEvent(handle: handle, endOffset: endOffset)
        lifecycleCache[cacheKey] = LifecycleCacheEntry(
            modifiedAt: modifiedAt,
            fileSize: endOffset,
            event: event
        )
        return event
    }

    private static func scanBackwardForLifecycleEvent(
        handle: FileHandle,
        endOffset: UInt64
    ) -> CodexLifecycleEvent? {
        let chunkSize: UInt64 = 64 * 1024
        var offset = endOffset
        var carriedLineSuffix = Data()

        while offset > 0 {
            let startOffset = offset > chunkSize ? offset - chunkSize : 0
            let length = Int(offset - startOffset)
            let chunk: Data
            do {
                try handle.seek(toOffset: startOffset)
                chunk = try handle.read(upToCount: length) ?? Data()
            } catch {
                return nil
            }

            var combined = chunk
            combined.append(carriedLineSuffix)

            if startOffset == 0 {
                return decodeLastLifecycleEvent(from: combined)
            }

            if let firstNewline = combined.firstIndex(of: 0x0A) {
                let completeLines = combined.suffix(from: combined.index(after: firstNewline))
                if let event = decodeLastLifecycleEvent(from: Data(completeLines)) {
                    return event
                }
                carriedLineSuffix = Data(combined[..<firstNewline])
            } else {
                carriedLineSuffix = combined
            }
            offset = startOffset
        }

        return nil
    }

    private static func parseISO8601Seconds(_ value: String) -> Int64? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractionalFormatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return nil }
        return Int64(date.timeIntervalSince1970)
    }
}

private struct LifecycleCacheEntry: Sendable {
    let modifiedAt: Date
    let fileSize: UInt64
    let event: CodexLifecycleEvent?
}

public struct CodexLifecycleEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case started
        case completed
        case interrupted
    }

    public let kind: Kind
    public let timestamp: Int64

    public init(kind: Kind, timestamp: Int64) {
        self.kind = kind
        self.timestamp = timestamp
    }
}

private struct RolloutLifecycleRecord: Decodable {
    let timestamp: String?
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String?
        let startedAt: Int64?
        let completedAt: Int64?

        enum CodingKeys: String, CodingKey {
            case type
            case startedAt = "started_at"
            case completedAt = "completed_at"
        }
    }
}

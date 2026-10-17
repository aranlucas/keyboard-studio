import Foundation
import Testing
@testable import KeyboardCore

struct CodexActivityServiceTests {
    @Test
    func sameSizeRolloutReplacementInvalidatesLifecycleCache() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let rollout = sessions.appendingPathComponent("synthetic.jsonl")
        let started = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"started_at\":1000}}"
        let completed = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"completed_at\":1001}}"
        let service = CodexActivityService(homeDirectory: home)
        let now = Date(timeIntervalSince1970: 2000)

        try Data(started.padding(toLength: 256, withPad: " ", startingAt: 0).utf8).write(to: rollout)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1998)], ofItemAtPath: rollout.path
        )
        let before = await service.runtimeStatus(now: now)
        #expect(before.activeTaskCount == 1)
        #expect(before.lastCompletedAt == nil)

        try Data(completed.padding(toLength: 256, withPad: " ", startingAt: 0).utf8).write(to: rollout)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1999)], ofItemAtPath: rollout.path
        )
        let after = await service.runtimeStatus(now: now)
        #expect(after.activeTaskCount == 0)
        #expect(after.lastCompletedAt == 1001)
    }
}

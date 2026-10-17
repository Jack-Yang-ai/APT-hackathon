import XCTest
import GRDB
@testable import GrowthApp

/// 手动私有快照重放。仅读取测试容器 Documents/watch-recovery-fixture，
/// 不连接手机、不调用模型；日常 CI 没有私人 fixture 时跳过。
final class WatchRecoverySnapshotTests: XCTestCase {
    private func stableRows(_ name: String, in db: Database) throws -> [Row] {
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(name)\")").count
        let order = (1...max(columns, 1)).map(String.init).joined(separator: ",")
        return try Row.fetchAll(db, sql: "SELECT * FROM \"\(name)\" ORDER BY \(order)")
    }

    func testPrivateSnapshotRestoresEveryManifestBlockWithoutChangingExistingContent() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fixture = documents.appendingPathComponent("watch-recovery-fixture")
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("backlog.json").path) else {
            throw XCTSkip("No private Watch recovery snapshot installed")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("watch-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for name in ["growth.sqlite", "recordings", "watch_inbox"] {
            try FileManager.default.copyItem(at: fixture.appendingPathComponent(name), to: work.appendingPathComponent(name))
        }
        let db = try DatabaseQueue(path: work.appendingPathComponent("growth.sqlite").path)
        let untouched = try db.read { d -> [String: [Row]] in
            let excluded: Set<String> = ["sessions", "tasks", "upload_jobs", "grdb_migrations", "processing_events", "sqlite_sequence"]
            let tables = try String.fetchAll(d, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            return try Dictionary(uniqueKeysWithValues: tables.filter { !excluded.contains($0) }.map { name in
                (name, try stableRows(name, in: d))
            })
        }
        let originalSessionIDs = try db.read { try Int64.fetchAll($0, sql: "SELECT id FROM sessions") }
        let sessionProjection = "id,started_at,day,source,active_transcript_id,grade,grade_source,title,removed_at,cloud_purged_at,voiceprint_gated_out"
        let originalSessions = try db.read { try Row.fetchAll($0, sql: "SELECT \(sessionProjection) FROM sessions ORDER BY id") }
        try AppDatabase.makeMigrator().migrate(db)
        let report = try WatchMirror.drain(inbox: work.appendingPathComponent("watch_inbox"), root: work.appendingPathComponent("recordings"), in: db)
        XCTAssertTrue(report.applied > 0, "私有快照必须实际重放，不得以跳过冒充恢复")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("backlog.json"))) as? [[String: Any]])
        XCTAssertEqual(manifest.count, 36)
        let progress = try JSONDecoder().decode(WatchMirror.Progress.self, from: Data(contentsOf: work.appendingPathComponent("watch_inbox/progress.json")))
        var verified = 0
        for item in manifest {
            let path = try XCTUnwrap(item["path"] as? String)
            let key = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let msg = try WatchLink.message(from: Data(contentsOf: work.appendingPathComponent("watch_inbox/\(key).msg.json")))
            let block = try XCTUnwrap(msg.entry.block)
            let mapped = try XCTUnwrap(progress.blockMap["\(msg.installID)|\(msg.day)|\(block.seq)"])
            let audio = RecordingPaths.audioDir(day: msg.day, source: SessionSource.watch, root: work.appendingPathComponent("recordings"))
                .appendingPathComponent(String(format: "block-%04d.m4a", mapped))
            XCTAssertTrue(try WatchMirror.digest(audio) == item["sha256"] as? String, "原积压音频摘要必须保持一致")
            verified += 1
        }
        let second = try WatchMirror.drain(inbox: work.appendingPathComponent("watch_inbox"), root: work.appendingPathComponent("recordings"), in: db)
        XCTAssertEqual(second.applied, 0)
        try db.read { d in
            for (name, rows) in untouched {
                XCTAssertTrue(try stableRows(name, in: d) == rows, "既有内容表变化：\(name)")
            }
            let marks = originalSessionIDs.map { _ in "?" }.joined(separator: ",")
            let after = try Row.fetchAll(d, sql: "SELECT \(sessionProjection) FROM sessions WHERE id IN (\(marks)) ORDER BY id", arguments: StatementArguments(originalSessionIDs))
            XCTAssertTrue(after == originalSessions, "旧场身份、用户字段与正式转写指针不能改变")
            XCTAssertEqual(try String.fetchOne(d, sql: "PRAGMA quick_check"), "ok")
            XCTAssertTrue(try Row.fetchAll(d, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        let receipt: [String: Any] = ["verified_original_audio": verified, "applied_messages": report.applied,
            "replay_applied": second.applied, "preserved_tables": untouched.count, "original_sessions": originalSessionIDs.count,
            "notices": report.notices]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: documents.appendingPathComponent("watch-recovery-offline-receipt.json"))
    }
}

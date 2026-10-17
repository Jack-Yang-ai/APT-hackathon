import XCTest
import GRDB
@testable import GrowthApp

/// 给 Python 断言脚本产一个**建好 schema 的空库**。
///
/// 判 8 定了:地基是 Swift 真身,验收脚本是 Python,两边靠同一个 SQLite 文件对接。
/// 那 Python 从哪拿到一个带 schema 的库?**不能在 Python 里重抄一遍 DDL**——
/// 那就是两份 schema,迟早分叉,而且分叉的时候断言脚本还会报绿。
///
/// 所以由这里导出:每次跑 iOS 测试都重新生成,永远与 migration 同步。
/// 文件进 .gitignore,不进版本库。
final class SchemaFixtureTests: XCTestCase {

    /// 相对仓库根的固定路径。`#filePath` 是 ios/GrowthAppTests/…,往上两级就是仓库根。
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GrowthAppTests
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("eval/checks/fixtures/empty.sqlite")
    }

    func testEmitEmptySchemaFixture() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: fixtureURL.path + suffix)
        }

        let queue = try DatabaseQueue(path: fixtureURL.path)
        try AppDatabase.makeMigrator().migrate(queue)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }

        // 落对没落对:确认四类表都在,而不是只确认文件生成了
        try queue.read { db in
            for table in ["transcript_lines", "line_speakers", "judgments",
                          "judgment_current", "id_remaps", "summary_stances", "tasks",
                          "input_memory_sources", "ask_turn_input_sources", "input_memory_sync", "personal_actions", "ask_drafts"] {
                XCTAssertTrue(try db.tableExists(table), "fixture 里缺表 \(table)")
            }
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT cursor FROM input_memory_sync WHERE singleton = 1"), 0)
            XCTAssertTrue(try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier = 'v50_input_memory_sources')") ?? false,
                          "fixture 必须由当前分支执行 v50，不可借用旧 schema")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_lines"), 0,
                           "这是空库,不该有数据")
            XCTAssertTrue(try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier = 'v52_source_revision_snapshots')") ?? false,
                          "fixture 必须由本分支生成最新的来源修订快照 schema")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path))
    }
}

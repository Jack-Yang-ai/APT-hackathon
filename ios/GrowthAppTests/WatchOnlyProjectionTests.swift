import XCTest
import GRDB
@testable import GrowthApp

@MainActor
final class WatchOnlyProjectionTests: XCTestCase {
    private var dir: URL!
    private var db: DatabaseQueue!
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testPhoneNeverSealsAnUnclosedWatchLedger() throws {
        let ledger = dir.appendingPathComponent(AudioWipe.ledgerName)
        try BlockLedger.append(LedgerEntry(at: t0, mark: .sessionStarted, source: SessionSource.watch), to: ledger)
        let before = try Data(contentsOf: ledger)
        let vm = RecordingViewModel(sessionDir: dir, database: db)
        vm.checkRelaunchGap(now: t0.addingTimeInterval(600))
        XCTAssertEqual(try Data(contentsOf: ledger), before)
        XCTAssertNil(vm.relaunchNotice)
        XCTAssertTrue(vm.watchSessionOpen)
        XCTAssertEqual(try db.read { try String.fetchOne($0, sql: "SELECT status FROM sessions") }, SessionBridge.Status.open)
    }

    func testOldPhoneRecordingStillRecoversAndAppearsInHistory() throws {
        let ledger = dir.appendingPathComponent(AudioWipe.ledgerName)
        try BlockLedger.append(LedgerEntry(at: t0, mark: .sessionStarted), to: ledger)
        try BlockLedger.append(LedgerEntry(at: t0.addingTimeInterval(60), mark: .interrupted), to: ledger)
        let vm = RecordingViewModel(sessionDir: dir, database: db)
        vm.checkRelaunchGap(now: t0.addingTimeInterval(600))
        XCTAssertEqual(try BlockLedger.read(from: ledger).entries.last?.kind, SessionMark.sessionEnded.rawValue)
        XCTAssertTrue(vm.relaunchNotice?.contains("旧版手机录音") == true)
        XCTAssertTrue(vm.relaunchNotice?.contains("手表") == true)
        XCTAssertEqual(try HomeProjection.cards(day: dir.lastPathComponent, in: db).count, 1)
    }

    func testPhoneRefreshDoesNotEnqueueRemovedSessions() throws {
        try db.write { d in
            try d.execute(sql: "INSERT INTO sessions(started_at,ended_at,day,source,status,removed_at) VALUES('2026-10-12T10:00:00Z','2026-10-12T10:01:00Z',?,'watch','closed','removed')", arguments: [dir.lastPathComponent])
        }
        let vm = RecordingViewModel(sessionDir: dir, database: db)
        vm.refreshToday()
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tasks") }, 0)
    }

    func testUnclosedWatchStatusDoesNotClaimRealTimeListening() {
        XCTAssertEqual(WatchRecordingStatus(sessionOpen: true).label, "手表未收尾")
        XCTAssertEqual(WatchRecordingStatus(sessionOpen: false).label, "手表录音")
    }

    func testLegacyPhoneEnqueueFailureIsVisibleAndRefreshRetries() throws {
        try assertEnqueueFailureIsVisibleAndRefreshRetries(source: SessionSource.recording)
    }

    func testImportedEnqueueFailureIsVisibleAndRefreshRetries() throws {
        try assertEnqueueFailureIsVisibleAndRefreshRetries(source: SessionSource.imported)
    }

    private func assertEnqueueFailureIsVisibleAndRefreshRetries(source: String) throws {
        try db.write { d in
            try d.execute(sql: "INSERT INTO sessions(started_at,ended_at,day,source,status) VALUES('2026-10-12T10:00:00Z','2026-10-12T10:01:00Z',?,?,'closed')", arguments: [dir.lastPathComponent, source])
            try d.execute(sql: """
                CREATE TRIGGER reject_enqueue BEFORE INSERT ON tasks
                BEGIN SELECT RAISE(ABORT, 'enqueue failpoint'); END;
                """)
        }
        let vm = RecordingViewModel(sessionDir: dir, database: db)
        XCTAssertNotNil(vm.databaseFailure, "队列写失败必须可见,不能被投影成功清除")
        XCTAssertTrue(vm.databaseFailure?.contains("enqueue failpoint") == true)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tasks") }, 0)
        vm.refreshToday()
        XCTAssertNotNil(vm.databaseFailure)

        try db.write { try $0.execute(sql: "DROP TRIGGER reject_enqueue") }
        vm.refreshToday()
        XCTAssertNil(vm.databaseFailure)
        vm.refreshToday()
        XCTAssertNil(vm.databaseFailure)
        XCTAssertEqual(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tasks WHERE kind = ?", arguments: [ProcessingOrchestrator.Kind.upload]) }, 1,
                       "刷新必须补入队,重复刷新不能创建重复任务")
    }
}

import XCTest
import GRDB
@testable import GrowthApp

/// 手机收件落盘的规则(W1 spec 决定 2,批 A)。
///
/// 每一种出错的样子都是「这一块没了,而到达日志说收到了」—— 不会有任何东西报错。
/// 所以逐个构造:重复到达、同号不同内容、两次安装同号、上一次落了一半。
final class WatchInboxTests: XCTestCase {

    private var dir: URL!
    private var src: URL!
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z")!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
        dir = base.appendingPathComponent("watch_inbox")
        src = base.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    /// 系统交来的临时文件(每次到达都是一份新的)。
    private func incoming(_ bytes: String) throws -> URL {
        let u = src.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(bytes.utf8).write(to: u)
        return u
    }

    private func msg(install: String = "A", seq: Int, blockSeq: Int = 0) -> WatchMessage {
        WatchMessage(v: WatchLink.version, installID: install, msgSeq: seq, day: "2026-10-12",
                     entry: LedgerEntry(block: BlockRecord(
                        seq: blockSeq, startedAt: t0, endedAt: t0.addingTimeInterval(300),
                        hardCut: false, fileName: String(format: "block-%04d.m4a", blockSeq))),
                     sentAt: t0, watchBattery: 0.7)
    }

    private func audio(_ key: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("\(key).m4a"), encoding: .utf8)
    }

    func testFirstArrivalLands() throws {
        let m = msg(seq: 0)
        XCTAssertEqual(try WatchInbox.land(try incoming("a"), msg: m, into: dir), .landed)
        XCTAssertEqual(try audio(m.key), "a")
        XCTAssertEqual(try WatchLink.message(from: Data(contentsOf:
            dir.appendingPathComponent("\(m.key).msg.json"))), m)
    }

    func testSameMessageTwiceIsDuplicate() throws {
        let m = msg(seq: 0)
        _ = try WatchInbox.land(try incoming("a"), msg: m, into: dir)
        XCTAssertEqual(try WatchInbox.land(try incoming("a"), msg: m, into: dir), .duplicate)
    }

    /// 同一安装号同一序号却是另一块 —— 不该发生,但发生了也不许当重复丢掉。
    func testSameKeyDifferentContentKeepsBoth() throws {
        let first = msg(seq: 0, blockSeq: 0)
        let second = msg(seq: 0, blockSeq: 7)
        _ = try WatchInbox.land(try incoming("first"), msg: first, into: dir)
        XCTAssertEqual(try WatchInbox.land(try incoming("second"), msg: second, into: dir), .conflict)
        XCTAssertEqual(try audio(first.key), "first", "先到的那份不许被顶掉")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".m4a") }.count, 2, "冲突的那份也要留着")
    }

    /// 手表重装后序号从 0 重来:新安装号的 0 号必须照常落地,不能被旧安装号的 0 号挡掉。
    func testReinstallSameSeqDoesNotCollide() throws {
        _ = try WatchInbox.land(try incoming("old"), msg: msg(install: "A", seq: 0), into: dir)
        XCTAssertEqual(try WatchInbox.land(try incoming("new"), msg: msg(install: "B", seq: 0), into: dir),
                       .landed)
        XCTAssertEqual(try audio(msg(install: "B", seq: 0).key), "new")
        XCTAssertEqual(try audio(msg(install: "A", seq: 0).key), "old")
    }

    /// 上一次挪完音频、写消息文件之前被杀 ⇒ 只有音频没有消息。
    /// 第二次同号到达必须把它当首次处理,换上完整的一份。
    func testHalfLandedFirstCopyIsReplaced() throws {
        let m = msg(seq: 0)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("torn".utf8).write(to: dir.appendingPathComponent("\(m.key).m4a"))
        XCTAssertEqual(try WatchInbox.land(try incoming("whole"), msg: m, into: dir), .landed)
        XCTAssertEqual(try audio(m.key), "whole")
    }

    /// 「清除全部录音」把 `recordings/` 下每个子目录当一天来清 ——
    /// 收件目录放在那下面的话,一次清除就会删掉还没誊写的手表录音。
    func testInboxIsNotUnderRecordings() {
        XCTAssertFalse(WatchInbox.inboxDir.path.hasPrefix(ProcessingPump.recordingsRoot.path + "/"))
    }

    func testBlockedDrainIsPersistedOnceAndRecoveryIsRecorded() throws {
        let db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        let blocked = WatchMirror.Report(applied: 0, notices: ["第 1 条未到达"])
        let notice = WatchInbox.recordDrainReport(blocked, previousNotice: nil, in: db)
        _ = WatchInbox.recordDrainReport(blocked, previousNotice: notice, in: db)
        XCTAssertEqual(try ProcessingEvents.recent(in: db).count, 1)
        XCTAssertTrue(try XCTUnwrap(ProcessingEvents.recent(in: db).first).outcome.contains("受阻"))
        XCTAssertNil(WatchInbox.recordDrainReport(.init(applied: 2), previousNotice: notice, in: db))
        let events = try ProcessingEvents.recent(in: db)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.first?.outcome, "手表录音同步已恢复")
    }

    func testChangedBlockReasonIsRecordedWithoutDependingOnAppliedCount() throws {
        let db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        let notice = WatchInbox.recordDrainReport(.init(notices: ["缺号"]), previousNotice: nil, in: db)
        _ = WatchInbox.recordDrainReport(.init(notices: ["内容冲突"]), previousNotice: notice, in: db)
        XCTAssertEqual(try ProcessingEvents.recent(in: db).map(\.detail), ["内容冲突", "缺号"])
    }
}

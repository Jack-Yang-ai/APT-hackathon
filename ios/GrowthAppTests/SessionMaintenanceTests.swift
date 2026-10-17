import XCTest
import GRDB
@testable import GrowthApp

/// 一场录音的重新冻结与删除。
///
/// 这一层只剩**重新冻结**。最贵的错法是**改了旧版** —— 冻结层的纪律是永不改。
/// (删除那一半搬去了 `MemoryRemoval`,见文件末尾。)
final class SessionMaintenanceTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-17T19:30:00+08:00"

    /// 一条真实形状的转写报文:`result` 是**数组**、`speaker` 是**字典** ——
    /// 这两点都是 2026-08-17 真机上踩出来的,写错的话解析器返回空而不报错。
    private static let payload =
        #"{"data":{"result":[{"utterances":[{"start_time":1000,"end_time":4000,"text":"第一句话在这里","speaker":{"id":"speaker_0"}}]}]}}"#

    /// 账本目录。**每个测试各用一个**,免得互相删。
    private var dir: URL!
    private let base = Date(timeIntervalSince1970: 1_786_000_000)
    private var day: String { SessionBridge.iso(base).prefix(10).description }

    /// 造账本。块时长由调用方给 —— 「块跑满 330 秒」正是要验的形态之一。
    private func makeLedger(_ durations: [Double]) throws {
        dir = ProcessingPump.recordingsRoot.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ledger = dir.appendingPathComponent("ledger.jsonl")
        try? FileManager.default.removeItem(at: ledger)
        try BlockLedger.append(LedgerEntry(at: base, mark: .sessionStarted), to: ledger)
        var off = 0.0
        for (seq, d) in durations.enumerated() {
            try BlockLedger.append(LedgerEntry(block: BlockRecord(
                seq: seq, startedAt: base.addingTimeInterval(off),
                endedAt: base.addingTimeInterval(off + d),
                hardCut: true, fileName: String(format: "block-%04d.m4a", seq))), to: ledger)
            off += d
        }
        try BlockLedger.append(LedgerEntry(at: base.addingTimeInterval(off),
                                           mark: .sessionEnded), to: ledger)
    }

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        try dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, ?, ?, 'recording', 'closed')
                """, arguments: [SessionBridge.iso(base), day])
            // 存着的转写报文 —— 重冻就靠它,不必重新提交(那才是要花钱的)
            try d.execute(sql: """
                INSERT INTO asr_jobs (session_id, block_seq, remote_id, state, result_json,
                                      created_at, updated_at)
                VALUES (1, 0, 'r0', 'done', ?, 'x', 'x')
                """, arguments: [Self.payload])
        }
    }
    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dbQueue = nil
    }

    // MARK: - 重新冻结

    /// 🔴 **落新版本,旧那版一个字不改。** 冻结层的纪律是永不改(§3.1.6)。
    func testRefreezeCreatesANewVersionAndLeavesTheOldOne() throws {
        try makeLedger([300])
        try dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'a', 'frozen', 'x')
                """)
            try d.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (100, 1, 0, 0, 3000, '旧版的一句', 0)
                """)
            try d.execute(sql: "UPDATE sessions SET active_transcript_id = 1 WHERE id = 1")
        }
        let r = try SessionMaintenance.refreeze(sessionID: 1, now: now, in: dbQueue)
        XCTAssertEqual(r.version, 2)

        try dbQueue.read { d in
            // 旧版原样在
            XCTAssertEqual(try String.fetchOne(
                d, sql: "SELECT text FROM transcript_lines WHERE line_id = 100"), "旧版的一句")
            // active 指到新版
            let active = try Int64.fetchOne(
                d, sql: "SELECT active_transcript_id FROM sessions WHERE id = 1")
            XCTAssertNotEqual(active, 1, "active 还指着旧版 —— 界面看不到重整的结果")
        }
    }

    /// 没有存着的报文就**明说**,不要假装重冻成功 ——
    /// 那时唯一的出路是重转写,而重转写要花钱,用户该知道。
    func testRefreezeWithoutStoredPayloadSaysSo() throws {
        try dbQueue.write { d in try d.execute(sql: "DELETE FROM asr_jobs") }
        XCTAssertThrowsError(try SessionMaintenance.refreeze(sessionID: 1, now: now, in: dbQueue)) {
            XCTAssertTrue("\($0)".contains("花钱"), "\($0)")
        }
    }

    /// 重冻也把簇标签写回去 —— 不写的话新版没有分人,
    /// 而界面看的是新版,用户会以为「分人没了」。
    func testRefreezeAlsoWritesClusterTags() throws {
        try makeLedger([300])
        let r = try SessionMaintenance.refreeze(sessionID: 1, now: now, in: dbQueue)
        XCTAssertGreaterThan(r.clustersTagged, 0)
        let n = try dbQueue.read { d in
            try Int.fetchOne(d, sql:
                "SELECT COUNT(*) FROM line_speakers WHERE cluster_tag IS NOT NULL") ?? 0
        }
        XCTAssertGreaterThan(n, 0)
    }

    /// 🔴 **重整之后缺块照样是缺块 —— 不许自称完整。**
    ///
    /// 2026-08-18 复核抓到:`TranscriptFreeze.freeze` 有**两个**调用点,
    /// 而 M1-14a(缺块不许被静默抹平)只修了 `ProcessingPump` 那一个。
    /// 这里原来自己写了一份装配、不传 `missing:` ⇒
    /// 「重新整理时间轴」会把一份缺块的转写重新落成 `frozen`,
    /// 卡片说「好了」而逐字稿有洞 —— **同一个 BUG,换了个入口**。
    func testRefreezeKeepsAMissingBlockMissing() throws {
        // 账本里两块,而只有块 0 有转写报文 ⇒ 块 1 是缺块
        try makeLedger([300, 300])

        let r = try SessionMaintenance.refreeze(sessionID: 1, now: now, in: dbQueue)
        XCTAssertEqual(r.status, "partial", "缺了一块,重整出来的转写却自称完整")
        try dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM transcript_lines l
                  JOIN transcripts t ON t.id = l.transcript_id
                 WHERE t.version = 1 AND l.is_gap = 1
                """), 1, "重整之后洞没留下来 —— 时间轴上看不出缺了五分钟")
        }
    }

    /// 块起点取**账本真值**,不是 `blockSeq × 300_000`。
    /// 这条守的是 M1-13a 的另一个入口:兜底那个乘法在块跑满时会逐块累积偏移,
    /// **跳原话跳到错的位置,而且不报任何错**。
    func testRefreezeTakesBlockOffsetsFromTheLedger() throws {
        // 块 0 跑满 **330 秒**(名义是 300)—— 名义值会让块 1 的行整体提前 30 秒
        try makeLedger([330, 300])
        try dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO asr_jobs (session_id, block_seq, remote_id, state, result_json,
                                      created_at, updated_at)
                VALUES (1, 1, 'r1', 'done', ?, 'x', 'x')
                """, arguments: [Self.payload])
        }

        try SessionMaintenance.refreeze(sessionID: 1, now: now, in: dbQueue)
        let starts = try dbQueue.read { d in
            try Int.fetchAll(d, sql: """
                SELECT l.t_start_ms FROM transcript_lines l
                  JOIN transcripts t ON t.id = l.transcript_id
                 WHERE t.version = 1 AND l.block_seq = 1 AND l.is_gap = 0
                 ORDER BY l.seq
                """)
        }
        XCTAssertEqual(starts.first, 331_000,
                       "块 1 的起点用了名义 300 秒 —— 整块的时间轴提前了 30 秒")
    }

    /// 报文在、账本没了 → **说准原因**。
    /// 与「没有存下来的转写报文」分开:那时重转写能救,这时救不了
    /// (块的位置在账本里,不在报文里),而两句话会把用户导向不同的按钮。
    func testRefreezeWithoutALedgerSaysWhichThingIsMissing() throws {
        XCTAssertThrowsError(try SessionMaintenance.refreeze(sessionID: 1, now: now, in: dbQueue)) {
            XCTAssertTrue("\($0)".contains("账本"), "\($0)")
        }
    }

    // MARK: - 移出记忆不在这一层

    // 🔴 redact 的验收全在 `MemoryRemovalTests` —— 那才是唯一的通道。
    // 我 2026-08-17 曾在 `SessionMaintenance` 里另写一份 redact 并配了一整组测试,
    // **五条全绿,而绿的是第二个写方**。整组删掉;守它的断言换成
    // `MemoryRemovalTests.testNoSecondRedactChannel`(扫源码)——
    // 「两处行为一致」的数据断言挡不住第三处,而这类 BUG 的形态正是「又写了一个」。
}

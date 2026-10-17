import XCTest
import GRDB
@testable import GrowthApp

/// 时间轴体检(M1-13b-1)。
///
/// ## 这一组测试自己最容易造的假绿
///
/// 「脏数据能被扫出来」**一条通不过任何审查** —— 一个 `return allSessions` 的
/// `scan` 也能让它变绿。所以每一条「报了」旁边都钉着一条「不报」:
/// 干净场次不报、宽限之内不报、还在录的不报、旧版本不报。
/// 判据要能红,先得证明它会白。
///
/// 另一条同样贵的假绿在**修**那一侧:`refreeze` 返回成功 ≠ 时间轴修好了。
/// 账本里块的位置本身就歪的时候,它会**成功地再落一遍同样的错**
/// (仓规 §3.3:验「落对没落对」,不验「跑没跑通」)。
/// `testRefreezeThatStillOvershootsCountsAsFailedNotFixed` 钉的就是这一条。
final class TimelineAuditTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-19T10:00:00+08:00"

    /// **和 `SessionMaintenanceTests` 错开一天。** 两个 suite 都往
    /// `Documents/recordings/<day>/ledger.jsonl` 写,撞在同一天里会互相删。
    /// 1787100000 = 2026-08-19 08:40(本地),本文件里的偏移都在一小时内,不跨零点。
    private let base = Date(timeIntervalSince1970: 1_787_100_000)
    private var day: String { SessionBridge.iso(base).prefix(10).description }
    private var dir: URL!
    private var ledgerURL: URL { dir.appendingPathComponent("ledger.jsonl") }

    /// 一条真实形状的转写报文(照抄 `SessionMaintenanceTests`):
    /// `result` 是**数组**、`speaker` 是**字典** —— 写错的话解析器返回空而不报错。
    private static let payload =
        #"{"data":{"result":[{"utterances":[{"start_time":1000,"end_time":4000,"text":"第一句话在这里","speaker":{"id":"speaker_0"}}]}]}}"#

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        dir = ProcessingPump.recordingsRoot.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: ledgerURL)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dbQueue = nil
    }

    // MARK: - 造数据

    /// 一场。`endsAfter == nil` ⇒ `ended_at` 留空(还在录);
    /// `endedAtLiteral` ⇒ 直接塞一个字符串进去(用来造解析不出来的时间戳)。
    private func session(_ id: Int64, startOffset: TimeInterval = 0,
                         endsAfter: TimeInterval?, endedAtLiteral: String? = nil) throws {
        let start = base.addingTimeInterval(startOffset)
        let ended = endedAtLiteral ?? endsAfter.map { SessionBridge.iso(start.addingTimeInterval($0)) }
        try dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (?, ?, ?, ?, 'recording', 'closed')
                """, arguments: [id, SessionBridge.iso(start), ended, day])
        }
    }

    /// 一版转写 + 它的行。`lines` 里每项是 `(起, 止)` 毫秒。
    private func transcript(_ tid: Int64, session sid: Int64, version: Int = 1, part: Int = 1,
                            lines: [(Int, Int)], gap: Bool = false, redacted: Bool = false,
                            active: Bool = true) throws {
        try dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (?, ?, ?, ?, 'a', 'frozen', 'x')
                """, arguments: [tid, sid, version, part])
            for (seq, l) in lines.enumerated() {
                try d.execute(sql: """
                    INSERT INTO transcript_lines
                      (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap, redacted)
                    VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                    """, arguments: [tid, seq, l.0, l.1,
                                     redacted ? "〔已移出记忆〕" : "一句话", gap, redacted])
            }
            if active {
                try d.execute(sql: "UPDATE sessions SET active_transcript_id = ? WHERE id = ?",
                              arguments: [tid, sid])
            }
        }
    }

    /// 往当天账本里追加一场:`sessionStarted` → 若干块 → `sessionEnded`。
    /// `blocks` 每项是 `(相对场次起点的偏移, 块时长)`,单位秒。
    private func appendLedger(startOffset: TimeInterval = 0,
                              blocks: [(offset: TimeInterval, duration: TimeInterval)]) throws {
        let start = base.addingTimeInterval(startOffset)
        try BlockLedger.append(LedgerEntry(at: start, mark: .sessionStarted), to: ledgerURL)
        var last = start
        for (seq, b) in blocks.enumerated() {
            let s = start.addingTimeInterval(b.offset)
            let e = s.addingTimeInterval(b.duration)
            try BlockLedger.append(LedgerEntry(block: BlockRecord(
                seq: seq, startedAt: s, endedAt: e, hardCut: true,
                fileName: String(format: "block-%04d.m4a", seq))), to: ledgerURL)
            last = e
        }
        try BlockLedger.append(LedgerEntry(at: last, mark: .sessionEnded), to: ledgerURL)
    }

    private func asrJob(session sid: Int64, blockSeq: Int = 0) throws {
        try dbQueue.write { d in
            try d.execute(sql: """
                INSERT INTO asr_jobs (session_id, block_seq, remote_id, state, result_json,
                                      created_at, updated_at)
                VALUES (?, ?, 'r', 'done', ?, 'x', 'x')
                """, arguments: [sid, blockSeq, Self.payload])
        }
    }

    private func scan() throws -> [TimelineAudit.Finding] {
        try dbQueue.read { try TimelineAudit.scan(in: $0) }
    }

    // MARK: - 扫:它得会白

    /// 🔴 **照妖镜的另一半。** 没有这一条,一个恒真的 `scan` 也能让整组测试变绿。
    /// 一场 600 秒、行正好落在 600 秒 —— 什么都不该报。
    func testACleanSessionIsNotReported() throws {
        try session(1, endsAfter: 600)
        try transcript(10, session: 1, lines: [(0, 3_000), (596_000, 600_000)])

        XCTAssertEqual(try scan(), [], "干净场次被报了 —— 判据不是在查时间轴,是在恒真")
    }

    /// 宽限之内的溢出咽下去。**误报要花钱**:用户照着报告点「重整」会落一版新转写,
    /// 而新版的纪要要重新抽(见 `SessionMaintenance.refreeze` 的注释)。
    /// 1.8 秒的溢出多半只是秒粒度时间戳 + ASR 末句压尾,不该变成一条待办。
    func testASubSecondTailWithinTheGraceIsNotReported() throws {
        try session(1, endsAfter: 600)
        try transcript(10, session: 1, lines: [(590_000, 601_800)])   // 溢出 1800 ms

        XCTAssertEqual(try scan(), [], "1.8 秒的溢出被报成问题 —— 宽限没起作用")
    }

    /// 边界钉死:**正好等于宽限不报,多 1 毫秒就报**。
    /// 不钉的话,`>` 写成 `>=`(或反过来)没有任何东西会红。
    func testTheGraceBoundaryIsExclusive() throws {
        try session(1, endsAfter: 600)
        try transcript(10, session: 1, lines: [(0, 600_000 + TimelineAudit.graceMs)])
        XCTAssertEqual(try scan(), [], "正好等于宽限不该报")

        try session(2, startOffset: 3_000, endsAfter: 600)
        try transcript(20, session: 2, lines: [(0, 600_000 + TimelineAudit.graceMs + 1)])
        XCTAssertEqual(try scan().map(\.sessionID), [2], "比宽限多 1 毫秒就该报")
    }

    // MARK: - 扫:它得会红

    /// 真机上那 6 场的形状(某场次:实际 155 秒,行落在 1800 秒)。
    func testLinesLandingPastTheEndOfTheSessionAreReported() throws {
        try session(1, endsAfter: 155)
        try transcript(10, session: 1, lines: [(1_800_000, 1_803_000)])

        XCTAssertEqual(try scan(), [
            TimelineAudit.Finding(sessionID: 1, durationMs: 155_000,
                                  maxLineEndMs: 1_803_000, overshootMs: 1_648_000)
        ])
    }

    /// 某场次 那一例:块偏移是 300 秒,而**量得到的溢出只有 116 秒** ——
    /// 场次自己的长度吃掉了一部分。宽限一旦按「块是 300 秒粒度」去取,这一例就漏掉,
    /// 而它恰恰是最像正常的那一例。
    func testTheSmallestRealCaseFromTheDeviceIsStillCaught() throws {
        try session(184, endsAfter: 184)
        try transcript(10, session: 184, lines: [(300_000, 300_000)])

        let found = try scan()
        XCTAssertEqual(found.map(\.sessionID), [184])
        XCTAssertEqual(found.first?.overshootMs, 116_000,
                       "溢出不等于块偏移(300 秒)—— 场次自己的长度吃掉了一部分")
    }

    // MARK: - 扫:范围口径

    /// 🔴 **一场 = 该 version 的全部 part。**
    /// 这一场的 `active_transcript_id` 指着 part 2(`TranscriptFreeze` 就是这么指的),
    /// 而**坏行在 part 1 里**。按 `active_transcript_id` 过滤的实现会返回空 ——
    /// 而且是一路绿的空:超长场次正是全时录音的常态,那种实现下这道检查等于没跑。
    func testAllPartsOfTheActiveVersionAreMeasuredNotJustTheLastOne() throws {
        try session(1, endsAfter: 600)
        try transcript(10, session: 1, part: 1, lines: [(1_800_000, 1_800_500)], active: false)
        try transcript(11, session: 1, part: 2, lines: [(500_000, 590_000)], active: true)

        XCTAssertEqual(try scan().map(\.sessionID), [1],
                       "坏行在 part 1 —— 只看 active_transcript_id 会漏掉整场")
    }

    /// 修完之后旧那版**原样留着**(冻结层永不改,§3.1.6)。
    /// 拿旧版去判会让修过的场次永远挂在名单上,用户点一次修一次,永远修不完。
    func testOnlyTheNewestVersionCounts() throws {
        try session(1, endsAfter: 600)
        try transcript(10, session: 1, version: 1, lines: [(1_800_000, 1_803_000)], active: false)
        try transcript(11, session: 1, version: 2, lines: [(0, 3_000)], active: true)

        XCTAssertEqual(try scan(), [], "v1 是坏的,但 v2 才是生效那一版")
    }

    /// 占位行(缺块)与墓碑行(移出记忆)**都算数**。
    /// 把它们排除掉,「缺最后一块」「末尾被移出记忆」的场次会恰好躲过这道检查。
    func testGapAndRedactedLinesStillCount() throws {
        try session(1, endsAfter: 60)
        try transcript(10, session: 1, lines: [(1_500_000, 1_800_000)], gap: true)
        try session(2, startOffset: 3_000, endsAfter: 60)
        try transcript(20, session: 2, lines: [(1_500_000, 1_800_000)], redacted: true)

        XCTAssertEqual(try scan().map(\.sessionID), [1, 2])
    }

    /// 还在录的场次没有结束时刻 —— 没有比较的另一边,跳过。
    /// (行落在哪都不算问题:这一刻它本来就还在长。)
    func testStillRecordingSessionsAreSkipped() throws {
        try session(1, endsAfter: nil)
        try transcript(10, session: 1, lines: [(1_800_000, 1_803_000)])

        XCTAssertEqual(try scan(), [])
    }

    // MARK: - 查不了的要说出来

    /// 🔴 **「没查」和「查过了没问题」必须分开报。**
    /// 两者在界面上都长成「不在问题名单里」,而前者是「不知道」(仓规 §3.2)。
    func testUnparseableTimestampsAreReportedAsUnauditableAndRecorded() throws {
        try session(1, endsAfter: nil, endedAtLiteral: "不是一个时间")
        try transcript(10, session: 1, lines: [(1_800_000, 1_803_000)])

        let check = try TimelineAudit.check(in: dbQueue)
        XCTAssertEqual(check.findings, [], "量不出时长的场次不该混进问题名单")
        XCTAssertEqual(check.unauditable, [1])

        let events = try ProcessingEvents.recent(limit: 5, in: dbQueue)
        XCTAssertTrue(events.contains { $0.outcome.contains("没查") },
                      "跳过了却什么都没记 —— 这正是 §3.2 不许的静默丢弃")
    }

    // MARK: - 修

    /// 端到端:脏的 v1 → 重整 → 溢出没了。
    func testRepairRefreezesAndTheOvershootIsGone() throws {
        try appendLedger(blocks: [(offset: 0, duration: 300)])
        try session(1, endsAfter: 300)
        try transcript(10, session: 1, lines: [(1_800_000, 1_803_000)])
        try asrJob(session: 1)

        let findings = try scan()
        XCTAssertEqual(findings.count, 1)

        let r = TimelineAudit.repair(findings, now: now, in: dbQueue)
        XCTAssertEqual(r.fixed, [1])
        XCTAssertTrue(r.failed.isEmpty, "\(r.failed)")
        XCTAssertEqual(try scan(), [], "报了修好,再扫却还在 —— 那就是没修好")
    }

    /// 🔴 **一场失败不许中断其余场次。**
    /// 某场次 没有存下来的报文(重整无从下手),某场次 是能修的 ——
    /// 中断的实现会让 2 一直挂在名单上,而用户刚点过一次「修」。
    func testOneFailingSessionDoesNotStopTheRest() throws {
        try session(1, endsAfter: 300)                       // 没有 asr_jobs
        try transcript(10, session: 1, lines: [(1_800_000, 1_803_000)])
        try appendLedger(startOffset: 3_000, blocks: [(offset: 0, duration: 300)])
        try session(2, startOffset: 3_000, endsAfter: 300)
        try transcript(20, session: 2, lines: [(1_800_000, 1_803_000)])
        try asrJob(session: 2)

        let r = TimelineAudit.repair(try scan(), now: now, in: dbQueue)
        XCTAssertEqual(r.fixed, [2])
        XCTAssertEqual(r.failed.map(\.0), [1])
        XCTAssertTrue(r.failed.first?.1.contains("没有存下来的转写报文") == true,
                      "原因被吞成了一句「没成功」:\(r.failed)")
    }

    /// 🔴 **最贵的那个假绿:`refreeze` 说成功了,而时间轴还是错的。**
    ///
    /// 这一场的账本自己就是歪的 —— 块躺在 1800 秒处,而场次只有 155 秒。
    /// 重整会**成功地把同样的错再落一遍**并返回一个 `RefreezeResult`。
    /// 不复查的实现会把它报进 `fixed`,用户从此以为这一场好了。
    func testRefreezeThatStillOvershootsCountsAsFailedNotFixed() throws {
        try appendLedger(blocks: [(offset: 1_800, duration: 30)])
        try session(1, endsAfter: 155)
        try transcript(10, session: 1, lines: [(1_800_000, 1_803_000)])
        try asrJob(session: 1)

        let r = TimelineAudit.repair(try scan(), now: now, in: dbQueue)
        XCTAssertTrue(r.fixed.isEmpty, "重整跑通了但时间轴还是错的,不能算修好:\(r.fixed)")
        XCTAssertEqual(r.failed.map(\.0), [1])
        XCTAssertTrue(r.failed.first?.1.contains("还是落在场次之外") == true,
                      "\(r.failed)")

        // 而且它确实又落了一版 —— 证明「失败」不是因为重整没跑。
        let versions = try dbQueue.read { d in
            try Int.fetchOne(d, sql: "SELECT MAX(version) FROM transcripts WHERE session_id = 1")
        }
        XCTAssertEqual(versions, 2)
    }

    /// 每一场都要在事件表里留一行 —— **失败那几场尤其**:
    /// `refreeze` 抛出来时它自己那条事件根本没走到,不在这儿记就彻底没人知道。
    func testEveryRepairedSessionLeavesOneEvent() throws {
        try session(1, endsAfter: 300)                       // 修不了(没报文)
        try transcript(10, session: 1, lines: [(1_800_000, 1_803_000)])
        try session(2, startOffset: 3_000, endsAfter: 300)   // 也修不了
        try transcript(20, session: 2, lines: [(1_800_000, 1_803_000)])

        _ = TimelineAudit.repair(try scan(), now: now, in: dbQueue)

        let audits = try ProcessingEvents.recent(limit: 20, in: dbQueue)
            .filter { $0.outcome.hasPrefix("时间轴体检:场次") }
        XCTAssertEqual(audits.count, 2, "两场两行,一行都不能少")
        XCTAssertTrue(audits.allSatisfy { $0.trigger == ProcessingEvents.Trigger.foreground.rawValue })
        XCTAssertTrue(audits.allSatisfy { ($0.detail ?? "").contains("超出 1503 秒") },
                      "detail 里没写偏了多少 —— 那是这行事件唯一的信息量:\(audits)")
    }
}

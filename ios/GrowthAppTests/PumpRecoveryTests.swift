import XCTest
import GRDB
@testable import GrowthApp

/// 2026-08-17 真机取证抓到的三条(M1-4c 收尾)。
///
/// 三条的共同点:**任务表看起来一切正常**。没有报错、没有崩溃、
/// exit code 全绿 —— 而钱在多花、场次在卡死。仓规 §3.3:
/// 验收验「落对没落对」,不验「跑没跑通」。这组测试就是那把尺子。
final class PumpRecoveryTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-14T19:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        // tasks.session_id 是外键 —— 没有场次行就插不进任务
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, ?, '2026-08-14', 'recording', 'closed')
                """, arguments: [now])
        }
    }
    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 🔴 B:`running` 不能是死态

    /// `nextRunnable` 只捡 queued / retrying / waiting_network。
    /// 于是一个任务只要在 `running` 上被打断(App 被杀、后台时间用完、崩溃),
    /// 就**永远再也捡不起来** —— 而任务表看起来一切正常,状态是「在跑」。
    ///
    /// 真机实测:三个转写任务全卡在 running、attempts=0、next_retry_at 为空。
    /// M1-4 的准入条件是「整条链路能从落盘状态恢复」,少了这一步那句话就是空的。
    func testInterruptedRunningTaskIsReclaimedSoItCanRunAgain() throws {
        let id = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: now, in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tasks SET state = 'running' WHERE task_id = ?",
                           arguments: [id])
        }
        XCTAssertNil(try TaskQueue.nextRunnable(now: now, in: dbQueue),
                     "前提变了:running 现在能被捡起来了,这条测试要重写")

        XCTAssertEqual(try TaskQueue.reclaimInterrupted(now: now, in: dbQueue), 1)
        XCTAssertEqual(try TaskQueue.nextRunnable(now: now, in: dbQueue), id,
                       "捡回来了却还是捡不起来 —— 这一场永远出不了稿")
    }

    /// `uploading` 同理 —— 上传那一步也会把任务置成一个不可捡的态。
    func testInterruptedUploadingTaskIsAlsoReclaimed() throws {
        let id = try TaskQueue.enqueue(kind: "upload_audio", sessionID: 1, now: now, in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tasks SET state = 'uploading' WHERE task_id = ?",
                           arguments: [id])
        }
        XCTAssertEqual(try TaskQueue.reclaimInterrupted(now: now, in: dbQueue), 1)
        XCTAssertEqual(try TaskQueue.nextRunnable(now: now, in: dbQueue), id)
    }

    /// **attempts 不许加。** 被打断不是失败 —— 加了会把任务一路推向 dead,
    /// 而它一次都没真的失败过。
    func testReclaimDoesNotCountAsAFailure() throws {
        let id = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: now, in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE tasks SET state = 'running', attempts = 2 WHERE task_id = ?
                """, arguments: [id])
        }
        try TaskQueue.reclaimInterrupted(now: now, in: dbQueue)
        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT attempts FROM tasks"), 2,
                           "被打断被记成了一次失败")
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT last_error FROM tasks"),
                            "捡回来了却没说为什么 —— 排查时看到的就是一行「不知道怎么回事的重排」")
        }
    }

    /// **终态不许动。** dead / done 被捡回去等于把已经收工的任务重跑一遍,
    /// 而重跑 transcribe 是要花钱的。
    func testReclaimNeverTouchesTerminalStates() throws {
        for state in ["done", "dead", "degraded", "queued", "retrying", "waiting_network"] {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO tasks (kind, session_id, state, priority, created_at, attempts)
                    VALUES ('transcribe', 1, ?, 0, ?, 0)
                    """, arguments: [state, now])
            }
        }
        XCTAssertEqual(try TaskQueue.reclaimInterrupted(now: now, in: dbQueue), 0,
                       "把不该动的任务也捡了 —— dead/done 重跑 transcribe 是要花钱的")
    }

    // MARK: - 🔴 B2:「进程刚起来」这条判据不够(2026-08-24)

    /// 🔴 **每拍都要捡一次,不能只在冷启动时捡。**
    ///
    /// 真机某场次 的 `transcribe` **在 `running` 上躺了四天**:
    /// `attempts = 0`、`next_retry_at` 为空 —— 它一次都没失败过,只是没人捡。
    /// 根因是这条补救只挂在 `didFinishLaunching` 上,而 App 被系统留在后台、
    /// 一直没冷启动 ⇒ **它一次都没跑**。
    ///
    /// ⚠️ 而用户对这种任务**没有任何可达的补救手段**:`retrySession` 只动
    /// `dead`/`degraded`,`releaseBackoff` 只动 `retrying`,三个都不沾 `running`。
    /// 界面上就是永远的「整理中」。
    func testTickLevelReclaimPicksUpAnOrphanedRunningTask() throws {
        let id = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: now, in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tasks SET state = 'running' WHERE task_id = ?",
                           arguments: [id])
        }
        XCTAssertEqual(try TaskQueue.reclaimInterrupted(states: ["running"],
                                                        now: now, in: dbQueue), 1)
        XCTAssertEqual(try TaskQueue.nextRunnable(now: now, in: dbQueue), id,
                       "孤儿没被捡回来 —— 这一场会永远停在「整理中」")
    }

    /// 🔴 **每拍那次不许碰 `uploading`。**
    ///
    /// 后台 `URLSession` 的传输**在没有任何一拍在跑的时候照样在传** ——
    /// 它跟 `running` 不是一回事。每拍把它打回 `queued`,会让一个
    /// **正在成功上传**的块重新排队,而重传是花钱的。
    ///
    /// ⚠️ 这条与上面那条必须**分开**写:合成一条的话,把 `states:` 写死成
    /// `["running","uploading"]` 也能过 —— 而那正是要挡的那个改法。
    func testTickLevelReclaimLeavesUploadingAlone() throws {
        let id = try TaskQueue.enqueue(kind: "upload_audio", sessionID: 1, now: now, in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tasks SET state = 'uploading' WHERE task_id = ?",
                           arguments: [id])
        }
        XCTAssertEqual(try TaskQueue.reclaimInterrupted(states: ["running"],
                                                        now: now, in: dbQueue), 0,
                       "每拍把在途的上传打回了队列 —— 那个块会被重新传一次,而重传花钱")
        try dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM tasks WHERE task_id = ?",
                                               arguments: [id]), "uploading")
        }
    }

    // MARK: - 🔴 C:同一时刻只许一个 pump

    /// 三条腿(前台 / BGTask / 传输回调)都会推,而传输回调是**每块一次**。
    /// 真机实测:事件表里同一秒 5 条一模一样的记录,说明它们看到的是同一份状态。
    ///
    /// 后果不只是噪声,是**可能花两次钱**:「查有没有提交过 → 提交 → 落 asr_jobs」
    /// 不是原子的,两个 pump 会双双查到「没提交过」,然后各提交一次。
    func testConcurrentPumpsDoNotAllRun() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: now, in: dbQueue)

        // 五条腿同时推 —— 传输回调那条真机上就是这个形状
        await withTaskGroup(of: [ProcessingOrchestrator.Outcome].self) { g in
            for _ in 0..<5 {
                g.addTask { await ProcessingPump.run(trigger: .transferCallback, in: self.dbQueue) }
            }
            var ran = 0
            for await outcomes in g where !outcomes.isEmpty { ran += 1 }
            XCTAssertEqual(ran, 1, "\(ran) 个 pump 同时跑了 —— 转写会被提交 \(ran) 次,钱花 \(ran) 份")
        }
    }

    /// 锁必须**放得掉**:一次推完之后下一次还要能推,
    /// 否则第一次之后这个 App 就再也不处理任何东西了 —— 比并发更糟。
    func testGateIsReleasedSoLaterPumpsStillRun() async throws {
        _ = await ProcessingPump.run(trigger: .foreground, in: dbQueue)
        let second = await ProcessingPump.run(trigger: .foreground, in: dbQueue)
        XCTAssertEqual(second, [.idle], "锁没放掉 —— 从此再也不会处理任何东西")
    }

    // MARK: - 🔴 A:一场只能算自己的块

    /// 原来读整个账本、把当天所有块都当成这一场的。
    /// 真机实测:一天三场,每场都传了当天全部 4 个块 ——
    /// **12 次上传对应 4 个音频文件**,再往下走就是 12 次转写,而转写按块收费。
    /// 而且每一场的逐字稿里都会是一整天的内容。
    func testEachSessionOnlyOwnsItsOwnBlocks() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 一天两场:第一场 2 块(0、1),第二场 2 块(2、3)
        let t0 = Date(timeIntervalSince1970: 1_786_000_000)
        let url = dir.appendingPathComponent("ledger.jsonl")
        // `LedgerEntry(block:)` 的 `at` 取块的 endedAt —— 账本里就是这么写的
        func block(_ seq: Int, _ at: Date) -> LedgerEntry {
            LedgerEntry(block: BlockRecord(
                seq: seq, startedAt: at.addingTimeInterval(-300), endedAt: at,
                hardCut: false, fileName: String(format: "block-%04d.m4a", seq)))
        }
        try BlockLedger.append(LedgerEntry(at: t0, mark: .sessionStarted), to: url)
        try BlockLedger.append(block(0, t0.addingTimeInterval(300)), to: url)
        try BlockLedger.append(block(1, t0.addingTimeInterval(600)), to: url)
        try BlockLedger.append(LedgerEntry(at: t0.addingTimeInterval(600), mark: .sessionEnded),
                               to: url)
        let t1 = t0.addingTimeInterval(3600)
        try BlockLedger.append(LedgerEntry(at: t1, mark: .sessionStarted), to: url)
        try BlockLedger.append(block(2, t1.addingTimeInterval(300)), to: url)
        try BlockLedger.append(block(3, t1.addingTimeInterval(600)), to: url)
        try BlockLedger.append(LedgerEntry(at: t1.addingTimeInterval(600), mark: .sessionEnded),
                               to: url)

        let (entries, _) = try BlockLedger.read(from: url)
        let sessions = BlockLedger.sessions(entries: entries)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].blocks.map(\.seq), [0, 1], "第一场吃到了第二场的块")
        XCTAssertEqual(sessions[1].blocks.map(\.seq), [2, 3], "第二场吃到了第一场的块")
        // blockCount 现在是派生的,不能和清单打架
        XCTAssertEqual(sessions.map(\.blockCount), [2, 2])
    }

    /// 一个块都没有的场次给空清单,**不是给「当天所有块」**。
    /// 「开了但没录上」是真实存在的一种场次(账本里就有),
    /// 给它别人的音频就是把别人的话记到它头上。
    func testASessionThatRecordedNothingGetsNoBlocks() throws {
        let t0 = Date(timeIntervalSince1970: 1_786_000_000)
        let entries = [
            LedgerEntry(at: t0, mark: .sessionStarted),
            LedgerEntry(at: t0.addingTimeInterval(2), mark: .sessionEnded),
            LedgerEntry(at: t0.addingTimeInterval(60), mark: .sessionStarted),
            LedgerEntry(block: BlockRecord(
                seq: 0, startedAt: t0.addingTimeInterval(60),
                endedAt: t0.addingTimeInterval(360), hardCut: false,
                fileName: "block-0000.m4a")),
        ]
        let sessions = BlockLedger.sessions(entries: entries)
        XCTAssertTrue(sessions[0].blocks.isEmpty, "空场次拿到了别人的块")
        XCTAssertEqual(sessions[1].blocks.map(\.seq), [0])
    }
}

// MARK: - 🔴 退避必须真的退(2026-08-17 真机)

extension PumpRecoveryTests {

    /// `next_retry_at` 与 `nextRunnable` 比的是**字符串**,所以两边的时区格式
    /// 必须一致。原来 `recordFailure` 本地新建了一个格式化器、**没设时区**
    /// ⇒ 写的是 UTC(`…T04:00:13Z`),而比较用本地串(`…T11:59:13+08:00`),
    /// `"04" < "11"` 恒成立 ⇒ **退避完全失效**。
    ///
    /// 后果不是「早了一点」,是整套节流塌掉:失败任务立刻又被捡起来,
    /// 一拍 12 次全花在同一个任务上,真正该干的活一次都排不到(**队头阻塞**),
    /// 而 attempts 几分钟内烧到上限被判 dead —— 它一次都没真的退避过。
    func testAFailedTaskIsNotImmediatelyRunnableAgain() throws {
        let id = try TaskQueue.enqueue(kind: "extract", sessionID: 1, now: now, in: dbQueue)
        let at = ISO8601DateFormatter.growth.date(from: now)!
        try TaskQueue.recordFailure(taskID: id, error: "失败了", at: at, in: dbQueue)

        XCTAssertNil(try TaskQueue.nextRunnable(now: now, in: dbQueue),
                     "刚失败就又能被捡起来 —— 退避没生效,它会把整拍占满")
        // 退避第一档是 1 分钟,过了就该能捡
        let later = ISO8601DateFormatter.growth.string(from: at.addingTimeInterval(61))
        XCTAssertEqual(try TaskQueue.nextRunnable(now: later, in: dbQueue), id,
                       "退避到点了却捡不起来 —— 这个任务再也不会跑")
    }

    /// 写进库的时间串**必须和全仓同一个口径**(带本地偏移),不能是 UTC 的 `Z`。
    /// 混着写的话字符串比较会给出一个看着正常、实际差 8 小时的答案。
    func testBackoffTimestampUsesTheOneRepoWideFormatter() throws {
        let id = try TaskQueue.enqueue(kind: "extract", sessionID: 1, now: now, in: dbQueue)
        try TaskQueue.recordFailure(taskID: id, error: "x",
                                    at: ISO8601DateFormatter.growth.date(from: now)!, in: dbQueue)
        let next = try XCTUnwrap(try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT next_retry_at FROM tasks WHERE task_id = ?",
                                arguments: [id])
        })
        XCTAssertFalse(next.hasSuffix("Z"),
                       "写成了 UTC(\(next))—— 和比较用的本地串不是一个口径")
        XCTAssertNotNil(ISO8601DateFormatter.growth.date(from: next), "解不回来:\(next)")
    }

    /// 一拍**不该把所有步数花在同一个任务上**。退避正常时这是自然结果 ——
    /// 这条钉住的是那个自然结果,真机上它塌过。
    func testOnePumpDoesNotSpendEveryStepOnTheSameFailingTask() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (2, '2026-08-17T19:30:00+08:00', '2026-08-17', 'recording', 'closed')
                """)
        }
        // 一个会失败的任务(没有场次目录 ⇒ 一块音频都没有)+ 一个排在后面的
        let bad = try TaskQueue.enqueue(kind: "upload_audio", sessionID: 1, now: now, in: dbQueue)
        try TaskQueue.enqueue(kind: "upload_audio", sessionID: 2, now: now, in: dbQueue)

        let outcomes = await ProcessingPump.run(trigger: .foreground, in: dbQueue)
        let onBad = outcomes.filter { if case .failed(1, _) = $0 { return true }; return false }
        XCTAssertLessThanOrEqual(onBad.count, 2,
            "一拍在同一个失败任务上跑了 \(onBad.count) 次 —— 后面的活永远排不上(队头阻塞)")
        _ = bad
    }
}

// MARK: - 🔴 分人标签真的写进去了吗(2026-08-17)

extension PumpRecoveryTests {

    private func makeTranscript(lines: [(Int64, String)]) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (session_id, version, part, asr_model, status,
                                         created_at, frozen_at)
                VALUES (1, 1, 1, 'stepaudio-2.5-asr', 'frozen', 'now', 'now')
                """)
            let tid = db.lastInsertedRowID
            for (i, l) in lines.enumerated() {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0)
                    """, arguments: [l.0, tid, i, i * 1000, i * 1000 + 900, l.1])
            }
            return tid
        }
    }

    /// 🔴 **这条测试是补票。** 真机上标签解出来了、也调到了写入口,
    /// 但 `confidence` 传了 nil ⇒ `assignSpeaker` 按 §3.2.2 拒收 ⇒
    /// `line_speakers` **0 行**,而逐字稿看起来一切正常。
    /// 当时没有任何测试盖这条路 —— 它是靠事件表里那行「分人标签写不进去」
    /// 才被抓到的,而那已经是真机上跑完之后了。
    func testClusterTagsActuallyLandInTheAttributionTable() throws {
        let long = String(repeating: "长", count: 25)
        _ = try makeTranscript(lines: [(500, long), (501, "短句"), (502, long)])
        try ProcessingPump.writeClusterTags([500: "speaker_0", 501: "speaker_1", 502: "speaker_0"],
                                            now: now, trigger: .foreground, in: dbQueue)

        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM line_speakers"), 3,
                           "标签一行都没写进去 —— 走文件端点的全部价值就在这")
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT cluster_tag FROM line_speakers WHERE line_id = 500
                """), "speaker_0")
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT source FROM line_speakers WHERE line_id = 500
                """), "系统整理")
            // person 必须是空:簇标签是「这一场里的第 N 个人」,不是身份
            XCTAssertNil(try Int64.fetchOne(db, sql: """
                SELECT person_id FROM line_speakers WHERE line_id = 500
                """))
        }
    }

    /// 置信度按行长分档。依据是 P4a 那条实测(20 字以上长句错误率 10%);
    /// 短行的 0.5 **不是测量值,是一句「不知道」** —— 编一个像样的数会让
    /// 下游拿它当真去做取舍。
    func testConfidenceIsSplitByLineLength() throws {
        let long = String(repeating: "长", count: 25)
        _ = try makeTranscript(lines: [(600, long), (601, "短")])
        try ProcessingPump.writeClusterTags([600: "speaker_0", 601: "speaker_0"],
                                            now: now, trigger: .foreground, in: dbQueue)
        try dbQueue.read { db in
            XCTAssertEqual(try Double.fetchOne(db, sql: """
                SELECT confidence FROM line_speakers WHERE line_id = 600
                """), 0.90, "长句该用实测的那个数")
            XCTAssertEqual(try Double.fetchOne(db, sql: """
                SELECT confidence FROM line_speakers WHERE line_id = 601
                """), 0.50, "短行该如实写「不知道」")
        }
    }

    /// 没有标签时什么都不做 —— 上游没开分人是正常情况,不该报错也不该写空行。
    func testNoTagsMeansNoWrites() throws {
        _ = try makeTranscript(lines: [(700, "一句话")])
        try ProcessingPump.writeClusterTags([:], now: now, trigger: .foreground, in: dbQueue)
        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM line_speakers"), 0)
        }
    }
}

import XCTest
import GRDB
@testable import GrowthApp

/// 2026-08-25 真机取证:**一个不朽任务把整条队列饿死了五天**。
///
/// 现场(拉库确认):任务 74(`transcribe` / 某场次)在 `running` 上活了五天、
/// `attempts` 始终 0;而今天那场录音的上传任务在它后面等了六小时、`attempts = 0`,
/// **一块音频都没传上去** —— 界面上就是一直「转写中」。
///
/// 三个缺陷叠在一起,而**每一个单独看都不报错**:
/// ① 抛穿 `tick` 的异常不记账 ⇒ `attempts` 不加 ⇒「烧到 dead」那道保险丝不通电;
/// ② `reclaimInterrupted`(`M2-B9`)把它每拍捡回来,而 `(priority, task_id)` 让它永远赢排序;
/// ③ 冻结不幂等 ⇒ 重跑撞 `UNIQUE(session_id, version, part)`。
final class StuckTaskStarvationTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-25T16:00:00+08:00"
    private var nowDate: Date { ISO8601DateFormatter.growth.date(from: now)! }

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            // ⚠️ `sessions` 上有 `UNIQUE(source, started_at)` —— 两场不能同一秒开始。
            for (i, id) in [7610, 2895].enumerated() {
                try db.execute(sql: """
                    INSERT INTO sessions (id, started_at, day, source, status)
                    VALUES (?, ?, '2026-08-25', ?, ?)
                    """, arguments: [id, "2026-08-25T1\(i):00:00+08:00",
                                     SessionBridge.Source.recording,
                                     SessionBridge.Status.closed])
            }
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    @discardableResult
    private func task(_ kind: String, _ session: Int64, state: String = "queued") throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (kind, session_id, attempts, state, priority, created_at)
                VALUES (?, ?, 0, ?, 0, ?)
                """, arguments: [kind, session, state, self.now])
            return db.lastInsertedRowID
        }
    }

    private func row(_ id: Int64) throws -> Row {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT state, attempts, next_retry_at FROM tasks WHERE task_id = ?",
                             arguments: [id])!
        }
    }

    // MARK: - 🔴 ① 抛出必须记账

    /// **任务被取走去跑,就必须以三种终态之一收场:done / 失败记账 / 明确让出。
    /// 「抛出」不是终态。**
    ///
    /// 这条钉住的是保险丝本身:抛出之后 `attempts` 必须加、`next_retry_at` 必须落。
    /// 不加的话「烧到 dead」永远不会发生 —— 那正是任务 74 活了五天的原因。
    func testAThrowingTaskGetsItsFailureRecorded() async throws {
        let id = try task(ProcessingOrchestrator.Kind.transcribe, 7610)
        let before = try row(id)
        XCTAssertEqual(before["attempts"] as Int, 0)

        // 造一个必抛的依赖:冻结时抛(与真机上那次 UNIQUE 冲突同形)
        var deps = Self.throwingDeps()
        deps.trigger = .foreground
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO asr_jobs (session_id, block_seq, remote_id, state, result_json,
                                      created_at, updated_at)
                VALUES (7610, 0, 'r0', 'done', '{}', ?, ?)
                """, arguments: [self.now, self.now])
        }

        do {
            _ = try await ProcessingOrchestrator.tick(now: nowDate, deps: deps, in: dbQueue)
            XCTFail("依赖是必抛的,tick 却没抛 —— 这条用例的前提没成立")
        } catch {
            // 预期:抛出去了(原异常不许被记账吞掉)
        }

        let after = try row(id)
        XCTAssertEqual(after["attempts"] as Int, 1,
                       "抛出之后 attempts 没加 —— 「烧到 dead」那道保险丝不通电,任务会永生")
        XCTAssertNotEqual(after["state"] as String, "running",
                          "抛出之后任务还留在 running —— 每一拍都会被 reclaim 捡回来重跑")
    }

    // MARK: - 🔴 ② 反复失败的任务不许饿死后面的

    /// 一条一直失败的任务,**必须让位**。
    ///
    /// 判据是**退避落到 `next_retry_at` 上** —— 有了它,`nextRunnable` 的
    /// `next_retry_at IS NULL OR <= now` 那一条就会跳过它,后面的任务才排得上。
    /// 没有退避的话,`(priority ASC, task_id ASC)` 让小号任务永远赢,
    /// 而新任务的 `attempts` 会一直停在 0(真机上就是这样,六小时零次尝试)。
    func testARepeatedlyFailingTaskStopsBlockingTheQueue() throws {
        let old = try task(ProcessingOrchestrator.Kind.transcribe, 7610)
        let fresh = try task(ProcessingOrchestrator.Kind.upload, 2895)
        XCTAssertLessThan(old, fresh, "前提:老任务号更小,所以它默认赢排序")

        // 老任务先赢
        XCTAssertEqual(try TaskQueue.nextRunnable(now: now, in: dbQueue), old)

        // 记一次失败之后,退避把它推到将来 ⇒ 该轮到新任务了
        _ = try TaskQueue.recordFailure(taskID: old, error: "撞唯一键", at: nowDate, in: dbQueue)
        XCTAssertNotNil(try row(old)["next_retry_at"] as String?,
                        "失败没落退避时刻 —— 它下一拍还会赢,后面的任务永远排不上")
        XCTAssertEqual(try TaskQueue.nextRunnable(now: now, in: dbQueue), fresh,
                       "老任务失败之后仍然挡在前面 —— 这就是今天那场录音六小时没上传的形状")
    }

    // MARK: - 🔴 ③ 已经冻结过的场次不许再冻一次

    /// 冻结层不可变,`transcripts` 上有 `UNIQUE(session_id, version, part)`。
    /// 任务在「冻结已写库」与「标 done」之间被打断,重跑必然撞唯一键。
    ///
    /// **判据是产物在不在,不是任务标没标完** —— 产物是事实,任务状态只是关于
    /// 事实的记账,而记账会丢(真机上就丢了五天)。
    func testAlreadyFrozenSessionIsNotFrozenAgain() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at)
                VALUES (7610, ?, ?, 'step-asr-v1', 'partial', ?)
                """, arguments: [TranscriptFreeze.firstVersion, TranscriptFreeze.firstPart, self.now])
        }
        // 再插一份同 (场次, 版本, 分片) —— 这正是重跑时会做的事
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at)
                VALUES (7610, ?, ?, 'step-asr-v1', 'frozen', ?)
                """, arguments: [TranscriptFreeze.firstVersion, TranscriptFreeze.firstPart, self.now])
        }, "唯一键没拦住 —— 那重跑就会写出第二份冻结层")
    }

    /// 首版号只有一个出处:`ProcessingOrchestrator` 查的与 `TranscriptFreeze` 写的
    /// 必须是同一个数。各写一个 `1` 的话,首版号一改就会**查一个版本、写另一个版本**
    /// —— 查不到、照插、照撞,而报出来的还是那句 `SQLite error 19`。
    func testTheFirstVersionHasASingleSource() {
        XCTAssertEqual(TranscriptFreeze.firstVersion, 1)
        XCTAssertEqual(TranscriptFreeze.firstPart, 1)
    }

    // MARK: - 造一个必抛的依赖

    /// 上传腿在这组用例里不是被测对象 —— 但 `transport` 不可空,
    /// 所以给一个**会抛**的,而不是一个假装成功的:假装成功会让
    /// 「上传失败」这条路径在这里静默通过。
    private struct NeverUploads: UploadTransport {
        struct Boom: Error {}
        func handOff(fileURL: URL, to key: String, tag: String,
                     trigger: ProcessingEvents.Trigger) throws { throw Boom() }
    }

    private static func throwingDeps() -> ProcessingOrchestrator.Dependencies {
        struct Boom: Error {}
        return .init(trigger: .foreground,
                     blocks: { _ in [] }, seconds: { _ in 0 },
                     reachability: { .wifi }, wifiOnly: false, audioExt: "m4a",
                     transport: NeverUploads(),
                     proxy: .init(baseURL: URL(string: "https://example.invalid")!, token: "t"),
                     submit: { _, _ in throw Boom() }, query: { _ in throw Boom() },
                     freeze: { _, _ in throw Boom() },
                     extract: { _ in throw Boom() })
    }
}

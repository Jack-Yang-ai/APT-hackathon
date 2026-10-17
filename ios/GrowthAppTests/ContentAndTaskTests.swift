import XCTest
import GRDB
@testable import GrowthApp

/// 内容层与任务表(M0-2e)。
final class ContentAndTaskTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-08T16:00:00+08:00"

    /// 失败发生的时刻。**与 `now` 同一个时钟,只晚一小时。**
    ///
    /// 🔴 **原来三处各写死一个 `2026-08-19`,而 `now` 是 08-08 —— 相差 11 天。**
    /// M1-30 ③ 之后期限按 `created_at` 的**真实差值**判(6 天),
    /// 于是那三条测试里的任务一失败就被判死,而它们想测的是别的事。
    /// ⇒ 收成一个出处。**夹具里混用两个时钟,现在是有后果的**
    /// (本仓在时间口径上栽过一次:2026-08-17 退避因时区串比较而整体失效)。
    private var base: Date { ISO8601DateFormatter.growth.date(from: now)!.addingTimeInterval(3600) }

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-08T14:00:00+08:00', '2026-08-08', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-08T15:00:00+08:00')
                """)
            for seq in 0..<3 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                    VALUES (?, 1, ?, 0, 1000, ?, 0)
                    """, arguments: [10 + seq, seq, "第\(seq)句"])
            }
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    /// `worker/extract.py` 的 `validate()` 交出来的形状:丢弃的已剔除、
    /// 挂起的带 pending、speaker_hint 已剥掉。
    ///
    /// ⚠️ 字段名照 **§4.2 契约**写,不照 DDL 列名写。`key_points` 的字段是 `point`,
    /// 落进去的列叫 `text` —— 这两个名字不一样。这里原先写的是 `text`,
    /// 与当时 `ExtractionStore` 的实现是同一个错误信念,所以测试一直绿;
    /// 直到 M0-12a 拿 `worker/extract.py` 的真产出跑端到端才炸出来。
    private var validatedPayload: [String: Any] {
        [
            "one_liner": "定了接口文档的交付时间,预算待确认",
            "key_points": [
                ["point": "周三交文档", "quote": "周三之前", "line_id": 10],
                ["point": "预算待确认", "quote": "跟财务确认", "line_id": 11, "pending": true],
            ],
            "commitments": [
                ["what": "交接口文档", "quote": "周三之前", "line_id": 10, "to_whom_text": "老王"],
            ],
            "stances": [
                ["stance": "对预算保留", "quote": "跟财务确认", "line_id": 11,
                 "premise": "如果预算不批", "premise_line_id": 12, "pending": true],
            ],
            "pendings": [
                ["issue": "预算没定", "quote": "跟财务确认", "line_id": 11,
                 "parties_text": ["老王", "小李"]],
            ],
            "topic_keys": [["key": "交付时间", "line_ids": [10]]],
        ]
    }

    // MARK: - 验收①:validate() 的产出落库再读回来,字段无损、挂起标记保留

    func testValidatedPayloadRoundTrips() throws {
        let stored = try ExtractionStore.store(validatedPayload, transcriptID: 1, now: now, in: dbQueue)
        XCTAssertEqual(stored, 5, "四类里一共 5 条")

        try dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT one_liner FROM summaries WHERE transcript_id = 1"),
                           "定了接口文档的交付时间,预算待确认")

            // 自由文本与逐字引文**分两列**存(判 4),没有混成一句
            let kp = try Row.fetchAll(db, sql: "SELECT text, quote, line_id, pending FROM summary_key_points ORDER BY seq")
            XCTAssertEqual(kp.map { $0["text"] as String }, ["周三交文档", "预算待确认"])
            XCTAssertEqual(kp.map { $0["quote"] as String }, ["周三之前", "跟财务确认"])
            XCTAssertEqual(kp.map { $0["line_id"] as Int64 }, [10, 11])
            XCTAssertEqual(kp.map { $0["pending"] as Int }, [0, 1], "挂起标记必须原样保留")

            let commit = try Row.fetchOne(db, sql: "SELECT what, to_whom_text FROM summary_commitments")
            XCTAssertEqual(commit?["what"] as String?, "交接口文档")
            XCTAssertEqual(commit?["to_whom_text"] as String?, "老王", "对谁承诺是文本线索,不是 person 外键")

            let stance = try Row.fetchOne(db, sql: "SELECT premise, premise_line_id, pending FROM summary_stances")
            XCTAssertEqual(stance?["premise"] as String?, "如果预算不批")
            XCTAssertEqual(stance?["premise_line_id"] as Int64?, 12)
            XCTAssertEqual(stance?["pending"] as Int?, 1)

            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT line_ids FROM summary_topic_keys"), "[10]")
        }
    }

    /// 钉住「JSON 字段名 ≠ DDL 列名」这件事。
    ///
    /// 拿 DDL 的列名(`text`)冒充契约字段名喂进来,必须**点名报缺 point** 而不是
    /// 报一句「NOT NULL constraint failed」。这条测试存在的理由就是上一次的教训:
    /// 实现和测试同时把这两个名字当成一回事,于是谁也发现不了。
    func testDDLColumnNameIsNotAcceptedAsContractFieldName() throws {
        var bad = validatedPayload
        bad["key_points"] = [["text": "拿列名冒充字段名", "quote": "周三之前", "line_id": 10]]
        XCTAssertThrowsError(try ExtractionStore.store(bad, transcriptID: 1, now: now, in: dbQueue)) {
            guard case ExtractionStore.Failure.missingField(let kind, let field) = $0 else {
                return XCTFail("应当点名缺哪个字段,实际抛的是 \($0)")
            }
            XCTAssertEqual(kind, "key_points")
            XCTAssertEqual(field, "point")
        }
    }

    /// 内容挂在不存在的行上 = 新造一批悬空引用,必须抛,且全回滚。
    func testUnknownLineIsRejectedAndRollsBack() throws {
        var bad = validatedPayload
        bad["key_points"] = [["point": "x", "quote": "y", "line_id": 999]]
        XCTAssertThrowsError(try ExtractionStore.store(bad, transcriptID: 1, now: now, in: dbQueue))

        let summaries = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summaries") ?? -1
        }
        XCTAssertEqual(summaries, 0, "抛了就该全回滚,不留半条 one_liner")
    }

    func testMissingOneLinerIsRejected() throws {
        var bad = validatedPayload
        bad.removeValue(forKey: "one_liner")
        XCTAssertThrowsError(try ExtractionStore.store(bad, transcriptID: 1, now: now, in: dbQueue))
    }

    // MARK: - 验收②:内容层建表 SQL 里没有「谁说的」

    /// 直接问库要建表语句来查,而不是查源文件——查的是**真落地的 schema**。
    func testNoAttributionColumnsInContentTables() throws {
        let tables = ["summaries", "summary_key_points", "summary_commitments",
                      "summary_stances", "summary_pendings", "summary_topic_keys"]
        try dbQueue.read { db in
            for table in tables {
                let columns = try db.columns(in: table).map { $0.name.lowercased() }
                for name in columns {
                    XCTAssertFalse(name == "who" || name.contains("speaker"),
                                   "\(table).\(name) 是归属字段,内容层不许有(铁律 3)")
                }
            }
        }
    }

    // MARK: - 验收③:退避序列与 dead 终态

    /// ⚠️ **同一件事的第二个出处**:`UploadTests.testBackoffSequenceFollowsSpec`
    /// 钉的是同一组常数。两条一起红是对的(改退避必须两处都看见),
    /// 但下次谁动这里,记得那边也有一条。
    func testBackoffFollowsTheSpecSequence() {
        // 2026-08-19 改:原为 [1, 5, 30, 120] 封顶 360(6h)。理由见 M1-21 与
        // `TaskQueue.backoffMinutes` 的注释 —— 6 小时封顶让「结束到出稿 ≤10 分钟」
        // 不可能成立,而这条链上的重试并不贵。
        XCTAssertEqual((1...4).map(TaskQueue.backoff(afterAttempt:)), [1, 5, 15, 30])
        XCTAssertEqual(TaskQueue.backoff(afterAttempt: 5), 30, "第五次起封顶 30 分钟")
        XCTAssertEqual(TaskQueue.backoff(afterAttempt: 99), 30)
    }

    /// ⚠️ **2026-08-17 改写:原来这条把字面量 `"...Z"` 钉死了,而那正是缺陷本身。**
    ///
    /// `next_retry_at` 与 `nextRunnable` 比的是**字符串**,所以两边的时区格式必须
    /// 一致。`recordFailure` 当时本地新建了一个没设时区的格式化器 ⇒ 写 UTC,
    /// 而比较用本地串 ⇒ `"04" < "11"` 恒成立 ⇒ **退避完全失效**。
    /// 这条测试当时是绿的,因为它照着实现抄了期望值。
    ///
    /// 现在断言的是**不变式**:退避的长度对、格式与全仓同一个口径。
    func testNextRetryAtIsComputedFromBackoff() throws {
        let taskID = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: now, in: dbQueue)
        let base = ISO8601DateFormatter.growth.date(from: "2026-08-09T00:00:00+08:00")!

        let first = try TaskQueue.recordFailure(taskID: taskID, error: "网络断了", at: base, in: dbQueue)
        XCTAssertEqual(first.state, "retrying")
        let t1 = try XCTUnwrap(first.nextRetryAt.flatMap(ISO8601DateFormatter.growth.date(from:)),
                               "解不回来 —— 和全仓不是一个口径:\(first.nextRetryAt ?? "nil")")
        XCTAssertEqual(t1.timeIntervalSince(base), 60, accuracy: 1, "第一次退避 1 分钟")

        let second = try TaskQueue.recordFailure(taskID: taskID, error: "又断了", at: base, in: dbQueue)
        let t2 = try XCTUnwrap(second.nextRetryAt.flatMap(ISO8601DateFormatter.growth.date(from:)))
        XCTAssertEqual(t2.timeIntervalSince(base), 300, accuracy: 1, "第二次退避 5 分钟")
    }

    func testAttemptsOverLimitBecomeDead() throws {
        let taskID = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: now, in: dbQueue)
        let base = ISO8601DateFormatter().date(from: "2026-08-08T16:00:00Z")!

        var last: (state: String, nextRetryAt: String?) = ("queued", nil)
        for _ in 1...TaskQueue.maxAttempts {
            last = try TaskQueue.recordFailure(taskID: taskID, error: "一直失败", at: base, in: dbQueue)
        }
        XCTAssertEqual(last.state, "dead")
        XCTAssertNil(last.nextRetryAt, "终态不再排下一次重试")

        // 失败原因留在表上。dead 却查不出为什么,跟静默丢单差不多。
        let err = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT last_error FROM tasks WHERE task_id = ?", arguments: [taskID])
        }
        XCTAssertEqual(err, "一直失败")
    }

    /// 🔴 **`progress` 走付费额度,不是 290 次**(`M2-审7`,2026-08-24)。
    ///
    /// `ProgressAttributionRunner.run` 是「先 `call`(花钱)、再 `parse`」——
    /// 与抽取一模一样的形状。模型输出恒定坏 JSON 是**确定性**失败:
    /// 同一份转写每次都触发,重试永远救不了,而**每一次都真买一遍**。
    ///
    /// 它漏在集合外的代价不是假设:`M2-认7` 记着某场次 的 progress 任务
    /// `attempts = 58`、**连崩 6 天**,期间每一拍都占一次 pump,
    /// 而界面上只是「还在处理」。
    ///
    /// ⚠️ 这条打的是**行为**(第 6 次就得是 dead);「谁该在集合里」那一问
    /// 由源码对撞 `eval/checks/test_paid_retry_kinds.py` 守着 ——
    /// 它管的是**将来新加的第三条付费腿**,而这条测试管不了。
    func testProgressUsesThePaidRetryBudgetNotTheOrdinaryOne() throws {
        let taskID = try TaskQueue.enqueue(kind: ProcessingOrchestrator.Kind.progress,
                                           sessionID: 1, now: now, in: dbQueue)
        let base = ISO8601DateFormatter().date(from: "2026-08-08T16:00:00Z")!

        var states: [String] = []
        for _ in 1...TaskQueue.maxAttemptsForPaidRetry {
            states.append(try TaskQueue.recordFailure(
                taskID: taskID, error: "模型输出不是约定的 JSON:{坏的", at: base,
                in: dbQueue).state)
        }
        XCTAssertEqual(states.last, "dead",
                       "恒定坏 JSON 跑满付费上限还没判死 —— 它会一路重试到 290 次,每次真花钱")
        XCTAssertEqual(states.dropLast().filter { $0 == "dead" }.count, 0,
                       "还没到上限就判死了,一次网络抖动会把整场进展判没:\(states)")

        // 上限本身必须比普通额度小得多 —— 相等的话上面那条断言是空的
        XCTAssertLessThan(TaskQueue.maxAttemptsForPaidRetry, TaskQueue.maxAttempts)
        XCTAssertEqual(TaskQueue.maxAttempts(forKind: ProcessingOrchestrator.Kind.progress),
                       TaskQueue.maxAttemptsForPaidRetry)
    }

    /// 次数没超但**真实**已经跑过总期限(6 天),同样落 dead。
    /// 两条判据取先到的那条——只看次数会在退避封顶后拖过音频保留期。
    func testDeadlineAlsoTerminates() {
        XCTAssertEqual(TaskQueue.stateAfterFailure(attempts: 1), "retrying")
        XCTAssertEqual(TaskQueue.stateAfterFailure(attempts: TaskQueue.maxAttempts), "dead")
        XCTAssertGreaterThanOrEqual(
            TaskQueue.cumulativeMinutes(through: TaskQueue.maxAttempts),
            TaskQueue.deadlineMinutes - TaskQueue.backoffCapMinutes,
            "上限次数应当刚好把 6 天期限填满,不多不少")
    }

    // MARK: - 期限按真实耗时判(M1-30 ③)

    /// 🔴 **判期限用 `created_at` 的差值,不用退避序列的模型值。**
    ///
    /// ~~上一版用 `cumulativeMinutes(through: attempts)`~~ —— 那只累加**等待**,
    /// 不含每一拍真实花掉的时间(网络 + 上游;长场次上一拍就是十几分钟)。
    /// 290 次的模型值是 5.99 天,**真实会显著晚于 6 天**。
    ///
    /// ⚠️ 而「6 天」这个数的**全部意义**是「比音频保留期短一天,留最后一次人工机会」——
    /// 晚过去之后**音频先被清掉**,那条「最后的人工机会」根本不存在,
    /// 而任务表上什么都不会显示。
    func testDeadlineIsJudgedByRealElapsedNotTheBackoffModel() throws {
        let taskID = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: now, in: dbQueue)
        // 把它的 created_at 挪到 6 天零 1 分钟以前。
        let born = Date(timeIntervalSince1970: 1_800_000_000)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tasks SET created_at = ? WHERE task_id = ?",
                           arguments: [ISO8601DateFormatter.growth.string(from: born), taskID])
        }
        let at = born.addingTimeInterval(Double(TaskQueue.deadlineMinutes + 1) * 60)
        let r = try TaskQueue.recordFailure(taskID: taskID, error: "一直失败", at: at, in: dbQueue)
        XCTAssertEqual(r.state, "dead", """
            真实已经跑了 6 天零 1 分钟,却还判 retrying —— 用的是退避序列的模型值。
            后果:音频先被清掉,而「留最后一次人工机会」那条前提就没了。
            """)
        // 照妖镜的另一半:同一条任务、同样 1 次失败,**只是没跑那么久** ⇒ 必须还活着,
        // 否则上面那条证明不了任何东西(说明是别的原因判死的)。
        // ⚠️ 复用 sessionID 1 —— 夹具里只建了这一场,外键挡着(它挡对了)。
        let fresh = try TaskQueue.enqueue(kind: "extract", sessionID: 1, now: now, in: dbQueue)
        let r2 = try TaskQueue.recordFailure(taskID: fresh, error: "刚失败", at: base, in: dbQueue)
        XCTAssertEqual(r2.state, "retrying")
    }

    /// `created_at` 读不出来时**只按次数判,而且要在 `last_error` 里说出来**。
    ///
    /// 静默退回模型值等于把这个 BUG 又藏回去 —— 表现是「这条任务比预期
    /// 晚了半天才判死」,而没有任何东西会报错。
    func testUnparseableCreatedAtSaysSoInsteadOfSilentlyFallingBack() throws {
        let taskID = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: now, in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tasks SET created_at = '不是时间' WHERE task_id = ?",
                           arguments: [taskID])
        }
        _ = try TaskQueue.recordFailure(taskID: taskID, error: "失败了", at: base, in: dbQueue)
        let err = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT last_error FROM tasks WHERE task_id = ?",
                                arguments: [taskID])
        }
        XCTAssertTrue(err?.contains("created_at 解析不了") == true, """
            算不出真实耗时却一声不吭 —— 那样期限又退回模型值了,而没人看得见。
            实际写的是:\(err ?? "nil")
            """)
    }

    // MARK: - 队列取任务

    /// §1.3 两级优先级:用户在等的 > 积压回补。
    func testUserWaitingTasksComeFirst() throws {
        try TaskQueue.enqueue(kind: "backfill", sessionID: 1, priority: 1, now: now, in: dbQueue)
        let urgent = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, priority: 0, now: now, in: dbQueue)
        XCTAssertEqual(try TaskQueue.nextRunnable(now: now, in: dbQueue), urgent)
    }

    /// 还没到重试时刻的任务不该被捡起来。
    ///
    /// ⚠️ 比较时刻**必须用同一个格式化器生成**,不能手写字面量 ——
    /// 手写的那一版恰好写成了 UTC,把「退避失效」这个缺陷测成了绿的(2026-08-17)。
    func testTaskNotDueIsNotPickedUp() throws {
        let taskID = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: now, in: dbQueue)
        let base = ISO8601DateFormatter.growth.date(from: "2026-08-09T00:00:00+08:00")!
        try TaskQueue.recordFailure(taskID: taskID, error: "x", at: base, in: dbQueue)

        let at = { (s: TimeInterval) in
            ISO8601DateFormatter.growth.string(from: base.addingTimeInterval(s))
        }
        XCTAssertNil(try TaskQueue.nextRunnable(now: at(30), in: dbQueue),
                     "退避还没到就被捡起来了 —— 失败任务会把整拍占满")
        XCTAssertEqual(try TaskQueue.nextRunnable(now: at(120), in: dbQueue), taskID)
    }

    // MARK: - 🔴 放行退避(2026-08-19)

    /// 打开 App / 点「再试一次」= 用户明确说「我在等」——
    /// 这时还让他对着一个 30 分钟的计时器,是拿一条防上游过载的规矩
    /// 去挡一个已经在场的人。
    func testReleaseBackoffMakesARetryingTaskRunnableNow() throws {
        let taskID = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, priority: 0,
                                           now: now, in: dbQueue)
        let base = self.base
        try TaskQueue.recordFailure(taskID: taskID, error: "网络抖了", at: base, in: dbQueue)
        let justAfter = ISO8601DateFormatter.growth.string(from: base.addingTimeInterval(1))
        XCTAssertNil(try TaskQueue.nextRunnable(now: justAfter, in: dbQueue),
                     "前提不成立:它压根没在退避")

        XCTAssertEqual(try TaskQueue.releaseBackoff(in: dbQueue), 1)
        XCTAssertEqual(try TaskQueue.nextRunnable(now: justAfter, in: dbQueue), taskID)
    }

    /// **attempts 不清零。** 它是 6 天总期限那条判据的一半 ——
    /// 清零等于让一条永远好不了的任务只要用户多点几次就永远不会 dead。
    func testReleaseBackoffKeepsAttempts() throws {
        let taskID = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, priority: 0,
                                           now: now, in: dbQueue)
        let base = self.base
        try TaskQueue.recordFailure(taskID: taskID, error: "x", at: base, in: dbQueue)
        try TaskQueue.recordFailure(taskID: taskID, error: "x", at: base, in: dbQueue)
        try TaskQueue.releaseBackoff(in: dbQueue)
        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT attempts FROM tasks"), 2)
        }
    }

    /// 只放行「用户在等的」。积压回补本来就该慢慢来;
    /// dead 是终态,放行它等于把一条已经判死的任务偷偷复活。
    func testReleaseBackoffLeavesBackfillAndDeadAlone() throws {
        let backfill = try TaskQueue.enqueue(kind: "backfill", sessionID: 1, priority: 1,
                                             now: now, in: dbQueue)
        let dying = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, priority: 0,
                                          now: now, in: dbQueue)
        let base = self.base
        try TaskQueue.recordFailure(taskID: backfill, error: "x", at: base, in: dbQueue)
        for _ in 1...TaskQueue.maxAttempts {
            try TaskQueue.recordFailure(taskID: dying, error: "x", at: base, in: dbQueue)
        }

        XCTAssertEqual(try TaskQueue.releaseBackoff(in: dbQueue), 0,
                       "放行动了不该动的行")
        let justAfter = ISO8601DateFormatter.growth.string(from: base.addingTimeInterval(1))
        XCTAssertNil(try TaskQueue.nextRunnable(now: justAfter, in: dbQueue))
    }

    /// dead 是终态,不再被捡起来重跑。
    func testDeadTasksAreNotPickedUp() throws {
        let taskID = try TaskQueue.enqueue(kind: "transcribe", sessionID: 1, now: now, in: dbQueue)
        let base = ISO8601DateFormatter().date(from: "2026-08-08T16:00:00Z")!
        for _ in 1...TaskQueue.maxAttempts {
            try TaskQueue.recordFailure(taskID: taskID, error: "x", at: base, in: dbQueue)
        }
        XCTAssertNil(try TaskQueue.nextRunnable(now: "2099-01-01T00:00:00Z", in: dbQueue))
    }
}

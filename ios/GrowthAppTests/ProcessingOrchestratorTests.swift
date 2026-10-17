import XCTest
import GRDB
@testable import GrowthApp

/// 结束录音 → 出稿的编排(M1-4)。
///
/// M1-4 的准入条件是「整条链路能从落盘状态恢复,不依赖 App 一直活着」,
/// 所以这组测试打的不是「happy path 跑得通」,而是:
///   · **重放会不会多花钱**(提交转写是花钱的动作)
///   · **断在任何一步能不能续上**(每一步之后杀掉,重来一遍要接着走)
///   · **失败会不会被当成成功**(闸不通过 / 一块转不出来 / 一块都没成)
final class ProcessingOrchestratorTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let t0 = Date(timeIntervalSince1970: 1_786_000_000)
    /// `t0` 的字符串形式。⚠️ 时间口径只有一个来源 —— 别在用例里另写一个
    /// (M1-30 ③ 刚因为夹具混用两个时钟打红过三条测试)。
    private var t0Iso: String { ISO8601DateFormatter.growth.string(from: t0) }

    /// 记下每一次真正打出去的网络动作 —— 花钱的那些必须能数出来。
    private final class Spy: UploadTransport, @unchecked Sendable {
        var uploads: [String] = []
        var submits: [String] = []
        var queries: [String] = []
        /// 每个 remote id 被查第几次时返回 done;默认第一次就 done。
        var doneAfter = 1
        var failSubmit = false
        var failUpload = false
        /// 只炸这几个键的提交。`failSubmit` 是「全炸」,而
        /// **「一块炸掉,别的块还走不走得下去」只有这个测得出来** ——
        /// 全炸时「继续下一块」和「立刻返回」的观测结果一模一样。
        var failSubmitKeys: Set<String> = []
        /// 只炸这几个 remote id 的查询。同理。
        var failQueryIDs: Set<String> = []
        /// 抽取:送出去的 prompt。**花钱的动作,必须能数出来。**
        var extracts: [String] = []
        var failExtract = false
        /// 默认回一份能过三项校验的产出:引文逐字取自下面 `insertTranscript` 写的行。
        var extractReply = """
        {"one_liner":"定了首页的事",
         "key_points":[{"point":"先定首页","quote":"先把首页定下来","line_id":101}],
         "commitments":[{"what":"给老王文档","quote":"把文档给老王","line_id":100,
                         "to_whom_text":"老王","speaker_hint":"说话人1"}],
         "stances":[],"pendings":[],"topic_keys":[],"action_protocol":"personal-actions/v1","personal_actions":[]}
        """

        /// ⚠️ 语义是**「交出去了」不是「传完了」**(M1-4c)。
        /// 结果由系统的回调写进 `upload_jobs`,这里用 `db` 立刻模拟那个回调 ——
        /// 真机上它会在几分钟后、甚至另一个进程里发生。
        /// 「交出去之后要多推一拍才看得到结果」这一点被完整保留,不作弊。
        var db: DatabaseQueue?
        /// 收到的 trigger 逐次记下来。**它是这一拍的真值**,
        /// 生产实现(`BackgroundUploadCenter.handOff`)拿它记 M1-4d 那两条事件。
        var triggers: [ProcessingEvents.Trigger] = []
        func handOff(fileURL: URL, to key: String, tag: String,
                     trigger: ProcessingEvents.Trigger) throws {
            triggers.append(trigger)
            if failUpload { throw NSError(domain: "spy", code: 1) }
            uploads.append(key)
            guard let db, let (s, b) = UploadJobStore.parse(tag: tag) else { return }
            try UploadJobStore.finish(sessionID: s, blockSeq: b, status: 200,
                                      now: ISO8601DateFormatter.growth.string(from: Date()),
                                      in: db)
        }
        func submit(_ key: String, _ seconds: Int) async throws -> String {
            if failSubmit || failSubmitKeys.contains(key) { throw NSError(domain: "spy", code: 2) }
            submits.append(key)
            return "remote-\(key)"
        }
        /// 让上游**永远**回同一个答案(M1-30 ②:一直回看不懂的报文 / 一直说还在算)。
        var queryReply: ProxyClient.QueryResult?
        func query(_ id: String) async throws -> ProxyClient.QueryResult {
            if failQueryIDs.contains(id) { throw NSError(domain: "spy", code: 5) }
            queries.append(id)
            if let fixed = queryReply { return fixed }
            return queries.filter { $0 == id }.count >= doneAfter
                ? .done(rawJSON: #"{"status":"SUCCESS"}"#) : .pending
        }
        func extract(_ prompt: String) async throws -> String {
            if failExtract { throw NSError(domain: "spy", code: 3) }
            extracts.append(prompt)
            return extractReply
        }
    }

    private var spy: Spy!
    private var frozenCalls: [(Int64, Int)] = []

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        spy = Spy()
        spy.db = dbQueue
        frozenCalls = []
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (1, '2026-08-14T10:00:00+08:00', '2026-08-14T10:30:00+08:00',
                        '2026-08-14', 'recording', 'closed')
                """)
        }
    }

    override func tearDownWithError() throws { dbQueue = nil; spy = nil }

    // MARK: - 等太久了要有出口(M1-30 ②)

    func testSlowPendingASRDoesNotStarveAlreadyQueuedExtract() async throws {
        let start = ISO8601DateFormatter.growth.string(from: t0)
        _ = try ASRJobStore.claim(sessionID: 1, blockSeq: 0, remoteID: "slow", now: start, in: dbQueue)
        let extract = try await dbQueue.write { d -> Int64 in
            try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES('transcribe',1,'queued',0,?),('extract',1,'queued',0,?)", arguments: [start, start])
            return d.lastInsertedRowID
        }
        var d = deps(blocks: [0], pollInterval: 1)
        d.query = { _ in try await Task.sleep(for: .milliseconds(1200)); return .pending }
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: d, in: dbQueue)
        XCTAssertEqual(try TaskQueue.nextRunnable(now: ISO8601DateFormatter.growth.string(from: t0.addingTimeInterval(1)), in: dbQueue), extract)
    }

    /// 🔴 **上游一直回「看不懂的报文」时,这一块必须有一条看得见的出口。**
    ///
    /// 不设的话:`.unknown` 按 pending 处理 ⇒ 任务回 `queued`、`attempts` 不加、
    /// **永不 dead** ⇒ 这一场永远停在「整理中」,而 `last_error` 每拍被覆盖。
    /// 本仓历史上出过两次这个形状。
    ///
    /// ⚠️ `.unknown` 尤其救不回来:它是「报文形状不认识」,同一份报文每拍都会
    /// 得到同一个结论 —— **重试永远不会成功**。而云代理那道 6 小时兜底只覆盖
    /// 「已提交但还没出结果」的,覆盖不到「出了结果但看不懂」的。
    func testAnUnparseableReplyEventuallyFailsTheBlock() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.queryReply = .unknown(body: "{\"什么\":\"都不认识\"}")
        _ = try await drain(deps())

        // 把这些块的提交时刻挪到超过等待上限之前。
        let born = ISO8601DateFormatter.growth.date(from: t0Iso)!
            .addingTimeInterval(-Double(ProcessingOrchestrator.asrStallMinutes + 1) * 60)
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE asr_jobs SET created_at = ?",
                           arguments: [ISO8601DateFormatter.growth.string(from: born)])
        }
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(), in: dbQueue)

        let states = try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT state FROM asr_jobs")
        }
        XCTAssertTrue(states.allSatisfy { $0 == "failed" }, """
            等过了上限还全都挂在 submitted —— 这一场会永远「整理中」,
            而 attempts 一次都不涨、永不 dead。实际:\(states)
            """)
        let why = try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT last_error FROM asr_jobs LIMIT 1")
        }
        XCTAssertTrue(why?.contains("报文看不懂") == true, """
            判失败了但没说清是哪种卡住 ——「上游还在算」与「报文看不懂」
            处置完全不同(后者重试永远救不了)。实际:\(why ?? "nil")
            """)
    }

    /// 反面:**没到上限就不许判死** —— 否则上一条证明不了任何东西。
    func testAFreshBlockIsNotGivenUpOn() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.queryReply = .unknown(body: "{}")
        _ = try await drain(deps())
        let states = try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT state FROM asr_jobs")
        }
        XCTAssertFalse(states.contains("failed"), "刚提交就被判死了 —— 上限形同虚设")
    }

    // MARK: - 进展归属是一种独立任务(M2-B3)

    /// 抽完就把进展排上,**而且和标完成在同一个事务里**。
    ///
    /// 分开写的话,抽取标了 done 而进展没排上的那一场会永远停在
    /// 「有纪要、事上没有进展」,**而任务表看起来一切正常**。
    func testExtractEnqueuesProgress() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        try await drain(deps())
        let kinds = try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM tasks ORDER BY task_id")
        }
        XCTAssertTrue(kinds.contains(ProcessingOrchestrator.Kind.progress), """
            抽完了却没排进展 —— 这一场会永远停在「有纪要、事上没有进展」,
            而任务表看起来一切正常。实际排上的:\(kinds)
            """)
    }

    /// 🔴 **进展与抽取是两行任务,各有各的 attempts。**
    ///
    /// 合成一个的话,进展失败的每一次重试都会**把抽取一起重跑** ——
    /// 而两者都花钱。`ExtractionRunner` 的去重只保证不重复落库,挡不住重复调用。
    /// 这个仓在「重放 = 重复付费」上栽过不止一次。
    func testProgressIsASeparateRowSoRetryingItDoesNotRerunExtraction() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        try await drain(deps())
        let rows = try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, state FROM tasks WHERE kind IN (?, ?)",
                             arguments: [ProcessingOrchestrator.Kind.extract,
                                         ProcessingOrchestrator.Kind.progress])
        }
        XCTAssertEqual(rows.count, 2, "抽取与进展该是两行,实得 \(rows.count) 行")
        let extract = rows.first { ($0["kind"] as String?) == ProcessingOrchestrator.Kind.extract }
        XCTAssertEqual(extract?["state"] as String?, "done", """
            抽取没停在 done —— 进展那条腿一旦重试,这一行会被一起重跑,而它花钱。
            """)
    }

    /// 没配云代理时进展**停在等配置**,不是失败 —— 与抽取同一条处置。
    /// 判成失败会白烧 attempts,而这一场其实一个字都还没错。
    func testProgressWithoutProxyParksInsteadOfFailing() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        try await drain(deps())
        var d = deps()
        d.progressCall = nil
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: d, in: dbQueue)
        let state = try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM tasks WHERE kind = ?",
                                arguments: [ProcessingOrchestrator.Kind.progress])
        }
        XCTAssertNotEqual(state, "dead", "没配云代理被判成了死任务 —— 那不是失败,是还没配")
    }

    private func deps(blocks: [Int] = [0, 1],
                      reachability: Reachability = .wifi,
                      wifiOnly: Bool = true,
                      trigger: ProcessingEvents.Trigger = .foreground,
                      pollInterval: TimeInterval = 0,
                      cloud: FakeCloud? = nil)
        -> ProcessingOrchestrator.Dependencies {
        .init(trigger: trigger,
              blocks: { _ in blocks.map {
                  PendingBlock(blockSeq: $0,
                               fileURL: URL(fileURLWithPath: "/tmp/b\($0).m4a"),
                               seconds: 300, offsetMs: $0 * 300_000, durationMs: 300_000) } },
              seconds: { _ in 300 },
              reachability: { reachability },
              wifiOnly: wifiOnly,
              audioExt: "m4a",
              transport: spy,
              proxy: .init(baseURL: URL(string: "https://example.invalid")!, token: "t"),
              submit: { [spy] in try await spy!.submit($0, $1) },
              query: { [spy] in try await spy!.query($0) },
              freeze: { [weak self] sid, jobs in
                  // **真写一份转写进库**,不是记一笔就返回 —— 抽取那一步要从库里
                  // 读行,给个假返回值的话「冻结 → 抽取」这一跳根本测不到。
                  try self?.insertTranscript(sessionID: sid)
                  self?.frozenCalls.append((sid, jobs.count))
                  return (lines: jobs.count * 10, status: "frozen")
              },
              extract: { [spy] in try await spy!.extract($0) },
              // 云端队列默认**不接** —— 老用例照旧走同步那条,行为一个字不变。
              enqueueExtract: cloud?.enqueue,
              fetchExtract: cloud?.fetch,
              // 认人在这些用例里一律「没有可判的行」:它不是被测对象,而不给的话
              // 会走 parkUntilConfigured,在 pollInterval=0 下把 maxSteps 吃光,
              // 抽取一步都排不到(第一版就是这么红的)。
              voiceprint: { _ in .noLines },
              pollInterval: pollInterval)
    }

    // MARK: - 云端抽取队列(M2-B8)

    func testVoiceprintPollingWaitsWithoutReportingFailureOrConsumingAttempts() async throws {
        let stamp = t0Iso
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES('voiceprint',1,'queued',0,?)", arguments: [stamp])
        }
        var d = deps(pollInterval: 30)
        var calls = 0
        d.voiceprint = { _ in calls += 1; return .waiting }
        let outcome = try await ProcessingOrchestrator.tick(now: t0, deps: d, in: dbQueue)
        if case .failed = outcome { XCTFail("正常声纹排队被报成失败：\(outcome)") }
        XCTAssertEqual(outcome, .waitingForVoiceprint(sessionID: 1))
        XCTAssertEqual(calls, 1)
        let early = try await ProcessingOrchestrator.tick(now: t0.addingTimeInterval(1), deps: d, in: dbQueue)
        XCTAssertEqual(early, .idle)
        _ = try await ProcessingOrchestrator.tick(now: t0.addingTimeInterval(31), deps: d, in: dbQueue)
        XCTAssertEqual(calls, 2)
        try await dbQueue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT state,attempts FROM tasks WHERE kind='voiceprint'"))
            XCTAssertEqual(row["state"] as String, "queued")
            XCTAssertEqual(row["attempts"] as Int, 0)
        }
    }

    /// 假的云端队列。`ready` 控制「抽完了没有」。
    private final class FakeCloud {
        var enqueued: [(key: Int64, part: Int)] = []
        var ready: [String: String] = [:]      // ticket → 产物
        var fetches = 0
        /// ⚠️ **ticket 由云端发,手机只是带着它回来**(`M2-审11`)。
        /// 这里照真契约模拟:`enqueue` 返回一张票,`fetch` 只认票 ——
        /// 手机自己拼键的那一版会在重装后撞上旧安装的产物。
        /// 云端发出去的票,按发出顺序。用例用它给产物找位置 ——
        /// **不许自己拼票**,那正是这次要修掉的形态。
        var tickets: [String] = []
        var enqueue: (Int64, Int, String) async throws -> String { { k, p, prompt in
            self.enqueued.append((k, p))
            let t = "\(k)-\(p)-\(abs(prompt.hashValue))"
            self.tickets.append(t)
            return t
        } }
        var fetch: (String) async throws -> String? { { ticket in
            self.fetches += 1
            return self.ready[ticket]
        } }

    }

    /// 🔴 **云端还在跑时,轮询不许算成失败。**
    ///
    /// 算成失败的话 `attempts` 每拍加一,一场抽取会被**自己的轮询**推向 dead ——
    /// 而那时的现场与「上游真的挂了」一模一样。任务要停在 `queued` 等下一拍。
    func testPollingTheCloudNeverCountsAsAFailure() async throws {
        let cloud = FakeCloud()                       // ready 空 = 还没抽完
        try await seedFrozenSessionWithExtractTask()
        for _ in 0..<3 {
            let outcome = try await ProcessingOrchestrator.tick(now: t0, deps: deps(cloud: cloud),
                                                               in: dbQueue)
            guard case .waitingForExtraction(sessionID: 1, transcriptID: _, part: 0) = outcome else {
                return XCTFail("正常轮询应是等待，不能显示成失败：\(outcome)")
            }
        }
        let row = try await dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT state, attempts, last_error FROM tasks WHERE kind = 'extract'
                """)
        }
        XCTAssertEqual(row?["state"] as String?, "queued", """
            云端还在跑,任务却不在 queued —— 下一拍捡不起来它就永远停在这儿了。
            """)
        XCTAssertEqual(row?["attempts"] as Int?, 0, """
            轮询被记成了失败:attempts = \(row?["attempts"] as Int? ?? -1)。
            每拍加一的话,一场抽取会被自己的轮询推向 dead。
            """)
        XCTAssertTrue((row?["last_error"] as String? ?? "").contains("云端"),
                      "没说清在等什么 —— 「等着」与「出事了」会长得一模一样")
    }

    /// 两阶段实际路径：等待时退避、空结果取回后正常完成；0 条事不等于失败。
    func testTwoStageWaitPollsLaterAndEmptyResultCompletes() async throws {
        let cloud = FakeCloud()
        try await seedFrozenSessionWithExtractTask()
        var d = deps(pollInterval: 30, cloud: cloud)
        d.enqueueExtractLines = { key, part, lines in
            let data = try JSONSerialization.data(withJSONObject: lines, options: [.sortedKeys])
            return try await cloud.enqueue(key, part, String(decoding: data, as: UTF8.self))
        }
        let waiting = try await ProcessingOrchestrator.tick(now: t0, deps: d, in: dbQueue)
        guard case .waitingForExtraction(sessionID: 1, transcriptID: _, part: 0) = waiting else {
            return XCTFail("两阶段没有正常等待：\(waiting)")
        }
        let early = try await ProcessingOrchestrator.tick(now: t0.addingTimeInterval(1), deps: d, in: dbQueue)
        XCTAssertEqual(early, .idle, "等待必须退避，不能连拍重跑")
        let ticket = try XCTUnwrap(cloud.tickets.first)
        let empty: [String: Any] = ["one_liner": "此段暂无可整理结果", "events": [],
            "key_points": [], "commitments": [], "stances": [], "pendings": [], "topic_keys": [],
            "pipeline_version": StreamContinuity.recipe, "action_protocol": ActionExtraction.protocolVersion, "personal_actions": []]
        cloud.ready[ticket] = String(decoding: try JSONSerialization.data(withJSONObject: empty), as: UTF8.self)
        let finished = try await ProcessingOrchestrator.tick(now: t0.addingTimeInterval(31), deps: d, in: dbQueue)
        XCTAssertEqual(finished, .extracted(sessionID: 1, items: 0, discarded: 0))
        try await dbQueue.read {
            XCTAssertEqual(try String.fetchOne($0, sql: "SELECT state FROM tasks WHERE kind='extract'"), "done")
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT attempts FROM tasks WHERE kind='extract'"), 0)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM summaries"), 1)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM summary_events"), 0)
        }
        XCTAssertEqual(Set(cloud.tickets).count, 1, "同一材料取回时应复用同一产物")
    }

    func testWholeSessionActionsWaitForStreamFinishAndReplayDoesNotRebuy() async throws {
        try insertTranscript(sessionID:1)
        try await dbQueue.write { db in
            try db.execute(sql:"UPDATE sessions SET status='open',source='watch' WHERE id=1")
            try db.execute(sql:"INSERT INTO stream_sessions(session_id,created_at) VALUES(1,'now')")
            try db.execute(sql:"INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(2,1,1,2,'test','frozen','now')")
            try db.execute(sql:"INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(103,2,0,3000,4000,'材料已经发完',0)")
            try db.execute(sql:"INSERT INTO summaries(transcript_id,one_liner,created_at) VALUES(1,'保留前片纪要','now'),(2,'保留后片纪要','now')")
            try db.execute(sql:"INSERT INTO tasks(kind,session_id,state,priority,created_at) VALUES('extract',1,'queued',0,'now')")
        }
        var requests = 0
        var d = deps()
        d.enqueueExtractLines = { _,_,lines in
            requests += 1
            XCTAssertEqual(lines.first?["action_only"] as? Bool,true)
            XCTAssertEqual(Set(lines.compactMap { ActionExtraction.integer($0["line_id"]) }),[100,101,102,103])
            return "whole-session"
        }
        d.fetchExtract = { _ in #"{"action_protocol":"personal-actions/v1","personal_actions":[]}"# }
        _ = try await ProcessingOrchestrator.tick(now:t0,deps:d,in:dbQueue)
        XCTAssertEqual(requests,0,"持续录音中不能每片重买一次整场行动识别")
        try await dbQueue.write { db in
            try db.execute(sql:"UPDATE sessions SET status='closed' WHERE id=1")
            try db.execute(sql:"UPDATE tasks SET state='queued' WHERE kind='extract'")
        }
        _ = try await ProcessingOrchestrator.tick(now:t0,deps:d,in:dbQueue)
        XCTAssertEqual(requests,0,"场次关闭但尾块未完成时仍要等收尾")
        try await dbQueue.write { db in
            try db.execute(sql:"UPDATE stream_sessions SET finished_at='now' WHERE session_id=1")
            try db.execute(sql:"UPDATE tasks SET state='queued' WHERE kind='extract'")
        }
        _ = try await ProcessingOrchestrator.tick(now:t0,deps:d,in:dbQueue)
        XCTAssertEqual(requests,1)
        let current = try await dbQueue.read { try ActionCandidateStore.isSessionCurrent(1,in:$0) }
        XCTAssertTrue(current)
        try await dbQueue.write { try $0.execute(sql:"UPDATE tasks SET state='queued' WHERE kind='extract'") }
        _ = try await ProcessingOrchestrator.tick(now:t0,deps:d,in:dbQueue)
        XCTAssertEqual(requests,1,"有效整场识别在任务重放后仍要复用")
        XCTAssertTrue(spy.extracts.isEmpty,"整场校准不能重抽旧纪要")
    }

    /// 云端抽完了就照常落库 —— 走队列不改变产物。
    func testAResultFromTheCloudLandsJustLikeALocalOne() async throws {
        let cloud = FakeCloud()
        try await seedFrozenSessionWithExtractTask()
        // 先跑一拍让它排队,拿到真实的键(键是 transcriptID,不是 sessionID)
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(cloud: cloud), in: dbQueue)
        XCTAssertEqual(cloud.enqueued.count, 1, "该排一块")
        // 🔴 **取下标前必须先解包。** 断言失败不中断执行,空数组上 `[0]`
        // 会让整个测试进程 SIGTRAP —— 崩掉的进程没有失败信息,
        // 而「排队没排上」与「测试跑挂了」长得一模一样(2026-08-24 真崩过)。
        // ⚠️ 键用 `tickets`(`M2-审11`):产物的键含只在云侧算的指纹,
        // 手机侧自己拼 "\(key)-0" 就是第二个出处,而对不上时永远取不到产物。
        cloud.ready[try XCTUnwrap(cloud.tickets.first, "一块都没排上,后面无从谈起")] =
            Spy().extractReply
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(cloud: cloud), in: dbQueue)
        let n = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summaries") ?? -1
        }
        XCTAssertEqual(n, 1, "云端给了产物却没落库")
    }

    /// 🔴 **队列的键是 `transcript_id`,不是 `session_id`。**
    ///
    /// 一场可能有多份转写(多 part)。拿场次做键的话,第二份的第 0 块会撞上
    /// 第一份第 0 块的产物 —— 而**撞上不报错**,只是把别人的纪要落到这一份头上。
    func testTheQueueKeyIsTheTranscriptNotTheSession() async throws {
        // 🔴 **先让两个 id 岔开。** 不岔开的话夹具里 transcript_id 恰好 = session_id,
        // 这条断言在这种夹具上**根本分不出来** —— 而分不出来的测试会一直绿着,
        // 直到真出现多 part 的场次把别人的纪要盖掉(那时它也不报错)。
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (900, 'x', '2026-08-21', 'recording', 'closed');
                INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at)
                VALUES (900, 1, 1, 'x', 'frozen', 'x');
                """)
        }
        let cloud = FakeCloud()
        let sessionID = try await seedFrozenSessionWithExtractTask()
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(cloud: cloud), in: dbQueue)
        let realTranscript = try await dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM transcripts WHERE session_id = ?",
                               arguments: [sessionID])
        }
        XCTAssertNotEqual(realTranscript, sessionID, "两个 id 没岔开,这条断言证明不了任何事")
        // 🔴 同上:先解包再取,别让空数组把进程崩掉。
        let firstKey = try XCTUnwrap(cloud.enqueued.first, "一块都没排上,队列键无从检验").key
        XCTAssertEqual(firstKey, realTranscript, """
            队列键不是 transcript_id —— 多 part 的场次会互相盖掉产物,而且不报错。
            """)
    }

    /// 造一份冻结好的转写:三行,分别覆盖「有归属」「归属未定」「占位行」。
    /// 行号写死是刻意的 —— `Spy.extractReply` 里的 `line_id` 指着它们。
    private func insertTranscript(sessionID: Int64, version: Int = 1, part: Int = 1) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (session_id, version, part, asr_model, status,
                                         created_at, frozen_at)
                VALUES (?, ?, ?, 'stepaudio-2.5-asr', 'frozen', 'now', 'now')
                """, arguments: [sessionID, version, part])
            let tid = db.lastInsertedRowID
            let rows: [(Int64, String, Int, Int64?, String?)] = [
                (100, "我周三之前把文档给老王,行吧", 0, 7, "说话人1"),
                (101, "先把首页定下来", 0, nil, "说话人2"),      // 归属未定 → 挂起
                (102, "这段没听清", 1, nil, nil),                // 占位行
            ]
            for (i, r) in rows.enumerated() {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?)
                    """, arguments: [r.0 + Int64(version - 1) * 1000, tid, i,
                                     i * 1000, i * 1000 + 900, r.1, r.2])
                if r.3 != nil || r.4 != nil {
                    try db.execute(sql: """
                        INSERT INTO line_speakers (line_id, person_id, cluster_tag, source, updated_at)
                        VALUES (?, ?, ?, '系统整理', 'now')
                        """, arguments: [r.0 + Int64(version - 1) * 1000, r.3, r.4])
                }
            }
        }
    }

    /// 造一场**已冻结、抽取任务排着**的场次,返回场次号。
    ///
    /// 走的是真链路(排队 → 上传 → 转写 → 冻结),而不是直接插一行任务 ——
    /// 直接插的话冻结那一步不会跑,库里就没有行,抽取无从谈起。
    /// ⚠️ 灌 deps 时**不给云端队列**:这一步要的是「抽取任务排到了」,
    /// 而不是「抽取跑完了」。
    @discardableResult
    private func seedFrozenSessionWithExtractTask() async throws -> Int64 {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        // 只推到抽取那一步之前:让上传/转写/冻结跑完,抽取留着。
        //
        // ⚠️ **判据必须是「抽取是下一个会被捡的」,不是「抽取已排队」**(M2-认8)。
        // 冻结时同时排了认人,而认人的 task_id 更小 ⇒ 只等「抽取已排队」的话,
        // 调用方的下一拍跑的是认人,`cloud.enqueued` 还是空 —— 第一版就是这么
        // 崩在 `cloud.enqueued[0]` 上的(Index out of range,而断言消息毫无线索)。
        for _ in 0..<10 {
            let next = try await dbQueue.read { db in
                try String.fetchOne(db, sql: """
                    SELECT kind FROM tasks
                     WHERE state IN ('queued', 'retrying') ORDER BY priority, task_id LIMIT 1
                    """)
            }
            if next == "extract" { break }
            _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(), in: dbQueue)
        }
        return 1
    }

    /// 跑到没有可跑的任务为止。**上限是防死循环的**,不是业务逻辑。
    @discardableResult
    private func drain(_ d: ProcessingOrchestrator.Dependencies,
                       max: Int = 16,
                       at: Date? = nil) async throws -> [ProcessingOrchestrator.Outcome] {
        var out: [ProcessingOrchestrator.Outcome] = []
        for _ in 0..<max {
            let o = try await ProcessingOrchestrator.tick(now: at ?? t0, deps: d, in: dbQueue)
            out.append(o)
            if o == .idle { break }
        }
        return out
    }

    // MARK: - 排队是幂等的

    /// 同一场排两次只有一个任务 —— 调用方会被重放,不能靠它记得只调一次。
    func testEnqueueingTheSameSessionTwiceMakesOneTask() throws {
        XCTAssertTrue(try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue))
        XCTAssertFalse(try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue))
        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks"), 1)
        }
    }

    // MARK: - 整条链

    func testFullChainUploadsSubmitsPollsAndFreezes() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        let outcomes = try await drain(deps())

        XCTAssertEqual(spy.uploads.count, 2, "两块都该传")
        XCTAssertEqual(spy.submits.count, 2, "两块都该提交")
        XCTAssertEqual(frozenCalls.map(\.1), [2], "该拿两块的结果冻结一次")
        XCTAssertTrue(outcomes.contains { if case .frozen = $0 { return true }; return false },
                      "整条链没走到冻结:\(outcomes)")
    }

    // MARK: - 🔴 重放不许多花钱

    /// **这条是这个编排最贵的不变量。**
    ///
    /// 把整条链跑完,再从头 drain 一遍(模拟 App 被杀之后重启续跑)——
    /// 第二遍**一次提交都不该再发**。提交是花钱的动作,而重放是常态。
    func testReplayingTheWholeChainDoesNotSubmitAgain() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        try await drain(deps())
        let submitsAfterFirstRun = spy.submits.count

        // 第二遍:任务表已经是终态,不该再有任何动作
        try await drain(deps())
        XCTAssertEqual(spy.submits.count, submitsAfterFirstRun,
                       "重放又提交了 \(spy.submits.count - submitsAfterFirstRun) 次 —— 那是白花的钱")
        XCTAssertEqual(frozenCalls.count, 1, "重放又冻结了一次")
    }

    /// 断在「提交完但还没轮询到」那一刻重启 —— 续跑不该重新提交。
    func testResumingAfterSubmitDoesNotResubmit() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.doneAfter = 99          // 永远 pending,停在轮询那一步

        for _ in 0..<4 { _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(),
                                                                   in: dbQueue) }
        let submitted = spy.submits.count
        XCTAssertEqual(submitted, 2, "两块该都提交出去了")

        // 「重启」:换一组全新的依赖,只有库是共享的
        spy.doneAfter = 1
        try await drain(deps())
        XCTAssertEqual(spy.submits.count, submitted, "续跑时又提交了一遍")
        XCTAssertEqual(frozenCalls.count, 1, "续上之后该走到冻结")
    }

    // MARK: - 🔴 边录边传(2026-08-19):录音期间就传、就提交,但绝不冻

    /// 把这一场设成「还在录」/「已封场」。
    private func setRecording(_ open: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sessions SET status = ? WHERE id = 1",
                           arguments: [open ? SessionBridge.Status.open
                                            : SessionBridge.Status.closed])
        }
    }

    private func taskState(_ kind: String) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM tasks WHERE kind = ? AND session_id = 1",
                                arguments: [kind])
        }
    }

    /// 还在录的场次:块该传、也该提交 —— 那是这件事的全部价值。
    /// **但绝不许冻结**:冻结不可回改,冻在半截就把这一场永久截断成前半段。
    func testARecordingSessionUploadsAndSubmitsButNeverFreezes() async throws {
        try setRecording(true)
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)

        // 两拍之间要隔一会儿,和真机一样:第一拍把块**交出去**,
        // 系统传完是在那之后;下一拍才看得到「传完了」并去提交。
        // (`pollInterval: 0` 会让上传任务每拍都到点,把转写任务饿死 ——
        //  真机上它 30 秒才到点一次,转写在同一次 pump 里就轮得到。)
        let d = deps(pollInterval: 30)
        try await drain(d)                                      // 交出去
        try await drain(d, at: t0.addingTimeInterval(60))        // 看到传完了 → 提交
        // 🔴 **第三拍不能省。** 少了它,轮询根本没跑到、每一块都还没拿到结果,
        // 于是「冻结」这一步压根没被走到 —— 那时候断言「没冻」是**恒真**的,
        // 把守卫整个拿掉测试照样绿(实测过)。要让它咬住,得先把这一场推到
        // 「每一块都有终态、就差冻」的那一刻。
        try await drain(d, at: t0.addingTimeInterval(120))       // 结果回来 → 到了冻结门口

        XCTAssertEqual(spy.uploads.count, 2, "还在录就该开始传 —— 否则整条链要等用户按结束")
        XCTAssertEqual(spy.submits.count, 2, "还在录就该开始提交 —— 传是省时间,提交是省等待")
        XCTAssertFalse(spy.queries.isEmpty, "前提不成立:结果都没轮询,谈不上会不会误冻")
        XCTAssertTrue(frozenCalls.isEmpty,
                      "还在录就冻结了 —— 后面切出来的块将来无处可去,而且不报错")
    }

    /// 上传任务在录音期间**不许标 done**。
    /// 标了就再也捡不起来,而后面切出来的块**永远没人传**。
    func testUploadTaskStaysAliveWhileRecording() async throws {
        try setRecording(true)
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        let d = deps(pollInterval: 30)
        try await drain(d)
        try await drain(d, at: t0.addingTimeInterval(60))

        let state = try await taskState(ProcessingOrchestrator.Kind.upload)
        XCTAssertNotEqual(state, "done",
                          "已知的块传完就把上传任务标 done 了 —— 后面的块再也没人管")
    }

    /// 封场之后才冻,而且真的冻得成(别把「不许冻」写成「永远不冻」)。
    func testFreezingHappensOnceTheSessionIsClosed() async throws {
        try setRecording(true)
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        let d = deps(pollInterval: 30)
        try await drain(d)
        try await drain(d, at: t0.addingTimeInterval(60))
        XCTAssertTrue(frozenCalls.isEmpty, "前提不成立:录音中就已经冻了")

        try setRecording(false)
        try await drain(d, at: t0.addingTimeInterval(120))
        try await drain(d, at: t0.addingTimeInterval(180))
        XCTAssertEqual(frozenCalls.map(\.1), [2], "封场之后仍然冻不了 —— 那就永远出不了稿")
    }

    /// 还在录、还一块都没切出来 —— **不许标死**。
    /// 第一块要 4.5–5.5 分钟才切出来,而边录边传意味着任务在那之前就排上了。
    func testARecordingSessionWithNoBlocksYetIsNotKilled() async throws {
        try setRecording(true)
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)

        _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(blocks: []), in: dbQueue)

        let state = try await taskState(ProcessingOrchestrator.Kind.upload)
        XCTAssertNotEqual(state, "dead",
                          "第一块还没切出来就把这一场判死了 —— 它的音频永远不会被传")
    }

    // MARK: - 🔴 一块炸掉不许炸掉整条(2026-08-19,M1-21 真机)

    /// 某场次 的形状:七块,炸在第 4 块。
    /// 改之前:第 4 块提交失败 → 整条任务 `recordFailure` 回退,
    /// **第 5/6/7 块从头到尾一次都没被提交过**。
    func testOneFailingBlockDoesNotStopTheOthers() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        let bad = R2Layout.audioKey(sessionID: 1, blockSeq: 1, ext: "m4a")
        spy.failSubmitKeys = [bad]

        try await drain(deps(blocks: [0, 1, 2, 3]))

        XCTAssertEqual(Set(spy.submits), [
            R2Layout.audioKey(sessionID: 1, blockSeq: 0, ext: "m4a"),
            R2Layout.audioKey(sessionID: 1, blockSeq: 2, ext: "m4a"),
            R2Layout.audioKey(sessionID: 1, blockSeq: 3, ext: "m4a"),
        ], "炸掉的那一块之后的块必须照样提交出去")
        XCTAssertFalse(spy.submits.contains(bad), "炸掉的那一块不该被记成提交成功")
    }

    /// 🔴 **已经算完的结果,不许被另一块的提交失败扣着。**
    ///
    /// 这是 （场次略） 真正贵的那一半:块 0/1/2 的转写**早就在云端躺着**
    /// (41 KB / 51 KB 的正文),而手机每一轮都先在块 3 上炸掉、
    /// 一次都没走到轮询那一步 —— 花过钱的结果一个字都取不回来。
    func testResultsAlreadyBackAreSavedEvenWhenAnotherBlockFails() async throws {
        // 块 1 一提交就炸;块 0 提交得出去,结果随后会回来
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.failSubmitKeys = [R2Layout.audioKey(sessionID: 1, blockSeq: 1, ext: "m4a")]
        try await drain(deps(blocks: [0, 1]))

        let before = try await dbQueue.read { try ASRJobStore.fetch($0, sessionID: 1,
                                                                    blockSeq: 0) }
        XCTAssertEqual(before?.state, .submitted,
                       "前提不成立:块 0 压根没提交出去,那就谈不上「结果被扣着」")

        // 退避到点之后的下一拍:块 1 照样炸,而块 0 的结果该照样落盘
        _ = try await ProcessingOrchestrator.tick(now: t0.addingTimeInterval(3600),
                                                  deps: deps(blocks: [0, 1]), in: dbQueue)

        let fetched = try await dbQueue.read { try ASRJobStore.fetch($0, sessionID: 1,
                                                                      blockSeq: 0) }
        let job0 = try XCTUnwrap(fetched)
        XCTAssertEqual(job0.state, .done,
                       "块 0 的结果已经回来了,却被块 1 的提交失败扣住没落盘")
        XCTAssertNotNil(job0.resultJSON, "落了个状态但没存报文,等于没取回来")
    }

    /// 一拍里炸了四块,`attempts` 只该加 **1**。
    ///
    /// 每块记一次的话,一次网络抖动就把 attempts 烧掉四次 ——
    /// 而 attempts 是「多久之后判死」那条判据的一半。
    func testManyFailuresInOneTickBurnOnlyOneAttempt() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.failSubmit = true                                  // 四块提交全炸
        try await drain(deps(blocks: [0, 1, 2, 3]))            // 上传跑完 → 转写那一拍

        let attempts = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT attempts FROM tasks WHERE kind = 'transcribe' AND session_id = 1
                """)
        }
        XCTAssertEqual(attempts, 1, "四块各记一次失败 —— 一次抖动烧掉四条命")
    }

    /// 🔴 **提交没成功的块必须挡住冻结。**
    ///
    /// 容错之后最危险的新形态:块 0 回来了、块 1 压根没提交出去,
    /// 此时「等结果的块」是空的 —— 看起来像「都齐了」。
    /// 真去冻结的话,这一场会**少一块音频落库,而且不报错**。
    func testABlockThatNeverGotSubmittedBlocksFreezing() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.failSubmitKeys = [R2Layout.audioKey(sessionID: 1, blockSeq: 1, ext: "m4a")]

        try await drain(deps(blocks: [0, 1]))
        // 让块 0 的结果回来:换一个更晚的时刻,绕过上一拍失败推的退避
        for _ in 0..<4 {
            _ = try await ProcessingOrchestrator.tick(now: t0.addingTimeInterval(3600),
                                                      deps: deps(blocks: [0, 1]), in: dbQueue)
        }

        let fetched = try await dbQueue.read { try ASRJobStore.fetch($0, sessionID: 1,
                                                                      blockSeq: 0) }
        let job0 = try XCTUnwrap(fetched)
        XCTAssertEqual(job0.state, .done, "前提不成立:块 0 的结果都没回来,谈不上会不会误冻")
        XCTAssertTrue(frozenCalls.isEmpty,
                      "块 1 从没提交出去,却把这一场冻结了 —— 那一块音频就这么没了,还不报错")
    }

    // MARK: - 失败不许被当成成功

    /// 闸不通过 = **还没到时候**,不是失败。
    /// attempts 不该加(加了会把任务推向 dead,而用户只是还没连 Wi-Fi)。
    func testCellularHoldIsNotAFailure() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        let o = try await ProcessingOrchestrator.tick(
            now: t0, deps: deps(reachability: .cellular, wifiOnly: true), in: dbQueue)

        guard case .held = o else { return XCTFail("蜂窝网被当成了失败:\(o)") }
        XCTAssertTrue(spy.uploads.isEmpty, "闸没拦住,已经传出去了")
        try await dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT attempts FROM tasks"), 0,
                           "没网被记成了一次失败 —— 几次之后任务会被推向 dead")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM tasks"),
                           "waiting_network")
        }
    }

    /// 一块转不出来 ≠ 整场失败。§3.1.6 允许缺块以 partial 落库,
    /// 所以失败记在**作业**上,不是记在任务上。
    func testOneFailedBlockDoesNotKillTheWholeSession() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        var d = deps()
        d.query = { id in
            id.hasSuffix("block-0001.m4a") ? .failed(reason: "audio_download")
                                           : .done(rawJSON: "{}")
        }
        try await drain(d)

        XCTAssertEqual(frozenCalls.map(\.1), [1], "该拿成功的那一块去冻结")
        try await dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT state FROM asr_jobs WHERE block_seq = 1
                """), "failed")
        }
    }

    /// 一块都没转出来 —— **不许冻结一份空转写**。
    /// 冻结是终态,空的冻上去之后用户看到的是「好了」而里面什么都没有。
    func testNothingTranscribedDoesNotFreezeAnEmptyTranscript() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        var d = deps()
        d.query = { _ in .failed(reason: "audio_download") }
        try await drain(d)

        XCTAssertTrue(frozenCalls.isEmpty, "一块都没成还冻结了 —— 那会是一份空的终态转写")
        try await dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT state FROM tasks WHERE kind = 'transcribe'
                """), "degraded")
        }
    }

    /// 一块音频都没有的场次:**标死并说清楚**,不许悄悄标 done ——
    /// 标 done 的话下游会等一份永远不来的转写。
    func testSessionWithNoBlocksIsMarkedDeadNotDone() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        let o = try await ProcessingOrchestrator.tick(now: t0, deps: deps(blocks: []),
                                                      in: dbQueue)
        guard case .failed = o else { return XCTFail("空场次没被判失败:\(o)") }
        try await dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM tasks"), "dead")
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT last_error FROM tasks"),
                            "标死了却没说为什么")
        }
    }

    /// 传失败要走任务表的退避,不是直接死。
    func testUploadFailureGoesThroughBackoffNotStraightToDead() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.failUpload = true
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(), in: dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT attempts FROM tasks"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM tasks"), "retrying")
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT next_retry_at FROM tasks"),
                            "没有下次重试时间 —— 这个任务再也不会被捡起来")
        }
    }

    /// 云代理没配时**不许悄悄跳过**,要留在表上等配好。
    func testUnconfiguredProxyLeavesTheTaskRetryable() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        // 上传要两拍:一拍交出去,一拍才看到系统回话说传完了(M1-4c 的语义)
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(), in: dbQueue)
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(), in: dbQueue)
        var d = deps()
        d.proxy = nil
        let o = try await ProcessingOrchestrator.tick(now: t0, deps: d, in: dbQueue)

        guard case .failed(_, let why) = o, why.contains("云代理") else {
            return XCTFail("没配云代理时的表现不对:\(o)")
        }
        XCTAssertTrue(spy.submits.isEmpty)
        try await dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT state FROM tasks WHERE kind = 'transcribe'
                """), "retrying", "该留着等配好,不是死掉")
        }
    }

    /// 🔴 **轮询抛异常不许把任务钉死在 `running`。**
    ///
    /// 任务在轮询前已置 `running`,而 `nextRunnable` 不捡 `running`;
    /// 抛出去又被 `ProcessingPump` 的 `try?` 吞掉 ⇒ 这一场永久卡住,
    /// **而任务表看起来还在干活**。手机上这是常态不是异常:
    /// 轮询要跑很多次,地铁、电梯、切网各一次就够。
    func testAThrowingPollDoesNotPinTheTaskInRunning() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        var d = deps()
        d.query = { _ in .pending }          // 先让它停在「已提交,等结果」
        try await drain(d)
        XCTAssertFalse(spy.submits.isEmpty, "前提不成立:还没提交就谈不上轮询")

        d.query = { _ in throw URLError(.notConnectedToInternet) }
        // ⚠️ **用 `try?`,断言看的是「任务有没有被钉住」,不是「有没有抛」。**
        // 生产里 `ProcessingPump` 的 `try?` 会把它吞掉 —— 所以「抛出来」在真机上
        // 等于「无声无息」,拿抛不抛当尺子会漏掉这个 BUG 的全部危害。
        _ = try? await ProcessingOrchestrator.tick(now: t0, deps: d, in: dbQueue)

        try await dbQueue.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: """
                SELECT state, attempts, next_retry_at, last_error FROM tasks
                 WHERE kind = 'transcribe'
                """))
            XCTAssertNotEqual(row["state"] as String, "running",
                              "任务钉死在 running —— 再也不会被捡起来")
            XCTAssertEqual(row["attempts"] as Int, 1)
            XCTAssertNotNil(row["next_retry_at"] as String?, "没有下次重试时间")
            XCTAssertNotNil(row["last_error"] as String?, "断网了却没说为什么")
        }
    }

    /// 🔴 **「没配」不许忙等。**
    ///
    /// 转写腿原先把 `next_retry_at` 置成 `iso`(**就是「现在」**),而
    /// `nextRunnable` 按 `priority, task_id` 排序、所有任务 priority 都是 0
    /// ⇒ 每一拍都选中它,一拍 12 步全砸在同一个任务上,
    /// **后面所有任务一次机会都排不到,而它永不 dead**。
    func testUnconfiguredProxyDoesNotStarveTheRestOfTheQueue() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (2, '2026-08-14T12:00:00+08:00', '2026-08-14T12:30:00+08:00',
                        '2026-08-14', 'recording', 'closed')
                """)
        }
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        var d = deps()
        d.query = { _ in .pending }
        // 两拍把某场次 推到「已提交,等结果」—— 它的转写任务此刻立刻可跑
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: d, in: dbQueue)
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: d, in: dbQueue)
        try ProcessingOrchestrator.enqueueSession(2, now: "x", in: dbQueue)

        // 退避要真的是一段时间 —— 默认夹具是 0,那样测不出忙等
        d.pollInterval = 60
        d.proxy = nil
        let parked = try await ProcessingOrchestrator.tick(now: t0, deps: d, in: dbQueue)
        guard case .failed(_, let why) = parked, why.contains("云代理") else {
            return XCTFail("没配云代理时的表现不对:\(parked)")
        }

        // 下一拍必须轮到别人 —— 这条才是这个 BUG 的本体。
        // ⚠️ 断言看的是**这一拍在为谁干活**,不是任务表的状态:
        // 上传任务交出去之后本来就还停在 `queued`(等系统回话),
        // 拿状态当尺子会把「排到了」误判成「没排到」。
        let next = try await ProcessingOrchestrator.tick(now: t0, deps: d, in: dbQueue)
        guard case .waitingForUpload(let sid, _) = next, sid == 2 else {
            return XCTFail("场次 2 一次机会都没排到 —— 队列被没配的那个任务霸占了:\(next)")
        }
    }

    // MARK: - 再试一次(M1-13d)

    /// 🔴 **验收:造一个 dead 任务,重跑起来,而且它真的往前走。**
    ///
    /// 「回到可跑状态」不够 —— 最常见的 degraded 是「一块都没转出来」,
    /// 而 `asr_jobs` 里那些 failed 行还在:提交那步看见有行就跳过、
    /// 轮询只捡 submitted、冻结拿不到 done ⇒ **原地又 degraded**。
    /// 所以这条一路跑到冻结,验的是结果不是状态。
    func testARetriedDeadSessionActuallyMovesForward() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        var d = deps()
        d.query = { _ in .failed(reason: "audio_download") }   // 每块都转不出来
        try await drain(d)
        XCTAssertTrue(frozenCalls.isEmpty, "前提不成立:一块都没成不该冻结")
        try await dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT state FROM tasks WHERE kind = 'transcribe'
                """), "degraded")
        }

        let r = try ProcessingOrchestrator.retrySession(1, now: "x", in: dbQueue)
        XCTAssertEqual(r.tasks, 1)
        XCTAssertEqual(r.resubmittedBlocks, 2, "失败的作业没清掉 —— 重试会原地打转")

        // 这次云端正常 —— 应当一路走到冻结
        try await drain(deps())
        XCTAssertEqual(frozenCalls.map(\.1), [2], "重试之后没有真的往前走")
    }

    /// 墓志铭要留下 —— 重置抹掉 attempts 与 last_error,
    /// 那之后「它当初为什么死的」就只剩事件表这一份。
    func testRetryLeavesAnEpitaphBehind() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(blocks: []), in: dbQueue)

        _ = try ProcessingOrchestrator.retrySession(1, now: "x", in: dbQueue)
        let detail = try await dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT detail FROM processing_events ORDER BY id DESC LIMIT 1
                """)
        }
        let lastError = try await dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT attempts, last_error FROM tasks")?["last_error"] as String?
        }
        XCTAssertNil(lastError, "重置该把 last_error 清掉,原因搬去事件表")
        XCTAssertTrue(detail?.contains("一块音频都没有") == true,
                      "死因没留下 —— 重置之后就再也查不到了:\(detail ?? "nil")")
    }

    /// 还在自己重试的任务:**放行,但不重置**。(2026-08-19 改)
    ///
    /// 原来这里是「一律不碰」,返回 0 并回一句「它还在自己重试,再等等」——
    /// 而「再等等」可能是六个小时(退避封顶)。用户按着一颗写着「再试一次」
    /// 的按钮,什么都不会发生。
    ///
    /// 现在放行退避(不花钱、不动 attempts),但**仍然不重置** ——
    /// 抹掉 attempts 会白花一次重新提交的钱,也会让一条永远好不了的任务
    /// 只要用户多点几次就永远不 dead。
    func testRetryReleasesBackoffButDoesNotResetARetryingTask() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.failUpload = true
        _ = try await ProcessingOrchestrator.tick(now: t0, deps: deps(), in: dbQueue)
        let iso = ISO8601DateFormatter.growth.string(from: t0)
        XCTAssertNil(try TaskQueue.nextRunnable(now: iso, in: dbQueue),
                     "前提不成立:它本来就没在退避,那放行就无从谈起")

        XCTAssertEqual(try ProcessingOrchestrator.retrySession(1, now: "x", in: dbQueue),
                       .init(tasks: 0, released: 1, resubmittedBlocks: 0))

        XCTAssertNotNil(try TaskQueue.nextRunnable(now: iso, in: dbQueue),
                        "放行之后它该当场可跑 —— 否则「再试一次」还是要等退避")
        try await dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT attempts FROM tasks"), 1,
                           "attempts 被抹了 —— 那条任务的退避历史没了")
        }
    }

    /// 没有可跑的任务时是 `.idle`,不是抛错也不是空转。
    func testEmptyQueueIsIdle() async throws {
        let o = try await ProcessingOrchestrator.tick(now: t0, deps: deps(), in: dbQueue)
        XCTAssertEqual(o, .idle)
    }

    // MARK: - 抽取(M1-4b)

    /// 整条链要走到**出稿**,不是停在冻结。
    func testChainReachesExtractionAndStoresASummary() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        let outcomes = try await drain(deps())

        XCTAssertEqual(spy.extracts.count, 1, "该抽一次:\(outcomes)")
        XCTAssertTrue(outcomes.contains { if case .extracted = $0 { return true }; return false },
                      "链路没走到抽取:\(outcomes)")
        try await dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summaries"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT one_liner FROM summaries"),
                           "定了首页的事")
            // 归属未定的那条**留着并带挂起标记**,不是被丢掉等重抽
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT pending FROM summary_key_points WHERE line_id = 101
                """), 1, "归属未定的条目该挂起,不该丢")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT pending FROM summary_commitments WHERE line_id = 100
                """), 0)
        }
    }

    /// 送出去的 prompt 里必须有真的转写行 —— 少了它模型抽的是空气。
    func testThePromptCarriesTheRealTranscript() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        try await drain(deps())
        let prompt = try XCTUnwrap(spy.extracts.first)
        XCTAssertTrue(prompt.contains("100 | 说话人1 | 我周三之前把文档给老王,行吧"), prompt.suffix(200).description)
        XCTAssertTrue(prompt.contains("101 | 说话人2 | 先把首页定下来"))
        // 没有归属的行也要出现 —— 用内连接的话它们会整个消失,
        // 而模型看不到的内容不会被抽出来(一种「少抽了但没人知道」的静默丢失)
        XCTAssertTrue(prompt.contains("102 | 未分人 | 这段没听清"))
    }

    /// 🔴 **抽取比转写贵得多,重放绝不许再抽一次。**
    func testReplayingDoesNotExtractAgain() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        try await drain(deps())
        XCTAssertEqual(spy.extracts.count, 1)

        try await drain(deps())
        XCTAssertEqual(spy.extracts.count, 1, "重放又抽了一次 —— 那是白花的钱")
        try await dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summaries"), 1)
        }
    }

    /// 抽取任务**被强行重排**也不能再花一次钱 —— 去重靠 `summaries` 主键这个
    /// 库里的事实,不靠任务表的状态(任务表可能被手工重置、被迁移改写)。
    func testRequeuedExtractionStillSkipsWhenSummaryExists() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        try await drain(deps())

        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE tasks SET state = 'queued', attempts = 0, next_retry_at = NULL
                 WHERE kind = 'extract'
                """)
        }
        try await drain(deps())
        XCTAssertEqual(spy.extracts.count, 1, "任务被重排就又抽了一次 —— 去重不该依赖任务状态")
    }

    /// 抽取失败走退避,**不许标 done** —— 标 done 的话这一场永远停在
    /// 「有逐字稿、没纪要」,而任务表看起来一切正常。
    func testExtractionFailureGoesThroughBackoff() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.failExtract = true
        try await drain(deps())

        try await dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT state FROM tasks WHERE kind = 'extract'
                """), "retrying")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summaries"), 0,
                           "抽失败了却落了一份纪要")
        }
    }

    /// 模型回一份**结构不合契约**的产出 —— 必须失败,不许当成「这场没抽到内容」。
    func testMalformedModelOutputFailsInsteadOfStoringNothing() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.extractReply = #"{"one_liner":"缺了几类数组"}"#
        try await drain(deps())

        try await dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summaries"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT state FROM tasks WHERE kind = 'extract'
                """), "retrying", "结构不合契约被当成了「没内容」")
            let err = try String.fetchOne(db, sql: """
                SELECT last_error FROM tasks WHERE kind = 'extract'
                """)
            XCTAssertNotNil(err, "失败了却没记原因")
        }
    }

    /// 被截断的输出(空正文 / 半截 JSON)同样必须失败。
    /// §4.2 明列:「输出被截断」和「这场没内容」在下游看起来一模一样,而前者要重试。
    func testTruncatedModelOutputFails() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.extractReply = #"{"one_liner":"被切一半","key_poin"#
        try await drain(deps())
        try await dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summaries"), 0)
        }
    }

    /// 编造引文的条目**不许落库**,而且丢了几条要报出来。
    func testFabricatedQuotesAreDiscardedAndCounted() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        spy.extractReply = """
        {"one_liner":"两条编的一条真的",
         "key_points":[{"point":"编的","quote":"这句话原文里根本没有","line_id":100},
                       {"point":"挂占位行","quote":"这段没听清","line_id":102},
                       {"point":"真的","quote":"先把首页定下来","line_id":101}],
         "commitments":[],"stances":[],"pendings":[],"topic_keys":[],"action_protocol":"personal-actions/v1","personal_actions":[]}
        """
        let outcomes = try await drain(deps())

        guard let last = outcomes.first(where: {
            if case .extracted = $0 { return true }; return false
        }), case .extracted(_, let items, let discarded) = last else {
            return XCTFail("没走到抽取:\(outcomes)")
        }
        XCTAssertEqual(items, 1, "只有一条该落库")
        XCTAssertEqual(discarded, 2, "丢了 2 条却没报出来 —— 静默丢弃正是要防的")
        try await dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summary_key_points"), 1)
        }
    }

    /// 云代理没配时抽取任务**留在表上等**,不标死也不悄悄跳过。
    func testUnconfiguredProxyLeavesExtractionRetryable() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        try await drain(deps())              // 先把链跑到抽取
        try await dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM summaries;
                UPDATE tasks SET state = 'queued', next_retry_at = NULL WHERE kind = 'extract'
                """)
        }
        var d = deps()
        d.extract = nil
        let o = try await ProcessingOrchestrator.tick(now: t0, deps: d, in: dbQueue)

        guard case .failed(_, let why) = o, why.contains("云代理") else {
            return XCTFail("没配云代理时抽取的表现不对:\(o)")
        }
        try await dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT state FROM tasks WHERE kind = 'extract'
                """), "retrying", "该留着等配好,不是死掉")
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT attempts FROM tasks WHERE kind = 'extract'
                """), 0, "没配当成了一次失败 —— 几次之后任务会被推向 dead")
        }
    }

    /// 一块都没转出来 → 没有转写 → **不许排抽取**。
    /// 排了的话会去抽一份不存在的转写,而那笔钱花得毫无意义。
    func testNoTranscriptMeansNoExtractionTask() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        var d = deps()
        d.query = { _ in .failed(reason: "audio_download") }
        try await drain(d)

        XCTAssertTrue(spy.extracts.isEmpty, "没有转写却抽了一次")
        try await dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tasks WHERE kind = 'extract'
                """), 0)
        }
    }
}

// MARK: - 🔴 「看不懂」不能和「还在跑」共用一个态(2026-08-17)

extension ProcessingOrchestratorTests {

    /// 报文形状变了、或者字段名传错时,回来的东西认不出来 —— 原来一律当 pending,
    /// 于是**永远还在跑**,而任务表、界面、日志全都一切正常。
    /// 实测:一段几十秒的音频提交十一分钟、问过四次,状态纹丝不动,
    /// 而没有任何地方说得出为什么。
    func testUnrecognizedQueryResponseIsRecordedInsteadOfSilentlyWaiting() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        var d = deps()
        d.query = { _ in .unknown(body: #"{"code":40001,"msg":"task not found"}"#) }
        try await drain(d)

        try await dbQueue.read { db in
            let err = try String.fetchOne(db, sql: """
                SELECT last_error FROM tasks WHERE kind = 'transcribe'
                """)
            XCTAssertNotNil(err, "看不懂的报文被静默吞了 —— 这一场会一直「还在跑」到超期")
            XCTAssertTrue(err?.contains("task not found") == true,
                          "留痕了但没把原文带出来,等于只说了「有问题」:\(err ?? "nil")")
        }
    }

    /// 但**状态不能动**:看不懂 ≠ 失败。当成失败会烧 attempts,几次之后
    /// 任务落 dead,而上游可能只是回了个我们没见过的中间态。
    func testUnrecognizedResponseDoesNotBurnRetries() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        var d = deps()
        d.query = { _ in .unknown(body: "???") }
        try await drain(d)

        try await dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT attempts FROM tasks WHERE kind = 'transcribe'
                """), 0, "看不懂被记成了失败 —— 几次之后任务会被推向 dead")
        }
        XCTAssertTrue(frozenCalls.isEmpty, "看不懂却冻结了 —— 那会是一份空的终态转写")
    }

    /// 明确说「还在跑」的那些状态串**不留痕** —— 一天几百次正常轮询,
    /// 每次都记一条会把真正的异常淹掉。
    func testKnownPendingStatusesAreNotRecordedAsProblems() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        var d = deps()
        d.query = { _ in .pending }
        try await drain(d)

        try await dbQueue.read { db in
            XCTAssertNil(try String.fetchOne(db, sql: """
                SELECT last_error FROM tasks WHERE kind = 'transcribe'
                """), "正常轮询也留痕了 —— 真出问题时会被淹掉")
        }
    }
}

// MARK: - 🔴 「转写回来了但一行都没有」不许当成功(2026-08-17)

extension ProcessingOrchestratorTests {

    /// `done.isEmpty` 那一条挡的是「一块都没转出来」;这一条挡它的孪生兄弟:
    /// **块都「成功」了,加起来零行**。对用户是同一件事 —— 界面显示「好了」,
    /// 点进去什么都没有 —— 而后者在任务表上看起来完全正常。
    ///
    /// 实测正在发生:m4a 冒充 mp3 送检,StepFun 返回 `result:[{}]`,五块全是。
    func testZeroLineFreezeIsDegradedNotDone() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        var d = deps()
        d.freeze = { [weak self] sid, _ in
            try self?.insertTranscript(sessionID: sid)
            return (lines: 0, status: "frozen")     // 块都成功了,加起来零行
        }
        try await drain(d)

        try await dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT state FROM tasks WHERE kind = 'transcribe'
                """), "degraded", "零行的转写被标成了 done —— 用户会看到「好了」而里面什么都没有")
            XCTAssertNotNil(try String.fetchOne(db, sql: """
                SELECT last_error FROM tasks WHERE kind = 'transcribe'
                """), "标降级了却没说为什么")
        }
    }

    /// 有行的正常路径**不能**被这条误伤。
    func testNonEmptyFreezeStaysDone() async throws {
        try ProcessingOrchestrator.enqueueSession(1, now: "x", in: dbQueue)
        try await drain(deps())
        try await dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: """
                SELECT state FROM tasks WHERE kind = 'transcribe'
                """), "done")
        }
    }
}

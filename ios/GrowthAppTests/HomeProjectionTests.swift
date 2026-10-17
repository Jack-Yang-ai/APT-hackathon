import XCTest
import GRDB
@testable import GrowthApp

/// 首页展示模型与投影(PRD §4.2.2)。
final class HomeProjectionTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }

    override func tearDownWithError() throws { dbQueue = nil }

    /// 一场 = 一个 session + 一个 transcript + 若干行。
    private func seedSession(id: Int64,
                             day: String,
                             startedAt: String,
                             status: String = "frozen",
                             lines: [(seq: Int, endMs: Int, text: String, isGap: Int)]) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (?, ?, ?, 'recording', 'closed')
                """, arguments: [id, startedAt, day])
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (?, ?, 1, 1, 'step-asr-v1', ?, ?)
                """, arguments: [id, id, status, startedAt])
            for l in lines {
                try db.execute(sql: """
                    INSERT INTO transcript_lines (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                    VALUES (?, ?, ?, ?, ?, 0, ?)
                    """, arguments: [id, l.seq, max(0, l.endMs - 1000), l.endMs, l.text, l.isGap])
            }
        }
    }

    func testAllSemanticEventsRemainVisibleBeyondTwelveAndCalendarMatches() throws {
        try seedSession(id:1,day:"2026-10-14",startedAt:"2026-10-14T10:00:00+08:00",lines:[(0,3000,"有一件事",0)])
        try seedSession(id:2,day:"2026-10-13",startedAt:"2026-10-13T10:00:00+08:00",lines:[(0,3000,"只有原话没有事件",0)])
        try dbQueue.write { d in
            let line=try Int64.fetchOne(d,sql:"SELECT line_id FROM transcript_lines WHERE transcript_id=1")!
            for seq in 0..<15 {
                try d.execute(sql:"INSERT INTO summary_events(transcript_id,seq,title,summary,first_line_id,last_line_id) VALUES(1,?,'事件','摘要',?,?)",arguments:[seq,line,line])
            }
        }
        XCTAssertEqual(try HomeProjection.understoodEvents(day:"2026-10-14",in:dbQueue).count,15)
        XCTAssertEqual(try HomeProjection.eventDays(in:dbQueue),["2026-10-14"])
        try dbQueue.write { d in
            try d.execute(sql:"INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(3,1,2,1,'test','frozen','now')")
        }
        XCTAssertTrue(try HomeProjection.understoodEvents(day:"2026-10-14",in:dbQueue).isEmpty)
        XCTAssertTrue(try HomeProjection.eventDays(in:dbQueue).isEmpty,"旧版本事件不能让日历继续亮点")
    }

    func testTombstonedTailDoesNotMakeAnOlderEventAppearMostRecent() throws {
        try seedSession(id:1,day:"2026-10-14",startedAt:"2026-10-14T10:00:00+08:00",lines:[(0,1000,"有效首段",0),(1,6000000,"删掉的尾段首句",0),(2,7200000,"尾段剩余句",0)])
        try seedSession(id:2,day:"2026-10-14",startedAt:"2026-10-14T11:00:00+08:00",lines:[(0,1000,"较新事件",0)])
        let deleted=try dbQueue.write { d -> Int64 in
            let ids=try Int64.fetchAll(d,sql:"SELECT line_id FROM transcript_lines WHERE transcript_id=1 ORDER BY seq")
            try d.execute(sql:"INSERT INTO summary_events(transcript_id,seq,title,summary,first_line_id,last_line_id) VALUES(1,0,'首段','有效事件',?,?)",arguments:[ids[0],ids[0]])
            let root=d.lastInsertedRowID
            try d.execute(sql:"INSERT INTO summary_events(transcript_id,seq,title,summary,first_line_id,last_line_id,continuation_id) VALUES(1,1,'尾段','要删除的片段',?,?,?)",arguments:[ids[1],ids[2],root])
            let other=try Int64.fetchOne(d,sql:"SELECT line_id FROM transcript_lines WHERE transcript_id=2")!
            try d.execute(sql:"INSERT INTO summary_events(transcript_id,seq,title,summary,first_line_id,last_line_id) VALUES(2,0,'较新事件','新事件',?,?)",arguments:[other,other])
            return ids[1]
        }
        _ = try MemoryRemoval.removeLines([deleted],audioFiles:[],in:dbQueue)
        let events=try HomeProjection.understoodEvents(day:"2026-10-14",in:dbQueue)
        XCTAssertEqual(events.map(\.sessionID),[2,1])
        XCTAssertEqual(events.last?.latestMillis,1000)
    }

    private func summary(_ title: String, points: Int = 2) -> SessionSummary {
        SessionSummary(
            title: title,
            oneLiner: "对方对交付时间有顾虑",
            keyPoints: (0..<points).map {
                KeyPoint(text: "要点\($0)", quote: "原话\($0)", lineID: Int64(100 + $0), atMillis: $0 * 1000)
            }
        )
    }

    // MARK: - 🔴 重整之后,首页卡不许还读旧那一版

    func testLaterDoneTaskCannotHideEarlierExtractFailure() throws {
        try seedSession(id: 1, day: "2026-08-08", startedAt: "2026-08-08T12:08:40+08:00", lines: [(0, 3000, "还有后片没理解", 0)])
        try dbQueue.write { d in
            try d.execute(sql: "INSERT INTO tasks(kind,session_id,state,created_at,attempts) VALUES('extract',1,'dead','x',5),('voiceprint',1,'done','y',0)")
        }
        let feed = try HomeProjection.homeFeed(day: "2026-08-08", summaries: [1: summary("前半片")], in: dbQueue)
        XCTAssertEqual(feed.todayCards.first?.state, .failed(attempt: 5, willRetry: false))
        XCTAssertEqual(feed.digest?.brokenSessionIDs, [1])
    }

    /// 场次真实 155 秒;旧版(v1)的行因为 `M1-13a` 那个 BUG 落在 1800 秒;
    /// 重整出 v2 之后行落回 155 秒。**卡上的时长必须是 155 秒,不是 30 分钟。**
    ///
    /// 冻结层只增不改(§3.1.4)⇒ 旧那版的坏行**永远留在库里**。
    /// 而首页那个时长是用户判断「修好没有」的**唯一可见信号** ——
    /// 跨版本取 `MAX(t_end_ms)` 的后果是:事件表说「重整好了」、
    /// `TimelineAudit` 也不再报它,而首页照旧显示 30 分钟。
    /// 三处齐声说好、用户看到的症状原样不动,这是本仓最贵的失败形态。
    ///
    /// (2026-08-18:`M1-13b-1` 收活时由子 Agent 在它够不着的文件里发现 ——
    ///  它自己那条修复的成效正好被这个 BUG 吃掉。)
    func testTheCardReadsOnlyTheActiveVersionAfterARefreeze() throws {
        try seedSession(id: 1, day: "2026-08-08", startedAt: "2026-08-08T12:08:40+08:00", lines: [
            (seq: 0, endMs: 1_800_000, text: "旧那版落在一个不存在的时刻", isGap: 0),
        ])
        // v2:同一场次的新一版,行落回真实位置
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (2, 1, 2, 1, 'step-asr-v1', 'frozen', '2026-08-08T12:20:00+08:00')
                """)
            try db.execute(sql: """
                INSERT INTO transcript_lines (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                VALUES (2, 0, 154000, 155000, '重整之后落回来了', 0, 0)
                """)
        }

        let feed = try HomeProjection.homeFeed(day: "2026-08-08",
                                               summaries: [:], in: dbQueue)
        let card = try XCTUnwrap(feed.todayCards.first)
        XCTAssertEqual(card.durationMinutes, 2,
                       "首页卡跨版本取了 MAX(t_end_ms) —— 重整已经修好了,"
                       + "而用户在卡上看到的还是坏那版的 30 分钟,"
                       + "他没有任何办法知道修复其实生效了")
    }

    // MARK: - 验收:一场 + 两行(含一条 is_gap=1)投影出场次卡

    func testProjectsSessionCardFromFrozenLayer() throws {
        // 14:00 起,两行:正常行到 5s,占位行到 40 分钟
        try seedSession(id: 1, day: "2026-08-08", startedAt: "2026-08-08T14:00:00+08:00", lines: [
            (seq: 0, endMs: 5_000,     text: "今天下午三点开会讨论预算", isGap: 0),
            (seq: 1, endMs: 2_400_000, text: "〔此处缺失 30 秒〕",       isGap: 1),
        ])

        let feed = try HomeProjection.homeFeed(day: "2026-08-08",
                                               summaries: [1: summary("与同事一对一")],
                                               in: dbQueue)

        XCTAssertEqual(feed.todayCards.count, 1)
        let card = try XCTUnwrap(feed.todayCards.first)

        // 卡面元素逐个对 PRD §4.2.2:时间 · 标题 · 时长 · 一句话 · 要点
        XCTAssertEqual(card.startTime, "14:00")
        XCTAssertEqual(card.durationMinutes, 40)
        XCTAssertEqual(card.state, .done(summary("与同事一对一")))
        XCTAssertEqual(card.state.summary?.title, "与同事一对一")
        XCTAssertEqual(card.state.summary?.oneLiner, "对方对交付时间有顾虑")
        XCTAssertEqual(card.state.summary?.keyPoints.count, 2)

        // M1 只预留容器位,不产出内容
        XCTAssertEqual(card.attachments, .none)
    }

    /// 占位行不该作为内容出现在卡面上——卡面只认纪要里的要点,
    /// 而占位行按契约压根进不了抽取(A6)。
    func testGapLineNeverAppearsOnCard() throws {
        try seedSession(id: 1, day: "2026-08-08", startedAt: "2026-08-08T14:00:00+08:00", lines: [
            (seq: 0, endMs: 5_000,   text: "今天下午三点开会讨论预算", isGap: 0),
            (seq: 1, endMs: 600_000, text: "〔此处缺失 30 秒〕",       isGap: 1),
        ])

        let feed = try HomeProjection.homeFeed(day: "2026-08-08",
                                               summaries: [1: summary("与同事一对一")],
                                               in: dbQueue)
        let card = try XCTUnwrap(feed.todayCards.first)

        let surfaced = (card.state.summary?.keyPoints.map(\.text) ?? [])
            + (card.state.summary.map { [$0.oneLiner, $0.title] } ?? [])
        for text in surfaced {
            XCTAssertFalse(text.contains("此处缺失"), "占位文本冒到了卡面上:\(text)")
        }
        // 但占位行仍然计进时长——它占着真实流逝的时间
        XCTAssertEqual(card.durationMinutes, 10)
    }

    // MARK: - 排序与折叠(PRD §4.2.2)

    func testTodayCardsAreNewestFirst() throws {
        try seedSession(id: 1, day: "2026-08-08", startedAt: "2026-08-08T09:00:00+08:00",
                        lines: [(0, 60_000, "早上的会", 0)])
        try seedSession(id: 2, day: "2026-08-08", startedAt: "2026-08-08T16:30:00+08:00",
                        lines: [(0, 60_000, "下午的会", 0)])

        let feed = try HomeProjection.homeFeed(day: "2026-08-08",
                                               summaries: [1: summary("早"), 2: summary("晚")],
                                               in: dbQueue)
        XCTAssertEqual(feed.todayCards.map(\.startTime), ["16:30", "09:00"])
    }

    /// 无要点、无挂载的场次折进「还有 N 段零碎」,不占一张卡。
    func testEmptySessionsFoldIntoFragments() throws {
        try seedSession(id: 1, day: "2026-08-08", startedAt: "2026-08-08T09:00:00+08:00",
                        lines: [(0, 60_000, "有内容", 0)])
        try seedSession(id: 2, day: "2026-08-08", startedAt: "2026-08-08T10:00:00+08:00",
                        lines: [(0, 60_000, "约个时间", 0)])

        let feed = try HomeProjection.homeFeed(
            day: "2026-08-08",
            summaries: [1: summary("正经会议"), 2: summary("寒暄", points: 0)],
            in: dbQueue)

        XCTAssertEqual(feed.todayCards.map(\.id), [1], "零碎不该还占一张卡")
        XCTAssertEqual(feed.fragments, FragmentsFold(count: 1, sessionIDs: [2]))
        XCTAssertEqual(Set(feed.recordedCards.map(\.id)), [1, 2], "时间条必须保留折叠的真实录音")
    }

    /// 一段零碎都没有时,整行不出现(而不是 count = 0 的空行)。
    func testNoFragmentsRowWhenNothingToFold() throws {
        try seedSession(id: 1, day: "2026-08-08", startedAt: "2026-08-08T09:00:00+08:00",
                        lines: [(0, 60_000, "有内容", 0)])
        let feed = try HomeProjection.homeFeed(day: "2026-08-08",
                                               summaries: [1: summary("正经会议")], in: dbQueue)
        XCTAssertNil(feed.fragments)
    }

    /// 还在处理的场次不能被折进零碎——它只是还没出内容,不是没内容。
    func testProcessingSessionIsNotFolded() throws {
        try seedSession(id: 1, day: "2026-08-08", startedAt: "2026-08-08T09:00:00+08:00",
                        status: "pending", lines: [(0, 60_000, "还在整理", 0)])

        let feed = try HomeProjection.homeFeed(day: "2026-08-08", in: dbQueue)
        XCTAssertNil(feed.fragments)
        XCTAssertEqual(feed.todayCards.first?.state, .processing)
    }

    func testEarlierDaysAreFoldedByDayNewestFirst() throws {
        try seedSession(id: 1, day: "2026-08-08", startedAt: "2026-08-08T09:00:00+08:00",
                        lines: [(0, 60_000, "今天", 0)])
        try seedSession(id: 2, day: "2026-08-07", startedAt: "2026-08-07T09:00:00+08:00",
                        lines: [(0, 60_000, "昨天一", 0)])
        try seedSession(id: 3, day: "2026-08-07", startedAt: "2026-08-07T15:00:00+08:00",
                        lines: [(0, 60_000, "昨天二", 0)])
        try seedSession(id: 4, day: "2026-08-05", startedAt: "2026-08-05T09:00:00+08:00",
                        lines: [(0, 60_000, "前几天", 0)])

        let feed = try HomeProjection.homeFeed(day: "2026-08-08", in: dbQueue)
        XCTAssertEqual(feed.earlier, [EarlierDay(day: "2026-08-07", sessionCount: 2),
                                      EarlierDay(day: "2026-08-05", sessionCount: 1)])
    }

    // MARK: - 点得开(M1-15a / M1-15b)

    /// 🔴 **验收(M1-15a):造两天数据,能拿到昨天那一天的场次卡。**
    ///
    /// 在此之前「更早」每一天渲染成纯 `HStack` —— 长得像卡片却没有任何手势,
    /// 于是这个产品实际上退化成**只有今天**,而 M1 出口要求回看最近 14 天。
    func testCardsOfAnEarlierDayAreReachable() throws {
        try seedSession(id: 1, day: "2026-08-08", startedAt: "2026-08-08T09:00:00+08:00",
                        lines: [(0, 60_000, "今天的", 0)])
        try seedSession(id: 2, day: "2026-08-07", startedAt: "2026-08-07T15:00:00+08:00",
                        lines: [(0, 60_000, "昨天的", 0)])

        let yesterday = try HomeProjection.cards(day: "2026-08-07", in: dbQueue)
        XCTAssertEqual(yesterday.map(\.id), [2])
        XCTAssertEqual(yesterday.first?.startTime, "15:00")
    }

    /// 🔴 **验收(M1-15b):折进「零碎」的场次要能从那一行打开。**
    ///
    /// `FragmentsFold.sessionIDs` 一直生成、**一直无人消费** ——
    /// 被折进去的场次在全 App **没有任何其他入口**(比「更早」更彻底:
    /// 那些至少还在别的日子里,这些是今天的,却哪儿都点不到)。
    func testFoldedFragmentsCanBeOpenedFromTheFoldRow() throws {
        try seedSession(id: 1, day: "2026-08-08", startedAt: "2026-08-08T09:00:00+08:00",
                        lines: [(0, 60_000, "正经会议", 0)])
        try seedSession(id: 2, day: "2026-08-08", startedAt: "2026-08-08T10:00:00+08:00",
                        lines: [(0, 60_000, "约个时间", 0)])
        let feed = try HomeProjection.homeFeed(
            day: "2026-08-08",
            summaries: [1: summary("正经会议"), 2: summary("寒暄", points: 0)],
            in: dbQueue)

        let fold = try XCTUnwrap(feed.fragments)
        XCTAssertEqual(fold.sessionIDs, [2], "前提不成立:那一场没被折起来")
        XCTAssertFalse(feed.todayCards.map(\.id).contains(2), "前提不成立:它还在主流里")

        // 折叠行点开之后拿到的就是它 —— 与主流走同一份投影,不是另查一次库
        let opened = try HomeProjection.cards(day: "2026-08-08", in: dbQueue)
            .filter { fold.sessionIDs.contains($0.id) }
        XCTAssertEqual(opened.map(\.id), [2], "折叠行点开之后是空的 —— 那一场哪儿都到不了")
    }

    /// 翻回某一天时**不再折叠** —— 折叠是给「今天那条流」保持干净用的,
    /// 在「那天到底有什么」这一屏上再折一次,等于把用户刚点开的东西又藏起来。
    func testADayPageDoesNotFoldAgain() throws {
        try seedSession(id: 1, day: "2026-08-07", startedAt: "2026-08-07T09:00:00+08:00",
                        lines: [(0, 60_000, "正经", 0)])
        try seedSession(id: 2, day: "2026-08-07", startedAt: "2026-08-07T10:00:00+08:00",
                        lines: [(0, 60_000, "零碎", 0)])
        XCTAssertEqual(
            try HomeProjection.cards(day: "2026-08-07", in: dbQueue).count, 2,
            "翻回那一天却少了几场 —— 它们在这一屏上没有别的入口")
    }

    /// 🔴 **界面上不许留「还没做」这种字。**
    ///
    /// 「零碎」那一行原来右侧写死一句「展开还没做」—— 它长得像功能、
    /// 说的是实话,而实话本身就是这条 BUG:**那些场次哪儿都到不了**。
    /// 这条断言防的是它被原样写回来(M1-17 那一整类的形状)。
    func testTheHomeScreenPromisesNothingItCannotDo() throws {
        let home = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GrowthApp/Presentation/HomeView.swift")
        let src = try String(contentsOf: home, encoding: .utf8)
        // 整个文件里一次都不许出现 —— **连注释里都不行**。
        // 写成「只查字符串字面量」的话,`Text("展开" + "还没做")` 之类的写法就绕过去了,
        // 而这条断言的意义恰恰是「一眼看得见」。
        for phrase in ["还没做", "敬请期待", "暂未开放"] {
            XCTAssertFalse(src.contains(phrase), "首页上写着「\(phrase)」")
        }
    }

    // MARK: - 状态

    /// PRD §4.1.7 的并发优先级:失败 > 等待网络 > 上传中 > 排队中 > 处理中 >
    /// 说话人整理中 > 部分失败 > 降级 > 完成
    func testConcurrencyPriorityMatchesPRD() throws {
        let ordered: [SessionDisplayState] = [
            .failed(attempt: 2, willRetry: true), .waitingForNetwork, .uploading(percent: 45), .queued(ahead: 1),
            .processing, .attributionPending(summary("x")), .partialFailure(missing: "要点"),
            .degraded, .done(summary("x")),
        ]
        XCTAssertEqual(ordered.map(\.concurrencyPriority),
                       ordered.map(\.concurrencyPriority).sorted(),
                       "优先级次序必须与 PRD §4.1.7 那一行一致")
    }

    /// 没有任务行时(比如导入的历史场次),退回按 transcripts.status 判。
    func testFallsBackToTranscriptStatusWithoutATask() throws {
        try dbQueue.read { db in
            for (status, expected) in [("pending", SessionDisplayState.processing),
                                       ("frozen", .processing),
                                       ("partial", .degraded)] {
                XCTAssertEqual(try HomeProjection.displayState(
                    taskState: nil, taskAttempts: 0, queuedAhead: 0,
                    transcriptStatus: status, summary: nil, in: db), expected)
            }
            XCTAssertEqual(try HomeProjection.displayState(
                taskState: nil, taskAttempts: 0, queuedAhead: 0,
                transcriptStatus: "frozen", summary: summary("a"), in: db), .done(summary("a")))
        }
    }

    /// 有任务行时,展示态**查映射表**得来,不是代码里 switch 出来的(§1.3)。
    func testDisplayStateComesFromTheMappingTable() throws {
        try dbQueue.read { db in
            XCTAssertEqual(try HomeProjection.displayState(
                taskState: "waiting_network", taskAttempts: 0, queuedAhead: 0,
                transcriptStatus: nil, summary: nil, in: db), .waitingForNetwork)
            XCTAssertEqual(try HomeProjection.displayState(
                taskState: "queued", taskAttempts: 0, queuedAhead: 3,
                transcriptStatus: nil, summary: nil, in: db), .queued(ahead: 3))
            // §1.3:dead 映射为「失败」,重试次数取任务行上的 attempts
            XCTAssertEqual(try HomeProjection.displayState(
                taskState: "dead", taskAttempts: 27, queuedAhead: 0,
                transcriptStatus: nil, summary: nil, in: db), .failed(attempt: 27, willRetry: false))
            XCTAssertEqual(try HomeProjection.displayState(
                taskState: "retrying", taskAttempts: 2, queuedAhead: 0,
                transcriptStatus: nil, summary: nil, in: db), .failed(attempt: 2, willRetry: true))
        }
    }

    /// 🔴 **`dead` 的卡不许说自己「重试中」。**
    ///
    /// 映射表把 `retrying` 与 `dead` 都收进 `failed`,而这两者的差别是全部:
    /// 一个会自己好,一个再也不会。2026-08-17 真机实拍到的是一张 `dead` 的卡
    /// 说「重试中(第 0 次)」—— 用户于是去等一件永远不会发生的事。
    func testDeadAndRetryingDoNotReadTheSame() throws {
        try dbQueue.read { db in
            func label(_ state: String, _ attempts: Int) throws -> String {
                try HomeProjection.displayState(
                    taskState: state, taskAttempts: attempts, queuedAhead: 0,
                    transcriptStatus: nil, summary: nil, in: db).presentation.label
            }
            let dead = try label("dead", 27), retrying = try label("retrying", 2)
            XCTAssertNotEqual(dead, retrying, "两种失败在卡面上长得一模一样")
            XCTAssertFalse(dead.contains("重试"), "再也不会重试的任务说自己在重试:\(dead)")
            XCTAssertEqual(dead, "处理失败,不会自己好了")
            XCTAssertTrue(retrying.contains("第 2 次"), retrying)
        }
    }

    /// 「第 0 次」这句话本身不通,而且读起来像坏了 —— 它其实正常得很。
    func testZeroAttemptsNeverSaysTheZerothTime() throws {
        let label = try dbQueue.read { db in
            try HomeProjection.displayState(
                taskState: "retrying", taskAttempts: 0, queuedAhead: 0,
                transcriptStatus: nil, summary: nil, in: db).presentation.label
        }
        XCTAssertFalse(label.contains("0"), label)
    }

    /// 映射表里没有的内部态,不该被悄悄渲染成某个状态。
    /// (真正的防线是 tasks.state 上的外键——插都插不进去,这里只是补一道。)
    func testUnknownTaskStateFallsThroughInsteadOfGuessing() throws {
        try dbQueue.read { db in
            XCTAssertEqual(try HomeProjection.displayState(
                taskState: "没登记过的态", taskAttempts: 0, queuedAhead: 0,
                transcriptStatus: "partial", summary: nil, in: db), .degraded,
                "认不出的内部态应退回 transcripts.status,不是猜一个")
        }
    }

    /// 加一个内部态却忘了给它映射 —— 外键直接挡下,不会渲染出空白状态。
    func testUnmappedTaskStateCannotEvenBeInserted() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (kind, session_id, state, created_at)
                VALUES ('transcribe', NULL, '忘了映射的态', '2026-08-08T15:00:00+08:00')
                """)
        })
    }

    /// 本地时区 ISO 的钟点按字面取,不过时区转换;认不出的原样返回,不猜。
    func testClockTimeIsLiteralNotReinterpreted() {
        XCTAssertEqual(HomeProjection.clockTime(fromISO: "2026-08-08T14:00:00+08:00"), "14:00")
        XCTAssertEqual(HomeProjection.clockTime(fromISO: "2026-08-08T09:05:00-05:00"), "09:05")
        XCTAssertEqual(HomeProjection.clockTime(fromISO: "看不懂"), "看不懂")
    }
}

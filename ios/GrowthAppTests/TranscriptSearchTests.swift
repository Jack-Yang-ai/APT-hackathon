import XCTest
import GRDB
@testable import GrowthApp

/// 全文检索。FTS5 虚表在 M0 就建好了,**而一行查询代码都没有** —— 这组测试补的是查询那一半。
///
/// 重点全在「**看起来正常的错**」上:短查询静默落空、用户输入被当成查询语法、
/// 搜出用户在界面上根本看不到的旧版本、超长场次搜不全。
/// 这四种都不会报错、不会崩,只会给出一个解释得通但是错的结果。
final class TranscriptSearchTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 造数

    @discardableResult
    private func makeSession(startedAt: String, day: String = "2026-08-12") throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (started_at, day, source, status)
                VALUES (?, ?, 'recording', 'closed')
                """, arguments: [startedAt, day])
            return db.lastInsertedRowID
        }
    }

    /// 落一版转写。`activate` 决定要不要把 `active_transcript_id` 指过来。
    @discardableResult
    private func makeTranscript(session: Int64, version: Int = 1, part: Int = 1,
                                lines: [(ms: Int, text: String)],
                                activate: Bool = true) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at, frozen_at)
                VALUES (?, ?, ?, 'test-asr', 'frozen', '2026-08-12T20:00:00+08:00', '2026-08-12T20:00:00+08:00')
                """, arguments: [session, version, part])
            let tid = db.lastInsertedRowID
            for (seq, l) in lines.enumerated() {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                    VALUES (?, ?, ?, ?, ?, 0, 0)
                    """, arguments: [tid, seq, l.ms, l.ms + 1000, l.text])
                // 与生产同一条路径:词索引由 `WordIndex` 这个唯一入口填
                try WordIndex.index(lineID: db.lastInsertedRowID, text: l.text,
                                    isGap: false, in: db)
            }
            if activate {
                try db.execute(sql: "UPDATE sessions SET active_transcript_id = ? WHERE id = ?",
                               arguments: [tid, session])
            }
            return tid
        }
    }

    private func search(_ q: String, limit: Int = 50) throws -> [TranscriptSearch.Hit] {
        try dbQueue.read { try TranscriptSearch.search(q, limit: limit, in: $0) }
    }

    // MARK: - 一、短词必须搜得到(迁移 v10 之前它们静默落空)

    /// trigram 索引按三字一组建,两个字的词匹配不到 —— 而「老周」「排期」满篇都是。
    /// v10 之前这里只能显式报错「至少输三个字」;现在词索引那条腿把它们接住了。
    func testShortWordsAreFoundByTheWordIndex() throws {
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: s, lines: [(0, "老周说排期要重排")])

        XCTAssertEqual(try search("老周").count, 1, "两个字的人名搜不到 —— 词索引那条腿没生效")
        XCTAssertEqual(try search("排期").count, 1)
    }

    /// 切词只能整词命中,而「交付」会被切进整体的「交付时间」。
    /// 查询侧的前缀匹配(末尾 `*`)就是为这一下存在的。
    func testPrefixOfALongerWordStillMatches() throws {
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: s, lines: [(0, "他说交付时间要重排")])

        XCTAssertEqual(try search("交付").count, 1, "「交付」找不到「交付时间」—— 前缀匹配没生效")
    }

    /// 词中间的子串只有 trigram 那条腿能覆盖 —— 两条腿谁也替代不了谁。
    func testMidWordSubstringStillWorksViaTrigram() throws {
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: s, lines: [(0, "他说交付时间要重排")])

        XCTAssertEqual(try search("付时间").count, 1, "跨词的子串搜不到 —— trigram 那条腿丢了")
    }

    /// 空输入仍然要喊。它和「搜了但没有」是两件事。
    func testEmptyQueryThrows() throws {
        for empty in ["", "   ", "\n"] {
            XCTAssertThrowsError(try search(empty)) { err in
                guard case TranscriptSearch.Failure.emptyQuery = err else {
                    return XCTFail("抛的不是「空查询」:\(err)")
                }
            }
        }
    }

    /// 前后空格不该影响判定,也不该被当成词。
    func testWhitespaceIsTrimmed() throws {
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: s, lines: [(0, "交付时间要重排")])
        XCTAssertEqual(try search("  交付时间  ").count, 1)
    }

    // MARK: - 二、用户输入是数据,不是查询语法

    /// FTS5 的 MATCH 右边是一门查询语言。不转义的话:
    /// 一个孤零零的 `"` 直接抛 SQL 语法错;而「产品 OR 定位」会**悄悄**变成布尔查询——
    /// 后者更糟,它不报错,只是给出一批解释不了的结果。
    func testFTSOperatorsInUserInputAreTreatedAsPlainText() throws {
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: s, lines: [
            (0, "他说产品 OR 定位这个说法很怪"),
            (1000, "产品定位到底是什么"),
            (2000, "他打了个引号\"强调\"了一下"),
        ])

        // 当成短语字面量:只命中那一行原样出现过的
        let hits = try search("产品 OR 定位")
        XCTAssertEqual(hits.count, 1, "被当成布尔查询了 —— 应该只命中原样出现的那一行")
        XCTAssertTrue(hits[0].text.contains("很怪"))

        // 含双引号的输入不该抛 SQL 语法错
        XCTAssertNoThrow(try search("引号\"强调"), "双引号没转义,MATCH 抛了语法错")
        XCTAssertNoThrow(try search("*星号*"))
        XCTAssertNoThrow(try search("NEAR(a b)"))
    }

    // MARK: - 三、只搜界面看得见的那一版

    /// 重转写产生 v2 之后,v1 的行仍留在索引里(§3.1.4 不覆盖、可回看)。
    /// 搜索若不过滤,会返回用户在界面上根本找不到的行。
    func testOnlyTheActiveVersionIsSearchable() throws {
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: s, version: 1,
                           lines: [(0, "旧版本里写的是交付时间要重排")], activate: false)
        try makeTranscript(session: s, version: 2,
                           lines: [(0, "新版本里写的是交付时间要提前")], activate: true)

        let hits = try search("交付时间")
        XCTAssertEqual(hits.count, 1, "把旧版本也搜出来了 —— 用户在界面上根本点不到它")
        XCTAssertTrue(hits[0].text.contains("提前"), "搜出来的是旧版本")
    }

    /// ⚠️ 这条钉的是一个真实的陷阱:超长场次会切成多个 part,
    /// 而 `TranscriptFreeze` 每冻结一个 part 就把 `active_transcript_id` 指过去 ——
    /// **它最终只指向最后一个 part**。
    /// 若按 `transcript_id = active_transcript_id` 过滤,前面所有 part 的内容会一起搜没,
    /// 而 3 小时以上的场次正是全时录音的常态。
    func testEveryPartOfALongSessionIsSearchable() throws {
        let s = try makeSession(startedAt: "2026-08-12T09:00:00+08:00")
        try makeTranscript(session: s, version: 1, part: 1,
                           lines: [(0, "上半场谈的是交付时间")], activate: true)
        try makeTranscript(session: s, version: 1, part: 2,
                           lines: [(7_200_000, "下半场谈的是交付时间的下游影响")], activate: true)

        let hits = try search("交付时间")
        XCTAssertEqual(hits.count, 2,
                       "只搜到 \(hits.count) 条 —— active_transcript_id 只指最后一个 part,"
                     + "按它过滤会把前面的 part 全丢掉")
    }

    // MARK: - 四、不该被搜到的东西

    /// 占位行(缺块)与脱敏行不进索引(§3.1.2)。
    /// 占位行被搜出来会让用户点进一段根本不存在的内容;脱敏行被搜出来则是隐私事故。
    func testGapAndRedactedLinesNeverSurface() throws {
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        let tid = try makeTranscript(session: s, lines: [(0, "这句会被脱敏掉交付时间")])
        try dbQueue.write { db in
            // 占位行:直接以 is_gap=1 插入,触发器的 WHEN 会挡住它进索引
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                VALUES (?, 9, 99000, 99999, '〔此处缺失 30 秒〕交付时间', 0, 1)
                """, arguments: [tid])
            try WordIndex.index(lineID: db.lastInsertedRowID,
                                text: "〔此处缺失 30 秒〕交付时间", isGap: true, in: db)
        }
        XCTAssertEqual(try search("交付时间").count, 1, "占位行被搜出来了")

        // 脱敏:唯一允许改冻结行的通道,改完该行要移出索引
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET redacted = 1 WHERE transcript_id = ? AND seq = 0",
                           arguments: [tid])
        }
        XCTAssertEqual(try search("交付时间").count, 0, "脱敏之后还搜得到 —— 隐私事故")
        // ⚠️ 两条索引都要移除。只删正文那条的话,词索引仍然搜得到 —— 同一个隐私事故
        XCTAssertEqual(try search("交付").count, 0, "词索引没跟着脱敏 —— 隐私事故")
    }

    // MARK: - 五、结果本身要够界面用

    /// 命中要能跳回原话:行号、场次、场次内毫秒、整行原文,一样都不能少。
    /// 三项校验里的「位置」那一项打的就是 `lineID`。
    func testHitCarriesEverythingNeededToJumpBackToTheQuote() throws {
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: s, lines: [(0, "开场白"), (488_000, "他说交付时间要重排")])

        let hit = try XCTUnwrap(try search("交付时间").first)
        XCTAssertEqual(hit.sessionID, s)
        XCTAssertEqual(hit.sessionStartedAt, "2026-08-12T14:00:00+08:00")
        XCTAssertEqual(hit.atMillis, 488_000, "时间点不对,跳过去会落在别的地方")
        XCTAssertEqual(hit.text, "他说交付时间要重排")
        XCTAssertTrue(hit.snippet.contains("⟦"), "片段里没有高亮标记")
    }

    /// 时间倒序:「最近一次是什么时候说的」是这个产品里最常见的问法。
    func testResultsAreNewestFirst() throws {
        let older = try makeSession(startedAt: "2026-08-01T10:00:00+08:00", day: "2026-08-01")
        let newer = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: older, lines: [(0, "八月初就提过交付时间")])
        try makeTranscript(session: newer, lines: [(0, "今天又提了交付时间")])

        let hits = try search("交付时间")
        XCTAssertEqual(hits.map(\.sessionID), [newer, older], "顺序不是最近优先")
    }

    /// `limit` 要真的生效 —— 否则一次搜索可能把几万行拖进内存。
    ///
    /// ⚠️ 造数必须用**互不相同**的句子。用「第 N 次提到交付时间」这种只差一个数字的,
    /// 会被近重复折叠吃成一条 —— 那时测的就不是 limit 了。
    func testLimitIsHonoured() throws {
        let verbs = ["要重排", "得往后挪", "不能再拖", "有人反对", "下游不同意",
                     "已经确认", "还没定", "先放着", "重新谈", "按原计划"]
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: s,
                           lines: verbs.enumerated().map {
                               (ms: $0.offset * 1000, text: "交付时间\($0.element)")
                           })
        XCTAssertEqual(try search("交付时间", limit: 5).count, 5)
        XCTAssertEqual(try search("交付时间").count, verbs.count, "互不相同的句子被折掉了")
    }

    // MARK: - 六、真的走了索引

    /// 要求是 <100ms。这里不测时间(会因机器而飘),测**机制**:
    /// 查询计划里必须出现虚表扫描,而不是对 `transcript_lines` 全表扫。
    /// 哪天有人把 MATCH 改成 LIKE,这条会红 —— 而功能测试全都还是绿的。
    func testQueryActuallyUsesTheFullTextIndex() throws {
        // ⚠️ EXPLAIN QUERY PLAN 返回四列(id / parent / notused / **detail**),
        //    人话在 detail 里。取第一列只会拿到一串数字。
        let plan = try dbQueue.read { db -> String in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT l.line_id FROM transcript_lines_fts
                JOIN transcript_lines l ON l.line_id = transcript_lines_fts.rowid
                WHERE transcript_lines_fts MATCH ?
                """, arguments: ["\"交付时间\""])
                .map { $0["detail"] as String? ?? "" }
                .joined(separator: " | ")
        }
        XCTAssertTrue(plan.contains("transcript_lines_fts"),
                      "查询计划里没有 FTS 虚表:\(plan)")
        // 「SCAN transcript_lines」后面必须没有 `_fts`,否则命中的是虚表自己
        XCTAssertFalse(plan.contains("SCAN transcript_lines ") || plan.hasSuffix("SCAN transcript_lines"),
                       "对转写行做了全表扫:\(plan)")
    }

    // MARK: - 七、不变量:没有一行是「插进去了但没进词索引」的

    /// 词索引不能由触发器填(切词要调系统 API,SQL 里调不到),只能由写入方顺手填。
    /// 「靠调用方自觉」在本仓出过事 —— 归属层没有统一入口,实测悬空 1979 条。
    /// 这条断言就是那件事的疫苗:漏填不报错、不崩,只会让那一行**从此搜不到**。
    func testEveryIndexableLineHasWordTokens() throws {
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: s, lines: [(0, "第一句"), (1000, "第二句交付时间")])

        let missing = try dbQueue.read { try WordIndex.unindexedLineCount(in: $0) }
        XCTAssertEqual(missing, 0, "有 \(missing) 行没进词索引 —— 它们从此搜不到,而且不会报错")
    }

    /// 整表重切:切词器随 iOS 更新会变切法,旧切法留在库里就是旧的盲区。
    /// 做得到是因为词放在独立表 —— 原文那张表冻结后不可改。
    func testRebuildAllReindexesEveryLine() throws {
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: s, lines: [(0, "老周说排期要重排")])

        let n = try dbQueue.write { try WordIndex.rebuildAll(in: $0) }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try search("老周").count, 1, "重切之后搜不到了")
        XCTAssertEqual(try dbQueue.read { try WordIndex.unindexedLineCount(in: $0) }, 0)
    }

    // MARK: - 八、几乎重复的折起来(全时录音的重复率天然高)

    /// 同一场里说了六遍几乎一样的话,只该留一条,并且说清折了几条。
    func testNearDuplicatesWithinASessionAreFolded() throws {
        let s = try makeSession(startedAt: "2026-08-12T14:00:00+08:00")
        try makeTranscript(session: s, lines: [
            (0,    "交付时间要重排一下"),
            (1000, "交付时间得重排一下"),
            (2000, "这个交付时间要重排一下"),
            (3000, "交付时间要重排一下吧"),
            (4000, "交付时间不用改了"),        // ← 这条不一样,必须留下
        ])

        let hits = try search("交付时间")
        XCTAssertEqual(hits.count, 2, "没折起来,或者把不一样的那条也折了:\(hits.map(\.text))")
        XCTAssertTrue(hits.contains { $0.text.contains("不用改了") },
                      "「不用改了」被折掉了 —— 把反义句吃掉比不折严重得多")
        XCTAssertTrue(hits.contains { $0.foldedCount > 0 }, "折了却没报数量 —— 那是悄悄丢信息")
    }

    /// ⚠️ **跨场次不折。** 同一场里说三遍是啰嗦,跨三场都在说是信号 ——
    /// 「他第 3 次提到交付时间」正是这个产品要抓的东西。
    func testNearDuplicatesAcrossSessionsAreKept() throws {
        for (i, day) in ["2026-08-10", "2026-08-11", "2026-08-12"].enumerated() {
            let s = try makeSession(startedAt: "\(day)T14:00:00+08:00", day: day)
            try makeTranscript(session: s, lines: [(i * 1000, "交付时间要重排一下")])
        }
        let hits = try search("交付时间")
        XCTAssertEqual(hits.count, 3, "跨场次也折了 —— 「他第 3 次提到」这类发现被抹掉了")
        XCTAssertTrue(hits.allSatisfy { $0.foldedCount == 0 })
    }

    /// 相似度本身的边界:反义句不能被判成重复。
    func testOppositeSentencesAreNotConsideredDuplicates() {
        let sim = NearDuplicate.similarity("交付时间要重排一下", "交付时间不用改了")
        XCTAssertLessThan(sim, NearDuplicate.similarityThreshold,
                          "反义句被判成重复(相似度 \(sim))—— 会把关键的那条吃掉")
    }
}

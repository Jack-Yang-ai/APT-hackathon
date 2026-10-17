import XCTest
import GRDB
@testable import GrowthApp

/// 自由提问的本地检索与 prompt(§4.7.3 / §4.7.4)。
///
/// 这一层最容易出的错不是「搜不到」,是**搜到了但喂错了东西**:
/// 整句当短语搜必然空 · 出处编号漂 · 模型编一个不存在的出处而界面照样渲染成链接。
final class AskRetrievalTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-13T10:00:00+08:00', '2026-08-13', 'recording', 'closed'),
                       (2, '2026-08-16T15:00:00+08:00', '2026-08-16', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'a', 'frozen', 'x'), (2, 2, 1, 1, 'a', 'frozen', 'x')
                """)
            let rows: [(Int64, Int64, Int, String)] = [
                (10, 1, 0, "首页结构先收敛,再补推荐逻辑"),
                (11, 1, 1, "入口别再加了,先把主路径跑通"),
                (12, 1, 2, "今天天气不错"),
                (20, 2, 0, "首页的信息优先级还没定"),
            ]
            for (lid, tid, seq, text) in rows {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                    VALUES (?, ?, ?, ?, ?, ?, 0)
                    """, arguments: [lid, tid, seq, seq * 1000, seq * 1000 + 900, text])
                try WordIndex.index(lineID: lid, text: text, isGap: false, in: db)
            }
            // ⚠️ 必须指 active —— `TranscriptSearch` 只搜当前生效的那一版
            // (它防的正是「搜出用户在界面上根本看不到的旧版本」)。
            // 不指的话检索恒空,而那看起来像「拆词没生效」,会把人引到错的地方。
            try db.execute(sql: "UPDATE sessions SET active_transcript_id = 1 WHERE id = 1")
            try db.execute(sql: "UPDATE sessions SET active_transcript_id = 2 WHERE id = 2")
        }
    }
    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 为什么需要这一层

    /// 🔴 **这条测试是 `AskRetrieval` 存在的全部理由。**
    ///
    /// 把一整句问题丢给 `TranscriptSearch.search` 会搜空 —— 它是**字面短语**检索,
    /// 要求那些词相邻出现,而没有哪一行原文恰好是用户问的那句话。
    /// 若哪天有人「简化」成直接调 `search`,这条会红。
    func testAWholeQuestionFedToLiteralSearchFindsNothing() throws {
        let raw = try dbQueue.read {
            try TranscriptSearch.search("首页的信息优先级到底定了没有", in: $0)
        }
        XCTAssertTrue(raw.isEmpty, "字面短语检索居然命中了 —— 那这一层的前提变了,要重看")

        let viaAsk = try dbQueue.read {
            try AskRetrieval.materials(for: "首页的信息优先级到底定了没有", in: $0)
        }
        XCTAssertFalse(viaAsk.isEmpty, "拆词之后应该能找到首页那两行")
    }

    /// 命中词数多的排前面 —— 一行同时含「首页」「优先级」比只含「首页」更可能是要找的。
    func testMoreMatchedTermsRanksHigher() throws {
        let m = try dbQueue.read {
            try AskRetrieval.materials(for: "首页的信息优先级", in: $0)
        }
        XCTAssertEqual(m.first?.hit.lineID, 20)
        XCTAssertGreaterThan(m.first!.matchedTerms, 1)
    }

    /// 单字词不参与检索 —— 否则「的」「了」会把整库拉回来。
    /// (刻意不做停用词表:中文实词绝大多数 ≥2 字,按长度筛等效且不用维护。)
    func testSingleCharTermsAreDropped() {
        XCTAssertFalse(AskRetrieval.queryTerms("他的首页是不是改了").contains("的"))
        XCTAssertTrue(AskRetrieval.queryTerms("他的首页是不是改了").contains("首页"))
    }

    /// 长词排前面 —— `maxTerms` 会砍尾巴,砍掉「今天」比砍掉「信息优先级」代价小。
    func testLongerTermsSurviveTheCap() {
        let terms = AskRetrieval.queryTerms("今天 上次 信息优先级 主路径 收敛 入口 推荐逻辑 结构")
        XCTAssertEqual(terms.count, AskRetrieval.maxTerms)
        XCTAssertTrue(terms.first!.count >= terms.last!.count)
    }

    /// **搜不到不是失败**,是「库里没有相关记录」—— 那时该答「这个我没有记录」(P5)。
    /// 所以这里返回空数组而不是抛。
    func testNoMaterialIsNotAnError() throws {
        let m = try dbQueue.read {
            try AskRetrieval.materials(for: "量子纠缠与超导材料", in: $0)
        }
        XCTAssertTrue(m.isEmpty)
    }

    // MARK: - prompt 与出处

    /// ⚠️ **出处解析是纯函数,刻意不经过检索。**
    /// 让它依赖检索结果的话,一条测试就在测两件事 —— 检索一变红,
    /// 出处逻辑到底对不对反而看不出来了。
    private func material(_ lineID: Int64, _ text: String,
                          at day: String = "2026-08-13") -> AskRetrieval.Material {
        AskRetrieval.Material(
            hit: .init(lineID: lineID, sessionID: 1, sessionStartedAt: "\(day)T10:00:00+08:00",
                       atMillis: 0, text: text, snippet: text),
            matchedTerms: 1)
    }

    /// 出处用 `line_id`,不用「第几条」—— 序号会随检索结果变,而 line_id 是稳定的。
    func testMaterialLineCarriesTheStableLineID() {
        let line = AskPrompt.materialLine(material(11, "先把主路径跑通"))
        XCTAssertTrue(line.hasPrefix("[#11] 2026-08-13 10:00 · "), line)
    }

    /// 没有材料时**照样发请求**,并把「没有材料」明说进 prompt。
    /// 在手机侧写死一句「这个我没有记录」的话,用户下一句「那你记得什么」就没人接得住。
    func testEmptyMaterialsStillProduceAPromptThatSaysSo() {
        let msgs = AskPrompt.messages(question: "他同意了吗", materials: [])
        XCTAssertTrue(msgs.last!["content"]!.contains("没有检索到相关记录"))
    }

    /// 🔴 **模型编出来的出处必须被丢掉。**
    /// 收下一个不存在的 `[#99999]`,界面就会渲染出一个点不开的链接 ——
    /// 而那正好长得像「出处功能坏了」,用户没法分辨是幻觉还是 bug。
    func testFabricatedCitationsAreDropped() {
        let offered = [material(11, "先把主路径跑通")]
        let cited = AskPrompt.citedLineIDs(in: "他说过 [#11],也提过 [#99999]。", offered: offered)
        XCTAssertEqual(cited, [11])
    }

    /// 同一个出处被引用两次只记一次。
    func testCitationsAreDeduped() {
        let offered = [material(11, "先把主路径跑通")]
        XCTAssertEqual(AskPrompt.citedLineIDs(in: "[#11] 又 [#11]", offered: offered), [11])
    }

    /// 历史只带问答文本,**不带当时的材料** —— 再喂一遍是重复付费,
    /// 而它们已经体现在当时的回答里了(§4.7.3 上下文裁剪)。
    func testHistoryCarriesOnlyTextNotMaterials() {
        let past = AskTurn(id: 1, conversationID: 1, seq: 0, askedAt: "x",
                           question: "上次说了啥", answer: "说了 [#10]",
                           status: .answered, error: nil, citedLineIDs: [10])
        let msgs = AskPrompt.messages(question: "然后呢", materials: [], history: [past])
        XCTAssertEqual(msgs.filter { $0["role"] == "user" }.count, 2)
        XCTAssertFalse(msgs.contains { $0["content"]!.contains("【材料】\n[#10]") })
    }

    /// 失败过的轮次不进历史 —— 它没有回答,喂进去只是让模型看见一个悬空的问题。
    func testFailedTurnsAreNotReplayedAsHistory() {
        let failed = AskTurn(id: 1, conversationID: 1, seq: 0, askedAt: "x",
                             question: "没答上的问题", answer: nil,
                             status: .failed, error: "断网", citedLineIDs: [])
        let msgs = AskPrompt.messages(question: "再问一次", materials: [], history: [failed])
        XCTAssertFalse(msgs.contains { $0["content"] == "没答上的问题" })
    }

    // MARK: - 问句里的相对时间词(`M2-检2` §1.2)

    /// `yyyy-MM-dd` → 当天 12:00。
    private func day(_ key: String) -> Date {
        let p = key.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour) = (p[0], p[1], p[2], 12)
        return RelativeDates.growthCalendar.date(from: c)!
    }

    /// 夹具里两场都含「首页」:某场次 在 08-13,某场次 在 08-16。
    /// 默认排序按时间倒序,所以 08-16 那条在前。
    func testWithoutATimeCueTheNewerSessionComesFirst() throws {
        let got = try dbQueue.read {
            try AskRetrieval.materials(for: "首页", now: day("2026-08-14"),
                                       bundle: Bundle(for: Self.self), in: $0)
        }
        XCTAssertEqual(got.first?.hit.lineID, 20)
        XCTAssertTrue(got.allSatisfy { !$0.inDateRange }, "问句里没有相对时间词,不该有谁「在范围内」")
    }

    /// 问「昨天」时,昨天那一场的命中排到前面 —— 排序翻转,而**不是**靠过滤。
    func testATimeCuePullsThatDaysSessionToTheFront() throws {
        let got = try dbQueue.read {
            try AskRetrieval.materials(for: "昨天的首页", now: day("2026-08-14"),
                                       bundle: Bundle(for: Self.self), in: $0)
        }
        XCTAssertEqual(got.first?.hit.lineID, 10, "08-13 那场没被「昨天」提到前面")
        XCTAssertEqual(got.first?.inDateRange, true)
    }

    /// 🔴 日期是**重排,不是过滤**。「上周那版方案后来怎么样了」问的不是上周发生了什么 ——
    /// 过滤会把答案直接删掉而界面显示「没找到」。范围外的那条必须还在材料里。
    func testMaterialsOutsideTheRangeAreKeptNotDropped() throws {
        let got = try dbQueue.read {
            try AskRetrieval.materials(for: "昨天的首页", now: day("2026-08-14"),
                                       bundle: Bundle(for: Self.self), in: $0)
        }
        XCTAssertTrue(got.contains { $0.hit.lineID == 20 && !$0.inDateRange },
                      "范围外的命中被丢了 —— 这一级是重排,不许过滤")
    }
}

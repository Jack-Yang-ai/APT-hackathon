import XCTest
import GRDB
@testable import GrowthApp

/// 「人」这一层的投影(M1-10)。
///
/// 🔴 **这个文件验的是「落对没落对」,不是「跑没跑通」。** 本仓最贵的失败形态是
/// 「成功地写进了错的地方」—— 退出码全绿、行数在涨,而结果是错的。所以下面每一条
/// 都在打一个**具体的错数**:句数会不会因为重跑转写翻倍、改名会不会顺手动了归属、
/// 两处的「待确认」数会不会对不上。
final class PeopleProjectionTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-17T15:00:00+08:00"
    private let today = "2026-08-17"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }

    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 夹具

    /// 一场录音 + 若干行。`version` 默认 1。
    ///
    /// ⚠️ **默认连音频一起造**(2026-08-31)。`pendingSpeakers` 现在只列
    /// 「放得出声」的候选,夹具不造音频的话候选恒为空 —— 那时每一条断言都是
    /// 真空放行,而屏幕上是一片绿。`withAudio: false` 是给「听不了就该消失」
    /// 那条测试专用的。
    private func makeSession(id: Int64, day: String, startedAt: String, endedAt: String?,
                             transcriptID: Int64, version: Int = 1,
                             lines: [(id: Int64, text: String, endMs: Int)],
                             oneLiner: String? = nil,
                             withAudio: Bool = true) throws {
        if withAudio { try makeAudio(day: day, startedAt: startedAt) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (?, ?, ?, ?, 'recording', 'closed')
                """, arguments: [id, startedAt, endedAt, day])
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (?, ?, ?, 1, 'step-asr-v1', 'frozen', ?)
                """, arguments: [transcriptID, id, version, startedAt])
            for (seq, l) in lines.enumerated() {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset,
                       block_seq)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?)
                    """, arguments: [l.id, transcriptID, seq, max(0, l.endMs - 900), l.endMs,
                                     l.text, withAudio ? 0 : nil])
            }
            if let oneLiner {
                try db.execute(sql: """
                    INSERT INTO summaries (transcript_id, one_liner, created_at) VALUES (?, ?, ?)
                    """, arguments: [transcriptID, oneLiner, startedAt])
            }
        }
    }

    /// 造「这一场的音频真的在盘上」——块文件 + 账本。
    ///
    /// 🔴 **块起点必须从账本来**(`BlockTiming.offsets` → `ProcessingPump.blocks`),
    /// 只造 .m4a 不造 ledger 的话 `offsets` 是空的,`withinBlock` 返回 nil,
    /// 判据仍然是「听不了」—— 而那时测试红在一个与被测逻辑无关的地方。
    private func makeAudio(day: String, startedAt: String) throws {
        let dir = ProcessingPump.recordingsRoot.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m4a = dir.appendingPathComponent("block-0000.m4a")
        try Data([0]).write(to: m4a)

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let start = f.date(from: startedAt) else {
            return XCTFail("夹具时间戳解析不了:\(startedAt)")
        }
        // 🔴 账本里的场次靠 `SessionBridge.iso(startedAt) == sessions.started_at` 对上,
        // 而 `iso` 按 `TimeZone.current` 渲染。夹具串写的是 +08:00 —— 机器不在这个
        // 时区时对不上,而**对不上的样子是「候选一个都没有」**,看起来像被测逻辑坏了。
        // ⇒ 当场喊出来,不让它伪装成产品缺陷。
        guard SessionBridge.iso(start) == startedAt else {
            return XCTFail("""
                这台机器的时区渲染出来是 \(SessionBridge.iso(start)),而夹具写的是 \(startedAt)
                —— 账本对不上场次,音频判据会全判「听不了」。夹具与机器时区必须一致。
                """)
        }
        let ledger = dir.appendingPathComponent("ledger.jsonl")
        try? FileManager.default.removeItem(at: ledger)
        try BlockLedger.append(LedgerEntry(at: start, mark: .sessionStarted), to: ledger)
        try BlockLedger.append(LedgerEntry(block: BlockRecord(
            seq: 0, startedAt: start, endedAt: start.addingTimeInterval(300),
            hardCut: false, fileName: "block-0000.m4a")), to: ledger)

        addTeardownBlock {
            try? FileManager.default.removeItem(at: m4a)
            try? FileManager.default.removeItem(at: ledger)
        }
    }

    private func person(_ id: Int64, name: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO persons (id, name, source, created_at, updated_at)
                VALUES (?, ?, '用户创建', ?, ?)
                """, arguments: [id, name, now, now])
        }
    }

    /// 直接写归属层。**只在夹具里这么做** —— 生产代码一律走 `assignSpeaker`(铁律 3)。
    private func attribute(lines: [Int64], person: Int64?, clusterTag: String?,
                           source: String = "系统整理") throws {
        try dbQueue.write { db in
            for l in lines {
                try db.execute(sql: """
                    INSERT INTO line_speakers
                      (line_id, person_id, cluster_tag, confidence, source, updated_at)
                    VALUES (?, ?, ?, 0.9, ?, ?)
                    """, arguments: [l, person, clusterTag, source, now])
            }
        }
    }

    // MARK: - 空库

    /// 一个人都没有时不许炸,也不许一片空白。
    ///
    /// ⚠️ `persons` 不是空的 —— 迁移种了本人那一行(-1)。所以「空」的正确样子是
    /// **`others` 为空、`me` 未确认**,而不是「查出 1 个人」。本人混进「其他人」
    /// 是这一屏最容易出的错:他会在自己下面又出现一次。
    func testEmptyDatabaseYieldsNoOthersAndUnconfirmedSelf() throws {
        let list = try PeopleProjection.peopleList(today: today, in: dbQueue)
        XCTAssertTrue(list.others.isEmpty, "库里只有本人那一行,不该有「其他人」")
        XCTAssertFalse(list.me.isConfirmed)
        XCTAssertEqual(list.me.lineCount, 0)
        XCTAssertEqual(list.pendingSpeakers, 0)
    }

    /// 本人**永远**不出现在「其他人」里,哪怕他已经说了很多话。
    func testSelfNeverAppearsInOthers() throws {
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:32:00+08:00", transcriptID: 1,
                        lines: [(10, "我说的第一句", 1000), (11, "我说的第二句", 2000)])
        try attribute(lines: [10, 11], person: SpeakerNaming.mePersonID, clusterTag: "S0",
                      source: "用户确认")

        let list = try PeopleProjection.peopleList(today: today, in: dbQueue)
        XCTAssertTrue(list.others.allSatisfy { $0.id != SpeakerNaming.mePersonID })
        XCTAssertTrue(list.me.isConfirmed)
        XCTAssertEqual(list.me.lineCount, 2)
        XCTAssertEqual(list.me.sessionCount, 1)
    }

    // MARK: - 没名字的人有出路

    /// `name IS NULL` 的人**必须出现在列表里**,并且 `hasName == false` ——
    /// 界面靠这一位给出通往命名屏的路,而那是施工规格 §6-⑧ 那个缺口的唯一出口。
    /// 把他滤掉的话,声纹认出的人就永远没有名字了。
    func testUnnamedPersonIsListedAndFlagged() throws {
        try person(7, name: nil)
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:32:00+08:00", transcriptID: 1,
                        lines: [(10, "这句话比较长,是用来给人认的样本", 1000)])
        try attribute(lines: [10], person: 7, clusterTag: "S1")

        let list = try PeopleProjection.peopleList(today: today, in: dbQueue)
        let row = try XCTUnwrap(list.others.first { $0.id == 7 })
        XCTAssertFalse(row.hasName)
        XCTAssertEqual(row.initial, "?", "没名字时头像不该拿「说话人」的首字「说」去凑")
        XCTAssertEqual(row.label, "说话人 1", "称呼要走 SpeakerNaming,不在投影层另编一套")
    }

    /// 建出来但还没派到任何一行上的人**也要出现**(LEFT JOIN 的理由)。
    /// 内连接会把他抹掉 —— 而命名屏刚建的人正是这种,用户会看到刚起的名字凭空消失。
    func testPersonWithNoAttributionStillListed() throws {
        try person(8, name: "小李")
        let list = try PeopleProjection.peopleList(today: today, in: dbQueue)
        let row = try XCTUnwrap(list.others.first { $0.id == 8 })
        XCTAssertEqual(row.label, "小李")
        XCTAssertNil(row.lastMetDay)
        XCTAssertEqual(row.sessionCount, 0)
        XCTAssertEqual(PeopleText.lastSeen(row), "还没有往来记录")
    }

    // MARK: - 重跑转写不许把句数翻倍

    /// 同一场重跑过一次转写(v1 + v2),两版的行都还在归属层。
    /// **句数必须只数最新版本那一份** —— 翻倍不会报错,只是个看起来很正常的错数。
    func testRerunTranscriptDoesNotDoubleCountLines() throws {
        try person(7, name: "小李")
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:32:00+08:00", transcriptID: 1, version: 1,
                        lines: [(10, "旧版第一句", 1000), (11, "旧版第二句", 2000)])
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:32:00+08:00", transcriptID: 2, version: 2,
                        lines: [(20, "新版第一句", 1000), (21, "新版第二句", 2000)])
        try attribute(lines: [10, 11, 20, 21], person: 7, clusterTag: "S1")

        let list = try PeopleProjection.peopleList(today: today, in: dbQueue)
        let row = try XCTUnwrap(list.others.first { $0.id == 7 })
        XCTAssertEqual(row.lineCount, 2, "四行里只有两行属于最新版本")
        XCTAssertEqual(row.sessionCount, 1)
    }

    // MARK: - 排序

    /// 按上次见面倒序;**从没见过的沉到最后**(nil 不是「很久以前」,是「没有」)。
    func testOrderedByLastMetWithNeverMetLast() throws {
        try person(7, name: "近的")
        try person(8, name: "远的")
        try person(9, name: "没见过的")
        try makeSession(id: 1, day: "2026-08-10", startedAt: "2026-08-10T09:00:00+08:00",
                        endedAt: "2026-08-10T09:30:00+08:00", transcriptID: 1,
                        lines: [(10, "远的说的", 1000)])
        try makeSession(id: 2, day: "2026-08-16", startedAt: "2026-08-16T09:00:00+08:00",
                        endedAt: "2026-08-16T09:30:00+08:00", transcriptID: 2,
                        lines: [(20, "近的说的", 1000)])
        try attribute(lines: [10], person: 8, clusterTag: "S0")
        try attribute(lines: [20], person: 7, clusterTag: "S0")

        let list = try PeopleProjection.peopleList(today: today, in: dbQueue)
        XCTAssertEqual(list.others.map(\.id), [7, 8, 9])
        XCTAssertEqual(list.others[0].daysAgo, 1)
        XCTAssertEqual(list.others[1].daysAgo, 7)
        XCTAssertNil(list.others[2].daysAgo)
    }

    // MARK: - 档案

    func testProfileBriefReadsStoredOneLinerAndLongestQuote() throws {
        try person(7, name: "小李")
        // ⚠️ 墙钟跨度(50 分钟)与转写行跨度(32 分钟)**故意不一样** ——
        // 这样这条断言才钉得住「优先取转写行」这条口径,而不是碰巧两边相等。
        try makeSession(id: 1, day: "2026-08-13", startedAt: "2026-08-13T10:20:00+08:00",
                        endedAt: "2026-08-13T11:10:00+08:00", transcriptID: 1,
                        lines: [(10, "短句", 1000),
                                (11, "入口别再加了,先把主路径跑通", 32 * 60_000)],
                        oneLiner: "首页结构先收敛,再补推荐逻辑")
        try attribute(lines: [10, 11], person: 7, clusterTag: "S1")

        let p = try XCTUnwrap(try PeopleProjection.profile(personID: 7, today: today, in: dbQueue))
        let met = try XCTUnwrap(p.brief.lastMet)
        XCTAssertEqual(met.sessionID, 1)
        XCTAssertEqual(met.day, "2026-08-13")
        XCTAssertEqual(met.clock, "10:20")
        XCTAssertEqual(met.daysAgo, 4)

        let topic = try XCTUnwrap(p.brief.lastTopic)
        XCTAssertEqual(topic.oneLiner, "首页结构先收敛,再补推荐逻辑")
        XCTAssertEqual(topic.quote, "入口别再加了,先把主路径跑通", "原话要取最长那句,短句认不出人")
        XCTAssertEqual(topic.quoteLineID, 11)

        let s = try XCTUnwrap(p.recentSessions.first)
        XCTAssertEqual(s.durationMinutes, 32,
                       "时长要优先取转写行的最大 t_end_ms(32 分),不是墙钟跨度(50 分)")
        XCTAssertEqual(s.relatedLineCount, 2)
        XCTAssertEqual(s.oneLiner, "首页结构先收敛,再补推荐逻辑")
    }

    /// 转写行的时间戳全是 0 时**退回墙钟跨度**。
    ///
    /// 不退回的话这一场会显示「0 分钟」—— 那不是「不知道」,那是一个看起来很正常的错数。
    /// (`HomeProjection` 为同一件事钉过一条测试,两处口径必须一样。)
    func testDurationFallsBackToWallClockWhenLinesHaveNoTimestamps() throws {
        try person(7, name: "小李")
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:47:00+08:00", transcriptID: 1,
                        lines: [(10, "没有时间戳的一句", 0)])
        try attribute(lines: [10], person: 7, clusterTag: "S1")

        let p = try XCTUnwrap(try PeopleProjection.profile(personID: 7, today: today, in: dbQueue))
        // ⚠️ 47 分钟。用 julianday 那种浮点算法这里会截成 46 —— 少一分钟不会有人发现,
        // 但它是错的,所以取的是 strftime('%s') 的整数秒。
        XCTAssertEqual(p.recentSessions.first?.durationMinutes, 47)
    }

    /// 查无此人返回 nil,**不返回一个空档案**。
    /// 「这个人不存在」和「这个人还没材料」是两件事,后者要如实说明,前者该露出来。
    func testProfileOfUnknownPersonIsNil() throws {
        XCTAssertNil(try PeopleProjection.profile(personID: 4242, today: today, in: dbQueue))
    }

    /// 一句话都没说过的人:档案打得开,简报两行都空 —— 界面按 §4.4.8 如实说明。
    func testProfileOfPersonWithNoMaterial() throws {
        try person(8, name: "还没聊过的人")
        let p = try XCTUnwrap(try PeopleProjection.profile(personID: 8, today: today, in: dbQueue))
        XCTAssertNil(p.brief.lastMet)
        XCTAssertNil(p.brief.lastTopic)
        XCTAssertTrue(p.recurringTopics.isEmpty)
        XCTAssertTrue(p.recentSessions.isEmpty)
    }

    // MARK: - 反复关心的

    /// PRD:**≥2 次才显示**。只提过一次的不是「他关心的」,是一次偶然提到。
    /// 而且只数**他自己那些行**上的命中 —— 别人提的不算他关心。
    func testRecurringTopicsNeedTwoMentionsAndOnlyCountHisOwnLines() throws {
        try person(7, name: "小李")
        try person(8, name: "别人")
        try makeSession(id: 1, day: "2026-08-13", startedAt: "2026-08-13T10:20:00+08:00",
                        endedAt: "2026-08-13T11:00:00+08:00", transcriptID: 1,
                        lines: [(10, "下游影响一", 1000), (11, "下游影响二", 2000),
                                (12, "只提一次的", 3000), (13, "别人说的", 4000)])
        try attribute(lines: [10, 11, 12], person: 7, clusterTag: "S1")
        try attribute(lines: [13], person: 8, clusterTag: "S2")
        try dbQueue.write { db in
            // 「下游影响」他自己命中两条 ⇒ 显示;「只提一次」一条 ⇒ 不显示;
            // 「别人的话题」两条但都不是他的行 ⇒ 不显示。
            try db.execute(sql: """
                INSERT INTO summary_topic_keys (transcript_id, key, line_ids) VALUES
                  (1, '下游影响', '[10,11]'), (1, '只提一次', '[12]'), (1, '别人的话题', '[13]')
                """)
        }

        let p = try XCTUnwrap(try PeopleProjection.profile(personID: 7, today: today, in: dbQueue))
        XCTAssertEqual(p.recurringTopics.map(\.key), ["下游影响"])
        XCTAssertEqual(p.recurringTopics.first?.count, 2)
    }

    func testParseLineIDsIgnoresGarbageInsteadOfThrowing() throws {
        XCTAssertEqual(PeopleProjection.parseLineIDs("[1,2,3]"), [1, 2, 3])
        XCTAssertEqual(PeopleProjection.parseLineIDs("[]"), [])
        XCTAssertEqual(PeopleProjection.parseLineIDs("[1, x, 3]"), [1, 3])
    }

    // MARK: - 待确认说话人:两处必须给同一个数

    /// 同一个人身上**既有确认行又有未确认行**——上一版就是在这里分叉的:
    /// 引导页算「总数 − 确认过的数」得 0,确认页算「没有任何确认行的键」也得 0,
    /// 但反过来构造(有确认行的键仍有未确认行)两者就不等。现在只有一个定义。
    func testPendingCountMatchesConfirmationScreenCandidates() throws {
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:30:00+08:00", transcriptID: 1,
                        lines: [(10, "已经确认过的那个人说的话", 1000),
                                (11, "还没确认的那个人说的话", 2000)])
        try attribute(lines: [10], person: nil, clusterTag: "S0", source: "用户确认")
        try attribute(lines: [11], person: nil, clusterTag: "S1")

        let list = try PeopleProjection.peopleList(today: today, in: dbQueue)
        let candidates = try PeopleProjection.pendingSpeakers(in: dbQueue)
        XCTAssertEqual(list.pendingSpeakers, candidates.count)
        XCTAssertEqual(candidates.map(\.key), ["c:1:S1"])
        XCTAssertEqual(candidates.first?.sample, "还没确认的那个人说的话")
    }

    /// 🔴 **「没被用户确认过」≠「还没有名字」。**
    ///
    /// 这条是 2026-08-17 实拍抓出来的:「小李」同时出现在待确认区(被写成
    /// 「还没有名字」)和「其他人」列表(正显示着名字)—— 同一屏两处自相矛盾。
    /// 他的归属来源是「系统整理」,所以确认页该问他「是不是你」;但他早就有名字,
    /// 不该出现在「还叫不出名字的」那一段里。两个消费方问的问题不同,过滤也不同。
    func testNamedPersonIsStillPendingConfirmationButNotUnnamed() throws {
        try person(7, name: "小李")
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:30:00+08:00", transcriptID: 1,
                        lines: [(10, "有名字但归属还没被用户确认过的一句", 1000),
                                (11, "连人都还没有的一句", 2000)])
        try attribute(lines: [10], person: 7, clusterTag: "S0")     // 系统整理,没被确认
        try attribute(lines: [11], person: nil, clusterTag: "S1")

        let pending = try PeopleProjection.pendingSpeakers(in: dbQueue)
        XCTAssertEqual(pending.count, 2, "两个都没被用户确认过 —— 确认页该把两个都问一遍")
        XCTAssertEqual(pending.first { $0.key == "p:7" }?.hasName, true,
                       "他有名字,不该被拉进「还叫不出名字的」")
        XCTAssertEqual(pending.first { $0.key == "c:1:S1" }?.hasName, false)
        XCTAssertEqual(pending.filter { !$0.hasName }.count, 1)
    }

    /// 待确认列表**最近的场次排最前**(2026-08-31 用户拍板)。
    ///
    /// ~~口径与 `SpeakerNaming` 的编号规则同一条:全库按首次出现。~~
    /// **那条口径 2026-08-31 作废。** 原因是真机实测:按首次出现排,
    /// 235 个候选里**前 41 个一个都听不了**(最老的数据音频早清掉了),
    /// 第一个能听的排在第 42 位 —— 用户的原话是「我没办法听声音判断哪个是我」。
    /// 定序这条要求仍然成立(不定序会让列表看起来在自己动),只是方向反过来。
    /// ⚠️ 编号(`说话人 N`)仍然按全库首次出现,**它与列表顺序从此不是同一条**——
    /// 编号是人的名字,换个排序就改名比乱序更糟。
    func testPendingSpeakersPutTheMostRecentSessionFirst() throws {
        try makeSession(id: 1, day: "2026-08-10", startedAt: "2026-08-10T09:00:00+08:00",
                        endedAt: "2026-08-10T09:30:00+08:00", transcriptID: 1,
                        lines: [(10, "先开口的那个人说的话", 1000)])
        try makeSession(id: 2, day: "2026-08-16", startedAt: "2026-08-16T09:00:00+08:00",
                        endedAt: "2026-08-16T09:30:00+08:00", transcriptID: 2,
                        lines: [(20, "后开口的那个人说的话", 1000)])
        try attribute(lines: [10], person: nil, clusterTag: "S0")
        try attribute(lines: [20], person: nil, clusterTag: "S0")

        let pending = try PeopleProjection.pendingSpeakers(in: dbQueue)
        XCTAssertEqual(pending.map(\.key), ["c:2:S0", "c:1:S0"], "最近那一场该排在前面")
        // 待确认是**跨场次列表** ⇒ 名字自带场次(见 `SpeakerNaming.Scope`)。
        // ~~["说话人 2", "说话人 1"]~~ 那是全库编号时代的期望值。
        // 🔴 关键不是长什么样,是**两个不同的人不许同名** —— 这一屏点下去写的是
        // `用户确认`,认错了就锁死了。
        XCTAssertEqual(pending.map(\.label), ["08-16 09:00 的说话人 1", "08-10 09:00 的说话人 1"])
        XCTAssertEqual(Set(pending.map(\.label)).count, 2, "两个候选显示成同一个名字")
    }

    /// 🔴 **点过「说不准」的不再出现在待确认里 —— 但也不许失踪**(`M2-认11`)。
    ///
    /// 用户 2026-09-02 报:「我点了说不准看一个的,那段不会消失」。
    /// 原来的 `skip()` 只做 `index += 1`,**一个字都不写库** ——
    /// 退出去再进来重新查一遍,那个候选原封不动排在原位。
    ///
    /// ⚠️ 后半句同样要钉住:只从**这一屏**拿掉,不是丢掉。
    /// 丢掉的话那些行永久没有说话人,而且用户再也找不到它们。
    func testASkippedSpeakerLeavesPendingButStaysReachable() throws {
        try makeSession(id: 1, day: "2026-08-10", startedAt: "2026-08-10T09:00:00+08:00",
                        endedAt: "2026-08-10T09:30:00+08:00", transcriptID: 1,
                        lines: [(10, "说不准的那个人说的话", 1000)])
        try makeSession(id: 2, day: "2026-08-16", startedAt: "2026-08-16T09:00:00+08:00",
                        endedAt: "2026-08-16T09:30:00+08:00", transcriptID: 2,
                        lines: [(20, "还没答过的那个人说的话", 1000)])
        try attribute(lines: [10], person: nil, clusterTag: "S0")
        try attribute(lines: [20], person: nil, clusterTag: "S0")
        XCTAssertEqual(try PeopleProjection.pendingSpeakers(in: dbQueue).count, 2, "夹具本身不对")

        try SpeakerSkips.record("c:1:S0", now: "2026-09-02T20:00:00+08:00", in: dbQueue)

        XCTAssertEqual(try PeopleProjection.pendingSpeakers(in: dbQueue).map(\.key), ["c:2:S0"], """
            点过「说不准」的还在待确认里 —— 退出去再进来它原封不动排在原位,
            而用户的意思是「我判不了」,不是「翻一页」。
            """)
        XCTAssertEqual(try PeopleProjection.skippedSpeakers(in: dbQueue).map(\.key), ["c:1:S0"], """
            说不准的行从「改一改」那一屏也没了 —— 那它们就永久没有入口能认。
            「只从待确认拿掉」与「丢掉」是两件事。
            """)
    }

    /// 同一个键点两次不炸(键是主键,第二次覆盖时间)。
    func testSkippingTwiceIsIdempotent() throws {
        try SpeakerSkips.record("c:1:S0", now: "2026-09-02T20:00:00+08:00", in: dbQueue)
        try SpeakerSkips.record("c:1:S0", now: "2026-09-02T21:00:00+08:00", in: dbQueue)
        XCTAssertEqual(try dbQueue.read { try SpeakerSkips.keys(in: $0) }, ["c:1:S0"])
    }

    /// 🔴 **放不出声的候选一个都不许出现**(2026-08-31 用户拍板)。
    ///
    /// 这一屏问的是「哪个是你」,而人是照着**声音**回答的。只给文字让他猜,
    /// 猜错就是一次不可逆的错归属(`source='用户确认'` 之后声纹再也修不回来)。
    /// 真机上正是这条把用户挡了两周:候选列了 235 个,前 41 个全是哑的。
    func testSpeakersWithNoPlayableAudioAreNotOffered() throws {
        try makeSession(id: 1, day: "2026-08-10", startedAt: "2026-08-10T09:00:00+08:00",
                        endedAt: "2026-08-10T09:30:00+08:00", transcriptID: 1,
                        lines: [(10, "音频已经不在了的那个人", 1000)],
                        withAudio: false)
        try makeSession(id: 2, day: "2026-08-16", startedAt: "2026-08-16T09:00:00+08:00",
                        endedAt: "2026-08-16T09:30:00+08:00", transcriptID: 2,
                        lines: [(20, "听得到的那个人", 1000)])
        try attribute(lines: [10], person: nil, clusterTag: "S0")
        try attribute(lines: [20], person: nil, clusterTag: "S0")

        let pending = try PeopleProjection.pendingSpeakers(in: dbQueue)
        XCTAssertEqual(pending.map(\.key), ["c:2:S0"],
                       "音频不在盘上的那个说话人还被列出来了 —— 用户只能靠猜")
        // 两处必须同时收敛,否则人 tab 的角标会说「还有 2 个」而确认页只给 1 个。
        let list = try PeopleProjection.peopleList(today: today, in: dbQueue)
        XCTAssertEqual(list.pendingSpeakers, 1)
    }

    /// 🔴 **认过的必须还能被找回来改**(用户 2026-08-31:「判过的得能让我重改」)。
    ///
    /// 这一屏点下去写的是 `用户确认`,而 `assignSpeaker` 从此不许任何自动来源改它。
    /// 数据层允许用户自己再确认一次,可界面上原来**没有任何路径能再看到它** ——
    /// `pendingSpeakers` 把有确认行的键整个滤掉了。于是一次误触 =
    /// 一整簇话永久记在错的人名下。⇒ `confirmedSpeakers` 是那条回头路。
    func testConfirmedSpeakersCanBeFoundAgainForRevision() throws {
        try person(7, name: "小李")
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:30:00+08:00", transcriptID: 1,
                        lines: [(10, "认过的那个人说的话", 1000),
                                (11, "还没认过的那个人说的话", 2000)])
        try attribute(lines: [10], person: 7, clusterTag: "S0", source: "用户确认")
        try attribute(lines: [11], person: nil, clusterTag: "S1")

        let pending = try PeopleProjection.pendingSpeakers(in: dbQueue)
        let confirmed = try PeopleProjection.confirmedSpeakers(in: dbQueue)

        XCTAssertEqual(pending.map(\.key), ["c:1:S1"], "认过的不该再出现在「待确认」里")
        XCTAssertEqual(confirmed.map(\.key), ["p:7"],
                       "认过的一个都找不回来 —— 点错了就永久错着")
        XCTAssertEqual(confirmed.first?.label, "小李", "改一改那一屏要说得出「现在认作谁」")
    }

    /// 两个列表**互斥且共用一份实现** —— 分开写会各漂各的,
    /// 而漂了的表现是「待确认里听得见,改一改里听不见」,两边都跑得通。
    func testPendingAndConfirmedAreDisjointAndShareTheSameRules() throws {
        try person(7, name: "小李")
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:30:00+08:00", transcriptID: 1,
                        lines: [(10, "认过的", 1000), (11, "没认过的", 2000)])
        // 没有音频的那一场:两个列表都该滤掉它,规则一致才叫共用
        try makeSession(id: 2, day: "2026-08-16", startedAt: "2026-08-16T09:00:00+08:00",
                        endedAt: "2026-08-16T09:30:00+08:00", transcriptID: 2,
                        lines: [(20, "听不见的认过的", 1000)], withAudio: false)
        try attribute(lines: [10], person: 7, clusterTag: "S0", source: "用户确认")
        try attribute(lines: [11], person: nil, clusterTag: "S1")
        try attribute(lines: [20], person: 7, clusterTag: "S2", source: "用户确认")

        let pending = Set(try PeopleProjection.pendingSpeakers(in: dbQueue).map(\.key))
        let confirmed = Set(try PeopleProjection.confirmedSpeakers(in: dbQueue).map(\.key))
        XCTAssertTrue(pending.isDisjoint(with: confirmed), "同一个键同时出现在两个列表里")
        XCTAssertFalse(confirmed.contains("c:2:S2"),
                       "听不了的候选进了「改一改」—— 那边的过滤规则和待确认漂了")
    }

    /// 样本句必须挑**听得见的那一句**。
    ///
    /// 🔴 挑最长的那句是原来的规则,而最长的那句可能恰恰是哑的 ——
    /// 那时候选留下了,按钮却写着「音频文件已经不在了」,等于换个地方再哑一次。
    func testSampleIsPickedAmongPlayableLinesOnly() throws {
        try person(7, name: nil)        // 先建人 —— `line_speakers.person_id` 有外键
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:30:00+08:00", transcriptID: 1,
                        lines: [(10, "短的但听得见", 1000)])
        // 同一个说话人在另一场里有更长的一句,而那一场没有音频。
        try makeSession(id: 2, day: "2026-08-16", startedAt: "2026-08-16T09:00:00+08:00",
                        endedAt: "2026-08-16T09:30:00+08:00", transcriptID: 2,
                        lines: [(20, "长得多的那一句可惜听不见了啊啊啊啊", 1000)],
                        withAudio: false)
        try attribute(lines: [10], person: 7, clusterTag: "S0")
        try attribute(lines: [20], person: 7, clusterTag: "S0")

        let pending = try PeopleProjection.pendingSpeakers(in: dbQueue)
        XCTAssertEqual(pending.first?.sampleLineID, 10,
                       "挑了一句放不出来的当样本 —— 屏幕上的字和听到的声音对不上")
        XCTAssertEqual(pending.first?.sample, "短的但听得见")
    }

    /// 只有簇标签的说话人**不进人列表**。簇只在一场之内有效——把它摆进跨场次的
    /// 人列表,等于替用户宣称两场的 `S0` 是同一个人。
    func testClusterOnlySpeakersStayOutOfThePeopleList() throws {
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:30:00+08:00", transcriptID: 1,
                        lines: [(10, "某个还没归属的人说的", 1000)])
        try attribute(lines: [10], person: nil, clusterTag: "S0")

        let list = try PeopleProjection.peopleList(today: today, in: dbQueue)
        XCTAssertTrue(list.others.isEmpty)
        XCTAssertEqual(list.pendingSpeakers, 1, "它该出现在待确认里,而不是人列表里")
    }

    // MARK: - 改名 vs 改归属:两件事

    /// **改名一行归属都不许动。** 改的是称呼,id 不动,他说过的话还是他说的。
    /// 顺手动了归属的话,纪要里的表态与承诺会跟着换主,而用户以为只是改了个称呼。
    func testRenameDoesNotTouchAttribution() throws {
        try person(7, name: nil)
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:30:00+08:00", transcriptID: 1,
                        lines: [(10, "第一句", 1000), (11, "第二句", 2000)])
        try attribute(lines: [10, 11], person: 7, clusterTag: "S1")

        let before = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT line_id, person_id, source, cluster_tag"
                             + " FROM line_speakers ORDER BY line_id")
        }
        try PersonStore.rename(7, to: "小李", now: now, in: dbQueue)
        let after = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT line_id, person_id, source, cluster_tag"
                             + " FROM line_speakers ORDER BY line_id")
        }
        XCTAssertEqual(before, after, "改名动了归属层")

        let list = try PeopleProjection.peopleList(today: today, in: dbQueue)
        let row = try XCTUnwrap(list.others.first { $0.id == 7 })
        XCTAssertEqual(row.label, "小李")
        XCTAssertTrue(row.hasName)
        XCTAssertEqual(row.lineCount, 2, "归属没动,句数就该一句不差")
    }

    /// 把一个还没归属的簇指给某个人,**必须走 `assignSpeaker`** ——
    /// 判据不是「person_id 变了」(裸 UPDATE 也能做到),是**判断库里留下了记录**。
    /// 归属只有一条路可写(铁律 3),而这条路的证据就是那条 judgment。
    func testAttachingClusterGoesThroughAssignSpeakerAndLeavesAJudgment() throws {
        try person(7, name: "小李")
        try makeSession(id: 1, day: today, startedAt: "2026-08-17T14:00:00+08:00",
                        endedAt: "2026-08-17T14:30:00+08:00", transcriptID: 1,
                        lines: [(10, "还没有主人的一句话", 1000)])
        try attribute(lines: [10], person: nil, clusterTag: "S0")

        let judgmentsBefore = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM judgments") ?? 0
        }
        let r = try AssignSpeaker.assignSpeaker(
            lines: [10], person: 7, clusterTag: nil, source: .userConfirmed,
            confidence: nil, actor: .user, now: now, in: dbQueue)

        XCTAssertEqual(r.changedLines, [10])
        let (judgmentsAfter, source, cluster) = try dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM judgments") ?? 0,
             try String.fetchOne(db, sql: "SELECT source FROM line_speakers WHERE line_id = 10"),
             try String.fetchOne(db, sql: "SELECT cluster_tag FROM line_speakers WHERE line_id = 10"))
        }
        XCTAssertEqual(judgmentsAfter, judgmentsBefore + 1, "没留下判断记录 = 没走唯一入口")
        XCTAssertEqual(source, "用户确认")
        XCTAssertEqual(cluster, "S0", "簇标签是校验的证据,不该被这一步顶掉")

        // 指过去之后他就该出现在人列表里,并且不再是待确认。
        let list = try PeopleProjection.peopleList(today: today, in: dbQueue)
        XCTAssertEqual(list.others.first { $0.id == 7 }?.lineCount, 1)
        XCTAssertEqual(list.pendingSpeakers, 0)
    }

    // MARK: - 日期

    func testDaysBetween() {
        XCTAssertEqual(PeopleProjection.daysBetween("2026-08-13", and: "2026-08-17"), 4)
        XCTAssertEqual(PeopleProjection.daysBetween("2026-08-17", and: "2026-08-17"), 0)
        // 跨月、跨年、闰日各一条 —— 手写日期算法最容易在这三处错。
        XCTAssertEqual(PeopleProjection.daysBetween("2026-07-31", and: "2026-08-01"), 1)
        XCTAssertEqual(PeopleProjection.daysBetween("2025-12-31", and: "2026-01-01"), 1)
        XCTAssertEqual(PeopleProjection.daysBetween("2024-02-28", and: "2024-03-01"), 2)
        XCTAssertEqual(PeopleProjection.daysBetween("2023-02-28", and: "2023-03-01"), 1)
        // 认不出格式返回 nil,**不猜**。
        XCTAssertNil(PeopleProjection.daysBetween("不是日期", and: "2026-08-17"))
        XCTAssertNil(PeopleProjection.daysBetween("2026-13-01", and: "2026-08-17"))
    }

    /// 降级文案:算不出天数时说「已有往来记录」,**不说「很久以前」**——
    /// 「不知道多久」和「很久」是两件事,后者是一次没有依据的推断(PRD §4.4.8)。
    func testLastSeenTextDoesNotGuess() {
        let noRecord = PersonRow(id: 1, label: "甲", hasName: true, lastMetDay: nil,
                                 daysAgo: nil, sessionCount: 0, lineCount: 0)
        XCTAssertEqual(PeopleText.lastSeen(noRecord), "还没有往来记录")

        let unparsable = PersonRow(id: 2, label: "乙", hasName: true, lastMetDay: "坏日期",
                                   daysAgo: nil, sessionCount: 3, lineCount: 9)
        XCTAssertEqual(PeopleText.lastSeen(unparsable), "已有往来记录")

        XCTAssertEqual(PeopleText.relative(0), "今天")
        XCTAssertEqual(PeopleText.relative(1), "昨天")
        XCTAssertEqual(PeopleText.relative(3), "3 天前")
        XCTAssertEqual(PeopleText.relative(14), "2 周前")
        XCTAssertEqual(PeopleText.relative(60), "2 个月前")
    }

    // MARK: - 「待确认」只有一个定义

    /// 🔴 **源码断言,不是数据断言。**
    ///
    /// 「待确认几个说话人」这个数有三个消费方(人 tab / 确认页 / 设置页)。
    /// M1-11 把定义收进 `pendingSpeakers`,而**设置页当时漏了**,仍是
    /// 「总键数 − 用户确认过的键数」—— 两者差在「整键的行全是空洞行/抹除行」
    /// 那种数据上,而两边都「跑得通」,数据上看不出谁对。
    ///
    /// 所以扫源码:除了投影层自己,没有第二处再去数 `source = '用户确认'` 的键。
    func testNobodyElseDefinesPendingSpeakers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GrowthAppTests
            .deletingLastPathComponent()   // ios
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? [])
            .map { (rel: $0.path.replacingOccurrences(of: root.path + "/", with: ""), url: $0) }
            .filter { $0.rel.hasPrefix("GrowthApp/") }
        XCTAssertGreaterThan(files.count, 10, "一个 .swift 都没扫到,这条断言是空转的")

        // ⚠️ **判据不能是裸的 `contains("COUNT(DISTINCT")`。**
        // 它管的是「有没有第二处**数归属键**」,而 `COUNT(DISTINCT` 本身随处可用 ——
        // 2026-08-25 `AssignSpeaker` 里一句 `COUNT(DISTINCT matter_id)`
        // (数一条立场跨了几件事,与归属毫无关系)把这道闸打红了。
        // 这与同一天 `matchSpeakers` 被 `rematchSpeakers` 误伤是同一个形状:
        // **子串不是语义**。⇒ 只有当同一条 SQL 里同时出现
        // `COUNT(DISTINCT` 与 `line_speakers` 时才算数了归属键。
        let offenders = try files
            .filter { $0.rel != "GrowthApp/Presentation/PeopleProjection.swift" }
            .filter { file in
                let text = try String(contentsOf: file.url, encoding: .utf8) as NSString
                var from = 0
                while case let r = text.range(of: "COUNT(DISTINCT",
                                              options: [],
                                              range: NSRange(location: from,
                                                             length: text.length - from)),
                      r.location != NSNotFound {
                    let lo = max(0, r.location - 300)
                    let hi = min(text.length, r.location + 300)
                    if text.substring(with: NSRange(location: lo, length: hi - lo))
                            .contains("line_speakers") { return true }
                    from = r.location + r.length
                }
                return false
            }
            .map(\.rel)
        XCTAssertEqual(offenders, [],
                       "这些文件自己数了一遍归属键 —— 「待确认」会出现第二个定义:\(offenders)")
    }
}

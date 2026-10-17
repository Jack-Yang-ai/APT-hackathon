import XCTest
import GRDB
@testable import GrowthApp

/// 分块抽取(M1-27)。
///
/// ## 这一组守的是什么
///
/// 2026-08-19 之前,一场的**所有块进同一个 transcript**,抽取对整场跑**一次**调用。
/// 试点实测:2,232 行 → 输出 19,998 顶到 `MAX_TOKENS` 20,000,JSON 解不开。
/// 而这个产品是全时录音,一天远超 2,232 行 ⇒ **抽取在真实使用下必然失败**。
///
/// 🔴 **为什么之前没暴露**:真机跑过的场次都短(全库最长的一场 344 行)。
/// **它是被数据规模挡住的,不是被设计挡住的** —— 而规模一定会到。
final class ExtractionChunkingTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-19T15:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    /// 造一份 `count` 行的转写。
    private func seed(lines count: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-19T09:00:00+08:00', '2026-08-19', 'recording', 'closed');
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (5, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-19T09:30:00+08:00');
                """)
            for i in 0..<count {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                    VALUES (?, 5, ?, ?, ?, ?, 0, 0)
                    """, arguments: [1000 + i, i, i * 1000, i * 1000 + 900, "第 \(i) 句话"])
            }
        }
    }

    /// 假模型:每次调用回一条挂在**本块第一行**上的要点。
    /// 记下每次收到的 prompt,好数它被调了几次、每次喂了多少行。
    private final class FakeModel {
        private(set) var prompts: [String] = []
        func call(_ prompt: String) async throws -> String {
            prompts.append(prompt)
            // 合并「一句话」那次调用的 prompt 不含转写体,单独识别
            if prompt.contains("合成**整场的一句话**") { return "整场合起来的一句话" }
            let firstID = prompt
                .split(separator: "\n")
                .compactMap { Int64($0.split(separator: " ").first.map(String.init) ?? "") }
                .first ?? 1000
            return """
            {"one_liner":"第 \(prompts.count) 块的结论","key_points":[
              {"point":"要点","quote":"第","line_id":\(firstID),"speaker_hint":null}],
             "commitments":[],"stances":[],"pendings":[],"topic_keys":[]}
            """
        }
    }

    /// 🔴 **一场大到装不下时,必须切开跑,而不是硬塞一次。**
    func testALongTranscriptIsSplitIntoSeveralCalls() async throws {
        try seed(lines: ExtractionRunner.chunkSize * 2 + 10)
        let model = FakeModel()
        let r = try await ExtractionRunner.run(transcriptID: 5, now: now,
                                               call: model.call, in: dbQueue)
        // 3 块 + 1 次合并一句话
        XCTAssertEqual(model.prompts.count, 4,
                       "没有按块切 —— 整场一次调用会在全天录音上撞输出上限(实测 2232 行就顶死)")
        XCTAssertEqual(r.stored, 3, "三块各一条要点,落库应当是 3 条")
    }

    /// **每一块喂进去的行数不超过上限** —— 切了但切不够,等于没切。
    func testNoSingleCallCarriesMoreThanTheChunkSize() async throws {
        try seed(lines: ExtractionRunner.chunkSize * 2 + 10)
        let model = FakeModel()
        _ = try await ExtractionRunner.run(transcriptID: 5, now: now,
                                           call: model.call, in: dbQueue)
        for p in model.prompts where p.contains("逐句转写") {
            // ⚠️ 只数**真的转写行**(以行号开头)—— prompt 模板里那句
            // 「格式:行号 | 簇标签 | 原话」自己也含分隔符,数进去会多出 1,
            // 而那会让这条断言在临界点上冤枉实现(第一版就是这么红的)。
            let n = p.split(separator: "\n")
                .filter { $0.contains(" | ") && Int(($0.split(separator: " ").first).map(String.init) ?? "") != nil }
                .count
            XCTAssertLessThanOrEqual(n, ExtractionRunner.chunkSize, "有一块喂了 \(n) 行,超了上限")
        }
    }

    /// **短场次不许因此多花一次钱** —— 一块的时候不该跑那次合并调用。
    func testAShortTranscriptStillCostsExactlyOneCall() async throws {
        try seed(lines: 12)
        let model = FakeModel()
        _ = try await ExtractionRunner.run(transcriptID: 5, now: now,
                                           call: model.call, in: dbQueue)
        XCTAssertEqual(model.prompts.count, 1,
                       "只有一块却调了 \(model.prompts.count) 次 —— 多出来的每一次都是真金白银")
    }

    // MARK: - 空产物:抽取回来了,而里面什么都没有(2026-08-20)

    /// 🔴 **这是「钱花了、纪要没落盘」那条的根因。**
    ///
    /// `one_liner` 三处都只查「有这个键、是字符串」——
    /// `ExtractValidate:143` 判 `is String`、`:205` 缺了就 `?? ""`、
    /// `ExtractionStore:52` 又是 `as? String`。**没有一处查非空**,
    /// 而 `ExtractionStore` 那句报错原文写的就是「PRD §4.2.3 写明它必有」。
    ///
    /// 空串落库之后有两层后果,**两层都不报错**:
    /// ① 详情页 `d.oneLiner ?? "这一场还没出一句话"` 拿到的是**空串不是 nil**,
    ///    连兜底文案都不显示,标题一片空白 —— 与「还没抽」长得一模一样;
    /// ② `summaries` 有行了 ⇒ 去重从此**永久跳过**这份转写,再也不会重抽。
    func testAnEmptyOneLinerIsRefusedInsteadOfStored() async throws {
        try seed(lines: 12)
        let call: (String) async throws -> String = { _ in
            """
            {"one_liner":"","key_points":[],"commitments":[],
             "stances":[],"pendings":[],"topic_keys":[]}
            """
        }
        do {
            _ = try await ExtractionRunner.run(transcriptID: 5, now: now, call: call, in: dbQueue)
            XCTFail("空的 one_liner 被当成一份合法纪要收下了")
        } catch {
            XCTAssertTrue("\(error)".contains("整场结论是空的"),
                          "抛了,但抛的不是这件事:\(error)")
        }
        let rows = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summaries WHERE transcript_id = 5") ?? -1
        }
        XCTAssertEqual(rows, 0, """
            拦下了却还是留了一行 —— 那一行会永久挡住重抽,比不拦更糟。
            """)
    }

    /// 多块时同样不许:每一块都空 ⇒ 合起来还是空,不能靠「合并那一步」洗成合法产物。
    func testAllChunksEmptyStillRefused() async throws {
        try seed(lines: ExtractionRunner.chunkSize * 2 + 10)
        var calls = 0
        let call: (String) async throws -> String = { prompt in
            calls += 1
            if prompt.contains("合成**整场的一句话**") { return "" }
            return """
            {"one_liner":"","key_points":[],"commitments":[],
             "stances":[],"pendings":[],"topic_keys":[]}
            """
        }
        do {
            _ = try await ExtractionRunner.run(transcriptID: 5, now: now, call: call, in: dbQueue)
            XCTFail("三块全空,却收下了")
        } catch {
            XCTAssertTrue("\(error)".contains("整场结论是空的"), "\(error)")
        }
    }

    /// **库里已经躺着的空产物,要能被重抽救回来。**
    ///
    /// 修复之前落下的空行不会自己消失,而去重那句 `EXISTS(summaries …)`
    /// 会让它们**永久**跳过 —— 「跳过因为抽过了」与「跳过因为抽出来是空的」
    /// 在任务表上一模一样。
    func testAnEmptyRowLeftBehindDoesNotBlockReExtraction() async throws {
        try seed(lines: 12)
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO summaries (transcript_id, one_liner, created_at) VALUES (5, '', ?)
                """, arguments: [now])
        }
        let model = FakeModel()
        let r = try await ExtractionRunner.run(transcriptID: 5, now: now,
                                               call: model.call, in: dbQueue)
        XCTAssertFalse(r.skipped, "库里那行是空的,却被当成「已经抽过」跳过了")
        XCTAssertEqual(model.prompts.count, 1, "该重抽一次")
    }

    /// 🔴 **反面照妖镜:非空的产物必须照旧跳过。**
    ///
    /// 上面那条把去重放松了半步,而去重是**钱的守卫**——
    /// 放松过头的表现是「每次重试都重新付一次费」,而它同样什么都不报。
    func testANonEmptyRowStillSkipsAndCostsNothing() async throws {
        try seed(lines: 12)
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO summaries (transcript_id, one_liner, created_at)
                VALUES (5, '已经有结论了', ?)
                """, arguments: [now])
        }
        let model = FakeModel()
        let r = try await ExtractionRunner.run(transcriptID: 5, now: now,
                                               call: model.call, in: dbQueue)
        XCTAssertTrue(r.skipped, "已经抽过的又抽了一遍 —— 每一次都是真金白银")
        XCTAssertEqual(model.prompts.count, 0, "跳过了却还是打了模型")
    }

    /// 🔴 **照妖镜:把分块关掉(块开得比全场还大),第一条必须转红。**
    ///
    /// 没有这一条的话,上面那些断言可能只是因为夹具恰好小而绿着。
    func testWithoutChunkingItWouldBeASingleCall() async throws {
        try seed(lines: ExtractionRunner.chunkSize * 2 + 10)
        let lines = try await dbQueue.read { try ExtractionRunner.lines($0, transcriptID: 5) }
        // 不切时就是 1 块 —— 也就是修复之前的行为,而那正是会顶死输出上限的形态
        XCTAssertEqual(lines.chunked(into: .max).count, 1)
        XCTAssertEqual(lines.chunked(into: ExtractionRunner.chunkSize).count, 3,
                       "按上限切应当得到 3 块;若这里也是 1,说明切分根本没生效")
    }

    // MARK: - 两阶段(M2-成7,v2.5)

    /// ✅ **照妖镜验过(2026-08-24 夜班,复核清单 §八)**:把两阶段那条改成
    /// `linesCall(Array(lines.prefix(800)))` ⇒ **只有这一条红**,另一条不动。
    ///
    /// 🔴 **走两阶段时不分块。** 切分由两阶段自己按候选块做
    /// (`TARGET_CHARS = 2000`,静音 ≥10 分钟强制断组),手机再切一次会把它的分组切碎 ——
    /// 而切碎的后果是 **event 边界错**,那是下游挂进展的键,错了不报错。
    func testTwoStageGetsTheWholeTranscriptInOneShot() async throws {
        try seed(lines: 2000)
        var gotCounts: [Int] = []
        let payload = """
            {"one_liner":"两阶段的一句话","key_points":[],"commitments":[],
             "stances":[],"pendings":[],"topic_keys":[]}
            """
        _ = try await ExtractionRunner.run(
            transcriptID: 5, now: now,
            call: { _ in XCTFail("走了两阶段还调 v1 那条"); return "" },
            linesCall: { lines in gotCounts.append(lines.count); return payload },
            in: dbQueue)
        XCTAssertEqual(gotCounts, [2000], """
            两阶段被分块了(实得每次 \(gotCounts) 行)—— 候选块与分组会被切碎,
            event 边界跟着错,而 event_id 是下游挂进展的键。
            """)
    }

    /// ✅ **照妖镜验过(2026-08-24 夜班)**:把 `ExtractValidate.validate` 那一行
    /// 换成直接放行 ⇒ **只有这一条红**,另一条不动。
    ///
    /// 🔴 **远端产物落库前仍要在手机上再校验一遍。**
    /// 远端已经校验过(那边也有行),但**落库这道口是手机把的** ——
    /// 信一份没验过的 payload 就是新开一个洞,而三项校验是纯字符串比对、便宜得很。
    func testRemotePayloadIsStillValidatedOnDevice() async throws {
        try seed(lines: 3)
        // 引文不是原文子串 ⇒ 校验②该丢弃它
        let fabricated = """
            {"one_liner":"一句话",
             "key_points":[{"point":"编的","quote":"这句话原文里根本没有","line_id":1000}],
             "commitments":[],"stances":[],"pendings":[],"topic_keys":[]}
            """
        let r = try await ExtractionRunner.run(
            transcriptID: 5, now: now,
            call: { _ in "" },
            linesCall: { _ in fabricated },
            in: dbQueue)
        XCTAssertEqual(r.stats?.discarded, 1, """
            远端来的编造引文没被丢弃 —— 手机这道校验形同虚设,
            而「远端验过了」是一句没人守得住的承诺。
            """)
        let n = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summary_key_points") ?? -1
        }
        XCTAssertEqual(n, 0, "编造的要点落库了")
    }
}

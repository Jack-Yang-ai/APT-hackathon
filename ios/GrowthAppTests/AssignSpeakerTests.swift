import XCTest
import GRDB
@testable import GrowthApp

/// 归属唯一入口(§3.2)。
///
/// 幂等这一条要按**判 11** 打:与**当前状态**一致才 no-op,不与历史比。
/// 差别就在 A→B→A —— 跟历史比会把第三次吞掉,而那是一次真实判断。
final class AssignSpeakerTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-08T16:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        RecomputeRegistry.resetToM0Defaults()
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
                    VALUES (?, 1, ?, ?, ?, ?, 0)
                    """, arguments: [10 + seq, seq, seq * 1000, seq * 1000 + 900, "第\(seq)句"])
            }
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    @discardableResult
    private func assign(_ person: PersonID?, lines: [LineID] = [10],
                        clusterTag: String? = nil,
                        source: AttributionSource = .voiceprint,
                        confidence: Double? = 0.9,
                        actor: Actor = .user,
                        causedBy: JudgmentID? = nil) throws -> AssignResult {
        try AssignSpeaker.assignSpeaker(lines: lines, person: person, clusterTag: clusterTag,
                                        source: source,
                                        confidence: confidence, actor: actor,
                                        causedBy: causedBy, now: now, in: dbQueue)
    }

    private func judgmentCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM judgments") ?? -1 }
    }

    private func personOf(_ line: LineID) throws -> PersonID? {
        try dbQueue.read { db in
            try PersonID.fetchOne(db, sql: "SELECT person_id FROM line_speakers WHERE line_id = ?",
                                  arguments: [line])
        }
    }

    private func clusterTagOf(_ line: LineID) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT cluster_tag FROM line_speakers WHERE line_id = ?",
                                arguments: [line])
        }
    }

    private func lastPayload() throws -> [String: Any] {
        let raw = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT payload FROM judgments ORDER BY id DESC LIMIT 1")
        }
        return try JSONSerialization.jsonObject(
            with: Data((raw ?? "").utf8)) as? [String: Any] ?? [:]
    }

    // MARK: - 验收第一条:同入参连调两次只增一条判断记录

    func testSameInputTwiceRecordsOnlyOneJudgment() throws {
        let first = try assign(7)
        XCTAssertNotNil(first.judgmentID)
        XCTAssertEqual(first.changedLines, [10])
        XCTAssertEqual(try judgmentCount(), 1)

        let second = try assign(7)
        XCTAssertTrue(second.isNoOp, "与当前状态一致就该 no-op")
        XCTAssertEqual(second.changedLines, [])
        XCTAssertEqual(try judgmentCount(), 1, "第二次不该再产生判断记录")
    }

    // MARK: - 验收第二条:A→B→A 的第三次要记录

    func testAThenBThenARecordsThreeJudgments() throws {
        try assign(7)                                  // A
        try assign(8)                                  // B
        let third = try assign(7)                      // 又回到 A —— 这是一次真实判断

        XCTAssertFalse(third.isNoOp, "跟历史比会把这次吞掉;判 11 要求只跟当前状态比")
        XCTAssertEqual(try judgmentCount(), 3)
        XCTAssertEqual(try personOf(10), 7)
    }

    // MARK: - 幂等的边界

    /// 人相同但来源变了(声纹识别 → 用户确认),是真实变化,要记。
    func testSamePersonDifferentSourceIsAChange() throws {
        try assign(7, source: .voiceprint, confidence: 0.9)
        let upgrade = try assign(7, source: .userConfirmed, confidence: nil)
        XCTAssertFalse(upgrade.isNoOp)
        XCTAssertEqual(try judgmentCount(), 2)
    }

    /// person = nil 是取消归属,回到「说话人 N」;它也是一次判断。
    func testUnassignIsRecordedAsItsOwnAction() throws {
        try assign(7)
        try assign(nil, source: .userConfirmed, confidence: nil)

        XCTAssertNil(try personOf(10))
        let action = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT action FROM judgments ORDER BY id DESC LIMIT 1")
        }
        XCTAssertEqual(action, "unassign_speaker")
    }

    /// 一次调用覆盖一簇行,仍然只出**一条**判断记录。
    func testOneCallOverManyLinesIsOneJudgment() throws {
        let r = try assign(7, lines: [10, 11, 12])
        XCTAssertEqual(r.changedLines, [10, 11, 12])
        XCTAssertEqual(try judgmentCount(), 1)

        let targetID = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT target_id FROM judgments WHERE id = ?",
                                arguments: [r.judgmentID])
        }
        XCTAssertEqual(targetID, "[10,11,12]")
    }

    /// 一簇里只有部分行需要改时,只记那部分。
    func testPartialClusterOnlyRecordsChangedLines() throws {
        try assign(7, lines: [10])
        let r = try assign(7, lines: [10, 11])
        XCTAssertEqual(r.changedLines, [11], "10 已经是 7 了,不该再算一次改动")
    }

    // MARK: - §3.2.4 优先级:用户确认不被自动来源覆盖

    func testUserConfirmationIsNotOverwrittenByAutomaticSource() throws {
        try assign(7, source: .userConfirmed, confidence: nil)
        let auto = try assign(9, source: .voiceprint, confidence: 0.99)

        XCTAssertTrue(auto.isNoOp, "自动来源不该盖掉用户确认")
        XCTAssertEqual(auto.blockedByUserConfirmation, [10], "被挡下的行要说出来,不能默默跳过")
        XCTAssertEqual(try personOf(10), 7)
    }

    func testUserCanOverwriteUserConfirmation() throws {
        try assign(7, source: .userConfirmed, confidence: nil)
        let again = try assign(9, source: .userConfirmed, confidence: nil)
        XCTAssertFalse(again.isNoOp)
        XCTAssertEqual(try personOf(10), 9)
    }

    // MARK: - 签名上的强制项

    func testConfidenceRequiredForAutomaticSources() throws {
        XCTAssertThrowsError(try assign(7, source: .voiceprint, confidence: nil))
    }

    func testCascadeMustCarryCausedBy() throws {
        XCTAssertThrowsError(try assign(7, actor: .systemCascade, causedBy: nil))
        XCTAssertNoThrow(try assign(7, actor: .systemCascade, causedBy: 1))
    }

    /// 写一条指向不存在行的归属 —— 这正是旧仓 1979 条悬空的做法,必须抛。
    func testUnknownLineIsRejected() throws {
        XCTAssertThrowsError(try assign(7, lines: [10, 999])) { error in
            guard case AssignSpeaker.Failure.unknownLines(let ids) = error else {
                return XCTFail("应报 unknownLines,实际 \(error)")
            }
            XCTAssertEqual(ids, [999])
        }
        // 全回滚:合法的那一行也不该被写进去(B2)
        XCTAssertNil(try personOf(10))
        XCTAssertEqual(try judgmentCount(), 0)
    }

    func testEmptyLinesIsRejected() throws {
        XCTAssertThrowsError(try assign(7, lines: []))
    }

    // MARK: - 簇标签(§4.2「说话人一致」校验的对撞对象)
    //
    // 这一列此前**全库恒为 NULL**:入口把它写死成 NULL,而铁律 3 说只有这一条路
    // 能写归属层 —— 于是抽取那侧 `hint != line["cluster_tag"]` 这项校验永远短路,
    // 「模型把内容挂错行」这类错一条也抓不到,而且不会有任何地方报错。
    // 下面这几条钉的就是「它真的落了库」,不是「调用没抛异常」。

    func testClusterTagIsWritten() throws {
        try assign(7, clusterTag: "说话人3")
        XCTAssertEqual(try clusterTagOf(10), "说话人3",
                       "簇标签没落库 —— 抽取侧的说话人一致校验就没有对撞对象")
    }

    /// ON CONFLICT 分支同样要写:第二次调用走的是 UPDATE,不是 INSERT。
    func testClusterTagIsUpdatedOnConflictPath() throws {
        try assign(7, clusterTag: "说话人3")
        try assign(7, clusterTag: "说话人5", source: .userConfirmed, confidence: nil)
        XCTAssertEqual(try clusterTagOf(10), "说话人5")
    }

    /// nil 表示「这次没有簇标签可说」,不是「清空」。
    ///
    /// 反过来做会有一个静默的坏法:用户在界面上点一个人名时手上没有分人产物,
    /// 只能传 nil,那一下就会把簇标签抹掉 —— 校验又回到没有对撞对象的状态,
    /// 而且是**在归属刚刚变好的那一刻**丢的,最难查。
    func testNilClusterTagDoesNotEraseAnExistingOne() throws {
        try assign(nil, clusterTag: "说话人3", source: .systemOrganized, confidence: 0.4)
        try assign(7, source: .userConfirmed, confidence: nil)   // 界面上确认人名,拿不到簇标签

        XCTAssertEqual(try personOf(10), 7)
        XCTAssertEqual(try clusterTagOf(10), "说话人3", "用户确认不该顺手抹掉簇标签")
    }

    /// 同人同来源、只换了簇标签 —— 这是真实变化,不能被幂等吞掉。
    /// 重跑分人(换阈值重算)正是这个形状。
    func testClusterTagOnlyChangeIsNotSwallowed() throws {
        try assign(nil, clusterTag: "说话人3", source: .systemOrganized, confidence: 0.4)
        let rerun = try assign(nil, clusterTag: "说话人7", source: .systemOrganized, confidence: 0.4)

        XCTAssertFalse(rerun.isNoOp, "换了簇标签却被判成 no-op,新标签就悄悄丢了")
        XCTAssertEqual(try clusterTagOf(10), "说话人7")
        XCTAssertEqual(try judgmentCount(), 2)
    }

    /// 反过来:簇标签也一样时仍然 no-op,判 11 的幂等不因为多了一列就松掉。
    func testSameClusterTagIsStillNoOp() throws {
        try assign(7, clusterTag: "说话人3")
        let second = try assign(7, clusterTag: "说话人3")
        XCTAssertTrue(second.isNoOp)
        XCTAssertEqual(try judgmentCount(), 1)
    }

    /// 已知边界,**钉住而不是假装没有**:被用户确认挡下的行,簇标签也一并挡下。
    ///
    /// 闸的语义是「这一行整个不动」,让它半写半不写的话 `blockedByUserConfirmation`
    /// 就成了半句真话。代价是这些行上的簇标签会停在分人上一次的值 ——
    /// 后果是校验多挂起几条(看得见、可复核),不是漏掉挂错行(看不见)。
    func testUserConfirmationGateAlsoHoldsBackTheClusterTag() throws {
        try assign(nil, clusterTag: "说话人1", source: .systemOrganized, confidence: 0.4)
        try assign(7, source: .userConfirmed, confidence: nil)

        let auto = try assign(9, clusterTag: "说话人9", source: .voiceprint, confidence: 0.99)
        XCTAssertEqual(auto.blockedByUserConfirmation, [10])
        XCTAssertEqual(try clusterTagOf(10), "说话人1", "挡下就是整行不动,不该只放簇标签进去")
    }

    // MARK: - 判断记录要说清自己写了什么

    func testJudgmentPayloadCarriesTheClusterTag() throws {
        try assign(7, clusterTag: "说话人3")
        XCTAssertEqual(try lastPayload()["cluster_tag"] as? String, "说话人3",
                       "只改簇标签的那次判断,不记就解释不清它为什么存在")
    }

    /// 簇标签是 ASR 给的任意字符串。拼字符串造 JSON 时一个引号就写出坏 payload,
    /// 而它要等到 `eval/checks/check_attribution.py` 那边 json.loads 才炸。
    func testWeirdClusterTagStillProducesValidPayloadJSON() throws {
        try assign(7, clusterTag: "说\"话\\人\n3")
        XCTAssertEqual(try lastPayload()["cluster_tag"] as? String, "说\"话\\人\n3")
        XCTAssertEqual(try clusterTagOf(10), "说\"话\\人\n3")
    }

    // MARK: - 重算注册表(§3.5.2)

    /// 注册表**恰好**是声明过的那几项 —— 多一个少一个都要有人发现。
    ///
    /// ⚠️ 2026-08-18 由两项变三项:M2-0c 的迁移 v19 建了 `matter_timeline`,
    /// 而它**确实消费归属**(进展归属 V1 = M2-B3)。注册它而不是塞进豁免名单,
    /// 是因为豁免等于说「归属变了这张表不用动」—— 那是假话,
    /// 而假话一旦进了豁免名单就再没有东西会提醒任何人。
    /// 它现在挂的是一个**会自己响的桩**:表空时如实返回 0,第一条进展落库就抛。
    ///
    /// ⚠️ 2026-08-25 由三项变四项:`M3-0c` 的迁移 v26 建了 `discovery_evidence`
    /// (§3.2.3 清单第 7 项前半「关于人的发现」),处置照清单原文是
    /// **依据失效的整条撤回**,只撤人线。
    /// 🔴 **这条断言今天正常工作了一次** —— v26 落地时它当场红,
    /// 逼着「加了一项」这件事被写下来,而不是悄悄多一个注册。
    func testTheRegistryIsExactlyWhatWasDeclared() {
        XCTAssertEqual(Set(RecomputeRegistry.registered),
                       [.summaryStances, .summaryCommits, .matterProgress,
                        .personDiscoveries, .cards, .observations, .personBrief, .selfStances],
                       "注册表与声明对不上 —— 要么有人悄悄加了一项,要么有人漏注册了")
    }

    /// 每次真实改动都要把注册表里每个函数都调过一遍(§3.5.2 断言 2)。
    func testEveryRegisteredFunctionRunsOnChange() throws {
        let r = try assign(7)
        XCTAssertEqual(Set(r.recomputed.keys), RecomputeRegistry.registered)
    }

    /// 重算做的是实事:归属到位后,挂在那些行上的条目从「挂起」翻成正常。
    ///
    /// 这就是 §3.2.3 清单第 2、3 项的实质——「说话人一致」这项校验的结论会随归属改变。
    /// (M0-2e 之前这两张表还不存在,那时这里断言的是 pendingSchema;表建好之后
    ///  就该真干活了,否则「重算跑过了」是句假话。)
    func testRecomputeFlipsPendingWhenAttributionLands() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO summary_stances (transcript_id, line_id, seq, stance, quote, pending, pending_reason)
                VALUES (1, 10, 0, '对预算持保留态度', '还得再跟财务确认', 1, '归属未定')
                """)
            try db.execute(sql: """
                INSERT INTO summary_commitments (transcript_id, line_id, seq, what, quote, pending, pending_reason)
                VALUES (1, 10, 0, '周三前交文档', '周三之前', 1, '归属未定')
                """)
        }

        let r = try assign(7)
        XCTAssertEqual(r.recomputed[.summaryStances], .recomputed(rows: 1))
        XCTAssertEqual(r.recomputed[.summaryCommits], .recomputed(rows: 1))

        let (stancePending, commitPending) = try dbQueue.read { db -> (Int?, Int?) in
            (try Int.fetchOne(db, sql: "SELECT pending FROM summary_stances WHERE line_id = 10"),
             try Int.fetchOne(db, sql: "SELECT pending FROM summary_commitments WHERE line_id = 10"))
        }
        XCTAssertEqual(stancePending, 0, "归属到位了,表态不该再挂起")
        XCTAssertEqual(commitPending, 0)
    }

    /// 反过来:取消归属,条目要翻回挂起。挂起是可逆的,不是一次性的。
    func testRecomputeRestoresPendingWhenAttributionIsRemoved() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO summary_stances (transcript_id, line_id, seq, stance, quote, pending)
                VALUES (1, 10, 0, '对预算持保留态度', '还得再跟财务确认', 0)
                """)
        }
        try assign(7)
        try assign(nil, source: .userConfirmed, confidence: nil)

        let pending = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT pending FROM summary_stances WHERE line_id = 10")
        }
        XCTAssertEqual(pending, 1, "归属没了,条目该翻回挂起")
    }

    /// 表不在时仍然如实报 pendingSchema,不返回 rows: 0 假装跑过了。
    func testMissingTableStillReportsPendingSchema() throws {
        let bare = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(bare, upTo: "v3_judgments_undoes")
        let outcome = try bare.write { db in
            try RecomputeRegistry.run(db, lines: [10], triggeredBy: 1)
        }
        XCTAssertEqual(outcome[.summaryStances], .pendingSchema(table: "summary_stances"))
        XCTAssertEqual(outcome[.summaryCommits], .pendingSchema(table: "summary_commitments"))
    }

    /// 重算函数幂等(§3.5.2 断言 3):连调两次库状态一致。
    func testRecomputeIsIdempotent() throws {
        try assign(7)
        let before = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM line_speakers") ?? -1
        }
        try assign(7)   // no-op
        let after = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM line_speakers") ?? -1
        }
        XCTAssertEqual(before, after)
    }

    // MARK: - 判断记录接上判断库

    /// 入口写出的判断记录,要能被 judgment_current 认出来。
    func testJudgmentIsVisibleInCurrent() throws {
        let r = try assign(7)
        let current = try dbQueue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT judgment_id FROM judgment_current
                 WHERE target_kind = 'line' AND target_id = '[10]'
                """)
        }
        XCTAssertEqual(current, r.judgmentID)
    }

    /// basis_line_ids 要能解析回真实的行(E4)。
    func testBasisLineIDsResolve() throws {
        try assign(7, lines: [10, 11])
        let resolved = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM judgments j
                  JOIN json_each(j.basis_line_ids) b
                  JOIN transcript_lines l ON l.line_id = b.value
                """) ?? -1
        }
        XCTAssertEqual(resolved, 2)
    }
}

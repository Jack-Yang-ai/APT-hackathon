import XCTest
import GRDB
@testable import GrowthApp

/// 我的立场与原则(`M3-0c` 迁移 v29,§3.2.3 清单第 8 项)。
///
/// 🔴 **判据是「这条行现在还属不属于我」,不是「这条行动过没有」。**
/// 归属被**改到**「我」身上是件好事,不该因此撤掉任何立场;只有**改走**了,
/// 才说明当初那条立场是错认的产物。写成「动过就撤」的后果是:用户每纠正一次说话人,
/// 自己的立场就少几条 —— 而少掉的那几条恰恰是刚被确认为他自己说的。
final class SelfStanceSchemaTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-25T16:00:00+08:00"
    private let me = MatterSituation.mePersonID

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        RecomputeRegistry.resetToM0Defaults()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-25T14:00:00+08:00', '2026-08-25', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-25T15:00:00+08:00')
                """)
            try db.execute(sql: """
                INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (10, 1, 0,    0, 1000, '先看成本再看方案',   0),
                       (11, 1, 1, 1000, 2000, '这次也是成本优先',   8),
                       (12, 1, 2, 2000, 3000, '因为预算会批',      15)
                """)
            // 两件事,供「跨 ≥2 件事」用
            try db.execute(sql: """
                INSERT INTO matters (id, title, state, created_at, updated_at)
                VALUES (1, '产品定位', '活跃', ?, ?), (2, '排期', '活跃', ?, ?)
                """, arguments: [self.now, self.now, self.now, self.now])
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 造样例

    /// 一条立场 + 它在哪几件事上说过。`owner` 是这些行当前挂在谁名下。
    @discardableResult
    private func makeStance(evidence: [(line: Int, matter: Int)],
                            owner: Int64? = nil,
                            premiseLine: Int? = nil) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO self_stances (topic_key, direction, text, premise, premise_line_id, created_at)
                VALUES ('成本优先', ?, '先看成本再看方案', ?, ?, ?)
                """, arguments: [CardTrigger.Direction.support.rawValue,
                                 premiseLine == nil ? nil : "预算会批", premiseLine, self.now])
            let id = db.lastInsertedRowID
            for e in evidence {
                try db.execute(sql: """
                    INSERT INTO self_stance_evidence (stance_id, line_id, matter_id, said_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [id, e.line, e.matter, self.now])
                try db.execute(sql: """
                    INSERT INTO line_speakers (line_id, person_id, source, updated_at)
                    VALUES (?, ?, '用户确认', ?)
                    ON CONFLICT(line_id) DO UPDATE SET person_id = excluded.person_id
                    """, arguments: [e.line, owner ?? self.me, self.now])
            }
            if let p = premiseLine {
                try db.execute(sql: """
                    INSERT INTO line_speakers (line_id, person_id, source, updated_at)
                    VALUES (?, ?, '用户确认', ?)
                    ON CONFLICT(line_id) DO UPDATE SET person_id = excluded.person_id
                    """, arguments: [p, owner ?? self.me, self.now])
            }
            return id
        }
    }

    @discardableResult
    private func makePrinciple(from stance: Int64) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO self_principles (text, source_kind, stance_id, meets_predictive,
                                             meets_exclusive, created_at)
                VALUES ('先看成本再看方案', '系统提炼', ?, 1, 1, ?)
                """, arguments: [stance, self.now])
            return db.lastInsertedRowID
        }
    }

    private func col(_ table: String, _ column: String, _ id: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT \(column) FROM \(table) WHERE id = ?", arguments: [id])
        }
    }

    @discardableResult
    private func correct(_ line: Int, to person: Int64) throws -> AssignResult {
        try AssignSpeaker.assignSpeaker(lines: [LineID(line)], person: person, clusterTag: nil,
                                        source: .userConfirmed, confidence: nil,
                                        actor: .user, now: now, in: dbQueue)
    }

    // MARK: - 归一口径:库里那份就是 CardTrigger 那份

    /// 方向闭集播种自 `CardTrigger.Direction`,闭集外写不进去。
    ///
    /// 这是 `M3-0d` 立的跨层契约(发现层与卡片层共用同一个归一口径)在库里的物理落点。
    func testDirectionClosedSetIsSeededFromCardTrigger() throws {
        let rows = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT direction FROM stance_directions")
        }
        XCTAssertEqual(Set(rows), Set(CardTrigger.Direction.allCases.map(\.rawValue)))
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO self_stances (topic_key, direction, text, created_at)
                VALUES ('x', '大概支持吧', 'y', ?)
                """, arguments: [self.now])
        }, "闭集外的方向写进去了 —— 归一按 (主题 × 方向),方向一散,矛盾卡就永远出不来")
    }

    /// 🔴 `UNIQUE (topic_key, direction)` 是归一口径的**物理防线**。
    ///
    /// `CardTrigger.decide` 假设同主题下至多一条同方向记录。库里允许重复的话,
    /// 它会静默挑一条,而挑到哪条取决于查询顺序。
    func testTheSameTopicAndDirectionCannotBeStoredTwice() throws {
        try makeStance(evidence: [(10, 1)])
        XCTAssertThrowsError(try makeStance(evidence: [(11, 2)]),
                             "同一个 (主题 × 方向) 存了两条 —— CardTrigger 会静默挑一条")
    }

    /// 系统提炼的原则必须挂在一条立场上 —— 否则「降级为立场」降到哪去?
    func testASystemPrincipleWithoutAStanceIsRefused() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO self_principles (text, source_kind, stance_id, created_at)
                VALUES ('无源之水', '系统提炼', NULL, ?)
                """, arguments: [self.now])
        })
        // 用户自己写的可以没有来源立场
        XCTAssertNoThrow(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO self_principles (text, source_kind, stance_id, created_at)
                VALUES ('我自己写的', '你自己写的', NULL, ?)
                """, arguments: [self.now])
        })
    }

    // MARK: - 🔴 第 8 项前半:因错认产生的立场自动撤销

    /// 唯一的证据行被改走 ⇒ 立场撤销并移出「我自己」。
    func testAStanceWhoseOnlyEvidenceMovesAwayIsWithdrawn() throws {
        let s = try makeStance(evidence: [(10, 1)])
        try correct(10, to: 7)
        XCTAssertNotNil(try col("self_stances", "withdrawn_at", s),
                        "行被改走了,而这条立场还挂在「我自己」里")
    }

    /// 🔴 **改到「我」身上不许撤任何立场。**
    ///
    /// 这条是这一组的重心:写成「动过就撤」的话它会红 ——
    /// 而那种写法在生产上的表现是「用户每确认一次自己说的话,立场就少几条」。
    func testCorrectingALineOntoMeWithdrawsNothing() throws {
        let s = try makeStance(evidence: [(10, 1)], owner: 7)   // 本来挂在别人名下
        try correct(10, to: me)                                  // 认回自己
        XCTAssertNil(try col("self_stances", "withdrawn_at", s),
                     "把行认回自己反而把立场撤了 —— 判据写成了「动过就撤」")
        let left = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM self_stance_evidence WHERE stance_id = ?",
                             arguments: [s]) ?? -1
        }
        XCTAssertEqual(left, 1, "证据被误删了")
    }

    /// 还剩证据的立场不撤 —— 「因错认产生的」指的是**只靠错认才存在**的那些。
    func testAStanceWithRemainingEvidenceSurvives() throws {
        let s = try makeStance(evidence: [(10, 1), (11, 2)])
        try correct(10, to: 7)
        XCTAssertNil(try col("self_stances", "withdrawn_at", s),
                     "还有一条证据在,却整条撤了")
    }

    /// 前提的锚点行不再属于我 ⇒ **清空前提**,不是留着指向别人那句话。
    ///
    /// PRD §4.6.3:前提锚不到就留空显示「没说前提」,**不得由系统补写** ——
    /// 留着一个指向别人的前提,等于系统替用户编了一个前提。
    func testAPremiseAnchoredToSomebodyElseIsCleared() throws {
        let s = try makeStance(evidence: [(10, 1), (11, 2)], premiseLine: 12)
        XCTAssertNotNil(try col("self_stances", "premise", s))
        try correct(12, to: 7)
        XCTAssertNil(try col("self_stances", "premise", s), "前提还指着别人那句话")
        XCTAssertNil(try col("self_stances", "premise_line_id", s))
    }

    // MARK: - 🔴 第 8 项后半:证据不足 2 件事 ⇒ 降级为立场

    /// 跨事数掉到 2 以下 ⇒ 原则降级;**降级不是删除**(PRD §4.4.6「降级不丢弃」)。
    func testAPrincipleLosingItsSecondMatterIsDemotedNotDeleted() throws {
        let s = try makeStance(evidence: [(10, 1), (11, 2)])
        let p = try makePrinciple(from: s)
        XCTAssertNil(try col("self_principles", "demoted_at", p))

        try correct(11, to: 7)          // 第二件事那条证据被改走

        XCTAssertNotNil(try col("self_principles", "demoted_at", p),
                        "只剩 1 件事了还挂在「我的原则」里 —— 三条标准的第一条已经不成立")
        let still = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM self_principles WHERE id = ?",
                             arguments: [p]) ?? -1
        }
        XCTAssertEqual(still, 1, "原则被删了 —— PRD §4.4.6 写的是降级不丢弃")
        XCTAssertNil(try col("self_stances", "withdrawn_at", s), "立场也被撤了 —— 降级要降到立场上")
    }

    /// 🔴 **跨事数是数 distinct matter,不是数证据行。**
    ///
    /// ⚠️ 这条是照妖镜逼出来的:把实现里的 `COUNT(DISTINCT matter_id)` 改成
    /// `COUNT(matter_id)`,原来那两条测试**一条都不红** —— 它们的夹具里
    /// 「证据行数」与「跨事数」恰好相等,根本不区分这两种写法。
    /// **只测「对的能过」而夹具不区分错的写法,与没测一样。**
    ///
    /// 这里的夹具专门让两者分家:同一件事上说了两遍 + 另一件事一遍,
    /// 掉的是另一件事那条 ⇒ 剩 2 行证据,但只跨 1 件事 ⇒ 必须降级。
    /// PRD §4.4.6 那条标准的原文就是「同一件事里说三遍不算」。
    func testDemotionCountsDistinctMattersNotEvidenceRows() throws {
        let s = try makeStance(evidence: [(10, 1), (11, 1), (12, 2)])
        let p = try makePrinciple(from: s)
        try correct(12, to: 7)          // 掉的是唯一一条来自第 2 件事的证据

        let rows = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM self_stance_evidence WHERE stance_id = ?",
                             arguments: [s]) ?? -1
        }
        XCTAssertEqual(rows, 2, "夹具前提没成立:这里必须剩 2 行证据,才区分得出两种数法")
        XCTAssertNotNil(try col("self_principles", "demoted_at", p),
                        "剩 2 行证据但只跨 1 件事,却没降级 —— 数的是证据行,不是 distinct matter。"
                        + "PRD §4.4.6:「同一件事里说三遍不算」")
    }

    /// 仍跨着 2 件事的原则不降级。
    func testAPrincipleStillSpanningTwoMattersIsLeftAlone() throws {
        let s = try makeStance(evidence: [(10, 1), (11, 2), (12, 1)])
        let p = try makePrinciple(from: s)
        try correct(12, to: 7)          // 掉的是第 1 件事的重复证据
        XCTAssertNil(try col("self_principles", "demoted_at", p),
                     "还跨着 2 件事却被降级了 —— 跨事数是数 distinct matter,不是数证据行")
    }
}

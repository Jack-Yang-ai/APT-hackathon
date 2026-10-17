import XCTest
import GRDB
@testable import GrowthApp

/// 「人 → 我自己」三块(`M3-0e`,PRD §4.4.6 / §4.4.7)。
///
/// 🔴 **这一组守的是两条 PRD 明写的禁止项**,而两条被违反时界面都照常工作:
/// ① 原则**不用被引用次数排序**;② 盲区类观察**不在 20:00 后呈现**。
final class SelfPageProjectionTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-25T16:00:00+08:00"
    private let me = MatterSituation.mePersonID

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, ?, '2026-08-25', ?, ?)
                """, arguments: [self.now, SessionBridge.Source.recording,
                                 SessionBridge.Status.closed])
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'step-asr-v1', 'frozen', ?)
                """, arguments: [self.now])
            for i in 0..<4 {
                try db.execute(sql: """
                    INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms,
                                                  text, char_offset)
                    VALUES (?, 1, ?, ?, ?, ?, ?)
                    """, arguments: [10 + i, i, i * 1000, (i + 1) * 1000, "第 \(i) 句", i * 4])
            }
            try db.execute(sql: """
                INSERT INTO matters (id, title, state, created_at, updated_at)
                VALUES (1, '产品定位', '活跃', ?, ?), (2, '排期', '活跃', ?, ?)
                """, arguments: [self.now, self.now, self.now, self.now])
            try db.execute(sql: """
                INSERT INTO generation_batches (batch_id, producer, prompt_version, model_id, created_at)
                VALUES ('b1', '观察', 'observation/v1', 'deepseek-v4-flash', ?)
                """, arguments: [self.now])
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 造样例

    @discardableResult
    private func stance(_ topic: String, _ dir: CardTrigger.Direction,
                        matters: [Int64], premise: String? = nil,
                        lastSaid: String? = nil) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO self_stances (topic_key, direction, text, premise, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [topic, dir.rawValue, "\(topic) 的立场", premise, self.now])
            let id = db.lastInsertedRowID
            for (i, m) in matters.enumerated() {
                try db.execute(sql: """
                    INSERT INTO self_stance_evidence (stance_id, line_id, matter_id, said_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [id, 10 + i, m, lastSaid ?? self.now])
            }
            return id
        }
    }

    @discardableResult
    private func principle(_ text: String, from stance: Int64,
                           predictive: Bool, exclusive: Bool) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO self_principles (text, source_kind, stance_id, meets_predictive,
                                             meets_exclusive, created_at)
                VALUES (?, '系统提炼', ?, ?, ?, ?)
                """, arguments: [text, stance, predictive ? 1 : 0, exclusive ? 1 : 0, self.now])
            return db.lastInsertedRowID
        }
    }

    private func observation(_ statement: String, kind: ObservationKind?, count: Int = 3) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO person_observations (person_id, statement, occurrence_count, kind,
                                                 batch_id, created_at)
                VALUES (?, ?, ?, ?, 'b1', ?)
                """, arguments: [self.me, statement, count, kind?.rawValue, self.now])
        }
    }

    // MARK: - 🔴 禁止项①:原则不用次数排序

    /// **说过两遍的真原则,必须排在说过二十遍的口头禅前面。**
    ///
    /// PRD §4.4.6 特意写了「不用被引用次数排序」并给了理由:
    /// 次数是拿次数当替身,会让重复的废话晋升、说过两遍的真原则出局。
    /// ⇒ 排序按**三条标准的满足数**,同级才按最近出现时间。
    func testPrinciplesAreRankedByCriteriaNotByHowOftenTheyWereSaid() throws {
        // 口头禅:说了 20 次,但只跨 1 件事、两条软标准都没过 ⇒ 满足 0 条
        let catchphrase = try stance("先看成本", .support, matters: Array(repeating: 1, count: 1))
        try dbQueue.write { db in
            for i in 0..<20 {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO self_stance_evidence (stance_id, line_id, matter_id, said_at)
                    VALUES (?, ?, 1, ?)
                    """, arguments: [catchphrase, 10 + (i % 4), self.now])
            }
        }
        let loud = try principle("口头禅", from: catchphrase, predictive: false, exclusive: false)

        // 真原则:只说过两次,但跨 2 件事 + 两条软标准都过 ⇒ 满足 3 条
        let real = try stance("先问约束", .support, matters: [1, 2])
        let quiet = try principle("真原则", from: real, predictive: true, exclusive: true)

        let ranked = try dbQueue.read { db in try SelfPageProjection.principles(in: db) }
        XCTAssertEqual(ranked.map(\.id), [quiet, loud],
                       "排序把说得多的顶到了前面 —— PRD §4.4.6 明写不用次数排:"
                       + "次数是拿次数当替身,会让重复的废话晋升、说过两遍的真原则出局")
        XCTAssertEqual(ranked.first?.criteriaMet, 3)
        XCTAssertEqual(ranked.last?.criteriaMet, 0)
    }

    /// 「跨事复现」是**现数**出来的,不读缓存的数字(PRD 标了它「机械可判」)。
    func testCrossMatterCriterionIsCountedNotStored() throws {
        let s = try stance("先问约束", .support, matters: [1, 2])
        _ = try principle("真原则", from: s, predictive: false, exclusive: false)
        XCTAssertEqual(try dbQueue.read { db in
            try SelfPageProjection.principles(in: db).first?.criteriaMet
        }, 1, "跨 2 件事应当算 1 条标准")

        // 掉到只剩 1 件事 ⇒ 立刻变 0,不需要谁去更新任何列
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM self_stance_evidence WHERE matter_id = 2")
        }
        XCTAssertEqual(try dbQueue.read { db in
            try SelfPageProjection.principles(in: db).first?.criteriaMet
        }, 0, "证据掉了而标准数没跟着掉 —— 那个数是存下来的,不是数出来的")
    }

    /// 降级的原则**不在原则栏,但也没丢**(§4.4.6「降级不丢弃」)。
    func testDemotedPrinciplesLeaveTheListButAreStillThere() throws {
        let s = try stance("先问约束", .support, matters: [1, 2])
        let p = try principle("被降级的", from: s, predictive: true, exclusive: true)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE self_principles SET demoted_at = ? WHERE id = ?",
                           arguments: [self.now, p])
        }
        XCTAssertTrue(try dbQueue.read { db in try SelfPageProjection.principles(in: db) }.isEmpty)
        XCTAssertEqual(try dbQueue.read { db in
            try SelfPageProjection.demotedPrinciples(in: db).map(\.id)
        }, [p], "降级之后就找不着了 —— PRD 写的是降级不丢弃")
    }

    // MARK: - 立场

    /// 冲突的立场**并列**,各自带前提和时间;**系统不做调和**。
    /// 前提为空显示「没说前提」,**不得由系统补写**。
    ///
    /// 🔴 **顺序是时间序,不是方向的字典序** —— 冲突的三种呈现里有一种是「观点演变」,
    /// PRD 要的是「你从 X 变成了 Y」的**回放**。按方向排,那句回放会时对时错,
    /// 而界面照常显示两条并列的立场。
    func testConflictingStancesStandSideBySideInChronologicalOrder() throws {
        // 先「支持」(8/01),后改成「反对」(8/20)
        try stance("要不要自研", .support, matters: [1], premise: "预算会批",
                   lastSaid: "2026-08-01T10:00:00+08:00")
        try stance("要不要自研", .oppose, matters: [2],
                   lastSaid: "2026-08-20T10:00:00+08:00")     // 没说前提
        let all = try dbQueue.read { db in try SelfPageProjection.stances(in: db) }
        let conflicts = SelfPageProjection.conflicts(all)
        XCTAssertEqual(conflicts["要不要自研"]?.count, 2, "冲突被合并了 —— PRD 禁止挑一边留下")
        XCTAssertEqual(conflicts["要不要自研"]?.map(\.direction),
                       [CardTrigger.Direction.support.rawValue, CardTrigger.Direction.oppose.rawValue],
                       "顺序不是时间序 —— 「你从 X 变成了 Y」那句回放会说反")
        XCTAssertEqual(conflicts["要不要自研"]?.first?.premiseText, "预算会批")
        XCTAssertEqual(conflicts["要不要自研"]?.last?.premiseText, "没说前提",
                       "前提空着却编了一句 —— PRD §4.6.3 明写不得由系统补写")
    }

    // MARK: - 🔴 禁止项②:盲区类不在 20:00 后呈现

    /// **20:00 之后,盲区类不出现;白天全都在。**
    ///
    /// R-D 那条红线的全部意义就是不让盲区观察在睡前弹出来 ——
    /// 而违反了界面照常工作,没有任何东西会报错。
    func testBlindSpotObservationsAreHiddenAfterCurfew() throws {
        try observation("你在 5 件事上都是先问成本", kind: .behaviorPattern)
        try observation("有 3 件事你都是最后一个表态的", kind: .participationGap)
        try observation("同一种困境出现了 4 次", kind: .recurringPredicament)

        let day = try dbQueue.read { db in try SelfPageProjection.observations(hour: 14, in: db) }
        XCTAssertEqual(day.count, 3, "白天应该全都在")

        let night = try dbQueue.read { db in
            try SelfPageProjection.observations(hour: ObservationKind.blindSpotCurfewHour, in: db)
        }
        XCTAssertEqual(night.count, 1, "20:00 之后还在呈现盲区类:\(night.map(\.statement))")
        XCTAssertFalse(night.contains { $0.isBlindSpot })
    }

    /// 🔴 **类型为空时按盲区处置(默认从严)。**
    ///
    /// v28 落地过的老观察没有类型。随便当成非盲区,等于替一条谁都没读过的观察
    /// 断言它可以睡前弹出来。
    func testAnUntypedObservationIsTreatedAsABlindSpot() throws {
        try observation("老数据,没有类型", kind: nil)
        XCTAssertEqual(try dbQueue.read { db in
            try SelfPageProjection.observations(hour: 21, in: db)
        }.count, 0, "没有类型的观察在 21:00 被呈现了 —— 默认该从严")
    }

    /// 顺序:**先亮点与规律,后盲区**(§4.4.7)。
    func testObservationsPutStrengthsFirstAndBlindSpotsLast() throws {
        try observation("盲区那条", kind: .recurringPredicament)
        try observation("规律那条", kind: .behaviorPattern)
        try observation("亮点那条", kind: .overlookedStrength)
        let ordered = try dbQueue.read { db in try SelfPageProjection.observations(hour: 10, in: db) }
        XCTAssertEqual(ordered.map(\.statement), ["亮点那条", "规律那条", "盲区那条"],
                       "打开「我自己」第一眼看到的不该是自己的短处")
    }

    /// 播种表与 `ObservationKind` 逐行一致(Swift ↔ 库,与 PRD 那道对撞互补)。
    func testSeededObservationKindsMatchSwift() throws {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, band, is_blindspot FROM observation_kinds")
        }
        XCTAssertEqual(rows.count, ObservationKind.allCases.count)
        for k in ObservationKind.allCases {
            let r = rows.first { $0["kind"] == k.rawValue }
            XCTAssertEqual(r?["band"], k.band.rawValue, "「\(k.rawValue)」的呈现档漂了")
            XCTAssertEqual(r?["is_blindspot"] as Int?, k.isBlindSpot ? 1 : 0,
                           "「\(k.rawValue)」的盲区判定漂了 —— 20:00 那条规则会跟着错")
        }
    }

    /// 写侧的桩必抛。
    func testEveryUnwiredWriteThrows() {
        let w = UnimplementedSelfPageWriting()
        XCTAssertThrowsError(try w.promote(observation: 1, now: ""))
        XCTAssertThrowsError(try w.editPrinciple(1, to: "x", now: ""))
        XCTAssertThrowsError(try w.setObservationsEnabled(false, now: ""))
    }
}

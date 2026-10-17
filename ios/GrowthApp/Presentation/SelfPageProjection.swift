import Foundation
import GRDB

/// 「人 → 我自己」三块的展示模型(`M3-0e`,对 PRD §4.4.6 / §4.4.7)。
///
/// ```
/// ┌ 关于你的观察(系统给的草稿)   ← §4.4.7
/// ├ 我的原则(已确认的判断方式)
/// └ 我的立场(按事分组,冲突的并列展示)
/// ```
///
/// ## 🔴 两条 PRD 明写的**禁止项**,都落在这一层
///
/// | 禁止 | 出处 | 违反了会怎样 |
/// |---|---|---|
/// | **原则不用被引用次数排序** | §4.4.6「次数是拿次数当替身,会让重复的废话晋升、说过两遍的真原则出局」 | 排序看着很合理,而排在最前面的是口头禅 |
/// | **盲区类观察不在 20:00 后呈现** | R-D / §4.4.7 | 一条盲区观察在睡前弹出来 |
///
/// 两条的共同点:**违反了界面照常工作**,没有任何东西会报错。
enum SelfPageProjection {

    // MARK: - 我的原则

    struct Principle: Equatable, Identifiable {
        let id: Int64
        let text: String
        /// `系统提炼` / `你自己写的`。
        let sourceKind: String
        /// 三条标准满足了几条(§4.4.6)。**排序按它**,不按次数。
        let criteriaMet: Int
        /// 最近一次出现。同级内按它排(§4.4.6)。
        let lastSeenAt: String?
        /// 被降级了吗(证据不足 2 件事 ⇒ 降为立场,§3.2.3 第 8 项)。
        let demoted: Bool
    }

    /// 我的原则。**只列没被降级的** —— 降级的那些出现在立场那一栏。
    ///
    /// 🔴 **排序:三条标准的满足数降序,同级按最近出现时间降序。**
    /// PRD §4.4.6 特意写了「**不用被引用次数排序**」并给了理由 ——
    /// 次数是拿次数当替身,会让重复的废话晋升、说过两遍的真原则出局。
    static func principles(in db: Database) throws -> [Principle] {
        try fetchPrinciples(db, demoted: false)
    }

    /// 被降级的原则 —— 它们**显示为立场**(§4.4.6「降级不丢弃」)。
    static func demotedPrinciples(in db: Database) throws -> [Principle] {
        try fetchPrinciples(db, demoted: true)
    }

    private static func fetchPrinciples(_ db: Database, demoted: Bool) throws -> [Principle] {
        try GRDB.Row.fetchAll(db, sql: """
            SELECT p.id, p.text, p.source_kind, p.demoted_at,
                   -- 🔴 「跨事复现」那条标准是**机械可判**的(PRD §4.4.6),所以现数,
                   --    不读任何缓存的数字。存一份就是把机械可判变成了没人核过。
                   (p.meets_predictive + p.meets_exclusive
                    + (SELECT COUNT(DISTINCT e.matter_id) >= 2 FROM self_stance_evidence e
                        WHERE e.stance_id = p.stance_id)) AS met,
                   (SELECT MAX(e.said_at) FROM self_stance_evidence e
                     WHERE e.stance_id = p.stance_id) AS last_seen
              FROM self_principles p
             WHERE p.demoted_at IS \(demoted ? "NOT NULL" : "NULL")
             ORDER BY met DESC, last_seen DESC, p.id DESC
            """).map {
            Principle(id: $0["id"], text: $0["text"], sourceKind: $0["source_kind"],
                      criteriaMet: $0["met"], lastSeenAt: $0["last_seen"],
                      demoted: ($0["demoted_at"] as String?) != nil)
        }
    }

    // MARK: - 我的立场

    struct Stance: Equatable, Identifiable {
        let id: Int64
        let topicKey: String
        let direction: String
        let text: String
        /// 前提。**空就是空** —— 界面显示「没说前提」,不得由系统补写(§4.4.6 / PRD §4.6.3)。
        let premise: String?
        let premiseLineID: Int64?
        /// 说过几次、最近一次什么时候(冲突并列时「各自带前提和时间」)。
        let saidCount: Int
        let lastSaidAt: String?
        /// 这条立场在哪几件事上出现过 —— 界面「按事分组」用。
        let matterIDs: [Int64]

        /// 界面上那句前提。**不编** —— nil 时说的是「没说前提」,不是猜一个。
        var premiseText: String { premise ?? "没说前提" }
    }

    /// 我的立场,按主题分组(同主题多方向 = 冲突,**并列展示,系统不做调和**)。
    static func stances(in db: Database) throws -> [Stance] {
        try GRDB.Row.fetchAll(db, sql: """
            SELECT s.id, s.topic_key, s.direction, s.text, s.premise, s.premise_line_id,
                   (SELECT COUNT(*) FROM self_stance_evidence e WHERE e.stance_id = s.id) AS n,
                   (SELECT MAX(e.said_at) FROM self_stance_evidence e WHERE e.stance_id = s.id) AS last_said
              FROM self_stances s
             WHERE s.withdrawn_at IS NULL
             -- 🔴 **同一主题内按「最近说的时间」正序** —— 冲突的三种呈现里有一种是
             -- 「观点演变」:PRD §4.4.6 要的是**「你从 X 变成了 Y」的回放**。
             -- 按方向的字典序排,那句回放就会随「支持」「反对」两个词的编码顺序
             -- 时对时错,而界面照常显示两条并列的立场,没有任何东西会报错。
             -- 末尾用 id 兜底,保证全序(同一秒说的两条不许每次换位置)。
             ORDER BY s.topic_key, last_said, s.id
            """).map { r in
            Stance(id: r["id"], topicKey: r["topic_key"], direction: r["direction"],
                   text: r["text"], premise: r["premise"], premiseLineID: r["premise_line_id"],
                   saidCount: r["n"], lastSaidAt: r["last_said"],
                   matterIDs: (try? Int64.fetchAll(db, sql: """
                       SELECT DISTINCT matter_id FROM self_stance_evidence
                        WHERE stance_id = ? AND matter_id IS NOT NULL ORDER BY matter_id
                       """, arguments: [r["id"] as Int64])) ?? [])
        }
    }

    /// 同一主题下有几个方向 ⇒ 冲突。**并列,不合并、不挑一边、不编和解说法**(§4.4.6 禁止项)。
    static func conflicts(_ all: [Stance]) -> [String: [Stance]] {
        Dictionary(grouping: all, by: \.topicKey).filter { $0.value.count > 1 }
    }

    // MARK: - 关于你的观察

    struct Observation: Equatable, Identifiable {
        let id: Int64
        let statement: String
        /// `ObservationKind` 的 rawValue;老数据可能为空。
        let kind: String?
        let occurrenceCount: Int
        let evidenceCount: Int
        let statBasis: String?

        /// 盲区类?**类型为空时算盲区(默认从严)** ——
        /// 随便当成非盲区,等于替一条谁都没读过的观察断言它可以睡前弹出来。
        var isBlindSpot: Bool {
            kind.flatMap(ObservationKind.init(rawValue:))?.isBlindSpot ?? true
        }
        var band: Int {
            kind.flatMap(ObservationKind.init(rawValue:))?.band.rawValue
                ?? ObservationKind.Band.blindSpot.rawValue
        }
    }

    /// 关于我的观察。
    ///
    /// 🔴 **`hour` 是调用方给的真实时刻,没有默认值。**
    /// 给一个 `= 12` 之类的默认值,等于把「现在不是睡前」这个假设藏进签名里 ——
    /// 而 R-D 那条红线的全部意义就是不让盲区类在睡前出现。
    /// 藏在默认值里的假设在这个仓已经害过两次(见 `PendingBlock.init` 那段)。
    static func observations(hour: Int, in db: Database) throws -> [Observation] {
        let all = try GRDB.Row.fetchAll(db, sql: """
            SELECT o.id, o.statement, o.kind, o.occurrence_count, o.stat_basis,
                   (SELECT COUNT(*) FROM observation_evidence e
                     WHERE e.observation_id = o.id) AS n
              FROM person_observations o
             WHERE o.person_id = \(MatterSituation.mePersonID) AND o.withdrawn_at IS NULL
             ORDER BY o.created_at DESC, o.id DESC
            """).map {
            Observation(id: $0["id"], statement: $0["statement"], kind: $0["kind"],
                        occurrenceCount: $0["occurrence_count"], evidenceCount: $0["n"],
                        statBasis: $0["stat_basis"])
        }
        // ① 20:00 之后不呈现盲区类(R-D)。**是不呈现,不是删** —— 明天白天它还在。
        let visible = hour >= ObservationKind.blindSpotCurfewHour ? all.filter { !$0.isBlindSpot } : all
        // ② 先亮点与规律,后盲区(§4.4.7 顺序)。稳定排序:同档保持原来的时间序。
        return visible.enumerated().sorted {
            $0.element.band != $1.element.band ? $0.element.band < $1.element.band
                                               : $0.offset < $1.offset
        }.map(\.element)
    }
}

/// 「我自己」的**写侧动作契约**。🔴 未实现的一律抛,绝不 no-op(§3.2)。
protocol SelfPageWriting {
    /// 把一条观察升格(§4.4.6「观察是系统的草稿,原则与立场是用户确认过的定稿」)。
    /// - Note: 升成原则还是立场,**由三条标准决定,不由用户选** ——
    ///   只满足一两条的降级显示为立场(§4.4.6「降级不丢弃」)。
    func promote(observation id: Int64, now: String) throws
    /// 编辑一条原则。保存后来源标记变为「你自己写的」(§4.4.9)。
    func editPrinciple(_ id: Int64, to text: String, now: String) throws
    /// 关掉「关于你的观察」整块(§4.4.7 可关闭)。
    func setObservationsEnabled(_ on: Bool, now: String) throws
}

struct UnimplementedSelfPageWriting: SelfPageWriting {
    struct NotWired: Error, CustomStringConvertible {
        let action: String
        /// ⚠️ 这句会显示给用户,不写任务号(挡着它的是 `M3-B4` / `M3-F4`)。
        var description: String { "「我自己」的「\(action)」还没做出来。" }
    }
    func promote(observation id: Int64, now: String) throws { throw NotWired(action: "升格") }
    func editPrinciple(_ id: Int64, to text: String, now: String) throws { throw NotWired(action: "编辑原则") }
    func setObservationsEnabled(_ on: Bool, now: String) throws { throw NotWired(action: "开关") }
}

import Foundation
import GRDB

// 「事」这一格的第一版:**零散悬点区**(PRD §4.3.8,P0)。
//
// ## 为什么第一版是它,而不是「事」本身
//
// §4.3 的「事」是一个有状态机、有提名三层、有进展归属的对象(M2)。
// 而**跨场次的承诺与悬点现在就在库里** —— `summary_commitments` /
// `summary_pendings` 每场都在产出,只是至今没有任何一个界面读它们。
//
// §4.3.8 那句「零散悬点区常驻底部」正是这些东西的落点,而且它是 P0。
// ⇒ **零新表**就能让「事」这一格显示真数据。
//
// 🔴 ~~**给 `matters` / `discoveries` / `cards` 建表是给一个没有生产者的仓库盖厂房。**~~
// **2026-08-18:这句对 `matters` 已经不成立了,连着前提一起重写(仓规 6)。**
//   · 当时的前提是「产出器要到 M2/M3 才有」—— 那一刻是真的;
//   · 而 `M2-0c` 建了 `matters` 那几张表(迁移 v19),`M2-B1` 提名产出器就在同一个冲刺里。
//   ⇒ 事的展示模型现在长在 `MatterBoardProjection`,本文件只管**零散悬点区**那一块。
// 对 `discoveries` / `cards` 原判仍然成立:产出器是 §4.5.4 / §4.6(M3),现在库里一条都不会有。
enum MattersProjection {

    /// 一条悬着的事。
    struct LooseEnd: Equatable, Identifiable {
        enum Kind: String { case commitment = "承诺", pending = "待定" }

        var id: String { "\(kind.rawValue)#\(rowID)" }
        let rowID: Int64
        let kind: Kind
        /// 正文(承诺是「做什么」,待定是「悬着什么」)。
        let text: String
        /// 逐字引文 —— 三项校验打的就是它,所以它一定在原话里。
        let quote: String
        /// 跳原话用。
        let lineID: Int64
        let sessionID: Int64
        /// 场次起点,本地时区 ISO。界面按字面截钟点,别再过一次时区转换。
        let sessionStartedAt: String
        /// 谁说的。**可空,而且空是常态** —— 见下面那段注释。
        let speaker: String?
        /// 🔴 **这一条还没通过三项校验。**
        ///
        /// 今天(2026-08-17)库里**每一条都是挂起**:`ExtractValidate:173`
        /// 要求 `line.personID != nil`,而 `writeClusterTags` 写的 person 恒为 nil
        /// (簇标签不是身份)—— 所以归属那一项永远不过。
        ///
        /// ⚠️ **不能因此把它们滤掉**:滤掉的话这一格永远是空的,
        /// 而库里明明有几十条真实的承诺与悬点。也**不能当成已确认的显示**:
        /// 那是拿一条没核验的信息冒充核验过的。
        /// ⇒ 照实显示 + 标出来,让用户自己判断。理由就写在这儿。
        let unverified: Bool
        let unverifiedReason: String?
    }

    /// 跨场次的承诺与悬点,时间倒序。
    ///
    /// **只读当前生效的那一版转写**(`sessions.active_transcript_id`)——
    /// 不筛的话会把重转写之前那一版的承诺也捞出来,而用户在界面上
    /// 根本看不到那一版,却会看到它产出的条目。
    static func looseEnds(in db: Database, limit: Int = 100) throws -> [LooseEnd] {
        var out: [LooseEnd] = []
        for (table, textColumn, kind) in [
            ("summary_commitments", "what",  LooseEnd.Kind.commitment),
            ("summary_pendings",    "issue", LooseEnd.Kind.pending),
        ] {
            for row in try Row.fetchAll(db, sql: """
                SELECT x.id AS rid, x.\(textColumn) AS body, x.quote AS quote,
                       x.line_id AS line_id, x.pending AS pending,
                       x.pending_reason AS why,
                       t.session_id AS sid, s.started_at AS started,
                       ls.person_id AS pid, ls.cluster_tag AS tag
                  FROM \(table) x
                  JOIN transcripts t ON t.id = x.transcript_id
                  JOIN sessions    s ON s.id = t.session_id
                                    AND s.active_transcript_id = t.id
                  LEFT JOIN line_speakers ls ON ls.line_id = x.line_id
                 ORDER BY s.started_at DESC, x.seq
                 LIMIT ?
                """, arguments: [limit]) {
                out.append(LooseEnd(
                    rowID: row["rid"], kind: kind,
                    text: row["body"], quote: row["quote"],
                    lineID: row["line_id"], sessionID: row["sid"],
                    sessionStartedAt: row["started"],
                    speaker: nil,   // 名字在下面统一填 —— 编号只有一个出处
                    unverified: (row["pending"] as Int? ?? 0) == 1,
                    unverifiedReason: row["why"]))
            }
        }

        // 说话人的称呼**只从 `SpeakerNaming` 取**(全 App 唯一一套编号)。
        // 各处自己按看到的人从 1 编起,是 2026-08-14 实拍过的那个 bug:
        // 同一个人在两屏上是两个号,用户会确认错人。
        let names = try SpeakerNaming.labels(in: db)
        let keyByLine = try lineKeys(for: out.map(\.lineID), in: db)
        out = out.map { e in
            LooseEnd(rowID: e.rowID, kind: e.kind, text: e.text, quote: e.quote,
                     lineID: e.lineID, sessionID: e.sessionID,
                     sessionStartedAt: e.sessionStartedAt,
                     speaker: keyByLine[e.lineID].flatMap { names[$0] },
                     unverified: e.unverified, unverifiedReason: e.unverifiedReason)
        }
        return out.sorted { $0.sessionStartedAt > $1.sessionStartedAt }
    }

    /// `line_id → 归属键`。键的形状由 `SpeakerNaming.keyExpr` 定死。
    private static func lineKeys(for lineIDs: [Int64], in db: Database) throws -> [Int64: String] {
        guard !lineIDs.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: lineIDs.count).joined(separator: ",")
        var out: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT ls.line_id AS line_id,
                   \(SpeakerNaming.keyExpr(session: "t.session_id")) AS who
              FROM line_speakers ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
             WHERE ls.line_id IN (\(marks))
            """, arguments: StatementArguments(lineIDs)) {
            if let who = row["who"] as String? { out[row["line_id"]] = who }
        }
        return out
    }

    static func looseEnds(in reader: some DatabaseReader,
                          limit: Int = 100) throws -> [LooseEnd] {
        try reader.read { try looseEnds(in: $0, limit: limit) }
    }
}

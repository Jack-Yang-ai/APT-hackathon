import Foundation
import GRDB

/// **`matter_timeline` 与 `matter_progress_cards` 的唯一写入口**(M2-B3,迁移 v23)。
///
/// 🔴 **为什么一开始就定唯一入口** —— 铁律 3 的形状。
/// 旧仓的 `line_speakers` 没有统一入口,实测悬空 1979 条;
/// 这两张表今天还是空的,**现在定入口的成本是零,以后定要先把散出去的路收回来**。
///
/// ## 规格出处
///
/// PRD §4.3.6(三档处置)、技术方案 §4.5.4(边界)、§4.5.6(吸收 `reconcile` 的判决范式)。
enum MatterProgressStore {

    struct Landed: Equatable {
        /// 静默入脉络的条数(高档)。
        let toTimeline: Int
        /// 出确认卡的条数(中档)。
        let toCards: Int
        /// 重放撞上幂等闸、这次没重复落的条数。
        ///
        /// 🔴 **要报出来,不能当成 0 条落库。** 「这一场没有进展」与
        /// 「这一场的进展上一拍已经落过了」处置完全不同,而两者都返回 0。
        let alreadyLanded: Int
    }

    /// 落一批判完的进展。
    ///
    /// - `.tiered(.high)`   ⇒ 静默入脉络,`actor = system-cascade`;
    /// - `.tiered(.medium)` ⇒ 出确认卡,等用户判;
    /// - `.tiered(.low)`    ⇒ **不落这两张表**(不挂该事;含未兑现承诺/未答问题进
    ///   零散悬点区那条另走 —— 悬点区是 `M2-B4` 的地盘,不在这个入口里做);
    /// - `.held`            ⇒ **一个字都不写**。它是「还判不了」,不是一档;
    ///   写进任何一张表都会让 `M2-L4` 判的那个静默档判准率失真。
    @discardableResult
    static func land(_ judged: [ProgressAttributionRunner.Judged],
                     sessionID: Int64, in db: Database, now: String) throws -> Landed {
        var timeline = 0, cards = 0, dup = 0
        for j in judged {
            guard case .tiered(let v) = j.disposition else { continue }
            let p = j.progress
            switch v.tier {
            case .high:
                // §4.5.6:先落判决,再落内容。**不新建第二套判决语义** ——
                // 悬点关闭 = FULFILL、立场/前提变化 = UPDATE,都照 §2.2 那套记在
                // `judgments` 里,`action` 用 `progress_<kind>`。
                //
                // ⚠️ `actor` 是 `system-cascade` 而不是 `system`:这条进展是被
                // 「这一场抽取出了什么」触发的,**有「因为」**(`AssignSpeaker` 的
                // `Actor` 注释把这条区别写得很清楚)。审计链的起点是那一行原话,
                // 所以 `basis_line_ids` 必须带上它 —— 断了链,
                // 「这条脉络为什么这么说」就再也答不出来。
                try db.execute(sql: """
                    INSERT INTO judgments
                      (decided_at, actor, caused_by, undoes, action, target_kind, target_id,
                       payload, basis_line_ids)
                    VALUES (?, 'system-cascade', NULL, NULL, ?, 'matter', ?, ?, ?)
                    """, arguments: [now, "progress_\(p.kind)", "\(p.matterID)",
                                     #"{"question_id":\#(p.questionID.map(String.init) ?? "null")}"#,
                                     "[\(p.lineID)]"])
                if try insertTimeline(p, sessionID: sessionID, now: now, in: db) {
                    timeline += 1
                } else {
                    dup += 1
                }
            case .medium:
                if try insertCard(p, sessionID: sessionID, now: now, in: db) {
                    cards += 1
                } else {
                    dup += 1
                }
            case .low:
                continue
            }
        }
        return Landed(toTimeline: timeline, toCards: cards, alreadyLanded: dup)
    }

    /// 返回 `false` = 撞了幂等闸(这一条上一拍已经落过)。
    ///
    /// ⚠️ 用 `INSERT OR IGNORE` + 看行数,**不是先 SELECT 再 INSERT** ——
    /// 后者在两拍并发时会双双查到「没有」然后双双插入,而唯一索引会让第二条抛,
    /// 一路抛穿之后这一场的任务停在 `running`(本仓踩过的形状)。
    private static func insertTimeline(_ p: ProgressAttributionRunner.Progress,
                                       sessionID: Int64, now: String,
                                       in db: Database) throws -> Bool {
        try db.execute(sql: """
            INSERT OR IGNORE INTO matter_timeline (matter_id, at, summary, session_id, line_id)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [p.matterID, now, p.summary, sessionID, p.lineID])
        return db.changesCount > 0
    }

    private static func insertCard(_ p: ProgressAttributionRunner.Progress,
                                   sessionID: Int64, now: String,
                                   in db: Database) throws -> Bool {
        try db.execute(sql: """
            INSERT OR IGNORE INTO matter_progress_cards
              (matter_id, question_id, session_id, line_id, quote, kind, summary, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [p.matterID, p.questionID, sessionID, p.lineID,
                             p.quote, p.kind, p.summary, now])
        return db.changesCount > 0
    }
}

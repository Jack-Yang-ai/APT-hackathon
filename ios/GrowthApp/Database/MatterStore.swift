import Foundation
import GRDB

/// `MatterWriting` 的真实现(M2-B2 第二段),替掉 `MatterWritingStub`。
///
/// ## 一个必须裁的语义:提名行与 `matters` 行是什么关系
///
/// v19 同时有 `matter_nominations` 和 `matters`(六态含「候选」),这两者的关系
/// 规格里没写死。**裁决:提名行是生成物,`matters` 行在用户第一次动作时才建。**
///
/// 理由是 PRD §4.3.5 明写**生成层不限量** —— 给每条生成的候选都建一个 `matters` 行,
/// 会把状态机和活跃计数灌满一堆用户从没看过的东西;而「30 天未处理 ⇒ 静默拒绝」
/// 用 `matter_nominations.created_at` 就能判,不需要 `matters` 行先存在。
///
/// 三键落下来分别是:
///
/// | 键 | 做什么 |
/// |---|---|
/// | 单独盯着它 | 建 `matters`(候选)→ 走状态机到「活跃」。**两步都留痕** ⇒ 账本上能看出「它生为候选、被你提上来」 |
/// | 不用 | 建 `matters`(候选)→ 走到「已拒绝」。**必须建行** —— PRD 要求拒绝过的仍可搜索找回 |
/// | 说不准 | 建 `matters`(候选)+ 写一条判断,**状态不变** |
///
/// ## 「说不准」为什么也要写库
///
/// PRD §4.3.4 的流转表里真有「候选 → 候选(用户,点说不准)」这一行。
/// 它不改状态,但**必须留痕**:「看过并决定先不决定」与「还没看过」是两件事,
/// 而 30 天静默拒绝那条规则要靠这个区分 —— 不写的话,一条用户主动搁置的候选
/// 会在第 30 天被系统当成「没人管」悄悄拒掉。
struct MatterStore: MatterWriting {
    let db: DatabaseQueue

    // MARK: - 三键

    func promote(nomination id: Int64, now: String) throws -> Int64 {
        try db.write { d in
            let m = try adopt(id, now: now, in: d)
            // 满员在这里抛(`MatterStateMachine` 判的),而**上一步建的行会随事务回滚** ——
            // 所以「满员被拒」之后库里不会留下一个半吊子的候选。
            try MatterStateMachine.transition(m, to: "活跃", by: .user, now: now, in: d)
            return m
        }
    }

    func dismiss(nomination id: Int64, now: String) throws {
        try db.write { d in
            let m = try adopt(id, now: now, in: d)
            try MatterStateMachine.transition(m, to: "已拒绝", by: .user, now: now, in: d)
        }
    }

    func defer_(nomination id: Int64, now: String) throws {
        try db.write { d in
            let m = try adopt(id, now: now, in: d)
            // 状态不变,只留痕。**不走 `transition`** —— 它会因为
            // `NEW.state = OLD.state` 而什么都不做,那样这条判断就丢了。
            try d.execute(sql: """
                INSERT INTO judgments
                  (decided_at, actor, caused_by, undoes, action, target_kind, target_id, payload)
                VALUES (?, 'user', NULL, NULL, 'matter_defer', 'matter', ?, '{"note":"说不准"}')
                """, arguments: [now, "\(m)"])
        }
    }

    // MARK: - 生命周期

    func close(matter id: Int64, now: String) throws {
        try db.write { try MatterStateMachine.transition(id, to: "已结案", by: .user, now: now, in: $0) }
    }

    func sleep(matter id: Int64, now: String) throws {
        try db.write { try MatterStateMachine.transition(id, to: "沉睡", by: .user, now: now, in: $0) }
    }

    func wake(matter id: Int64, now: String) throws {
        try db.write { try MatterStateMachine.transition(id, to: "活跃", by: .user, now: now, in: $0) }
    }

    func closeQuestion(_ id: Int64, now: String) throws {
        try db.write { d in
            guard let matterID = try Int64.fetchOne(d, sql: """
                SELECT matter_id FROM matter_open_questions WHERE id = ? AND closed_at IS NULL
                """, arguments: [id])
            else { throw MatterActionFailure.notFound(kind: "悬点", id: id) }
            // 关悬点是用户动作 ⇒ 写 `judgments`(H5 §0.3 缺口 B:用户动作一律进判断库,
            // 不在别处再记一份状态)。`closed_at` 是那条判断的**投影**,不是第二个出处 ——
            // 界面要按 `matter_id` 数未关悬点,每次去判断库里重放 undo 链太贵。
            try d.execute(sql: """
                INSERT INTO judgments
                  (decided_at, actor, caused_by, undoes, action, target_kind, target_id, payload)
                VALUES (?, 'user', NULL, NULL, 'close_question', 'question', ?, ?)
                """, arguments: [now, "\(id)", #"{"matter_id":\#(matterID)}"#])
            try d.execute(sql: "UPDATE matter_open_questions SET closed_at = ? WHERE id = ?",
                          arguments: [now, id])
        }
    }

    // MARK: - 把提名行认领成一件事

    /// 建 `matters`(候选)并把提名行指向它。**已经认领过就直接返回原来那件** ——
    /// 重复点(网络慢时用户点两下)不该造出两件事。
    private func adopt(_ nominationID: Int64, now: String, in d: Database) throws -> Int64 {
        guard let row = try Row.fetchOne(d, sql: """
            SELECT title, matter_id FROM matter_nominations WHERE id = ?
            """, arguments: [nominationID])
        else { throw MatterActionFailure.notFound(kind: "候选", id: nominationID) }
        if let existing = row["matter_id"] as Int64? { return existing }

        try d.execute(sql: """
            INSERT INTO matters (title, state, created_at, updated_at) VALUES (?, '候选', ?, ?)
            """, arguments: [row["title"] as String, now, now])
        let m = d.lastInsertedRowID
        try d.execute(sql: "UPDATE matter_nominations SET matter_id = ? WHERE id = ?",
                      arguments: [m, nominationID])
        return m
    }
}

import Foundation
import GRDB

/// 「说不准 —— 看下一个」点过之后记下来(`M2-认11`,用户 2026-09-02 报)。
///
/// ## 🔴 它修的是「点了说不准,退出去再进来那段还在」
///
/// 原来的 `skip()` 只做 `index += 1` —— **一个字都不写库**。
/// 退出去再进来,`load()` 重新查 `pendingSpeakers`,那个候选原封不动排在原位。
/// 用户点「说不准」的意思是「我现在判不了,别再问我」,而它理解成了「翻一页」。
///
/// ## 为什么不是把那些行丢掉
///
/// 「说不准」不是「这些行不重要」。丢掉的话那些行**永久没有说话人**,
/// 而且用户再也找不到它们。⇒ 只从**待确认**里拿掉,仍然挂在「改一改」那一屏上,
/// 想起来了随时能回去认(同 `PeopleProjection.confirmedSpeakers` 那条路)。
///
/// ⚠️ 记的是**说话人键**(`SpeakerNaming.keyExpr` 的产物),不是行 ——
/// 行会被重判、会换簇,而用户拒绝回答的是「这个说话人是谁」这个问题。
enum SpeakerSkips {

    /// 记下「这个说话人我说不准」。同一个键点多次只留一条(键是主键)。
    static func record(_ key: String, now: String, in writer: some DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO speaker_skips (who, created_at) VALUES (?, ?)
                ON CONFLICT(who) DO UPDATE SET created_at = excluded.created_at
                """, arguments: [key, now])
        }
    }

    /// 已经说不准过的说话人键。
    static func keys(in db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT who FROM speaker_skips"))
    }
}

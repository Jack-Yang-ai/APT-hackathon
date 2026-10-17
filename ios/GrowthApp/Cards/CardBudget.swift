import Foundation
import GRDB

/// 卡片推送预算 `B` 的自适应(`M3-B2`,契约 `docs/技术方案.md` §4.6.1)。
///
/// ## 信号只有一个:处理率
///
/// ```
/// rate = 最近 7 天「被用户做出任意出口动作」的推送卡数 / 同期推送出去的卡数
/// ```
///
/// 「任意出口动作」**含搁置、也含「这问题问得不对」**。
///
/// 🔴 **它衡量的是打扰的接受度,不是提问质量。** 提问质量有自己的通道 ——
/// 「这问不对」按 PRD §5.3 对同类提问降权。两条混在一起的后果很具体:
/// 用户老老实实点「这问不对」反而把 `rate` 顶高,系统于是**问得更多**。
enum CardBudget {

    /// 初始值(PRD §4.1.8)。
    static let initialValue = 3
    static let minValue = 1
    static let maxValue = 6

    /// 升档门槛与降档门槛(技术方案 §4.6.1 那张表)。
    static let raiseAt = 0.8
    static let lowerBelow = 0.4

    /// 升档要**连续这么多天**满足才生效;降档立即。
    ///
    /// 🔴 **非对称是刻意的**:少问一张只是慢一天,多问一张是实打实的打扰,
    /// 而打扰的代价由用户当场承担。两个方向的错误代价不对称,阻尼就不该对称。
    static let raiseStreakNeeded = 2

    /// 样本不足这么多张时**不动 B** —— 一张卡的 0/1 不该决定明天的预算。
    static let minSample = 3

    /// 连续这么多天零处理 ⇒ **暂停推送**(PRD §4.6.4)。
    static let pauseAfterIdleDays = 30

    /// 一次调整的输入。**全部由调用方从库里数出来**,这里不查库 ——
    /// 纯函数才能被「造边界打自己」。
    struct Input: Equatable {
        /// 最近 7 天推送出去的卡数(分母)。
        let pushed: Int
        /// 其中被用户做出任意出口动作的卡数(分子)。
        let handled: Int
        /// 已经连续多少天零处理。
        let idleDays: Int
    }

    /// 一次调整的结果。
    struct Outcome: Equatable {
        let value: Int
        let raisedStreak: Int
        /// 暂停了吗。**暂停不改 `value`** —— 恢复时要用暂停前的那个数。
        let paused: Bool
        /// 为什么是这个结果。**没有「静默不动」这一档**:不动也要说出来是为什么。
        let why: String
    }

    /// 每天一次(08:00 免打扰结束时)按 §4.6.1 调整。
    ///
    /// - Parameters:
    ///   - current: 当前的 B。
    ///   - streak: 已经连续多少天满足升档条件。
    static func adjust(current: Int, streak: Int, input: Input) -> Outcome {
        // 🔴 **连续 30 天零处理 ⇒ 暂停,而 B 冻住。**
        // 暂停期间照常算 rate 的话,恢复那天 B 已经掉到底了 —— 而用户什么都没做错。
        if input.idleDays >= pauseAfterIdleDays {
            return Outcome(value: current, raisedStreak: 0, paused: true,
                           why: "连续 \(input.idleDays) 天零处理 ⇒ 暂停推送;"
                              + "B 冻在 \(current),用户处理任意一张即恢复")
        }
        // 🔴 **分母为 0 不是 rate = 0。**
        // 把「没推」读成「没处理」的话,B 会一路掉到 \(minValue) 再也起不来,
        // 而现象只是「最近卡片好少」—— 没有任何东西会报错。
        guard input.pushed > 0 else {
            return Outcome(value: current, raisedStreak: streak, paused: false,
                           why: "最近 7 天一张都没推过 ⇒ 不动 B(分母为 0 不是处理率 0)")
        }
        guard input.pushed >= minSample else {
            return Outcome(value: current, raisedStreak: streak, paused: false,
                           why: "样本只有 \(input.pushed) 张(要 \(minSample))⇒ 不动 B")
        }

        let rate = Double(input.handled) / Double(input.pushed)
        if rate < lowerBelow {
            // 降档**立即生效**,并把升档的连续计数清零。
            let v = max(minValue, current - 1)
            return Outcome(value: v, raisedStreak: 0, paused: false,
                           why: "处理率 \(pct(rate)) < \(pct(lowerBelow)) ⇒ B \(current) → \(v)")
        }
        if rate >= raiseAt {
            let s = streak + 1
            guard s >= raiseStreakNeeded else {
                return Outcome(value: current, raisedStreak: s, paused: false,
                               why: "处理率 \(pct(rate)) 够升档,但只连续 \(s) 天"
                                  + "(要 \(raiseStreakNeeded))⇒ 先不动")
            }
            let v = min(maxValue, current + 1)
            return Outcome(value: v, raisedStreak: 0, paused: false,
                           why: "处理率 \(pct(rate)) ≥ \(pct(raiseAt)) 连续 \(s) 天 ⇒ B \(current) → \(v)")
        }
        // 中间档:不变。**连续计数清零** —— 「连续两天」要求的是连续,
        // 不清零的话隔三差五够一次也能攒够,那就不是连续了。
        return Outcome(value: current, raisedStreak: 0, paused: false,
                       why: "处理率 \(pct(rate)) 在 \(pct(lowerBelow))–\(pct(raiseAt)) 之间 ⇒ B 不变")
    }

    private static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    // MARK: - 落库

    /// 读当前的 B。**读不到就抛** —— 迁移 v33 会写初始行,读不到说明库不对,
    /// 而给个默认值等于替一个不存在的状态编一个数。
    static func load(_ db: Database) throws -> (value: Int, streak: Int, paused: Bool) {
        guard let r = try Row.fetchOne(db, sql: """
            SELECT value, raised_streak, paused_since FROM card_budget WHERE id = 1
            """) else {
            throw Failure.missingRow
        }
        return (r["value"], r["raised_streak"], (r["paused_since"] as String?) != nil)
    }

    static func save(_ o: Outcome, now: String, in db: Database) throws {
        try db.execute(sql: """
            UPDATE card_budget SET value = ?, raised_streak = ?,
                   paused_since = CASE WHEN ? THEN COALESCE(paused_since, ?) ELSE NULL END,
                   updated_at = ?
             WHERE id = 1
            """, arguments: [o.value, o.raisedStreak, o.paused, now, now])
    }

    enum Failure: Error, CustomStringConvertible {
        case missingRow
        var description: String {
            "`card_budget` 没有那一行 —— 迁移 v33 会写初始行,读不到说明库不对。"
            + "这里不给默认值:那等于替一个不存在的状态编一个数"
        }
    }
}

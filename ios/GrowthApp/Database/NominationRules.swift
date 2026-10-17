import Foundation
import GRDB

/// 提名判据与排序(M2-B1 里「判断该不该」的那一半,主模型不外包)。
///
/// ## 这个文件**不调模型、不花钱**
///
/// PRD §4.3.5 的两个提名条件都是**结构性**的 —— 表过态没有、有没有未兑现承诺、
/// 最近有没有新材料,库里现成的信号就能答。要模型的是另一半(把跨场次的材料
/// 归成「同一个内核问题」并起个标题),那一半跑批要花钱,归 `M2-B1` 的付费步骤。
///
/// 把判据先独立出来的好处很实在:**它可以被离线测**。
/// 混在一次 LLM 调用里的话,「这条该不该提名」与「模型这次答得好不好」
/// 就再也分不开了 —— 而 M2-L4 的提名卷要判的恰恰是前者。
enum NominationRules {

    /// 「本人」。与 `MatterSituation.mePersonID` 同一个值 ——
    /// ⚠️ 两处各写一份是「一件事两个出处」。这里显式指回去,改的时候一起改。
    static let mePersonID = MatterSituation.mePersonID

    /// PRD §4.3.5 条件二里的「近 14 天(初)」。
    static let freshMaterialDays = 14

    /// 一条候选的信号。**全部是可数的事实**,没有一项来自模型。
    struct Signals: Equatable {
        /// 条件一「用户已卷入」的四种形态,本人各有多少条。
        let myStances: Int
        let myCommitments: Int
        /// 条件二「未决内核」:未答问题 / 未解分歧的条数。
        let openPoints: Int
        /// 跨几场。§4.3.5 排序依据里的「跨场次广度」。
        let sessions: Int
        /// 最近一条材料距今几天。§4.3.5 条件二要「近 14 天内有新材料」。
        let daysSinceLatest: Int

        /// 条件一:**用户已卷入**。
        /// 口径:本人在这批材料里表过态,或许下/收到过承诺。
        /// ⚠️ PRD 还列了「提过问题 / 主动问过它 / 传过相关材料」——
        /// 那三种今天**库里没有对应信号**(问答走 `ask_conversations` 但与材料无关联,
        /// 导入没有「相关」这个概念)。⇒ 只用得到的两种,**并且把漏掉的写在这儿**,
        /// 免得下一个人以为条件一已经全覆盖了。
        var userIsInvolved: Bool { myStances > 0 || myCommitments > 0 }

        /// 条件二:**存在未决内核,且近 14 天内有新材料**。
        var hasLiveOpenCore: Bool {
            openPoints > 0 && daysSinceLatest <= NominationRules.freshMaterialDays
        }

        /// 两个条件**同时**满足才提名(PRD 原文「同时满足」)。
        var qualifies: Bool { userIsInvolved && hasLiveOpenCore }
    }

    /// 排序分数。§4.3.5:**用户卷入程度 × 未决点数量 × 跨场次广度 × 近期活跃度**。
    ///
    /// 口径(PRD 只说「权重由实现决定,以离线判卷的接受率验收」,所以这里定死一版):
    /// · 四项**相乘**,照 PRD 字面 —— 相乘意味着**任何一项为 0 就出局**,
    ///   那正是「同时满足」的算术形态;相加会让一个四场都提到、而用户根本没卷入的
    ///   话题排到前面去。
    /// · 近期活跃度取**衰减**而不是布尔:14 天线内是连续的,3 天前和 13 天前不该同分。
    ///
    /// ⚠️ **这套权重是起点值,判准率归 `M2-L4` 的提名卷。**
    /// 这里不自设「抽 10 条人工看」的线 —— 那会与 `M2-J2` 的尺子打架。
    static func score(_ s: Signals) -> Double {
        guard s.qualifies else { return 0 }
        let involvement = Double(s.myStances + s.myCommitments)
        let recency = max(0, Double(freshMaterialDays - s.daysSinceLatest)) / Double(freshMaterialDays)
        return involvement * Double(s.openPoints) * Double(s.sessions) * recency
    }

    // MARK: - 推送节流(PRD §4.3.5 第三层)

    /// 「跟随纪要出现」的那条**才受节流**;进候选区的不限量(生成层不限量)。
    ///
    /// 动态档位,PRD 原文:初始 3 条/周;最近 4 周接受率 >70% 且活跃 <7 件 → 5 条/周;
    /// 接受率 <40% → 1 条/周。
    enum Throttle {
        static let initialPerWeek = 3
        static let boostedPerWeek = 5
        static let dampedPerWeek = 1
        static let boostAcceptance = 0.70
        static let dampAcceptance = 0.40
        static let boostActiveCeiling = 7

        /// → 这一周能推几条。
        ///
        /// ⚠️ **降档优先于升档**:两个条件理论上不会同时成立,但真同时成立时
        /// (接受率同时 >0.7 和 <0.4 是不可能的,而将来有人改了阈值就可能),
        /// 少推比多推安全 —— 推错的代价是打扰,漏推的代价只是晚一周。
        static func perWeek(recentAcceptance: Double?, activeCount: Int) -> Int {
            guard let a = recentAcceptance else { return initialPerWeek }  // 还没有 4 周数据
            if a < dampAcceptance { return dampedPerWeek }
            if a > boostAcceptance && activeCount < boostActiveCeiling { return boostedPerWeek }
            return initialPerWeek
        }
    }

    // MARK: - 冷启动质量线(PRD 说「线由主模型定」)

    /// 冷启动批量确认页要 5–8 条候选。**候选不足或质量分低于线 ⇒ 推迟**(宁缺毋滥,P5)。
    static let coldStartMinimumCandidates = 5

    /// 质量线。**口径:分数中位数不低于它**,不是「每条都要高于」——
    /// 后者会被一条垫底的候选整页否掉,而 PRD 要的是这一屏整体值不值得看。
    ///
    /// 取 1.0 的推理:分数是四项相乘,而**一条勉强够格的候选**
    /// (本人 1 条表态 × 1 个未决点 × 1 场 × 刚好过半的新鲜度)约 0.5。
    /// 取 1.0 意味着「这一屏的中位数要比勉强够格好一倍」。
    /// ⚠️ 这是推理不是实测 —— 与权重一起,由 `M2-L4` 的提名卷验收后回来定版。
    static let coldStartQualityFloor = 1.0

    /// 冷启动这一屏该不该出。→ nil = 出;非 nil = 推迟,且说清为什么。
    static func coldStartDeferral(scores: [Double]) -> String? {
        guard scores.count >= coldStartMinimumCandidates else {
            return "候选只有 \(scores.count) 条,不足 \(coldStartMinimumCandidates) 条"
        }
        let sorted = scores.sorted()
        let median = sorted[sorted.count / 2]
        guard median >= coldStartQualityFloor else {
            return String(format: "候选质量中位数 %.2f,低于线 %.2f", median, coldStartQualityFloor)
        }
        return nil
    }
}

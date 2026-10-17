import Foundation

/// 解读型发现的**类型闭集**(PRD §4.5.4 那张表)与产出策略(同节「产出规则」)。
/// 契约正文在 `docs/技术方案.md` §4.7。
///
/// 🔴 **「清单之外不做」是硬约束,不是建议。** 闭集是这一整块的安全边界 ——
/// 发现是系统**主动**对用户和他人下的观察,R-A 禁止系统单方面下定义、
/// R-E 禁止预测式断言。放开闭集,这两条红线就没有可执行的落点了。
///
/// ## 🔴 为什么「我」不在这个闭集里
///
/// PRD §4.5.4 的表里有第 7 行「我 | 被验证的判断 / 重复的判法」,
/// 而它写的是**统一收进「我自己 → 关于你的观察」(§4.4.7),遵守那里更严格的规则**。
///
/// 那边严在两处:验收是**零容忍**(抽 10 条,0 条含性格标签 / 能力评价 / 动机推测),
/// 呈现是**不推送 + 盲区类不在 20:00 后出**(R-D)。
/// ⇒ 在这里加一个 `case selfInsight`,它会**继承发现这边更松的一套规则**
/// (可进抽屉、可计入「有 N 条新发现」),而**零容忍验收根本不会去抽它** ——
/// 两边各自都自洽,没有任何东西会报错。这就是它必须留在别处的原因。
enum DiscoveryKind: String, CaseIterable {
    // 事
    case argumentShift = "争论点转移"
    case unverifiedPremise = "前提未验证"
    case stalledReason = "停滞原因"
    // 人
    case attitudeChange = "态度变化"
    case repeatedConcern = "反复关切"
    case suspendedCommitment = "承诺悬置"

    /// 挂在哪一类对象上(PRD §4.5.4 表的第一列)。
    enum Subject: String { case matter = "事", person = "人" }

    var subject: Subject {
        switch self {
        case .argumentShift, .unverifiedPremise, .stalledReason: return .matter
        case .attitudeChange, .repeatedConcern, .suspendedCommitment: return .person
        }
    }

    /// 依据形态。**界面须标注形态**(PRD §4.5.4 证据那行)——
    /// 两类的可验证性不一样,混着显示等于把「统计出来的」说成「他说过」。
    ///
    /// rawValue 直接进库(`discovery_kinds.evidence_form` 由 `DiscoveryKind.allCases` 播种),
    /// 所以这里改字面量 = 改 schema,**不会有第二份**。
    enum EvidenceForm: String {
        /// 有原话类:≥2 处可跳转原话。
        case quotes = "有原话"
        /// 「没出现」类:1 处锚点原话 + 1 个**可复算**的统计口径。
        ///
        /// 🔴 「可复算」不是形容词:口径要能被重新跑一遍并得到同一个数
        /// (「近 6 周内该承诺再未被任一说话人提及」)。
        /// 写不出可复算口径的「没出现」就是**无依据推论**(R-A 禁止项),不产出。
        case absence = "没出现"
    }

    /// PRD §4.5.4 只把**三型**列为「没出现」类:承诺悬置、前提未验证、停滞原因。
    var evidenceForm: EvidenceForm {
        switch self {
        case .unverifiedPremise, .stalledReason, .suspendedCommitment: return .absence
        case .argumentShift, .attitudeChange, .repeatedConcern: return .quotes
        }
    }
}

/// 发现的产出策略常数(PRD §4.5.4「产出规则」表)。
///
/// ⚠️ **这里是这几个数在代码里的唯一副本**,`M3-B1` 的频率闸与过期规则读它,不各写一个。
enum DiscoveryPolicy {
    /// 频率闸:每件事每周 ≤2 条。
    static let perMatterPerWeek = 2
    /// 每人每周 ≤1 条。
    static let perPersonPerWeek = 1
    /// 全局每天 ≤5 条。
    static let globalPerDay = 5

    /// 有原话类的最少原话数。
    static let minQuotes = 2
    /// 「没出现」类的锚点原话数。
    static let minAnchorQuotes = 1

    /// 7 天没有新材料触及 ⇒ 降为「旧」,移出抽屉默认视图,**不再计入「有 N 条新发现」**。
    static let staleAfterDays = 7
    /// 14 天未读 ⇒ 沉入历史。**不删除**,仍可搜索。
    static let sinkAfterDays = 14
}

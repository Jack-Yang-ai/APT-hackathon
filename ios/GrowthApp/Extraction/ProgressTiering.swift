import Foundation

/// 进展归属 V1 的**判决核心**(M2-B3)。
///
/// 这个文件里**只有判断,没有 IO** —— 不读库、不调模型、不写库。
/// 那三件在 `ProgressAttributionRunner` 里(照 `ExtractionRunner` 的形状,调用注入)。
/// 分开是因为**判决语义是这条任务的全部难点**,而它不该被 IO 缠着才能测。
///
/// ## 规格出处
///
/// PRD §4.3.6(四类信号 / 三档处置 / 分级上线)、技术方案 §4.5(比对契约)。
/// **达标线与容量上限一律引用,不在这里抄数。**
enum ProgressTiering {

    // MARK: - 三档

    /// PRD §4.3.6 的三档。
    enum Tier: String, Equatable {
        /// 静默入脉络,标「系统整理」,**不经用户的眼睛**。
        case high
        /// 出进展确认卡,用户判。
        case medium
        /// 不挂该事。含未兑现承诺/未答问题 ⇒ 进零散悬点区;否则丢弃。
        case low
    }

    /// 判成某一档的**理由**。
    ///
    /// 🔴 **不是给日志看的,是给判卷看的**:`M2-L4` 要判静默档的判准率,
    /// 而「为什么它进了静默档」是那次判卷唯一能复查的东西。
    /// 只给一个 `Tier` 的话,错判与对判在数据里长得一模一样。
    enum Reason: String, Equatable {
        case hitQuestionAndValidated       // 高:指认了悬点且三项校验全过
        case validatedButNoQuestion        // 中:校验过了,但没指到具体悬点
        case failedValidation              // 低:进了模型,校验没过
        case prefilteredOut                // 低:预筛就没进模型
    }

    struct Verdict: Equatable {
        let tier: Tier
        let reason: Reason
    }

    /// 判档。**输入是三个已经算好的事实,这里不重新计算任何一个。**
    ///
    /// - Parameter lexicalHit: 词面命中(本地算,¥0,PRD §4.3.6 ①)
    /// - Parameter validated: 三项校验全过(复用 `ExtractValidate`,技术方案 §4.5.3)
    /// - Parameter questionID: 模型指认的悬点 ID;`nil` = 认为相关但没指到具体悬点
    ///
    /// 🔴 **V1 的高档判据里没有「双判一致」,这是 2026-08-20 的裁决,不是遗漏。**
    /// 技术方案 §4.5.4 那张表的高档写着「且双判一致」,而 PRD 分级表说
    /// **V1 = 单次结构化判定**(双判是 V2)。两者矛盾,按规格自己的话裁:
    /// V2 的触发条件原文是「**V1 离线判卷静默档**判准率 <90%」——
    /// 这句话**预设了 V1 有静默档**,否则那个数量不出来、V2 永远触发不了。
    /// ⇒ §4.5.4 描述的是 V2 终态,V1 少的就是双判那一步。详见 `TASKS.md` 的 `M2-B3`。
    static func tier(lexicalHit: Bool, validated: Bool, questionID: Int64?) -> Verdict {
        guard lexicalHit else { return Verdict(tier: .low, reason: .prefilteredOut) }
        guard validated else { return Verdict(tier: .low, reason: .failedValidation) }
        return questionID == nil
            ? Verdict(tier: .medium, reason: .validatedButNoQuestion)
            : Verdict(tier: .high,   reason: .hitQuestionAndValidated)
    }

    // MARK: - 本地预筛(¥0,在进模型之前)

    /// 预筛阈值。**这两个数是待校准的默认值,不是实测值。**
    ///
    /// 🔴 规格(PRD §4.3.6「阈值校准」)写的是「M2 离线判卷上跑准召曲线定阈值」——
    /// 那批语料现在还不存在(`M2-J7`:等 App 真实数据)。
    /// ⇒ 先给一个**明说是默认值**的数,并且**在这里写清它没被量过** ——
    /// 不写的话,下一个人会把它当成实测结论去引用,而这个仓库刚因为
    /// 「拿过期/未验证的数当既定事实」吃过亏。
    /// ⚠️ 校准之后要回来改这两行,并把实测出处写在旁边。
    static let lexicalThreshold = 0.15
    static let peopleThreshold = 0.34

    /// 词面重合度:**本场说的话里有多大比例落在这件事的词面上**。
    ///
    /// 口径是**包含度** `|∩| / |本场词集|`,分母只取本场那一侧。
    ///
    /// 🔴 ~~「用 Jaccard,因为它不奖励长文本」~~ **2026-08-20 作废,那句是错的**
    /// (仓规 6:推翻结论要标作废并写明为什么)。
    /// Jaccard 是 `|∩| / |∪|`,而并集里含着**事的全部词面** ——
    /// ⇒ **一件谈得越久、脉络越丰富的事,分母越大、得分越低**。
    /// 实测被自己的测试打脸:10 件标题里就写着「压缩方式怎么定」的事,
    /// 配上长脉络之后**一件都没进模型**。
    ///
    /// **两种错法的代价完全不对称,这才是选包含度的理由**:
    /// · Jaccard 的错法是**漏召回** —— 该比的事根本没进模型,而输出是
    ///   「这一场没有进展」,**与一切正常一模一样,没有任何东西会红**;
    /// · 包含度的错法是**多召回** —— 词汇面宽的事被多比几次,花几分钱,
    ///   **而且下游还有三项校验与三档兜着**,错了看得见。
    /// ⇒ 预筛这一层宁可多召回。不可恢复且不可见的错,永远比可见的错贵。
    ///
    /// ⚠️ 多召回的上界由输入裁剪按住:进词面的只有标题 + 未关悬点 +
    /// **最近 10 条**脉络(技术方案 §4.5.1)。没有那个窗口,这个口径会退化成
    /// 「事越老越匹配一切」。**两者是一对,改窗口时要一起想。**
    static func lexicalOverlap(sessionTerms: Set<String>, matterTerms: Set<String>) -> Double {
        guard !sessionTerms.isEmpty, !matterTerms.isEmpty else { return 0 }
        return Double(sessionTerms.intersection(matterTerms).count) / Double(sessionTerms.count)
    }

    /// 人物重合度:本场说话人与该事参与人的重合比例。
    ///
    /// ⚠️ 分母取**事的参与人**,不取两者并集 —— 问的是「这件事的人今天在不在场」,
    /// 而不是「今天在场的人有多少比例跟这件事有关」。一场十个人的会里
    /// 出现了这件事的全部两个参与人,那是强信号,不该被另外八个人稀释。
    static func peopleOverlap(sessionPeople: Set<Int64>, matterPeople: Set<Int64>) -> Double {
        guard !matterPeople.isEmpty else { return 0 }
        return Double(sessionPeople.intersection(matterPeople).count) / Double(matterPeople.count)
    }

    /// 进不进模型。
    ///
    /// 🔴 **两个信号都低才排除(AND),不是任一低就排除(OR)。**
    /// PRD §4.3.6 原文:「词面重合度与人物重合度**都**低于阈值的事不进模型」。
    /// 写成 OR 的后果很具体:一件**换了措辞但还是这批人在谈**的事会被筛掉,
    /// 而那正是「进展」最典型的样子 —— 事情推进时用词本来就会变。
    static func shouldCompare(lexical: Double, people: Double) -> Bool {
        lexical >= lexicalThreshold || people >= peopleThreshold
    }
}

import Foundation

/// 卡片的**不出卡判定**(PRD §4.6.2.2「触发器是变化,不是存在」;契约 `docs/技术方案.md` §4.6.3)。
///
/// 这一层是控制卡片总量的**第一道闸**,比推送预算更靠前 ——
/// 预算管的是「递几张」,这里管的是「**该不该生成**」。
///
/// ## 为什么它是一个纯函数、不碰库
///
/// 判定要的东西只有两样:**这次的一条事实** 与 **同主题下已记录的立场**。
/// 让调用方(`M3-B2` 产出器)去查库、把结果喂进来,判定本身就能被 8 条测试逐行钉死;
/// 反过来把查询揉进来,测试就要先造一整套 schema,而 `M3-0c` 的表还没落。
///
/// ## 🔴 这一层**不持有**的三个数(别在这里加,会变成第二个出处 —— 铁律 4)
///
/// · **停滞阈值 / 反复关切阈值**:属发现层(`M3-0d`)。这里只回答「不出卡,交给发现层」,
///   到底攒够没攒够由那边定 —— 两处各写一个阈值,调了一处不会有任何东西报错;
/// · **排他性粗筛**:属原则层(`M3-B4`)。所以它是**入参**不是内部判断 ——
///   写成入参,漏传会编译不过;写成内部 `true`,漏了没人知道;
/// · **归属三档**(进展确认卡何时出):PRD §4.3.6 与 `docs/技术方案.md` §4.5.4 已定,不在这里重述。
enum CardTrigger {

    // MARK: - 闭集

    /// 卡型闭集,**序号就是 PRD §4.6.3 那张优先级表的「序」**(1 最高)。
    ///
    /// ⚠️ 这是 PRD 那张表在代码里的**唯一副本**,由
    /// `eval/checks/test_card_kinds.py` 与 PRD 对撞(名字 + 序号双向)。
    /// 少一个 / 序号错了都**不会有任何运行时症状** —— 队列照样出数,
    /// 只是排错了顺序、或某一型永远排不上;所以它必须有一道会红的闸。
    enum Kind: String, CaseIterable {
        case progressConfirm = "进展确认卡"
        case premiseOverturned = "前提推翻卡"
        case contradiction = "矛盾卡"
        case nomination = "提名卡"
        case stance = "立场卡"
        case absence = "缺席观察卡"
        case principleEmerging = "原则浮现卡"
        case wrapUp = "收尾卡"
        case closing = "结案卡"
        case identity = "说话人卡 / 称呼卡"

        /// PRD §4.6.3 的「序」。**1 最高**。
        var priority: Int {
            switch self {
            case .progressConfirm: return 1
            case .premiseOverturned: return 2
            case .contradiction: return 3
            case .nomination: return 4
            case .stance: return 5
            case .absence: return 6
            case .principleEmerging: return 7
            case .wrapUp: return 8
            case .closing: return 9
            case .identity: return 10
            }
        }

        /// 队列排序用的**重要度**(§4.6.2「重要度 × 紧急度」)。数越大越重要。
        var importance: Int { Kind.allCases.count + 1 - priority }
    }

    /// 不出卡、也不追加证据的两个理由。
    ///
    /// ⚠️ **两个都必须被记账**(§3.2 失败必须可见):`normalizationFailed` 尤其 ——
    /// 「归一老是失败所以一张卡都没出」与「今天真的没什么可问」长得一模一样。
    enum DropReason: String {
        case alreadyJudged = "用户已对同类事实做过判断"
        case normalizationFailed = "归一失败:主题或方向拿不准"
        /// 🔴 **排他性粗筛还没接上(`M3-B4`)** —— 与「粗筛没过」是两回事。
        ///
        /// 「没过」是一个**结论**(这条判断谁都会说),「还没接上」是一个**缺口**
        /// (没有人去判过)。折成同一个值的后果是:账上看不出该去接什么,
        /// 而缺口会一直以「结论」的样子存在下去。
        ///
        /// ⚠️ 2026-08-25 写产出器时**先折过一次**:那边拿 `screen ?? false` 喂进来,
        /// 于是判定给的是 `.appendEvidence` —— 缺口连一笔账都没留下,是测试逼出来的。
        case exclusivityUnknown = "排他性粗筛还没接上(M3-B4)"
    }

    /// 立场的**判断方向**。归一按 (主题 × 方向),**不按措辞** —— 所以方向必须是闭集,
    /// 不能是自由文本:自由文本下「反对」与「不同意」会被当成两条立场,矛盾卡永远出不来。
    enum Direction: String, CaseIterable {
        case support = "支持"
        case oppose = "反对"
        case conditional = "有保留"
    }

    // MARK: - 判定结果

    enum Decision: Equatable {
        /// 不出卡:静默给已有立场追加一条证据,并更新「最近一次」时间(§4.6.2.2 第 1 行)。
        case appendEvidence
        /// 不出卡,也不追加。
        case drop(DropReason)
        /// 不出卡,交给发现层;**不占卡片预算**(§4.6.2.2 第 5、6 行)。
        ///
        /// ⚠️ 用的是发现层的闭集 `DiscoveryKind`(`M3-0d`),**这边不另立一份枚举** ——
        /// 两处各列一份,发现层增删一型不会有任何东西报错(铁律 4)。
        case discovery(DiscoveryKind)
        /// 出卡。
        case card(Kind)
    }

    // MARK: - 入参

    /// 这次新冒出来的一条立场(抽取产出,还没决定要不要做成卡片)。
    struct StanceFact: Equatable {
        /// 归一用的主题键。**拿不准就给 `nil`,不许编一个** —— `nil` ⇒ 归一失败 ⇒ 倾向不出卡。
        let topicKey: String?
        /// 判断方向。抽取分不出来就给 `nil`,同样走归一失败。
        let direction: Direction?
        /// 这次表达挂在哪件事上(原则浮现要数「跨了几件事」)。
        let matterID: String
        /// 前提。**锚不到原话就是 `nil`**(PRD §4.6.3:不得由模型推断补写)。
        let premiseKey: String?
    }

    /// 已记录的一条立场(调用方按**同一主题**查出来喂进来,可能有多条:
    /// 「场景不同」的矛盾处置会让同一主题下并存两个方向)。
    struct StanceRecord: Equatable {
        let direction: Direction
        let premiseKey: String?
        /// 这条立场已经在哪几件事上出现过。
        let matterIDs: Set<String>
        /// 用户已对它做过判断(接受 / 否定 / 搁置 / 这问不对 都算)。
        let userJudged: Bool
        /// 那个判断本身被推翻了 —— 推翻之后同类事实可以再问(§4.6.2.2 第 7 行的例外)。
        let judgmentOverturned: Bool
    }

    /// 「重复但没有变化」的两种非立场情形(§4.6.2.2 第 5、6 行)。
    ///
    /// 用枚举而不是布尔参数:**case 的名字本身就是前提** ——
    /// 调用方只有在「确实无进展 / 确实是重复提」时才构造得出对应的 case。
    enum RepetitionWithoutChange {
        /// 同一悬点被反复讨论但**无进展**。
        case openQuestionRediscussedWithoutProgress
        /// 同一个人重复提**同一件事**。
        case personRaisedSameMatterAgain
    }

    // MARK: - 常数

    /// 原则浮现卡的门槛:同一判断方式跨 **≥2** 件不同的事(PRD §4.6.3 第 7 类)。
    static let principleMatterSpread = 2

    /// 🔴 被 `M3-0f`(前提召回率实测)挡着的卡型:**判定照出,出卡侧必须挡住**。
    ///
    /// PRD §4.6.3 明写「前提未验证类发现与前提推翻卡在拿到前提召回率实测数字前不排期」。
    /// 判定与出卡分开的理由:判定逻辑现在就要钉死(否则 `M3-0f` 出数那天要重新推一遍),
    /// 而出卡会真的打扰用户 —— 拿一个**召回率未知**的前提字段去问「你的前提变了吗」,
    /// 问错的代价由用户承担。
    static let blockedPendingPremiseRecall: Set<Kind> = [.premiseOverturned]

    // MARK: - 判定

    /// 立场类事实的判定(§4.6.2.2 第 1、2、3、4、7 行 + 表下的归一失败)。
    ///
    /// - Parameters:
    ///   - stance: 这次新冒出来的一条立场。
    ///   - sameTopic: **同一主题**下已记录的立场(方向可能不同)。
    ///   - exclusivityScreenPassed: 原则层的**排他性粗筛**结果。这一层算不出它
    ///     (PRD §4.4.6 把「只属于他」标的是「prompt 约束 + 抽样盲测」,不是机械可判),
    ///     所以它是入参。**三态**:`true` 过 / `false` 没过 / `nil` **还没接上** ——
    ///     后两者不能合并,见 `DropReason.exclusivityUnknown`。
    static func decide(stance: StanceFact,
                       sameTopic records: [StanceRecord],
                       exclusivityScreenPassed: Bool?) -> Decision {
        // 表下:归一失败(主题或方向拿不准)**倾向不出卡** ——
        // 漏一次的代价远小于反复问同一个问题。
        guard let topic = stance.topicKey, !topic.isEmpty,
              let direction = stance.direction else {
            return .drop(.normalizationFailed)
        }

        guard let same = records.first(where: { $0.direction == direction }) else {
            // 同主题下没有同方向的记录:
            // · 一条都没有 ⇒ 第一次表达这个判断 ⇒ 立场卡(§4.6.3 第 5 类)
            //   ⚠️ 「本人身份已确认」是立场卡的前置(§4.6.3),由调用方在查库时把住,不在这里。
            // · 有别的方向 ⇒ 第 3 行:立场变了 ⇒ 矛盾卡
            return records.isEmpty ? .card(.stance) : .card(.contradiction)
        }

        // 第 4 行:立场的**前提变了** ⇒ 前提推翻卡。
        // 🔴 **两侧都锚到了原话才算「变了」**:任一侧为 nil 是「没说前提」,不是「前提变了」。
        // 把 nil 当成变化,等于让模型的沉默去触发一张卡 —— 正是 §4.6.3 明令禁止的推断补写。
        //
        // 🔴 **次序:变化(第 3、4 行)压过「已判断过」(第 7 行)。**
        // 理由是这一节的标题本身 —— 第 7 行挡的是「同类事实**再现**」,而前提变了是**变化**;
        // 第 3 行(立场变了)已经排在第 7 行之前(方向不同那一支更早返回),
        // 两条变化分支不能一条压得住、一条压不住。
        //
        // ⚠️ **放行这一型时必须同时定下「前提」的归一口径**:`premiseKey` 现在是自由文本,
        // 而 §4.6.2.2 的归一口径只写了立场(主题 × 方向),没写前提。
        // 它又排在 `alreadyJudged` 之前 ⇒ `M3-0f` 出数那天若只解开闸不定口径,
        // 表现就是**已经确认过的立场被反复问**,而那正是这一整节要禁的事。
        if let old = same.premiseKey, let now = stance.premiseKey, old != now {
            return .card(.premiseOverturned)
        }

        // 第 7 行:用户已判断过,同类事实再现不再出同类卡 —— 除非那个判断本身被推翻。
        if same.userJudged && !same.judgmentOverturned {
            return .drop(.alreadyJudged)
        }

        // 第 1、2 行:重复表达同一立场,不出立场卡。
        // 若这次跨到了一件**新的**事,并且因此**刚好**满足「跨 ≥2 件事」,触发原则浮现卡。
        // 「刚好」很重要:第 3、第 4 件事再来时不该反复出同一张卡 —— 那是「存在」不是「变化」。
        let isNewMatter = !same.matterIDs.contains(stance.matterID)
        let spread = same.matterIDs.union([stance.matterID]).count
        let justCrossed = isNewMatter
            && same.matterIDs.count < principleMatterSpread
            && spread >= principleMatterSpread
        if justCrossed {
            switch exclusivityScreenPassed {
            case .some(true):  return .card(.principleEmerging)
            case .some(false): return .appendEvidence      // 粗筛判过了:这条谁都会说
            case .none:        return .drop(.exclusivityUnknown)   // 还没人判过
            }
        }
        return .appendEvidence
    }

    /// 「重复但没有变化」的两种非立场情形(§4.6.2.2 第 5、6 行):都不出卡,交给发现层。
    ///
    /// 发现层是否**真的**产出一条发现,取决于它自己的阈值(`M3-0d`)—— 这里不判,也不该判。
    static func decide(_ repetition: RepetitionWithoutChange) -> Decision {
        switch repetition {
        case .openQuestionRediscussedWithoutProgress: return .discovery(.stalledReason)
        case .personRaisedSameMatterAgain: return .discovery(.repeatedConcern)
        }
    }
}

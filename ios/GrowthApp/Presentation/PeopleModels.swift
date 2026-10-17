import Foundation

// 当前声音、设置与归属投影使用的兼容模型；无独立人页导航。

// MARK: - 人列表

/// 人列表整页(`people-v1-1.html` / `people-empty-v1.html`)。
struct PeopleList: Equatable {
    let me: SelfBlock
    /// 还叫不出名字的说话人有几个。**与确认页的候选数同一个算法**——
    /// 两处给不同的数是这一屏最容易犯的错(见 `PeopleProjection.pendingSpeakerKeys`)。
    let pendingSpeakers: Int
    let others: [PersonRow]
}

/// 「我自己」那一块。
///
/// ⚠️ **图纸上那三个计数(1 条已确认原则 / 2 个持续立场 / 1 个待确认观察)不在这里**,
/// 它们要 `self_principles` / `self_stances` / `person_observations` 三张表,一张都没有。
///
/// 显示「0 条原则」是**准确但会骗人**的:它读起来像「系统已经在算了,只是还没算出来」,
/// 而真相是这一层根本没开工。PRD §4.4.12 对这种情况有明确写法——
/// 「还没有攒够,继续用几周」+ 说明攒够的条件。界面照那个来。
struct SelfBlock: Equatable {
    /// 用户**确认过**某些行是自己。⚠️ 不等于「库里有 -1 这个人」——
    /// 后者由迁移写入,恒为真;前者才是 M1-6 的语义。
    let isConfirmed: Bool
    let lineCount: Int
    let sessionCount: Int
}

/// 人列表里的一行。
struct PersonRow: Identifiable, Equatable {
    let id: Int64
    /// 怎么称呼他。**一律来自 `SpeakerNaming.labels()`**,不在别处另编一套。
    /// 2026-08-14 实测过两处各编各的后果:用户以为在认先开口的那个,写进归属层的是另一个。
    let label: String
    /// 有没有真名字。`false` 时 `label` 是临时编号(「说话人 3」),
    /// 界面要给一条通往命名屏的路——这是施工规格 §6-⑧ 那个缺口的唯一出口。
    let hasName: Bool
    /// 最近一次出现的日子(`sessions.day`)。没有往来记录时为 nil。
    let lastMetDay: String?
    /// 距今几天。`0` = 今天。`lastMetDay` 为 nil 或日期解析不了时为 nil(**不猜**)。
    let daysAgo: Int?
    let sessionCount: Int
    let lineCount: Int

    /// 头像里那个字。没名字就是「?」——拿「说话人 3」的首字「说」当头像,
    /// 满屏都是「说」,反而看不出谁是谁。
    var initial: String { hasName ? String(label.prefix(1)) : "?" }
}

// MARK: - 某个人的档案

/// 档案整页(`person-detail-v1.html` 里**已有数据填得起**的那部分)。
struct PersonProfile: Equatable {
    let person: PersonRow
    /// 见面前简报(PRD §4.4.5)。三行里只做得出两行,第三行「他还等着」见文件头。
    let brief: PersonBrief
    /// 反复关心的。**PRD 要求 ≥2 次才显示**,所以这里可能是空的。
    let recurringTopics: [TopicMention]
    /// 最近场次,时间倒序。
    let recentSessions: [PersonSession]
}

/// 三行简报里做得出来的两行。两行都可能缺——这个人可能一句话都还没说过。
struct PersonBrief: Equatable {
    let lastMet: LastMeeting?
    let lastTopic: LastTopic?
}

/// 上次见面。**没有场次名**——缺口 A,`sessions` 表没有 `title` 列。
///
/// 图纸上这里写的是「今天 · 产品碰头会」。后半截编不出来,所以界面只显示
/// 时间那一半,**不拿纪要的一句话去顶场次名**:那会让人以为模型给这一场起过名字
/// (`HomeProjection.swift` 里 `storedSummaries` 的 `title` 恒为空,是同一个理由)。
struct LastMeeting: Equatable {
    let sessionID: Int64
    /// `2026-08-13`
    let day: String
    /// `10:20`。取自 `sessions.started_at` 的字面钟点。
    let clock: String
    /// 距今几天,`0` = 今天。解析不了为 nil。
    let daysAgo: Int?
}

/// 上次聊到。PRD §4.4.5 定死了它的出处:**那场纪要的一句话**(已经产好的,零模型调用)。
struct LastTopic: Equatable {
    let oneLiner: String
    /// 该人在那一场里最长的一句原话,给「必带原话跳转」用(PRD §4.4.3 字段规则)。
    /// 那场里他一句没说时为 nil。
    let quote: String?
    let quoteLineID: Int64?
}

/// 反复关心的一个主题。
struct TopicMention: Equatable, Identifiable {
    let key: String
    let count: Int
    var id: String { key }
}

/// 档案里的一场。
struct PersonSession: Equatable, Identifiable {
    let id: Int64
    let day: String
    let clock: String
    let durationMinutes: Int
    /// 这一场里他有几条记录。
    let relatedLineCount: Int
    /// 那一场纪要的一句话。**这是摘要,不是标题**——界面上要摆在时间下面当次级信息,
    /// 不能当成场次名摆在最上面(缺口 A,见 `LastMeeting`)。
    let oneLiner: String?
}

// MARK: - 待确认的说话人

/// 一个还叫不出名字的说话人(归属键 + 给人认的材料)。
///
/// ⚠️ **它不是 `PersonRow`,不能摆进人列表。** 键可能是 `c:<场次>:<簇>`——
/// 簇标签**只在一场之内有效**(`SpeakerNaming.keyExpr` 的注释),
/// 把它当成跨场次的人摆出去,等于宣称两场的 `S0` 是同一个人。
struct PendingSpeaker: Equatable, Identifiable {
    /// 归属键。`p:<id>` 或 `c:<场次>:<簇>`。
    let key: String
    let label: String
    /// 最长的一句原话。短句认不出人,而这一屏全部的作用就是让人认出来。
    let sample: String
    /// 🔴 **`sample` 那句话自己的 `line_id`,用来放它的音频。**
    ///
    /// 必须是**同一行**,不能另挑一行来放 —— 认人时用户是照着屏幕上的字
    /// 去听声音的,字和声音对不上,他会照着别人的声音确认「这是小李」,
    /// 而归属一错,表态与承诺全跟着错。
    /// 可空:v15 之前落的行没有 `block_seq`,定位不到音频(见 `LineAudio`)。
    let sampleLineID: Int64?
    let lineIDs: [Int64]
    let sessionCount: Int
    /// 这个说话人已经有名字了吗。
    ///
    /// 🔴 **「没被用户确认过」与「还没有名字」是两回事,别拿一个当另一个用。**
    /// 2026-08-17 实拍抓到:「小李」同时出现在待确认区(被写成「还没有名字」)
    /// 和「其他人」列表(正显示着名字)—— 同一屏两处自相矛盾。
    /// 他确实没被用户确认过(归属来源是「系统整理」),但他早就有名字了。
    ///
    /// 两个消费方问的问题不同,所以过滤也不同:
    /// · 确认页问「哪个是你」⇒ 要**全部**未经确认的键(名字与这个问题无关)
    /// · 人列表的命名入口问「谁还叫不出名字」⇒ 只要 `hasName == false` 的
    let hasName: Bool
    var id: String { key }

    /// 这个键背后已经是一个 `persons` 行了吗?是的话命名屏走「改名」,
    /// 不是的话走「建人并归属」。两条路语义不同,不能混。
    var personID: Int64? { SpeakerNaming.personID(of: key) }
}

// Shared presentation text; no old navigation dependency.
enum PeopleText {

    /// 上次见面怎么说。
    ///
    /// ⚠️ **算不出天数时说「已有往来记录」,不说「很久以前」。** PRD §4.4.8 第一档
    /// 要的是如实——「不知道多久」和「很久」是两件事,后者是一次没有依据的推断。
    static func lastSeen(_ r: PersonRow) -> String {
        guard r.lastMetDay != nil else {
            // 这个人在 `persons` 里,但归属层还没有他的行。真实且正常:
            // 声纹种子导进来了还没匹配上,或者刚在命名屏建出来。
            return "还没有往来记录"
        }
        guard let d = r.daysAgo else { return "已有往来记录" }
        return relative(d) + "见过 · \(r.sessionCount) 场 \(r.lineCount) 句"
    }

    /// 距今几天 → 人话。
    static func relative(_ daysAgo: Int) -> String {
        switch daysAgo {
        case ..<0:   return "晚些时候"    // 库里的日子比今天晚 —— 不编,如实说
        case 0:      return "今天"
        case 1:      return "昨天"
        case 2...6:  return "\(daysAgo) 天前"
        case 7...29: return "\(daysAgo / 7) 周前"
        default:     return "\(daysAgo / 30) 个月前"
        }
    }
}

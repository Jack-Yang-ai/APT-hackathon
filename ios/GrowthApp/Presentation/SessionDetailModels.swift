import Foundation

// 当前场次详情的本地投影模型；入口见 docs/CURRENT.md。

/// 五块里的一条。四张表(`summary_key_points` / `_commitments` / `_stances` / `_pendings`)
/// 形状一致,所以共用一个模型 —— 加一块只加一个 `Block`,渲染逻辑不动。
struct SummaryItem: Equatable, Identifiable {
    let id: Int64
    /// 主文:要点的 `text` / 承诺的 `what` / 表态的 `stance` / 悬点的 `issue`。
    /// **这是模型可改写的自由文本**(判 4),不是逐字引文。
    let lead: String
    /// 副文:承诺的「对谁」· 表态的前提 · 悬点的「涉及谁」。没有就是 nil。
    let detail: String?
    /// 逐字引文。三项校验只打它 —— 跳原话靠 `lineID`,显示引文靠这个。
    let quote: String
    let lineID: Int64
    /// 场次内绝对毫秒,卡面显示时间点。
    let atMillis: Int
    /// 说话人标签。表态要按人分组;承诺的「谁」也是它。nil = 归属还没定。
    let speaker: String?
    /// 挂起原因。**目前只有一种:`归属未定`**(`ExtractionStore.recomputePending`
    /// 按 `line_speakers.person_id` 是否为空写的)。
    ///
    /// ⚠️ 它**不是** PRD §4.2.3 说的「出处待核」。那个是**逐字校验失败**,
    /// 是另一回事,而且现在的管线还不产出。两者混成一个标注,用户会以为
    /// 「不知道谁说的」等于「这句话可能是编的」—— 差得远。
    let pendingReason: String?

    /// 引文能不能跳原话。归属未定不影响跳转:行还在,只是不知道谁说的。
    /// 将来真出现「出处待核」时,判据加在这里,而不是散在界面里。
    var canJumpToQuote: Bool { pendingReason != "出处待核" }
}

/// 纪要的五块。**无内容的块隐藏,不显示「暂无」**(G6 空态两分法:
/// 内容块无内容就隐藏,结构性栏目才保留并说明原因)。
struct SessionDetail: Equatable {
    let sessionID: Int64
    let startTime: String
    let durationMinutes: Int
    /// 参与人。设计里是底部那块「参与人 · 2」。
    ///
    /// ⚠️ 这是**结构性栏目**,不是内容块 —— G6 空态两分法:结构性栏目无内容时
    /// **保留并说明原因**(「还没认出谁在说话」),不像五块那样直接隐藏。
    /// 一场对话没有参与人是不可能的,栏目消失只会让人以为这一屏坏了。
    let speakers: [String]
    var speakerCount: Int { speakers.count }
    /// ≤40 字,PRD 写明「必有」。**但没出纪要的场次整个 detail 就是 nil**,
    /// 所以这里能为空的唯一情况是纪要写坏了 —— 那时该看得出来,不该假装有。
    let oneLiner: String?
    let keyPoints: [SummaryItem]
    let commitments: [SummaryItem]
    let stances: [SummaryItem]
    let pendings: [SummaryItem]
    /// 因**抽取缺字段**被挡下的承诺条数(缺「对谁」或「什么」)。
    ///
    /// ⚠️ 不含「还不知道谁说的」那些 —— 那些会列出来把「谁」留空,因为它们会自己好。
    ///
    /// ⚠️ **必须显示出来。** PRD 说三要素缺一不列,但「不列」不等于「不说」——
    /// 悄悄丢掉条目正是仓规 §3.2 点名的错法(校验失败要计数并告警,不能静默丢弃)。
    /// 而且漏掉承诺是纪要最贵的失误,用户至少要知道有几条没能列出来。
    let commitmentsWithheld: Int
    /// 转写行数,给「原始记录」那一条用。
    let lineCount: Int

    /// 这一场有几句**没有说话人**。
    ///
    /// 🔴 用户 2026-08-19 拍板「要看见」。没有它的话,一场走了 SSE 兜底
    /// (`M1-34`:上游文件端点卡死时的降级,**只出文字没有分人**)的稿子,
    /// 与「这一场只有一个人说话」在界面上一模一样 ——
    /// 而下游会静默地把它从提名与「人」相关的发现里排除掉。
    let linesWithoutSpeaker: Int
    /// 认人任务的状态(nil = 这一场没排过认人,比如老场次)。
    let voiceprintState: String?

    /// 这一场里有没有已经确认为**本人**的说话人。
    ///
    /// 🔴 ~~「M1 的库里还没有 `persons` 表,三种本人来源一条都不成立,
    /// 所以标题恒为『表态(按说话人)』—— 这是如实,不是没做。」~~
    /// **2026-08-17 作废(仓规 6:前提没了,结论要跟着改)。**
    /// `persons` 表在迁移 v14 就建好了,而「这是我」那条路(`SpeakerConfirmationView`
    /// → `assignSpeaker(person: mePersonID)`)也早就通了 ——
    /// 那句话从 v14 落地那天起就是假的,后果是用户确认完「是我」,
    /// 标题**还是**「表态(按说话人)」,他会以为确认没生效。
    let hasConfirmedMe: Bool

    // MARK: M5-1 新加(带默认值,老的构造点不用改)

    /// 第一个事件的标题,当这一场的标题用。没有事件(v1 单阶段 / 老产物)⇒ nil,界面退回一句话。
    var title: String? = nil
    /// 详情页的分段。空 = 这一场没有事件(老产物),界面如实说,不编。
    var events: [DetailEvent] = []
    /// 我说的承诺 = 待办的来源(`M5-1` spec §四)。**不做三要素过滤** ——
    /// 「对谁」缺了不影响它是我要做的事;三要素是给纪要展示的规矩,不是给待办的。
    var myCommitments: [SummaryItem] = []
    var source: String = SessionSource.recording

    /// 表态那一块的标题。PRD §4.2.3:**只有当某说话人已确认为本人后,
    /// 界面才可出现「我的表态」**;在此之前一律「表态(按说话人)」。
    var stanceTitle: String { hasConfirmedMe ? "我的表态" : "表态(按说话人)" }
}

/// 原话上下文(PRD §4.2.5):前后各 3 句 + 本条高亮。
struct QuoteContext: Equatable {
    struct Line: Equatable, Identifiable {
        let id: Int64
        let atMillis: Int
        let text: String
        let speaker: String?
        let isGap: Bool
        /// 已经移出记忆了。**界面据此不再给「移出记忆」的入口** ——
        /// 对一条墓碑再做一次是 no-op,而一个按了没反应的按钮
        /// 会让用户以为这次没生效、于是反复按。
        let isRedacted: Bool
        let isTarget: Bool

        /// 同一行,标成高亮(原话页从话题跳进来时用)。
        func focused() -> Line {
            Line(id: id, atMillis: atMillis, text: text, speaker: speaker,
                 isGap: isGap, isRedacted: isRedacted, isTarget: true)
        }
    }
    let lines: [Line]
    static let radius = 3
}

/// 详情页的一段(`M5-1` spec §三):两阶段抽取的一个事件。
struct DetailEvent: Equatable, Identifiable {
    let id: Int64
    let title: String
    let summary: String
    /// 「14:00–14:24」。老产物没有行范围 ⇒ nil,**不编**。
    let clockRange: String?
    /// 这一段里说过话的人,称呼与原话页同一套(`SpeakerNaming`)。
    let speakers: [String]
    /// 话题:点了跳到这一段里它第一次出现的那一行。
    let topics: [Topic]

    struct Topic: Equatable, Hashable {
        let key: String
        let firstLineID: Int64
    }
}

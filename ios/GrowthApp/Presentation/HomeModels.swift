import Foundation

// 首页展示模型(PRD §4.2.2 的四块:提示条 / 场次卡 / 零碎折叠行 / 按天折叠)。
//
// 三件事先说清楚,免得后来人照旧仓的样子改回去:
//
// 1. **这不是报文,是本地投影。** 旧仓同位置的 SurfaceModels.swift 是服务端下发的
//    JSON 契约,所以除极少数外全部 optional——那是为了容忍服务端漏字段。这里内容就在
//    本机库里,漏字段是 BUG,该崩就崩。下面每一个 optional 都对应一种**真实存在的缺席**
//    (比如「还在整理,本来就没有纪要」),不是「可能没取到」。
//
// 2. **这里一个「谁说的」字段都没有。** 归属一律现查归属层那张表。旧仓正是把它写进
//    展示层,才有了第二个归属真相源;抽取契约(技术方案 §4.2)也因此删掉了那个字段,
//    并写明簇标签「只用于校验、永不落库」——它不该出现在这一层。
//
//    (本目录有一条结构断言,连注释一起查那几个英文标识符,所以上面只用中文称呼它们。
//     断言写在 TASKS.md M0-1d 的验收里。)
//
// 3. **旧组件里有、这里刻意不建的两个概念**:
//    · Era(纪元)—— PRD 全文零命中,这个概念已经没有了。
//    · Reviews(周回顾)—— 属 M4,不是 M1。
//    旧仓的 Emergence(浮现)在 PRD 里已改名「发现」,按新名建。

// MARK: - 场次卡

/// 处理状态。闭集,逐条对应 PRD §4.1.7 的十个展示态。
///
/// 「已出纪要」的两个态直接把纪要带在身上,别的态压根没有这个字段——
/// 让「处理中却有纪要」「已完成却没纪要」这两种非法组合**写不出来**,
/// 而不是写得出来再靠调用方自觉检查。
enum SessionDisplayState: Equatable {
    case recording(elapsedMinutes: Int)     // 记录中 · 3 小时 20 分
    case waitingForNetwork                  // 等网络好了就传
    case uploading(percent: Int)            // 上传中 45%
    case queued(ahead: Int)                 // 排队中,前面还有 1 段
    case processing                         // 整理中
    case attributionPending(SessionSummary) // 已出纪要,说话人还在整理
    case done(SessionSummary)               // 显示纪要
    case partialFailure(missing: String)    // 要点没提取出来
    /// 处理失败。**`willRetry` 是这一档的承重字段**,见下面。
    case failed(attempt: Int, willRetry: Bool)
    case degraded                           // 只保留了文字记录

    // 🔴 **为什么是加一个字段,不是加第十一个 case。**
    //
    // `task_state_display` 把 `retrying` 与 `dead` **都映射成 `failed`** ——
    // 而这两者对用户的差别是全部:一个会自己好,一个再也不会。
    // 2026-08-17 真机实拍到的形态是一张 `dead` 的卡说自己「重试中(第 0 次)」,
    // 用户于是去等一件永远不会发生的事(和 §4.1.7「说话人整理中 vs 降级
    // 必须视觉分开」是同一件事)。
    //
    // 但**十态是 PRD §4.1.7 定死的**,不是这一层能加减的。所以差别落在
    // 关联值上:「还会不会再试」是这一态的一个属性,不是另一个态。

    /// PRD §4.1.7「并发时显示哪个」,数越小越优先:
    /// 失败 > 等待网络 > 上传中 > 排队中 > 处理中 > 说话人整理中 > 部分失败 > 降级 > 完成
    ///
    /// ⚠️ PRD 那行只列了 9 个态,没把「录音中」放进去。这里给它排在最前——
    /// 还在录的场次不可能同时处于下游任何一个态,排在最前不会改变其余 9 个的相对次序。
    var concurrencyPriority: Int {
        switch self {
        case .recording:           return 0
        case .failed:              return 1
        case .waitingForNetwork:   return 2
        case .uploading:           return 3
        case .queued:              return 4
        case .processing:          return 5
        case .attributionPending:  return 6
        case .partialFailure:      return 7
        case .degraded:            return 8
        case .done:                return 9
        }
    }

    /// 已出纪要的态把纪要交出来,其余态没有。
    ///
    /// ⚠️ **和 `presentation` 一样刻意不写 `default`。** 它是承重的:
    /// 首页的折叠判据与卡面渲染都读它。将来加一个带纪要的态而这里漏了,
    /// 编译器不吭声,卡面不显示纪要、还被当成「还在处理的不折」。
    var summary: SessionSummary? {
        switch self {
        case .done(let s), .attributionPending(let s): return s
        case .recording, .waitingForNetwork, .uploading, .queued,
             .processing, .partialFailure, .failed, .degraded: return nil
        }
    }
}

// MARK: - 界面上的六种

/// 界面真正呈现的态。**上面那十个不是要删,是降级成内部状态机**
/// (PRD §4.1.7 原文:「下表仍然是工程的真相,重试逻辑与并发优先级都依赖它,
/// 只是不再逐个映射到界面文案」)。所以这里是一层**投影**,不是替换。
///
/// 为什么合并:「等待网络 / 上传中 / 排队中 / 处理中」四个态**用户可做的动作完全一样**
/// (等,或取消)。把它们分别摆给用户看,是把工程内部搬到脸上。
///
/// 为什么两个「半成品」态要单列、而且**必须互相分开**:
/// 「说话人整理中」会自己好(Mac 上线后自动补),「只保留了文字记录」不会(灰色终态)。
/// 混成一个,用户就不知道该等还是该动手。
enum SessionPresentation: Equatable {
    case recording(elapsedMinutes: Int)   // 录着
    case organizing                       // 整理中
    case ready(SessionSummary)            // 好了
    case broken(String)                   // 出问题了(带上具体那句)
    case speakersPending(SessionSummary)  // 说话人整理中 —— 会自己好,带动画
    case transcriptOnly                   // 只保留了文字记录 —— 灰色终态

    /// 状态药丸上那行字。PRD §4.1.7 的四种 + 两种半成品,文案逐字照抄。
    var label: String {
        switch self {
        case .recording(let m):   return "记录中 · \(SessionPresentation.duration(m))"
        case .organizing:         return "整理中"
        case .ready:              return "好了"
        case .broken(let why):    return why
        case .speakersPending:    return "说话人整理中"
        case .transcriptOnly:     return "只保留了文字记录"
        }
    }

    /// 卡在这儿了、**不会自己好** —— 该给用户一个「再试一次」。
    ///
    /// ⚠️ `.broken` 里混着「会自己好」的那一档(还在重试),这里连它一起算进来
    /// 是**故意的**:重试中的任务用户也有权说「我不等了」。真正的把关在
    /// `retrySession` 里 —— 它只动 `dead` / `degraded` 的行,重试中的原样不碰,
    /// 返回 0 并如实说「它还在自己重试」。
    ///
    /// 同样不写 `default`:以后加一个态,编译器在这里逼人决定它算不算卡住。
    var isStuck: Bool {
        switch self {
        case .broken, .transcriptOnly: return true
        case .recording, .organizing, .ready, .speakersPending: return false
        }
    }

    /// 已出纪要的态把纪要交出来,其余态没有。同样不写 `default`。
    var summary: SessionSummary? {
        switch self {
        case .ready(let s), .speakersPending(let s): return s
        case .recording, .organizing, .broken, .transcriptOnly: return nil
        }
    }

    /// 「3 小时 20 分」。不足一小时只说分钟,别写「0 小时 20 分」。
    ///
    /// 0 说「不到 1 分」而不是「0 分」:刚点下开始的那几十秒里,
    /// 「记录中 · 0 分」读起来像坏了,而它其实正常得很。
    static func duration(_ minutes: Int) -> String {
        if minutes <= 0 { return "不到 1 分" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) 分" }
        return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
    }
}

extension SessionDisplayState {
    /// 内部十态 → 界面六态。
    ///
    /// ⚠️ **这个 switch 刻意不写 `default`。** 以后给 `SessionDisplayState` 加一个 case,
    /// 编译器会在这里报错逼人做决定 —— 而 `default` 会把新态静悄悄塞进某一档,
    /// 用户看到的是一个「看起来完全正常」的错误文案。
    var presentation: SessionPresentation {
        switch self {
        case .recording(let m):
            return .recording(elapsedMinutes: m)
        case .waitingForNetwork, .uploading, .queued, .processing:
            return .organizing
        case .done(let s):
            return .ready(s)
        case .attributionPending(let s):
            return .speakersPending(s)
        case .partialFailure(let missing):
            // ⚠️ 关联值不能丢。上一版写死成「要点没提取出来」,
            // 而 `.partialFailure(missing: "承诺")` 会显示成「要点没提取出来」——
            // 用户按着错的线索去查。同仓 `TimelineComponents.swift` 早就是带值的写法。
            return .broken("\(missing)没提取出来")
        case .failed(let attempt, let willRetry):
            // ⚠️ 三句话,三种真相,一句都不能互相顶替:
            // · 不会再试 —— 说清楚**不会自己好**,否则用户永远在等
            // · 会再试且真的试过 —— 报第几次,让人看出它在动
            // · 会再试但一次都还没试 —— **不说「第 0 次」**。那句话本身不通,
            //   而且读起来像坏了,而它其实正常得很(同 `duration(0)` 那条)
            // ⚠️ 这句话里**不许出现「重试」二字**(测试盯着)。
            // 「不会再重试了」读起来仍像在谈重试这件事,眼睛扫过去只看见「重试」;
            // 而用户真正要判断的是**会不会自己好** —— 和 §4.1.7 里
            // 「说话人整理中 vs 只保留了文字记录」分的是同一条线,所以照那条线说话。
            if !willRetry { return .broken("处理失败,不会自己好了") }
            return .broken(attempt > 0 ? "处理失败,重试中(第 \(attempt) 次)"
                                       : "处理失败,正在重试")
        case .degraded:
            return .transcriptOnly
        }
    }
}

/// 一条要点。字段取自技术方案 §4.2 的抽取契约。
///
/// 判 4 的双字段化在这里保留:`text` 是模型可改写的自由文本,`quote` 是逐字引文——
/// 三项校验只打 quote。两个都留着,因为卡面显示 text、跳转原话要 quote 定位。
struct KeyPoint: Equatable {
    let text: String        // ≤50 字
    let quote: String       // 必须是原文子串
    let lineID: Int64       // 跳转到原话(PRD §4.2.5)
    let atMillis: Int       // 场次内绝对毫秒,卡面显示时间点
}

/// 一场的纪要内容。有就是齐的,没有就整个不存在——不做「有一句话但没要点」的中间态,
/// 那种情况是 `.partialFailure`。
struct SessionSummary: Equatable {
    let title: String           // 「与同事一对一」
    let oneLiner: String        // ≤40 字,PRD §4.2.3 写明「必有」
    let keyPoints: [KeyPoint]   // 3–5 条
}

/// 挂在场次卡上的东西的引用。内容本身在各自的库里,卡面只要 id 与一行标签。
struct AttachmentRef: Equatable {
    let id: String
    let label: String
}

/// PRD §4.2.2 挂载上限:每张卡最多 1 条发现 + 1 条进展 + 2 张卡片,超出的进详情页。
///
/// M1 期恒为 `.none`——PRD 写明 M1 只预留容器位、不产出内容。类型现在就定死,
/// 免得 M2/M3 接上来时再动一次场次卡的形状。
struct Attachments: Equatable {
    let discovery: AttachmentRef?
    let progress: AttachmentRef?
    let cards: [AttachmentRef]

    static let none = Attachments(discovery: nil, progress: nil, cards: [])

    /// 卡面是否空到该折进「零碎」(PRD §4.2.2 折叠规则的一半判据)
    var isEmpty: Bool { discovery == nil && progress == nil && cards.isEmpty }
}

/// 一张场次卡。PRD §4.2.2:单位是「场」,一场 3 小时的会仍是一张卡,不拆条。
struct SessionCard: Equatable, Identifiable {
    let id: Int64                    // session id
    let startTime: String            // 「14:00」,场次起点的本地钟面
    let durationMinutes: Int
    let state: SessionDisplayState
    let attachments: Attachments
    var source: String = SessionSource.recording
    var recordedIntervals: [RecordedInterval] = []
    var isCaptureOpen = false

    struct RecordedInterval: Equatable {
        let offsetMs: Int
        let durationMs: Int
    }
}

// MARK: - 今天处理成了没有

/// 出稿与失败合成的**首页头部一句话**(PRD §4.1.8,拍板 2026-08-12)。
///
/// ## 它为什么不是一条通知
///
/// 拍板原文:**「M1 完全不做 App 外推送」**,出稿与失败合成首页头部一句话
/// (「今天整理出 3 场,有 1 段没成」)。理由是单用户自用、每天主动打开的产品,
/// 推送收益很低而打扰成本实打实;净收益是 M1 连通知权限都不用碰。
///
/// ⚠️ 所以 `grep UNUserNotificationCenter` 零命中**是对的,而且应该是零**。
/// 任务板一度拿那条 grep 当「这一项没做」的证据 —— 尺子拿错了,照着做会去建
/// 一条拍板已经否掉的通道。真正缺的是**这句话本身**。
///
/// ## 🔴 它与 `HomeBanner` 是两条,不许合并
///
/// `HomeBanner`(§4.2.2 提示条)是**内容性**的:有东西等你看。
/// 这一条是**状态性**的:今天处理成了没有。
///
/// 合成一条、按优先级取第一条的话,**「有 1 段没成」会被「3 天没打开了」顶掉** ——
/// 而 G5 要求失败恒可见。两条各占各的位置,失败那半任何情况下不被抑制。
struct ProcessingDigest: Equatable {
    /// 有纪要可看的场次数。
    let readyCount: Int
    /// 没整理出来、要你管的那些场次。**带 id 是因为拍板要求「失败那半自带可点的出口」**。
    let brokenSessionIDs: [Int64]

    var brokenCount: Int { brokenSessionIDs.count }

    /// 从今天的场次卡里数出来。**不额外查库** —— 卡片的状态已经是这一天的真相,
    /// 再查一次就有了第二个「今天成了几场」的答案,而两个答案迟早会分叉。
    ///
    /// - Returns: 两边都是 0 时返回 nil。**这不是「今天整理出 0 场」** ——
    ///   那句话会在一个还什么都没录的早晨挂在首页上,像是出了什么事。
    static func make(from cards: [SessionCard]) -> ProcessingDigest? {
        var ready = 0
        var broken: [Int64] = []
        for card in cards {
            // ⚠️ **刻意不写 `default`**,与 `presentation` 那个 switch 同一个理由:
            // 以后加一个展示态,编译器在这里逼人决定它算「成了」还是「没成」——
            // 而 `default` 会把它静悄悄归进某一边,给出一个看起来很正常的错数。
            switch card.state.presentation {
            case .ready, .speakersPending:
                ready += 1
            case .broken, .transcriptOnly:
                // 「只保留了文字记录」也算没成:PRD §4.1.7 说它是**灰色终态、需手动重试**,
                // 也就是说它不会自己好。归进「成了」的话,用户永远不知道该去管它。
                broken.append(card.id)
            case .recording, .organizing:
                // 还在路上,两边都不算。算进任何一边都是在替一件没有结果的事下结论。
                break
            }
        }
        guard ready > 0 || !broken.isEmpty else { return nil }
        return ProcessingDigest(readyCount: ready, brokenSessionIDs: broken)
    }

    /// 拍板给的那句话的形状:「今天整理出 3 场,有 1 段没成」。
    ///
    /// 两半各自可缺:只出稿就不提失败,**只失败就不说「整理出 0 场」**
    /// —— 说了会让人以为今天本来该有稿。
    var sentence: String {
        switch (readyCount, brokenCount) {
        case (let r, 0):        return "今天整理出 \(r) 场"
        case (0, let b):        return "有 \(b) 段没成"
        case (let r, let b):    return "今天整理出 \(r) 场,有 \(b) 段没成"
        }
    }
}

// MARK: - 提示条

/// PRD §4.2.2 提示条:五条优先级取第一条。
///
/// 第 5 条「以上都无 → 不显示」没有对应的 case——那是**没有提示条**,
/// 用 `HomeFeed.banner == nil` 表达。给它建一个 `.none` case 只会让人不小心把它渲染出来。
enum HomeBanner: Equatable {
    case thingAwakened(thingID: String, text: String)     // 1 有事被唤醒
    case thingProgressed(thingID: String, text: String)   // 2 有事出现新进展
    case unreadDiscoveries(count: Int)                    // 3 有新发现未读
    case awayForDays(days: Int, sessionCount: Int)        // 4 距上次打开 >3 天
}

// MARK: - 折叠

/// PRD §4.2.2 ④:折叠成一行「还有 N 段零碎」。
/// 一段都没有时整行不出现,所以是 `HomeFeed.fragments == nil` 而不是 `count == 0`。
struct FragmentsFold: Equatable {
    let count: Int
    /// 折进来的场次 id,点开要用
    let sessionIDs: [Int64]
}

/// PRD §4.2.2 ⑤ 更早:按天折叠,下滑加载。
struct EarlierDay: Equatable, Identifiable {
    let day: String          // 「2026-08-07」
    let sessionCount: Int
    var id: String { day }
}

// MARK: - 首页

struct HomeFeed: Equatable {
    /// 今天处理成了没有(§4.1.8)。**与 `banner` 并列而不是二选一** ——
    /// 见 `ProcessingDigest` 的注释:合并会让失败被内容提示顶掉,而 G5 不允许。
    let digest: ProcessingDigest?
    let banner: HomeBanner?
    /// 今天的场次卡,**时间倒序**(PRD §4.2.2 排序规则)
    let todayCards: [SessionCard]
    let fragments: FragmentsFold?
    let earlier: [EarlierDay]
    var recordedCards: [SessionCard] = []
    var understood: [UnderstoodEvent] = []
}

struct UnderstoodEvent: Equatable, Identifiable {
    let sessionID: Int64
    let event: DetailEvent
    let sessionOpen: Bool
    let latestMillis: Int
    var id: Int64 { event.id }
}

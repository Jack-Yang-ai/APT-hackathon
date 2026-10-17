import Foundation
import GRDB
import Network

// 上传层(§六「上传层」· §1.2 第 ④ 步 · §1.3 队列与退避)。
//
// 判断都在这里,网络实现在 `BackgroundTransport`。分开是因为 URLSession 在单元
// 测试里跑不起来,而要验的三件事(退避算得对不对、仅 Wi-Fi 拦不拦得住、
// 键对不对得上)全是判断,不是网络。

/// 当前网络。`offline` 与 `cellular` 不是一回事:前者谁都传不了,
/// 后者只有开了「仅 Wi-Fi」才拦。
enum Reachability: Equatable {
    case wifi
    case cellular
    case offline

    /// 当前网络。`NWPathMonitor` 是推送式的,所以这里读的是一个常驻监视器的快照。
    ///
    /// ⚠️ **它只是闸的参考,不是执行者。** 真正挡住蜂窝上传的是后台 session 的
    /// `allowsCellularAccess = false` —— 一块音频要传好几分钟,而网络会在
    /// 传的过程中变;交出去那一刻的判断保不了后面几分钟。
    ///
    /// 监视器还没给出第一次更新时按 `.wifi` 走(乐观)。代价可控:
    /// 真没网时后台 session 自己会等到有网,而那正是想要的行为。
    static func current() -> Reachability { Monitor.shared.value }

    /// 常驻网络监视器。
    private final class Monitor: @unchecked Sendable {
        static let shared = Monitor()
        private let monitor = NWPathMonitor()
        private let lock = NSLock()
        private var cached: Reachability = .wifi

        var value: Reachability { lock.lock(); defer { lock.unlock() }; return cached }

        private init() {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let v: Reachability = path.status != .satisfied ? .offline
                    : (path.usesInterfaceType(.cellular) ? .cellular : .wifi)
                self.lock.lock(); self.cached = v; self.lock.unlock()
            }
            monitor.start(queue: DispatchQueue(label: "growth.reachability"))
        }
    }
}

enum UploadDecision: Equatable {
    case go
    /// 现在不传。**任务留在表上,不是丢弃** —— 丢弃就是静默丢单,
    /// 而这张任务表存在的理由正是替掉旧实现的静默丢单。
    case hold(reason: String)
}

enum UploadGate {
    static func decide(reachability: Reachability, wifiOnly: Bool) -> UploadDecision {
        switch reachability {
        case .offline:
            return .hold(reason: "没有网络")
        case .cellular:
            return wifiOnly ? .hold(reason: "开了仅 Wi-Fi,当前是蜂窝网络") : .go
        case .wifi:
            return .go
        }
    }
}

/// 这一块**永远传不上去**了 —— 音频文件读不出来、或者不在了。
///
/// 和普通的传输失败分开抛,是因为两者该做的事相反:普通失败要退避重试,
/// 而这个重试一万次也一样。混在一起的话,一块坏音频会把**整场**卡在退避里
/// 直到任务被判 dead(2026-08-17 真机上就是这样)。
struct PermanentUploadFailure: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

/// 网络实现。生产是后台 URLSession(`BackgroundUploadCenter`),测试注入假的。
///
/// ## ⚠️ 语义是「交出去了」,不是「传完了」
///
/// 这是 M1-4c 改掉的那个契约。原来是同步的 `upload(...) throws` ——
/// 「调用返回 = 传完了」。**那个语义和真后台不兼容**:后台 URLSession 的结果
/// 在另一个进程生命周期里才回来(App 可能已经被杀掉、几小时后因传输完成
/// 被重新拉起)。同步契约逼着调用方在原地等,而原地等正是真后台要消灭的东西。
///
/// 所以:成功返回**只说明系统收下了这个传输**。真正的结果由
/// `UploadJobStore` 里那一行说了算,而那一行由回调写。
protocol UploadTransport {
    /// 把文件交给系统去传 `key`。`tag` 是回调回来时用来对回某一块的标识。
    ///
    /// 交不出去(没配云代理、文件不在)就抛。**抛出来的是「没交成」,
    /// 不是「传失败」** —— 前者一次网络都没发生。
    ///
    /// 🔴 **`trigger` 是这一拍的真值,不是给日志凑数的参数。**
    /// 实现方在这条路径上记事件(M1-4d 的两条 VAD 事件就在
    /// `BackgroundUploadCenter.handOff` 里),而这条路径在 `BGProcessingTask`
    /// 唤醒下同样会走。写死「前台」的话 `processing_events` 会说
    /// 「你打开 App 才裁的段」,而实际是凌晨后台裁的 —— 而那张表存在的
    /// **唯一理由**就是把这两件事分开(见 `ProcessingEvents` 的文件注释)。
    ///
    /// ⚠️ **没有默认值是刻意的。** 给一个 `= .foreground` 等于把「前台」这个
    /// 假设藏进默认值里,而藏在默认值里的假设在这个仓已经害过两次
    /// (见 `PendingBlock.init` 那段)。不写就编译不过。
    func handOff(fileURL: URL, to key: String, tag: String,
                 trigger: ProcessingEvents.Trigger) throws
}

/// 一块的上传任务。任务表里存不下块号(`tasks` 表结构由 M0-2e 定死,不动),
/// 所以块清单从场次目录的落盘账本来 —— 那本来就是块的真相源(M0-1e)。
struct PendingBlock: Equatable {
    let blockSeq: Int
    let fileURL: URL
    /// 这一块的真实时长(秒)。**记账要用它** —— 转写按送检时长计费。
    ///
    /// ⚠️ 曾经在调用点写死 300(「块长 5 分钟」)。但块并不总是满 5 分钟:
    /// 用户点结束、断流续跑、路由切换都会提前切块。2026-08-17 真机实测,
    /// 四个块分别只有几十秒,而账上每块记 300 秒 —— **账面系统性高估**,
    /// 而高估会让人去优化根本不贵的地方(仓规原则 5)。
    /// 真时长本来就在账本里躺着,没有理由猜。
    let seconds: Int

    /// 这一块的起点在**场次内**的绝对毫秒(墙钟口径:块起点 − 场次起点)。
    ///
    /// 🔴 **2026-08-17 加的,和上面那个 `seconds` 是同一个错的另一半。**
    /// 冻结那一步原来写的是 `blockSeq * 300_000` —— 又一次把「块长 5 分钟」
    /// 当成了事实。而 `BlockCutPolicy` 的窗口是 **270–330 秒**
    /// (`targetMs ± windowMs`),块长本来就不是定值,用户点结束、断流续跑、
    /// 路由切换还会切出更短的块。
    /// 乘出来的偏移**逐块累积**,后果是**跳原话跳到错的位置**,而且**不报任何错**。
    ///
    /// 墙钟口径是刻意的:块之间可能有空洞(中断、暂停),而 §3.1.2 的
    /// 「场次内绝对毫秒」算的是「用户以为在录的那段真实时间」,空洞要占位置
    /// (`BlockRecord` 的注释、`gapText` 的存在都在说同一件事)。
    let offsetMs: Int

    /// 这一块的真实时长(毫秒)。给保留区间用 —— `seconds` 是取整过的,
    /// 拿它乘 1000 会比真值短最多一秒,而**短了就会让末尾那句话越界抛异常**。
    let durationMs: Int

    /// 🔴 **三个时间字段都没有默认值,这是刻意的(2026-08-17)。**
    ///
    /// 原来这里是 `seconds: Int = 300` —— 「块长 5 分钟」这个假设**藏在一个默认值里**,
    /// 而它已经害过两次:一次让账面系统性高估(见 `seconds` 那段),
    /// 一次让冻结层的偏移逐块漂移(见 `offsetMs` 那段)。
    /// 默认值的坏处正在于**不写就有**:调用方不写,拿到的是一个看起来很合理的错数。
    /// 现在不写就编译不过。
    init(blockSeq: Int, fileURL: URL, seconds: Int, offsetMs: Int, durationMs: Int) {
        self.blockSeq = blockSeq
        self.fileURL = fileURL
        self.seconds = seconds
        self.offsetMs = offsetMs
        self.durationMs = durationMs
    }
}

enum BlockUploader {

    /// 任务表里 `kind` 的取值。
    static let taskKind = "upload_audio"

    struct RunResult: Equatable {
        /// 系统已经回话说传成了的块。
        let uploaded: [Int]
        /// 交出去了、还没回话的块数。**它不是失败,也不是完成** ——
        /// 有它在就说明这一场还得再来看一眼。
        let inFlight: Int
        let heldReason: String?
        let failed: String?

        init(uploaded: [Int], inFlight: Int = 0, heldReason: String? = nil,
             failed: String? = nil) {
            self.uploaded = uploaded; self.inFlight = inFlight
            self.heldReason = heldReason; self.failed = failed
        }
    }

    /// 把一场的上传排进任务表。一场一个任务行,块清单在账本里。
    @discardableResult
    static func enqueue(sessionID: Int64, priority: Int = 1, now: String,
                        in writer: some DatabaseWriter) throws -> Int64 {
        try TaskQueue.enqueue(kind: taskKind, sessionID: sessionID,
                              priority: priority, now: now, in: writer)
    }

    /// 跑一个上传任务。**做一步就返回** —— 交完没回话的块留给下一拍去看。
    ///
    /// 四条边界:
    /// · 闸不通过 → **任务原样留在表上**,attempts 不加(不是失败,是还没到时候)
    /// · 交不出去 → 走 `TaskQueue.recordFailure`,attempts + 1、按 §1.3 退避、超限落 dead
    /// · 系统回话说没成 → 同上,并把那一行抹掉,下次重新交
    /// · 全传完   → `done`
    ///
    /// ⚠️ **「交出去了」不是「传完了」。** 交完之后任务回 `queued` + 退避,
    /// attempts **不加** —— 等系统传完不是失败,加了会把任务推向 dead,
    /// 而它其实正在正常地传。
    static func run(taskID: Int64, sessionID: Int64, blocks: [PendingBlock],
                    reachability: Reachability, wifiOnly: Bool, ext: String,
                    moreBlocksComing: Bool = false,
                    at: Date, transport: UploadTransport,
                    trigger: ProcessingEvents.Trigger,
                    pollInterval: TimeInterval = BlockUploader.pollInterval,
                    in writer: some DatabaseWriter) throws -> RunResult {

        if case .hold(let reason) = UploadGate.decide(reachability: reachability,
                                                      wifiOnly: wifiOnly) {
            // 落 `waiting_network`:这个态本来就是为这种情况建的(展示成「等待网络」)。
            // attempts **不加** —— 没网不是失败,加了会把任务推向 dead,
            // 而用户只是还没连上 Wi-Fi。`next_retry_at` 也不设:网一回来就该跑。
            try writer.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET state = 'waiting_network', last_error = ? WHERE task_id = ?
                    """, arguments: [reason, taskID])
            }
            return RunResult(uploaded: [], heldReason: reason)
        }

        try writer.write { db in
            try db.execute(sql: "UPDATE tasks SET state = 'uploading' WHERE task_id = ?",
                           arguments: [taskID])
        }

        let now = ISO8601DateFormatter.growth.string(from: at)
        var uploaded: [Int] = []
        var inFlight = 0
        /// 永久坏掉、已跳过的块。它们让这一场落成 `partial`,而不是卡住。
        var skipped: [Int] = []

        for block in blocks {
            let key = R2Layout.audioKey(sessionID: sessionID, blockSeq: block.blockSeq, ext: ext)
            let existing = try writer.read { db in
                try UploadJobStore.fetch(db, sessionID: sessionID, blockSeq: block.blockSeq)
            }

            switch existing?.state {
            case "done":
                uploaded.append(block.blockSeq)
                continue

            case "handed":
                inFlight += 1
                continue

            case "failed":
                // 🔴 **永久失败的块跳过,不拖垮整场。**
                // 音频文件读不出来(空块、写了一半)重试一万次也一样,而
                // §3.1.6 本来就允许缺块以 `partial` 落库。2026-08-17 真机:
                // 结束那一刻开的空块把整场卡在退避里,后面全不动。
                if existing?.httpStatus == UploadJobStore.permanentStatus {
                    skipped.append(block.blockSeq)
                    continue
                }
                // 传输失败是**一次真失败**,走任务表的退避,不在这里原地重交。
                // 原地重交等于绕开 `dead` 终态:一个永远传不上去的块会被无限重交,
                // 而任务表上看不出任何异常。
                let why = existing?.lastError ?? "上传失败"
                try TaskQueue.recordFailure(taskID: taskID, error: "\(key): \(why)",
                                            at: at, in: writer)
                // 抹掉那一行,下一次重试才会重新交给系统
                try UploadJobStore.reset(sessionID: sessionID, blockSeq: block.blockSeq,
                                         in: writer)
                return RunResult(uploaded: uploaded, inFlight: inFlight, failed: why)

            default:
                // 还没交过 —— 先占住行再交。**顺序不能反**:先交后占的话,
                // 传输在占行之前就回调完了,回调会找不到行,结果被扔掉,
                // 而这一块从此停在「没人管」。
                do {
                    let tag = UploadJobStore.tag(sessionID: sessionID, blockSeq: block.blockSeq)
                    try UploadJobStore.claim(sessionID: sessionID, blockSeq: block.blockSeq,
                                             key: key, now: now, in: writer)
                    try transport.handOff(fileURL: block.fileURL, to: key, tag: tag,
                                          trigger: trigger)
                    inFlight += 1
                } catch let e as PermanentUploadFailure {
                    // 这一块的音频本身坏了 —— 重试没有意义。标死它、跳过、继续下一块。
                    // **不动任务的 attempts**:这不是这一场的失败,是这一块没了。
                    try UploadJobStore.failPermanently(
                        sessionID: sessionID, blockSeq: block.blockSeq,
                        error: e.reason, now: now, in: writer)
                    skipped.append(block.blockSeq)
                    continue
                } catch BackgroundUploadCenter.Failure.notConfigured {
                    // 🔴 **「没配」不烧 attempts。** 这条腿原先把它当普通失败,
                    // 走下面的 `recordFailure` ⇒ 用户还没来得及填设置,任务就
                    // 已经把 27 次 attempts 烧完、判 dead —— 而 dead 没有复活路径。
                    // 而转写腿与抽取腿对同一件事的处理是「退到下一拍再看」。
                    // 三条腿口径必须一致,否则同一个原因三种下场,谁都说不清哪个对。
                    try UploadJobStore.reset(sessionID: sessionID, blockSeq: block.blockSeq,
                                             in: writer)
                    try writer.write { db in
                        try db.execute(sql: """
                            UPDATE tasks SET state = 'retrying', last_error = ?, next_retry_at = ?
                             WHERE task_id = ?
                            """, arguments: [ProcessingOrchestrator.notConfiguredReason,
                                             ISO8601DateFormatter.growth.string(
                                                from: at.addingTimeInterval(pollInterval)),
                                             taskID])
                    }
                    return RunResult(uploaded: uploaded, inFlight: inFlight,
                                     heldReason: ProcessingOrchestrator.notConfiguredReason)
                } catch {
                    // 交不出去 ≠ 传失败:一次网络都没发生。行要抹掉,
                    // 不然它会停在 `handed` 等一个永远不会来的回调。
                    try UploadJobStore.reset(sessionID: sessionID, blockSeq: block.blockSeq,
                                             in: writer)
                    try TaskQueue.recordFailure(taskID: taskID, error: "\(key): \(error)",
                                                at: at, in: writer)
                    return RunResult(uploaded: uploaded, inFlight: inFlight, failed: "\(error)")
                }
            }
        }

        // 🔴 **场次还开着 = 后面还会有新块。** 这时候「已知的块都传完了」
        // 不等于「这一场传完了」,标 done 会让这个任务再也捡不起来,
        // 而后面切出来的块**永远没人传**。判据在编排那边(它读 sessions.status),
        // 这里只按它说的做。
        guard !moreBlocksComing else {
            try writer.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET state = 'queued', last_error = NULL, next_retry_at = ?
                     WHERE task_id = ?
                    """, arguments: [ISO8601DateFormatter.growth.string(
                                        from: at.addingTimeInterval(pollInterval)), taskID])
            }
            return RunResult(uploaded: uploaded, inFlight: inFlight)
        }

        guard inFlight == 0 else {
            // 还有在传的 —— 退避后再来看。**attempts 不加**:等传输完成不是失败。
            try writer.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET state = 'queued', last_error = NULL, next_retry_at = ?
                     WHERE task_id = ?
                    """, arguments: [ISO8601DateFormatter.growth.string(
                                        from: at.addingTimeInterval(pollInterval)), taskID])
            }
            return RunResult(uploaded: uploaded, inFlight: inFlight)
        }

        try writer.write { db in
            try db.execute(sql: "UPDATE tasks SET state = 'done', last_error = NULL WHERE task_id = ?",
                           arguments: [taskID])
        }
        return RunResult(uploaded: uploaded)
    }

    /// 还在传的时候隔多久回来看一眼(默认值,可由编排注入)。
    ///
    /// 30 秒不是随便挑的:它比一块 5 分钟音频在 Wi-Fi 上的传输时间长,
    /// 又比 `BGProcessingTask` 的典型唤醒间隔短 —— 前台开着时不会空转太多拍,
    /// 后台唤醒时又总能赶上已经传完的那些。
    static let pollInterval: TimeInterval = 30
}

import Foundation

/// 手表 → 手机的消息契约(W1 spec 决定 2)。**手表与手机两个 target 共用这一份。**
///
/// ## 一条消息 = 手表账本里的一行
///
/// 手表是它那本账的唯一作者,手机只按序誊写(铁律 1 的形状:手表产物,手机合并)。
/// 每条消息带一个**全局递增**的 `msgSeq`;块条目随音频文件一起走,
/// 标记条目(开场/暂停/继续/中断/收尾)走一个装着这条消息的小文件。
///
/// 后台 `transferFile` 与即时字节传送携带**同一条消息**，共同进入 WatchInbox。
/// 顺序由下面的 `msgSeq` 门控制，不依赖系统的送达先后；即时传送须整文件校验
/// 并收到落盘回执，才移出同一外发账。两条送达路径不各造应用序号或提前收尾。
///
/// ## 手机按 `msgSeq` 严格按序应用
///
/// · 小于等于已应用的 ⇒ 重复,丢掉(系统重传、手表重装后重发都可能)
/// · 前面缺号 ⇒ 先存着,等补齐;**不跳过** —— 跳过就是静默丢一段音频
struct WatchMessage: Equatable, Codable {
    /// 契约版本。手机认不得更高的版本时**照收不应用、如实报**,不猜着解。
    let v: Int
    /// 手表这一次安装的身份(首次启动生成的 UUID)。**序号只在同一个安装号里有意义** ——
    /// 重装、换表、外发记录读不出来时序号会从 0 重来,不分安装号的话手机会把
    /// 新录音当成「已经收过的旧号」静默丢掉(W1 对抗审查 2026-10-12)。
    let installID: String
    /// 同一安装号内全局递增,从 0 起,永不回退。
    let msgSeq: Int
    /// 这一行属于手表上哪一天的目录(`yyyy-MM-dd`,那一场的**开场日**)。
    let day: String
    /// 手表账本里的那一行,原样。
    let entry: LedgerEntry
    /// 首次登记外发账的时间；旧版登记后立即提交系统，新批次模式还包含本地等待。
    /// 到达日志用它算排队到收件延迟，不能据此推断无线发送耗时。
    let sentAt: Date
    /// 登记时的手表电量(0–1)，可画录音续航曲线；不代表无线发送时的电量。取不到就是 nil。
    let watchBattery: Float?

    var isBlock: Bool { entry.block != nil }

    /// 手机落盘用的名字:安装号 + 序号。只用序号会让两次安装的同号互相顶掉。
    var key: String { "\(installID)-\(msgSeq)" }
}

enum WatchLink {

    /// `transferFile` 元数据里装消息的那个键。元数据只收 plist 类型,所以存 JSON 字节。
    static let metadataKey = "growth.watch.msg"

    /// 当前契约版本。改了 `WatchMessage` / `LedgerEntry` 的形状就加一。
    static let version = 1

    private static var encoder: JSONEncoder {
        // 与 `BlockLedger` 同一个日期口径 —— 手机誊写时再经它编码一次,
        // 两边口径不同的话「账本最后一行是不是这条」永远比不上(见 `alreadyApplied`)。
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case noMetadata
        case undecodable(String)

        var description: String {
            switch self {
            case .noMetadata:
                return "手表传来的文件没带消息元数据 —— 不知道它是第几条、属于哪天,不敢落"
            case .undecodable(let why):
                return "手表传来的消息解不开:\(why)"
            }
        }
    }

    static func data(_ m: WatchMessage) throws -> Data { try encoder.encode(m) }
    static func message(from data: Data) throws -> WatchMessage {
        do { return try decoder.decode(WatchMessage.self, from: data) }
        catch { throw Failure.undecodable(String(describing: error)) }
    }

    static func metadata(_ m: WatchMessage) throws -> [String: Any] {
        [metadataKey: try data(m)]
    }

    static func message(fromMetadata md: [String: Any]?) throws -> WatchMessage {
        guard let raw = md?[metadataKey] as? Data else { throw Failure.noMetadata }
        return try message(from: raw)
    }

    // MARK: - 手机侧:按序应用

    struct ApplyPlan: Equatable {
        /// 现在就能按序应用的号(从 `nextExpected` 起连续的那一段)。
        let apply: [Int]
        /// 已经应用过的号 —— 重复,丢掉。
        let duplicates: [Int]
        /// 卡住后面所有消息的那个缺号。nil = 没有缺口(手上的全应用完了)。
        let missing: Int?
    }

    /// 纯函数:已应用到哪 + 手上有哪些号 ⇒ 这一轮怎么办。
    ///
    /// - Parameters:
    ///   - nextExpected: 下一个该应用的号(已应用的最大号 + 1;一条都没应用过是 0)。
    ///   - pending: 手上待应用的号,顺序与重复都不假设。
    static func plan(nextExpected: Int, pending: [Int]) -> ApplyPlan {
        let have = Set(pending)
        let duplicates = have.filter { $0 < nextExpected }.sorted()
        var apply: [Int] = []
        var n = nextExpected
        while have.contains(n) { apply.append(n); n += 1 }
        let stuck = have.contains { $0 > n }
        return ApplyPlan(apply: apply, duplicates: duplicates, missing: stuck ? n : nil)
    }

    /// 誊写前的判据:**镜像账本里已经有这一条**,就不再追加。
    ///
    /// 不只看最后一行(初稿那样写):手表重装或外发记录丢了之后会换安装号把整天重发一遍,
    /// 那时重复的是**整本**,不是最后一行。一天的账本不过几百行,整本比一遍很便宜。
    /// 重复一行块条目的代价是同一块转写两次 —— 真花两笔钱。
    ///
    /// ⚠️ 两条**合法但完全相等**的相邻条目(同一秒内两次中断)会被当成一条。
    /// 状态机里同一种标记不会连写两次(两次断流之间至少隔一个探测阈值),块条目带块号,
    /// 所以这只可能吞掉一条重复的 `interrupted` —— 它不闭合任何区间,吞了不改变空洞算术。
    static func alreadyApplied(_ entry: LedgerEntry, in ledger: [LedgerEntry]) -> Bool {
        ledger.contains(entry)
    }

    // MARK: - 手表侧:外发账

    /// 手表外发的全部状态(持久化成一个 JSON)。纯值,好测。
    ///
    /// ## 顺序:先记账(含「在途」),再交给系统
    ///
    /// 分配了号、记进 `inflight` 并落盘之后才 `transferFile`。被杀在两者之间 ⇒
    /// 重开后 `inflight` 里有它而系统队列里没有 ⇒ **用同一份消息**再交一次。
    /// 号不会丢(没有永远补不上的缺口),也不会换(同一条不会拿到两个号)。
    ///
    /// ## 送到之前不删
    ///
    /// `inflight` 里的条目要等系统回报成功或即时整文件落盘回执才移出;块文件被 `inflight` 引用时
    /// 保留期不许删(`pinnedPaths`)。失败的不当场重发(持续性错误会空转耗电),
    /// 旧版按 `retryInterval` 补交；当前手表按 `batchInterval` 集中补交。
    struct Book: Codable, Equatable {
        enum DeliveryFailure: Error { case differentMessage }
        struct Inflight: Codable, Equatable {
            /// 要传的文件,相对 Documents。
            let path: String
            let message: WatchMessage
        }

        let installID: String
        private(set) var nextMsgSeq = 0
        /// 每天那本账已经**分配了号**的行数。
        private(set) var sentCount: [String: Int] = [:]
        /// 已交出去、还没收到成功回报的。键是 `msgSeq`。
        private(set) var inflight: [Int: Inflight] = [:]
        private(set) var lastRetryAt: Date?
        /// 自动同步批次的起点；旧外发账缺字段时按最早待传消息恢复。
        private(set) var lastBatchAt: Date?

        static let retryInterval: TimeInterval = 5 * 60
        static let batchInterval: TimeInterval = 15 * 60

        init(installID: String = UUID().uuidString) { self.installID = installID }

        /// 给一行分配号、记为在途。调用方**先落盘这本账,再交给系统**。
        mutating func enqueue(_ entry: LedgerEntry, day: String, path: String,
                              now: Date, battery: Float?) -> WatchMessage {
            if inflight.isEmpty, entry.kind == SessionMark.sessionStarted.rawValue {
                lastBatchAt = nil
            }
            let m = WatchMessage(v: WatchLink.version, installID: installID, msgSeq: nextMsgSeq,
                                 day: day, entry: entry, sentAt: now, watchBattery: battery)
            inflight[m.msgSeq] = Inflight(path: path, message: m)
            nextMsgSeq += 1
            sentCount[day, default: 0] += 1
            return m
        }

        mutating func delivered(_ msgSeq: Int) { inflight[msgSeq] = nil }

        /// 系统回调的日期经 ISO 编码，先核同一完整消息，不能让旧安装号释放新号。
        func owns(_ message: WatchMessage) -> Bool {
            guard let item = inflight[message.msgSeq],
                  let stored = try? WatchLink.data(item.message),
                  let returned = try? WatchLink.data(message) else { return false }
            return stored == returned
        }

        /// 两条成功路径共用：持久提交失败时调用者仍持有原 book，所有原件继续被 pinned。
        func committingDelivery(_ message: WatchMessage, persist: (Book) throws -> Void) throws -> Book {
            guard owns(message) else { throw DeliveryFailure.differentMessage }
            var next = self
            next.delivered(message.msgSeq)
            try persist(next)
            return next
        }

        /// 在途、但系统队列里已经没有的 —— 被杀前没交出去的,或交了但失败了的。
        func needsResend(outstanding: Set<Int>) -> [Inflight] {
            inflight.values.filter { !outstanding.contains($0.message.msgSeq) }
                .sorted { $0.message.msgSeq < $1.message.msgSeq }
        }

        func retryDue(now: Date) -> Bool {
            lastRetryAt.map { now.timeIntervalSince($0) >= Self.retryInterval } ?? true
        }
        mutating func markRetried(now: Date) { lastRetryAt = now }

        /// 本地切块不变，传输按墙钟批次节流。空队列不发送；闲置后新录音重新等一批。
        func batchDue(now: Date) -> Bool {
            guard let first = inflight.values.map(\.message.sentAt).min() else { return false }
            let anchor = lastBatchAt ?? first
            return now.timeIntervalSince(anchor) >= Self.batchInterval
        }

        /// 必须先持久保存批次时间，再开始任何传输；落盘失败不改变原账。
        func committingBatch(now: Date, persist: (Book) throws -> Void) throws -> Book {
            var next = self
            next.lastBatchAt = now
            try persist(next)
            return next
        }

        /// 还被在途消息引用的文件。保留期不许删它们。
        var pinnedPaths: Set<String> { Set(inflight.values.map(\.path)) }
        /// 在途的**块**数(界面上「还有几块没传到」)。标记不算块。
        var inflightBlocks: Int { inflight.values.filter { $0.message.isBlock }.count }
        func sent(day: String) -> Int { sentCount[day] ?? 0 }
    }

    /// 即时任务只取已获批批次。结束时可追加尾块，普通切块不会进入此集合。
    struct LiveBatch {
        private(set) var pending: [Int: Book.Inflight] = [:]
        private(set) var active: Int?

        mutating func admit(_ items: [Book.Inflight]) {
            for item in items where item.message.msgSeq != active {
                pending[item.message.msgSeq] = item
            }
        }

        mutating func takeNext() -> Book.Inflight? {
            guard active == nil, let seq = pending.keys.min() else { return nil }
            active = seq
            return pending.removeValue(forKey: seq)
        }

        mutating func finish(retrying item: Book.Inflight? = nil) {
            active = nil
            if let item { pending[item.message.msgSeq] = item }
        }
        mutating func cancelWaiting() { pending.removeAll() }
    }

    // MARK: - 手表侧:哪些还没发

    /// 一本账本里**还没发过的**行。`sentCount` = 这本账已经发出去的行数。
    ///
    /// ⚠️ 账本被截过(`sentCount` 比现有行数还多)时**一条都不发**并交给调用方报错 ——
    /// 账本只追加不改写,行数变少只可能是文件被换掉了,照着新文件重发会把别的场次发成这一场。
    static func unsent(_ entries: [LedgerEntry], sentCount: Int) -> ArraySlice<LedgerEntry>? {
        guard sentCount <= entries.count else { return nil }
        return entries[sentCount...]
    }
}

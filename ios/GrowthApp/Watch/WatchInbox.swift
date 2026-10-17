import Foundation
import UIKit
import WatchConnectivity
import GRDB

/// 手机这一侧的手表收件处(W1 spec 决定 2)。
///
/// ## 接收与接线
///
/// 收到的每条消息**在回调返回之前**挪进 `Documents/watch_inbox/`
/// (回调一返回系统就删临时文件,晚一步就没了),再往 `arrivals.jsonl` 记一行。
/// 库可用后,同一串行队列按安装号/序号誊写,接入既有处理链。
///
/// ⚠️ 收件目录**不在 `recordings/` 下面**:「清除全部录音」(`AudioWipe`)把
/// `recordings/` 下每个子目录都当成一天来清,放在里面的话一次清除就把还没誊写的
/// 手表录音和 W0 的到达日志一起删掉(W1 对抗审查)。
///
/// 到达日志就是 W0 的数据源:`watchBattery` 连起来是 W0-1 的续航曲线,
/// `receivedAt − entryAt` 是 W0-3 的「切完到落盘」延迟,`appState` 回答
/// 「手机 App 被关掉时会不会被拉起来」。
final class WatchInbox: NSObject, WCSessionDelegate {

    static let shared = WatchInbox()
    static let changed = Notification.Name("GrowthWatchInboxChanged")
    static let connectionChanged = Notification.Name("APTWatchConnectionChanged")
    private let queue = DispatchQueue(label: "com.growth.watch.inbox")
    private var writer: DatabaseQueue?
    private let statusLock = NSLock()
    private var _notice: String?
    private var _connection: WatchConnectionStatus = .connecting
    var connection: WatchConnectionStatus { statusLock.lock(); defer { statusLock.unlock() }; return _connection }
    var notice: String? { statusLock.lock(); defer { statusLock.unlock() }; return _notice }

    /// 冷启动收件先激活,数据库开好后补处理所有之前落盘的消息。
    func startProcessing(in db: DatabaseQueue) {
        queue.async { self.writer = db; self.drain() }
    }

    /// 前台/后台每次推泵都重试文件接线,不只依赖首次到达回调。
    func processPending() async {
        await withCheckedContinuation { continuation in
            queue.async { self.drain(); continuation.resume() }
        }
    }

    private func drain() {
        guard let writer else { return }
        let previousNotice = notice
        let nextNotice: String?
        do {
            let report = try WatchMirror.drain(inbox: Self.inboxDir, in: writer)
            nextNotice = Self.recordDrainReport(report, previousNotice: previousNotice, in: writer)
        } catch {
            nextNotice = Self.recordDrainReport(.init(applied: 0, notices: ["手表录音还没同步: \(error)"]),
                                               previousNotice: previousNotice, in: writer)
        }
        statusLock.lock(); _notice = nextNotice; statusLock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// 普通顺序／场次守卫也会阻塞，不能只把抛出的异常记进处理日志。
    /// 同一原因只在变化时记录，避免每次推泵把诊断历史刷掉。
    static func recordDrainReport(_ report: WatchMirror.Report, previousNotice: String?,
                                  in writer: some DatabaseWriter) -> String? {
        let notices = Array(Set(report.notices)).sorted()
        let next = notices.isEmpty ? nil : notices.joined(separator: "\n")
        if report.applied > 0 {
            ProcessingEvents.record(trigger: .transferCallback,
                outcome: "手表录音已同步 \(report.applied) 条记录", in: writer)
        }
        if next != previousNotice {
            ProcessingEvents.record(trigger: .transferCallback,
                outcome: next == nil ? "手表录音同步已恢复" : "手表录音同步受阻，原件已保留",
                detail: next, in: writer)
        }
        return next
    }

    static var inboxDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch_inbox")
    }
    static var arrivalsURL: URL { inboxDir.appendingPathComponent("arrivals.jsonl") }

    /// 必须在 `didFinishLaunching` **返回之前**调:手表传文件把 App 从后台拉起来时,
    /// 委托要已经在,否则那条文件交给谁?
    func activate() {
        AppStateTracker.shared.start()
        guard WCSession.isSupported() else { publishConnection(.unsupported); return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        refreshConnection()
    }

    /// 回到前台时也读一次，避免错过后台配对／安装变化。
    func refreshConnection() {
        guard WCSession.isSupported() else { publishConnection(.unsupported); return }
        let session = WCSession.default
        if session.activationState == .notActivated { session.activate() }
        updateConnection(session)
    }

    private func updateConnection(_ session: WCSession, error: Error? = nil) {
        publishConnection(WatchConnectionStatus(supported: true, activation: session.activationState,
            paired: session.isPaired, installed: session.isWatchAppInstalled,
            reachable: session.isReachable, error: error?.localizedDescription))
    }

    private func publishConnection(_ value: WatchConnectionStatus) {
        statusLock.lock()
        let changed = _connection != value
        _connection = value
        statusLock.unlock()
        if changed {
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.connectionChanged, object: nil) }
        }
    }

    // MARK: - 收件

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // 系统临时文件必须在回调返回前落地。与重试誊写共用一条串行队列。
        queue.sync { receive(file) }
        guard let db = AppDatabase.shared else { return }
        Task {
            await ProcessingPump.run(trigger: .transferCallback, in: db)
        }
    }

    /// 即时传输只确认已持久保存的字节；整文件验摘要后复用同一收件箱及顺序门。
    func session(_ session: WCSession, didReceiveMessageData data: Data,
                 replyHandler: @escaping (Data) -> Void) {
        queue.async {
            var packet: WatchLiveTransfer.Packet?
            do {
                let decoded = try WatchLiveTransfer.decode(data)
                packet = decoded
                let result = try WatchLiveReceiver.accept(decoded, inbox: Self.inboxDir)
                if let landed = result.landing {
                    let msg = decoded.header.message
                    var arrival = Arrival(receivedAt: Date(), appState: AppStateTracker.shared.current, error: result.receipt.error)
                    arrival.installID = msg.installID; arrival.msgSeq = msg.msgSeq; arrival.v = msg.v
                    arrival.kind = msg.entry.kind; arrival.day = msg.day; arrival.entryAt = msg.entry.at
                    arrival.sentAt = msg.sentAt; arrival.watchBattery = msg.watchBattery
                    arrival.bytes = decoded.header.totalBytes; arrival.outcome = landed.rawValue
                    arrival.transport = "live"
                    self.log(arrival)
                    self.drain()
                }
                replyHandler(try WatchLiveTransfer.encode(result.receipt))
                if result.receipt.complete, let db = self.writer {
                    Task { await ProcessingPump.run(trigger: .transferCallback, in: db) }
                }
            } catch {
                let reply = WatchLiveTransfer.Receipt(key: packet?.header.message.key ?? "",
                    sha256: packet?.header.sha256 ?? "", nextOffset: 0, complete: false,
                    error: String(describing: error).prefix(512).description)
                replyHandler((try? WatchLiveTransfer.encode(reply)) ?? Data())
            }
        }
    }

    private func receive(_ file: WCSessionFile) {
        let receivedAt = Date()
        let state = AppStateTracker.shared.current
        let msg: WatchMessage
        do {
            msg = try WatchLink.message(fromMetadata: file.metadata)
        } catch {
            log(Arrival(receivedAt: receivedAt, appState: state, error: String(describing: error)))
            return
        }
        var a = Arrival(receivedAt: receivedAt, appState: state, error: nil)
        a.transport = "file"
        a.installID = msg.installID; a.msgSeq = msg.msgSeq; a.v = msg.v
        a.kind = msg.entry.kind; a.day = msg.day; a.entryAt = msg.entry.at
        a.sentAt = msg.sentAt; a.watchBattery = msg.watchBattery
        a.bytes = (try? FileManager.default.attributesOfItem(atPath: file.fileURL.path)[.size]) as? Int
        do {
            let landed = try Self.land(file.fileURL, msg: msg, into: Self.inboxDir)
            a.outcome = landed.rawValue
            if landed != .conflict {
                // 清临时副本失败不能把已落盘的正式录音记成失败。
                try? WatchLiveReceiver.discardReceivedPartial(for: msg, inbox: Self.inboxDir)
            }
        } catch {
            // 落不下来**要留痕,而且带着是哪一条**:手表那边以为送到了,
            // 这里再不记就两边都不知道丢了第几号。
            a.error = String(describing: error)
        }
        log(a)
        drain()
    }

    enum Landing: String { case landed, duplicate, conflict }

    /// 把一条消息落进收件目录:`<key>.msg.json`(消息本身)+ 块的话再加 `<key>.m4a`。
    /// `key` = 安装号 + 序号,两次安装的同号不互相顶掉。
    ///
    /// · 同 key 已经在、内容一样 ⇒ 重复到达,丢掉这一份;
    /// · 同 key 已经在、**内容不一样** ⇒ 不该发生(同一安装号同一序号只该对应一条)。
    ///   **两份都留**、标冲突 —— 当重复丢掉就是静默丢一段录音。
    ///
    /// 消息文件最后写:它在 = 这一条完整落地了(音频先到位)。被杀在两者之间时,
    /// 第二次同号到达会看到「没有消息文件」,把残缺的那份音频换掉。
    static func land(_ src: URL, msg: WatchMessage, into dir: URL) throws -> Landing {
        try WatchMirror.validateEnvelope(msg)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var key = msg.key
        var outcome = Landing.landed
        let existing = dir.appendingPathComponent("\(key).msg.json")
        if fm.fileExists(atPath: existing.path) {
            let sameMessage = (try? Data(contentsOf: existing)) == (try WatchLink.data(msg))
            let receipt = dir.appendingPathComponent("\(key).sha256")
            let sameAudio: Bool
            if msg.isBlock {
                let existingAudio = dir.appendingPathComponent("\(key).m4a")
                let previous = (try? String(contentsOf: receipt, encoding: .utf8))
                    ?? (try? WatchMirror.digest(existingAudio))
                sameAudio = try WatchMirror.digest(src) == previous
            } else { sameAudio = true }
            if sameMessage && sameAudio { return .duplicate }
            key += ".conflict-\(UUID().uuidString.prefix(8))"
            outcome = .conflict
        }
        if msg.isBlock {
            let audio = dir.appendingPathComponent("\(key).m4a")
            if fm.fileExists(atPath: audio.path) { try fm.removeItem(at: audio) }
            // 字节摘要也是接收收据。已誊写后收件音频可删,重传仍能核内容是否相同。
            let hash = try WatchMirror.digest(src)
            try fm.moveItem(at: src, to: audio)
            try Data(hash.utf8).write(to: dir.appendingPathComponent("\(key).sha256"), options: .atomic)
        }
        try WatchLink.data(msg).write(to: dir.appendingPathComponent("\(key).msg.json"), options: .atomic)
        return outcome
    }

    // MARK: - 到达日志

    struct Arrival: Codable {
        var installID: String?
        var msgSeq: Int?
        var v: Int?
        var kind: String?
        var day: String?
        var entryAt: Date?
        var sentAt: Date?
        let receivedAt: Date
        let appState: String
        var watchBattery: Float?
        var bytes: Int?
        /// `landed` / `duplicate` / `conflict`。重复不剔掉的话 W0-3 的延迟会混进重传。
        var outcome: String?
        var error: String?
        var transport: String?

        init(receivedAt: Date, appState: String, error: String?) {
            self.receivedAt = receivedAt; self.appState = appState; self.error = error
        }
    }

    private func log(_ a: Arrival) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let url = Self.arrivalsURL
        do {
            var line = try e.encode(a)
            line.append(0x0A)
            try FileManager.default.createDirectory(at: Self.inboxDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            // 文件在但打不开时**不许整份重写**(那会抹掉已有的实测数据);记一行系统日志。
            NSLog("[growth] watch inbox: 到达日志写不进去 %@ —— %@", "\(error)", "\(a)")
        }
    }

    // MARK: - 会话生命周期(iOS 必须实现这三个)

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        if let error { NSLog("[growth] watch session activation: %@", "\(error)") }
        updateConnection(session, error: error)
    }
    func sessionReachabilityDidChange(_ session: WCSession) { updateConnection(session) }
    func sessionWatchStateDidChange(_ session: WCSession) { updateConnection(session) }
    func sessionDidBecomeInactive(_ session: WCSession) { publishConnection(.connecting) }
    /// 换了一块配对的表。重新激活,不然新表传来的东西没人收。
    func sessionDidDeactivate(_ session: WCSession) {
        publishConnection(.connecting)
        WCSession.default.activate()
    }
}

/// 「手机 App 此刻在前台还是后台」,给到达日志用。
///
/// `UIApplication.applicationState` 只能在主线程读,而收件回调不在主线程。
/// 原来用 `DispatchQueue.main.sync` 去读 —— 启动阶段主线程被别的事占着时会把收件拖住。
/// 改成主线程上听通知、记进一个上锁的值,收件时直接读。
final class AppStateTracker {
    static let shared = AppStateTracker()
    private let lock = NSLock()
    private var value = "unknown"
    private var tokens: [NSObjectProtocol] = []

    var current: String { lock.lock(); defer { lock.unlock() }; return value }

    /// 在主线程上调(`didFinishLaunching` 里)。
    func start() {
        guard tokens.isEmpty else { return }
        set(Self.name(UIApplication.shared.applicationState))
        let nc = NotificationCenter.default
        let pairs: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willResignActiveNotification, "inactive"),
            (UIApplication.didEnterBackgroundNotification, "background"),
        ]
        for (name, state) in pairs {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.set(state)
            })
        }
    }

    private func set(_ s: String) { lock.lock(); value = s; lock.unlock() }

    private static func name(_ s: UIApplication.State) -> String {
        switch s {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

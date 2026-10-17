import Foundation
import WatchConnectivity
import WatchKit

/// 手表的外发箱(W1 spec 决定 2、3)。把本地账本里**还没发过的行**按序交给系统传给手机。
///
/// 所有「发没发、送没送到、该不该重发、能不能删」的判断在 `WatchLink.Book`(纯值,有测试);
/// 这里只做 IO:读账本、落盘外发账、按批次发送后台文件及即时字节。
///
/// 顺序与理由见 `WatchLink.Book` 的注释:**先记账(含在途)再交出去;送到之前不删;
/// 录音期间约每 15 分钟集中传输；结束、暂停和手动同步立即补交。**
@MainActor
final class WatchOutbox: NSObject, ObservableObject {

    /// 还没收到「送到了」回报的块数。界面上「还有几块没传到手机」就是它。
    @Published private(set) var inflightBlocks = 0
    /// 跟手机连上了没有(会话已激活)。没连上时「都已传到」是假话。
    @Published private(set) var linked = false
    @Published private(set) var reachable = false
    @Published private(set) var activelySyncing = false
    /// 最近一次出错。**下一次成功送到就清掉** —— 一直挂着的红字很快就没人看了。
    @Published private(set) var lastError: String?

    static let retentionDays = 3

    private var book: WatchLink.Book
    private let docs: URL
    private let bookURL: URL
    private let markDir: URL
    private var root: URL?
    private var liveTask: Task<Void, Never>?
    private var liveBatch = WatchLink.LiveBatch()
    private var lastBatchAttemptAt: Date?

    override init() {
        docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        markDir = docs.appendingPathComponent("outbox")
        try? FileManager.default.createDirectory(at: markDir, withIntermediateDirectories: true)
        bookURL = markDir.appendingPathComponent("book.json")
        let (loaded, loadError) = Self.loadBook(at: bookURL)
        book = loaded
        super.init()
        lastError = loadError
        inflightBlocks = book.inflightBlocks
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    }

    /// 外发账读不出来时**换一个安装号从头发**,并且说出来。
    ///
    /// 不能静默回落成初始值:那样序号从 0 重来,而手机按(安装号, 序号)认 ——
    /// 安装号没变的话新录音会被当成「收过的旧号」丢掉。换了安装号,手机把它当
    /// 一条新的流;重发的整天内容在誊写时按条目去重(`WatchLink.alreadyApplied`)。
    private static func loadBook(at url: URL) -> (WatchLink.Book, String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.init(), nil) }
        do {
            return (try JSONDecoder().decode(WatchLink.Book.self, from: Data(contentsOf: url)), nil)
        } catch {
            // 坏文件留着当证据,不覆盖。
            try? FileManager.default.moveItem(
                at: url, to: url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))"))
            return (.init(), "外发记录读不出来(\(error)),已换新的安装号把录音整批重发")
        }
    }

    /// 激活完成之后**由回调**补发积压 —— 没激活就 `transferFile` 是会失败的。
    func activate(root: URL) {
        self.root = root
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 把所有天的账本都过一遍(上次被杀时可能有没交出去的行),再补发在途的。
    func flushAll(root: URL, force: Bool = false) {
        for dir in Self.dayDirs(root) { stage(dayDir: dir) }
        sendPendingIfDue(force: force)
        refresh()
        prune(root: root)
    }

    func retryPending(force: Bool = false) {
        if let root { flushAll(root: root, force: force) }
        refresh()
        startLiveIfPossible()
    }

    func flush(dayDir: URL, force: Bool = false) {
        stage(dayDir: dayDir)
        sendPendingIfDue(force: force)
        refresh()
    }

    /// 每次切块只落外发账；等传输批次才交给系统。待传原件仍由 book 保留。
    private func stage(dayDir: URL) {
        let ledger = dayDir.appendingPathComponent("ledger.jsonl")
        guard FileManager.default.fileExists(atPath: ledger.path) else { return }
        // 没激活时不分配号 —— 激活回调会把积压整个补一遍。
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let day = dayDir.lastPathComponent
        do {
            // 读不出最后半行是正常的(被杀时写到一半),那一行下次再发。
            let entries = try BlockLedger.read(from: ledger).entries
            guard let tail = WatchLink.unsent(entries, sentCount: book.sent(day: day)) else {
                lastError = "\(day) 的账本比已经发出去的还短(\(entries.count) < \(book.sent(day: day)))"
                    + "—— 文件被换过,这一天停发"
                return
            }
            for entry in tail {
                let path = filePath(for: entry, day: day)
                var next = book
                let msg = next.enqueue(entry, day: day, path: path, now: Date(), battery: battery())
                if !msg.isBlock {
                    // 标记没有音频,也走文件通道(见 `WatchLink` 顶上那段:一条通道才有顺序)。
                    try WatchLink.data(msg).write(to: docs.appendingPathComponent(path), options: .atomic)
                }
                // **先落账再交出去。** 落账失败就不交 —— 这一行下次再来,号也没被占。
                try JSONEncoder().encode(next).write(to: bookURL, options: .atomic)
                book = next
            }
        } catch {
            lastError = "外发失败:\(error)"
        }
    }

    private func filePath(for entry: LedgerEntry, day: String) -> String {
        if let block = entry.block {
            let url = RecordingPaths.audioDir(day: day, source: SessionSource.recording,
                                               root: root ?? RecordingPaths.root)
                .appendingPathComponent(block.fileName)
            return url.path.replacingOccurrences(of: docs.path + "/", with: "", options: .anchored)
        }
        return "outbox/msg-\(book.installID)-\(book.nextMsgSeq).json"
    }

    private func transfer(path: String, msg: WatchMessage) throws {
        let url = docs.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 账本里有、盘上没有。**说出来**:手机会卡在这个号上,而这里是唯一知道原因的地方。
            lastError = "第 \(msg.msgSeq) 条的文件不在了(\(path)),手机会卡在这一条"
            return
        }
        WCSession.default.transferFile(url, metadata: try WatchLink.metadata(msg))
    }

    /// 复用录音计时器检查到期，无须增加唤醒。自动重连和抬腕不绕过节流。
    func sendPendingIfDue(force: Bool = false) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              !book.inflight.isEmpty else { return }
        let now = Date()
        guard force || (book.batchDue(now: now) &&
            (lastBatchAttemptAt.map { now.timeIntervalSince($0) >= WatchLink.Book.batchInterval } ?? true))
        else { return }
        lastBatchAttemptAt = now
        do {
            book = try book.committingBatch(now: now) { next in
                try JSONEncoder().encode(next).write(to: bookURL, options: .atomic)
            }
        } catch {
            lastError = "同步时间尚未保存，原件仍保留：\(error)"
            return
        }
        let outstanding = Set(WCSession.default.outstandingFileTransfers.compactMap { transfer -> Int? in
            guard let msg = try? WatchLink.message(fromMetadata: transfer.file.metadata),
                  msg.installID == book.installID else { return nil }
            return msg.msgSeq
        })
        let again = book.needsResend(outstanding: outstanding)
        for item in again {
            do { try transfer(path: item.path, msg: item.message) }
            catch { lastError = "第 \(item.message.msgSeq) 条重发失败:\(error)" }
        }
        sendLiveIfPossible(items: book.inflight.values.sorted { $0.message.msgSeq < $1.message.msgSeq })
    }

    private func sendLiveIfPossible(items: [WatchLink.Book.Inflight]) {
        liveBatch.admit(items.filter { book.owns($0.message) })
        startLiveIfPossible()
    }

    private func startLiveIfPossible() {
        guard liveTask == nil, WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isReachable, !liveBatch.pending.isEmpty else { return }
        activelySyncing = true
        liveTask = Task { [weak self] in
            guard let self else { return }
            defer { self.liveTask = nil; self.activelySyncing = false; self.refresh() }
            // 同一外发账按序主动送；大文件仍在系统队列，不无限重复尝试。
            // 只接续已授权批次（包括结束的尾块），新落账未授权块仍留到下批。
            while WCSession.default.isReachable, let item = self.liveBatch.takeNext() {
                defer { self.liveBatch.finish() }
                guard self.book.owns(item.message) else { continue }
                do {
                    try await self.sendLive(item)
                    if self.book.owns(item.message), !WCSession.default.isReachable {
                        // 包与包之间断连会正常退出；保留本次授权，重连先接回缺号。
                        self.liveBatch.finish(retrying: item)
                        break
                    }
                }
                catch {
                    // 后台通道已成功时，迟到的即时错误不再覆盖成功状态。
                    if self.book.owns(item.message) {
                        self.lastError = "主动同步暂未完成，录音仍在后台队列：\(error)"
                        self.liveBatch.cancelWaiting()
                        break
                    }
                    continue
                }
            }
        }
    }

    private func sendLive(_ item: WatchLink.Book.Inflight) async throws {
        let url = docs.appendingPathComponent(item.path)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let count = size?.intValue, count > 0, count <= WatchLiveTransfer.maxFileBytes else { return }
        let header = WatchLiveTransfer.Header(message: item.message, totalBytes: count,
                                              sha256: try WatchLiveTransfer.digest(url))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            guard WCSession.default.isReachable,
                  book.inflight[item.message.msgSeq] != nil else { return }
            try handle.seek(toOffset: UInt64(offset))
            guard let bytes = try handle.read(upToCount: min(WatchLiveTransfer.chunkBytes, count - offset)),
                  !bytes.isEmpty else { throw WatchLiveTransfer.Failure.invalid("录音文件读取中断") }
            let packet = WatchLiveTransfer.Packet(header: header, offset: offset, bytes: bytes)
            let data = try WatchLiveTransfer.encode(packet)
            let returned: Data = try await withCheckedThrowingContinuation { continuation in
                WCSession.default.sendMessageData(data, replyHandler: { continuation.resume(returning: $0) },
                    errorHandler: { continuation.resume(throwing: $0) })
            }
            let receipt = try WatchLiveTransfer.receipt(from: returned, for: packet)
            offset = receipt.nextOffset
            if receipt.complete {
                // 手机整文件落盘成功；外发账持久提交后，才取消同号后台副本。
                guard book.owns(item.message) else { return }
                book = try book.committingDelivery(item.message) { next in
                    try JSONEncoder().encode(next).write(to: bookURL, options: .atomic)
                }
                for transfer in WCSession.default.outstandingFileTransfers {
                    if (try? WatchLink.message(fromMetadata: transfer.file.metadata).key) == item.message.key {
                        transfer.cancel()
                    }
                }
                if !item.message.isBlock { try? FileManager.default.removeItem(at: url) }
                lastError = nil
                refresh()
            }
        }
    }

    private func battery() -> Float? {
        let level = WKInterfaceDevice.current().batteryLevel
        return level < 0 ? nil : level
    }

    private func refresh() {
        linked = WCSession.isSupported() && WCSession.default.activationState == .activated
        reachable = linked && WCSession.default.isReachable
        inflightBlocks = book.inflightBlocks
    }

    private static func dayDirs(_ root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 删掉 3 天前的块音频 —— **还在途的不删**(送到之前删了,失败重发时就没东西可发了)。
    /// 账本留着(它小,而且是唯一的发货记录)。
    private func prune(root: URL) {
        let cutoff = BlockLedger.dayKey(Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400))
        let pinned = book.pinnedPaths
        let fm = FileManager.default
        for dir in Self.dayDirs(root) where dir.lastPathComponent < cutoff {
            let day = dir.lastPathComponent
            guard let entries = try? BlockLedger.read(from: dir.appendingPathComponent("ledger.jsonl")).entries,
                  book.sent(day: day) >= entries.count else { continue }
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where f.pathExtension == "m4a" {
                let url = RecordingPaths.audioDir(day: day, source: SessionSource.recording, root: root)
                    .appendingPathComponent(f.lastPathComponent)
                let path = url.path.replacingOccurrences(of: docs.path + "/", with: "", options: .anchored)
                guard !pinned.contains(path) else { continue }
                try? fm.removeItem(at: f)
            }
        }
    }
}

extension WatchOutbox: WCSessionDelegate {
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.retryPending() }
    }
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        DispatchQueue.main.async {
            if let error { self.lastError = "连不上手机:\(error.localizedDescription)" }
            if let root = self.root { self.flushAll(root: root, force: true) }
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer,
                             error: Error?) {
        let msg = try? WatchLink.message(fromMetadata: fileTransfer.file.metadata)
        let url = fileTransfer.file.fileURL
        let failure = error?.localizedDescription
        DispatchQueue.main.async {
            guard let msg else {
                self.lastError = "系统回报了一条认不出来的传输(\(url.lastPathComponent))"
                return
            }
            // 即时路径已确认并取消的后台副本，或旧安装遗留回调，不改变新外发账。
            guard self.book.owns(msg) else {
                self.refresh(); return
            }
            if let failure {
                // 留在外发账里，下个批次再补，不当场重发。
                self.lastError = "第 \(msg.msgSeq) 条没送到,稍后重发:\(failure)"
            } else {
                do {
                    self.book = try self.book.committingDelivery(msg) { next in
                        try JSONEncoder().encode(next).write(to: self.bookURL, options: .atomic)
                    }
                    self.lastError = nil
                    // 只有外发账提交成功后才删标记；块音频仍按原保留期管理。
                    if !msg.isBlock { try? FileManager.default.removeItem(at: url) }
                } catch {
                    self.lastError = "手机已收件，但外发记录尚未保存，原件仍保留：\(error)"
                }
            }
            self.refresh()
        }
    }
}

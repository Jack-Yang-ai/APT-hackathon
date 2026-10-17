import Foundation
import SwiftUI
import UserNotifications
import WatchKit

/// 手表上的录音(W1)。**录音本身就是手机那一份 `RecordingKernel`**,
/// 这里只做手机上 `RecordingViewModel` 做的那几件事:按天选目录、
/// 重开时补收尾、把回调接到界面与外发箱上。
///
/// 与手机最大的差别在「停了没人知道」:watchOS 后台被打断后多半接不回来,
/// 而 App 一旦被挂起,连看门狗定时器都不跑。所以提醒分两层(spec §二 3):
/// · **系统告诉我们的**(来电/Siri 打断、内核报错)—— 当场震动 + 通知;
/// · **系统不告诉我们的**(被挂起、被杀)—— 靠一条**预约好的**通知:录音期间每 10 秒
///   往后推一次,推不动了(进程没在跑)它就在 30 秒内自己弹出来。
@MainActor
final class WatchRecorder: ObservableObject {

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var sessionStartedAt: Date?
    @Published private(set) var notice: String?
    @Published private(set) var hasSpeech = false
    /// 通知权限没给。被打断时只剩震动,而手表不在前台时震动多半不播 —— 界面要常驻说出来。
    @Published private(set) var notificationsDenied = false

    let outbox = WatchOutbox()
    private var kernel: RecordingKernel
    private var sessionDir: URL
    private var meter: Timer?

    static let watchdogID = "growth.recording.watchdog"
    /// 预约通知在多久没被推后时弹出。
    static let watchdogFireAfter: TimeInterval = 30
    /// 录音期间多久推后一次。必须明显小于上面那个数,否则正常录着也会误弹。
    static let watchdogPushEvery: TimeInterval = 10

    static var recordingsRoot: URL {
        RecordingPaths.root
    }

    init() {
        let dir = RecordingPaths.audioDir(day: BlockLedger.dayKey(Date()),
                                          source: SessionSource.recording)
        sessionDir = dir
        kernel = RecordingKernel(sessionDir: dir, source: SessionSource.watch)
        wireKernel()
        sealAbandonedSessions()
        outbox.activate(root: Self.recordingsRoot)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.notificationsDenied = !granted
                if let error { self.notice = "通知权限请求失败:\(error.localizedDescription)" }
            }
        }
    }

    // MARK: - 用户操作

    func start() {
        rollDayIfNeeded()
        kernel.start()
    }
    func pause()  { kernel.pause() }
    func resume() { kernel.resume() }
    func stop()   { kernel.stop() }

    // MARK: - 接线

    /// 回调一律 `DispatchQueue.main.async`:它按提交顺序执行。
    /// 每次起一个 `Task` 不保证先后 —— 先到 `.stopped` 后到 `.pausedBySystem` 的话,
    /// 界面会停在「被打断」上,而「继续」按什么都不会发生。
    private func wireKernel() {
        kernel.onFailure = { [weak self] error in
            DispatchQueue.main.async { self?.report(error) }
        }
        kernel.onStateChange = { [weak self] newState in
            DispatchQueue.main.async { self?.apply(newState) }
        }
        // 切完一块就登记待传。约 15 分钟集中同步，账本仍先落盘。
        kernel.onBlockCut = { [weak self] in
            DispatchQueue.main.async { self?.flush() }
        }
        kernel.onAutoStopped = { [weak self] in
            DispatchQueue.main.async {
                self?.notice = "静音超过 \(AutoStopPolicy.silenceMs / 3_600_000) 小时,这一场自己收尾了。"
            }
        }
    }

    private func apply(_ newState: RecordingState) {
        let old = state
        state = newState
        if RecordingStateMachine.startsFresh(from: old, to: newState) {
            sessionStartedAt = Date()
            notice = nil
        }
        if newState == .stopped { sessionStartedAt = nil }
        // 系统打断 = 用户以为在录而其实停了。**当场说**,不等他抬手看。
        if newState == .pausedBySystem, old != .pausedBySystem {
            alert(title: "APT 没在录音",
                  body: "录音被打断了(来电、Siri 或别的 App 占了麦克风)。点开 APT 按「继续」。")
        }
        if newState == .recording { startMeter() } else { stopMeter() }
        // 每一次状态变化都可能在账本里多一行标记(开场/暂停/继续/中断/收尾)。
        flush(force: newState != .recording)
    }

    /// 内核报上来的错,按「这一场还在不在录」说不同的话。
    /// `audioRecovered` 是「断了一下、已经接上」,说成「没在录音」会让人去点一个不需要点的按钮。
    private func report(_ error: Error) {
        let text = String(describing: error)
        if state == .recording {
            alert(title: "录音断了一下", body: text)
        } else {
            alert(title: "APT 没在录音", body: text + "(点开 APT 重新开始)")
        }
    }

    private func flush(force: Bool = false) {
        outbox.flush(dayDir: sessionDir, force: force)
    }

    // MARK: - 在录期间的两件事:人声指示 + 推后预约通知

    private func startMeter() {
        guard meter == nil else { return }
        pushWatchdog()
        meter = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hasSpeech = self.kernel.energyGate.hasSpeechNow
                self.outbox.sendPendingIfDue()
                if Int(Date().timeIntervalSince1970) % Int(Self.watchdogPushEvery) == 0 {
                    self.pushWatchdog()
                }
            }
        }
    }

    /// 离开「在录」:人声点灭掉,预约通知撤掉(用户自己暂停/结束不该收到「没在录」)。
    /// 被系统打断时它也会被撤掉 —— 那一刻 `apply` 已经当场发了提醒,不需要它了。
    private func stopMeter() {
        meter?.invalidate(); meter = nil; hasSpeech = false
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.watchdogID])
    }

    private func pushWatchdog() {
        let content = UNMutableNotificationContent()
        content.title = "APT 可能没在录音"
        content.body = "手表上的 APT 有一会儿没动静了。点开看一眼,没在录就按「继续」或重新开始。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.watchdogFireAfter, repeats: false)
        // 同一个 identifier 会顶掉上一条 —— 这就是「往后推」。
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.watchdogID, content: content, trigger: trigger)
        ) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.notice = "预约提醒失败:\(error.localizedDescription)" }
        }
    }

    /// 震一下 + 发一条通知。App 在前台时通知不弹,所以震动不能省;
    /// 通知加不上要留在界面上 —— 那意味着后台被打断时**没有人会知道**。
    private func alert(title: String, body: String) {
        notice = body
        WKInterfaceDevice.current().play(.failure)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.notice = body + "(通知没发出去:\(error.localizedDescription))" }
        }
    }

    // MARK: - 跨天与重开(照手机 `RecordingViewModel` 的同名两件事)

    /// 不在录的时候把目录对到今天。正在录的不换:跨零点的场次留在开场日。
    private func rollDayIfNeeded() {
        guard state == .idle || state == .stopped else { return }
        let want = RecordingPaths.audioDir(day: BlockLedger.dayKey(Date()),
                                           source: SessionSource.recording)
        guard want != sessionDir else { return }
        sessionDir = want
        kernel = RecordingKernel(sessionDir: want, source: SessionSource.watch)
        wireKernel()
    }

    /// 手表 App 被杀之后重开:**每一天**的账本,最后一条不是收尾的都补一条收尾,并如实说空了多久。
    ///
    /// 🔴 必须扫所有天,不能只看今天(W1 对抗审查):22:00 开录、23:30 被杀、
    /// 次日才打开 —— 只看今天的话前一天那一场永远不收尾。手机那边不兜底手表场次
    /// (spec 决定 4),它会在首页一直显示「录音中」、永远不进处理队列。
    /// 收尾时刻取账本最后一条的时刻(与手机 `sealAbandonedSession` 同口径),不取「现在」。
    private func sealAbandonedSessions() {
        let days = ((try? FileManager.default.contentsOfDirectory(
            at: Self.recordingsRoot, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var notices: [String] = []
        for dir in days {
            let url = dir.appendingPathComponent("ledger.jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let report = try RecordingKernel.relaunchReport(sessionDir: dir)
                guard !report.cleanShutdown,
                      let last = try BlockLedger.read(from: url).entries.last else { continue }
                if let text = report.noticeText { notices.append(text) }
                try BlockLedger.append(LedgerEntry(at: last.at, mark: .sessionEnded), to: url)
            } catch {
                notices.append("\(dir.lastPathComponent) 那一场没能补上收尾:\(error)")
            }
        }
        notice = notices.isEmpty ? nil : notices.joined(separator: "\n")
    }
}

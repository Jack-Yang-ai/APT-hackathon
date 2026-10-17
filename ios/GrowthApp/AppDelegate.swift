import BackgroundTasks
import GRDB
import UIKit

/// 真后台的接线板(M1-4c)。
///
/// ## 为什么 SwiftUI App 还需要一个 AppDelegate
///
/// 两个回调只有 `UIApplicationDelegate` 有,SwiftUI 没有对应物:
///
/// · `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
///   —— App **被杀之后**、系统为了送传输回调把它冷启动起来时,走的就是这里。
///      那一刻没有界面、没有 ViewModel。
/// · `BGTaskScheduler.register` 必须在 `didFinishLaunching` **返回之前**调完,
///   晚一点系统就会拒绝(而且是崩溃,不是报错)。
///
/// ## 两条腿各管一半
///
/// | | 管什么 | 挺过什么 |
/// |---|---|---|
/// | 后台 `URLSession` | 长传输 | App 挂起、**被杀**、用户上滑关掉 |
/// | `BGProcessingTask` | 短活(提交 / 轮询 / 冻结 / 抽取) | App 挂起。**用户上滑强杀之后不再唤醒**(iOS 的设计) |
///
/// 所以两条都要:强杀之后靠传输回调把 App 拉起来,没强杀时靠 BGTask 定期推。
/// 而两条都不灵的时候还有第三条 —— 用户下次打开 App(`pumpProcessing`)。
/// **三条腿都只是「给它机会跑」,真正的进度在库里。**
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// ⚠️ 这个字符串必须同时出现在 `Info.plist` 的
    /// `BGTaskSchedulerPermittedIdentifiers` 里。**对不上不会报错**,
    /// 只是 `register` 返回 false、任务永远不跑 —— 一种完全静默的失效。
    static let processingTaskID = "com.growth.app.processing"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
                     = nil) -> Bool {
        // 手表收件处(W1)。放在库之前:它只落文件,库开不了也照样要接住手表传来的录音。
        WatchInbox.shared.activate()

        guard let db = AppDatabase.shared else {
            // 库开不了的话什么后台都没意义。界面那边会把原因显示出来
            // (`RecordingViewModel.databaseFailure`),这里不重复喊。
            return true
        }

        WatchInbox.shared.startProcessing(in: db)

        // Public distribution starts without bundled personal voiceprints.
        // Enrollment continues through the existing controlled registry entry.

        // ⚠️ 这里**不再传 config**:传的话就是启动那一刻的快照,而用户往往是
        // 启动之后才去设置页填的 —— 上传腿会在整个进程里一直以为「还没配」。
        // 配置由 `handOff` 在用的时候读。
        BackgroundUploadCenter.shared.start(writer: db)
        BackgroundUploadCenter.shared.onProgress = { [weak self] in
            self?.pump(trigger: .transferCallback)
        }

        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskID,
                                                 using: nil) { [weak self] task in
            self?.runProcessingTask(task as! BGProcessingTask)
        }
        if !ok {
            // 注册失败**说出来**。静默的话表现是「后台永远不跑」,
            // 而那和「后台跑了但没活干」在界面上一模一样。
            ProcessingEvents.record(trigger: .background,
                                    outcome: "BGTask 注册失败",
                                    detail: "Info.plist 的 BGTaskSchedulerPermittedIdentifiers "
                                          + "里有没有 \(Self.processingTaskID)?", in: db)
        }

        // 🔴 **进程刚起来:把上次没跑完就被打断的任务捡回来。**
        // `nextRunnable` 只捡 queued/retrying/waiting_network,所以一个停在
        // `running` 上的任务永远再也捡不起来 —— 而任务表看起来一切正常。
        // 放在这里(而不是每次 pump)是因为判据就是「进程刚起来」:
        // 那一刻按定义没有任何任务在跑。
        if let n = try? TaskQueue.reclaimInterrupted(
            now: ISO8601DateFormatter.growth.string(from: Date()), in: db), n > 0 {
            ProcessingEvents.record(trigger: .foreground,
                                    outcome: "捡回 \(n) 个上次没跑完的任务", in: db)
        }
        do {
            _ = try db.write { try AskStore.reclaimInterrupted(now: ISO8601DateFormatter.growth.string(from: Date()), in: $0) }
        } catch {
            ProcessingEvents.record(trigger: .foreground, outcome: "问答恢复失败", detail: "\(error)", in: db)
        }

        // 🔴 **同一条判据的另一半:把上次没收尾的场次收掉并入队。**
        // 崩在录音中的场次留着 `status='recording'` ⇒ 首页无条件显示「录音中」
        // (那个态压过一切),而入队只捞 `closed` ⇒ **永远没有人处理它**。
        // 当天再录一场有账本那条补救,但跨天之后账本不再被读 —— 就永久钉住了。
        if let ids = try? SessionBridge.closeAbandoned(in: db), !ids.isEmpty {
            let now = ISO8601DateFormatter.growth.string(from: Date())
            let queued = ids.filter {
                (try? ProcessingOrchestrator.enqueueSession($0, now: now, in: db)) == true
            }
            ProcessingEvents.record(
                trigger: .foreground,
                outcome: "收尾 \(ids.count) 场上次没结束的录音",
                detail: "其中 \(queued.count) 场新排进处理队列(其余早就排过了)。"
                      + "收尾时间取最后一个块的结束时刻 —— 那是最后一次有证据证明它还在录。",
                in: db)

            // 🔴 **正在写的那一块丢了,要说出来。**(2026-08-19)
            //
            // 进程被杀时那一块没写进账本,而**文件本身也读不出来** ——
            // MP4 的索引是关文件时才写的(拿真文件验过:`moov atom not found`)。
            // 在此之前它的表现是:这一场被判「一块音频都没有」→ 失败 → 移出记忆,
            // **音频没了、记录也没了,两边都不报错**。那正是 §3.2 点名的形态。
            //
            // 这里不认领、不删文件,只把损失摆到事件流里。
            for id in ids {
                let orphans = ProcessingPump.orphanBlockFiles(sessionID: id, ext: "m4a", in: db)
                guard !orphans.isEmpty else { continue }
                ProcessingEvents.record(
                    trigger: .foreground,
                    outcome: "场次 \(id) 有 \(orphans.count) 块音频在中断中损坏,内容取不回来",
                    detail: orphans.map { "\($0.name)(\($0.bytes / 1024) KB,没写完索引)" }
                        .joined(separator: " · ")
                        + "。文件留在盘上没删,但解不出音频 —— 录音进程是被杀掉的,"
                        + "MP4 的索引要关文件时才写。",
                    in: db)
            }
        }

        // 音频保留期(PRD §4.1.10:7 天)。**只删已经冻结的场次** ——
        // 还没转写完的那些,音频是唯一的原始材料。
        if let r = try? AudioRetention.sweep(in: db), r.filesDeleted > 0 || r.keptUnfinished > 0 {
            ProcessingEvents.record(
                trigger: .foreground,
                outcome: "过期音频清掉 \(r.filesDeleted) 块(\(r.bytesFreed / 1_048_576) MB)",
                // 留着的那个数要能看见:它一直不降就说明有场次卡住了,
                // 而卡住的场次会一直占着空间(去首页长按「再试一次」)。
                detail: "\(r.sessionsSwept) 场清完 · \(r.keptUnfinished) 场够老了但还没冻结,"
                      + "音频留着(它们是唯一的原始材料)。", in: db)
        }

        // 启动时对一次账:把「标着在传、系统那边已经没有」的块捡回来。
        Task { await BackgroundUploadCenter.shared.reconcile() }
        schedule()
        return true
    }

    /// App 被杀之后、系统为了送传输回调把它冷启动起来 —— 入口就是这里。
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploadCenter.sessionIdentifier else {
            // 不是我们的 session 也**必须调** completion,不然系统会一直等。
            completionHandler()
            return
        }
        BackgroundUploadCenter.shared.handleSystemWake(completion: completionHandler)
    }

    // MARK: - BGProcessingTask

    /// 排下一次唤醒。**每次跑完都要重排** —— BGTask 是一次性的,
    /// 不重排就只会被叫醒一次,而这条链常常要好几拍才走完。
    func schedule(earliestAfter: TimeInterval = 60) {
        let req = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        // 要联网:这条链每一步都在跟云代理说话,没网叫醒了也只是白耗一次配额。
        req.requiresNetworkConnectivity = true
        // **不要外接电源**。要的话实际只会在夜里充电时跑,
        // 而用户点完结束是希望十分钟内看到纪要的。
        req.requiresExternalPower = false
        req.earliestBeginDate = Date(timeIntervalSinceNow: earliestAfter)
        do { try BGTaskScheduler.shared.submit(req) }
        catch {
            if let db = AppDatabase.shared {
                ProcessingEvents.record(trigger: .background, outcome: "排后台唤醒失败",
                                        detail: "\(error)", in: db)
            }
        }
    }

    private func runProcessingTask(_ task: BGProcessingTask) {
        // 先把下一次排上。**放在最前面**是刻意的:后面任何一条 return
        // 都不会漏掉重排,而漏掉一次重排 = 后台从此再也不醒。
        schedule()

        guard let db = AppDatabase.shared else { return task.setTaskCompleted(success: false) }

        let work = Task {
            await ProcessingPump.run(trigger: .background, in: db)
            task.setTaskCompleted(success: true)
        }
        // 系统随时可能收回时间。**取消而不是硬跑完** —— 每一步都落盘,
        // 被打断只会退回上一步,而超时不主动结束会被系统记一笔并减少以后的配额。
        task.expirationHandler = {
            work.cancel()
            if let db = AppDatabase.shared {
                ProcessingEvents.record(trigger: .background, outcome: "后台时间用完,已落盘中断",
                                        in: db)
            }
            task.setTaskCompleted(success: false)
        }
    }

    private func pump(trigger: ProcessingEvents.Trigger) {
        guard let db = AppDatabase.shared else { return }
        Task { await ProcessingPump.run(trigger: trigger, in: db) }
    }
}

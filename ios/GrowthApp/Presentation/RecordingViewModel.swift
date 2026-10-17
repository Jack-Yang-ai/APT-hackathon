import Foundation
import GRDB
import SwiftUI

// 手机只负责接收、处理、回看与确认。本版采集只在Apple Watch,这里不创建录音内核。
// 旧手机账本仍同步到内容库,方便升级后继续回看与恢复未完成处理。
@MainActor
final class RecordingViewModel: ObservableObject {

    /// 重开 App 时那句如实的提示(PRD §4.1.3 异常表)。用户看过就消掉。
    @Published var relaunchNotice: String?
    /// 导入、维护等手机操作的失败必须可见。
    @Published var failure: String?
    /// 首页要渲染的一切。**全部来自 `HomeProjection.homeFeed`,界面层不自己查库** ——
    /// 界面自己拼一份就是第二个真相源,而两份迟早不一样。
    /// nil = 还没投影出来(库开不了的时候 `databaseFailure` 同时在喊)。
    @Published private(set) var feed: HomeFeed?

    /// 主库出问题时那句话。**与录音失败分开显示** —— 录音坏了是「这一场没了」,
    /// 库坏了是「录下来的东西进不了库」,用户该做的事完全不同。
    @Published var databaseFailure: String?
    @Published private(set) var watchNotice: String?
    @Published private(set) var watchSessionOpen = false
    @Published private(set) var watchRecordedSeconds: TimeInterval = 0

    private var sessionDir: URL

    /// 非 nil = 这个实例**钉死在这个目录上,不跟日历走**(测试用)。
    /// nil = 生产:刷新时按当前日期读取,见 `rollDayIfNeeded`。
    private let pinnedDir: URL?
    /// 取「现在」的方式。测试可以注入一个能跨零点的钟。
    private let clock: () -> Date

    /// 当前首页日期。生产随日历刷新,测试使用钉死的目录。
    /// Watch跨日场次仍归其原始账本日,由WatchMirror同步;未收尾查询覆盖所有日期。
    var todayKey: String { sessionDir.lastPathComponent }
    /// 主库。开不了就是 nil,而 `databaseFailure` 同时有值 ——
    /// **两个字段永远同时设置**,不存在「静悄悄的 nil」。
    private let dbQueue: DatabaseQueue?
    /// 给详情页读用。**只读不写** —— 所有写路径仍然只走这个类里的方法,
    /// 界面拿到句柄不等于界面可以写库。
    var database: DatabaseQueue? { dbQueue }
    private var _pumping = false
    /// - Parameter database: 传 nil 走默认路径开库;测试传自己的内存库。
    ///   开库失败**不抛**,而是把 App 起起来并把错误显示出来 ——
    ///   起不来的 App 什么都说不了,而这一刻最需要的恰恰是把原因告诉用户。
    /// - Parameter sessionDir: 传 nil(生产)= 跟日历走;传一个目录 = 钉死在它上面(测试)。
    init(sessionDir: URL? = nil,
         database: DatabaseQueue? = nil,
         clock: @escaping () -> Date = { Date() }) {
        self.pinnedDir = sessionDir
        self.clock = clock
        let dir = sessionDir ?? RecordingViewModel.defaultSessionDir(now: clock())
        self.sessionDir = dir

        var opened = database
        var openFailure: String?
        if opened == nil {
            // ⚠️ **走进程共享的那一个,不自己 `open()`。**
            // 自己开会在同一个文件上多出一个 `DatabaseQueue`,两边各自串行、
            // 彼此不知道 —— 而真后台之后这不再是理论问题:界面在前台写,
            // 后台传输的回调可能在同一时刻从另一个线程写 `upload_jobs`。
            switch AppDatabase.sharedResult {
            case .success(let q): opened = q
            case .failure(let e): openFailure = "主库打不开,今天录的东西进不了库:\(e)"
            }
        }
        self.dbQueue = opened
        self.databaseFailure = openFailure

        // ⚠️ **没有这一行,归属改完的连锁重算在生产里是空转的。**
        // `RecomputeRegistry` 原来只有测试调用 `resetToM0Defaults()`,App 启动路径上
        // 一处都没有 —— 于是 `fns` 为空、`run()` 返回 `[:]`、`AssignResult.recomputed`
        // 是空字典,而没有任何调用方检查它。用户确认完说话人,承诺与表态的挂起标记
        // **永远不翻**,纪要停在「归属未定」。判断照写、`line_speakers` 照更新、
        // 退出码全绿 —— 仓规 §3.2 点名的「成功地写进了错的地方」。
        // 测试全绿是因为测试自己补了注册。
        RecomputeRegistry.registerM0Defaults()

        refreshToday()
    }

    /// 手机不采集,首页日期直接跟当前日历翻篇。测试钉死的历史目录继续保留。
    private func rollDayIfNeeded() {
        guard pinnedDir == nil else { return }
        sessionDir = Self.defaultSessionDir(now: clock())
    }

    /// 默认落盘位置:Documents/recordings/<当天>。一天一场,与 `sessions.day` 同口径。
    /// `nonisolated`:它不碰任何 actor 状态,而 init 的默认参数是在非隔离上下文里求值的。
    nonisolated static func defaultSessionDir(now: Date = Date()) -> URL {
        RecordingPaths.audioDir(day: BlockLedger.dayKey(now), source: SessionSource.recording)
    }

    // MARK: - 处理编排(M1-4)

    /// 把今天所有场次排进处理队列 —— **包括还在录的那一场**。
    ///
    /// PRD §2.1(2026-08-12 拍板):**点结束即自动处理,不再问第二次**。
    /// 所以这里没有「用户点处理」这个动作 —— 收尾即入队。
    ///
    /// **幂等**:`enqueueSession` 自己查重。这里每次刷新都跑,不判断「是不是新的」——
    /// 靠调用方记「上次排到哪」迟早对不上,而对不上的后果是有一场永远没人处理。
    private func enqueueClosedSessions() throws {
        guard let dbQueue else { return }
        let day = sessionDir.lastPathComponent
        // 🔴 **不再只排 `closed`(2026-08-19)。**
        // 只排收尾的场次意味着整条链在结束前一步都不动。
        // 旧手机版08-18那场32分钟录音,7块早已落盘,上传却等结束才建。
        // 本版Watch边录边传,手机收到已完成块后仍应立即排队。
        // 安全性由下游两道闸保证,不靠这里挑场次:
        // ① 上传腿:还在录 ⇒ 传完已知块也不标done(后面的块还要传);
        // ② 转写腿:还在录 ⇒ 不许冻结(冻结不可回改,冻在半截就截断了这一场)。
        let ids = try dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM sessions WHERE day = ? AND removed_at IS NULL
                """, arguments: [day])
        }
        let now = ISO8601DateFormatter.growth.string(from: Date())
        for id in ids {
            // 排不进队抛给整轮刷新的调用方,不能被后续投影成功清除。
            try ProcessingOrchestrator.enqueueSession(id, now: now, in: dbQueue)
        }
    }

    /// 推一拍编排。**它自己决定该做哪一步** —— 这里只负责给它机会跑。
    ///
    /// 这是三条腿里的**前台那条**。另外两条(`BGProcessingTask` 唤醒、
    /// 后台传输回调)在 `AppDelegate` 里,三条都调同一个 `ProcessingPump` ——
    /// 各造一份依赖的话迟早会有一份忘了接某一步,而那种缺失只表现为
    /// 「某条腿跑到一半就不动了」,不报错。
    /// - Parameter releasingBackoff: 这一拍是不是**用户刚把 App 拿到眼前**。
    ///   是的话先把「正在重试」的任务放行 —— 打开 App 就是「我在等」,
    ///   而退避是给「没人看着」时用的。
    ///
    ///   ⚠️ **只在入口那两拍传 true**(界面出现、从后台回到前台),
    ///   前台那个 30 秒定时器不能传 —— 每 30 秒放行一次等于把退避整个取消掉,
    ///   上游真挂了的时候会被我们按住捶。
    /// 推一拍编排。
    ///
    /// 🔴 **`trigger` 不做参数,自己从真实的应用状态读**(M1-29)。
    /// 上一版三处都硬写 `.foreground`,而这个方法在**后台也会被调到**
    /// (录音在后台继续切块 → `onBlockCut`;界面还活着时那个 30 秒定时器照样响)。
    /// ⇒ 「用户打开了 App」与「进程被系统唤醒了一下」记成了同一个值。
    /// 给它开个参数只是把错误换个地方犯 —— **根因是调用方得自己记得传对**。
    func pumpProcessing(releasingBackoff: Bool = false) {
        guard let dbQueue, !isPumping else { return }
        let trigger = ProcessingEvents.currentTrigger
        isPumping = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.isPumping = false } }
            if releasingBackoff {
                do {
                    let n = try TaskQueue.releaseBackoff(in: dbQueue)
                    if n > 0 {
                        ProcessingEvents.record(
                            trigger: trigger,
                            outcome: (trigger == .foreground ? "打开 App" : "醒了一下")
                                   + ",放行 \(n) 个正在重试的任务",
                            in: dbQueue)
                    }
                } catch {
                    // §3.2:兜底的 catch 要么记录要么抛,不要 pass。
                    ProcessingEvents.record(trigger: trigger,
                                            outcome: "放行退避失败:\(error)", in: dbQueue)
                }
            }
            await ProcessingPump.run(trigger: trigger, in: dbQueue)
            await MainActor.run { self?.refreshToday() }
        }
    }

    private var isPumping: Bool {
        get { _pumping }
        set { _pumping = newValue }
    }

    // MARK: - 重开 App:如实提示空洞

    /// PRD §4.1.3:被回收后录音停止且系统**不会自动重启**,重开时按落盘块尾
    /// 时间戳如实提示「录音中断过 N 分钟」——**不假装「已继续」**。
    ///
    /// 重读今天的账本。开录/停录/启动各刷一次 —— 账本是唯一真相源,
    /// 界面**不自己累计**:自己记的话,进程被杀之后那几场就凭空消失了。
    func refreshToday() {
        // 界面上的「今天」也要跟着日历翻篇 —— 不翻的话首页整天显示昨天。
        rollDayIfNeeded()
        let url = sessionDir.appendingPathComponent("ledger.jsonl")
        // 🔴 **读不到账本 ≠ 今天没有内容。**
        //
        // 上一版这里是 `guard … else { today = []; return }` —— 早退,不投影。
        // 后果:**今天还没按过录音的那些天,首页整页是空的**。`feed` 恒为 nil,
        // 于是场次卡、提示条、「今天整理出几场」那一句全都不出现 ——
        // 而屏幕上看起来只是「今天还没有东西」,一个非常合理的样子。
        //
        // 账本只管录音那一半。导入进来的场次(§4.1.5)、昨天没跑完今天还在处理的,
        // 都只在库里有,账本上没有它们。
        //
        // ⚠️ 空账本走下去是安全的:`SessionBridge.sync([])` 是纯 no-op
        // (循环体一次都不进),所以早退**没有保护作用,只有遮蔽作用**。
        let sessions = (try? BlockLedger.read(from: url))
            .map { BlockLedger.sessions(entries: $0.entries) } ?? []
        syncToDatabase(sessions)
    }

    /// 账本 → `sessions` 表。**每次刷新都跑,不判断「是不是变了」** ——
    /// 幂等由数据库的唯一索引保证(迁移 v8),靠调用方自己记「上次同步到哪」
    /// 迟早对不上,而对不上的后果是重复的场次行一路污染下游。
    ///
    /// `day` 取目录名而不是从时间戳反推:账本一个目录一天,
    /// 反推会在跨零点那一场上把它算进第二天。
    private func syncToDatabase(_ sessions: [BlockLedger.SessionSummary]) {
        guard let dbQueue else { return }        // 开库失败时 databaseFailure 已经在喊了
        let day = sessionDir.lastPathComponent
        do {
            try SessionBridge.sync(sessions, day: day, in: dbQueue)
            try enqueueClosedSessions()
            // 同步完立刻投影。**放在同一个 do 里是刻意的** —— 表写进去了但投影炸了,
            // 界面会拿着上一次的 feed 继续渲染,那就是「看起来完全正常」。
            feed = try HomeProjection.homeFeed(day: day, banner: awayBanner(today: day),
                                               in: dbQueue)
            let watchDir = RecordingPaths.audioDir(day: day, source: SessionSource.watch)
            let watchLedger = watchDir.appendingPathComponent(AudioWipe.ledgerName)
            if FileManager.default.fileExists(atPath: watchLedger.path) {
                watchRecordedSeconds = try BlockLedger.read(from: watchLedger).entries.compactMap(\.block)
                    .reduce(0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
            } else { watchRecordedSeconds = 0 }
            watchNotice = WatchInbox.shared.notice
            watchSessionOpen = try dbQueue.read { d in
                try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE source = ? AND status = ?)",
                    arguments: [SessionSource.watch, SessionBridge.Status.open]) ?? false
            }
            databaseFailure = nil
        } catch {
            // 写不进去要说出来。悄悄跳过的话,界面照常显示今天录了几段,
            // 而库里一条都没有 —— 「成功地写进了错的地方」的近亲。
            databaseFailure = "录音已保留,但同步或排进处理队列失败:\(error)"
        }
    }

    // MARK: - 提示条

    /// 上次打开 App 是哪一天。**app 本地状态,不是内容也不是判断**,所以进
    /// `UserDefaults` 而不是主库(与 `ProxyClient` 把地址放这儿同一个道理)。
    private static let lastOpenedKey = "growth.lastOpenedDay"

    /// §4.2.2 提示条第 4 条「距上次打开 >3 天」。
    ///
    /// ⚠️ **四档里现在只做得出这一档。** 另外三档(有事被唤醒 / 有事出现新进展 /
    /// 有新发现未读)分别要 `matters` 与 `discoveries` 两张还不存在的表 ——
    /// 它们不是漏写,是缺数据源,建表时回到这里补。
    ///
    /// 🔴 **`banner` 在这个函数出现之前,生产里恒为 nil。** `homeFeed` 的 `banner`
    /// 参数默认 nil 而唯一的生产调用点不传它,于是 `BannerRow` 那段界面代码
    /// 从上线起一次都没渲染过 —— 与 `summaries` 参数踩过的是同一个坑
    /// (见 `HomeProjection.swift` 里那段注释),而这次连测试都没露头,
    /// 因为测试都自己传了值。
    private func awayBanner(today: String) -> HomeBanner? {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.lastOpenedKey)
        defaults.set(today, forKey: Self.lastOpenedKey)

        // 第一次打开没有「上次」。**不显示,不编一个** —— 装作离开了很久是假的。
        guard let previous, previous != today,
              let gap = PeopleProjection.daysBetween(previous, and: today), gap > 3
        else { return nil }

        let count = (try? dbQueue?.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE day > ? AND day <= ?",
                             arguments: [previous, today])
        }) ?? nil
        return .awayForDays(days: gap, sessionCount: count ?? 0)
    }

    /// 账本读不出来时**不静默跳过**:那说明上一场的记录坏了或丢了,
    /// 而「没有提示」会被当成「上次一切正常」,恰好是事实的反面。
    /// ⚠️ **一个进程只跑一次。**
    ///
    /// 它原来挂在 `HomeView` 的 `.task` 上,而 `AppShell` 用 `switch tab` 渲染三个 tab ——
    /// 切走再切回来是新身份,`.task` 会重跑。后果不是多算一次,是**把正在录的那一场封掉**:
    /// 下面 `sealAbandonedSession` 只看账本最后一条,不看在不在录。
    /// 封完之后剩下的块全落进一个再也不会被 close 的桶,用户按「结束」时什么都不写 ——
    /// **后半场从账本里消失,音频还在盘上。**
    private var relaunchChecked = false

    func checkRelaunchGap(now: Date = Date()) {
        guard !relaunchChecked else { return }
        relaunchChecked = true
        do {
            let entries = try BlockLedger.read(from: sessionDir.appendingPathComponent(AudioWipe.ledgerName)).entries
            // 手机不改写手表账本,即便错误配置把目录指向了watch也不补收尾。
            guard !entries.contains(where: { $0.source == SessionSource.watch }) else { return }
            let report = try BlockLedger.relaunchReport(entries: entries, now: now)
            relaunchNotice = Self.noticeText(for: report).map {
                "旧版手机录音：" + $0.replacingOccurrences(of: "当前未在录音,请重新开始。",
                                                    with: "请在手表上开始新的录音。")
            }
            // ⚠️ **顺序不能反**:先算提示,再收尾。收尾之后账本就是「正常结束」了,
            //    再算提示就什么都报不出来 —— 那正好是事实的反面。
            sealAbandonedSession(report)
        } catch LedgerError.emptyLedger {
            relaunchNotice = "上一场的录音记录是空的 —— 开始那条没写进去,这一场的情况无法判断。"
        } catch CocoaError.fileReadNoSuchFile {
            relaunchNotice = nil            // 没有上一场,正常
        } catch {
            relaunchNotice = "读不出上一场的录音记录(\(error))—— 不能据此说「一切正常」。"
        }
    }

    /// 上一次运行被杀掉时,账本里那一场**永远停在「开着」**。
    ///
    /// 后果在首页上是一句假话:那张卡会一直显示「记录中 · N 分」,而根本没有在录
    /// (2026-08-14 模拟器实拍抓到)。而按 PRD §4.1.3,**被回收后系统不会自动重启录音** ——
    /// 所以那一场事实上就是结束了,只是没人给它写收尾。这里补上。
    ///
    /// 收尾时间戳取**账本最后一条的时刻**,不是 `now`:用 `now` 等于声称
    /// 这中间一直在录,而那段恰恰是空洞。最后一条也保证不会破坏账本的时序校验。
    private func sealAbandonedSession(_ report: RelaunchReport) {
        guard !report.cleanShutdown else { return }
        // 本版手机不会开始采集,这里只修复升级前的旧手机账本。
        let url = sessionDir.appendingPathComponent("ledger.jsonl")
        guard let (entries, _) = try? BlockLedger.read(from: url),
              let last = entries.last,
              last.kind != SessionMark.sessionEnded.rawValue else { return }
        do {
            try BlockLedger.append(LedgerEntry(at: last.at, mark: .sessionEnded), to: url)
            refreshToday()      // 账本变了,库与首页要跟着变
        } catch {
            // 补不上要说出来。悄悄跳过的话首页会一直挂着那句「记录中」,
            // 而没有任何地方记下「我们知道它是错的」。
            failure = "上一场没能补上收尾,首页可能仍显示它在录:\(error)"
        }
    }

    /// 文案在 `RelaunchReport.noticeText`(手表也用,只此一份)。
    static func noticeText(for r: RelaunchReport) -> String? { r.noticeText }

    /// 时长文案。超过一小时要显示小时位 —— 全时录音一天 8 小时,
    /// 只显示分秒的话到下午就变成「487:12」,读不出来。
    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
    // MARK: - 场次维护(§4.2 长按菜单)

    /// 拿已存的转写报文重拼时间轴,落成新的一版。**零花费** ——
    /// `asr_jobs.result_json` 存的是原始报文,不需要重新提交。
    func refreeze(sessionID: Int64) async {
        guard let db = database else { return }
        let now = ISO8601DateFormatter.growth.string(from: Date())
        do {
            let r = try SessionMaintenance.refreeze(sessionID: sessionID, now: now, in: db)
            relaunchNotice = "重整好了:v\(r.version) · \(r.lines) 行。纪要要重新出一份。"
        } catch {
            // 失败要说原因 —— 「没成功」让用户无从判断是重试还是放弃
            relaunchNotice = "重整没成:\(error)"
        }
        refreshToday()
    }

    /// 时间轴体检报出来的那几场,**一次全重整**(M1-13b-1)。**零花费的那一半** ——
    /// 重整本身不重新提交转写;但新版的纪要要重新抽,那一步是花钱的
    /// (见 `SessionMaintenance.refreeze` 的注释),所以调用方要把这句话说给用户听。
    ///
    /// ⚠️ **这里不设 `relaunchNotice`,和上面那个 `refreeze` 不一样 ——
    /// 前提写在一起(仓规 6):** `relaunchNotice` 画在 `RecordingNotices` 里,
    /// 而那个视图只在**首页**;这个入口在设置页(从「人」那一屏推进去的),
    /// 塞进去的话用户点完什么都看不见,要等他退回首页才冒出来一句
    /// 「修好了 3 场」—— 那时他早忘了自己点过什么。
    /// 所以结果**返回给调用方**,由设置页当场画出来。
    /// 🔴 哪天体检入口挪到首页,这段话就作废,改回照抄 `refreeze` 的形状。
    func repairTimelines(_ findings: [TimelineAudit.Finding]) async
        -> (fixed: [Int64], failed: [(Int64, String)]) {
        guard let db = database else { return ([], []) }
        let now = ISO8601DateFormatter.growth.string(from: Date())
        let r = TimelineAudit.repair(findings, now: now, in: db)
        // 时长在首页卡上取的就是转写行的最大 `t_end_ms`(见 `HomeProjection`),
        // 所以重整之后首页那几张卡的分钟数会跟着变 —— 得重投一次。
        refreshToday()
        return r
    }

    /// 「再试一次」:把 dead / degraded 的任务打回可跑(M1-13d)。
    ///
    /// ⚠️ **会花钱** —— 没转出来的块要重新提交。调用方负责在二次确认里说清楚。
    func reidentifyActions(_ sessionID: Int64) throws {
        guard let db = database else { throw ContinuousIngestion.Failure.invalid("主库尚未打开") }
        try ActionCandidateStore.requestReassessment(sessionID, now: ISO8601DateFormatter.growth.string(from: Date()), in: db)
        refreshToday()
        pumpProcessing()
    }

    func retrySession(_ sessionID: Int64) async {
        guard let db = database else { return }
        let now = ISO8601DateFormatter.growth.string(from: Date())
        do {
            let r = try ProcessingOrchestrator.retrySession(sessionID, now: now, in: db)
            // 0 个也要说话 —— 不说的话用户按了没反应,只会再按几次。
            switch (r.tasks, r.released) {
            case (0, 0):
                relaunchNotice = "这一场没有卡住的任务。"
            case (0, let n):
                // 以前这里说的是「它还在自己重试,再等等」—— 而「再等等」
                // 可能是六个小时。现在按下去真的会立刻再试一次。
                relaunchNotice = "放行了 \(n) 个正在重试的任务,马上再试一次。"
            default:
                relaunchNotice = "重新排上了:\(r.tasks) 个任务 · \(r.resubmittedBlocks) 块要重新转写。"
                    + (r.released > 0 ? " 另放行 \(r.released) 个正在重试的。" : "")
            }
        } catch {
            relaunchNotice = "重试没排上:\(error)"
        }
        refreshToday()
        // 🔴 **放行完要当场推一拍。** 只放行不推的话,最快也要等前台那个
        // 30 秒定时器 —— 而用户刚按下的按钮上写着「再试一次」,
        // 「排上了但什么都没发生」和「没排上」在屏幕上长得一模一样。
        pumpProcessing()
    }

    /// 「对这一场重新认人」(S5.5)。**纯本地、零成本** ——
    /// 不上云、不花钱,判决全在机器上跑完。
    ///
    /// 它是这条链上性价比最高的一个入口:底库里新进一个人之后,
    /// 上一次判成拒识的簇现在可能认得出来,而**没有这个入口就只能等下一场**。
    ///
    /// ⚠️ 用户确认过的行不会被改(闸在 `assignSpeaker` 里),所以这一步
    /// **不需要二次确认** —— 它推翻的只是机器自己上次的判断。
    func rematchSpeakers(sessionID: Int64) async {
        guard let db = database else { return }
        // 🔴 2026-08-24 起**判决只在 Mac**(M2-认8,方案 §3.1 单执行方)——
        // 这里不再本地跑 VoiceprintChain,改成强制重排队。诚实地说清语义:
        // 点了不等于马上有结果,Mac 判完下一拍自动合并;Mac 挂了就一直等
        // (它挂没挂在 Mac 上 `sh scripts/daemons.sh status` 一眼可见)。
        relaunchNotice = "已把这一场重新排给 Mac 判 —— 判完会自动更新,不用守着。"
        do {
            try await VoiceprintRemote.requeue(sessionID: sessionID, force: true, in: db)
            // trigger 算出来的,不写死 —— 这两个入口虽由用户点击触发,
            // 但源码闸(TriggerTruthTests)对本文件的 pump 调用一律要求真值。
            _ = await ProcessingPump.run(trigger: ProcessingEvents.currentTrigger, in: db)
        } catch {
            relaunchNotice = "没能排进队列:\(error)"
        }
        refreshToday()
    }

    /// 用户确认之后,把那些行的语音**回流进底库**(`M2-认1`)。
    ///
    /// 🔴 **它是把闭环接上的那一步。** 在此之前用户确认只改归属,底库一条不长 ——
    /// 于是下一场同一个人还是认不出,还是问你(实测 2026-08-20:四簇全拒识,
    /// 最高分 0.618 差阈值 0.640 一点点,而底库全是另一个采集域的种子)。
    ///
    /// ⚠️ **fail-open,但留痕。** 归属在调用这里之前就已经落库了,enroll 失败不该
    /// 让「记下了」这句话变成假的;但**不许静默** —— 悄悄没 enroll 的表现
    /// 就是「下一场还是认不出」,而那正是这条要修的东西。
    func enrollFromConfirmation(personID: Int64, lineIDs: [Int64]) async {
        guard let db = database, !lineIDs.isEmpty else { return }
        do {
            let out = try await VoiceprintEnroll.fromConfirmed(
                personID: personID, lineIDs: lineIDs,
                now: ISO8601DateFormatter.growth.string(from: Date()),
                embedder: try RedimnetBody(), vad: try SileroVAD(),
                trigger: .foreground, in: db)   // 用户当面点,这里是真值
            guard out.enrolled > 0 else { return }
            relaunchNotice = "记住了你的声音:\(out.enrolled) 段进了底库,正在把以前的场次重认一遍…"
            // 🔴 **底库刚变了就立刻推快照**(`M2-认8` ④b)。
            // 判决在 Mac,而 Mac 读的是 R2 上那份**只读快照** —— 不推的话
            // 这次 enroll 对判决**一点用都没有**,而用户看到的是「记住了」。
            // ⚠️ 失败不吞:悄悄没推的表现是「下一场还是认不出」,
            // 与「enroll 没成功」长得一模一样,而两者的修法完全不同。
            do {
                if let key = try RemoteSnapshotStore.pushIfNeeded(force: true, in: db) {
                    ProcessingEvents.record(trigger: .foreground, outcome: "底库快照已推",
                                            detail: key, in: db)
                }
            } catch {
                ProcessingEvents.record(
                    trigger: .foreground, outcome: "底库快照没推上去 —— Mac 判不了新登记的人",
                    detail: "\(error)", in: db)
            }
            // 🔴 **底库刚长了就得回头重认一遍,否则用户看不到任何变化。**
            // 不重认的话,这次确认的收益要等**下一场录音**才显形 —— 而用户刚做完
            // 一个动作,屏幕上什么都没变,与「没生效」一模一样。
            // ⚠️ 只重认**还有簇没身份**的场次:已经全认出来的重跑一遍是纯浪费
            //(每一场都要解码音频),而浪费的表现是「点完卡住半分钟」。
            let out2 = await rematchEverythingUnidentified()
            // ⚠️ 判决在 Mac(M2-认8):这里只知道排了几场,认出几个要等 Mac 判完
            // 自动合并 —— 别编一个「新认出 N 个」,那个数此刻还不存在。
            relaunchNotice = "记住了你的声音(\(out.enrolled) 段)。"
                + "\(out2.sessions) 场已重新排给 Mac 判,判完自动更新。"
        } catch {
            ProcessingEvents.record(trigger: .foreground,
                                    outcome: "底库:确认没能回流",
                                    detail: "人 \(personID):\(error)", in: db)
        }
    }

    /// 把**还有簇没身份**的场次全部重认一遍。底库刚长过之后调。
    ///
    /// ⚠️ **不是「所有场次」** —— 已经认全的场次重跑是纯浪费(每场都要解码音频),
    /// 而那份浪费的表现是用户点完之后卡住不动。
    ///
    /// ⚠️ 单场失败不打断整批:一场解不开音频不该让后面几十场都不重认。
    /// ⚠️ 返回的 `matched` 自 M2-认8 起恒为 0:判决在 Mac,排队时不知道结果。
    /// 留着这个位置只为不连锁改调用方;别再引用它当真值。
    func rematchEverythingUnidentified() async -> (sessions: Int, matched: Int) {
        guard let db = database else { return (0, 0) }
        let targets: [Int64] = (try? await db.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT DISTINCT t.session_id
                  FROM line_speakers ls
                  JOIN transcript_lines l ON l.line_id = ls.line_id
                  JOIN transcripts      t ON t.id = l.transcript_id
                 WHERE ls.person_id IS NULL AND ls.cluster_tag IS NOT NULL
                 ORDER BY t.session_id DESC
                """)
        }) ?? []
        guard !targets.isEmpty else { return (0, 0) }
        // 🔴 2026-08-24 起判决只在 Mac(M2-认8):enroll 之后的重判改成
        // 逐场强制重排队。**不再本地 rerun** —— 那条路会把已聚好的自动归属行
        // 重新判决,刚 enroll 的人模板少,重判可能把聚好的行改回拒识(审计 F)。
        var done = 0
        for sessionID in targets {
            do {
                try await VoiceprintRemote.requeue(sessionID: sessionID, force: true, in: db)
                done += 1
            } catch {
                ProcessingEvents.record(trigger: .foreground, outcome: "重认:这一场没排上",
                                        detail: "场次 \(sessionID):\(error)", in: db)
            }
        }
        if done > 0 { _ = await ProcessingPump.run(trigger: ProcessingEvents.currentTrigger, in: db) }
        refreshToday()
        return (done, 0)
    }

    /// 移出记忆(§3.1.7:墓碑,不物理删)。**撤不回来**,调用方负责二次确认。
    ///
    /// ⚠️ **走 `MemoryRemoval`,不自己写 UPDATE。** 我 2026-08-17 第一版在
    /// `SessionMaintenance` 里另写了一份 redact,而这条通道早就在那儿了 ——
    /// 那就是第二个写方。差别不是风格:`MemoryRemoval` 删完音频会**回读一次**,
    /// 只要还有文件在就抛;我那份用的是 `try?`,「以为删了其实没删」会被静默计成成功,
    /// 而那是隐私上最贵的一种失败。
    func deleteSession(_ sessionID: Int64) async {
        guard let db = database else { return }
        do {
            let audio = ProcessingPump.blocks(of: sessionID, ext: "m4a", in: db).map(\.fileURL)
            let r = try MemoryRemoval.removeSession(sessionID, audioFiles: audio, in: db)
            ProcessingEvents.record(
                trigger: .foreground, outcome: "场次 \(sessionID) 移出记忆",
                detail: "\(r.redactedLines) 行置墓碑 · \(r.deletedAudioFiles) 个音频文件删除。"
                      + "行本身留着,引用它们的判断不会悬空。", in: db)
            // 🔴 **云端那一半还没做完之前,不许说「删掉了」**(`M2-审12`)。
            // 界面承诺的是「音频、逐字稿、纪要、归属都会删掉」,而云上那份要联网才删得掉 ——
            // 用户按删的这一刻可能没网。泵会一拍一拍地补(`purgeCloudCopies`),
            // 但**在它落 `cloud_purged_at` 之前,这句话必须如实说出「云端还在删」**。
            // 没配云代理 ⇒ 本来就没往云上传过 ⇒ 不提云端,免得凭空吓人。
            let local = "\(r.deletedAudioFiles) 个音频文件已删 · \(r.redactedLines) 行置墓碑"
            relaunchNotice = ProxySettings.config == nil
                ? "移出记忆了:\(local)。"
                : "移出记忆了:\(local)。云端副本正在删,删完之前它还在 —— "
                  + "联网后会自动重试,设置页的事件流里能看到结果。"
        } catch {
            relaunchNotice = "没删掉:\(error)"
        }
        refreshToday()
    }

}

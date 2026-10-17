import Foundation
import GRDB
#if canImport(UIKit)
import UIKit
#endif

/// 「给编排一个跑的机会」(M1-4c)。**三条腿共用这一个入口。**
///
/// | 谁调 | 什么时候 |
/// |---|---|
/// | `RecordingViewModel.pumpProcessing` | 用户开着 App |
/// | `AppDelegate.runProcessingTask` | `BGProcessingTask` 把 App 叫醒 |
/// | `BackgroundUploadCenter.onProgress` | 后台传输回调(可能是冷启动的进程) |
///
/// ## 为什么依赖在这里造,不在 ViewModel 里
///
/// 后两条腿**没有 ViewModel** —— 回调可能发生在系统为送回调而冷启动的进程里,
/// 那时没有界面。依赖留在 ViewModel 里的话,后台那两条腿就得各造一份,
/// 而三份依赖迟早不一样(比如某一份忘了接抽取)。
enum ProcessingPump {

    /// 一次最多推几步。**不设上限的话,一个反复失败的任务能把这里变成死循环** ——
    /// 而在后台那条腿上,死循环会把系统给的时间耗光并被记一笔。
    static let maxSteps = 12

    /// 🔴 **同一时刻只许一个 pump 在推。**
    ///
    /// 三条腿(前台 / BGTask / 传输回调)都会调 `run`,而传输回调是**每块一次** ——
    /// 4 块传完就是 4 次几乎同时的调用。2026-08-17 真机实测:事件表里同一秒
    /// 5 条一模一样的「某场次 传完 4 块」,说明它们看到的是同一份状态、
    /// 各跑各的。
    ///
    /// 后果不只是噪声,是**可能花两次钱**:`runTranscribe` 里
    /// 「查有没有提交过 → 提交 → 落 `asr_jobs`」不是一个原子操作,
    /// 两个 pump 会双双查到「没提交过」,然后各提交一次。
    /// 去重表在**花钱之后**才写,挡不住并发。
    ///
    /// 也是 `TaskQueue.reclaimInterrupted` 的前提:那一步靠「进程刚起来时
    /// 没有任务在跑」这个判据,而并发 pump 会让这句话不成立。
    ///
    /// ⚠️ 残留风险(没修,记在这里):**提交成功之后、写 `asr_jobs` 之前**
    /// App 被杀,那一笔钱花了但没留痕,下次会再提交一次。窗口约两秒、
    /// 要正好撞上进程被杀。要堵死它得先落一条「提交中」再发请求,
    /// 而那需要 `remote_id` 可空 + 一个说不清怎么收场的中间态
    /// (拿不到 task_id 就既查不了也退不了)。现在不值得。
    private static let gate = PumpGate()

    private actor PumpGate {
        private var running = false
        /// 拿到锁返回 true;已经有人在推就返回 false,**直接放弃这一次** ——
        /// 排队等没有意义:在跑的那个会把队列推到底,等它跑完再推一遍
        /// 只是重复劳动。
        func tryEnter() -> Bool {
            guard !running else { return false }
            running = true
            return true
        }
        func leave() { running = false }
    }

    /// 推到没有可跑的任务为止,并**记一条事件**。
    ///
    /// 事件是这件事唯一可验的痕迹:界面上「出稿了」分不清是后台干的
    /// 还是刚打开才干的,而「凌晨 3:14 · 后台唤醒 · 冻结了 1 场」分得清。
    @discardableResult
    static func run(trigger: ProcessingEvents.Trigger, now: Date = Date(),
                    in db: DatabaseQueue) async -> [ProcessingOrchestrator.Outcome] {
        // 已经有人在推就直接走 —— 见 `gate` 的注释:并发推同一个队列会花两次钱。
        guard await gate.tryEnter() else { return [] }
        await WatchInbox.shared.processPending()
        // 🔴 **拿到锁了 ⇒ 此刻没有别的一拍在跑 ⇒ 还挂着 `running` 的都是孤儿。**
        //
        // 置 `running` 的只有 `ProcessingOrchestrator.tick` 两处,而 tick 只在这把锁
        // 里面跑 ⇒ 「拿到锁的这一刻还有 `running`」只有一种解释:**上一拍没收尾**
        // (被切走 / 进程被杀 / 抛穿了)。
        //
        // 在此之前这件事只在 `didFinishLaunching` 里做一次。真机某场次 的
        // `transcribe` 因此**在 `running` 上躺了四天**:App 一直被系统留在后台、
        // 没冷启动过 ⇒ 那条补救一次都没跑;而 `retrySession`/`releaseBackoff`
        // 都不碰 `running` ⇒ **用户没有任何可达的补救手段**,首页永远「整理中」。
        //
        // ⚠️ **只捡 `running`,不碰 `uploading`** —— 后台 URLSession 在没有任何一拍
        // 在跑的时候照样在传,把它打回 `queued` 会让一个正在成功上传的块重新排队,
        // 而重传是花钱的。`uploading` 仍然只在启动那次捡。
        if let n = try? TaskQueue.reclaimInterrupted(
            states: ["running"],
            now: ISO8601DateFormatter.growth.string(from: now), in: db), n > 0 {
            ProcessingEvents.record(trigger: trigger,
                                    outcome: "捡回 \(n) 个上一拍没收尾的任务",
                                    detail: "它们停在 `running`,而 `nextRunnable` 不捡这个态 —— "
                                          + "不捡回来就永远是「整理中」。", in: db)
        }
        do {
            let n = try ASRJobStore.recoverEmptyRecognitions(
                now: ISO8601DateFormatter.growth.string(from: now), in: db)
            if n > 0 {
                ProcessingEvents.record(trigger: trigger, outcome: "恢复 \(n) 个已完成的空转写分片",
                    detail: "复用已保存的转写结果，后续分片继续接入；没有重新付费转写。", in: db)
            }
        } catch {
            ProcessingEvents.record(trigger: trigger, outcome: "空转写状态恢复失败",
                                    detail: "\(error)", in: db)
        }
        // 🔴 **要一份「切走之后再跑一会儿」的宽限(M1-33)。**
        //
        // 2026-08-19 真机抓到:轮询失败 `NSURLError -999 "cancelled"、等了 0.0 秒` ——
        // 前台起的泵跑到一半,用户把 App 切走,**在途请求当场全被系统取消**。
        // 表现是最阴的那种:任务表转成 retrying、退避越排越远,而界面上只有「整理中」。
        // 拿了这份断言,切走后系统再给约 30 秒把这一拍跑完;到期回调里只收断言,
        // 泵自己的 maxSteps 与任务退避负责收敛,这里不抢它们的活。
        let endAssertion = beginBackgroundGrace()
        defer { endAssertion() }
        // ⚠️ **不能用 `defer { Task { await gate.leave() } }`。**
        // 那是**异步**释放:锁可能在下一次 pump 开始时还没放掉,于是后面的推
        // 全被当成「已经有人在推」丢掉 —— 比并发更糟,处理会直接停摆。
        // 自测抓到的:连推两次,第二次拿到空结果。
        let outcomes = await pump(trigger: trigger, now: now, in: db)
        await gate.leave()
        // 录音链已完成才给输入来源一个独立机会；不等待网络，也不占录音后台宽限。
        await InputMemorySourceSync.shared.scheduleBackground(in: db, config: ProxySettings.config, trigger: trigger)
        await RecordingMemorySync.shared.schedule(in: db, config: ProxySettings.config, trigger: trigger)
        return outcomes
    }

    /// 见 `run` 里那段注释。UIKit 不在(测试进程之外的宿主)就什么都不做。
    private static func beginBackgroundGrace() -> () -> Void {
        #if canImport(UIKit)
        // beginBackgroundTask 文档明说线程安全,这里可能在任意执行器上。
        final class Box: @unchecked Sendable { var id: UIBackgroundTaskIdentifier = .invalid }
        let box = Box()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "processing-pump") {
            if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id); box.id = .invalid }
        }
        return {
            if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id); box.id = .invalid }
        }
        #else
        return {}
        #endif
    }

    private static func pump(trigger: ProcessingEvents.Trigger, now: Date,
                             in db: DatabaseQueue) async -> [ProcessingOrchestrator.Outcome] {
        // 🔴 **这一拍是谁叫起来的,只有这里知道 —— 所以从这里往下灌。**
        // 下游(上传腿的 `handOff`、冻结腿的 `assemble` / `writeClusterTags`)
        // 都会往 `processing_events` 记事件,而它们此前一律写死「前台」。
        // 那些代码路径在 `BGProcessingTask` 唤醒下同样会走 ⇒ 事件表里
        // 一半诚实一半不诚实,而读的人分不出来 —— 比整张表都不诚实更糟。
        let deps = dependencies(in: db, trigger: trigger)
        var outcomes: [ProcessingOrchestrator.Outcome] = []
        for _ in 0..<maxSteps {
            if Task.isCancelled { break }
            // 🔴 **抛出必须留痕。** 上一版是 `try?` + `break` ——
            // 抛出时 `outcomes` 为空 ⇒ 下面那段事件记录整个被跳过 ⇒
            // **连库里都没有痕迹**:处理停了,而设置页的事件流里什么都没发生过。
            // 那是本仓 §3.2 点名的形态,只不过反过来:不是「成功地写进了错的地方」,
            // 是「失败了而任何地方都没写」。
            do {
                let o = try await ProcessingOrchestrator.tick(now: Date(), deps: deps, in: db)
                outcomes.append(o)
                if o == .idle { break }
            } catch {
                outcomes.append(.failed(sessionID: nil, error: "\(error)"))
                break
            }
        }
        // 🔴 ~~认人:冻结之后在端侧跑(M1-9b)~~ **2026-08-24 断开(M2-认8 ③,
        // 方案 §3.1 单执行方)**:判决挪到 Mac,这里不再调 `VoiceprintChain`。
        // 认人现在是一种任务(`Kind.voiceprint`,冻结时排队),由 tick 走
        // 「排队 → 取回 → 合并」—— 断开与 Mac daemon 上线在同一个提交,
        // 中间没有两份判决并行写库的窗口。

        // 🔴 **把「移出记忆」在云上那一半补完(`M2-审12`)。**
        //
        // 界面承诺的是「音频、逐字稿、纪要、归属都会删掉」,而删云端要联网 ——
        // 用户按删的那一刻可能没网。所以删这件事**不在按钮里做完**:
        // 按钮只管本地(不能因为没网就不让删),云端那半挂在这里,
        // 没删成的场次每一拍都会被重新捡起来,直到 `cloud_purged_at` 落上。
        //
        // ⚠️ **fail-open,但不静默**:删不掉不影响别的处理,但要记事件 ——
        // 「以为删了其实没删」在隐私上是最贵的一种静默失败。
        await purgeCloudCopies(trigger: trigger, now: now, db: db)
        // 🔴 **兜住「enroll 那次没推成」**(`M2-认8` ④b)。enroll 之后会立刻推一次,
        // 而那一次可能没网。一天一次的定时推让「Mac 读的底库」最多落后一天,
        // 而不是**永远落后**(实测过的形态:R2 上 0 个快照,而两端都不报错)。
        do {
            if let key = try RemoteSnapshotStore.pushIfNeeded(force: false, now: now, in: db) {
                ProcessingEvents.record(trigger: trigger, outcome: "底库快照已推(定时)",
                                        detail: key, in: db)
            }
        } catch {
            ProcessingEvents.record(trigger: trigger,
                                    outcome: "底库快照没推上去 —— Mac 读到的底库会一直是旧的",
                                    detail: "\(error)", in: db)
        }

        // `.idle` 不记 —— 一天几十次「没事干」会把这张表淹掉,
        // 而它的用途恰恰是「最近真的发生了什么」。
        let real = outcomes.filter { $0 != .idle }
        if !real.isEmpty {
            ProcessingEvents.record(trigger: trigger, outcome: summarize(real),
                                    detail: real.map(describe).joined(separator: " · "),
                                    at: now, in: db)
            // ⚠️ **这里刻意不发 App 外推送。**
            // `PRD.md §4.1.8` [拍板 2026-08-12]:**M1 完全不做 App 外推送**,
            // 出稿与失败合成**首页头部一句话** —— 理由是单用户自用、每天主动打开的
            // 产品,推送收益很低而打扰成本实打实,而且这样 M1 完全不碰通知权限,
            // 也就没有「拒绝后怎么办」这条分支。
            //
            // 🔴 2026-08-17 我在这里加过 `UNUserNotificationCenter`,**加错了** ——
            // 恰好把那条被省掉的分支又装了回来。留这段注释是为了让下一个人
            // 在动手之前先看见那条拍板(出稿/失败那句话在 `HomeFeed.banner`)。
        }
        return outcomes
    }

    /// 把已经「移出记忆」但云上副本还在的场次补删掉。
    ///
    /// 🔴 **只有云端回读确认空了才落 `cloud_purged_at`**(`ProxyClient.purgeSession`
    /// 在云端返 500 时抛)。落早了等于把「还没删干净」写成「删干净了」,
    /// 而这一列存在的全部理由就是让这件事**查得出来**。
    ///
    /// ⚠️ 没配云代理时**什么都不做,也不落标记** —— 不落是对的:
    /// 这一场可能是在配过代理的时候传上去的,标成「已清除」就是替它撒谎。
    static func purgeCloudCopies(trigger: ProcessingEvents.Trigger,
                                 now: Date, db: DatabaseQueue) async {
        guard let config = ProxySettings.config else { return }
        let pending = (try? await db.read { try MemoryRemoval.pendingCloudPurge(in: $0) }) ?? []
        guard !pending.isEmpty else { return }

        var done = 0
        var failures: [String] = []
        for sessionID in pending {
            do {
                let keys = try await db.read { try MemoryRemoval.cloudKeys(of: sessionID, in: $0) }
                try await ProxyClient.purgeSession(sessionID: sessionID,
                                                   transcripts: keys.transcripts,
                                                   tasks: keys.tasks, config: config)
                try MemoryRemoval.markCloudPurged(
                    sessionID, at: ISO8601DateFormatter.growth.string(from: now), in: db)
                done += 1
            } catch {
                failures.append("场次 \(sessionID):\(error)")
            }
        }
        ProcessingEvents.record(
            trigger: trigger,
            outcome: failures.isEmpty
                ? "云端副本清除:\(done) 场"
                : "云端副本清除:\(done) 场成功 · \(failures.count) 场没删掉",
            detail: failures.isEmpty
                ? "这些场次的音频、ASR 报文、抽取产物都已从云端删除并回读确认。"
                : "⚠️ 没删掉的场次**云端仍有副本**,下一拍会再试:"
                  + failures.joined(separator: " · "),
            at: now, in: db)
    }

    /// 把编排要的外部能力接上真的。
    ///
    /// ⚠️ **VAD 裁剪那一步现在没做**:`keptIntervals` 传的是整块。
    /// 后果是**转写费不省**(实测裁完能降到约六成)。裁剪接上时只改这一处。
    ///
    /// 🔴 ~~「时间轴仍然对得上,因为『不裁剪』就是恒等情况」~~ **这句话原来是假的,
    /// 2026-08-17 修掉**(仓规 6:结论与前提一起改)。它假设每块都是 300 秒,而:
    /// · `BlockCutPolicy` 的窗口是 **270–330 秒**,`RecordingKernel` 注入的又是
    ///   真探针 `EnergyGate` ⇒ 切在 300 秒之后是**常态**;
    /// · 块一超 300 秒,`restoreToBlockTime` 抛 `timestampOutOfKeptRange`,
    ///   而 `pump` 的 `try?` 会把它吞掉 ⇒ **任务永久停在 `running`**,
    ///   `nextRunnable` 不捡它,attempts 也不涨 —— 既不 dead 也不 done,重启也救不回;
    /// · 就算没超,`offsetMs = blockSeq * 300_000` 也在**逐块累积偏移** ⇒
    ///   跳原话跳到错的位置,**而且不报任何错**。
    /// 现在两个数都从账本取真值(`PendingBlock.offsetMs` / `.durationMs`)。
    static func dependencies(in db: DatabaseQueue,
                             trigger: ProcessingEvents.Trigger)
        -> ProcessingOrchestrator.Dependencies {
        // ⚠️ **两个扩展名不是一回事,别合成一个。**
        // 手机上录的是 m4a(省空间);送检的是 wav(P4a 唯一跑通过的格式,
        // 见 `WavExport`)。转换发生在 `BackgroundUploadCenter.handOff` 里,
        // 所以**落进 R2 的键必须是 .wav** —— 云代理还会在提交前挡一道。
        let localExt = "m4a"
        return .init(
            // 这一拍的真值。下游一律读它,谁都不许自己写死 —— 见
            // `ProcessingOrchestrator.Dependencies.trigger` 那段。
            trigger: trigger,
            blocks: { sessionID in Self.blocks(of: sessionID, ext: localExt, in: db) },
            // 块自己带着真时长过来 —— 见 `PendingBlock.seconds` 那段注释
            seconds: { $0.seconds },
            reachability: { Reachability.current() },
            // 2026-08-17 用户拍板:**蜂窝也传**。
            //
            // 原来钉死 true 是照 §六 的「仅 Wi-Fi 开关」默认值,但那个开关的本意是
            // 省流量,而实测一天的音频经 VAD 裁剪后是几十 MB 级 —— 用户认为不值得
            // 为它把整条链卡在「等 Wi-Fi」上。真机上就卡住过:316 秒 93% 有声的那一场
            // 停在 `waiting_network` 动不了。
            //
            // ⚠️ 闸本身**留着**(`UploadGate` 一行没动):离线仍然要 hold,
            // 而且将来把开关做成用户可调时,这里换成读设置即可。
            wifiOnly: false,
            audioExt: "wav",
            transport: BackgroundUploadCenter.shared,
            proxy: ProxySettings.config,
            submit: { key, seconds in
                guard let c = ProxySettings.config else { throw ProxyClient.Failure.notConfigured }
                return try await ProxyClient.submit(key: key, seconds: seconds, config: c)
            },
            query: { id in
                guard let c = ProxySettings.config else { throw ProxyClient.Failure.notConfigured }
                return try await ProxyClient.query(remoteID: id, config: c)
            },
            freeze: { sessionID, jobs in
                let a = Self.assemble(sessionID: sessionID, jobs: jobs, ext: localExt,
                                      trigger: trigger, in: db)
                let now = ISO8601DateFormatter.growth.string(from: Date())
                let r = try TranscriptFreeze.freeze(
                    sessionID: sessionID, asrModel: "stepaudio-2.5-asr",
                    blocks: a.blocks, missing: a.missing,
                    unplaceable: a.unplaceable, now: now, in: db)
                try writeClusterTags(r.speakerByLine, now: now, trigger: trigger, in: db)
                return (lines: r.lineCount, status: r.status)
            },
            // 云代理没配时给 nil,**不给一个会抛的闭包** —— 两者在任务表里
            // 落的态不一样:nil 是「还没配,等你填」(retrying,不加 attempts),
            // 抛出来会被记成一次失败,填完设置之前就把重试次数耗光了。
            extract: ProxySettings.config.map { c in
                { prompt in try await ProxyClient.extract(prompt: prompt, config: c) }
            },
            // 🔴 **`scene` 与抽取分开。** 记账按 `scene` 分组 —— 合用一个的话
            // 「抽取一天花多少」与「比对一天花多少」会混成一个数,
            // 而降本时最需要知道的正是这两者各占多少(§5.1 第 3 条:八成成本在输出,
            // 而这两条腿的输出量差着数量级)。
            progressCall: ProxySettings.config.map { c in
                { prompt in try await ProxyClient.extract(scene: "progress",
                                                          prompt: prompt, config: c) }
            },
            // 🔴 **云端抽取队列**(`M2-B8`)。给了这两条,抽取就不在前台等模型了 ——
            // 排队(几百毫秒)之后手机可以睡,Mac daemon 或云端 cron 把它跑掉。
            // 用户 2026-08-21 的原话是「为啥还有 app 走了就不干活的逻辑」,
            // 而真相是 iOS 会挂起 App,抽取实测一两分钟到几分钟 ⇒ **同步那条结构上跑不完**。
            enqueueExtract: ProxySettings.config.map { c in
                { key, part, prompt in
                    try await ProxyClient.enqueueExtract(key: key, part: part,
                                                         prompt: prompt, config: c)
                }
            },
            fetchExtract: ProxySettings.config.map { c in
                { ticket in
                    try await ProxyClient.fetchExtractResult(ticket: ticket, config: c)
                }
            },
            // 两阶段抽取(`M2-成7`,v2.5):手机只交行材料。
            enqueueExtractLines: ProxySettings.config.map { c in
                { key, part, lines in
                    try await ProxyClient.enqueueExtractLines(key: key, part: part,
                                                              lines: lines, config: c)
                }
            },
            // 🔴 声纹认人(M2-认8):出题 → 排队 → 取回 → 合并,一整步。
            // **手机永远不判**(方案 §3.1 单执行方)—— 端侧 VoiceprintChain 的
            // 自动入口已随本提交断开,判决只在 Mac。
            voiceprint: ProxySettings.config.map { c in
                { sessionID in
                    guard let payload = try VoiceprintRemote.jobPayload(
                        sessionID: sessionID, in: db) else { return .noLines }
                    try await ProxyClient.enqueueVoiceprint(payload: payload, config: c)
                    guard let body = try await ProxyClient.fetchVoiceprintResult(
                        sessionID: sessionID, config: c) else { return .waiting }
                    let now = ISO8601DateFormatter.growth.string(from: Date())
                    let m: VoiceprintRemote.MergeOutcome
                    do {
                        m = try VoiceprintRemote.mergeSelf(body, sessionID: sessionID, now: now, in: db)
                    } catch VoiceprintRemote.Failure.identityModeMismatch {
                        var job = try JSONDecoder().decode(VoiceprintRemote.Job.self, from: payload)
                        job.force = true
                        try await ProxyClient.enqueueVoiceprint(payload: JSONEncoder().encode(job), config: c)
                        ProcessingEvents.record(trigger: trigger, outcome: "旧版认人结果已重新排队",
                                                detail: "场次 \(sessionID)，等待 Mac 按只认我重新判", in: db)
                        return .waiting
                    }
                    ProcessingEvents.record(
                        trigger: trigger,
                        outcome: "认人:\(m.matched) 簇认出我 · \(m.tagged) 簇未认成我",
                        detail: "场次 \(sessionID) · \(m.gatedOut) 段不是人声被 Mac 挡下"
                              + (m.anonymousReused > 0 ? " · 重放复用 \(m.anonymousReused) 个人格" : ""),
                        in: db)
                    return .merged(matched: m.matched, anonymous: m.anonymousNew,
                                   tagged: m.tagged)
                }
            },
            ingestCompletedBlocks: { sessionID, jobs in
                let completedAt = Date()
                let now = ISO8601DateFormatter.growth.string(from: completedAt)
                let ledger = Self.blocks(of: sessionID, ext: localExt, in: db)
                let uploads = try UploadJobStore.all(sessionID: sessionID, in: db)
                let skipped = Set(uploads.filter(\.isPermanentFailure).map(\.blockSeq))
                let appended = try ContinuousIngestion.append(
                    sessionID: sessionID, blocks: ledger, jobs: jobs, skipped: skipped, now: now,
                    knownBlockSeqs: Set(uploads.map(\.blockSeq)),
                    freezeBlock: { block, part, record in
                        let a = Self.assemble(sessionID: sessionID, jobs: jobs.filter { $0.state == .done },
                                              ext: localExt, onlyBlockSeqs: [block.blockSeq],
                                              trigger: trigger, in: db)
                        let completed = jobs.first { $0.blockSeq == block.blockSeq && $0.state == .done }
                        let noText = completed.map { ASRResponseParser.isEmptyRecognition(rawJSON: $0.resultJSON ?? "") } ?? false
                        if a.blocks.isEmpty || a.blocks.allSatisfy({ $0.lines.isEmpty }) {
                            if completed != nil && !noText {
                                try ASRJobStore.fail(sessionID: sessionID, blockSeq: block.blockSeq,
                                    error: "转写报文或时间无效，未冻结，可重试", now: now, in: db)
                                throw ContinuousIngestion.Failure.invalid("块 \(block.blockSeq) 没有可用转写，已保留录音供重试")
                            }
                        }
                        // 合法空结果是终态：保留可见占位，继续下一片；不把它说成无人说话。
                        let usable = a.blocks.filter { !$0.lines.isEmpty }.map { b in
                            BlockTranscript(blockSeq: b.blockSeq, offsetMs: b.offsetMs,
                                keptIntervals: b.keptIntervals, lines: b.lines.map { l in
                                    ASRLine(startMs: l.startMs, endMs: l.endMs, text: l.text,
                                            speaker: l.speaker.map { "块\(b.blockSeq)·\($0)" }, words: l.words)
                                })
                        }
                        let missing = usable.isEmpty
                            ? [MissingBlock(blockSeq: block.blockSeq, offsetMs: block.offsetMs,
                                            durationMs: block.durationMs, noRecognizedText: noText)]
                            : a.missing
                        return try TranscriptFreeze.freeze(
                            sessionID: sessionID, asrModel: "stepaudio-2.5-asr", part: part,
                            blocks: usable, missing: missing, unplaceable: a.unplaceable, now: now,
                            onFrozen: { transaction, result in
                                try record(transaction, result)
                                try Self.writeClusterTags(result.speakerByLine, now: now,
                                                          trigger: trigger, in: transaction)
                                if noText {
                                    try ProcessingEvents.record(trigger: trigger,
                                        outcome: "块 \(block.blockSeq) 未识别到文字，后续继续整理",
                                        detail: "场次 \(sessionID) · 已保留录音和原始转写，不重新提交。",
                                        at: completedAt, in: transaction)
                                }
                            }, in: db)
                    }, in: db)
                if let appended, !appended.blockSeqs.isEmpty {
                    ProcessingEvents.record(trigger: trigger, outcome: "已接入 \(appended.blockSeqs.count) 个分片，录音无需结束",
                                            detail: "场次 \(sessionID) · 块 \(appended.blockSeqs) · \(appended.lines) 行，语义判断已排队", in: db)
                }
                return appended
            })
    }

    /// 把已存的转写报文装配成「能冻结的块 + 缺块」。
    ///
    /// 🔴 **它是 `TranscriptFreeze.freeze` 两个调用点的共用件,而这正是它存在的理由。**
    /// 2026-08-18 复核抓到:M1-14a(缺块不许被静默抹平)与 M1-13a(块起点取真值)
    /// **都只修了 `freeze` 闭包这一个调用点**,而 `SessionMaintenance.refreeze`
    /// 是第二个 —— 它照旧不传 `missing:`、照旧拿 `blockSeq * 300_000` 兜底。
    /// 于是「重新整理时间轴」会把一份**缺块的转写重新落成 `frozen`**,
    /// 卡片说「好了」而逐字稿有洞:**同一个 BUG,换了个入口**。
    ///
    /// 两处各写一份装配逻辑就是这么来的。现在只有这一份。
    /// 冻结时用的保留区间表。
    ///
    /// - Parameter recorded: 上传时落的真值。nil = 这一块没裁过(整块送)。
    /// - Parameter maxLineEndMs: ASR 报的最大时间戳(**裁剪后**时间轴)。
    ///
    /// 🔴 **末尾的余量不是可选的。** 保留区间的总长若小于 ASR 报的最大时间戳,
    /// `restoreToBlockTime` 会抛 `timestampOutOfKeptRange`,而那个异常一路抛穿之后
    /// 任务会**永久停在 `running`**:`nextRunnable` 不捡它、attempts 一次都不涨,
    /// 既不 dead 也不 done,重启也救不回来 —— 用户没有任何可达的补救手段。
    ///
    /// 补法是把**最后一段**的尾巴放长到够用。为什么放最后一段而不是整体缩放:
    /// 越界只可能发生在末尾(编码器收尾那几十毫秒),前面每一段的起止都是我们
    /// 自己按采样点裁的、精确的。整体缩放会把**每一句话**都挪走一点。
    static func keptIntervals(recorded: [KeptInterval]?, blockDurationMs: Int,
                              maxLineEndMs: Int) -> [KeptInterval] {
        guard let recorded, !recorded.isEmpty else {
            return [KeptInterval(startMs: 0, endMs: max(blockDurationMs, maxLineEndMs))]
        }
        let total = recorded.reduce(0) { $0 + $1.durationMs }
        guard maxLineEndMs > total else { return recorded }
        var out = recorded
        let last = out[out.count - 1]
        out[out.count - 1] = KeptInterval(startMs: last.startMs,
                                          endMs: last.endMs + (maxLineEndMs - total))
        return out
    }

    /// 🔴 **`trigger` 是入参,不是这里的常量。** 这四条事件此前一律写死「前台」,
    /// 而这个函数在 `BGProcessingTask` 唤醒下照样跑 —— 于是事件表会说
    /// 「你打开 App 才发现缺块的」,而真相是凌晨后台发现的。
    /// `processing_events` 存在的唯一理由就是把这两件事分开(见它的文件注释),
    /// 写死等于把这张表的价值就地作废。
    static func assemble(sessionID: Int64, jobs: [ASRJobStore.Job], ext: String,
                         onlyBlockSeqs: Set<Int>? = nil,
                         trigger: ProcessingEvents.Trigger,
                         in db: DatabaseQueue) -> (blocks: [BlockTranscript],
                                                   missing: [MissingBlock],
                                                   unplaceable: [Int]) {
        // 块的真实起点与时长**只在账本里**(`asr_jobs` / `upload_jobs` 都不存时间)。
        let timing = Dictionary(
            blocks(of: sessionID, ext: ext, in: db)
                .filter { onlyBlockSeqs?.contains($0.blockSeq) ?? true }.map { ($0.blockSeq, $0) },
            uniquingKeysWith: { a, _ in a })

        // 这一场每块**到底送上去了哪几段**(M1-4d)。上传时算的,存在 `upload_jobs`。
        // 没有记录 ⇒ 这一块没裁过(整块送,或它早于 M1-4d),按整块还原 —— 那是对的。
        //
        // 🔴 **读不出来不能当成「没裁过」。** 上一版这里是 `try?` + `?? []`,
        // 而空表的后果是**每一块都按整块还原,而送上去的音频是裁过的** ⇒
        // 全场时间戳集体错位:跳原话跳到别人那句、声纹取到别人的声音,
        // **而且不报任何错**。这正是本仓最贵的失败形态,我 2026-08-18 亲手写了一个。
        var kept: [Int: [KeptInterval]] = [:]
        // 传上去过的块号。**它来自库,而 `timing` 来自磁盘账本** —— 两者会分叉,
        // 而分叉正是 M1-30 ① 的根因,见下面 `unplaceable` 那段。
        var uploadedSeqs: Set<Int> = []
        var uploadJobsReadable = true
        do {
            for job in try UploadJobStore.all(sessionID: sessionID, in: db) {
                guard onlyBlockSeqs?.contains(job.blockSeq) ?? true else { continue }
                uploadedSeqs.insert(job.blockSeq)
                if let intervals = SpeechTrim.decode(job.keptJSON) {
                    kept[job.blockSeq] = intervals
                }
            }
        } catch {
            uploadJobsReadable = false
            ProcessingEvents.record(
                trigger: trigger,
                outcome: "读不出场次 \(sessionID) 的保留区间表",
                detail: "\(error) —— 这一场的时间戳会按整块还原,裁过的块会错位;"
                      + "**而且账本完整性也查不了了**(见 unplaceable),"
                      + "这一场可能自称完整而实际缺块",
                in: db)
        }

        // ⚠️ **一块解不出来不能拖垮整场。**
        // 解析抛在这里的话会一路抛穿 `tick`,而 `pump` 用 do/catch 接住 ——
        // 任务就停在 `running` 上再也捡不起来(2026-08-17 踩过一次)。
        // 解不出来的块**跳过并记下来**,剩下的照常冻结成 partial;
        // 一块都解不出来时下游会判「这一场没有一块转写成功」,那是对的。
        let assembledBlocks = jobs.filter { onlyBlockSeqs?.contains($0.blockSeq) ?? true }.compactMap { job -> BlockTranscript? in
            guard let lines = try? ASRResponseParser.lines(fromRaw: job.resultJSON ?? "")
            else {
                ProcessingEvents.record(
                    trigger: trigger, outcome: "块 \(job.blockSeq) 的转写报文解不开",
                    detail: (job.resultJSON ?? "").prefix(200).description, in: db)
                return nil
            }
            // 🔴 **账本里没有这一块 = 不知道它在场次里的哪个位置。**
            // 退回 `blockSeq * 300_000` 是把一个**已知会错**的时间戳写进冻结层,
            // 而冻结层是不可变的 —— 写错就永久错。
            // 跳过并记下来,与上面「报文解不开」同一个处置。
            guard let t = timing[job.blockSeq] else {
                ProcessingEvents.record(
                    trigger: trigger,
                    outcome: "块 \(job.blockSeq) 在账本里找不到,定不了位",
                    detail: "场次 \(sessionID) —— 账本可能被「清除全部录音」删掉了",
                    in: db)
                return nil
            }
            return BlockTranscript(
                blockSeq: job.blockSeq,
                // 真实起点,不是「每块 5 分钟」乘出来的 —— 见 `PendingBlock.offsetMs`
                offsetMs: t.offsetMs,
                // 保留区间:裁过就用真值,没裁过就是整块。
                //
                // ⚠️ **末尾都要留出「ASR 报得比音频长」的余量**,不管裁没裁。
                // 原因:送检音频的时长与我们这边算的不会一模一样(编码器按帧收尾),
                // 差几十毫秒是正常的。不留余量的话末尾那句话刚好越界 ⇒
                // `restoreToBlockTime` 抛 → tick 被吞 → **任务永久停在 `running`**
                // (M1-13a 修的就是这个形状,别在同一处再造一个)。
                keptIntervals: Self.keptIntervals(recorded: kept[job.blockSeq],
                                                  blockDurationMs: t.durationMs,
                                                  maxLineEndMs: lines.map(\.endMs).max() ?? 0),
                lines: lines)
        }

        // 🔴 **账本里有、而这次没组装进来的块,就是缺块。**
        //
        // 不逐条去列来路(上传跳过的坏块 / 转写失败的块 / 报文解不开的块),
        // 而是**拿账本作差** —— 账本是「这一场到底录了哪些块」的唯一真相源,
        // 作差天然覆盖全部来路,**包括将来新增的第四种失败方式**。
        // 逐条枚举迟早漏掉一条,而漏掉的那一条不会报错,
        // 只会让一份残缺的转写自称完整。
        let assembled = Set(assembledBlocks.map(\.blockSeq))
        let missing = timing.values
            .filter { !assembled.contains($0.blockSeq) }
            .sorted { $0.blockSeq < $1.blockSeq }
            .map { MissingBlock(blockSeq: $0.blockSeq, offsetMs: $0.offsetMs,
                                durationMs: $0.durationMs) }
        if !missing.isEmpty {
            ProcessingEvents.record(
                trigger: trigger,
                outcome: "场次 \(sessionID) 缺 \(missing.count) 块,按 partial 冻结",
                detail: "缺的块号:\(missing.map(\.blockSeq)) —— "
                      + "逐字稿里会有占位行,卡片不会说「好了」。", in: db)
        }

        // 🔴 **账本与 `upload_jobs` 分叉时,上面那个 `missing` 是看不见缺口的**(M1-30 ①)。
        //
        // `missing` = 账本作差。而账本是**磁盘文件**、`upload_jobs` 是**库**:
        // 账本部分丢失时,丢掉的那些块**同时**从 `timing` 和 `missing` 里消失
        // ⇒ 既不进 partial、也不插占位行 ⇒ **这一场自称完整地落库**,
        // 而 exit code 全绿、行数在涨。这是本仓最贵的失败形态。
        //
        // ⇒ 拿**另一份出处**(库里的 `upload_jobs`)去照账本:传上去过、
        // 而账本里没有的块,就是账本丢掉的。
        //
        // ⚠️ **不把它们塞进 `missing`** —— `MissingBlock` 要 offset 与 duration,
        // 而「块的真实起点与时长只在账本里」(本函数开头那句)。编一个位置正是
        // 上面那段拒绝做的事。所以只推状态成 partial,**不产占位行**:
        // 我们确实不知道那个洞在哪,但**「说不清哪儿缺了」远好过「自称完整」**。
        //
        // ⚠️ 这不是「换个集合当守卫」(那会把账本缺块变成任务判死),
        // 是按 §3.1.6 的口径走 partial 那条路。
        let unplaceable = uploadJobsReadable
            ? uploadedSeqs.subtracting(timing.keys).sorted()
            : []
        if !unplaceable.isEmpty {
            ProcessingEvents.record(
                trigger: trigger,
                outcome: "场次 \(sessionID) 有 \(unplaceable.count) 块传上去过,但账本里没有",
                detail: "块号:\(unplaceable) —— 账本(磁盘)与 upload_jobs(库)分叉了。"
                      + "定不了位,所以**没有占位行**;但这一场按 partial 冻结,"
                      + "卡片不会说「好了」。账本可能被「清除全部录音」删过。",
                in: db)
        }
        return (assembledBlocks, missing, unplaceable)
    }

    /// 把 ASR 自带的分人标签写进归属层。
    ///
    /// 🔴 **这是走文件端点的全部理由**(判 18:它在 20 字以上长句上错误率 10%,
    /// 比 Mac 本地 pyannote 的 15% 更好,而产品要的表态与承诺都在长句里)。
    /// 2026-08-17 真机抓到:标签**回来了**(`speaker:{"id":"speaker_0"}`,还分出了
    /// 两个人),而这一步压根不存在 —— 13 行一个都没挂上,整条链最值钱的东西
    /// 落进了地板。`ASRResponseParser.speakers` 写了但**从没被调用过**。
    ///
    /// ## 只走 `assignSpeaker`,不直接写表
    ///
    /// 铁律 3:归属只有一条路可写。旧仓没有统一入口,实测悬空 1979 条。
    ///
    /// ## `person` 传 nil 是对的
    ///
    /// 簇标签是**这一场里的第 N 个人**,不是身份 —— 跨场对不上。
    /// 身份要等声纹匹配或用户确认(见 `SpeakerNaming`)。
    /// 现在写进去的是「这一场里谁跟谁是同一个人」,那已经是纪要能用的信息。
    ///
    /// 失败**不拖垮冻结**:逐字稿已经落盘了,归属可以重算(冻结层与归属层分离
    /// 就是为这个)。但要留痕 —— 静默跳过的话「这一场没分人」看起来像上游没给。
    ///
    /// `trigger` 与 `assemble` 同理:失败那条事件是这一步唯一的痕迹,
    /// 而它在后台唤醒下同样会发生。写死「前台」会让「后台跑过但没挂上标签」
    /// 看起来像「我打开 App 才挂失败的」。
    static func writeClusterTags(_ speakerByLine: [Int64: String], now: String,
                                 trigger: ProcessingEvents.Trigger,
                                 in db: DatabaseQueue) throws {
        try db.write { transaction in
            try writeClusterTags(speakerByLine, now: now, trigger: trigger, in: transaction)
        }
    }

    static func writeClusterTags(_ speakerByLine: [Int64: String], now: String,
                                 trigger: ProcessingEvents.Trigger, in db: Database) throws {
        // 🔴 **空集合不是「没事发生」,是「这一场没有分人」——必须留痕。**
        //
        // 原来这里直接 `return`,连一条事件都不写。后果链(2026-08-19 对抗审查逐跳查实):
        // `line_speakers` 0 行 ⇒ **「上游没给分人」「写失败」「这一场只有一个人说话」
        // 在库里长得完全一样**;再往下,提名的四项相乘任一为 0 即出局
        // ⇒ 这一场**永远不会被提名,而且没有任何地方说是因为缺分人**。
        // 静默漏报比误报更难发现 —— 用户 2026-08-19 拍板「要看见」。
        guard !speakerByLine.isEmpty else {
            try ProcessingEvents.record(trigger: trigger, outcome: "这一批没有分人标签",
                                    detail: "上游没给 speaker(例如走了 SSE 兜底,M1-34)。"
                                          + "本批的行不会有说话人,提名与「人」相关的发现会跳过它们。",
                                    in: db)
            return
        }

        // 行长从库里读 —— 置信度按行长分档(见下面那段注释)。
        let ids = speakerByLine.keys.map(String.init).joined(separator: ",")
        let lineLength: [Int64: Int] = try { () throws -> [Int64: Int] in
            var out: [Int64: Int] = [:]
            for row in try Row.fetchAll(db, sql:
                "SELECT line_id, LENGTH(text) AS n FROM transcript_lines WHERE line_id IN (" + ids + ")") {
                out[row["line_id"]] = row["n"]
            }
            return out
        }()

        // 按簇分组:一次 assignSpeaker 写一簇,而不是一行一次 ——
        // 每次调用都要跑一遍连锁重算,逐行调会把它跑上几十遍。
        var byTag: [String: [Int64]] = [:]
        for (lineID, tag) in speakerByLine { byTag[tag, default: []].append(lineID) }
        // ⚠️ **非「用户确认」的来源必须给 confidence**(§3.2.2 签名,`assignSpeaker` 会拒)。
        // 2026-08-17 真机上就是这么挡住的:标签解出来了、也调到了写入口,
        // 但 confidence 传了 nil ⇒ 整批被拒 ⇒ `line_speakers` 0 行。
        // 那次没有静默 —— 事件表里留了「分人标签写不进去」,这条修复就是它换来的。
        //
        // 置信度按**行长**分档,不是给所有行一个数。依据只有一条实测(P4a):
        // **20 字以上的长句,ASR 分人错误率 10%**(Mac 本地 pyannote 是 15%)。
        // 碎句只知道「更差」,**没量过**。
        //
        // 🔴 所以短行给 **0.5 —— 那不是测量值,是一句「不知道」。**
        // 编一个 0.75 之类的数会让它看起来像量过的,而下游(将来的「说话人N?」
        // 低置信展示、声纹交叉验证)会拿它当真去做取舍。
        // 宁可写「不知道」,也不写一个查不到出处的数。量到真数再回来改。
        let longLineChars = 20
        for (tag, lines) in byTag.sorted(by: { $0.key < $1.key }) {
            for (isLong, group) in Dictionary(grouping: lines,
                                              by: { (lineLength[$0] ?? 0) >= longLineChars }) {
                do {
                    _ = try AssignSpeaker.assignSpeaker(
                        lines: group, person: nil, clusterTag: tag,
                        source: .systemOrganized,
                        confidence: isLong ? 0.90 : 0.50,
                        actor: .system, now: now, in: db)
                } catch {
                    try ProcessingEvents.record(trigger: trigger, outcome: "分人标签写不进去",
                                            detail: "\(tag):\(error)", in: db)
                }
            }
        }
    }

    /// 这一场**自己的**块。
    ///
    /// 🔴 2026-08-17 真机实测抓到的钱包漏洞:原来这里读整个账本、把当天所有块
    /// 都当成这一场的。一天录三场,每场都传了当天全部 4 个块 ——
    /// **12 次上传对应 4 个音频文件**,再往下走就是 12 次转写,而转写按块收费。
    /// 而且每一场的逐字稿里都会是一整天的内容。
    ///
    /// 账本里本来就有场次边界(`sessionStarted` / `sessionEnded`),
    /// 只是 `SessionSummary` 把块清单丢了。现在带出来了,按**起始时刻**对上 ——
    /// 那正是 `sessions` 表的唯一键(`source, started_at`,迁移 v8)。
    ///
    /// 两处「找不到」都返回空数组,由编排把任务标死并说清楚 ——
    /// 悄悄返回一个「差不多的」块清单,就是拿别人的音频当这一场的。
    static func blocks(of sessionID: Int64, ext: String, in db: DatabaseQueue) -> [PendingBlock] {
        ((try? db.read { blocks(of: sessionID, ext: ext, in: $0) }) ?? [])
    }

    /// 同一件事的 `Database` 版。**逻辑只有下面这一份**,上面那个是它的包装 ——
    /// 投影层要在一次 `read` 里判「这一句能不能听」,而它手上只有 `Database`。
    static func blocks(of sessionID: Int64, ext: String, in d: Database) -> [PendingBlock] {
        // ⚠️ **按这一场自己的日期找目录,不是「今天」。**
        // 后台唤醒可能发生在凌晨,那时「今天」已经翻篇,而要处理的是昨天那一场 ——
        // 用「今天」的话读到的是空账本,这一场会被判成「一块音频都没有」并**标死**,
        // 而它的音频好好地躺在盘上。
        guard let row = try? Row.fetchOne(d, sql: """
                SELECT day, source, started_at FROM sessions WHERE id = ?
                """, arguments: [sessionID]),
              let day = row["day"] as String?,
              let source = row["source"] as String?,
              let startedAt = row["started_at"] as String? else { return [] }

        let dir = RecordingPaths.audioDir(day: day, source: source)
        guard let (entries, _) = try? BlockLedger.read(
            from: dir.appendingPathComponent("ledger.jsonl")) else { return [] }

        guard let mine = BlockLedger.sessions(entries: entries)
            .first(where: { ISO8601DateFormatter.growth.date(from: startedAt) == $0.startedAt }) else { return [] }

        return mine.blocks.map {
            let durationMs = max(0, Int(($0.endedAt.timeIntervalSince($0.startedAt) * 1000).rounded()))
            return PendingBlock(
                blockSeq: $0.seq,
                fileURL: dir.appendingPathComponent(
                    String(format: "block-%04d.\(ext)", $0.seq)),
                // 真时长,不是「块长 5 分钟」那个名义值 —— 记账要用它
                seconds: max(1, Int($0.endedAt.timeIntervalSince($0.startedAt).rounded())),
                // 块起点相对场次起点。**账本里本来就有,没有理由乘出来** ——
                // 见 `PendingBlock.offsetMs` 那段。
                offsetMs: max(0, Int(($0.startedAt.timeIntervalSince(mine.startedAt) * 1000).rounded())),
                durationMs: durationMs)
        }
    }

    /// 盘上有、账本里**没有**的块文件 —— 进程被杀时正在写的那一块。
    ///
    /// 🔴 **它们读不出来,不是「躺在盘上等认领」。**
    /// 2026-08-19 拿真文件验过(用户那 2 分 14 秒):MP4 的索引(`moov`)
    /// 是**关文件时才写**的,进程被杀只留下一堆没有目录的音频数据 ——
    /// `ffprobe` 报 `moov atom not found`,按裸 AAC 硬解出来是垃圾。
    /// 同一天正常关闭的块作对照,读得好好的(30.08 秒)。
    ///
    /// 所以这里**不认领、不补账本**(补了等于把一份读不出来的东西说成一块音频),
    /// 只做一件事:**把这段损失摆出来**。§3.2:失败必须可见 ——
    /// 而在此之前它的表现是「场次判成一块音频都没有 → 移出记忆」,
    /// 音频没了、记录也没了,两边都不报错。
    ///
    /// - Returns: (块序, 文件名, 字节数),按块序。
    static func orphanBlockFiles(sessionID: Int64, ext: String,
                                 in db: DatabaseQueue) -> [(seq: Int, name: String, bytes: Int)] {
        guard let row = try? db.read({ d in
            try Row.fetchOne(d, sql: "SELECT day, source FROM sessions WHERE id = ?",
                             arguments: [sessionID])
        }) ?? nil,
              let day = row["day"] as String?,
              let source = row["source"] as String? else { return [] }

        let dir = RecordingPaths.audioDir(day: day, source: source)
        guard let (entries, _) = try? BlockLedger.read(
            from: dir.appendingPathComponent("ledger.jsonl")) else { return [] }

        // 账本里出现过的块序 —— **整天的**,不分场次:块序在一天里是连续的,
        // 而孤儿只可能是「最后一次写到一半」的那一个。
        var known = Set<Int>()
        for e in entries { if let b = e.block { known.insert(b.seq) } }

        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [(seq: Int, name: String, bytes: Int)] = []
        for name in names where name.hasPrefix("block-") && name.hasSuffix(".\(ext)") {
            let digits = name.dropFirst("block-".count).prefix(4)
            guard let seq = Int(digits), !known.contains(seq) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            out.append((seq: seq, name: name, bytes: (attrs?[.size] as? Int) ?? 0))
        }
        return out.sorted { $0.seq < $1.seq }
    }

    static var recordingsRoot: URL {
        RecordingPaths.root
    }

    // MARK: - 说人话

    private static func summarize(_ outcomes: [ProcessingOrchestrator.Outcome]) -> String {
        // 只报最有信息量的那一件:失败 > 出稿 > 冻结 > 其余的第一件。
        // 报「跑了 5 步」是没用的,读的人想知道的是「到哪一步了 / 哪儿卡住了」。
        if let f = outcomes.first(where: { if case .failed = $0 { return true }; return false }) {
            return describe(f)
        }
        if let e = outcomes.last(where: { if case .extracted = $0 { return true }; return false }) {
            return describe(e)
        }
        if let z = outcomes.last(where: { if case .frozen = $0 { return true }; return false }) {
            return describe(z)
        }
        return outcomes.first.map(describe) ?? "没事干"
    }

    private static func describe(_ o: ProcessingOrchestrator.Outcome) -> String {
        switch o {
        case .idle:                              return "没事干"
        case .uploaded(let s, let b):            return "场次 \(s) 传完 \(b.count) 块"
        case .waitingForUpload(let s, let n):    return "场次 \(s) 还有 \(n) 块在传"
        case .held(let s, let why):              return "场次 \(s) 暂缓:\(why)"
        case .submitted(let s, let b):           return "场次 \(s) 提交转写 \(b.count) 块"
        case .waitingForASR(let s, let n):       return "场次 \(s) 等转写 \(n) 块"
        case .waitingForExtraction(let s, let t, let p):
            return "场次 \(s) 等待云端理解（转写 \(t) 第 \(p + 1) 块）"
        case .waitingForVoiceprint(let s):       return "场次 \(s) 等待 Mac 整理说话人"
        case .frozen(let s, let n, let st):      return "场次 \(s) 冻结 \(n) 行(\(st))"
        case .extracted(let s, let n, let d):
            return "场次 \(s) 理解完成" + (n > 0 ? "，\(n) 条整理记录" : "")
                 + (d > 0 ? "（过滤 \(d) 条）" : "")
        // ⚠️ **三个数都说出来。** 只报「比完了」的话,「这一场确实没有进展」与
        // 「模型说了五条但一条都过不了校验」在这一行里长得一模一样。
        case .progressed(let s, let silent, let cards, let bad):
            return "场次 \(s) 比对:静默 \(silent) · 待确认 \(cards)"
                 + (bad > 0 ? " · 校验没过 \(bad)" : "")
        // 四个数都说。**「一个都没认出」与「Mac 没跑」必须分得开** ——
        // 后者根本到不了这个 case(还在 waiting)。
        case .speakersJudged(let s, let m, let a, let t):
            return "场次 \(s) 认人:\(m) 簇认出 · \(a) 个新声音 · \(t) 簇待手动认"
        case .failed(let s, let why):
            return "场次 \(s.map(String.init) ?? "?") 失败:\(why.prefix(120))"
        }
    }
}

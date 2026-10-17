import Foundation
import AVFoundation
import GRDB

/// 后台上传(M1-4c)。**进程里唯一的一个。**
///
/// ## 为什么必须是单例
///
/// 一个后台 `URLSession` 标识符在一个进程里只能有一个实例 —— 建第二个会拿到
/// 一个行为未定义的 session(苹果文档明写)。而这个标识符必须固定,
/// 因为 App 被杀掉重新拉起时,系统靠它把还在传的任务交还给我们。
///
/// ## 为什么它不能依赖 `RecordingViewModel`
///
/// 回调可能发生在**冷启动的进程**里:App 被杀 → 系统在后台把这块传完 →
/// 系统把 App 拉起来只为了送这个回调。那一刻没有界面、没有 ViewModel,
/// 只有 `AppDelegate` 和这个类。所以它自己持有 writer,启动时由
/// `AppDelegate` 注入(而 writer 是进程级共享的 `AppDatabase.shared`)。
///
/// ## 这里没有判断
///
/// 该不该传、失败了怎么退避,全在 `BlockUploader`;结果怎么落盘,在
/// `UploadJobStore`。这个文件只做两件事:**把文件交给系统**,
/// **把系统的回话写回那一行**。
///
/// 分开的理由很实在:`URLSession` 在单元测试里跑不起来,而要验的东西
/// (退避算得对不对、回调对不对得上行、丢了的传输能不能捡回来)全是判断。
final class BackgroundUploadCenter: NSObject, UploadTransport {

    static let shared = BackgroundUploadCenter()

    /// ⚠️ **改这个字符串等于抛弃所有在传的任务。** 系统按它认领上一次进程
    /// 留下的传输;换了名字,那些传输会永远回调不到我们,而 `upload_jobs`
    /// 里的行只能靠 `resetLost` 的宽限期兜回来 —— 一次白传。
    static let sessionIdentifier = "com.growth.app.upload"

    enum Failure: Error, CustomStringConvertible {
        case notConfigured
        case fileMissing(URL)
        case conversionFailed(String)

        var description: String {
            switch self {
            case .notConfigured: return "云代理还没配 —— 去设置里填地址与令牌"
            case .fileMissing(let u): return "要传的音频不在:\(u.lastPathComponent)"
            case .conversionFailed(let w): return "音频转 wav 失败:\(w)"
            }
        }
    }

    private var writer: (any DatabaseWriter)?
    // 🔴 **这里刻意没有 `config` 这份副本(2026-08-17 删掉的,别加回来)。**
    //
    // 原来它是一个 `private var config`,只在 `start(writer:config:)` 里赋值一次,
    // 而 `start` 只在 `didFinishLaunching` 调。配套的 `updateConfig(_:)` **全仓没有调用方**。
    //
    // 后果命中的是**第一次用这个 App 的标准流程**:
    // 启动(config = nil)→ 去设置页填地址与令牌 → 探活显示「通了,令牌也对」
    // → 而上传腿在这个进程的剩余生命周期里**一直是 nil**,只会抛 `notConfigured`、
    // 烧 attempts,最终 dead(而 dead 没有复活路径)。用户看到的是
    // 「我明明配好了,探活也说通了,它却一直失败」,**杀掉 App 重开才会好**。
    //
    // 修法不是「记得在设置页调一次 `updateConfig`」—— 那还是两份配置,
    // 下一个改配置的入口照样会忘(本仓 §3.2 反复吃过「入口一多就有人漏」的亏)。
    // **改成和另外两条腿同一个做法:在用的时候读 `ProxySettings.config`。**
    // 转写与抽取每拍重读(`ProcessingPump.swift` 的 `dependencies`),所以它们
    // 当时就是对的 —— 三条腿本来就该只有一个真相源。
    //
    // ⚠️ 代价是每块读一次 Keychain。块是 5 分钟一个,可以忽略。

    /// 配置从哪来。**默认就是 `ProxySettings`,而且每次调用都重读** —— 这一行
    /// 就是上面那段的全部实现。
    ///
    /// ⚠️ 留这道缝只有一个理由:**让「配完不用重启」那条验收真的跑得起来**。
    /// 测试 target 没有宿主 App、拿不到 keychain entitlement,直接走 `ProxySettings`
    /// 的话那条测试只能 skip —— 而一条 skip 掉的验收等于把照妖镜关掉
    /// (本仓 §3.3)。注入的写法与 `RecordingKernel(probe:)` 同构。
    var configProvider: () -> ProxyClient.Config? = { ProxySettings.config }

    /// 系统送完回调后要调的那个 completion。**不调它系统会记账并惩罚 App**
    /// (下次给的后台时间更少),所以它只在 `urlSessionDidFinishEvents` 里被清掉。
    private var systemCompletion: (() -> Void)?
    /// 回调里发生了变化 → 该再推一拍编排。由 `AppDelegate` 接上。
    var onProgress: (() -> Void)?

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // 录音块不是「可有可无的后台数据」。true 会让系统按电量和网络自己挑时机,
        // 而用户点完结束就在等那份纪要。
        cfg.isDiscretionary = false
        // 传完了把 App 唤醒(甚至冷启动)—— 真后台的关键就是这一行。
        cfg.sessionSendsLaunchEvents = true
        // 2026-08-17 用户拍板:**蜂窝也传**。
        //
        // ⚠️ 这一项**不能在 session 建好之后改**,所以它和 `ProcessingPump` 里那个
        // `wifiOnly` 必须一起改、也只能靠重启生效。将来做成用户可调的开关时,
        // 改完必须提示重启 App —— 或者换个 identifier 建第二个 session,
        // 而那会把正在传的任务留在旧 session 里(更糟)。
        cfg.allowsCellularAccess = true
        // 每块 5 分钟音频,不该传半小时还没动静。超时由系统重试。
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// 启动时接上。**幂等** —— 冷启动与热启动都会调。
    ///
    /// ⚠️ **不再接收 config**(见上面那段)。配置由 `handOff` 在用的时候读,
    /// 所以设置页改完立刻生效,不用重启 App。
    func start(writer: any DatabaseWriter) {
        self.writer = writer
        _ = session          // 触发 lazy:让系统尽早把上次留下的任务交还给我们
    }

    // MARK: - 交出去

    /// 交出去之前先转 wav。
    ///
    /// 🔴 2026-08-17 实测:传 m4a 而在载荷里声明 `format: "mp3"`,StepFun 读出了
    /// **正确的时长**(音频确实拉到了)、`result` 却是 `[{}]` —— 一个字都没有。
    /// 对格式撒谎的代价不是报错,是静默的空结果。
    /// 而 P4a 唯一真跑通过的配置就是 wav(见 `WavExport` 的注释)。
    ///
    /// 转换是**异步**的,而 `handOff` 是同步契约(`BlockUploader` 每一步都要落盘)。
    /// 这里用一个一次性的信号量桥过来:转换是纯 CPU + 磁盘,没有网络,
    /// 不会像网络那样卡到天荒地老;而且它跑在编排的后台任务里,不占主线程。
    ///
    /// 🔴 **`trigger` 顺着编排传下来,这里一律不猜。** 这个函数在
    /// `BGProcessingTask` 唤醒下照样跑(整条链就是为「App 不在前台也要出稿」
    /// 建的),而它记的两条 M1-4d 事件曾经写死「前台」——
    /// 于是「凌晨 3:14 后台裁的段」在事件表里长得和「你打开 App 才裁的」
    /// 一模一样,而分开这两件事正是 `processing_events` 存在的唯一理由。
    func handOff(fileURL: URL, to key: String, tag: String,
                 trigger: ProcessingEvents.Trigger) throws {
        // **读的时候才取**,不吃启动时的那份快照 —— 理由见文件上方那段长注释。
        guard let config = configProvider() else { throw Failure.notConfigured }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // 文件不在也是永久的 —— 它不会自己回来。
            throw PermanentUploadFailure(reason: "要传的音频不在:\(fileURL.lastPathComponent)")
        }

        var wav: URL?
        var convertError: Error?
        var plan: SpeechTrim.Plan?
        let done = DispatchSemaphore(value: 0)
        Task {
            // ⚠️ **目的地按上传标签取,不按 m4a 的文件名推。**
            // 块号是按天从 0 起的 —— 两天各有一个 `block-0003`,推出来是
            // 同一个临时路径,而 `convert` 开头就 removeItem 再重写 ⇒
            // 两块同时在传时,后转的会把前一个**正在上传的文件换掉**,
            // 表现是「上传成功、转写成功、内容是别人的」。
            do {
                // 🔴 **一个 `plan`,两处消费:裁 wav、写还原表。**
                // 它们必须逐字一致,而让它们一致的唯一可靠办法不是写注释提醒,
                // 是**让它们读同一个变量** —— 这个仓 2026-08 反复栽在
                // 「一件事在两处各存一份,而只有一份被维护」上。
                let proposed = try await Self.trimPlan(for: fileURL, tag: tag, trigger: trigger)
                let p = Self.exportPlan(proposed)
                if proposed != nil && p == nil, let writer = self.writer {
                    ProcessingEvents.record(trigger: trigger, outcome: "裁剪没有保留采样点，改为整块送检",
                        detail: "\(tag) · 原音频保留，未将空裁剪当作音频损坏。", in: writer)
                }
                plan = p
                do {
                    wav = try await WavExport.convert(fileURL, to: UploadScratch.url(tag: tag), keeping: p?.intervals)
                } catch WavExport.Failure.emptyAudio(_) where p != nil {
                    // 非空裁剪也可能因时间范围异常没有输出；先核整块，不能据此判原件损坏。
                    plan = nil
                    wav = try await WavExport.convert(fileURL, to: UploadScratch.url(tag: tag))
                    if let writer = self.writer {
                        ProcessingEvents.record(trigger: trigger, outcome: "裁剪输出为空，已复用原音频整块送检",
                            detail: tag, in: writer)
                    }
                }
            }
            catch { convertError = error }
            done.signal()
        }
        // 5 分钟块解码约几秒。超时比无限等好 —— 失败会被任务表记下来并退避重试。
        if done.wait(timeout: .now() + 120) == .timedOut {
            throw Failure.conversionFailed("转 wav 超时(120 秒):\(fileURL.lastPathComponent)")
        }
        if let convertError {
            if Self.isPermanentExportFailure(convertError, untrimmed: plan == nil) {
                throw PermanentUploadFailure(reason: "音频转 wav 失败:\(convertError)")
            }
            // 取消、磁盘／文件保护和暂时的解码错误保留重试，不能被正式冻成缺块。
            throw Failure.conversionFailed("音频转 wav 暂未完成:\(convertError)")
        }
        guard let fileURL = wav else { throw Failure.conversionFailed("转 wav 没产出文件") }

        // 落还原表 + 记保留率。**两件都在交给系统之前做完** ——
        // `uploadTask` 一 resume,回调就可能在另一个进程生命周期里回来,
        // 那时这两件事没人做了,而转写会照样成功、时间戳照样错。
        if let plan, let writer, let ids = UploadJobStore.parse(tag: tag) {
            try UploadJobStore.recordKept(sessionID: ids.sessionID, blockSeq: ids.blockSeq,
                                          json: SpeechTrim.encode(plan.intervals), in: writer)
            // ⚠️ **保留率每块都记,不是只在触发保底闸时记**(M1-4d 验收③)。
            // 裁错了没有人会发现:转写照样返回、行照样有、顺序照样对,只是**少了一段**。
            // 这正是本仓最贵的失败形态,而这一行事件是它唯一会留下的痕迹。
            ProcessingEvents.record(
                trigger: trigger,
                outcome: plan.fellBack ? "保底闸:整块送检" : "VAD 裁段",
                detail: String(format: "块 %d 保留 %.1f%%%@", ids.blockSeq, plan.ratio * 100,
                               plan.fellBack ? " —— 低于 \(Int(SpeechTrim.minRetentionRatio * 100))% 判为异常,不裁" : ""),
                in: writer)
        }
        var comp = URLComponents(url: config.baseURL.appendingPathComponent("upload"),
                                 resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "key", value: key)]
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "POST"
        req.setValue(config.token, forHTTPHeaderField: "X-Growth-Token")

        let task = session.uploadTask(with: req, fromFile: fileURL)
        // ⚠️ **回调回来时只剩它。** 后台传输的回调可能发生在冷启动的进程里,
        // 那时内存里什么都没有 —— 靠这个字符串把结果对回某一块。
        // 它由系统随任务一起持久化。
        task.taskDescription = tag
        task.resume()
    }

    /// 空裁剪不是原音频损坏。整块回退与还原表必须读同一个计划；nil 代表整块，
    /// 不能送整块却落 []，否则 ASR 时间戳无法还原。非空计划与已批准阈值不变。
    static func exportPlan(_ proposed: SpeechTrim.Plan?) -> SpeechTrim.Plan? {
        guard let proposed, !proposed.intervals.isEmpty else { return nil }
        return proposed
    }

    static func isPermanentExportFailure(_ error: Error, untrimmed: Bool) -> Bool {
        if let failure = error as? AudioImport.Failure, case .noAudioTrack = failure { return true }
        if let failure = error as? WavExport.Failure, case .emptyAudio = failure { return untrimmed }
        return false
    }

    /// 算这一块的裁剪计划。**算不出来就整块送,绝不静默地裁**。
    ///
    /// 🔴 fail-open 的方向在这里是唯一正确的:VAD 挂了(模型没打进包、
    /// 算子集不对、解不出输出)时,「整块送」只是多花那一块的钱,
    /// 而「当成没人说话」是**把整场变成空白**。两个方向的代价差着一整个产品。
    ///
    /// → nil 表示不裁(整块),调用方据此把 `keeping:` 传 nil。
    private static func trimPlan(for fileURL: URL, tag: String,
                                 trigger: ProcessingEvents.Trigger) async throws
        -> SpeechTrim.Plan? {
        guard let ids = UploadJobStore.parse(tag: tag),
              let durationMs = try? await Self.durationMs(of: fileURL), durationMs > 0
        else { return nil }
        _ = ids
        do {
            return try await SpeechTrim.plan(of: fileURL, vad: SileroVAD(),
                                             durationMs: durationMs)
        } catch {
            // 记下来,不吞。**「这一块没裁」和「这一块裁了」的账要分得开** ——
            // 分不开的话,将来对账「为什么这个月转写费没降」时无从查起。
            if let writer = shared.writer {
                ProcessingEvents.record(trigger: trigger, outcome: "VAD 不可用,整块送检",
                                        detail: "\(fileURL.lastPathComponent):\(error)",
                                        in: writer)
            }
            return nil
        }
    }

    /// 块的真实时长(秒 → 毫秒)。裁剪的分母,不能用「每块 5 分钟」推。
    private static func durationMs(of url: URL) async throws -> Int {
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds * 1000)
    }

    // MARK: - 捡回丢掉的传输

    /// 启动时对一次账:`upload_jobs` 里还标着「在传」、而系统那边已经没有的,
    /// 判成丢失。
    ///
    /// 会发生:App 被强杀的瞬间任务还没真正入队、系统清理、设备重启。
    /// 不对账的话那些行会永远停在 `handed`,这一场永远等不到上传完成 ——
    /// 而任务表上看起来一切正常。
    func reconcile(now: Date = Date()) async {
        guard let writer else { return }
        let live = Set(await session.allTasks.compactMap(\.taskDescription))
        do {
            // 顺带扫掉转完 wav、还没等到回调就被杀掉的那些残留。
            // **拿同一份 `live` 判活**:系统那边还在传的不能删,
            // 删掉就是把正在传的文件从它脚下抽走。
            let swept = UploadScratch.sweep(liveTags: live)
            if swept.files > 0 {
                ProcessingEvents.record(
                    trigger: .transferCallback,
                    outcome: "清掉 \(swept.files) 个上传残留",
                    detail: "腾出 \(swept.bytes / 1_048_576) MB —— "
                          + "它们是转完 wav 之后、拿到回调之前被杀掉留下的。",
                    at: now, in: writer)
            }
            let lost = try UploadJobStore.resetLost(liveTags: live, now: now, in: writer)
            if !lost.isEmpty {
                ProcessingEvents.record(trigger: .transferCallback,
                                        outcome: "捡回 \(lost.count) 块丢掉的传输",
                                        detail: lost.map(\.key).joined(separator: " "),
                                        at: now, in: writer)
            }
        } catch {
            // 对账失败要留痕。悄悄跳过的话,卡住的那一场再也没人管。
            ProcessingEvents.record(trigger: .transferCallback, outcome: "对账失败",
                                    detail: "\(error)", at: now, in: writer)
        }
    }

    // MARK: - 系统唤醒

    /// `AppDelegate` 收到 `handleEventsForBackgroundURLSession` 时转进来。
    func handleSystemWake(completion: @escaping () -> Void) {
        systemCompletion = completion
        _ = session
    }
}

// MARK: - 回调

extension BackgroundUploadCenter: URLSessionDataDelegate {

    /// 传输结束(成功或失败)。**这是唯一权威的结果**,系统自己的重试已经在它之前。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let writer, let tag = task.taskDescription,
              let (sessionID, blockSeq) = UploadJobStore.parse(tag: tag) else { return }
        // 🔴 **wav 在这里删,不在别处。** 这是系统给出的最终结果 ——
        // 它自己的重试已经在它之前跑完,此刻这个文件对任何人都没用了。
        // 失败也删:重传会从 m4a 重新转一遍,而 m4a 受保留期保护、还在盘上。
        // 不删的话一天堆 1.4 GB(5 分钟块 ≈ 9.6 MB × 144 块),比 AAC 那笔大五倍。
        UploadScratch.discard(tag: tag)
        let now = ISO8601DateFormatter.growth.string(from: Date())
        let status = (task.response as? HTTPURLResponse)?.statusCode

        do {
            if let error {
                try UploadJobStore.fail(sessionID: sessionID, blockSeq: blockSeq, status: status,
                                        error: "\(error)", now: now, in: writer)
            } else if let status, (200..<300).contains(status) {
                try UploadJobStore.finish(sessionID: sessionID, blockSeq: blockSeq,
                                          status: status, now: now, in: writer)
            } else {
                // ⚠️ **没有 error 不等于成功。** HTTP 401/500 在 URLSession 眼里
                // 是一次完成的传输,`error` 是 nil —— 按 error 判成功的话,
                // 一块根本没落到 R2 的音频会被当成传好了,然后去转写一个不存在的对象。
                try UploadJobStore.fail(sessionID: sessionID, blockSeq: blockSeq, status: status,
                                        error: "HTTP \(status.map(String.init) ?? "?")",
                                        now: now, in: writer)
            }
        } catch {
            // 写不进库就没别的地方能记了。至少留一行事件。
            ProcessingEvents.record(trigger: .transferCallback, outcome: "回调写库失败",
                                    detail: "\(tag):\(error)", in: writer)
        }
        onProgress?()
    }

    /// 系统把这一批回调都送完了。
    ///
    /// ⚠️ **必须调那个 completion,而且必须在主线程。** 不调的话系统认为
    /// App 没干完活,下次给的后台时间会更少 —— 一个不报错、只会越来越慢的惩罚。
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = systemCompletion
        systemCompletion = nil
        DispatchQueue.main.async { done?() }
    }
}

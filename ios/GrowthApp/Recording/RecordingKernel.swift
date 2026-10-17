import Accelerate
import AVFoundation
import Foundation
// 手表 target 共用这一份外壳(W1)。两边唯一的差别是「回到前台」那条通知,
// 见 `observeSystemEvents` ① 之前那一段。
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

// 录音内核的外壳(§六 录音内核)。
//
// 这个文件里**没有任何判断**:状态迁移在 `RecordingStateMachine`,切点在
// `BlockCutPolicy`,空洞在 `BlockLedger`。外壳只做三件 AVFoundation 的事 ——
// 配会话、起停引擎、把 PCM 转成 16k 单声道 AAC 写文件。这样切分是因为
// AVAudioSession 在单元测试里跑不起来,判断留在这里就等于没验收。
//
// 失败一律往 `onFailure` 抛,不吞(§3.2:兜底的 except 要么记录要么抛)。
// 录音是「一次没录上就永远补不回来」的东西,静默失败的代价不可逆。
final class RecordingKernel {

    // MARK: - 对外

    private(set) var state: RecordingState = .idle
    /// 任何一步失败都从这里出来。调用侧必须接,不接就是把失败藏起来了。
    var onFailure: ((Error) -> Void)?

    /// 状态变了就回调(在内部串行队列上发,界面自己切主线程)。
    ///
    /// 界面**不能**自己推状态:四类中断是系统发起的,界面根本看不见它们。
    /// 自己推的话,来一通电话之后界面显示「录音中」而引擎其实停了 ——
    /// 那正是本仓最怕的那种「看起来正常」。
    var onStateChange: ((RecordingState) -> Void)?

    /// 当前块已经录了多久。没有打开的块时是 nil(暂停中、未开始、已结束)。
    var currentBlockElapsed: TimeInterval? {
        queue.sync { blockStartedAt.map { Date().timeIntervalSince($0) } }
    }

    enum Failure: Error, CustomStringConvertible {
        case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)
        case bufferAllocationFailed
        case noOpenBlock
        case microphoneDenied
        case noInputAvailable(sampleRate: Double, channels: UInt32)
        /// 断了、但已经自己接上了。**这一场还在录。**
        case audioRecovered(gapSeconds: Int, attempt: Int)
        /// 连着接了几次都没换回一帧音频 —— 麦克风真的死了,这一场停了。
        case audioDead(attempts: Int)
        /// 🔴 麦克风在送数据,但**送的全是零**。断流看门狗抓不到它 —— 数据是来的。
        case silentInput(route: String)
        /// ⚠️ 2026-08-14 起**不再从看门狗抛出**:断流的第一反应是接上,不是判死。
        /// 留着是因为它还是一种可能的真实失败(引擎起得来但音频永远不来),
        /// 而删掉一个错误类型会让读代码的人以为这种情况不存在。
        case audioStalled(gapSeconds: Int)

        var description: String {
            switch self {
            case .converterUnavailable(let f, let t):
                return "建不出 \(f) → \(t) 的转换器 —— 硬件输入格式不被支持,这一场录不了"
            case .bufferAllocationFailed:
                return "转换缓冲区分配失败"
            case .noOpenBlock:
                return "没有打开的块却收到音频 —— 状态机与外壳不同步"
            case .microphoneDenied:
                return "没有麦克风权限,录不了。去「设置 → 隐私与安全性 → 麦克风」里打开"
            case .noInputAvailable(let rate, let ch):
                return "音频输入不可用(采样率 \(rate)、\(ch) 声道)—— "
                     + "多半是没有麦克风权限或没有可用输入设备"
            case .audioRecovered(let s, let n):
                // **不是报错,是告诉他这段有个洞。** 默不作声的话,麦克风每十秒
                // 掉一次、录出来是筛子,而用户全程无感 —— 「看起来完全正常」。
                return "录音断了 \(s) 秒,已经自动接上,还在录(第 \(n) 次)。"
                     + "这段时间没录上,纪要里会是个洞。"
            case .audioDead(let n):
                return "麦克风连着 \(n) 次都没能接上,这一场停了。"
                     + "**已经录下的那部分还在**,可以直接再按开始录新的一场。"
            case .silentInput(let route):
                return "⚠️ 正在录,但麦克风送来的**全是静音**(输入:\(route))。"
                     + "多半是蓝牙耳机被选成了输入、或别的 App 正占着麦克风。"
                     + "这段录下来会是空的 —— 处理一下再继续说。"
            case .audioStalled(let s):
                return "录音断了:已经 \(s) 秒没有收到麦克风数据,这一场已停止。"
                     + "**这段时间没有录上**。要继续请重新开始。"
            }
        }
    }

    // MARK: - 内部

    private let sessionDir: URL
    private let ledgerURL: URL
    private let probe: SilenceProbe
    /// ⚠️ **每次开录都换一个新的**,不复用。
    ///
    /// 复用同一个实例、只 stop/start 的写法在真机上崩过:路由一变就走
    /// `[stopEngine, finalizeBlock, startEngine, openBlock]`,而重起时
    /// `installTap` 抛 ObjC 异常 → Swift 接不住 → 整个进程 abort。
    /// 崩溃栈:`AVAudioEngineImpl::InstallTapOnNode` ← `startEngine()`
    /// (2026-08-13 真机,`GrowthApp-2026-08-13-162306.ips`)。
    /// 账本上的形态是「块只有 0–1 秒,然后 sessionStarted 再来一条」。
    ///
    /// 换新实例把所有「上一轮的残留状态」这一整类问题从结构上去掉,代价只是一次分配。
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.growth.recording", qos: .userInitiated)

    /// 最后一次收到麦克风数据的时刻。音频线程写、主线程读,所以上锁 ——
    /// 这一下的开销相对于同一个回调里的格式转换与写盘可以忽略。
    private let bufferClock = NSLock()
    private var _lastBufferAt: Date?
    private var lastBufferAt: Date? {
        get { bufferClock.lock(); defer { bufferClock.unlock() }; return _lastBufferAt }
        set { bufferClock.lock(); _lastBufferAt = newValue; bufferClock.unlock() }
    }
    private var stallTimer: Timer?

    /// 多久没数据算断流。缓冲区每 ~85ms 来一次(4096 帧 / 48kHz),
    /// 3 秒是 35 倍余量 —— 不会误报,又足够快。
    static let stallThreshold: TimeInterval = 3

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var blockSeq = 0
    private var blockStartedAt: Date?
    private var blockFileName: String?

    /// 16 kHz 单声道(§六 录音格式)。VAD 参数的采样率前提就是 16k,换了这个数
    /// 既有实测的保留率与字召回全部作废。
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1,
                                             interleaved: false)!

    /// AAC 32–64 kbps(§六 录音格式)。取中间的 48k:一天 8 小时 ≈ 173 MB。
    private let bitRate = 48_000

    /// 音量门。既当切点探针,又给界面提供「此刻有没有人在说话」。
    let energyGate = EnergyGate()

    /// 自己收尾时叫一声。**用户没按过结束,却看到「已结束」——
    /// 不说明原因的话他只会以为 App 崩了。** 与 `onFailure` 同一个理由。
    var onAutoStopped: (() -> Void)?

    /// 刚切完一块(账本已经落盘)。
    ///
    /// 🔴 **它存在的理由:录音期间是 iOS 唯一保证我们有 CPU 的窗口。**
    /// 在此之前,一场 32 分钟的录音要等用户按下「结束」才开始传 ——
    /// 7 块音频在录制中早就切好躺在盘上,却一直等着(08-18 实测:17:28 结束、
    /// 17:57 才建上传作业)。而按下结束之后,进程随时会被挂起。
    ///
    /// 用回调而不是让编排去轮账本:切块是**事件**,轮询是猜。
    var onBlockCut: (() -> Void)?

    /// 开场那条账本记录上打的来源。手机录音传 nil —— 账本一个字节都不变,
    /// 读出来照旧是 `recording`(见 `LedgerEntry.source`)。手表传 `watch`:
    /// 手机那边是**照抄**手表账本的,来源得在源头就写对(W1 spec 决定 2)。
    private let source: String?

    init(sessionDir: URL, probe: SilenceProbe? = nil, source: String? = nil) {
        self.sessionDir = sessionDir
        self.source = source
        self.ledgerURL = sessionDir.appendingPathComponent("ledger.jsonl")
        self.probe = probe ?? energyGate
        self.blockSeq = Self.nextBlockSeq(ledgerURL: ledgerURL)
        observeSystemEvents()
    }

    /// 下一个块号 = 账本里最大的 + 1。
    ///
    /// 下一个块号。**不变量只有一句:永远不返回一个会覆盖已有块文件的号。**
    ///
    /// ⚠️ 目录是按天分的,块号原来每次开 App 从 0 起 —— 同一天录第二场时
    /// `block-0000.m4a` 会**覆盖掉第一场的**。用户 2026-08-10 真机实测到过。
    ///
    /// 🔴 **为什么要同时看盘,而不是只信账本**(2026-08-18 复核):
    ///
    /// 上一版是「账本读不出来就从 0 起」,理由写的是「那种情况下 `relaunchReport`
    /// 本来就会抛,用户会先看到」。查下来那个理由有两层都不成立:
    /// ① **`ImportIngest` 也调这个函数,而导入路径上根本没有 `relaunchReport`**
    ///    —— 结论写下来了,而它的前提在第二个调用点不成立(铁律四的形状);
    /// ② 更要命的是**账本坏了根本不一定抛**:`BlockLedger.read` 对
    ///    「最后一行写了一半」是**合法容忍**的(App 被 jetsam 杀掉时的正常形态),
    ///    于是一个只剩半行的账本会**读成功、且零条目** ⇒ 照样回 0 ⇒ 照样覆盖。
    ///    只防「抛出」那条路,防不住这条。
    ///
    /// ⇒ 改成**取账本与磁盘两者的较大值**。文件名本身就是「已经有哪些块」的
    /// 第二份记录,账本怎么坏都不影响它。这样这一类失败**整类消失**,
    /// 而不是逐个去堵。
    static func nextBlockSeq(ledgerURL: URL) -> Int {
        let fromLedger = (try? BlockLedger.read(from: ledgerURL))
            .flatMap { $0.entries.compactMap(\.block?.seq).max() }
            .map { $0 + 1 } ?? 0
        return max(fromLedger, nextSeqOnDisk(dir: ledgerURL.deletingLastPathComponent()))
    }

    /// 扫目录里已有的 `block-%04d.m4a`,返回最大号 + 1(没有则 0)。
    ///
    /// **这是「已经有哪些块」的第二份记录。** 本地 m4a 是原始证据
    /// (声纹取段、重算、用户回听读的都是它),覆盖不可逆 —— 所以宁可多跳几个号,
    /// 也不能重号。号跳了没有任何坏处:块位置由账本里的时间戳定,不是由号定。
    static func nextSeqOnDisk(dir: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> Int? in
            guard name.hasPrefix("block-"), name.hasSuffix(".m4a") else { return nil }
            return Int(name.dropFirst("block-".count).dropLast(".m4a".count))
        }.max().map { $0 + 1 } ?? 0
    }

    /// 注册出去的观察者令牌。
    ///
    /// 🔴 **`addObserver(forName:object:queue:using:)` 注册的是一个令牌对象,不是 `self`**
    /// (`M2-审9`,2026-08-24)。原来这里写的是 `removeObserver(self)` ——
    /// 那条 API 只摘得掉 `addObserver(_:selector:...)` 那种,对块式注册**一个都摘不掉**。
    /// ⚠️ 它看起来像清理,实际什么都没做 —— 本仓最贵的那类代码。
    /// 后果在从前不明显(内核一个进程只建一次),而**跨午夜换目录之后**
    /// (`M2-审10`)每天都会新建一个内核 ⇒ 死观察者按天累积。
    private var observerTokens: [NSObjectProtocol] = []

    deinit {
        let nc = NotificationCenter.default
        observerTokens.forEach(nc.removeObserver)
    }

    // MARK: - 用户操作

    /// 开录之前**必须先要到麦克风权限**。
    ///
    /// 不要的话:输入节点报 0 声道 0 采样率,而拿这种格式装 tap 会让 AVFAudio
    /// **抛 ObjC 异常** —— Swift 的 `try` 接不住,进程直接 abort。
    /// 实测(2026-08-10 首次真跑)就是这样崩的:点「开始记录」→ 秒退回桌面。
    /// 权限被拒是**正常情况**,必须变成一条看得见的失败,不是崩溃。
    func start() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.onFailure?(Failure.microphoneDenied); return }
            self.dispatch(.userStart)
        }
    }
    func pause()  { dispatch(.userPause) }
    func resume() { dispatch(.userResume) }
    func stop()   { dispatch(.userStop) }

    // MARK: - 重开 App 时的空洞

    /// 这次路由变化要不要重起引擎。
    ///
    /// 只有**输入设备真的换了**才要重起 —— 输入格式变了,tap 与转换器都得重建。
    /// 其余的(我们自己改类别、系统的音量覆盖、唤醒)不动引擎:
    /// 每重起一次就切一个块、丢一小段音频,白切的代价是实打实的。
    static func needsEngineRestart(_ reason: AVAudioSession.RouteChangeReason) -> Bool {
        switch reason {
        case .oldDeviceUnavailable,        // 拔耳机 / AirPods 断开
             .newDeviceAvailable,          // AirPods 连上
             .routeConfigurationChange:    // 同一设备的输入配置变了
            return true
        case .categoryChange,              // 我们自己 setCategory 触发的 —— 不是真换设备
             .override, .wakeFromSleep, .noSuitableRouteForCategory, .unknown:
            return false
        @unknown default:
            // 新 reason 一律**不重起**:重起会切块丢音频,而未知 reason 多半无害。
            // 真有需要重起的新情况,会以「录不上」的形式暴露出来,那时再加。
            return false
        }
    }

    /// 读账本,算出上次停在哪、空了多久。账本读不出来时**抛**,不返回「一切正常」。
    static func relaunchReport(sessionDir: URL, now: Date = Date()) throws -> RelaunchReport {
        let (entries, _) = try BlockLedger.read(
            from: sessionDir.appendingPathComponent("ledger.jsonl"))
        return try BlockLedger.relaunchReport(entries: entries, now: now)
    }

    // MARK: - 事件 → 状态机 → 副作用

    private func dispatch(_ event: RecordingEvent) {
        queue.async { [self] in
            let t = RecordingStateMachine.next(state: state, event: event)
            let previous = state
            state = t.state
            for effect in t.effects {
                do {
                    try perform(effect)
                } catch {
                    // ⚠️ 副作用失败之后**状态不能继续声称在录**。
                    // 实测(2026-08-10 首次真跑)起引擎失败时状态条照样显示「录音中 00:06」
                    // 而引擎根本没起来 —— 「看起来完全正常」正是本仓最贵的那种失败。
                    // 起不来就是没在录,落回终态并把错抛给用户,别让计时器继续涨。
                    onFailure?(error)
                    abortToStopped()
                    if previous != .stopped { onStateChange?(.stopped) }
                    return
                }
            }
            if t.state != previous { onStateChange?(t.state) }
        }
    }

    /// 副作用炸了之后的收尾:引擎停掉、块作废、状态落 `stopped`。
    /// 这里的每一步都**尽力做完**,不因为其中一步再失败就跳过后面的。
    private func abortToStopped() {
        state = .stopped
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        blockStartedAt = nil
        blockFileName = nil
        try? BlockLedger.append(LedgerEntry(at: Date(), mark: .sessionEnded), to: ledgerURL)
    }

    private func perform(_ effect: RecordingEffect) throws {
        switch effect {
        case .mark(let mark):
            try BlockLedger.append(
                LedgerEntry(at: Date(), mark: mark,
                            source: mark == .sessionStarted ? source : nil), to: ledgerURL)
        case .startEngine:
            try startEngine()
            lastBufferAt = Date()      // 起点就是现在,否则第一秒会被误判成断流
            startStallTimer()
        case .stopEngine:
            stopStallTimer()
            engine.stop()
            // 不摘 tap:引擎实例本身马上会被换掉,而在一个已 stop 的引擎上
            // 摘 tap 正是 `installTap` 那类断言的相邻雷区。让它随实例一起走。
        case .openBlock:
            try openBlock()
        case .finalizeBlock(let hardCut):
            try finalizeBlock(hardCut: hardCut)
        }
    }

    // MARK: - 音频会话与引擎

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        // `.mixWithOthers` 是这一行里最要紧的选项(§六):不加的话,别的 App 一播
        // 音频就会以非 mixable 的方式抢占会话,把我们的录音直接打断。
        // `.allowBluetooth` 是为了 AirPods 能当输入 —— 中断矩阵里「AirPods 连断」
        // 这一类本来就假设它在用。
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .allowBluetooth])
        try session.setActive(true)

        // 换新引擎:上一轮的 tap、节点连接、内部格式缓存全部作废。
        // **必须在 setActive 之后**再取 inputNode —— 会话激活会改变硬件格式,
        // 在那之前拿到的格式是上一条路由的。
        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // ⚠️ 这道检查换掉的是一次**硬崩溃**:格式非法时 `installTap` 抛的是 ObjC 异常,
        // Swift 接不住,整个进程 abort(实测栈顶是 AUGraphNodeBaseV3::CreateRecordingTap)。
        // 先在这里拦下来,失败才有机会走 onFailure 被用户看见。
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw Failure.noInputAvailable(sampleRate: inputFormat.sampleRate,
                                           channels: inputFormat.channelCount)
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw Failure.converterUnavailable(from: inputFormat, to: targetFormat)
        }
        self.converter = converter

        // 真机上这一行崩过。留一条日志:万一还崩,崩溃日志前一行就是这些数,
        // 能直接对上是哪个断言(AVAudioEngine 的断言文本会打在它后面)。
        // ⚠️ 把**真实输入路由**也打出来。2026-08-17 抓到过整块 270 秒峰值为 0 的录音
        // (纯数字静音),而代码一行没改 —— 那种情况下唯一能指认原因的就是
        // 「当时选的是哪个输入」:蓝牙耳机被选成输入、或别的 App 占着麦克风时,
        // `.mixWithOthers` 拿到的就是一片零,而一切看起来完全正常。
        let route = session.currentRoute.inputs
            .map { "\($0.portType.rawValue)/\($0.portName)" }.joined(separator: ",")
        NSLog("[growth] installTap sr=%.0f ch=%u in=%@ fmt=%@",
              inputFormat.sampleRate, inputFormat.channelCount, route, "\(inputFormat)")
        currentInputRoute = route.isEmpty ? "(没有输入设备)" : route
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buf, _ in
            self?.consume(buf)
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: - 断流看门狗

    /// **麦克风悄悄停了,是这个产品最贵的一种失败** —— 界面显示「录音中」、
    /// 计时在涨,而一个字节都没录进去。用户要到晚上打开纪要才发现今天是空的。
    ///
    /// 系统只在**它知道**的中断上给通知(来电、Siri、被抢占)。会话被降活、
    /// tap 停止投递这类情况**没有任何通知**,只能自己发现:数据不来了就是断了。
    ///
    /// 两个检查时机,缺一不可:
    ///   · 定时(App 活着但音频死了)
    ///   · **回到前台时**(App 被挂起期间连定时器都不跑,回来才发现刚才那段没了)
    /// 最多连着自己接几次。
    ///
    /// 3 次 ≈ 十秒左右的尝试。再多没意义:**引擎能起来但一帧不来**,
    /// 多试十次也是一样的结果,而每试一次就多一个空块和一条账本记录 ——
    /// 到头来界面一直显示「录音中」而什么都没录,正是要防的那件事。
    static let maxStallRecoveries = 3

    /// 音频线程送过来的帧数。**单调只增**,用来回答一个问题:
    /// 「上次重起之后,到底有没有真的收到过音频?」
    ///
    /// ⚠️ 不能拿 `lastBufferAt` 回答 —— `perform(.startEngine)` 会把它重置成此刻
    /// (那是对的:否则重起后的第一秒会被误判成断流)。于是「刚重起」和
    /// 「重起后真收到了音频」在它眼里一模一样,计数永远清零 → 无限重起。
    /// 当前选中的输入路由。全零时它是唯一能指认原因的东西。
    private var currentInputRoute: String?
    /// 连续为零的采样点数。
    private var silentFrames: UInt64 = 0
    private var silenceReported = false

    private var bufferCount: UInt64 = 0
    private var bufferCountAtLastRecovery: UInt64 = 0
    private var stallRecoveries = 0

    func checkForStall(now: Date = Date()) {
        guard state == .recording, let last = lastBufferAt else { return }
        let gap = now.timeIntervalSince(last)
        guard gap >= Self.stallThreshold else { return }

        // 上次重起之后真的收到过音频 = 那次续成功了,重新计数。
        if bufferCount > bufferCountAtLastRecovery { stallRecoveries = 0 }

        guard stallRecoveries < Self.maxStallRecoveries else {
            dispatch(.audioDead(gapMs: Int(gap * 1000)))
            onFailure?(Failure.audioDead(attempts: stallRecoveries))
            stallRecoveries = 0
            return
        }

        stallRecoveries += 1
        bufferCountAtLastRecovery = bufferCount
        dispatch(.audioStalled(gapMs: Int(gap * 1000)))
        // ⚠️ 走 `onFailure` 报一句**接上了**的话,而不是默不作声。
        // 默不作声的后果是:麦克风每十秒掉一次,录出来是筛子,而用户全程无感 ——
        // 「看起来完全正常」。这一句不是报错,是告诉他这段有个洞。
        onFailure?(Failure.audioRecovered(gapSeconds: Int(gap), attempt: stallRecoveries))
    }

    // MARK: - 全零看门狗

    /// 🔴 **麦克风在送数据,送的全是零。**
    ///
    /// 断流看门狗管的是「数据不来了」;这一条管的是它的**孪生兄弟**:
    /// 数据照来、时长正确、文件照写、账本与任务表全绿 —— 而里面一个字节的声音都没有。
    /// 后者更危险,因为**没有任何一处会报错**。
    ///
    /// 2026-08-17 真机抓到:一块 270 秒的录音,峰值 `0/32767`,
    /// 每一个采样点都是零(同一天更早的另一块是峰值 25852、94% 有声)。
    /// 而 `RecordingKernel` 一行没改 —— 是路由或占用状态变了。
    ///
    /// ## 为什么判据是「精确的零」而不是「很安静」
    ///
    /// 再安静的房间也有底噪,麦克风会给出非零的小数值。**恒等于零只有一个来源:
    /// 输入根本没接上** —— 蓝牙耳机被选成输入却不供麦、别的 App 占着麦克风、
    /// 系统级静音。用「很安静」当判据会在图书馆里误报,而那种误报几次之后
    /// 这条提示就没人看了。
    ///
    /// ## 为什么不停录音
    ///
    /// 用户 2026-08-17 拍板:别自动停。停了也解决不了 —— 能解决的动作
    /// (拔掉耳机、关掉占麦的 App)只有人能做。所以**只喊,不停**。
    private func checkForDigitalSilence(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        var peak: Float = 0
        vDSP_maxmgv(ch, 1, &peak, vDSP_Length(buffer.frameLength))

        guard peak == 0 else { silentFrames = 0; silenceReported = false; return }
        silentFrames &+= UInt64(buffer.frameLength)

        // 连续 5 秒精确为零才喊一次。**只喊一次** —— 每 4096 帧喊一遍
        // 会把状态条刷成一片红,而那和不喊一样没用。
        let threshold = UInt64(buffer.format.sampleRate * 5)
        if silentFrames >= threshold, !silenceReported {
            silenceReported = true
            onFailure?(Failure.silentInput(route: currentInputRoute ?? "未知"))
        }
    }

    private func startStallTimer() {
        guard stallTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkForStall() }
        // **必须挂 .common** —— 默认模式下用户一滚列表,定时器就不跑了,
        // 而「用户在滚屏」恰好是最不该漏报的时候。
        RunLoop.main.add(t, forMode: .common)
        stallTimer = t
    }

    private func stopStallTimer() {
        stallTimer?.invalidate()
        stallTimer = nil
        lastBufferAt = nil
    }

    /// 音频线程上只做两件事:写盘、问一句「该切了吗」。判断在 `BlockCutPolicy`。
    private func consume(_ buffer: AVAudioPCMBuffer) {
        lastBufferAt = Date()
        bufferCount &+= 1          // 单调只增:看门狗靠它判「重起之后真收到音频没有」
        checkForDigitalSilence(buffer)
        // 喂音量门。**在写盘之前** —— 写盘可能抛,而抛了之后这一帧的能量
        // 就永远进不了底噪估计,地板会慢慢失真。
        if let ch = buffer.floatChannelData?[0] {
            energyGate.feed(ch, count: Int(buffer.frameLength))
        }
        do {
            try write(buffer)
            guard let startedAt = blockStartedAt else { return }
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            if let cut = BlockCutPolicy.shouldCut(elapsedMs: elapsedMs, probe: probe) {
                dispatch(.blockBoundaryReached(hardCut: cut.hardCut))
            }
            // 🔴 **忘了按结束时自己收尾**(PRD §4.1.5:连续静音 >2 小时)。
            // 判据只看静音、不看总时长 —— 按总时长收尾会把一场真的三小时会议
            // 劈断,那是不可逆的;多录几小时只是费空间。两种错法差着量级。
            //
            // ⚠️ 放在切块判断**之后**:先让这一块正常收口,再结束这一场。
            // 反过来的话最后那一块会在 `finalizeBlock` 之前被丢掉。
            if AutoStopPolicy.shouldStop(silentForMs: probe.silentForMs) {
                dispatch(.autoStopped)
                onAutoStopped?()
            }
        } catch {
            onFailure?(error)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        // 收尾期间音频线程还会送一两帧过来 —— `removeTap` 不保证同步摘干净。
        // 那几帧的时间已经在块尾之后,丢掉是对的,**不是失败**。
        // 但「状态说在录、却没有打开的块」是真的不一致,那个要抛。
        guard file != nil, converter != nil else {
            if state == .recording { throw Failure.noOpenBlock }
            return
        }
        guard let file, let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw Failure.bufferAllocationFailed
        }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        if out.frameLength > 0 { try file.write(from: out) }
    }

    // MARK: - 块

    private func openBlock() throws {
        let name = String(format: "block-%04d.m4a", blockSeq)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        file = try AVAudioFile(forWriting: sessionDir.appendingPathComponent(name),
                               settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                          AVSampleRateKey: targetFormat.sampleRate,
                                          AVNumberOfChannelsKey: 1,
                                          AVEncoderBitRateKey: bitRate])
        blockFileName = name
        blockStartedAt = Date()
    }

    /// 收尾:先把文件关掉(AVAudioFile 在 deinit 时才 flush),再记账。
    /// 顺序反了的话账本里会有一条指向尚未落完的文件的记录。
    private func finalizeBlock(hardCut: Bool) throws {
        guard let startedAt = blockStartedAt, let name = blockFileName else { return }
        file = nil
        blockStartedAt = nil
        blockFileName = nil

        try BlockLedger.append(
            LedgerEntry(block: BlockRecord(seq: blockSeq, startedAt: startedAt,
                                           endedAt: Date(), hardCut: hardCut, fileName: name)),
            to: ledgerURL)
        blockSeq += 1
        // **落盘之后才喊。** 反过来的话编排会去读一条还不存在的账本记录,
        // 而它读到的是「这一场一块音频都没有」。
        onBlockCut?()
    }

    // MARK: - 四类中断(§六)

    #if os(watchOS)
    private static let didBecomeActive = WKApplication.didBecomeActiveNotification
    #else
    private static let didBecomeActive = UIApplication.didBecomeActiveNotification
    #endif

    private func observeSystemEvents() {
        let nc = NotificationCenter.default

        // ⚠️ **回到前台必须查一次。** App 被挂起期间连定时器都不跑 ——
        // 如果后台那段音频其实停了,只有回来这一刻能发现。
        // 不查的话,界面会带着一个「录音中」和一段空白继续跑下去。
        observerTokens.append(
            nc.addObserver(forName: Self.didBecomeActive,
                           object: nil, queue: .main) { [weak self] _ in
            self?.checkForStall()
        })

        // ① 来电 / Siri / 被别的 App 抢占
        observerTokens.append(
            nc.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self?.dispatch(.interruptionBegan)
            case .ended:
                let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: opts)
                    .contains(.shouldResume)
                self?.dispatch(.interruptionEnded(shouldResume: shouldResume))
            @unknown default:
                break
            }
        })

        // ② 路由切换(拔耳机、AirPods 断开)
        //
        // ⚠️ **必须按 reason 分流。** 我们自己 `setCategory` + `setActive` 就会触发一次
        // `.categoryChange` —— 不过滤的话,开录瞬间收到它,状态机按「AirPods 连断」
        // 处理:刚起的引擎立刻被停掉重起,顺手切出一个 **0 秒的空块**。
        // 真机实测(2026-08-10 首跑)每次开录都留下一个 557 字节的 block-0000。
        // 修法不是加延时躲开它 —— 延时是猜的,而 reason 是系统明说的。
        observerTokens.append(
            nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            guard Self.needsEngineRestart(reason) else { return }
            // 每重起一次就切一个块。留一行原因:开录瞬间多出一个 0 秒块时,
            // 只有它能说清是哪种路由变化触发的(手表上 2026-10-12 就是靠它查的)。
            NSLog("[growth] routeChange restart reason=%lu", raw)
            self?.dispatch(.routeChanged)
        })

        // ③ 引擎配置变化(AirPods 连上时输入格式变了,图会失效)
        //
        // 🔴 **`object:` 必须是 nil,不能是 `engine`**(`M2-审9`,2026-08-24)。
        // 这里在 `init` 里注册,那一刻的 `engine` 是第 99 行那个初始实例;
        // 而 `startEngine()` **每次开录都换一个新的**(见 `engine` 的注释)。
        // `NotificationCenter` 按对象身份过滤 ⇒ 绑死初始实例之后,
        // **从第一次开录起这个观察者再也不会触发**。不是「可能漏」,是必然不响。
        //
        // 表现为什么难发现:AirPods 连断还有 `routeChange`(② 那条,`object: nil`)
        // 兜着,所以大多数时候链路照样重建 —— 只有「路由没变而输入格式变了」
        // 那一类会静默漏掉,而它的现场与「录了但没声音」一模一样。
        //
        // 改成 `object: nil` + **在内核自己的队列上核对来源**:
        // `engine` 只在 `queue` 上被换,跨线程读它是数据竞争。
        observerTokens.append(
            nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                           object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let sender = note.object as AnyObject?
            queue.async { [weak self] in
                guard let self, sender === self.engine else { return }
                NSLog("[growth] engineConfigurationChange restart")
                self.dispatch(.engineConfigurationChanged)
            }
        })

        // ④ 内存回收:进程被 jetsam 杀掉,**没有回调**。
        //    所以这一类不在这里处理 —— 它靠 `relaunchReport` 在下次启动时算出来。
        //    §六 把这件事说死了:系统不会自动重启录音,空洞持续到用户重开 App。
    }
}

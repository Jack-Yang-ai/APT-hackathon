import XCTest
import GRDB
@testable import GrowthApp

/// `processing_events.trigger` 必须是**真值**(M1-4c 收尾,2026-08-18)。
///
/// ## 这张表存在的唯一理由就是这一列
///
/// v12 迁移的原话:「没有它,『后台处理』这件事无法被证明:打开 App 看到出稿了,
/// 分不清是后台干完的,还是『我一打开它才开始干』。」两种解释在界面上
/// **长得一模一样**,而「凌晨 3:14 由后台唤醒跑完」是一个可检验的事实。
///
/// ## 抓到的形状:一半诚实,一半不诚实
///
/// 五处事件把 trigger 写死成 `.foreground`,而它们所在的代码路径在
/// `BGProcessingTask` 唤醒下**同样会走**:
/// · `ProcessingPump.assemble` 四条(保留区间表读不出 / 报文解不开 /
///   块在账本里定不了位 / 缺块按 partial 冻结)
/// · `BackgroundUploadCenter.handOff` 两条(M1-4d 的 VAD 保留率、VAD 不可用)
///
/// 半修比不修更糟:表里有的行诚实、有的行不诚实,而**读的人分不出来** ——
/// 那时这一列不只是没用,是会主动误导。所以这组测试打的是**同一拍里
/// 每一条事件**,不是挑一条看。
///
/// ## 为什么不直接调 `ProcessingPump.run(trigger: .background,…)`
///
/// `run` 内部自己造依赖,而依赖里的 `proxy` 走 `ProxySettings.config` ——
/// 测试 target 没有宿主 App、读不到 Keychain ⇒ `proxy` 恒为 nil ⇒
/// 转写腿在第一道 guard 上就 park 了,永远走不到冻结那一步。
/// 所以这里拿**生产的依赖工厂** `dependencies(in:trigger:)` 造依赖,
/// 只替掉那两个要网络的口子(`proxy` / `transport`),其余全是生产接线 ——
/// `freeze` 闭包、`assemble`、`writeClusterTags` 都是真的那一份。
final class TriggerTruthTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    /// 与别的 suite 错开的一天 —— 它们共用 `recordingsRoot` 这个真目录,
    /// 撞同一天的话 teardown 会把对方的账本删掉。
    private let day = "2026-08-20"
    private let base = Date(timeIntervalSince1970: 1_786_400_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)

        // 账本两块 —— 它是「这一场到底录了哪些块」的唯一真相源,缺块靠它作差。
        dir = ProcessingPump.recordingsRoot.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }

        let ledger = dir.appendingPathComponent("ledger.jsonl")
        try BlockLedger.append(LedgerEntry(at: base, mark: .sessionStarted), to: ledger)
        for seq in 0..<2 {
            try BlockLedger.append(LedgerEntry(block: BlockRecord(
                seq: seq,
                startedAt: base.addingTimeInterval(Double(seq) * 300),
                endedAt: base.addingTimeInterval(Double(seq + 1) * 300),
                hardCut: true, fileName: "block-\(seq).m4a")), to: ledger)
        }
        try BlockLedger.append(
            LedgerEntry(at: base.addingTimeInterval(600), mark: .sessionEnded), to: ledger)

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (1, ?, ?, ?, 'recording', 'closed')
                """, arguments: [SessionBridge.iso(base),
                                 SessionBridge.iso(base.addingTimeInterval(600)), day])
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 夹具

    private func payload(_ text: String) -> String {
        #"{"data":{"result":[{"utterances":[{"start_time":1000,"end_time":4000,"text":"\#(text)","speaker":{"id":"speaker_0"}}]}]}}"#
    }

    /// 一块好报文 + 一块解不开的,外加一个**待跑的转写任务**。
    ///
    /// 两块都是 `done` ⇒ 这一拍不提交、不轮询(一次网络都不发),
    /// 直接落到冻结那一步,于是 `assemble` 会记两条事件:
    /// 「块 1 的转写报文解不开」与「某场次 缺 1 块,按 partial 冻结」。
    private func seedTwoBlocksOneUnparseable() throws {
        // ⚠️ 少了这一行 `tick` 会 `nextRunnable == nil` 直接回 `.idle`,
        // 事件表空空如也 —— 而空表会让「每一条都得说后台唤醒」那句恒真。
        // 上面那两条「确实记了事件」的断言就是为挡这个假绿而在的。
        try TaskQueue.enqueue(kind: ProcessingOrchestrator.Kind.transcribe, sessionID: 1,
                              now: SessionBridge.iso(base), in: dbQueue)
        try ASRJobStore.claim(sessionID: 1, blockSeq: 0, remoteID: "r0",
                              now: SessionBridge.iso(base), in: dbQueue)
        try ASRJobStore.finish(sessionID: 1, blockSeq: 0, resultJSON: payload("第零块说了这句"),
                               now: SessionBridge.iso(base), in: dbQueue)
        try ASRJobStore.claim(sessionID: 1, blockSeq: 1, remoteID: "r1",
                              now: SessionBridge.iso(base), in: dbQueue)
        try ASRJobStore.finish(sessionID: 1, blockSeq: 1, resultJSON: "{ 报文形状变了",
                               now: SessionBridge.iso(base), in: dbQueue)
    }

    /// 生产接线,只把要网络的两个口子换掉。
    private func productionDeps(trigger: ProcessingEvents.Trigger,
                                transport: UploadTransport? = nil)
        -> ProcessingOrchestrator.Dependencies {
        var d = ProcessingPump.dependencies(in: dbQueue, trigger: trigger)
        // 转写腿第一道 guard 看它。给一个值只是为了越过闸 —— 这一拍不会发请求
        // (没有待提交的块、没有待轮询的作业),所以这个地址永远不会被访问到。
        d.proxy = .init(baseURL: URL(string: "https://example.invalid")!, token: "t")
        if let transport { d.transport = transport }
        d.pollInterval = 0
        return d
    }

    /// 跑一拍,把这一拍写进事件表的所有行取出来。
    private func tickAndReadEvents(trigger: ProcessingEvents.Trigger)
        async throws -> [ProcessingEvents.Event] {
        _ = try await ProcessingOrchestrator.tick(
            now: base, deps: productionDeps(trigger: trigger), in: dbQueue)
        return try ProcessingEvents.recent(limit: 50, in: dbQueue)
    }

    // MARK: - 🔴 后台唤醒下跑一拍,事件必须说「后台唤醒」

    /// **这条测试就是这次修复的证明。** 修之前它必红:
    /// 同一拍里那两条事件都会写「前台」,而这一拍是 `BGProcessingTask` 叫起来的。
    func testATickUnderBackgroundWakeRecordsBackgroundNotForeground() async throws {
        try seedTwoBlocksOneUnparseable()
        let events = try await tickAndReadEvents(trigger: .background)

        // ① 这一拍**确实**记了事件 —— 没有这一句,断言 ② 在空表上恒绿(假绿)。
        XCTAssertTrue(events.contains { $0.outcome.contains("转写报文解不开") },
                      "没记「报文解不开」那条 —— 这一拍根本没走到 assemble,"
                      + "下面那条断言是空转的:\(events.map(\.outcome))")
        XCTAssertTrue(events.contains { $0.outcome.contains("缺 1 块") },
                      "没记「缺块」那条:\(events.map(\.outcome))")

        // ② 这一拍写下的**每一条**都得说「后台唤醒」。
        //    挑一条看是不够的 —— 五处里改一部分正是要挡的那种半修。
        let liars = events.filter { $0.trigger != "后台唤醒" }
        XCTAssertEqual(liars, [],
                       "后台唤醒跑的一拍,却有事件自称「\(liars.map(\.trigger))」 —— "
                       + "打开 App 看到出稿时,分不清是后台干的还是刚打开才干的,"
                       + "而分开这两件事是 processing_events 存在的唯一理由")
    }

    /// **反面那一半。** 少了它,把 trigger 写死成 `.background` 也能让上面那条绿 ——
    /// 那只是把谎话换了个方向。
    func testTheSameTickUnderForegroundStillSaysForeground() async throws {
        try seedTwoBlocksOneUnparseable()
        let events = try await tickAndReadEvents(trigger: .foreground)

        XCTAssertTrue(events.contains { $0.outcome.contains("转写报文解不开") },
                      "这一拍没走到 assemble,断言是空转的:\(events.map(\.outcome))")
        XCTAssertEqual(events.filter { $0.trigger != "前台" }, [],
                       "前台跑的一拍却说是后台唤醒 —— trigger 被写死成另一个常量了")
    }

    /// 传输回调那条腿同理:它是**第三种**来路,不是「前台」的别名。
    /// 回调可能发生在系统为送回调而冷启动的进程里 —— 那时连界面都没有。
    func testTheTransferCallbackLegIsNotFlattenedIntoForeground() async throws {
        try seedTwoBlocksOneUnparseable()
        let events = try await tickAndReadEvents(trigger: .transferCallback)
        XCTAssertTrue(events.contains { $0.outcome.contains("转写报文解不开") },
                      "这一拍没走到 assemble:\(events.map(\.outcome))")
        XCTAssertEqual(events.filter { $0.trigger != "传输回调" }, [],
                       "三种来路被压成了两种")
    }

    // MARK: - 🔴 上传腿:真值要一路交到 `handOff` 手里

    /// M1-4d 那两条事件(VAD 保留率、VAD 不可用)记在
    /// `BackgroundUploadCenter.handOff` 里,而它要真音频 + 真 URLSession,
    /// 单测跑不起来(这正是 `UploadTransport` 这层抽象存在的理由)。
    ///
    /// 能测、也**必须**测的是那条线本身:这一拍的 trigger 有没有一路交到
    /// `handOff` 手里。交到了,那两条事件就没有别的东西可写;
    /// 交不到,生产实现只能自己编一个 —— 编出来的就是原来那个 `.foreground`。
    func testTheUploadLegHandsTheRealTriggerDownToTheTransport() async throws {
        final class TriggerSpy: UploadTransport, @unchecked Sendable {
            var seen: [ProcessingEvents.Trigger] = []
            func handOff(fileURL: URL, to key: String, tag: String,
                         trigger: ProcessingEvents.Trigger) throws {
                seen.append(trigger)
            }
        }
        let spy = TriggerSpy()
        try BlockUploader.enqueue(sessionID: 1, now: SessionBridge.iso(base), in: dbQueue)

        _ = try await ProcessingOrchestrator.tick(
            now: base,
            deps: productionDeps(trigger: .background, transport: spy), in: dbQueue)

        XCTAssertEqual(spy.seen, [.background, .background],
                       "上传腿交给传输层的 trigger 是 \(spy.seen) —— "
                       + "后台唤醒下裁的段会在事件表里自称「前台」")
    }

    // MARK: - 🔴 源码闸:别再往回写死

    /// 数据断言只能证明「今天这三条路是对的」,挡不住第四个记事件的地方
    /// (仓规 §3.1 第四条:对撞优先扫源码)。这三个文件里的每一条事件
    /// 都在「可能被后台唤醒跑到」的路径上,**没有一个合法的 `.foreground` 字面量**。
    ///
    /// ⚠️ 不扫 `ProcessingOrchestrator.swift`:它的 `retrySession` 有一条真的
    /// `.foreground`(用户当面点「再试一次」),扫了会恒红。
    // MARK: - 真值从应用状态读(M1-29)

    /// App 不在前台时,那一拍必须记「后台定时器」,**不许记「前台」**。
    ///
    /// 🔴 触发这条的现场很具体:2026-08-19 读 08-18 的事件表,
    /// **凌晨 4:27:48 有一条标着「前台」** —— 而那个点用户在睡觉。
    @MainActor
    func testBackgroundStateIsNotReportedAsForeground() {
        let saved = ProcessingEvents.appStateProvider
        defer { ProcessingEvents.appStateProvider = saved }

        ProcessingEvents.appStateProvider = { .background }
        XCTAssertEqual(ProcessingEvents.currentTrigger, .backgroundTimer, """
            App 在后台却记成了前台 —— 判「后台到底跑没跑」时会把后台读成前台。
            """)
        ProcessingEvents.appStateProvider = { .inactive }
        XCTAssertEqual(ProcessingEvents.currentTrigger, .backgroundTimer,
                       "`.inactive`(比如来电覆盖)也不是前台")
        // 反面:真前台就该是前台,否则上面两条证明不了任何东西。
        ProcessingEvents.appStateProvider = { .active }
        XCTAssertEqual(ProcessingEvents.currentTrigger, .foreground)
    }

    /// 「后台定时器」是**单独一档**,不并进「后台唤醒」。
    ///
    /// 后者的定义是「`BGProcessingTask` 把 App 叫起来了」—— 一个具体的机制;
    /// 前者是「进程因为别的原因醒着,界面恰好还在」。并进去等于**重犯这条任务
    /// 正在修的那个错**:两件不同的事记成同一个值。
    func testBackgroundTimerIsItsOwnBucket() {
        XCTAssertNotEqual(ProcessingEvents.Trigger.backgroundTimer,
                          ProcessingEvents.Trigger.background)
        XCTAssertEqual(ProcessingEvents.Trigger.backgroundTimer.rawValue, "后台定时器")
    }

    /// 🔴 **泵这条腿不许拿字面量当 trigger**(M1-29)。
    ///
    /// ⚠️ **不能把整个 `RecordingViewModel.swift` 加进 guarded 名单** ——
    /// 它里面有**两处合法**的 `.foreground`(用户当面点「重新认人」「移出记忆」),
    /// 扫全文件会恒红。这正是板上写的那句:源码闸扫的是「有没有写死」,
    /// **不是「写的对不对」**。
    ///
    /// ⇒ 只钉一处:`ProcessingPump.run` 的 trigger 必须是**算出来的**,不是写死的。
    /// 上一版写死 `.foreground`,而这个方法在后台也会被调到
    /// (录音在后台继续切块 → `onBlockCut`;界面还活着时 30 秒定时器照样响)——
    /// 于是凌晨 4:27 的事件表里出现了一条「前台」,而那时用户在睡觉。
    func testThePumpLegComputesItsTriggerInsteadOfHardcodingIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf:
            root.appendingPathComponent("GrowthApp/Presentation/RecordingViewModel.swift"),
            encoding: .utf8)
        XCTAssertFalse(src.isEmpty, "读不到 RecordingViewModel —— 这条断言在空转")
        XCTAssertFalse(code(of: src).contains("ProcessingPump.run(trigger: .foreground"), """
            泵又被写死成前台了。它在后台也会被调到,而「用户打开了 App」与
            「进程被系统唤醒了一下」记成同一个值之后,判「后台到底跑没跑」
            就再也判不了 —— 而 M1-19 的两跑验收正是靠这一列判的。
            """)
    }

    func testNobodyHardcodesForegroundOnThePathsBackgroundAlsoRuns() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let guarded = ["GrowthApp/Upload/ProcessingPump.swift",
                       "GrowthApp/Upload/BackgroundUploadCenter.swift",
                       "GrowthApp/Upload/BlockUploader.swift",
                       // 2026-08-19 加:M1-9b 把声纹链接进泵之后,后台唤醒到得了它。
                       // 那个文件顶上早写着「接进流水线的那一刻就把它加进 guarded」——
                       // 这一行就是照它办的。
                       "GrowthApp/Voiceprint/VoiceprintChain.swift"]

        var offenders: [String] = []
        for rel in guarded {
            let url = root.appendingPathComponent(rel)
            let src = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(src.isEmpty, "\(rel) 读不到 —— 这条断言在空转")
            if code(of: src).contains("trigger: .foreground") { offenders.append(rel) }
        }
        XCTAssertEqual(offenders, [],
                       "这些文件把 trigger 写死了。它们在 BGProcessingTask 唤醒下同样会跑,"
                       + "写死之后事件表里一半诚实一半不诚实,而读的人分不出来:\(offenders)")
    }

    /// 上面那条**自己得能红** —— 去注释的处理不能把代码也吃掉。
    func testTheCommentStripperKeepsCode() {
        XCTAssertTrue(code(of: "record(trigger: .foreground)  // 说明")
            .contains("trigger: .foreground"))
        XCTAssertFalse(code(of: "/// 不许写 trigger: .foreground")
            .contains("trigger: .foreground"))
    }

    /// 去掉行注释与文档注释,只留会被编译的部分 ——
    /// 「解释为什么不许这么写」和「这么写了」必须分得开。
    private func code(of source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }
}

import XCTest
import AVFoundation
@testable import GrowthApp

/// 重开 App 那句提示的文案口径(PRD §4.1.3 异常表)。
///
/// 这里打的是**三种情况必须说不同的话**:正常收尾 / 你自己暂停了 / 录音被打断了。
/// 压成一句「中断过 N 分钟」的话,用户主动按的暂停会被报成故障 ——
/// 几次之后这条提示就没人看了,而它是「录音停了没人知道」的唯一出口。
@MainActor
final class RecordingNoticeTests: XCTestCase {

    private func report(clean: Bool = false, gapMs: Int = 0,
                        paused: Bool = false, lastBlock: Int? = 0) -> RelaunchReport {
        RelaunchReport(cleanShutdown: clean, gapMs: gapMs,
                       lastBlockSeq: lastBlock, endedWhilePaused: paused)
    }

    func testCleanShutdownSaysNothing() {
        XCTAssertNil(RecordingViewModel.noticeText(for: report(clean: true)))
    }

    // MARK: - 被杀掉的那一场要补收尾

    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// App 被杀掉之后账本里那一场永远停在「开着」,首页那张卡就一直显示「记录中 · N 分」——
    /// 而根本没有在录(2026-08-14 模拟器实拍抓到的)。
    /// 按 PRD §4.1.3「被回收后系统不会自动重启录音」,那一场事实上就是结束了。
    func testAbandonedSessionGetsSealedOnRelaunch() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("ledger.jsonl")
        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        try BlockLedger.append(LedgerEntry(at: t0, mark: .sessionStarted), to: url)
        try BlockLedger.append(LedgerEntry(at: t0.addingTimeInterval(300), mark: .interrupted),
                               to: url)

        let vm = RecordingViewModel(sessionDir: dir, database: nil)
        vm.checkRelaunchGap(now: t0.addingTimeInterval(900))

        let (entries, _) = try BlockLedger.read(from: url)
        XCTAssertEqual(entries.last?.kind, SessionMark.sessionEnded.rawValue,
                       "被杀掉的那一场没补上收尾 —— 首页会一直说它在录")
        XCTAssertEqual(entries.last?.at, t0.addingTimeInterval(300),
                       "收尾时间戳该是账本最后观察到的那一刻,不是 now —— "
                     + "用 now 等于声称这中间一直在录,而那段恰恰是空洞")
        XCTAssertEqual(BlockLedger.sessions(entries: entries).first?.isOpen, false)
    }

    /// ⚠️ **顺序陷阱**:收尾之后账本就是「正常结束」了,这时候再算提示什么都报不出来。
    /// 所以必须先算提示再收尾 —— 这条钉住那个顺序。
    func testNoticeIsComputedBeforeSealingNotAfter() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("ledger.jsonl")
        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        try BlockLedger.append(LedgerEntry(at: t0, mark: .sessionStarted), to: url)

        let vm = RecordingViewModel(sessionDir: dir, database: nil)
        vm.checkRelaunchGap(now: t0.addingTimeInterval(600))

        XCTAssertNotNil(vm.relaunchNotice,
                        "先收尾再算提示的话,这里会是 nil —— 用户永远不知道断过")
        XCTAssertTrue(vm.relaunchNotice?.contains("中断") == true, vm.relaunchNotice ?? "nil")
    }

    /// 正常收尾的账本**不许再加一条** —— 补一条重复的收尾会把那一场的时长算乱。
    func testCleanlyEndedLedgerIsLeftAlone() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("ledger.jsonl")
        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        try BlockLedger.append(LedgerEntry(at: t0, mark: .sessionStarted), to: url)
        try BlockLedger.append(LedgerEntry(at: t0.addingTimeInterval(60), mark: .sessionEnded),
                               to: url)

        let vm = RecordingViewModel(sessionDir: dir, database: nil)
        vm.checkRelaunchGap(now: t0.addingTimeInterval(600))

        let (entries, _) = try BlockLedger.read(from: url)
        XCTAssertEqual(entries.count, 2, "正常收尾的账本被多加了一条")
    }

    // MARK: - M2-审10:跨午夜

    /// 🔴 **App 不重启地跨过午夜之后,新场次必须写进新那一天。**
    ///
    /// `RootView` 用 `@StateObject` 只建一次 `RecordingViewModel`,而原来
    /// `sessionDir` 是 `let`、在 `init` 里按当天算死 ⇒ 凌晨录的东西全落进昨天的目录,
    /// `todayKey` 也继续是昨天。后果不只是「日期不好看」:场次错日、首页「今天」
    /// 不完整、**7 天音频保留期与按日统计一起偏**,而没有任何东西会报错。
    func testANewDayGetsANewDirectoryWithoutRestartingTheApp() throws {
        // ⚠️ **边界要按本地时区造。** `defaultSessionDir` 用的是本地 `DateFormatter`,
        // 拿 UTC 的 23:59 当边界的话,在 +08:00 上其实是当天早上八点 —— 根本没跨天,
        // 而断言会红得像代码坏了。(第一版就是这么写错的。)
        let midnight = Calendar.current.startOfDay(
            for: Date(timeIntervalSince1970: 1_786_000_000))
        var fake = midnight.addingTimeInterval(23 * 3600 + 59 * 60)   // 本地 23:59
        let vm = RecordingViewModel(sessionDir: nil, database: nil, clock: { fake })
        let before = vm.todayKey

        fake = fake.addingTimeInterval(120)          // 本地 00:01,翻篇了
        vm.refreshToday()

        XCTAssertNotEqual(vm.todayKey, before,
                          "跨过午夜之后「今天」还是昨天:\(vm.todayKey)")
        XCTAssertEqual(vm.todayKey,
                       RecordingViewModel.defaultSessionDir(now: fake).lastPathComponent)
    }

    /// **同一天之内不许换目录** —— 换了等于每次刷新都重建一台内核。
    func testTheDirectoryIsStableWithinTheSameDay() throws {
        // 本地 10:00 起步,加一小时仍在同一天(同上:边界按本地时区造)
        var fake = Calendar.current.startOfDay(
            for: Date(timeIntervalSince1970: 1_786_000_000)).addingTimeInterval(10 * 3600)
        let vm = RecordingViewModel(sessionDir: nil, database: nil, clock: { fake })
        let before = vm.todayKey
        fake = fake.addingTimeInterval(3600)
        vm.refreshToday()
        XCTAssertEqual(vm.todayKey, before)
    }

    /// **钉死目录的实例(测试用)永远不跟日历走。**
    ///
    /// 没有这条边界的话,所有传 `sessionDir:` 的测试会在第一次 `refreshToday`
    /// 就被今天的真目录顶掉 —— 而它们要打的东西全在那个临时目录里。
    func testAPinnedDirectoryNeverRolls() throws {
        let dir = try tempDir()
        var fake = Calendar.current.startOfDay(
            for: Date(timeIntervalSince1970: 1_786_000_000)).addingTimeInterval(23 * 3600)
        let vm = RecordingViewModel(sessionDir: dir, database: nil, clock: { fake })
        fake = fake.addingTimeInterval(86_400)
        vm.refreshToday()
        XCTAssertEqual(vm.todayKey, dir.lastPathComponent)
    }

    func testUserPauseIsNotReportedAsAnInterruption() {
        let text = RecordingViewModel.noticeText(for: report(gapMs: 0, paused: true))
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("你暂停"), "用户自己按的暂停不能说成「中断」:\(text!)")
        XCTAssertFalse(text!.contains("中断"), text!)
    }

    func testInterruptionReportsTheRealDuration() {
        let text = RecordingViewModel.noticeText(for: report(gapMs: 15 * 60 * 1000))
        XCTAssertEqual(text, "录音中断过约 15 分钟,当前未在录音,请重新开始。")
    }

    func testShortGapStillGetsAMinute() {
        // 20 秒的空洞四舍五入成 0 分钟的话,提示会变成「中断过约 0 分钟」——
        // 那句话读起来像「没事」,而实际是真丢了一段。
        let text = RecordingViewModel.noticeText(for: report(gapMs: 20_000))
        XCTAssertEqual(text, "录音中断过约 1 分钟,当前未在录音,请重新开始。")
    }

    /// 🔴 **照妖镜(`M2-审5`)**:任何空洞文案都不许声称录音又开始了。
    ///
    /// 上面两条是等值断言,改文案时会一起改 —— 它们挡不住「换个说法继续撒谎」。
    /// 这一条打的是**语义**:`checkRelaunchGap` 全程不调 `start()`,
    /// 所以这条路径上说出口的任何「开始了 / 恢复了 / 继续了」都是假话。
    /// 哪天真做了自动恢复,先让 `start()` 出现在那条路径上,再来动这条断言。
    func testNoticeNeverClaimsRecordingResumed() {
        // ⚠️ 打的是**断言式**的说法(「已…」),不是「请重新开始」那种祈使句 ——
        // 后者是给用户的指令,恰恰是这条文案该说的话。
        let liars = ["已重新开始", "已恢复", "已继续", "已重启", "又开始录"]
        for gapMs in [1, 20_000, 60_000, 15 * 60 * 1000, 8 * 3600 * 1000] {
            guard let text = RecordingViewModel.noticeText(for: report(gapMs: gapMs)) else {
                XCTFail("空洞 \(gapMs)ms 却什么都不说")
                continue
            }
            for liar in liars {
                XCTAssertFalse(text.contains(liar),
                               "空洞 \(gapMs)ms 的文案声称录音又开始了,而这条路径从不调 start():\(text)")
            }
            // 正面那一半:光「不撒谎」不够,还得**把真实状态说出口**。
            // 只删掉「已重新开始」四个字的话,剩下「录音中断过约 N 分钟。」
            // 读起来像「中断已经过去了」—— 用户照样不会去点开始。
            XCTAssertTrue(text.contains("未在录音"),
                          "文案没说清当前没在录:\(text)")
        }
    }

    func testZeroGapWithoutPauseSaysNothing() {
        XCTAssertNil(RecordingViewModel.noticeText(for: report(gapMs: 0)))
    }

    // MARK: - 时长文案

    func testDurationShowsHoursOnceItPassesOne() {
        // 全时录音一天 8 小时。只显示分秒的话到下午会变成「487:12」,读不出来。
        XCTAssertEqual(RecordingViewModel.format(59), "00:59")
        XCTAssertEqual(RecordingViewModel.format(3599), "59:59")
        XCTAssertEqual(RecordingViewModel.format(3600), "1:00:00")
        XCTAssertEqual(RecordingViewModel.format(8 * 3600 + 7 * 60 + 12), "8:07:12")
    }
}

/// 路由变化的 reason 分流(2026-08-10 真机首跑抓出来的)。
///
/// 激活音频会话本身会触发一次 `.categoryChange`。不过滤的话,开录瞬间收到它,
/// 状态机按「AirPods 连断」处理:刚起的引擎立刻停掉重起,顺手切出一个 **0 秒空块**。
/// 真机上每次开录都留下一个 557 字节的 block-0000。
@MainActor
final class RouteChangeFilterTests: XCTestCase {

    func testSelfInflictedCategoryChangeDoesNotRestartTheEngine() {
        // 我们自己 setCategory 触发的,不是真换设备。这条是空块的根因。
        XCTAssertFalse(RecordingKernel.needsEngineRestart(.categoryChange))
    }

    func testRealDeviceChangesDoRestartTheEngine() {
        // 输入设备真的换了 → 输入格式变了,tap 与转换器都得重建。
        for reason in [AVAudioSession.RouteChangeReason.oldDeviceUnavailable,
                       .newDeviceAvailable, .routeConfigurationChange] {
            XCTAssertTrue(RecordingKernel.needsEngineRestart(reason), "\(reason) 该重起引擎")
        }
    }

    func testHarmlessReasonsDoNotRestart() {
        // 每重起一次就切一块、丢一小段音频。白切的代价是实打实的。
        for reason in [AVAudioSession.RouteChangeReason.override,
                       .wakeFromSleep, .noSuitableRouteForCategory, .unknown] {
            XCTAssertFalse(RecordingKernel.needsEngineRestart(reason), "\(reason) 不该重起引擎")
        }
    }
}

/// 块号必须从账本续,不能每次开 App 从 0 重来(2026-08-10 真机录两场时抓到)。
///
/// 目录是按**天**分的,而块号原来每次从 0 起 —— 同一天录第二场时
/// `block-0000.m4a` 会**覆盖掉第一场的**。用户实测中第一场的块被第二场盖了。
@MainActor
final class BlockNumberingTests: XCTestCase {

    private func ledger(_ seqs: [Int]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("ledger.jsonl")
        let t0 = Date()
        try BlockLedger.append(LedgerEntry(at: t0, mark: .sessionStarted), to: url)
        for s in seqs {
            try BlockLedger.append(LedgerEntry(block: BlockRecord(
                seq: s, startedAt: t0, endedAt: t0.addingTimeInterval(60),
                hardCut: true, fileName: "block-\(s).m4a")), to: url)
        }
        return url
    }

    func testSecondSessionContinuesInsteadOfOverwriting() throws {
        XCTAssertEqual(RecordingKernel.nextBlockSeq(ledgerURL: try ledger([0, 1, 2])), 3)
    }

    func testFreshDayStartsAtZero() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("ledger.jsonl")
        XCTAssertEqual(RecordingKernel.nextBlockSeq(ledgerURL: empty), 0)
    }

    func testOutOfOrderLedgerStillTakesTheMaximum() throws {
        // 取 max 不是取「最后一条」:账本里块记录的顺序是**完成顺序**,
        // 而块号是开始顺序。乱序时取最后一条会算出一个已经用过的号。
        XCTAssertEqual(RecordingKernel.nextBlockSeq(ledgerURL: try ledger([2, 0, 1])), 3)
    }

    // MARK: - 🔴 块号永远不许覆盖已有的块文件

    /// **不变量:`nextBlockSeq` 返回的号,对应的文件不许已经存在。**
    ///
    /// 上一版只防「账本抛出」那一条路,而 2026-08-18 复核发现防不住:
    /// `BlockLedger.read` 对「最后一行写了一半」是**合法容忍**的
    /// (App 被 jetsam 杀掉时的正常形态)⇒ 半行账本**读成功、零条目** ⇒ 回 0 ⇒
    /// 覆盖那一天已有的块。而本地 m4a 是原始证据,覆盖不可逆。
    func testATruncatedLedgerNeverHandsBackASeqThatWouldOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trunc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 盘上已经有三个块
        for n in 0..<3 {
            try Data("x".utf8).write(to: dir.appendingPathComponent(
                String(format: "block-%04d.m4a", n)))
        }
        // 而账本只剩半行(合法的截断尾巴,`read` 会成功且零条目)
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        try Data(#"{"at":"2026-08-18T09:00:00+0"#.utf8).write(to: ledgerURL)

        let seq = RecordingKernel.nextBlockSeq(ledgerURL: ledgerURL)
        XCTAssertEqual(seq, 3, "账本读成了零条目就回 0 —— 会覆盖盘上已有的块")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(
                String(format: "block-%04d.m4a", seq)).path),
            "返回的块号对应的文件已经存在 —— 写下去就是覆盖原始音频")
    }

    /// 账本好、盘上也一致时,两者取大值不改变正常行为。
    func testANormalLedgerStillDrivesTheSeq() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("normal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 账本说到 2,盘上一个文件都没有(块还没落盘就被杀掉)⇒ 仍然接着账本走
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        let t0 = Date()
        for n in 0...2 {
            try BlockLedger.append(LedgerEntry(block: BlockRecord(
                seq: n, startedAt: t0, endedAt: t0.addingTimeInterval(60),
                hardCut: true, fileName: String(format: "block-%04d.m4a", n))), to: ledgerURL)
        }
        XCTAssertEqual(RecordingKernel.nextBlockSeq(ledgerURL: ledgerURL), 3)
    }

    /// 全新的一天:账本不存在、盘上也没有 ⇒ 0。
    func testAFreshDayStartsAtZero() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(RecordingKernel.nextBlockSeq(
            ledgerURL: dir.appendingPathComponent("ledger.jsonl")), 0)
    }

}

// MARK: - 计时归零(2026-08-19 用户实机:「时长不会从 0 开始算」)

extension RecordingNoticeTests {

    /// 🔴 **新的一场必须从 0 开始。**
    ///
    /// 之前 `settledSeconds` 从来不归零:录 3 分钟停掉、再按开始,
    /// 计时器接着从 3:00 往上走。与「隔多近」无关 —— 用户觉得有关,
    /// 是因为中间没重开 App(重启会新建 ViewModel,那个变量才跟着没了)。
    func testANewSessionStartsFromZero() {
        XCTAssertTrue(RecordingStateMachine.startsFresh(from: .stopped, to: .recording),
                      "停掉之后再开始,是新的一场,计时必须归零")
        XCTAssertTrue(RecordingStateMachine.startsFresh(from: .idle, to: .recording))
    }

    /// 🔴 **从暂停恢复绝不能归零** —— 归了就把用户已经录的时长当场抹掉,
    /// 而他看到的是「录了半小时,一恢复变成 0」。
    func testResumingFromPauseKeepsTheTimeAlreadyRecorded() {
        XCTAssertFalse(RecordingStateMachine.startsFresh(from: .pausedByUser, to: .recording),
                       "用户暂停后恢复被当成新的一场 —— 已录时长会被抹掉")
        XCTAssertFalse(RecordingStateMachine.startsFresh(from: .pausedBySystem, to: .recording),
                       "来电打断后恢复被当成新的一场 —— 已录时长会被抹掉")
    }

    /// 离开「在录」不触发归零(归零只发生在**进入**时)。
    func testLeavingRecordingNeverResets() {
        for to in [RecordingState.pausedByUser, .pausedBySystem, .stopped, .idle] {
            XCTAssertFalse(RecordingStateMachine.startsFresh(from: .recording, to: to))
        }
    }
}

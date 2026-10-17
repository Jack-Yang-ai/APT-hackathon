import XCTest
import GRDB
@testable import GrowthApp

/// 上传层(§六「上传层」· §1.2 ④ · §1.3)。
///
/// 三条验收都在这儿,外加两条「看着正常其实错了」的边界:
/// 断点续传别从头再传、没网别把任务推向 dead。
final class UploadTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-10T15:00:00+08:00"
    private let at = ISO8601DateFormatter().date(from: "2026-08-10T15:00:00Z")!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (7, '2026-08-10T09:00:00+08:00', '2026-08-10', 'recording', 'closed')
                """)
        }
    }
    override func tearDownWithError() throws { dbQueue = nil }

    // MARK: - 假网络

    // ⚠️ 语义是**「交出去了」不是「传完了」**(M1-4c)。所以假网络分两半:
    // `handOff` 只记「交了」,真结果由 `complete(...)` 模拟系统回调写进 `upload_jobs`。
    // 把两者合成一个的话,测的就还是那个被真后台淘汰掉的同步契约。

    /// 交完立刻当传成了 —— 给不关心异步的那些用例用。
    private struct HandsOffAndSucceeds: UploadTransport {
        let db: DatabaseQueue
        let seen = Box()
        func handOff(fileURL: URL, to key: String, tag: String,
                     trigger: ProcessingEvents.Trigger) throws {
            seen.keys.append(key)
            guard let (s, b) = UploadJobStore.parse(tag: tag) else { return }
            try UploadJobStore.finish(sessionID: s, blockSeq: b, status: 200,
                                      now: "2026-08-10T15:00:00+08:00", in: db)
        }
    }

    /// 交出去就抛 —— 「一次网络都没发生」那种失败。
    private struct RefusesToHandOff: UploadTransport {
        /// 第几次开始交不出去(0 = 第一次就交不出去)
        let failAt: Int
        let db: DatabaseQueue
        let seen = Box()
        func handOff(fileURL: URL, to key: String, tag: String,
                     trigger: ProcessingEvents.Trigger) throws {
            seen.keys.append(key)
            if seen.keys.count > failAt { throw NSError(domain: "net", code: -1009) }
            guard let (s, b) = UploadJobStore.parse(tag: tag) else { return }
            try UploadJobStore.finish(sessionID: s, blockSeq: b, status: 200,
                                      now: "2026-08-10T15:00:00+08:00", in: db)
        }
    }

    /// 交得出去,但系统回话说没成。
    private struct HandsOffThenSystemFails: UploadTransport {
        let db: DatabaseQueue
        let status: Int
        let seen = Box()
        func handOff(fileURL: URL, to key: String, tag: String,
                     trigger: ProcessingEvents.Trigger) throws {
            seen.keys.append(key)
            guard let (s, b) = UploadJobStore.parse(tag: tag) else { return }
            try UploadJobStore.fail(sessionID: s, blockSeq: b, status: status,
                                    error: "HTTP \(status)",
                                    now: "2026-08-10T15:00:00+08:00", in: db)
        }
    }

    /// 只交出去,**不回话** —— 真后台的常态:结果几分钟后才来。
    private struct HandsOffAndWaits: UploadTransport {
        let seen = Box()
        func handOff(fileURL: URL, to key: String, tag: String,
                     trigger: ProcessingEvents.Trigger) throws { seen.keys.append(key) }
    }

    final class Box { var keys: [String] = [] }

    private func blocks(_ seqs: [Int]) -> [PendingBlock] {
        // 这个 suite 只测上传排队,时间字段用不上 —— 但也**不给一个假的整数**:
        // 300 秒那个默认值已经害过两次(见 `PendingBlock` 的 init 注释)。
        // 这里显式给出「每块 300 秒、首尾相接」的夹具,读的人一眼知道是夹具不是事实。
        seqs.map { PendingBlock(blockSeq: $0,
                                fileURL: URL(fileURLWithPath: "/tmp/b\($0).m4a"),
                                seconds: 300,
                                offsetMs: $0 * 300_000,
                                durationMs: 300_000) }
    }

    private func task() throws -> Int64 {
        try BlockUploader.enqueue(sessionID: 7, now: now, in: dbQueue)
    }

    private func row() throws -> Row {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE session_id = 7")!
        }
    }

    // MARK: - 验收③:键与 Mac 侧读的前缀对得上

    func testAudioKeyMatchesMacSidePrefix() {
        // ⚠️ 这个字面量的另一侧是 `mac/r2_service.py::AUDIO_PREFIX` 与它的键测试。
        // 两个运行时共用不了常量,只能各钉一条 —— 改一边就得改另一边。
        XCTAssertEqual(R2Layout.audioPrefix, "inbox/audio/")
        XCTAssertEqual(R2Layout.audioKey(sessionID: 7, blockSeq: 0, ext: "m4a"),
                       "inbox/audio/7/block-0000.m4a")
        XCTAssertEqual(R2Layout.sessionPrefix(sessionID: 7), "inbox/audio/7/")
    }

    func testBlockSeqIsZeroPaddedSoLexicalOrderEqualsBlockOrder() {
        // Mac 侧靠列目录拿块清单。不补零的话 block-10 会排在 block-2 前面,
        // 拼接顺序就错了(§3.1.6 结果按 block_seq 排序拼接)。
        let keys = [2, 10].map { R2Layout.audioKey(sessionID: 7, blockSeq: $0, ext: "m4a") }
        XCTAssertEqual(keys.sorted(), keys, "字典序必须等于块序")
    }

    func testOnlyWritesUnderInbox() {
        // 手机只写 inbox(§1.1 铁律,凭证层面也只给这个权限)。
        for key in [R2Layout.audioKey(sessionID: 7, blockSeq: 0, ext: "m4a"),
                    R2Layout.enrollPrefix] {
            XCTAssertTrue(key.hasPrefix("inbox/"), "\(key) 不在 inbox/ 下")
        }
    }

    // MARK: - 验收②:仅 Wi-Fi 开关

    func testWifiOnlyHoldsOnCellularAndKeepsTaskOnTheTable() throws {
        let id = try task()
        let transport = HandsOffAndSucceeds(db: dbQueue)
        let r = try BlockUploader.run(taskID: id, sessionID: 7, blocks: blocks([0, 1]),
                                      reachability: .cellular, wifiOnly: true, ext: "m4a",
                                      at: at, transport: transport, trigger: .foreground,
                                      in: dbQueue)

        XCTAssertEqual(r.uploaded, [], "开了仅 Wi-Fi,蜂窝下一块都不该发起")
        XCTAssertEqual(transport.seen.keys, [], "连传输层都不该被调到")
        XCTAssertNotNil(r.heldReason)

        let t = try row()
        XCTAssertEqual(t["state"] as String, "waiting_network", "任务留在表上,不是丢弃")
        XCTAssertEqual(t["attempts"] as Int, 0, "没网不是失败 —— attempts 加了会把任务推向 dead")
        try XCTAssertEqual(jobs().count, 0, "闸拦住时不该留下 upload_jobs 行")
    }

    func testHeldTaskIsPickedUpAgainWhenNetworkReturns() throws {
        // 落了 waiting_network 之后必须还能被捡起来,否则用户连上 Wi-Fi 也不会自己动。
        let id = try task()
        _ = try BlockUploader.run(taskID: id, sessionID: 7, blocks: blocks([0]),
                                  reachability: .cellular, wifiOnly: true, ext: "m4a",
                                  at: at, transport: HandsOffAndSucceeds(db: dbQueue),
                                  trigger: .foreground, in: dbQueue)
        XCTAssertEqual(try TaskQueue.nextRunnable(now: now, in: dbQueue), id,
                       "waiting_network 的任务必须还在可捡集合里")
    }

    func testCellularUploadsWhenWifiOnlyIsOff() throws {
        let id = try task()
        let transport = HandsOffAndSucceeds(db: dbQueue)
        // 第一拍交出去,第二拍才看得到结果 —— **真后台就是这个形状**。
        let first = try run(id, transport, [0, 1], wifiOnly: false)
        XCTAssertEqual(first.inFlight, 2, "交出去 ≠ 传完了")
        XCTAssertEqual(try row()["state"] as String, "queued", "还在传的任务要留在可捡集合里")
        XCTAssertEqual(try row()["attempts"] as Int, 0, "等传输完成不是失败")

        let second = try run(id, transport, [0, 1], wifiOnly: false)
        XCTAssertEqual(second.uploaded, [0, 1])
        XCTAssertEqual(second.inFlight, 0)
        XCTAssertEqual(try row()["state"] as String, "done")
    }

    func testOfflineHoldsRegardlessOfTheSwitch() throws {
        let id = try task()
        let r = try BlockUploader.run(taskID: id, sessionID: 7, blocks: blocks([0]),
                                      reachability: .offline, wifiOnly: false, ext: "m4a",
                                      at: at, transport: HandsOffAndSucceeds(db: dbQueue),
                                      trigger: .foreground, in: dbQueue)
        XCTAssertEqual(r.heldReason, "没有网络")
        XCTAssertEqual(try row()["attempts"] as Int, 0)
    }

    // MARK: - 验收①:失败后 attempts 与退避

    func testFailureIncrementsAttemptsAndSchedulesBackoff() throws {
        let id = try task()
        _ = try run(id, RefusesToHandOff(failAt: 0, db: dbQueue), [0], wifiOnly: false)
        let t = try row()
        XCTAssertEqual(t["attempts"] as Int, 1)
        XCTAssertEqual(t["state"] as String, "retrying")
        // §1.3 退避序列第一档 = 1 分钟。
        // ⚠️ 比的是**间隔**不是字面量:字面量那一版把「写成 UTC」这个缺陷钉成了绿的
        // (2026-08-17 真机:退避因此完全失效,失败任务一拍占满 12 步)。
        let next = try XCTUnwrap((t["next_retry_at"] as String?)
            .flatMap(ISO8601DateFormatter.growth.date(from:)),
            "解不回来 —— 和全仓不是一个口径:\(t["next_retry_at"] as String? ?? "nil")")
        XCTAssertEqual(next.timeIntervalSince(at), 60, accuracy: 1)
        XCTAssertNotNil(t["last_error"] as String?, "失败原因不落盘的话,dead 了也没人知道为什么")
    }

    func testBackoffSequenceFollowsSpec() throws {
        // 1m / 5m / 15m / 30m,之后封顶 30m。
        // 🔴 2026-08-19 改过,原为 1m / 5m / 30m / 2h 封顶 6h ——
        // 6 小时封顶的前提是「重试很贵」,而实测这条链上的重试是一次
        // 几百字节的 POST、失败时连上游都没碰到。贵的是**等**:
        // 08-18 两场录音因此躺了 15 小时 51 分钟(M1-21)。
        XCTAssertEqual((1...6).map { TaskQueue.backoff(afterAttempt: $0) },
                       [1, 5, 15, 30, 30, 30])
        // 单调不降 —— 原来的 30m→2h→回落 6h 是个台阶,越试越慢才是退避该有的形状
        let seq = (1...8).map { TaskQueue.backoff(afterAttempt: $0) }
        XCTAssertEqual(seq, seq.sorted(), "退避序列不该回落:\(seq)")
    }

    func testRepeatedFailuresEventuallyGoDead() throws {
        let id = try task()
        for _ in 1...TaskQueue.maxAttempts {
            _ = try run(id, RefusesToHandOff(failAt: 0, db: dbQueue), [0], wifiOnly: false)
        }
        let t = try row()
        XCTAssertEqual(t["state"] as String, "dead")
        XCTAssertNil(t["next_retry_at"] as String?, "dead 是终态,不该再排下一次")
        // 注意别把 Database 从 read 块里漏出来 —— GRDB 会直接崩(线程断言)
        let display = try dbQueue.read { try TaskQueue.displayState(forTaskState: "dead", in: $0) }
        XCTAssertEqual(display, "failed")
    }

    // MARK: - 断点续传:别把已经传上去的再传一遍

    /// §1.2 ④「只传一次」。这是**真后台之后最容易破的一条** ——
    /// 交出去和传完之间隔着几分钟,而这几分钟里编排会被推很多拍。
    func testAlreadyHandedBlocksAreNotHandedAgain() throws {
        let id = try task()
        let transport = HandsOffAndWaits()          // 交了就不回话,模拟真在传
        _ = try run(id, transport, [0, 1, 2], wifiOnly: false)
        XCTAssertEqual(transport.seen.keys.count, 3)

        // 又推了三拍(前台每次刷新都会推)—— 一块都不该重交
        for _ in 0..<3 { _ = try run(id, transport, [0, 1, 2], wifiOnly: false) }
        XCTAssertEqual(transport.seen.keys.count, 3,
                       "重交了 \(transport.seen.keys.count - 3) 次 —— 同一块音频传了好几遍")
    }

    /// 一块传成了、一块还在传:成的那块**不能**被重交,任务也不能标 done。
    func testPartiallyDoneUploadKeepsWaitingWithoutRehandingTheDoneOne() throws {
        let id = try task()
        let transport = HandsOffAndWaits()
        _ = try run(id, transport, [0, 1], wifiOnly: false)

        // 模拟系统只回了第 0 块
        try UploadJobStore.finish(sessionID: 7, blockSeq: 0, status: 200, now: now, in: dbQueue)
        let r = try run(id, transport, [0, 1], wifiOnly: false)

        XCTAssertEqual(r.uploaded, [0])
        XCTAssertEqual(r.inFlight, 1)
        XCTAssertEqual(transport.seen.keys.count, 2, "传完的那块被重交了")
        XCTAssertEqual(try row()["state"] as String, "queued", "还有在传的就不能标 done")
    }

    // MARK: - 🔴 系统回话说没成 ≠ 还在传

    /// HTTP 401/500 在 `URLSession` 眼里是**一次完成的传输**(error 是 nil)。
    /// 按 error 判成功的话,一块根本没落到 R2 的音频会被当成传好了,
    /// 然后拿它去转写一个不存在的对象 —— 一次白花的调用,而且报错在很远的地方。
    func testSystemReportedFailureGoesThroughBackoffNotSilentSuccess() throws {
        let id = try task()
        _ = try run(id, HandsOffThenSystemFails(db: dbQueue, status: 401), [0], wifiOnly: false)
        // 第一拍只是交出去;第二拍才看到系统回的失败
        let r = try run(id, HandsOffThenSystemFails(db: dbQueue, status: 401), [0], wifiOnly: false)

        XCTAssertNotNil(r.failed)
        XCTAssertEqual(try row()["state"] as String, "retrying")
        XCTAssertEqual(try row()["attempts"] as Int, 1)
        XCTAssertTrue((try row()["last_error"] as String? ?? "").contains("401"),
                      "没把状态码带出来 —— 401 和断网该做的事完全不同")
        try XCTAssertEqual(jobs().count, 0, "失败的行要抹掉,下次才会重新交给系统")
    }

    // MARK: - 传输丢了要捡得回来

    /// App 被强杀 / 设备重启之后,系统那边可能已经没有这个传输任务了。
    /// 不捡回来的话这一行会永远停在 `handed`,这一场永远等不到上传完成 ——
    /// 而任务表上看起来一切正常。
    func testLostTransfersAreReclaimedAfterTheGracePeriod() throws {
        try UploadJobStore.claim(sessionID: 7, blockSeq: 0, key: "k0", now: now, in: dbQueue)
        let long = ISO8601DateFormatter.growth.date(from: now)!.addingTimeInterval(3600)

        let lost = try UploadJobStore.resetLost(liveTags: [], now: long, in: dbQueue)
        XCTAssertEqual(lost.count, 1)
        try XCTAssertEqual(jobs().first?.state, "failed")
        try XCTAssertNotNil(jobs().first?.lastError)
    }

    /// ⚠️ **宽限期不能是 0。** App 因「传输完成」被冷启动时,回调要过一小会儿才送达,
    /// 而这期间那个任务已经不在 `allTasks` 里了 —— 宽限期为 0 会把一次
    /// **刚刚成功**的传输判成丢失,然后白传一遍。
    func testRecentlyHandedTransfersAreNotJudgedLost() throws {
        try UploadJobStore.claim(sessionID: 7, blockSeq: 0, key: "k0", now: now, in: dbQueue)
        let justNow = ISO8601DateFormatter.growth.date(from: now)!.addingTimeInterval(5)

        let lost = try UploadJobStore.resetLost(liveTags: [], now: justNow, in: dbQueue)
        XCTAssertEqual(lost.count, 0, "刚交出去 5 秒就被判丢失 —— 会白传一遍")
        try XCTAssertEqual(jobs().first?.state, "handed")
    }

    /// 系统那边还在传的,**多久都不算丢**。
    func testStillLiveTransfersAreNeverJudgedLost() throws {
        try UploadJobStore.claim(sessionID: 7, blockSeq: 0, key: "k0", now: now, in: dbQueue)
        let long = ISO8601DateFormatter.growth.date(from: now)!.addingTimeInterval(86400)

        let lost = try UploadJobStore.resetLost(
            liveTags: [UploadJobStore.tag(sessionID: 7, blockSeq: 0)], now: long, in: dbQueue)
        XCTAssertEqual(lost.count, 0, "还在传的被判丢失了 —— 会把一份正在传的重传一遍")
    }

    /// 已经传完的行不参与对账 —— 它不是 `handed`。
    func testFinishedTransfersAreNotTouchedByReconcile() throws {
        try UploadJobStore.claim(sessionID: 7, blockSeq: 0, key: "k0", now: now, in: dbQueue)
        try UploadJobStore.finish(sessionID: 7, blockSeq: 0, status: 200, now: now, in: dbQueue)
        let long = ISO8601DateFormatter.growth.date(from: now)!.addingTimeInterval(86400)

        _ = try UploadJobStore.resetLost(liveTags: [], now: long, in: dbQueue)
        try XCTAssertEqual(jobs().first?.state, "done")
    }

    // MARK: - 行的幂等

    func testClaimingTheSameBlockTwiceKeepsTheFirstRow() throws {
        // 覆盖会把一次已完成的传输打回「在传」,于是重传一遍。
        try UploadJobStore.claim(sessionID: 7, blockSeq: 0, key: "k0", now: now, in: dbQueue)
        try UploadJobStore.finish(sessionID: 7, blockSeq: 0, status: 200, now: now, in: dbQueue)
        let again = try UploadJobStore.claim(sessionID: 7, blockSeq: 0, key: "k0",
                                             now: now, in: dbQueue)
        XCTAssertFalse(again.inserted)
        XCTAssertEqual(again.job.state, "done", "已完成的行被打回在传了")
    }

    func testTagRoundTrips() {
        let t = UploadJobStore.tag(sessionID: 12, blockSeq: 7)
        let parsed = UploadJobStore.parse(tag: t)
        XCTAssertEqual(parsed?.sessionID, 12)
        XCTAssertEqual(parsed?.blockSeq, 7)
        // 回调里拿到看不懂的标识时**返回 nil**,不猜 —— 猜错会把结果写到别的块上
        XCTAssertNil(UploadJobStore.parse(tag: "乱七八糟"))
        XCTAssertNil(UploadJobStore.parse(tag: "12"))
        XCTAssertNil(UploadJobStore.parse(tag: "a/b"))
    }

    // MARK: - 零件

    @discardableResult
    private func run(_ id: Int64, _ transport: UploadTransport, _ seqs: [Int],
                     reachability: Reachability = .wifi,
                     wifiOnly: Bool) throws -> BlockUploader.RunResult {
        try BlockUploader.run(taskID: id, sessionID: 7, blocks: blocks(seqs),
                              reachability: reachability, wifiOnly: wifiOnly, ext: "m4a",
                              at: at, transport: transport, trigger: .foreground, in: dbQueue)
    }

    private func jobs() throws -> [UploadJobStore.Job] {
        try UploadJobStore.all(sessionID: 7, in: dbQueue)
    }
}

// MARK: - 🔴 一块坏音频不该挡住一整场(2026-08-17 真机)

extension UploadTests {

    /// 音频文件读不出来(结束那一刻开的空块、写了一半的块)是**永久**失败 ——
    /// 重试一万次也一样。而真机上它把**整场**卡在退避里:后面的转写、纪要全不动。
    /// §3.1.6 本来就允许缺块以 `partial` 落库。
    private struct RefusesBlock: UploadTransport {
        let bad: Int
        let db: DatabaseQueue
        let seen = Box()
        func handOff(fileURL: URL, to key: String, tag: String,
                     trigger: ProcessingEvents.Trigger) throws {
            guard let (s, b) = UploadJobStore.parse(tag: tag) else { return }
            if b == bad { throw PermanentUploadFailure(reason: "音频转 wav 失败:读不出来") }
            seen.keys.append(key)
            try UploadJobStore.finish(sessionID: s, blockSeq: b, status: 200,
                                      now: "2026-08-10T15:00:00+08:00", in: db)
        }
    }

    func testAPermanentlyBadBlockIsSkippedInsteadOfBlockingTheSession() throws {
        let id = try task()
        let t = RefusesBlock(bad: 1, db: dbQueue)
        _ = try run(id, t, [0, 1, 2], wifiOnly: false)
        let r = try run(id, t, [0, 1, 2], wifiOnly: false)

        XCTAssertEqual(r.uploaded, [0, 2], "坏的那块把好的也带停了")
        XCTAssertNil(r.failed, "一块坏音频把整场判成了失败")
        XCTAssertEqual(try row()["state"] as String, "done",
                       "整场该照常收工(缺块由冻结那一步落成 partial)")
        XCTAssertEqual(try row()["attempts"] as Int, 0,
                       "这不是这一场的失败,是这一块没了 —— attempts 不该涨")
    }

    /// 坏块要**留痕**并标成永久,否则下一拍又会去读一次那个读不出来的文件。
    func testPermanentFailureIsRecordedWithItsSentinel() throws {
        let id = try task()
        _ = try run(id, RefusesBlock(bad: 0, db: dbQueue), [0], wifiOnly: false)
        let job = try XCTUnwrap(try jobs().first)
        XCTAssertEqual(job.state, "failed")
        XCTAssertEqual(job.httpStatus, UploadJobStore.permanentStatus,
                       "没标成永久 —— 下一拍还会再读一次那个读不出来的文件")
        XCTAssertNotNil(job.lastError)
    }

    /// **普通传输失败仍然要退避重试** —— 别把这条一起放过了。
    func testTransientFailureStillGoesThroughBackoff() throws {
        let id = try task()
        _ = try run(id, RefusesToHandOff(failAt: 0, db: dbQueue), [0], wifiOnly: false)
        XCTAssertEqual(try row()["attempts"] as Int, 1)
        XCTAssertEqual(try row()["state"] as String, "retrying")
    }
}

// MARK: - M1-33 上游说「任务不存在」时,记录必须作废并重提(用户 2026-08-19 指出)

final class LostASRJobTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-19T17:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-19T16:00:00+08:00', '2026-08-19', 'recording', 'closed');
                INSERT INTO asr_jobs (session_id, block_seq, remote_id, state, created_at, updated_at)
                VALUES (1, 0, 'gone-task-id', 'submitted', ?, ?);
                """, arguments: [now, now])
        }
    }
    override func tearDownWithError() throws { dbQueue = nil }

    private func state(_ blockSeq: Int = 0) throws -> String {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM asr_jobs WHERE block_seq = ?",
                                arguments: [blockSeq]) ?? ""
        }
    }

    /// 🔴 **判据只认上游自己的话。** 放宽到「任何 400」会把参数写错也算进来,
    /// 而那种重提一万次也没用,只会一次次买单。
    func testOnlyTheUpstreamsOwnWordsCountAsLost() {
        XCTAssertTrue(ProcessingOrchestrator.upstreamForgotTheTask(
            #"502:{"error":"query failed","status":400,"body":"{\"error\":{\"message\":\"task not found\"}}"}"#))
        XCTAssertFalse(ProcessingOrchestrator.upstreamForgotTheTask("502:{\"error\":\"参数不合法\"}"),
                       "普通 400 被当成「任务不存在」—— 会一次次重提一个永远不会成功的块")
        XCTAssertFalse(ProcessingOrchestrator.upstreamForgotTheTask("超时"))
    }

    /// **头两次落 `lost`(等着重提),第三次落 `failed`(别再买单)。**
    func testResubmitIsBoundedBecauseEachOneCostsMoney() throws {
        for i in 1...ASRJobStore.maxResubmits {
            let again = try ASRJobStore.markLost(sessionID: 1, blockSeq: 0,
                                                 error: "task not found", now: now, in: dbQueue)
            XCTAssertTrue(again, "第 \(i) 次就放弃了,而上限是 \(ASRJobStore.maxResubmits)")
            XCTAssertEqual(try state(), "lost")
        }
        let again = try ASRJobStore.markLost(sessionID: 1, blockSeq: 0,
                                             error: "task not found", now: now, in: dbQueue)
        XCTAssertFalse(again, "超过上限还在重提 —— 上游每忘一次我们就买一次单,而这不会有东西红")
        XCTAssertEqual(try state(), "failed")
    }

    /// **落了 `lost` 之后,`last_error` 必须留着** ——
    /// 「为什么这一块没有转写」要查得到,不能只剩一个状态字。
    func testTheReasonSurvivesSoYouCanFindOutWhy() throws {
        _ = try ASRJobStore.markLost(sessionID: 1, blockSeq: 0,
                                     error: "task not found", now: now, in: dbQueue)
        let why = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT last_error FROM asr_jobs WHERE block_seq = 0")
        }
        XCTAssertEqual(why, "task not found")
    }

    /// 🔴 **照妖镜:`lost` 与 `failed` 必须真的走不同的路。**
    ///
    /// 混成一个的话这一组全绿而缺陷还在 —— 因为 `failed` 的块
    /// 不会被重新提交(`neverSubmitted` 只看「有没有作业行」)。
    func testLostAndFailedAreNotTheSameThing() throws {
        XCTAssertNotEqual(ASRJobStore.State.lost.rawValue, ASRJobStore.State.failed.rawValue)
        try ASRJobStore.fail(sessionID: 1, blockSeq: 0, error: "音频坏了", now: now, in: dbQueue)
        XCTAssertEqual(try state(), "failed", "普通失败被写成了 lost —— 会一次次重提一个坏块")
    }
}

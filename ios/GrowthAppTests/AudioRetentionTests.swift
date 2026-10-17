import XCTest
import GRDB
@testable import GrowthApp

/// 音频保留期与上传残留(M1-16a)。
///
/// 🔴 **验收原文:跑满保留期之后,旧音频真的不在盘上了 ——「查文件,不查日志」。**
/// 所以这组测试每一条都去 `FileManager` 问,不看返回值里的计数。
final class AudioRetentionTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    /// 「现在」固定住,好让「几天前」是个确定的日子。
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private var days: [String] = []

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
    }

    override func tearDownWithError() throws {
        for d in days {
            try? FileManager.default.removeItem(
                at: ProcessingPump.recordingsRoot.appendingPathComponent(d))
        }
        dbQueue = nil
    }

    /// 造一场:账本 + 两块音频 + `sessions` 行(可选带冻结的转写)。
    @discardableResult
    private func session(_ id: Int64, daysAgo: Int, frozen: Bool) throws -> [URL] {
        let start = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let day = AudioRetention.dayKey(start)
        days.append(day)
        let dir = ProcessingPump.recordingsRoot.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ledger = dir.appendingPathComponent("ledger.jsonl")

        // 块号在目录里全局唯一 —— 用场次 id 岔开,免得两场撞名
        let base = Int(id) * 10
        try BlockLedger.append(LedgerEntry(at: start, mark: .sessionStarted), to: ledger)
        var urls: [URL] = []
        for i in 0..<2 {
            let seq = base + i
            let name = String(format: "block-%04d.m4a", seq)
            let url = dir.appendingPathComponent(name)
            try Data(repeating: 3, count: 2048).write(to: url)
            urls.append(url)
            try BlockLedger.append(LedgerEntry(block: BlockRecord(
                seq: seq,
                startedAt: start.addingTimeInterval(Double(i) * 300),
                endedAt: start.addingTimeInterval(Double(i + 1) * 300),
                hardCut: true, fileName: name)), to: ledger)
        }
        try BlockLedger.append(
            LedgerEntry(at: start.addingTimeInterval(600), mark: .sessionEnded), to: ledger)

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (?, ?, ?, ?, 'recording', 'closed')
                """, arguments: [id, SessionBridge.iso(start),
                                 SessionBridge.iso(start.addingTimeInterval(600)), day])
            if frozen {
                try db.execute(sql: """
                    INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at)
                    VALUES (?, 1, 1, 'a', 'frozen', 'x')
                    """, arguments: [id])
            }
        }
        return urls
    }

    private func onDisk(_ urls: [URL]) -> Int {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }.count
    }

    // MARK: - 验收:查文件,不查日志

    /// 过期且已冻结 → 音频**真的不在盘上**。账本留着。
    func testExpiredAndFrozenAudioIsActuallyGone() throws {
        let old = try session(1, daysAgo: 10, frozen: true)
        XCTAssertEqual(onDisk(old), 2, "前提不成立:文件本来就没造出来")

        try AudioRetention.sweep(now: now, in: dbQueue)
        XCTAssertEqual(onDisk(old), 0, "过了保留期还在盘上")

        let ledger = old[0].deletingLastPathComponent().appendingPathComponent("ledger.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.path),
                      "账本被一起删了 —— 它是场次的真相源")
    }

    /// 🔴 **还没冻结的一块都不许删。**
    ///
    /// 那时音频是**唯一的原始材料**,删了就永远没有了。而「够老了还没转写完」
    /// 在断网、云代理没配、任务卡死之后是常态,不是意外。
    func testAnUnfinishedSessionKeepsItsAudioNoMatterHowOld() throws {
        let stuck = try session(2, daysAgo: 90, frozen: false)
        let r = try AudioRetention.sweep(now: now, in: dbQueue)

        XCTAssertEqual(onDisk(stuck), 2, "还没转写完就把音频删了 —— 那一场永远回不来了")
        XCTAssertEqual(r.keptUnfinished, 1,
                       "留着的数没报出来 —— 它一直不降就说明有场次卡住了")
        XCTAssertEqual(r.filesDeleted, 0)
    }

    /// 保留期之内的一块都不动 —— 边界上宁可多留。
    func testAudioInsideTheWindowIsUntouched() throws {
        let fresh = try session(3, daysAgo: 2, frozen: true)
        try AudioRetention.sweep(now: now, in: dbQueue)
        XCTAssertEqual(onDisk(fresh), 2)
    }

    /// 保留期照 PRD §4.1.10 的 7 天,而且**与重试期限对得上**:
    /// §1.3 写明「重试期限必须短于音频保留期(7 天)减 1 天」,
    /// `TaskQueue.deadlineMinutes` = 6 天 ✓。两个数改一个就要一起看。
    func testRetentionMatchesTheRetryDeadline() {
        XCTAssertEqual(AudioRetention.days, 7)
        XCTAssertLessThanOrEqual(TaskQueue.deadlineMinutes, (AudioRetention.days - 1) * 24 * 60,
                                 "重试期限比「保留期 − 1 天」还长 —— 会重试一份已经被删掉的音频")
    }

    /// 只清该清的那一场,别的场次不受影响。
    func testOnlyTheExpiredSessionIsSwept() throws {
        let old = try session(4, daysAgo: 30, frozen: true)
        let fresh = try session(5, daysAgo: 1, frozen: true)
        try AudioRetention.sweep(now: now, in: dbQueue)
        XCTAssertEqual(onDisk(old), 0)
        XCTAssertEqual(onDisk(fresh), 2)
    }

    /// 连跑两次:第二次是 0,不该报错也不该重复计数。
    func testSweepingTwiceIsIdempotent() throws {
        try session(6, daysAgo: 10, frozen: true)
        try AudioRetention.sweep(now: now, in: dbQueue)
        XCTAssertEqual(try AudioRetention.sweep(now: now, in: dbQueue).filesDeleted, 0)
    }
}

/// 上传用的 wav 临时文件(M1-16a 的后一笔,比 AAC 那笔大五倍)。
final class UploadScratchTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UploadScratchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func make(_ tag: String) throws -> URL {
        let u = UploadScratch.url(tag: tag, in: dir)
        try Data(repeating: 1, count: 512).write(to: u)
        return u
    }

    /// 🔴 **两天各有一个 `block-0003`,临时路径必须不一样。**
    ///
    /// 原来 wav 的名字从 m4a 文件名推,而块号是按天从 0 起的 ⇒ 同一个路径。
    /// `WavExport.convert` 开头就 removeItem 再重写 ⇒ 两块同时在传时,
    /// 后转的会把前一个**正在上传的文件换掉** ——
    /// 表现是「上传成功、转写成功、内容是别人的」。
    func testDifferentSessionsNeverShareAScratchPath() {
        XCTAssertNotEqual(UploadScratch.url(tag: "11/3", in: dir),
                          UploadScratch.url(tag: "12/3", in: dir))
        // 路径里不许留 `/` —— 那会被当成目录分隔符
        XCTAssertFalse(UploadScratch.url(tag: "11/3", in: dir).lastPathComponent.contains("/"))
    }

    /// 传完(成功或失败)就删。
    func testDiscardRemovesTheFile() throws {
        let u = try make("7/0")
        UploadScratch.discard(tag: "7/0", in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: u.path))
    }

    /// 🔴 **系统那边还活着的不许删** —— 删掉就是把正在传的文件从它脚下抽走。
    func testSweepSpareLiveTransfers() throws {
        let live = try make("7/0")
        let orphan = try make("8/1")
        let r = UploadScratch.sweep(liveTags: ["7/0"], in: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path),
                      "把正在传的文件删了")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(r.files, 1)
        XCTAssertEqual(r.bytes, 512)
    }

    /// 临时目录里还有系统和别的库放的东西 —— **不能见 `.wav` 就删**。
    func testSweepOnlyTouchesItsOwnFiles() throws {
        let mine = try make("9/0")
        let theirs = dir.appendingPathComponent("some-other-library.wav")
        try Data([0]).write(to: theirs)

        UploadScratch.sweep(liveTags: [], in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: theirs.path),
                      "把别人的文件删了")
    }
}

import XCTest
import GRDB
@testable import GrowthApp

/// 进程被杀时正在写的那一块(M1-22)。
///
/// ## 它为什么不是「躺在盘上等认领」
///
/// 2026-08-19 拿真文件验过(真机上被强杀留下的 `block-0004.m4a`,926 KB):
/// `ffprobe` 报 **`moov atom not found`** —— MP4 的索引是**关文件时才写**的,
/// 进程被杀只留下一堆没有目录的音频数据。按裸 AAC 硬解出来是垃圾
/// (`channel element not allocated`)。同一天正常关闭的块作对照,读得好好的(30.08 秒)。
///
/// ⇒ **不认领、不补账本**(补了等于把一份读不出来的东西说成一块音频),
/// 只保证它**被看见**:在此之前的表现是「这一场判成一块音频都没有 → 失败 →
/// 移出记忆」,音频没了、记录也没了,而两边都不报错。
final class OrphanBlockTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var dir: URL!
    private let day = "2026-08-19"
    private let base = Date(timeIntervalSince1970: 1_786_000_000)

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        dir = ProcessingPump.recordingsRoot.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, ended_at, day, source, status)
                VALUES (1, ?, ?, ?, 'recording', 'closed')
                """, arguments: [SessionBridge.iso(base),
                                 SessionBridge.iso(base.addingTimeInterval(600)), day])
        }

        // 账本里有块 0、1;盘上多一个块 2 —— 那就是被杀时正在写的那一块。
        let ledger = dir.appendingPathComponent("ledger.jsonl")
        try BlockLedger.append(LedgerEntry(at: base, mark: .sessionStarted), to: ledger)
        for seq in 0..<2 {
            try BlockLedger.append(LedgerEntry(block: BlockRecord(
                seq: seq,
                startedAt: base.addingTimeInterval(Double(seq) * 300),
                endedAt: base.addingTimeInterval(Double(seq + 1) * 300),
                hardCut: true, fileName: "block-\(String(format: "%04d", seq)).m4a")), to: ledger)
            try Data(repeating: 0, count: 1024)
                .write(to: dir.appendingPathComponent("block-\(String(format: "%04d", seq)).m4a"))
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func writeOrphan(seq: Int, bytes: Int = 2048) throws {
        try Data(repeating: 0, count: bytes)
            .write(to: dir.appendingPathComponent("block-\(String(format: "%04d", seq)).m4a"))
    }

    /// 盘上有、账本里没有的那一块,要被找出来。
    func testTheBlockBeingWrittenWhenKilledIsFound() throws {
        try writeOrphan(seq: 2)
        let orphans = ProcessingPump.orphanBlockFiles(sessionID: 1, ext: "m4a", in: dbQueue)
        XCTAssertEqual(orphans.map(\.seq), [2], "被杀时正在写的那一块没被发现 —— 它会静默消失")
        XCTAssertEqual(orphans.first?.bytes, 2048, "大小要如实报,它是「丢了多少」唯一的线索")
    }

    /// 账本里有的块**不算**孤儿 —— 否则每一场都会报一堆假损失。
    func testBlocksTheLedgerKnowsAreNotOrphans() throws {
        let orphans = ProcessingPump.orphanBlockFiles(sessionID: 1, ext: "m4a", in: dbQueue)
        XCTAssertTrue(orphans.isEmpty, "账本里记着的块被当成孤儿了:\(orphans.map(\.seq))")
    }

    /// 别的后缀不算(将来换容器时,老文件不该被误报)。
    func testOtherExtensionsAreIgnored() throws {
        try Data(repeating: 0, count: 512)
            .write(to: dir.appendingPathComponent("block-0007.wav"))
        let orphans = ProcessingPump.orphanBlockFiles(sessionID: 1, ext: "m4a", in: dbQueue)
        XCTAssertTrue(orphans.isEmpty, "把 .wav 也当成了 m4a 的孤儿")
    }
}

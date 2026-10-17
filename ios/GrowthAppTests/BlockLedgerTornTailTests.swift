import XCTest
@testable import GrowthApp

/// 账本尾行写了一半(进程被杀时的正常形态)之后**再追加**(W1 对抗审查 2026-10-12)。
///
/// `read` 容忍最后半行,但 `append` 原来直接 `seekToEnd` 写 —— 新行粘在半行后面,
/// 成了「半行 + 新行」一整行,被当成截断尾巴丢掉(补的收尾等于没补);
/// 再追加一次,这一行落到中间,`read` 整本抛 `corruptLine` ——
/// 手表外发从此对这一天停发,手机重开时空洞报告也一直报错。
final class BlockLedgerTornTailTests: XCTestCase {

    private var dir: URL!
    private var ledger: URL { dir.appendingPathComponent("ledger.jsonl") }
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("torn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 先写一条完整的,再手工写半行(模拟被杀在 append 中途)。
    private func tornLedger() throws {
        try BlockLedger.append(LedgerEntry(at: t0, mark: .sessionStarted), to: ledger)
        let h = try FileHandle(forWritingTo: ledger)
        try h.seekToEnd()
        try h.write(contentsOf: Data(#"{"at":"2026-10-12T09:05:00Z","kind":"blo"#.utf8))
        try h.close()
    }

    func testAppendAfterTornTailKeepsTheNewEntry() throws {
        try tornLedger()
        let end = LedgerEntry(at: t0.addingTimeInterval(600), mark: .sessionEnded)
        try BlockLedger.append(end, to: ledger)

        let (entries, truncated) = try BlockLedger.read(from: ledger)
        XCTAssertEqual(entries.last, end, "补的收尾必须真的落进账本,不能和半行粘成一条被丢掉")
        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(truncated)
    }

    func testSecondAppendAfterTornTailStillReadable() throws {
        try tornLedger()
        try BlockLedger.append(LedgerEntry(at: t0.addingTimeInterval(600), mark: .sessionEnded),
                               to: ledger)
        try BlockLedger.append(LedgerEntry(at: t0.addingTimeInterval(900), mark: .sessionStarted),
                               to: ledger)
        XCTAssertNoThrow(try BlockLedger.read(from: ledger),
                         "半行之后追加两次,整本账不能变成读不出来")
        XCTAssertEqual(try BlockLedger.read(from: ledger).entries.count, 3)
    }
}

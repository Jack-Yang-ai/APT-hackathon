import XCTest
@testable import GrowthApp

/// 「清除全部录音」(M1-16c)。
///
/// 🔴 **这一条守的是一句会说谎的文案。**
/// 弹窗写着「录音账本、纪要与转写都留着,不受影响」,而 `wipe()` 删的是
/// `recordings/` 下**每一项** —— 每天一个目录,`ledger.jsonl` 就在里面。
/// 那句话在按下去的那一刻就是假的。
///
/// 而账本没了不是「少个文件」:它是场次的真相源,
/// `ProcessingPump.blocks(of:)` 读不到就判「这一场一块音频都没有」并**标死**。
final class AudioWipeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AudioWipeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 造一天:两块音频 + 一本账。
    @discardableResult
    private func makeDay(_ day: String, blocks: Int = 2) throws -> URL {
        let dir = root.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for seq in 0..<blocks {
            try Data(repeating: 7, count: 1024)
                .write(to: dir.appendingPathComponent(String(format: "block-%04d.m4a", seq)))
        }
        try Data("{\"kind\":\"block\"}\n".utf8)
            .write(to: dir.appendingPathComponent(AudioWipe.ledgerName))
        return dir
    }

    // MARK: - 验收:删完之后账本还在

    /// 🔴 音频删光,**每一天的账本一本不少**。
    func testAudioGoesAndTheLedgerStays() throws {
        let a = try makeDay("2026-08-15")
        let b = try makeDay("2026-08-16", blocks: 3)

        let r = try AudioWipe.run(root: root)
        XCTAssertEqual(r.filesDeleted, 5)
        XCTAssertEqual(r.ledgersKept, 2)
        XCTAssertEqual(r.bytesFreed, 5 * 1024)

        for dir in [a, b] {
            let left = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil).map(\.lastPathComponent)
            XCTAssertEqual(left, [AudioWipe.ledgerName],
                           "账本被一起删了 —— 在跑的场次会被判「一块音频都没有」并标死")
        }
    }

    /// 目录本身要留着 —— 删掉的话录音要往一个不存在的目录里写,
    /// 而账本也就跟着没了(它在那个目录里)。
    func testTheDayDirectoryItselfSurvives() throws {
        let dir = try makeDay("2026-08-15")
        try AudioWipe.run(root: root)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    /// 空的 `recordings/` 不该炸,也不该报「删了几个」。
    func testWipingNothingIsHarmless() throws {
        XCTAssertEqual(try AudioWipe.run(root: root), .init(filesDeleted: 0, bytesFreed: 0,
                                                            ledgersKept: 0))
    }

    /// 连着清两次:第二次是 0,账本仍在。
    func testWipingTwiceIsIdempotent() throws {
        try makeDay("2026-08-15")
        try AudioWipe.run(root: root)
        let second = try AudioWipe.run(root: root)
        XCTAssertEqual(second.filesDeleted, 0)
        XCTAssertEqual(second.ledgersKept, 1)
    }

    /// 删不掉要**抛出去**,不静默跳过 —— 默默失败会让用户以为空间腾出来了,
    /// 而它还占着(§3.2)。
    func testAFailedDeletionIsLoud() throws {
        try makeDay("2026-08-15", blocks: 1)
        final class StubbornFileManager: FileManager {
            override func removeItem(at URL: URL) throws {
                throw NSError(domain: "test", code: 1)
            }
        }
        XCTAssertThrowsError(try AudioWipe.run(root: root, fileManager: StubbornFileManager()))
    }

    // MARK: - 文案与行为是同一份契约

    /// 🔴 弹窗说「账本留着」,代码就必须留着。
    /// 这条断言把那句话钉在源码上 —— 它是这个 BUG 的**另一半**,
    /// 而两半分别待在两个文件里,谁改了另一处都不会红。
    func testTheDialogPromiseMatchesTheCode() throws {
        let settings = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GrowthApp/Presentation/SettingsView.swift")
        let src = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertTrue(src.contains("录音账本、纪要与转写都留着"),
                      "文案改了 —— 那 `AudioWipe` 豁免账本这件事就该一起重新审")
        XCTAssertTrue(src.contains("AudioWipe.run"),
                      "设置页又自己写了一遍删除 —— 那句承诺就没人保证了")
        XCTAssertTrue(src.contains("vm.watchSessionOpen"),
                      "未收尾手表场次的守卫没了 —— 必须先在手表结束并同步,才能清除音频")
    }
}

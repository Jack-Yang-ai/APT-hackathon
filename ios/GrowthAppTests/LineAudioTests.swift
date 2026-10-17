import XCTest
import GRDB
@testable import GrowthApp

/// 把一行转写定位回它自己那段音频。
///
/// 🔴 **这组测试守的是「不许猜」。**
/// 认人时放错音频,用户会听着**别人的声音**照屏幕上的字确认「这是小李」——
/// 一整簇话记到错的人名下,而归属一错,表态与承诺全跟着错。
final class LineAudioTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var day: String { "2026-08-17" }

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-17T10:00:00+08:00', ?, 'recording', 'closed')
                """, arguments: [day])
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (1, 1, 1, 1, 'a', 'frozen', 'x')
                """)
        }
    }
    override func tearDownWithError() throws { dbQueue = nil }

    /// 测试里的块按**名义 300 秒**排布(造数时就是这么造的),
    /// 所以这里给的 offsets 是名义值 —— 它验的是「块内换算这一层对不对」,
    /// 而「块起点从哪来」由 `BlockTiming` 那一层负责。
    private var offsets: [Int: Int] {
        Dictionary(uniqueKeysWithValues: (0...9).map { ($0, $0 * 300_000) })
    }

    private func line(_ id: Int64, startMs: Int, endMs: Int, blockSeq: Int?) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, block_seq)
                VALUES (?, 1, ?, ?, ?, '一句话', 0, ?)
                """, arguments: [id, id, startMs, endMs, blockSeq])
        }
    }

    /// 造一个块文件,好让「文件在不在」这一关能过。
    private func makeBlockFile(_ seq: Int) throws -> URL {
        let dir = ProcessingPump.recordingsRoot.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(String(format: "block-%04d.m4a", seq))
        try Data([0]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - 不许猜

    /// 🔴 **`block_seq` 是 NULL 时必须说「定位不到」,不许拿 `t_start_ms / 300_000` 反推。**
    ///
    /// 这条红了就说明有人给它加了 fallback,而那个 fallback 会在
    /// 块跑满(>300s)的场次上**取到另一个人的音频** —— 不报错、不越界。
    func testNullBlockSeqRefusesInsteadOfGuessing() throws {
        _ = try makeBlockFile(0)
        try line(1, startMs: 310_000, endMs: 315_000, blockSeq: nil)
        let r = try dbQueue.read { try LineAudio.clip(lineID: 1, offsets: offsets, in: $0) }
        XCTAssertEqual(r, .failure(.noBlockSeq),
                       "存量行没有块号,居然还是给出了一个片段 —— 那一定是猜的")
    }

    /// 同一个 `t_start_ms` 落在两个不同的块上时,**块号说了算**。
    /// 这正是 v15 那条列存在的理由:块 0 第 310 秒与块 1 第 10 秒的
    /// `t_start_ms` 都是 310000。
    func testSameTStartMsResolvesToDifferentFilesByBlockSeq() throws {
        let f0 = try makeBlockFile(0), f1 = try makeBlockFile(1)
        try line(1, startMs: 310_000, endMs: 315_000, blockSeq: 0)   // 块 0 的第 310 秒
        try line(2, startMs: 310_000, endMs: 312_000, blockSeq: 1)   // 块 1 的第 10 秒

        let a = try dbQueue.read { try LineAudio.clip(lineID: 1, offsets: offsets, in: $0) }
        let b = try dbQueue.read { try LineAudio.clip(lineID: 2, offsets: offsets, in: $0) }
        guard case .success(let ca) = a, case .success(let cb) = b else {
            return XCTFail("两行都该定位得到:\(a) / \(b)")
        }
        XCTAssertEqual(ca.url, f0)
        XCTAssertEqual(cb.url, f1)
        // 块内偏移也要各归各的 —— 只对文件不对偏移,放出来还是别人的话
        XCTAssertEqual(ca.start, 310, accuracy: 0.001)
        XCTAssertEqual(cb.start, 10,  accuracy: 0.001)
    }

    /// 块号与时间戳对不上(算出负偏移)时,**也要拒绝**。
    /// 那是数据坏了,不是「早了一点」—— 从 0 开始放一段不知道是谁的声音更糟。
    func testNegativeOffsetIsRefused() throws {
        _ = try makeBlockFile(3)
        try line(1, startMs: 10_000, endMs: 12_000, blockSeq: 3)   // 块 3 应从 900_000 起
        XCTAssertEqual(try dbQueue.read { try LineAudio.clip(lineID: 1, offsets: offsets, in: $0) },
                       .failure(.noBlockSeq))
    }

    /// 音频文件没了要**说清楚**,不要返回一个指向不存在文件的片段 ——
    /// 那会让播放器静默失败,而按钮看起来是好的。
    func testMissingFileIsReportedNotReturned() throws {
        try line(1, startMs: 0, endMs: 3_000, blockSeq: 7)   // 没造 block-0007
        XCTAssertEqual(try dbQueue.read { try LineAudio.clip(lineID: 1, offsets: offsets, in: $0) },
                       .failure(.fileMissing))
    }

    /// 每一种失败都要**说得出口** —— 认人页上一个不说原因的灰喇叭,
    /// 用户只会理解成「这个 App 坏了」。
    func testEveryFailureHasAHumanReason() {
        for why: LineAudio.Unavailable in [.noBlockSeq, .fileMissing, .noSuchLine] {
            XCTAssertFalse(why.reason.isEmpty)
        }
    }

    /// 正常一行:偏移与时长都按块内算。
    func testNormalLineResolvesToItsOwnSlice() throws {
        _ = try makeBlockFile(2)
        try line(1, startMs: 600_000 + 12_500, endMs: 600_000 + 17_000, blockSeq: 2)
        guard case .success(let c)? = try dbQueue.read({ try LineAudio.clip(lineID: 1, offsets: offsets, in: $0) })
        else { return XCTFail("该定位得到") }
        XCTAssertEqual(c.start, 12.5, accuracy: 0.001)
        XCTAssertEqual(c.duration, 4.5, accuracy: 0.001)
    }
}

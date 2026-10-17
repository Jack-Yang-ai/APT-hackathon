import XCTest
import GRDB
@testable import GrowthApp

/// 「事」这一格第一版:零散悬点区(§4.3.8)。
///
/// 这一层最容易出的错都不会报错:滤掉挂起 ⇒ 永远空页而库里明明有几十条 ·
/// 不筛 active 版本 ⇒ 显示用户根本看不到的那一版产出的条目 ·
/// 自己给说话人编号 ⇒ 与别的屏对不上,用户认错人。
final class MattersProjectionTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
    }
    override func tearDownWithError() throws { dbQueue = nil }

    /// 造一场:一版转写、一行、一条承诺。`activate` 决定它是不是当前生效那版。
    @discardableResult
    private func session(_ sid: Int64, startedAt: String, transcript tid: Int64,
                         line lid: Int64, text: String,
                         what: String, pending: Bool = false,
                         activate: Bool = true) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO sessions (id, started_at, day, source, status)
                VALUES (?, ?, ?, 'recording', 'closed')
                """, arguments: [sid, startedAt, String(startedAt.prefix(10))])
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (?, ?, 1, 1, 'a', 'frozen', 'x')
                """, arguments: [tid, sid])
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, block_seq)
                VALUES (?, ?, 0, 0, 3000, ?, 0, 0)
                """, arguments: [lid, tid, text])
            try db.execute(sql: """
                INSERT INTO summary_commitments
                  (transcript_id, line_id, seq, what, quote, pending, pending_reason)
                VALUES (?, ?, 0, ?, ?, ?, ?)
                """, arguments: [tid, lid, what, text, pending ? 1 : 0,
                                 pending ? "归属未定" : nil])
            if activate {
                try db.execute(sql: "UPDATE sessions SET active_transcript_id = ? WHERE id = ?",
                               arguments: [tid, sid])
            }
            return tid
        }
    }

    /// 🔴 **挂起的条目必须显示出来,只是要标出来。**
    ///
    /// 今天库里**每一条都是挂起**(`ExtractValidate:173` 要 `personID != nil`,
    /// 而簇标签写的 person 恒为 nil)。滤掉的话这一格永远是空的,
    /// 而库里明明有几十条真实的承诺 —— 那是「有数据却显示没有」,
    /// 比显示一条待核的更糟。
    func testPendingItemsAreShownButMarked() throws {
        try session(1, startedAt: "2026-08-17T10:00:00+08:00", transcript: 1,
                    line: 10, text: "我周四之前给你", what: "周四之前给", pending: true)
        let ends = try MattersProjection.looseEnds(in: dbQueue)
        XCTAssertEqual(ends.count, 1, "挂起的被滤掉了 —— 这一格会永远空着")
        XCTAssertTrue(ends[0].unverified)
        XCTAssertEqual(ends[0].unverifiedReason, "归属未定")
    }

    /// 只读**当前生效**的那一版转写。
    /// 不筛的话会把重转写之前那版的承诺也捞出来 —— 而用户在界面上
    /// 根本看不到那一版,却会看到它产出的条目。
    func testOnlyTheActiveTranscriptContributes() throws {
        try session(1, startedAt: "2026-08-17T10:00:00+08:00", transcript: 1,
                    line: 10, text: "旧版说的", what: "旧版", activate: false)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (2, 1, 2, 1, 'a', 'frozen', 'x')
                """)
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
                VALUES (11, 2, 0, 0, 3000, '新版说的', 0)
                """)
            try db.execute(sql: """
                INSERT INTO summary_commitments (transcript_id, line_id, seq, what, quote)
                VALUES (2, 11, 0, '新版', '新版说的')
                """)
            try db.execute(sql: "UPDATE sessions SET active_transcript_id = 2 WHERE id = 1")
        }
        let ends = try MattersProjection.looseEnds(in: dbQueue)
        XCTAssertEqual(ends.map(\.text), ["新版"], "把用户看不到的那一版的条目也捞出来了")
    }

    /// 承诺与待定**两类都要**,时间倒序。
    func testBothKindsSortedNewestFirst() throws {
        try session(1, startedAt: "2026-08-10T10:00:00+08:00", transcript: 1,
                    line: 10, text: "老的那条", what: "老承诺")
        try session(2, startedAt: "2026-08-17T10:00:00+08:00", transcript: 2,
                    line: 20, text: "新的那条", what: "新承诺")
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO summary_pendings (transcript_id, line_id, seq, issue, quote)
                VALUES (2, 20, 1, '还没定的事', '新的那条')
                """)
        }
        let ends = try MattersProjection.looseEnds(in: dbQueue)
        XCTAssertEqual(ends.first?.sessionStartedAt.prefix(10), "2026-08-17")
        XCTAssertTrue(ends.contains { $0.kind == .pending })
        XCTAssertTrue(ends.contains { $0.kind == .commitment })
    }

    /// 说话人称呼只从 `SpeakerNaming` 取 —— 各屏自己编号是 2026-08-14
    /// 实拍过的 bug:同一个人在两屏上是两个号,用户会确认错人。
    func testSpeakerLabelComesFromTheSingleSource() throws {
        try session(1, startedAt: "2026-08-17T10:00:00+08:00", transcript: 1,
                    line: 10, text: "我来跟进", what: "跟进")
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO line_speakers (line_id, person_id, source, confidence, updated_at)
                VALUES (10, 7, '声纹识别', 0.9, 'x')
                """)
        }
        let ends = try MattersProjection.looseEnds(in: dbQueue)
        let expected = try dbQueue.read { try SpeakerNaming.labels(in: $0) }["p:7"]
        XCTAssertEqual(ends[0].speaker, expected)
        XCTAssertNotNil(expected)
    }

    /// 没有归属的行,`speaker` 就是 nil —— **不编一个「说话人 1」**。
    /// 「不知道是谁」和「是某个人」是两件事,别用同一个值表示。
    func testUnattributedLineHasNoSpeakerRatherThanAFakeOne() throws {
        try session(1, startedAt: "2026-08-17T10:00:00+08:00", transcript: 1,
                    line: 10, text: "有人说了句话", what: "某事")
        XCTAssertNil(try MattersProjection.looseEnds(in: dbQueue)[0].speaker)
    }

    func testEmptyLibraryYieldsEmptyList() throws {
        XCTAssertTrue(try MattersProjection.looseEnds(in: dbQueue).isEmpty)
    }
}

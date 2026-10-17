import XCTest
import GRDB
@testable import GrowthApp

/// 块跑过 300 秒时,这一场会不会卡死。
///
/// 🔴 **这是一条「链路永久卡死」的缺陷,不是成本问题。**
/// 块长上界是 330 秒(`BlockCutPolicy.latestMs`),而内核注入的是真探针,
/// 切在 300 秒之后是常态。写死 `keptIntervals = [0, 300_000]` 的话,
/// 300 秒之后的行会让 `restoreToBlockTime` 抛,而 `pump` 的 `try?` 吞掉且不记事件
/// ⇒ 任务停在 `running` ⇒ 这一场再也走不动,重启也救不回来。
final class OverlongBlockTests: XCTestCase {

    /// 300 秒之后的行,在写死 300 秒的保留区间下会被拒 —— **先证明这个前提成立**,
    /// 否则下面那条修复测试可能在测一个不存在的问题。
    func testTimestampBeyondTheKeptRangeThrows() {
        XCTAssertThrowsError(try TranscriptFreeze.restoreToBlockTime(
            trimmedMs: 310_000,
            keptIntervals: [KeptInterval(startMs: 0, endMs: 300_000)],
            blockSeq: 0))
    }

    /// 而按**真实块长**给保留区间,同一行就还原得出来。
    func testTheSameTimestampResolvesWhenTheRealLengthIsUsed() throws {
        let ms = try TranscriptFreeze.restoreToBlockTime(
            trimmedMs: 310_000,
            keptIntervals: [KeptInterval(startMs: 0, endMs: 330_000)],
            blockSeq: 0)
        XCTAssertEqual(ms, 310_000)
    }

    /// 整场跑一遍:一块 330 秒、里面有一行落在第 310 秒 —— **必须冻结成功**。
    ///
    /// 这一条红了就说明 `keptIntervals` 又被写死成 300 秒了,
    /// 而真机上的表现是「这一场卡在整理中,永远不动,日志里什么都没有」。
    func testAnOverlongBlockStillFreezes() throws {
        let db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        try db.write { d in
            try d.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-08-17T10:00:00+08:00', '2026-08-17', 'recording', 'closed')
                """)
        }
        let block = BlockTranscript(
            blockSeq: 0, offsetMs: 0,
            // 真实块长 330 秒 —— 这正是 BlockCutPolicy 的上界
            keptIntervals: [KeptInterval(startMs: 0, endMs: 330_000)],
            lines: [ASRLine(startMs: 5_000,   endMs: 9_000,   text: "开头"),
                    ASRLine(startMs: 310_000, endMs: 315_000, text: "第 310 秒这一句")])

        let r = try TranscriptFreeze.freeze(sessionID: 1, asrModel: "a",
                                            blocks: [block], now: "x", in: db)
        XCTAssertEqual(r.lineCount, 2, "超过 300 秒的那一行被丢了或者整场抛了")

        let last = try db.read { d in
            try Int.fetchOne(d, sql:
                "SELECT MAX(t_start_ms) FROM transcript_lines WHERE is_gap = 0") ?? -1
        }
        XCTAssertEqual(last, 310_000)
    }
}

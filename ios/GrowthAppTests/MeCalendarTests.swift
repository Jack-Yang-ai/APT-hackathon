import XCTest
import GRDB
@testable import GrowthApp

/// 「我」页日历(`M5-1` 件 5)。
final class MeCalendarTests: XCTestCase {
    typealias Month = MonthGrid.Month

    /// 2026-10-01 是周四 ⇒ 周一开头前面空 3 格;10 月 31 天。
    func testOctober2026StartsOnThursday() {
        let cells = MonthGrid.cells(Month(year: 2026, month: 10))
        XCTAssertEqual(cells.prefix(4), [nil, nil, nil, 1])
        XCTAssertEqual(cells.compactMap { $0 }.count, 31)
    }

    /// 2027-02-01 是周一 ⇒ 一格不空;平年 28 天。
    func testFebruary2027StartsOnMondayWithNoPadding() {
        let cells = MonthGrid.cells(Month(year: 2027, month: 2))
        XCTAssertEqual(cells.first, 1)
        XCTAssertEqual(cells.count, 28)
    }

    /// 2026-11-01 是周日 ⇒ 空 6 格(周日在最后一列)。
    func testSundayStartPadsSix() {
        XCTAssertEqual(MonthGrid.cells(Month(year: 2026, month: 11)).prefix(7),
                       [nil, nil, nil, nil, nil, nil, 1])
    }

    /// 按周切:每行恰好 7 格(日历每格定高,行数不齐会让格子挪位)。
    func testWeeksAreRowsOfSeven() {
        let w = MonthGrid.weeks(Month(year: 2026, month: 10))
        XCTAssertEqual(w.count, 5)               // 3 空 + 31 天 = 34 ⇒ 补成 35
        XCTAssertTrue(w.allSatisfy { $0.count == 7 })
        XCTAssertEqual(w.last?.last, .some(nil))
    }

    func testMonthArithmeticWrapsYears() {
        XCTAssertEqual(Month(year: 2026, month: 12).adding(1), Month(year: 2027, month: 1))
        XCTAssertEqual(Month(year: 2026, month: 1).adding(-1), Month(year: 2025, month: 12))
        XCTAssertTrue(Month(year: 2026, month: 9) < Month(year: 2026, month: 10))
    }

    /// 键的写法要与 `sessions.day` 一致,不然日历上一个点都对不上。
    func testKeyMatchesSessionDayFormat() {
        XCTAssertEqual(Month(year: 2026, month: 3).key(day: 5), "2026-03-05")
    }

    /// 移出记忆的场次不算「那天有录音」—— 与「更早」计数同一个判据。
    func testRecordedDaysSkipRemovedSessions() throws {
        let db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, '2026-10-09T09:00:00+08:00', '2026-10-09', 'recording', 'closed'),
                       (2, '2026-10-10T09:00:00+08:00', '2026-10-10', 'recording', 'closed')
                """)
            try db.execute(sql: "UPDATE sessions SET removed_at = '2026-10-11T00:00:00+08:00' WHERE id = 2")
        }
        XCTAssertEqual(try HomeProjection.recordedDays(in: db), ["2026-10-09"])
    }
}

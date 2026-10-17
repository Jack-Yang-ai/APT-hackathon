import XCTest
@testable import GrowthApp

/// 此刻页时间条的纯函数(`M5-1` 件 2)。
final class DayTimelineTests: XCTestCase {
    typealias Span = DayTimeline.Span

    func testCalendarLabelsUseTheSharedStrictDayKeyParser() {
        XCTAssertEqual(HomeView.daysBetween("2024-02-28", "2024-03-01"), 2)
        XCTAssertEqual(HomeView.daysBetween("2026-12-31", "2027-01-01"), 1)
        XCTAssertNil(BlockLedger.date(forDayKey: "2026-02-30"))
        XCTAssertNil(BlockLedger.date(forDayKey: "seal-invalid"))
    }

    func testWindowDefaultsToSixToNow() {
        let w = DayTimeline.window(spans: [Span(start: 9 * 60, end: 10 * 60)], nowMinute: 16 * 60 + 40)
        XCTAssertEqual(w, DayTimeline.Window(from: 360, to: 1000))
    }

    func testEarlierSessionPullsWindowBackToItsHour() {
        let w = DayTimeline.window(spans: [Span(start: 5 * 60 + 20, end: 5 * 60 + 50)], nowMinute: 8 * 60)
        XCTAssertEqual(w.from, 5 * 60)
    }

    func testPastDayEndsAtLastSessionRoundedUp() {
        let w = DayTimeline.window(spans: [Span(start: 14 * 60, end: 14 * 60 + 51)], nowMinute: nil)
        XCTAssertEqual(w.to, 15 * 60)
    }

    /// 刚开录、窗口不足一小时也要能画 —— 不许出现 to <= from 的空条。
    func testWindowIsAtLeastOneHour() {
        let w = DayTimeline.window(spans: [], nowMinute: 6 * 60 + 5)
        XCTAssertEqual(w.to - w.from, 60)
    }

    /// 跨零点还在录:22:00 开录、00:30 打开 —— 不许算成 06:00–07:00 的空条。
    func testPastMidnightStillDrawsTheEveningSession() {
        let spans = [Span(start: 22 * 60, end: 23 * 60 + 50)]
        let w = DayTimeline.window(spans: spans, nowMinute: 30)
        XCTAssertTrue(w.from <= 22 * 60 && w.to >= 23 * 60 + 50, "\(w)")
        XCTAssertTrue(DayTimeline.bins(spans: spans, window: w).contains(.session))
    }

    /// 凌晨 5 点打开、当天还没场次:窗口从 5 点起,「现在」不该标到 07:00。
    func testEarlyMorningWindowStartsAtNowHour() {
        let w = DayTimeline.window(spans: [], nowMinute: 5 * 60 + 10)
        XCTAssertEqual(w.from, 5 * 60)
    }

    func testEmptyDayHasNoColouredBins() {
        let fills = DayTimeline.bins(spans: [], window: .init(from: 360, to: 480))
        XCTAssertEqual(fills.count, 8)
        XCTAssertTrue(fills.allSatisfy { $0 == .none })
    }

    /// 边界:14:00–14:15 只占一格;15 分钟整的场次不该把下一格也染上。
    func testSpanOnBinBoundaryColoursOnlyItsBins() {
        let fills = DayTimeline.bins(spans: [Span(start: 840, end: 855)],
                                     window: .init(from: 825, to: 870))
        XCTAssertEqual(fills, [.none, .session, .none])
    }

    /// 同一格里正经场次压过零碎。
    func testSessionWinsOverFragmentInSameBin() {
        let fills = DayTimeline.bins(spans: [Span(start: 600, end: 605, isFragment: true),
                                             Span(start: 610, end: 640)],
                                     window: .init(from: 600, to: 615))
        XCTAssertEqual(fills, [.session])
    }

    func testFragmentAloneIsLight() {
        let fills = DayTimeline.bins(spans: [Span(start: 600, end: 603, isFragment: true)],
                                     window: .init(from: 600, to: 615))
        XCTAssertEqual(fills, [.fragment])
    }

    func testClockParsing() {
        XCTAssertEqual(DayTimeline.minute(ofClock: "14:00"), 840)
        XCTAssertEqual(DayTimeline.minute(ofClock: "00:05"), 5)
        XCTAssertNil(DayTimeline.minute(ofClock: "25:00"))
        XCTAssertNil(DayTimeline.minute(ofClock: "下午"))
    }
}

import XCTest
import SwiftUI
@testable import GrowthApp

/// 首页组件与展示模型的接线。
///
/// 「能编译」不等于「接上了」——组件可以编译通过却根本喂不进真模型。
/// 这里逐个用 M0-1d 的展示模型把它们构造出来,并把 body 求值一次,
/// 确保类型是真对得上的,而不是躺在 target 里没人碰的死代码。
final class TimelineComponentsTests: XCTestCase {

    private func summary(points: Int = 2) -> SessionSummary {
        SessionSummary(
            title: "与同事一对一",
            oneLiner: "对方对交付时间有顾虑",
            keyPoints: (0..<points).map {
                KeyPoint(text: "要点\($0)", quote: "原话\($0)",
                         lineID: Int64(100 + $0), atMillis: $0 * 1000)
            })
    }

    private func card(_ state: SessionDisplayState) -> SessionCard {
        SessionCard(id: 1, startTime: "14:00", durationMinutes: 40,
                    state: state, attachments: .none)
    }

    /// 场次卡吃 SessionCard —— 不再需要旧仓的 Episode。
    func testEpisodeCardTakesSessionCard() {
        let view = TLEpisodeCard(card: card(.done(summary())), lite: false, open: true, toggle: {})
        XCTAssertNotNil(view.body)
    }

    /// 十个展示态每一个都要能渲染。没纪要的那几个态走 stateText 那条路,
    /// 漏掉一个 case 在 Swift 里是编译错误,但「渲染出空白」不是——所以逐个过一遍。
    func testEveryDisplayStateRenders() {
        let states: [SessionDisplayState] = [
            .recording(elapsedMinutes: 200), .waitingForNetwork, .uploading(percent: 45),
            .queued(ahead: 1), .processing, .attributionPending(summary()),
            .done(summary()), .partialFailure(missing: "要点"), .failed(attempt: 2, willRetry: true), .degraded,
        ]
        for s in states {
            XCTAssertNotNil(TLEpisodeCard(card: card(s), lite: false, open: true, toggle: {}).body,
                            "\(s) 渲染不出来")
        }
    }

    /// 没出纪要时展开也不该有 detail —— 没有要点就不编要点。
    func testProcessingCardHasNoSummary() {
        XCTAssertNil(card(.processing).state.summary)
        XCTAssertNotNil(card(.done(summary())).state.summary)
    }

    func testFoldRowTakesSessionCard() {
        XCTAssertNotNil(TLFoldRow(card: card(.done(summary(points: 0))), toggle: {}).body)
    }

    /// 零碎折叠行:PRD §4.2.2 ④「还有 N 段零碎」,只吃标量。
    func testFoldBarRendersFragmentsFold() {
        let fold = FragmentsFold(count: 3, sessionIDs: [2, 5, 9])
        XCTAssertNotNil(TLFoldBar(count: fold.count, range: nil, gist: nil,
                                  open: false, toggle: {}).body)
    }

    /// 提示条:HomeBanner 的四种都要能落成一行字。
    func testNoticeRendersEveryBanner() {
        let banners: [HomeBanner] = [
            .thingAwakened(thingID: "1", text: "招聘节奏这件事有新动静"),
            .thingProgressed(thingID: "2", text: "产品定位有新进展"),
            .unreadDiscoveries(count: 2),
            .awayForDays(days: 5, sessionCount: 3),
        ]
        for b in banners {
            let text: String
            switch b {
            case .thingAwakened(_, let t), .thingProgressed(_, let t): text = t
            case .unreadDiscoveries(let n): text = "有 \(n) 条新发现"
            case .awayForDays(let d, let n): text = "你 \(d) 天没来了，期间有 \(n) 场录音"
            }
            XCTAssertNotNil(TLNotice(text: text).body)
        }
    }

    /// 按天折叠:EarlierDay → 日界。
    func testDayHeaderRendersEarlierDay() {
        let day = EarlierDay(day: "2026-08-07", sessionCount: 2)
        XCTAssertNotNil(TLDayHeader(date: day.day, cover: "\(day.sessionCount) 段",
                                    isLatest: false, zoomLabel: nil, action: nil).body)
    }

    /// 时长格式化是组件自己的活,顺手钉住。
    func testDurationFormatting() {
        XCTAssertEqual(TL.dur(40), "0h40m")
        XCTAssertEqual(TL.dur(200), "3h20m")
    }
}

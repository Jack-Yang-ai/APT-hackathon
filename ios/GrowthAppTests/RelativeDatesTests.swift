import XCTest
@testable import GrowthApp

/// 相对时间词 → 日期区间(`M2-检2` §1.2)。
///
/// 这一层最容易出的错都**不报错**:词表没进包(恒不生效)、周首日跟随系统区域
/// (同一句在两台手机上差一天)、日期串与 `sessions.day` 差一个口径(区间框空)。
/// 所以下面每一条钉的都是「不会红但是错」的那种。
final class RelativeDatesTests: XCTestCase {

    private let bundle = Bundle(for: RelativeDatesTests.self)
    private var calendar: Calendar { RelativeDates.growthCalendar }

    /// `yyyy-MM-dd` → Date,当天 12:00(避开夏令时把午夜挪走那类边界)。
    private func day(_ key: String) -> Date {
        let p = key.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour) = (p[0], p[1], p[2], 12)
        return calendar.date(from: c)!
    }

    private func resolve(_ q: String, on today: String) -> RelativeDates.Interval? {
        RelativeDates.resolve(q, today: day(today), bundle: bundle, calendar: calendar)
    }

    // MARK: - 词表真的在包里

    /// 🔴 词表没进 target 时,`resolve` 恒返回 nil —— **而那和「这句话里没有相对
    /// 时间词」长得一模一样**,不会有任何东西报错。这条是那个失败模式的唯一哨兵。
    func testTheLexiconIsActuallyInTheBundle() {
        let table = RelativeDates.lexicon(bundle: bundle)
        XCTAssertFalse(table.isEmpty, "relative_dates.json 没进测试 target(project.yml 里补一行)")
        XCTAssertNotNil(table.days["昨天"])
        XCTAssertNotNil(table.weeks["下周"])
    }

    /// 读不到词表时不崩(增强件不阻塞主线),但**计数必须涨**,否则就是静默失败(仓规 6)。
    ///
    /// 🔴 断言「涨了」而不是「计数为 0」:计数是全局的,拿绝对值断言等于让这条
    /// 测试依赖执行顺序。
    func testAMissingLexiconIsCountedRatherThanSilent() {
        let before = RelativeDates.lexiconLoadFailures
        XCTAssertNil(RelativeDates.resolve("昨天呢", today: day("2026-09-07"),
                                           bundle: Bundle(for: XCTestCase.self),
                                           calendar: calendar))
        XCTAssertGreaterThan(RelativeDates.lexiconLoadFailures, before)
    }

    /// 词表刻意不收边界不确定的词。收了它们等于让代码去猜,而猜错不报错。
    func testVagueWordsAreDeliberatelyAbsent() {
        let table = RelativeDates.lexicon(bundle: bundle)
        for vague in ["最近", "前阵子", "上次", "以前"] {
            XCTAssertNil(table.days[vague], "「\(vague)」没有确定边界,不该进词表")
            XCTAssertNil(table.weeks[vague])
        }
    }

    // MARK: - 单天

    func testYesterdayIsASingleDay() {
        let i = resolve("昨天谁提到交付", on: "2026-09-07")
        XCTAssertEqual(i?.from, "2026-09-06")
        XCTAssertEqual(i?.to, "2026-09-06")
        XCTAssertEqual(i?.cues, ["昨天"])
    }

    func testTodayIsASingleDay() {
        let i = resolve("今天说了什么", on: "2026-09-07")
        XCTAssertEqual(i?.from, "2026-09-07")
        XCTAssertEqual(i?.to, "2026-09-07")
    }

    func testTomorrowCrossesIntoTheNextMonth() {
        let i = resolve("明天有什么安排", on: "2026-08-31")
        XCTAssertEqual(i?.from, "2026-09-01")
        XCTAssertEqual(i?.to, "2026-09-01")
    }

    func testTomorrowCrossesIntoTheNextYear() {
        let i = resolve("明天有什么安排", on: "2026-12-31")
        XCTAssertEqual(i?.from, "2027-01-01")
        XCTAssertEqual(i?.to, "2027-01-01")
    }

    func testYesterdayCrossesBackIntoThePreviousYear() {
        let i = resolve("昨天说了什么", on: "2027-01-01")
        XCTAssertEqual(i?.from, "2026-12-31")
    }

    /// 多天词覆盖的是一段,不是一天。
    func testAMultiDayWordCoversARange() {
        let i = resolve("这几天在忙什么", on: "2026-09-07")
        XCTAssertEqual(i?.from, "2026-09-05")
        XCTAssertEqual(i?.to, "2026-09-07")
    }

    // MARK: - 最长匹配

    /// 🔴 「大后天」含「后天」。不先匹配长的,「大后天」会被当成「后天」——
    /// 差一天,而且**不报错**。
    func testTheLongerWordWinsWhenOneContainsTheOther() {
        let i = resolve("大后天要交付吗", on: "2026-09-07")
        XCTAssertEqual(i?.from, "2026-09-10", "「大后天」被当成「后天」了")
        XCTAssertEqual(i?.cues, ["大后天"], "同一段字既算大后天又算后天 —— 命中后没抹掉")
    }

    // MARK: - 周

    /// 周一为一周之首(中文习惯),**写死不跟随系统区域**。
    func testLastWeekRunsMondayToSunday() {
        // 2026-09-07 是周一。
        XCTAssertEqual(calendar.component(.weekday, from: day("2026-09-07")), 2, "夹具日子不是周一了")
        let i = resolve("上周谁提到交付时间", on: "2026-09-07")
        XCTAssertEqual(i?.from, "2026-08-31")
        XCTAssertEqual(i?.to, "2026-09-06")
    }

    func testThisWeekOnAMondayStartsThatSameDay() {
        let i = resolve("本周有什么安排", on: "2026-09-07")
        XCTAssertEqual(i?.from, "2026-09-07")
        XCTAssertEqual(i?.to, "2026-09-13")
    }

    /// 🔴 周日是**本周的最后一天**,不是下一周的第一天。周首日若跟随系统区域
    /// (很多地区是周日),这条会差整整一周。
    func testSundayBelongsToTheWeekThatStartedOnMonday() {
        XCTAssertEqual(calendar.component(.weekday, from: day("2026-09-13")), 1, "夹具日子不是周日了")
        let i = resolve("这周有什么安排", on: "2026-09-13")
        XCTAssertEqual(i?.from, "2026-09-07")
        XCTAssertEqual(i?.to, "2026-09-13")
    }

    func testNextWeekIsTheFollowingMondayToSunday() {
        let i = resolve("下周有什么安排", on: "2026-09-07")
        XCTAssertEqual(i?.from, "2026-09-14")
        XCTAssertEqual(i?.to, "2026-09-20")
    }

    func testWeekSynonymsResolveToTheSameRange() {
        let a = resolve("下周有什么安排", on: "2026-09-07")
        for synonym in ["下个星期有什么安排", "下星期有什么安排"] {
            XCTAssertEqual(resolve(synonym, on: "2026-09-07")?.from, a?.from)
            XCTAssertEqual(resolve(synonym, on: "2026-09-07")?.to, a?.to)
        }
    }

    // MARK: - 多个词

    /// 两个词命中时取并集的首末两天;cues 按**在问句里出现的先后**给,不按词长。
    func testTwoCuesUnionTheirRangesAndKeepReadingOrder() {
        let i = resolve("昨天和下周分别有什么", on: "2026-09-07")
        XCTAssertEqual(i?.from, "2026-09-06")
        XCTAssertEqual(i?.to, "2026-09-20")
        XCTAssertEqual(i?.cues, ["昨天", "下周"])
    }

    // MARK: - 不解析的情况

    func testAQuestionWithoutAnyCueYieldsNothing() {
        XCTAssertNil(resolve("首页的信息优先级定了没有", on: "2026-09-07"))
    }

    func testAnEmptyLexiconYieldsNothingRatherThanCrashing() {
        let empty = RelativeDates.Lexicon(days: [:], weeks: [:])
        XCTAssertNil(RelativeDates.resolve("昨天呢", today: day("2026-09-07"),
                                           lexicon: empty, calendar: calendar))
    }

    /// 跨度上限:太宽的区间对排序没有信息(几乎所有场次都算「在范围内」),
    /// 所以不划界。包里那份词表任何组合都撞不到 31 天,拿造出来的词表撞。
    func testARangeWiderThanTheCapIsRefused() {
        let wide = RelativeDates.Lexicon(days: ["很久以前": (offset: -60, span: 1),
                                                "今天": (offset: 0, span: 1)],
                                         weeks: [:])
        XCTAssertNil(RelativeDates.resolve("很久以前到今天", today: day("2026-09-07"),
                                           lexicon: wide, calendar: calendar),
                     "跨 61 天还划了界 —— 上限没生效")
        XCTAssertNotNil(RelativeDates.resolve("今天", today: day("2026-09-07"),
                                              lexicon: wide, calendar: calendar))
    }

    // MARK: - 区间与场次日期对得上

    func testContainsIsInclusiveOnBothEnds() {
        let i = RelativeDates.Interval(from: "2026-08-31", to: "2026-09-06", cues: ["上周"])
        XCTAssertTrue(RelativeDates.contains(i, day: "2026-08-31"))
        XCTAssertTrue(RelativeDates.contains(i, day: "2026-09-06"))
        XCTAssertTrue(RelativeDates.contains(i, day: "2026-09-02"))
        XCTAssertFalse(RelativeDates.contains(i, day: "2026-08-30"))
        XCTAssertFalse(RelativeDates.contains(i, day: "2026-09-07"))
    }

    /// 场次时间戳是本地 ISO,前十位就是本地日期 —— 不要再过一次时区转换。
    func testSessionDayIsTheFirstTenCharactersOfItsLocalTimestamp() {
        XCTAssertEqual(RelativeDates.day(ofSessionStartedAt: "2026-08-13T10:00:00+08:00"),
                       "2026-08-13")
    }

    /// 🔴 日期串的口径必须与 `sessions.day` 同源。对不上不会报错,
    /// 只是「上周」框住的场次少一天。`AudioRetention.dayKey` 是写 `sessions.day`
    /// 那条路上的口径,两边逐日比一年。
    func testDayKeyAgreesWithTheOneThatWritesSessionsDay() {
        var d = day("2026-01-01")
        for _ in 0..<365 {
            XCTAssertEqual(RelativeDates.dayKey(d, calendar: calendar), AudioRetention.dayKey(d))
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }
    }
}

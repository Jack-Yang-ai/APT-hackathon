import Foundation

/// 问句里的相对时间词 → 一个**日期区间**。`M2-检2` §1.2。
///
/// ## 它不生成日期串去搜转写 —— 那条路被实测否掉了
///
/// 原设计(照 VoiceMem)是把「下周」展开成七个绝对日期,拼进检索串。
/// **实测语料 24 万字里,完整绝对日期只出现 5 次,而相对时间词出现 207 次**
/// (`docs/evidence/m2-检2/date_surface.md`,脚本 `eval/date_surface_freq.py`)。
/// 那套在 VoiceMem 成立是因为它检索的是**抽取产物**(写入时已归一成绝对日期);
/// 我们的 L1 检索的是**转写原文**,原文里写的是人怎么说的。
/// 拿七个日期串去搜转写,搜的是一个几乎不存在的字符串。
///
/// 还有一层更糟的:转写里的「下周」是**说话那天**的下周,与提问那天的下周不是同一周。
/// 拿字面「下周」去匹配,匹到的是别的周的事 —— **而这个错不报错**。
///
/// ⇒ 所以这里产出的是**区间**,用途是给区间内的场次**加权**(见 `AskRetrieval`),
/// 内容层建成后再用它过滤条目的 `valid_from` —— 那时对面才是归一过的绝对日期。
///
/// ## 只收边界确定的词
///
/// 词表(`relative_dates.json`)刻意不收「最近」「前阵子」「上次」:
/// 它们没有确定边界,收进来等于让代码去猜,而猜错**不报错**。
enum RelativeDates {

    /// 一个闭区间,两端都是 `yyyy-MM-dd` 的本地日期,与 `sessions.day` 同口径。
    struct Interval: Equatable {
        /// 起(含)
        let from: String
        /// 止(含)
        let to: String
        /// 命中的词,按出现顺序。**说得出是因为哪个词才划的界** —— 界面与日志都要它。
        let cues: [String]
    }

    /// 区间最多跨多少天。超过就不划界:一个横跨两个月的「区间」对排序没有信息,
    /// 而它会把几乎所有场次都算成「在范围内」,等于没加权。
    static let maxSpanDays = 31

    /// 一周之首 = 周一(中文习惯)。**写死不跟随系统区域** ——
    /// 跟随的话,同一句「上周」在不同手机上会解析成差一天的两个区间,而两边都不报错。
    static let firstWeekday = 2

    // MARK: - 词表

    struct Lexicon {
        /// 词 → (相对今天的偏移天数, 覆盖天数)
        let days: [String: (offset: Int, span: Int)]
        /// 词 → 相对本周一的周偏移
        let weeks: [String: Int]

        var isEmpty: Bool { days.isEmpty && weeks.isEmpty }
    }

    /// 词表读不出来的次数。**不是零就说明有一次提问没享受到这条腿**。
    ///
    /// 为什么记数而不是抛:相对时间是**增强**,它挂了不该让整次提问失败
    /// (同 `docs/方案-词库与候选挖掘.md` §2 抄 YouNavi 的那条:
    /// 「热词是增强功能,挂了不该阻塞转写」)。而仓规 6 说失败必须可见 ——
    /// 所以走「记录」那一支,并由 `RelativeDatesTests` 钉住「包里真的有这份词表」。
    private(set) nonisolated(unsafe) static var lexiconLoadFailures = 0

    /// 词表从包里读一次,之后复用。
    static func lexicon(bundle: Bundle = .main) -> Lexicon {
        if let cached = cache[bundle.bundlePath] { return cached }
        let loaded = load(bundle: bundle)
        cache[bundle.bundlePath] = loaded
        return loaded
    }

    private nonisolated(unsafe) static var cache: [String: Lexicon] = [:]

    private static func load(bundle: Bundle) -> Lexicon {
        guard let url = bundle.url(forResource: "relative_dates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            lexiconLoadFailures += 1
            return Lexicon(days: [:], weeks: [:])
        }
        var days: [String: (offset: Int, span: Int)] = [:]
        for (word, raw) in (root["days"] as? [String: [Int]] ?? [:]) where raw.count == 2 {
            days[word] = (raw[0], raw[1])
        }
        let weeks = root["weeks"] as? [String: Int] ?? [:]
        if days.isEmpty && weeks.isEmpty { lexiconLoadFailures += 1 }
        return Lexicon(days: days, weeks: weeks)
    }

    // MARK: - 解析

    /// 问句 → 区间。没有相对时间词、或跨度超过 `maxSpanDays` 时返回 nil。
    ///
    /// - Parameters:
    ///   - today: **必传**,函数内不取系统时间 —— 取了就没法在测试里固定「今天」,
    ///     而「今天是哪天」正是这件事唯一的变量。
    static func resolve(_ question: String,
                        today: Date,
                        bundle: Bundle = .main,
                        calendar: Calendar = growthCalendar) -> Interval? {
        resolve(question, today: today, lexicon: lexicon(bundle: bundle), calendar: calendar)
    }

    /// 同上,但词表由调用方给。**测试用这一支** —— 跨度上限这类守卫要拿造出来的
    /// 词表去撞(包里那份词表任何组合都撞不到 31 天,而守卫不能因此没有测试)。
    static func resolve(_ question: String,
                        today: Date,
                        lexicon table: Lexicon,
                        calendar: Calendar = growthCalendar) -> Interval? {
        guard !table.isEmpty else { return nil }

        // 长词先匹配:不先匹配「上个星期」的话,「上星期」这类会被更短的词切碎。
        let words = (Array(table.days.keys) + Array(table.weeks.keys))
            .sorted { $0.count > $1.count }

        var cues: [String] = []
        var covered: [Date] = []
        var consumed = question
        for word in words {
            guard consumed.contains(word) else { continue }
            cues.append(word)
            // 命中即抹掉,免得「上个星期」命中后「上周」在剩下的串里再命中一次。
            consumed = consumed.replacingOccurrences(of: word, with: "\u{0}")
            if let spec = table.days[word] {
                guard let start = calendar.date(byAdding: .day, value: spec.offset, to: today)
                else { continue }
                covered += (0..<max(spec.span, 1)).compactMap {
                    calendar.date(byAdding: .day, value: $0, to: start)
                }
            } else if let weekOffset = table.weeks[word] {
                guard let monday = mondayOfWeek(containing: today, calendar: calendar),
                      let start = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: monday)
                else { continue }
                covered += (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            }
        }
        guard !covered.isEmpty else { return nil }

        let keys = covered.map { dayKey($0, calendar: calendar) }.sorted()
        guard let low = keys.first, let high = keys.last else { return nil }
        // 跨度按**首末两天**算,不按命中的天数 —— 「昨天和下周」中间空着的那几天
        // 照样落在区间里,该按区间的实际宽度判。
        guard let lowDate = calendar.date(from: dayComponents(low)),
              let highDate = calendar.date(from: dayComponents(high)),
              let span = calendar.dateComponents([.day], from: lowDate, to: highDate).day,
              span + 1 <= maxSpanDays
        else { return nil }

        // cues 按在问句里出现的先后给,不按词长 —— 说出来给人看的东西按人读的顺序。
        let ordered = cues.sorted { a, b in
            (question.range(of: a)?.lowerBound ?? question.startIndex)
                < (question.range(of: b)?.lowerBound ?? question.startIndex)
        }
        return Interval(from: low, to: high, cues: ordered)
    }

    /// 某个日期串在不在区间里。两端都含。
    ///
    /// 比的是 `yyyy-MM-dd` 的**字典序** —— 这个格式下字典序与时间序一致,
    /// 不用再解析成 `Date`(解析要带时区,而两侧串本来就是同一时区写下的)。
    static func contains(_ interval: Interval, day: String) -> Bool {
        day >= interval.from && day <= interval.to
    }

    /// 场次时间戳(本地 ISO)→ 日期串。`sessions.started_at` 的前十位就是本地日期。
    static func day(ofSessionStartedAt iso: String) -> String { String(iso.prefix(10)) }

    // MARK: - 日历

    /// 本地时区 + 周一为首。
    static var growthCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = firstWeekday
        return c
    }

    private static func mondayOfWeek(containing date: Date, calendar: Calendar) -> Date? {
        // `weekday` 是 1=周日…7=周六。距本周一的天数 = (weekday + 5) % 7。
        let weekday = calendar.component(.weekday, from: date)
        return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: date)
    }

    /// `yyyy-MM-dd`。⚠️ 与 `AudioRetention.dayKey`、`sessions.day` 必须同口径 ——
    /// 对不上不会报错,只是「上周」框住的场次少一天。`RelativeDatesTests` 有一条钉着它。
    static func dayKey(_ date: Date, calendar: Calendar = growthCalendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func dayComponents(_ key: String) -> DateComponents {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        if parts.count == 3 { (c.year, c.month, c.day) = (parts[0], parts[1], parts[2]) }
        return c
    }
}

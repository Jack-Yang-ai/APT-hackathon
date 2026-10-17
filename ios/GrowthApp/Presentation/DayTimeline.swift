import SwiftUI

/// 此刻页录音卡里那条「06:00 → 现在」的时间条(`M5-1` spec §二)。
///
/// 🔴 **只画有依据的东西**:一格着色 = 这一刻钟里有场次。**不画音量柱** ——
/// 库里没有逐段音量,画一排高低不齐的柱子等于给一个看起来有信息、实际是编的图。
enum DayTimeline {

    /// 一场在当天的起止,单位:当天第几分钟(00:00 = 0)。
    struct Span: Equatable {
        let start: Int
        let end: Int
        /// 零碎(很短的场次)画浅色,与正经的场次分开。
        var isFragment = false
    }

    enum Fill: Equatable { case none, fragment, session }

    struct Window: Equatable {
        let from: Int
        let to: Int
    }

    /// 窗口:默认 06:00 起;有更早的场次就从它所在的整点起。
    /// 止点 = 现在(今天)或最后一场结束的整点(过去的日子),至少比起点晚一小时。
    static func window(spans: [Span], nowMinute: Int?) -> Window {
        let earliest = spans.map(\.start).min()
        // 跨零点还在录(22:00 开录、00:30 打开):场次都记在开录那天,而墙钟已经翻了 ——
        // 「现在」比最早一场还早就说明翻过零点了,这时按过去的日子画,不拿墙钟截窗口
        //(否则窗口算成 06:00–07:00,一格都不着色;2026-10-12 对抗审查)。
        let now = nowMinute.flatMap { n in earliest.map { n < $0 } == true ? nil : n }
        var from = min(6 * 60, ((earliest ?? 6 * 60) / 60) * 60)
        if let now { from = min(from, (now / 60) * 60) }   // 凌晨 5 点打开,窗口从 5 点起
        let latestEnd = spans.map(\.end).max() ?? from
        let rawTo = now.map { max($0, latestEnd) } ?? Int((Double(latestEnd) / 60).rounded(.up)) * 60
        return Window(from: from, to: min(24 * 60, max(rawTo, from + 60)))
    }

    /// 把窗口按 `step` 分钟切格,每格取覆盖它的场次里「最重」的那种。
    static func bins(spans: [Span], window: Window, step: Int = 15) -> [Fill] {
        guard step > 0, window.to > window.from else { return [] }
        let count = Int((Double(window.to - window.from) / Double(step)).rounded(.up))
        return (0..<count).map { i in
            let a = window.from + i * step, b = a + step
            let hits = spans.filter { $0.start < b && $0.end > a }
            if hits.contains(where: { !$0.isFragment }) { return .session }
            if !hits.isEmpty { return .fragment }
            return .none
        }
    }

    /// 「14:00」→ 840。认不出来返回 nil(不猜)。
    static func minute(ofClock s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

struct DayTimelineBar: View {
    let fills: [DayTimeline.Fill]
    let window: DayTimeline.Window
    let isToday: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(fills.enumerated()), id: \.offset) { _, f in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(f))
                        .frame(height: f == .none ? 14 : 44)
                }
            }
            .frame(height: 44, alignment: .bottom)
            .accessibilityHidden(true)

            GeometryReader { geo in
                let span = CGFloat(window.to - window.from)
                ZStack(alignment: .topLeading) {
                    Text(clock(window.from))
                    if 12 * 60 > window.from + 60, 12 * 60 < window.to - 60 {
                        Text("12:00").offset(x: geo.size.width * CGFloat(12 * 60 - window.from) / span - 16)
                    }
                    Text(isToday ? "现在" : clock(window.to))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(DS.C.dim)
            .frame(height: 16)
        }
    }

    private func color(_ f: DayTimeline.Fill) -> Color {
        switch f {
        case .session:  return DS.C.brand
        case .fragment: return DS.C.brand.opacity(0.38)
        case .none:     return DS.C.panel2
        }
    }

    private func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
}

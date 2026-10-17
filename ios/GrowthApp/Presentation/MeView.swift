import SwiftUI
import GRDB

/// 「我」(`M5-1` spec §六;画布 08)。日历回看 · 导入 · 设置。
///
/// ~~今天花了 / 这个月~~ 这期不做:记账在云代理里(R2),手机上没有这份数,
/// 为它新开一个接口不划算。处理详情在「设置」里(`SettingsView` 的最近处理记录)。
struct MeView: View {
    @ObservedObject var vm: RecordingViewModel

    @State private var month = MonthGrid.Month(date: Date())
    @State private var recorded: Set<String> = []
    @State private var loadFailure: String?
    @State private var templateCount = 0
    @State private var latestScope: AskScope?
    @ScaledMetric(relativeTo: .body) private var dayHeight: CGFloat = 44

    var body: some View {
        // ⚠️ **不用 `List`。** 2026-10-12 实拍闪退:日历网格放进 `List` 的格子里,
        // 格子的自适应高度两次算出来不一样(265 ↔ 309),UICollectionView 判成
        // 「递归布局死循环」直接 fatalError。滚动页 + 自画卡片,同一字号的日历行保持稳定高度。
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("回到那一天。")
                            .font(DS.pageTitle).foregroundStyle(DS.C.ink)
                        Text("回看切分好的事件，带着背景继续问。")
                            .font(.subheadline).foregroundStyle(DS.C.dim)
                    }.padding(.top, 8).padding(.bottom, 20)
                    calendar
                        .padding(.horizontal, geometry.size.width < 372 ? 0 : 12)
                        .padding(.vertical, 16)
                        .background(DS.C.panel, in: DS.panelShape())
                        .overlay(DS.panelShape().stroke(DS.C.line.opacity(0.6), lineWidth: 1))
                    Text(loadFailure ?? "有点的日子有事件，点进去回看。")
                        .font(DS.F.meta)
                        .foregroundStyle(DS.C.dim)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    if let latestScope {
                        ContextualAskButton(database: vm.database, scope: latestScope,
                            question: "这件事有哪些值得记住的内容？", title: "问问最近的事件")
                            .padding(.top, 12)
                    }

                    VStack(spacing: 0) {
                        NavigationLink { MyVoiceView(vm: vm) } label: {
                            MeRow(icon: .record, title: "我的声音",
                                  detail: "\(templateCount) 份样本")
                        }
                        Divider().overlay(DS.C.line).padding(.horizontal, DS.S.pad)
                        NavigationLink { ImportView(vm: vm) } label: {
                            MeRow(icon: .source, title: "导入录音或纪要")
                        }
                        Divider().overlay(DS.C.line).padding(.horizontal, DS.S.pad)
                        NavigationLink { SettingsView(vm: vm) } label: {
                            MeRow(icon: .me, title: "设置")
                        }
                    }
                    .buttonStyle(.plain)
                    .background(DS.C.panel, in: DS.panelShape())
                    .overlay(DS.panelShape().stroke(DS.C.line.opacity(0.6), lineWidth: 1))
                    .padding(.top, 24)
                }
                .padding(.horizontal, geometry.size.width < 372 ? 6 : DS.S.side)
                .padding(.vertical, 8)
            }
            .background(DS.C.bg)
            .navigationTitle("我")
            .navigationBarTitleDisplayMode(.inline)
            .task { load() }
            .onAppear { load() }
            .onChange(of: vm.feed) { _, _ in load() }
        }
    }

    private func load() {
        guard let db = vm.database else { loadFailure = "主库没打开，日历读不出来"; return }
        do {
            let days = try HomeProjection.eventDays(in: db)
            let count = try VoiceprintRegistry.templateCounts(in: db, model: VoiceprintModel.current)[SpeakerNaming.mePersonID] ?? 0
            latestScope = try days.sorted().last.flatMap { day in
                try HomeProjection.understoodEvents(day: day, in: db).first.map { AskScope(sessionID: $0.sessionID, eventID: $0.event.id) }
            }
            if recorded != days { recorded = days }
            if templateCount != count { templateCount = count }
            if loadFailure != nil { loadFailure = nil }
        }
        catch { loadFailure = "读日历出错:\(error)" }
    }

    // MARK: - 日历

    private var calendar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(String(month.year)) 年 \(month.month) 月")
                    .font(.headline)
                Spacer()
                Button { month = month.adding(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("上个月")
                    .frame(width: 44, height: 44)
                Button { month = month.adding(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("下个月")
                    .frame(width: 44, height: 44)
                    .disabled(month >= MonthGrid.Month(date: Date()))
            }
            .buttonStyle(.borderless)

            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                    Text($0).font(.caption.weight(.medium)).foregroundStyle(DS.C.dim)
                        .frame(maxWidth: .infinity)
                }
            }
            // 每格都有真实布局容器,点击区至少44。Group不占布局,混合链接与空格会错列。
            let weeks = MonthGrid.weeks(month)
            VStack(spacing: 4) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            ZStack {
                                if let day { dayCell(day) } else { Color.clear }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: dayHeight)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Int) -> some View {
        let key = month.key(day: day)
        let isToday = key == vm.todayKey
        let has = recorded.contains(key)
        let label = VStack(spacing: 3) {
            Text("\(day)")
                .font(.subheadline.weight(isToday ? .semibold : .regular).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.5)
                .foregroundStyle(isToday ? DS.C.brand : (has ? DS.C.ink : DS.C.dim))
            Circle().fill(has ? DS.C.brand : .clear).frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: dayHeight)
        .background {
            if isToday { Capsule().fill(DS.C.brandSoft).padding(.horizontal, 2) }
        }
        .contentShape(Rectangle())

        if has {
            NavigationLink {
                DaySessionsView(title: HomeView.monthDay(key), day: key, vm: vm)
            } label: { label }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel("\(HomeView.monthDay(key))，有事件")
        } else {
            label.accessibilityLabel("\(HomeView.monthDay(key))，没有事件")
        }
    }
}

/// 月历格子的纯函数:周一开头,前面补空。
enum MonthGrid {
    struct Month: Equatable, Comparable {
        let year: Int
        let month: Int

        init(year: Int, month: Int) { self.year = year; self.month = month }

        init(date: Date) {
            let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
            self.init(year: c.year ?? 2026, month: c.month ?? 1)
        }

        func adding(_ n: Int) -> Month {
            let total = year * 12 + (month - 1) + n
            return Month(year: total / 12, month: total % 12 + 1)
        }

        /// 「2026-10-09」—— 与 `sessions.day` 同一个写法。
        func key(day: Int) -> String { String(format: "%04d-%02d-%02d", year, month, day) }

        static func < (a: Month, b: Month) -> Bool { (a.year, a.month) < (b.year, b.month) }
    }

    /// 按周切成每行 7 格,末行用 nil 补齐。
    static func weeks(_ m: Month) -> [[Int?]] {
        var c = cells(m)
        while c.count % 7 != 0 { c.append(nil) }
        return stride(from: 0, to: c.count, by: 7).map { Array(c[$0..<$0 + 7]) }
    }

    /// nil = 月初之前的空格。
    static func cells(_ m: Month) -> [Int?] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        guard let first = cal.date(from: DateComponents(year: m.year, month: m.month, day: 1)),
              let days = cal.range(of: .day, in: .month, for: first)?.count else { return [] }
        // weekday:周日 = 1 … 周六 = 7 ⇒ 周一开头时前面空几格
        let lead = (cal.component(.weekday, from: first) + 5) % 7
        return Array(repeating: nil, count: lead) + (1...days).map { Optional($0) }
    }
}

/// 日历下面的中性图标行；长标题与样本数随系统大字换行。
struct MeRow: View {
    let icon: AptGlyph.Kind
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            AptGlyph(kind: icon).foregroundStyle(DS.C.ink)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body).foregroundStyle(DS.C.ink)
                if let detail { Text(detail).font(.caption).foregroundStyle(DS.C.dim) }
            }.fixedSize(horizontal: false, vertical: true)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.C.line2)
        }
        .padding(.horizontal, DS.S.pad)
        .padding(.vertical, 16)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

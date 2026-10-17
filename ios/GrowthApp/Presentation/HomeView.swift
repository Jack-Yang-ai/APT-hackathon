import SwiftUI
import GRDB

/// 此刻只呈现语义事件；录音分片与处理账本留在数据层和出处。
struct HomeView: View {
    @ObservedObject var vm: RecordingViewModel
    @State private var pastDay: String?
    @State private var pastEvents: [UnderstoodEvent] = []
    @State private var loadFailure: String?
    @State private var watchConnection = WatchInbox.shared.connection
    @State private var showsWatchDetails = false
    private var shownDay: String { pastDay ?? vm.todayKey }
    private var events: [UnderstoodEvent] { pastDay == nil ? vm.feed?.understood ?? [] : pastEvents }
    private var days: [String] { [vm.todayKey] + (vm.feed?.earlier ?? []).map(\.day).filter { HomeView.daysBetween($0,vm.todayKey).map { $0<=6 } ?? false } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:0) {
                HStack {
                    Menu {
                        ForEach(days,id:\.self) { day in
                            Button(HomeView.dayLabel(day,today:vm.todayKey)) { pastDay = day == vm.todayKey ? nil : day }
                        }
                    } label: {
                        HStack(spacing:6) { Text(HomeView.monthDay(shownDay));Image(systemName:"chevron.down").font(.caption) }
                            .font(.headline).frame(minHeight:44)
                    }.accessibilityLabel("切换日期，现在看的是 \(HomeView.dayLabel(shownDay,today:vm.todayKey))")
                    Spacer()
                    Text("\(events.count) 件事件").font(.caption).foregroundStyle(DS.C.dim)
                }
                DisclosureGroup(isExpanded: $showsWatchDetails) {
                    Text(watchConnection.detail).font(.caption).foregroundStyle(DS.C.dim).padding(.vertical,8)
                } label: {
                    Label(watchConnection.title,systemImage:watchConnection == .reachable ? "link" : "applewatch")
                        .font(.caption).foregroundStyle(DS.C.dim)
                }.padding(.bottom,20).accessibilityIdentifier("watch-connection-status")
                if let notice = vm.watchNotice {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("部分录音尚未接入，原件已保留").font(.subheadline.weight(.semibold))
                        Text(notice).font(.caption).foregroundStyle(DS.C.sub)
                        Button("重试同步") { vm.pumpProcessing() }.font(.caption).frame(minHeight: 44)
                    }.padding(.bottom, 16).accessibilityIdentifier("watch-sync-blocked")
                }
                if vm.watchNotice != nil || (pastDay == nil && !(vm.feed?.digest?.brokenSessionIDs.isEmpty ?? true)) {
                    NavigationLink("有录音待处理，查看处理状态") { ProcessingRecoveryView(vm:vm) }
                        .font(.caption).padding(.bottom,12)
                }
                if let failure=loadFailure ?? vm.databaseFailure {
                    Text(failure).font(.subheadline).foregroundStyle(DS.C.ink)
                } else if events.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        Text("还没有切分好的事件").font(.headline)
                        Text("事件整理好后会出现在这里，也可以随时和 Agent 聊聊。").font(.subheadline).foregroundStyle(DS.C.dim)
                    }.padding(.vertical,24)
                } else {
                    ForEach(events) { item in
                        NavigationLink { SessionDetailView(sessionID:item.sessionID,database:vm.database,eventID:item.event.id) } label: {
                            HomeEventRow(item:item)
                        }.buttonStyle(.plain)
                        Divider().overlay(DS.C.line.opacity(0.6))
                    }
                }
            }.padding(.horizontal,DS.S.side).padding(.top,8).padding(.bottom,24)
        }.background(DS.C.bg).toolbarTitleDisplayMode(.inline)
            .task { vm.checkRelaunchGap() }
            .task(id:pastDay) { loadPast() }
            .onReceive(vm.$feed) { _ in if pastDay != nil { loadPast() } }
            .onReceive(NotificationCenter.default.publisher(for:WatchInbox.connectionChanged)) { _ in watchConnection=WatchInbox.shared.connection }
    }
    private func loadPast() {
        guard let pastDay else { pastEvents=[];loadFailure=nil;return }
        guard let db=vm.database else { loadFailure="主库尚未打开";return }
        do { pastEvents=try HomeProjection.understoodEvents(day:pastDay,in:db);loadFailure=nil }
        catch { loadFailure="事件读不出来：\(error)" }
    }

    // MARK: - 日期与时长的写法

    /// 「2026-10-12」→「10月12日」。认不出来原样返回。
    static func monthDay(_ day: String) -> String {
        let p = day.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return day }
        return "\(m)月\(d)日"
    }

    /// 菜单里的写法:今天 · 10月12日 / 昨天 · 10月11日 / 10月9日。
    static func dayLabel(_ day: String, today: String) -> String {
        switch daysBetween(day, today) {
        case 0: return "今天 · \(monthDay(day))"
        case 1: return "昨天 · \(monthDay(day))"
        default: return monthDay(day)
        }
    }

    static func daysBetween(_ a: String, _ b: String) -> Int? {
        guard let da = BlockLedger.date(forDayKey: a), let db = BlockLedger.date(forDayKey: b) else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: da, to: db).day
    }

    /// 「6 小时 12 分」/「38 分钟」/「不到 1 分钟」。
    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        if m < 1 { return "不到 1 分钟" }
        if m < 60 { return "\(m) 分钟" }
        return m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分"
    }
}

struct HomeEventRow: View {
    let item: UnderstoodEvent
    var body: some View {
        HStack(alignment:.top,spacing:12) {
            VStack(alignment:.leading,spacing:3) {
                let clocks=item.event.clockRange?.components(separatedBy:"–") ?? []
                Text(clocks.first ?? "时间待核").font(.caption.weight(.medium))
                if clocks.count>1 { Text(clocks[1]).font(.caption).foregroundStyle(DS.C.dim) }
            }.monospacedDigit().frame(width:48,alignment:.leading)
            VStack(alignment:.leading,spacing:5) {
                Text(item.event.title).font(.subheadline.weight(.semibold)).foregroundStyle(DS.C.ink).lineLimit(1)
                Text(item.event.summary).font(.subheadline).foregroundStyle(DS.C.sub).lineLimit(2)
            }.frame(maxWidth:.infinity,alignment:.leading)
            Image(systemName:"chevron.right").font(.caption).foregroundStyle(DS.C.dim).padding(.top,4)
        }.padding(.vertical,14).frame(maxWidth:.infinity,minHeight:64,alignment:.leading).contentShape(Rectangle())
    }
}

/// 原话行的时间写法沿用既有格式。
enum SessionCardView {
    static func stamp(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }
}

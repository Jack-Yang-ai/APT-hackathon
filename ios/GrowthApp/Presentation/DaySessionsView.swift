import SwiftUI
import GRDB

/// 日历回看与此刻使用同一套语义事件，不按录音场次或传输分片展示。
struct DaySessionsView: View {
    let title: String
    let day: String
    @ObservedObject var vm: RecordingViewModel
    @State private var events: [UnderstoodEvent] = []
    @State private var loadFailure: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let loadFailure { Text(loadFailure).foregroundStyle(DS.C.ink) }
                else if events.isEmpty { Text("这一天还没有切分好的事件。").foregroundStyle(DS.C.dim).padding(.vertical,24) }
                ForEach(events) { item in
                    NavigationLink {
                        SessionDetailView(sessionID: item.sessionID, database: vm.database, eventID: item.event.id)
                    } label: { HomeEventRow(item: item) }
                    .buttonStyle(.plain)
                    Divider().overlay(DS.C.line.opacity(0.6))
                }
            }.padding(.horizontal, DS.S.side).padding(.top,12)
        }.background(DS.C.bg).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .onAppear { load() }
            .onChange(of: vm.feed) { _,_ in load() }
    }
    private func load() {
        guard let db=vm.database else { loadFailure="主库尚未打开";return }
        do { events=try HomeProjection.understoodEvents(day:day,in:db);loadFailure=nil }
        catch { events=[];loadFailure="事件读不出来：\(error)" }
    }
}

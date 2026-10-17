import SwiftUI

/// 首页的次级故障出口，也可从设置查看历史失败；重试只走原编排写入口。
struct ProcessingRecoveryView: View {
    @ObservedObject var vm: RecordingViewModel
    @State private var sessions: [ProcessingOrchestrator.RetryableSession] = []
    @State private var readFailure: String?
    @State private var selected: ProcessingOrchestrator.RetryableSession?
    @State private var showsConfirmation = false
    @State private var retrying: Int64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let readFailure {
                    Text(readFailure).foregroundStyle(DS.C.ink)
                    Button("重新读取") { reload() }
                } else if sessions.isEmpty {
                    Text("目前没有需要手动重试的录音").foregroundStyle(DS.C.dim)
                }
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Self.dateLabel(session.startedAt)).font(.headline)
                        Text(session.issue).font(.subheadline).foregroundStyle(DS.C.dim)
                        if let reason = session.blockedReason {
                            Text(reason).font(.subheadline).foregroundStyle(DS.C.dim)
                        } else {
                            Button(retrying == session.id ? "正在排入处理…" : "重试这份录音") {
                                selected = session
                                showsConfirmation = true
                            }
                            .disabled(retrying != nil)
                            .accessibilityIdentifier("retry-session-\(session.id)")
                        }
                    }
                    Divider()
                }
                if let notice = vm.relaunchNotice {
                    Text(notice).font(.subheadline).foregroundStyle(DS.C.ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.S.side)
        }
        .background(DS.C.bg)
        .navigationTitle("处理状态")
        .task { reload() }
        .onReceive(vm.$feed) { _ in reload() }
        .refreshable { reload() }
        .confirmationDialog("重新处理这份录音？", isPresented: $showsConfirmation,
                            titleVisibility: .visible, presenting: selected) { session in
            Button("重新处理") {
                guard retrying == nil else { return }
                retrying = session.id
                Task {
                    await vm.retrySession(session.id)
                    retrying = nil
                    reload()
                }
            }
            Button("取消", role: .cancel) { }
        } message: { _ in
            Text("重新转写或整理可能产生费用。原录音和已有内容会保留。")
        }
    }

    private func reload() {
        guard let db = vm.database else { readFailure = "主库尚未打开，请稍后重试"; return }
        do {
            sessions = try ProcessingOrchestrator.retryableSessions(in: db)
            readFailure = nil
        } catch { readFailure = "处理状态读不出来：\(error)" }
    }

    private static func dateLabel(_ value: String) -> String {
        guard let date = ISO8601DateFormatter.growth.date(from: value) else { return value }
        return date.formatted(.dateTime.year().month().day().hour().minute())
    }
}

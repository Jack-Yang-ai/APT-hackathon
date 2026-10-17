import SwiftUI
import GRDB

@MainActor
final class AskNavigation: ObservableObject {
    struct Request {
        let id = UUID()
        let scope: AskScope?
        let question: String?
        var preservingBackground = false
    }
    @Published var request: Request?
    func open(scope: AskScope?, question: String) { request = Request(scope: scope, question: question) }
    func openMain() { request = Request(scope: nil, question: nil, preservingBackground: true) }
}

/// 用户 2026-10-14 确认：此刻／行动／我，中央 Agent 与常驻输入进入主聊天。
struct AppShell: View {
    @ObservedObject var vm: RecordingViewModel
    @StateObject private var askNavigation = AskNavigation()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let db = vm.database {
                AppWorkspace(vm: vm, db: db)
            } else {
                UnavailableWorkspace(vm: vm)
            }
        }
        .environmentObject(vm)
        .environmentObject(askNavigation)
        .task {
            WatchInbox.shared.refreshConnection()
            vm.pumpProcessing(releasingBackoff: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchInbox.changed)) { _ in vm.refreshToday() }
        .onReceive(Timer.publish(every: BlockUploader.pollInterval, on: .main, in: .common).autoconnect()) { _ in
            vm.pumpProcessing()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                WatchInbox.shared.refreshConnection()
                vm.pumpProcessing(releasingBackoff: true)
            }
        }
    }
}

private struct AppWorkspace: View {
    @ObservedObject var vm: RecordingViewModel
    @StateObject private var chat: AskViewModel
    @EnvironmentObject private var navigation: AskNavigation
    @State private var tab: Tab = .now
    @State private var showingAsk = false
    @State private var openingForSend = false
    enum Tab: Hashable { case now, actions, me }

    init(vm: RecordingViewModel, db: DatabaseQueue) {
        self.vm = vm
        _chat = StateObject(wrappedValue: AskViewModel(db: db))
    }

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("此刻", image: "apt-now", value: Tab.now) {
                NavigationStack { HomeView(vm: vm).toolbar { agentToolbar } }
                    .safeAreaInset(edge: .bottom, spacing: 0) { floatingInput }
            }
            SwiftUI.Tab("行动", systemImage: "checklist", value: Tab.actions) {
                NavigationStack { ActionsView(vm: vm).toolbar { agentToolbar } }
                    .safeAreaInset(edge: .bottom, spacing: 0) { floatingInput }
            }
            SwiftUI.Tab("我", image: "apt-me", value: Tab.me) {
                NavigationStack { MeView(vm: vm).toolbar { agentToolbar } }
                    .safeAreaInset(edge: .bottom, spacing: 0) { floatingInput }
            }
        }
        .tint(DS.C.brand)
        .accessibilityHidden(showingAsk)
        .task { await chat.load() }
        .onReceive(vm.$feed) { _ in Task { await chat.load() } }
        .task(id: navigation.request?.id) { await receiveRequest() }
        .onChange(of: chat.inFlight || chat.isSwitching) { _, busy in
            if !busy {
                Task {
                    await receiveRequest()
                    if !showingAsk { await returnToMain() }
                }
            }
        }
        .fullScreenCover(isPresented: $showingAsk, onDismiss: { Task { await returnToMain() } }) {
            AskView(model: chat)
                .environmentObject(navigation)
                .overlay(alignment: .top) {
                    if navigation.request != nil && chat.inFlight {
                        Text("这问答完后，接着聊刚选的内容")
                            .font(.caption).padding(12).background(DS.C.brandSoft, in: Capsule())
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private var agentToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button { navigation.openMain() } label: {
                Mascot(working: chat.inFlight, size: 44).frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.plain).accessibilityLabel("打开问问")
                .accessibilityIdentifier("central-agent")
        }
    }

    private var floatingInput: some View {
        PageAskComposer(model: chat, coveredByChat: $showingAsk,
                        sending: $openingForSend, onSend: sendFromPage)
    }

    private func sendFromPage() {
        guard !openingForSend, chat.isMain, chat.canSend else { return }
        openingForSend = true
        showingAsk = true
        Task {
            openingForSend = false
            await chat.send()
        }
    }

    private func returnToMain() async {
        if !chat.isMain, !chat.inFlight, !chat.isSwitching {
            _ = await chat.openMain(preservingBackground: true)
        }
    }

    private func receiveRequest() async {
        guard let request = navigation.request else { return }
        showingAsk = true
        guard !chat.inFlight, !chat.isSwitching else { return }
        _ = await chat.openMain(attaching: request.scope, prefill: request.question,
                               preservingBackground: request.preservingBackground)
        if navigation.request?.id == request.id { navigation.request = nil }
    }
}

/// Tab 会缓存页面闭包；直接绑定呈现状态，聊天覆盖时撤下业务页输入的 AX 节点。
private struct PageAskComposer: View {
    @ObservedObject var model: AskViewModel
    @Binding var coveredByChat: Bool
    @Binding var sending: Bool
    let onSend: () -> Void

    var body: some View {
        if !coveredByChat {
            AskComposer(model: model, sending: sending, enabled: model.isMain,
                        showsBackground: true, onSend: onSend)
        }
    }
}

/// 主库失败时保留页面入口与设置，聊天不能写入时明确禁发送。
private struct UnavailableWorkspace: View {
    @ObservedObject var vm: RecordingViewModel
    @State private var tab = 0
    @State private var showingFailure = false
    @State private var draft = ""
    private var reason: String { vm.databaseFailure ?? "主库没打开，请重新打开 App 后再试。" }

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("此刻", image: "apt-now", value: 0) { page { HomeView(vm: vm) } }
            SwiftUI.Tab("行动", systemImage: "checklist", value: 1) { page { Text(reason).padding().background(DS.C.bg) } }
            SwiftUI.Tab("我", image: "apt-me", value: 2) { page { MeView(vm: vm) } }
        }.tint(DS.C.brand)
        .sheet(isPresented: $showingFailure) {
            NavigationStack {
                Text("问问暂时无法保存聊天。\n\(reason)").padding()
                    .navigationTitle("问问").toolbar { Button("关闭") { showingFailure = false } }
            }
        }
    }
    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().toolbar {
                ToolbarItem(placement: .principal) {
                    Button { showingFailure = true } label: { Mascot(size: 44) }
                        .accessibilityLabel("打开问问")
                }
            }
        }.safeAreaInset(edge: .bottom) {
            HStack {
                TextField("主库恢复后可继续问", text: $draft).disabled(true)
                Image(systemName: "arrow.up").frame(width: 44, height: 44)
            }.padding(16).background(DS.C.panel, in: DS.panelShape()).padding(DS.S.side)
                .background(DS.C.bg)
        }
    }
}

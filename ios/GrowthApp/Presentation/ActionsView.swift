import SwiftUI
import GRDB

struct ActionsView: View {
    @ObservedObject var vm: RecordingViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var actions: [PersonalAction] = []
    @State private var candidates: [ActionCandidate] = []
    @State private var legacy: [ActionCandidateStore.LegacySession] = []
    @State private var selected: ActionStatus?
    @State private var failure: String?
    @State private var adding = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.S.gap) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("让下一步清楚一点。").font(DS.pageTitle).foregroundStyle(DS.C.ink)
                        Text("你的行动、需要确认的事，都留在这里。")
                            .font(.subheadline).foregroundStyle(DS.C.dim)
                    }
                    Spacer(minLength: 4)
                    Button { adding = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                        .accessibilityLabel("新增行动")
                }.padding(.top, 8)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filter("全部", status: nil)
                        ForEach(ActionStatus.allCases) { filter($0.title, status: $0) }
                    }
                }
                if let failure {
                    Text(failure).font(.subheadline).foregroundStyle(DS.C.ink)
                    Button("重新读取") { load() }
                } else {
                    let shown = actions.filter { selected == nil || $0.shownStatus == selected }
                    ForEach(shown) { action in
                        NavigationLink { ActionDetailView(id: action.id, database: vm.database) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(action.shownStatus.title).font(.caption.weight(.semibold)).foregroundStyle(DS.C.brand)
                                Text(action.title).font(.headline).foregroundStyle(DS.C.ink)
                                if !action.nextStep.isEmpty { Text("下一步 · \(action.nextStep)").font(.subheadline).foregroundStyle(DS.C.sub) }
                                if let deadline = action.deadline { Text("期限 · \(ActionEditor.deadlineLabel(deadline))").font(.caption).foregroundStyle(DS.C.dim) }
                                if let warning = action.sourceWarning { Text(warning).font(.caption).foregroundStyle(DS.C.dim) }
                            }.actionPanel()
                        }.buttonStyle(.plain)
                    }
                    if selected == nil || selected == .confirm {
                        if !candidates.isEmpty {
                            Text("从记录中确认").font(.headline).foregroundStyle(DS.C.ink).padding(.top, 8)
                            Text("已核对后续动作和上下文；归属不明的先确认说话人。")
                                .font(.caption).foregroundStyle(DS.C.dim)
                        }
                        ForEach(candidates) { candidate in candidateCard(candidate) }
                        if !legacy.isEmpty { DisclosureGroup("旧记录 · \(legacy.count) 场待识别") {
                        ForEach(legacy) { source in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(source.title).font(.headline)
                                Text("这场记录尚未按个人待办识别，纪要和已保存的行动仍在。")
                                    .font(.caption).foregroundStyle(DS.C.dim)
                                Button(source.busy ? "正在识别，稍后更新" : "重新识别这场的行动") {
                                    do { try vm.reidentifyActions(source.id); load() }
                                    catch { failure = "行动识别没排上：\(error)" }
                                }.disabled(source.busy).frame(minHeight: 44)
                                Text("重新识别使用云端模型，不会重新转写录音。")
                                    .font(.caption).foregroundStyle(DS.C.dim)
                            }.actionPanel()
                        }
                        } }
                    }
                    if shown.isEmpty && (candidates.isEmpty || (selected != nil && selected != .confirm)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(selected == nil ? "从一件想做的事开始。" : "这里暂时没有\(selected!.title)的行动。")
                                .font(.headline).foregroundStyle(DS.C.ink)
                            Text("点右上角新增，也可以从录音提取结果里确认。")
                                .font(.subheadline).foregroundStyle(DS.C.dim)
                        }.actionPanel()
                    }
                }
            }.padding(.horizontal, DS.S.side).padding(.bottom, 24)
        }
        .background(DS.C.bg).navigationTitle("行动").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            NavigationLink { RemovedActionsView(database: vm.database) } label: {
                Text("已移除")
            }.accessibilityLabel("已移除的行动与候选")
        } }
        .onAppear { load() }
        .onReceive(vm.objectWillChange) { _ in load() }
        .onChange(of: vm.feed) { _, _ in load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { load() } }
        .onReceive(NotificationCenter.default.publisher(for: PersonalActionStore.changed)) { _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRemoval.changed)) { _ in load() }
        .sheet(isPresented: $adding) {
            ActionEditor(database: vm.database, action: nil)
        }
    }

    private func filter(_ title: String, status: ActionStatus?) -> some View {
        Button { selected = status } label: {
            Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 14).frame(minHeight: 44)
                .foregroundStyle(selected == status ? .white : DS.C.brand)
                .background(selected == status ? DS.C.brand : DS.C.brandSoft, in: Capsule())
        }.buttonStyle(.plain)
    }

    private func candidateCard(_ source: ActionCandidate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(source.admissionKind == "accepted" ? "承诺／决定" : source.admissionKind == "request" ? "尚未接下的请求" : "依赖跟进建议").font(.caption.weight(.semibold)).foregroundStyle(DS.C.brand)
            Text(source.title).font(.headline).foregroundStyle(DS.C.ink)
            Text(source.evidence).font(.caption).foregroundStyle(DS.C.dim)
            if source.pending { Text("提取结果仍需核验，请对照当前原话。") .font(.caption).foregroundStyle(DS.C.dim) }
            Text("“\(source.quote)”").font(.subheadline).foregroundStyle(DS.C.sub)
            ForEach(Array(source.contextQuotes.filter { $0 != source.quote }.enumerated()), id: \.offset) { _, quote in
                Text("“\(quote)”").font(.caption).foregroundStyle(DS.C.dim)
            }
            if !source.conditions.isEmpty { Text("条件 · \(source.conditions)").font(.caption).foregroundStyle(DS.C.dim) }
            if !source.deadlineText.isEmpty { Text("期限 · \(source.deadlineText)").font(.caption).foregroundStyle(DS.C.dim) }
            Text("\(source.sourceTime) · 原话 v\(source.version) · AI 提取")
                .font(.caption).foregroundStyle(DS.C.dim)
            ViewThatFits(in: .horizontal) {
                HStack { candidateButtons(source) }
                VStack(alignment: .leading) { candidateButtons(source) }
            }
        }.actionPanel()
    }

    @ViewBuilder private func candidateButtons(_ source: ActionCandidate) -> some View {
        Button(source.isMine && !source.pending && source.admissionKind != "request" ? "保存为行动" : "保存为待确认") {
            guard let db = vm.database else { failure = "主库没打开，行动无法保存"; return }
            do {
                let stamp = ISO8601DateFormatter.growth.string(from: Date())
                _ = try db.write { try PersonalActionStore.adopt(source, now: stamp, in: $0) }
                load()
                NotificationCenter.default.post(name: PersonalActionStore.changed, object: nil)
            } catch { failure = "行动还没保存：\(error)" }
        }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        Button("忽略") {
            guard let db = vm.database else { return }
            do {
                try db.write { try PersonalActionStore.dismissCandidate(source, now: ISO8601DateFormatter.growth.string(from:Date()), in:$0) }
                NotificationCenter.default.post(name:PersonalActionStore.changed,object:nil); load()
            } catch { failure = "候选还没忽略：\(error)" }
        }.font(.subheadline).frame(minHeight:44)
        NavigationLink { SessionDetailView(sessionID: source.sessionID, database: vm.database) } label: {
            Text("查看出处与说话人").font(.subheadline).frame(minHeight: 44)
        }
    }

    private func load() {
        guard let db = vm.database else { failure = "主库没打开，行动读不出来"; return }
        do {
            (actions, candidates) = try db.read { (try PersonalActionStore.actions(in: $0), try PersonalActionStore.candidates(in: $0)) }
            legacy = try db.read { try ActionCandidateStore.unassessedSessions(in: $0) }
            failure = nil
        } catch { failure = "行动读不出来：\(error)" }
    }
}


private struct RemovedActionsView: View {
    let database: DatabaseQueue?
    @State private var actions: [PersonalAction] = []
    @State private var candidates: [PersonalActionStore.Dismissal] = []
    @State private var failure: String?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if let failure { Text(failure) }
                if actions.isEmpty && candidates.isEmpty { Text("没有已移除的行动或候选。").foregroundStyle(DS.C.dim) }
                ForEach(actions) { action in
                    VStack(alignment:.leading,spacing:8) {
                        Text(action.title).font(.headline)
                        Text("移除前 · \(action.status.title)").font(.caption).foregroundStyle(DS.C.dim)
                        Button("恢复行动") { mutate { db,stamp in try PersonalActionStore.restore(action.id,now:stamp,in:db) } }.frame(minHeight:44)
                    }.actionPanel()
                }
                ForEach(candidates) { item in
                    VStack(alignment:.leading,spacing:8) {
                        Text(item.title).font(.headline)
                        Text("已忽略的候选").font(.caption).foregroundStyle(DS.C.dim)
                        if item.source?.quoteIsCurrent != true { Text("出处已变化，恢复后需重新识别才会显示有效候选。").font(.caption).foregroundStyle(DS.C.dim) }
                        Button("恢复候选") { mutate { db,_ in try PersonalActionStore.restoreCandidate(item.id,in:db) } }.frame(minHeight:44)
                    }.actionPanel()
                }
            }.padding(DS.S.side).frame(maxWidth:.infinity,alignment:.leading)
        }.background(DS.C.bg).navigationTitle("已移除").navigationBarTitleDisplayMode(.inline)
            .onAppear { load() }
            .onReceive(NotificationCenter.default.publisher(for: PersonalActionStore.changed)) { _ in load() }
            .onReceive(NotificationCenter.default.publisher(for: MemoryRemoval.changed)) { _ in load() }
            .onReceive(NotificationCenter.default.publisher(for: WatchInbox.changed)) { _ in load() }
    }
    private func load() {
        guard let database else { failure="主库尚未打开";return }
        do {
            (actions,candidates)=try database.read { (try PersonalActionStore.actions(in:$0,includeRemoved:true).filter { $0.removedAt != nil },try PersonalActionStore.dismissals(in:$0)) }
            failure=nil
        } catch { failure="已移除的内容读不出来：\(error)" }
    }
    private func mutate(_ body:(Database,String)throws->Void) {
        guard let database else { return }
        do {
            try database.write { try body($0,ISO8601DateFormatter.growth.string(from:Date())) }
            NotificationCenter.default.post(name:PersonalActionStore.changed,object:nil);load()
        } catch { failure="恢复失败：\(error)" }
    }
}

private struct ActionDetailView: View {
    let id: Int64
    let database: DatabaseQueue?
    @EnvironmentObject private var navigation: AskNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var action: PersonalAction?
    @State private var failure: String?
    @State private var editing: PersonalAction?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let failure { Text(failure).foregroundStyle(DS.C.ink); Button("重新读取") { load() } }
                if let action {
                    Text(action.shownStatus.title).font(.subheadline.weight(.semibold)).foregroundStyle(DS.C.brand)
                    Text(action.title).font(DS.pageTitle).foregroundStyle(DS.C.ink)
                    info("下一步", action.nextStep.isEmpty ? "还没填写" : action.nextStep)
                    info("期限", action.deadline.map(ActionEditor.deadlineLabel) ?? "尚未设置具体时间")
                    if !action.extractedDeadline.isEmpty { info("期限说明", action.extractedDeadline) }
                    info("条件", action.conditions.isEmpty ? "尚未填写" : action.conditions)
                    info("协作人／依赖", action.collaborators.isEmpty ? "尚未填写" : action.collaborators)
                    if let warning = action.sourceWarning { Text(warning).font(.subheadline).foregroundStyle(DS.C.ink) }
                    if let source = action.source {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("当前出处 · \(source.evidence)").font(.headline)
                            Text("“\(source.quote)”").font(.body)
                            Text("\(source.sourceTime) · 原话 v\(source.version) · AI 提取").font(.caption).foregroundStyle(DS.C.dim)
                            if action.sourceWarning != nil { Text("保存时依据：原话 v\(action.sourceVersion ?? source.version)").font(.caption).foregroundStyle(DS.C.dim) }
                            NavigationLink("查看录音详情与原话") { SessionDetailView(sessionID: source.sessionID, database: database) }
                            if action.sourceWarning != nil && source.isMine && source.quoteIsCurrent {
                                Button("我已核对，采用当前依据") { mutate { db, stamp in try PersonalActionStore.revalidate(id, now: stamp, in: db) } }
                            }
                        }.actionPanel()
                    } else if action.sourceKey == nil { info("来源", "你手动创建的行动") }
                    Button("继续讨论这件行动") {
                        let scope = action.sourceWarning == nil ? action.source.map { AskScope(sessionID: $0.sessionID) } : nil
                        navigation.open(scope: scope, question: "一起讨论这件行动：\(action.title)\n下一步：\(action.nextStep)\n期限：\(action.deadline.map(ActionEditor.deadlineLabel) ?? "未设置")\n条件：\(action.conditions)\n协作人／依赖：\(action.collaborators)")
                    }.buttonStyle(.borderedProminent)
                    if action.status.isClosed {
                        Button("恢复行动") { changeStatus(nil) }.frame(minHeight: 44)
                    } else {
                        Button("标记已完成") { changeStatus(.done) }.frame(minHeight: 44)
                        Button("取消行动") { changeStatus(.cancelled) }.frame(minHeight: 44)
                    }
                    Button("移除行动") {
                        guard let database else { return }
                        do {
                            try database.write { try PersonalActionStore.remove(id,now:ISO8601DateFormatter.growth.string(from:Date()),in:$0) }
                            NotificationCenter.default.post(name:PersonalActionStore.changed,object:nil)
                            dismiss()
                        } catch { failure = "行动还没移除：\(error)" }
                    }.frame(minHeight:44)
                    Text("移除后可在行动页的“已移除”里恢复。").font(.caption).foregroundStyle(DS.C.dim)
                }
            }.padding(DS.S.side).frame(maxWidth: .infinity, alignment: .leading)
        }.background(DS.C.bg).navigationTitle("行动详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { editing = action }.disabled(action == nil).accessibilityLabel("编辑行动")
            } }
            .onAppear { load() }
            .onReceive(NotificationCenter.default.publisher(for: PersonalActionStore.changed)) { _ in load() }
            .onReceive(NotificationCenter.default.publisher(for: WatchInbox.changed)) { _ in load() }
            .onReceive(NotificationCenter.default.publisher(for: MemoryRemoval.changed)) { _ in load() }
            .sheet(item: $editing) { item in ActionEditor(database: database, action: item) }
    }

    private func info(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(DS.C.dim)
            Text(text).font(.body).foregroundStyle(DS.C.ink)
        }
    }
    private func load() {
        guard let database else { failure = "主库没打开，行动读不出来"; return }
        do {
            action = try database.read { try PersonalActionStore.actions(in: $0).first { $0.id == id } }
            failure = action == nil ? "行动已不存在" : nil
        } catch { failure = "行动读不出来：\(error)" }
    }
    private func changeStatus(_ status: ActionStatus?) {
        mutate { db, stamp in
            try PersonalActionStore.setStatus(id, status: status, now: stamp, in: db)
        }
    }
    private func mutate(_ body: (Database, String) throws -> Void) {
        guard let database else { return }
        do {
            try database.write { try body($0, ISO8601DateFormatter.growth.string(from: Date())) }
            NotificationCenter.default.post(name: PersonalActionStore.changed, object: nil)
            load()
        } catch { failure = "行动还没更新：\(error)" }
    }
}

private struct ActionEditor: View {
    let database: DatabaseQueue?
    let action: PersonalAction?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var status: ActionStatus = .next
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var conditions = ""
    @State private var nextStep = ""
    @State private var collaborators = ""
    @State private var deadlineText = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("行动") {
                    TextField("标题", text: $title, axis: .vertical)
                        .accessibilityLabel("行动标题")
                    Picker("状态", selection: $status) { ForEach(ActionStatus.allCases) { Text($0.title).tag($0) } }
                    TextField("下一步", text: $nextStep, axis: .vertical)
                        .accessibilityLabel("行动下一步")
                    TextField("期限说明", text: $deadlineText)
                    Toggle("设置期限", isOn: $hasDeadline)
                    if hasDeadline { DatePicker("期限", selection: $deadline) }
                }
                Section("安排") {
                    TextField("条件", text: $conditions, axis: .vertical)
                    TextField("协作人／依赖", text: $collaborators, axis: .vertical)
                }
                if let failure { Section { Text(failure).foregroundStyle(DS.C.ink) } }
            }
            .navigationTitle(action == nil ? "新增行动" : "编辑行动").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .onAppear {
                guard let action else { return }
                deadlineText = action.extractedDeadline
                title = action.title; status = action.shownStatus; conditions = action.conditions
                nextStep = action.nextStep; collaborators = action.collaborators
                hasDeadline = action.deadline != nil
                if let stamp = action.deadline, let date = ISO8601DateFormatter.growth.date(from: stamp) { deadline = date }
            }
        }
    }

    fileprivate static func deadlineLabel(_ value: String) -> String {
        guard let date = ISO8601DateFormatter.growth.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    private func save() {
        guard let database else { failure = "主库没打开，行动无法保存"; return }
        let stamp = ISO8601DateFormatter.growth.string(from: Date())
        let due = hasDeadline ? ISO8601DateFormatter.growth.string(from: deadline) : nil
        do {
            if var edited = action {
                edited.extractedDeadline = deadlineText
                edited.title = title; edited.status = status; edited.deadline = due
                edited.conditions = conditions; edited.nextStep = nextStep; edited.collaborators = collaborators
                try database.write { try PersonalActionStore.update(edited, now: stamp, in: $0) }
            } else {
                _ = try database.write { try PersonalActionStore.create(title: title, status: status, deadline: due, conditions: conditions,
                    nextStep: nextStep, collaborators: collaborators, deadlineText: deadlineText, now: stamp, in: $0) }
            }
            NotificationCenter.default.post(name: PersonalActionStore.changed, object: nil)
            dismiss()
        } catch { failure = "行动还没保存：\(error)" }
    }
}

private extension View {
    func actionPanel() -> some View {
        padding(DS.S.pad).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.C.panel, in: DS.panelShape())
            .overlay(DS.panelShape().stroke(DS.C.line.opacity(0.6), lineWidth: 1))
    }
}

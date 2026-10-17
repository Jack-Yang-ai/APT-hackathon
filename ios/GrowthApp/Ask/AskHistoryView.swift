import SwiftUI

/// 主聊天常驻；话题手动创建，不根据页面入口自动生成。
struct AskHistoryView: View {
    @ObservedObject var model: AskViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [AskConversation]?
    @State private var loadFailure: String?
    @State private var editor: TopicEditor?
    @State private var showArchived = false
    @State private var closeAfterEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let why = loadFailure {
                        Text(why).font(.subheadline).foregroundStyle(DS.C.danger)
                        Button("重新读取") { Task { await load() } }
                    }
                    if let list = conversations {
                        ForEach(list.filter(\.isMain), id: \.id) { row($0) }
                        HStack {
                            Text("我的话题").font(.headline).foregroundStyle(DS.C.ink)
                            Spacer()
                            Text("\(list.filter { !$0.isMain && !$0.archived }.count)")
                                .font(.subheadline).foregroundStyle(DS.C.dim)
                        }
                        let topics = list.filter { !$0.isMain && !$0.archived }
                        if topics.isEmpty {
                            Text("想持续聊的一件事，可以放进一个话题。")
                                .font(.subheadline).foregroundStyle(DS.C.dim).lineSpacing(4)
                        }
                        ForEach(topics, id: \.id) { row($0) }
                        let archived = list.filter { !$0.isMain && $0.archived }
                        if !archived.isEmpty {
                            DisclosureGroup("已归档 · \(archived.count)", isExpanded: $showArchived) {
                                VStack(spacing: 12) { ForEach(archived, id: \.id) { row($0) } }.padding(.top, 12)
                            }.font(.subheadline).foregroundStyle(DS.C.dim)
                        }
                    }
                    Button { editor = TopicEditor(conversationID: nil, name: "") } label: {
                        Label("新建话题", systemImage: "plus")
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                            .background(DS.C.brandSoft, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).foregroundStyle(DS.C.brand).disabled(model.inFlight || model.isSwitching)
                }.padding(20)
            }
            .background(DS.C.bg)
            .navigationTitle("聊天与话题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task { await load() }
        .sheet(item: $editor, onDismiss: {
            if closeAfterEditor { closeAfterEditor = false; dismiss() }
        }) { item in
            TopicNameSheet(initialName: item.name, isNew: item.conversationID == nil) { name in
                if let id = item.conversationID {
                    try await model.renameConversation(id, title: name)
                    await load()
                } else {
                    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { _ = try AskStore.normalizedTopicName(clean) }
                    await model.startNewConversation(title: clean.isEmpty ? nil : clean)
                    if model.readFailure == nil { closeAfterEditor = true }
                }
            }
        }
    }

    private func row(_ conversation: AskConversation) -> some View {
        let current = conversation.id == model.currentConversationID
        return Button {
            Task {
                await model.openConversation(conversation.id)
                if model.currentConversationID == conversation.id { dismiss() }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: conversation.isMain ? "sparkles" : "bubble.left")
                    .font(.system(size: 18)).foregroundStyle(DS.C.brand)
                    .frame(width: 36, height: 36).background(DS.C.brandSoft, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(conversation.isMain ? "主聊天" : (conversation.title ?? "未命名话题"))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(DS.C.ink).lineLimit(2)
                    Text(conversation.isMain ? "随时聊，所有记录都能问" : Self.day(conversation.updatedAt))
                        .font(.caption).foregroundStyle(DS.C.dim)
                }
                Spacer(minLength: 4)
                if current { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(DS.C.brand) }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.C.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(current ? DS.C.brand.opacity(0.5) : DS.C.line, lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(model.inFlight || model.isSwitching)
        .contextMenu {
            if !conversation.isMain {
                Button("改名", systemImage: "pencil") { editor = TopicEditor(conversationID: conversation.id, name: conversation.title ?? "") }
                Button(conversation.archived ? "取消归档" : "归档", systemImage: "archivebox") {
                    Task {
                        do { try await model.archiveConversation(conversation.id, archived: !conversation.archived); await load() }
                        catch { loadFailure = "\(error)" }
                    }
                }
            }
        }
    }

    private func load() async {
        do { conversations = try await model.conversations(); loadFailure = nil }
        catch { loadFailure = "话题读不出来：\(error)" }
    }

    static func day(_ iso: String) -> String { iso.count >= 10 ? String(iso.prefix(10)) : iso }
}

private struct TopicEditor: Identifiable {
    let id = UUID()
    let conversationID: Int64?
    let name: String
}

private struct TopicNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var failure: String?
    let isNew: Bool
    let save: (String) async throws -> Void

    init(initialName: String, isNew: Bool, save: @escaping (String) async throws -> Void) {
        _name = State(initialValue: initialName); self.isNew = isNew; self.save = save
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField(isNew ? "想聊什么？给话题起个名字" : "话题名称", text: $name)
                    .padding(16).background(DS.C.panel, in: RoundedRectangle(cornerRadius: 16))
                Text(isNew ? "最多 12 个字。也可以留空，用第一问命名。" : "最多 12 个字，聊天内容会保留。")
                    .font(.caption).foregroundStyle(DS.C.dim)
                if let failure { Text(failure).font(.caption).foregroundStyle(DS.C.danger) }
                Spacer()
            }.padding(20).background(DS.C.bg)
                .navigationTitle(isNew ? "新话题" : "改名")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isNew ? "开始聊" : "保存") {
                            Task {
                                do { try await save(name); dismiss() }
                                catch { failure = "\(error)" }
                            }
                        }
                    }
                }
        }.presentationDetents([.medium])
    }
}

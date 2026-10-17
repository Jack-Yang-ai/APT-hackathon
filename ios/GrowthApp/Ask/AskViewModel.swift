import Foundation
import GRDB

// 自由提问的编排(PRD §4.7.3)。
//
// 一次提问的顺序**不能变**:
//
//     落盘(askBegin) → 本地检索 → 渲染 prompt → 云 → 落盘(answer / fail)
//
// 🔴 **第一步必须是落盘。** G5 要求「失败时保留用户已输入的问题」,
// 而唯一能兑现它的做法就是先写库再发请求 —— 反过来做的话,请求超时或
// App 被杀,用户敲的那段话就没了,而那正是他最不想重打的东西。
@MainActor
final class AskViewModel: ObservableObject {

    @Published private(set) var turns: [AskTurn] = []
    @Published private(set) var outdatedAnswerIDs: Set<Int64> = []
    @Published var draft: String = "" { didSet { draftRevision += 1; persistDraft() } }
    @Published private(set) var draftFailure: String?
    /// 有没有一轮正在等云端。用来禁掉发送 —— 不禁的话用户连点两下会花两次钱。
    @Published private(set) var inFlight = false
    @Published private(set) var scope: AskScope?
    @Published private(set) var contextLabel: String?
    @Published private(set) var readFailure: String?
    @Published private(set) var inputRefreshFailure: String?
    @Published private(set) var conversationTitle = "主聊天"
    @Published private(set) var isMain = true
    @Published private(set) var isSwitching = false

    var canSend: Bool {
        !inFlight && !isSwitching && readFailure == nil && draftFailure == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let db: DatabaseQueue
    /// 给出处 sheet 读用。**只读不写** —— 写路径仍然只走这个类里的方法。
    var database: DatabaseQueue { db }
    private var conversationID: Int64?
    private var attachedScope: AskScope?
    private var pendingTitle: String?
    private var selectionRevision = 0
    private var draftKey: String?
    private var draftRevision = 0
    private var restoringDraft = false
    private var backgroundIsExplicit = false

    /// 🔴 **「还没挑过」与「用户主动开了新的一段」必须分开,不能都用 `conversationID == nil` 表示。**
    ///
    /// `load()` 在 `conversationID == nil` 时会去续最近那一段。若「开新的一段」只是把
    /// id 清成 nil,那么下一次 `load()`(切走再切回来、或界面重建)就会**把用户
    /// 刚开的新对话又续回旧的那一段** —— 而他敲的第一句会落进一段几天前的对话里,
    /// 界面上完全看不出发生了什么。
    private var deliberatelyBlank = false

    /// 当前在哪一段。历史列表用它把「你正在看的这段」标出来。
    var currentConversationID: Int64? { conversationID }

    init(db: DatabaseQueue, scope: AskScope? = nil, prefill: String = "") {
        self.db = db; self.scope = scope; self.attachedScope = scope; self.draft = prefill
    }

    /// ⚠️ 每次用之前先取成局部常量再进闭包 —— `db.write` 的闭包是 Sendable,
    /// 在里面读 `@MainActor` 的属性过不了编译,而这一点正是它该拦的:
    /// 那意味着数据库线程在读界面线程的状态。
    private static func stamp() -> String { ISO8601DateFormatter.growth.string(from: Date()) }

    // MARK: - 生命周期

    func load() async {
        // 中断恢复只在 AppDelegate 冷启动做；打开第二个追问视图不能取消正在回答的请求。

        // 默认进入唯一主聊天；用户手动打开的空话题经 reload 也不能跳回去。
        if conversationID == nil && !deliberatelyBlank {
            let stamp = Self.stamp()
            let revision = selectionRevision
            do {
                let id = try await db.write { try AskStore.main(now: stamp, in: $0) }
                guard selectionRevision == revision else { return }
                let saved = try await db.read { try AskDraftStore.read("main", in: $0) }
                guard selectionRevision == revision else { return }
                conversationID = id
                selectDraft("main", saved: saved, defaultScope: scope)
            }
            catch { readFailure = "主聊天读不出来：\(error)"; return }
        }
        await refresh()
        persistDraft()
    }

    // MARK: - 会话之间(M2-B6)

    /// 打开历史里的某一段。
    func openConversation(_ id: Int64) async {
        guard !inFlight, !isSwitching else { return }
        guard prepareToSwitch() else { return }
        selectionRevision += 1
        let revision = selectionRevision
        isSwitching = true
        defer { if selectionRevision == revision { isSwitching = false } }
        do {
            let packet = try await db.read { db in
                guard let conversation = try AskStore.conversation(id, in: db) else { throw AskStore.Failure.noSuchTurn(id: id) }
                let key = conversation.isMain ? "main" : "topic:\(id)"
                let saved = try AskDraftStore.read(key, in: db)
                let selected = try saved == nil ? AskStore.scope(of: id, in: db) : saved?.scope
                let turns = try AskStore.turns(of: id, in: db)
                return (turns, selected, try? selected?.label(in: db), conversation, key, saved, try Self.outdatedAnswers(turns, in: db))
            }
            guard !inFlight, selectionRevision == revision else { return }
            conversationID = id; deliberatelyBlank = false; pendingTitle = nil
            turns = packet.0; contextLabel = packet.2
            outdatedAnswerIDs = packet.6
            isMain = packet.3.isMain; conversationTitle = isMain ? "主聊天" : (packet.3.title ?? "话题")
            selectDraft(packet.4, saved: packet.5, defaultScope: packet.1, force: true)
            readFailure = scope != nil && contextLabel == nil ? "这份背景记录已删除或重新整理，请从最新记录开始问" : nil
        } catch { readFailure = "这段对话读不出来：\(error)" }
    }

    /// 开新的一段。
    ///
    /// ⚠️ **这里不建行。** `ask()` 在同一个事务里 `open` + `askBegin`,
    /// 所以「新会话」在用户真敲出第一句之前不需要有库行 ——
    /// 提前建的话,他开了又走开就在历史里留下一段没有标题、点进去空白的对话
    /// (标题是第一轮问题定的)。同一条口径见 `MatterStore.adopt`:
    /// **生成物不建行,用户动作才建行。**
    func startNewConversation(title: String? = nil) async {
        guard !inFlight, !isSwitching else { return }
        guard prepareToSwitch() else { return }
        selectionRevision += 1
        let revision = selectionRevision
        isSwitching = true
        defer { if selectionRevision == revision { isSwitching = false } }
        do {
            let name = try title.map(AskStore.normalizedTopicName)
            let key = "new:\(name ?? "")"
            let saved = try await db.read { try AskDraftStore.read(key, in: $0) }
            guard selectionRevision == revision else { return }
            pendingTitle = name; conversationID = nil; deliberatelyBlank = true
            isMain = false; conversationTitle = name ?? "新话题"
            contextLabel = nil; readFailure = nil
            turns = []; outdatedAnswerIDs = []
            selectDraft(key, saved: saved, defaultScope: nil, force: true)
        } catch { readFailure = "新话题草稿读不出来：\(error)" }
    }

    /// 页面追问复用主聊天和同一个请求模型；背景只附在当前工作区，不建新话题。
    @discardableResult
    func openMain(attaching scope: AskScope? = nil, prefill: String? = nil, preservingBackground: Bool = false) async -> Bool {
        guard !inFlight, !isSwitching else { return false }
        guard prepareToSwitch() else { return false }
        selectionRevision += 1
        let revision = selectionRevision
        isSwitching = true
        defer { if selectionRevision == revision { isSwitching = false } }
        do {
            let stamp = Self.stamp()
            let packet = try await db.write { db in
                let id = try AskStore.main(now: stamp, in: db)
                let saved = try AskDraftStore.read("main", in: db)
                let selected = preservingBackground ? saved?.scope : scope
                let turns = try AskStore.turns(of: id, in: db)
                return (id, turns, saved, selected, try? selected?.label(in: db), try Self.outdatedAnswers(turns, in: db))
            }
            guard !inFlight, selectionRevision == revision else { return false }
            conversationID = packet.0; deliberatelyBlank = false; pendingTitle = nil
            turns = packet.1; isMain = true; conversationTitle = "主聊天"
            outdatedAnswerIDs = packet.5
            selectDraft("main", saved: packet.2, defaultScope: packet.3, force: true)
            attachedScope = packet.3; self.scope = packet.3; backgroundIsExplicit = true
            contextLabel = packet.4
            readFailure = self.scope != nil && contextLabel == nil ? "这份背景记录已删除或重新整理，请移除背景或从最新记录继续问" : nil
            if let prefill, !prefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = prefill }
                else if draft != prefill && !draft.hasSuffix("\n\n" + prefill) { draft += "\n\n" + prefill }
            }
            persistDraft()
        } catch { readFailure = "主聊天读不出来：\(error)"; return false }
        return true
    }

    func clearBackground() async {
        guard !inFlight, !isSwitching else { return }
        selectionRevision += 1
        attachedScope = nil; scope = nil; contextLabel = nil
        backgroundIsExplicit = true
        persistDraft()
        await refresh()
    }

    func renameConversation(_ id: Int64, title: String) async throws {
        guard !inFlight, !isSwitching else { return }
        try await db.write { try AskStore.rename(id, title: title, in: $0) }
        await refresh()
    }

    func archiveConversation(_ id: Int64, archived: Bool) async throws {
        guard !inFlight, !isSwitching else { return }
        try await db.write { try AskStore.archive(id, archived: archived, in: $0) }
    }

    /// 历史列表。
    ///
    /// 🔴 **抛,不要 `?? []`。** 读失败吞成空数组之后,界面画的是「还没问过什么」——
    /// 那是一句**结论**,而真相是「读不出来」,两者在屏幕上一模一样。
    /// 08-18 `MattersView` 上栽过一次同一形状,复核清单 §四点名的就是它。
    func conversations() async throws -> [AskConversation] {
        try await db.read { db in try AskStore.conversations(in: db) }
    }

    private func refresh() async {
        guard !isSwitching else { return }
        let revision = selectionRevision
        let pinned = conversationID
        let pendingScope = attachedScope
        let explicitBackground = backgroundIsExplicit
        do {
            let (turns, scope, label, conversation, outdated) = try await db.read { db in
                let selected = try explicitBackground ? pendingScope : (pendingScope ?? pinned.flatMap { try AskStore.scope(of: $0, in: db) })
                let turns = try pinned.map { try AskStore.turns(of: $0, in: db) } ?? []
                return (turns, selected, try? selected?.label(in: db),
                        try pinned.flatMap { try AskStore.conversation($0, in: db) }, try Self.outdatedAnswers(turns, in: db))
            }
            guard conversationID == pinned, selectionRevision == revision, !isSwitching else { return }
            self.turns = turns; self.scope = scope; contextLabel = label
            outdatedAnswerIDs = outdated
            if let conversation {
                isMain = conversation.isMain
                conversationTitle = conversation.isMain ? "主聊天" : (conversation.title ?? "话题")
            }
            readFailure = scope != nil && label == nil ? "这份背景记录已删除或重新整理，请从最新记录开始问" : nil
        } catch { readFailure = "问答记录读不出来：\(error)" }
    }

    // MARK: - 提问

    private nonisolated static func outdatedAnswers(_ turns: [AskTurn], in db: Database) throws -> Set<Int64> {
        var ids = Set<Int64>()
        for turn in turns where turn.status == .answered {
            if try !AskStore.sourcesAreCurrent(turn.id, in: db) { ids.insert(turn.id) }
        }
        return ids
    }

    private func selectDraft(_ key: String, saved: AskDraftStore.Draft?, defaultScope: AskScope?, force: Bool = false) {
        guard draftKey != key || force else { return }
        let initial = draftKey == nil ? draft : ""
        restoringDraft = true
        draftKey = key
        draft = saved?.text ?? initial
        scope = saved?.scope ?? defaultScope
        if let saved { scope = saved.scope }
        attachedScope = scope
        backgroundIsExplicit = saved != nil
        restoringDraft = false
        draftFailure = nil
        persistDraft()
    }

    private func prepareToSwitch() -> Bool {
        // 当前输入尚未落盘时，保持当前聊天和内存输入，不能用旧草稿覆盖它。
        persistDraft()
        return draftFailure == nil
    }

    private func persistDraft(removingOldKey: String? = nil) {
        guard !restoringDraft, let key = draftKey else { return }
        let text = draft, scope = scope, revision = draftRevision
        do {
            try db.write { db in
                try AskDraftStore.save(text, revision: revision, scope: scope, key: key, in: db)
                if let removingOldKey { try db.execute(sql: "DELETE FROM ask_drafts WHERE key=?", arguments: [removingOldKey]) }
            }
            draftFailure = nil
        } catch { draftFailure = "草稿尚未保存：\(error)" }
    }

    func send() async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        await ask(question, clearingDraft: (draftKey, draftRevision))
    }

    /// 重试一轮失败的。**新开一轮而不是改那一轮** ——
    /// 把失败那条就地改成成功,历史里就看不出「这一问失败过一次」,
    /// 而那恰恰是判断「是不是这个问题总答不上」的依据。
    func retry(_ turn: AskTurn) async {
        guard !inFlight, !isSwitching, readFailure == nil else { return }
        await ask(turn.question)
    }

    func delete(_ turn: AskTurn) async {
        do {
            try await db.write { db in try AskStore.deleteTurn(turn.id, in: db) }
            await refresh()
        } catch { readFailure = "这一轮没删掉：\(error)" }
    }

    private func ask(_ question: String, clearingDraft: (String?, Int)? = nil) async {
        inFlight = true
        defer { inFlight = false }

        // ① 先落盘 —— 见文件头
        let turnID: Int64
        let stamp = Self.stamp()
        let existing = conversationID
        let selectedScope = scope
        let explicitBackground = backgroundIsExplicit
        let name = pendingTitle
        let wantsMain = !deliberatelyBlank
        let requestConversation: Int64
        let oldDraftKey = draftKey
        do {
            let (cid, tid) = try await db.write { db -> (Int64, Int64) in
                let cid = try existing ?? (wantsMain ? AskStore.main(now: stamp, in: db) : AskStore.open(now: stamp, title: name, in: db))
                let tid = try AskStore.askBegin(conversation: cid, question: question, now: stamp, in: db)
                if let (key, revision) = clearingDraft, let key {
                    try db.execute(sql: "UPDATE ask_drafts SET text='' WHERE key=? AND revision=?", arguments: [key, revision])
                }
                if !wantsMain, let oldDraftKey, oldDraftKey.hasPrefix("new:") {
                    try AskDraftStore.move(from: oldDraftKey, to: "topic:\(cid)", in: db)
                }
                return (cid, tid)
            }
            conversationID = cid
            let shouldClear = clearingDraft.map { draftKey == $0.0 && draftRevision == $0.1 } ?? false
            if !wantsMain { draftKey = "topic:\(cid)" }
            if shouldClear { draft = "" } else { persistDraft() }
            // 主线程恢复之前若又输入，旧 key 上的文本仍保全；成功保存新 key 后才清理。
            if !wantsMain, let oldDraftKey, oldDraftKey.hasPrefix("new:") { persistDraft(removingOldKey: oldDraftKey) }
            requestConversation = cid
            turnID = tid
        } catch {
            // 连问题都没写进去,那就没有「保留用户输入」这回事了 —— 把草稿还给他
            if draft.isEmpty { draft = question }
            readFailure = "问题还没保存：\(error)"
            return
        }
        await refresh()

        // ② 本地检索。**搜不到不是失败**:那时该让模型说「这个我没有记录」(P5)
        let initialRefresh = await InputMemorySourceSync.shared.refresh(in: db, config: ProxySettings.config, freshWatermark: true)
        let inputReady = initialRefresh == .complete
        if case .failed(let message) = initialRefresh { inputRefreshFailure = message }
        else { inputRefreshFailure = nil }
        let materials: [AskRetrieval.Material]
        let inputs: [InputMemorySource]
        let offeredInputIDs: Set<Int64>
        let history: [AskTurn]
        let offeredIDs: Set<Int64>
        do {
            let packet = try await db.write { db in
                let pinnedScope = try explicitBackground ? selectedScope : (selectedScope ?? AskStore.scope(of: requestConversation, in: db))
                let conversation = try AskStore.conversation(requestConversation, in: db)
                let current = try pinnedScope ?? (conversation?.isMain == true ? AskScope.latestReceived(in: db) : nil)
                var found = try current?.materials(for: question, in: db) ?? []
                if pinnedScope == nil {
                    found += try AskRetrieval.materials(for: question, in: db)
                }
                let materials = AskRetrieval.bounded(found)
                let history = try AskStore.history(of: requestConversation, excluding: turnID,
                    allowInputSources: inputReady && pinnedScope == nil, in: db)
                let inputs = try InputMemorySource.materials(question, scope: pinnedScope, ready: inputReady, in: db)
                try AskStore.recordSources(turnID, materials: materials, history: history, inputs: inputs, in: db)
                let ids = try Int64.fetchSet(db, sql: "SELECT line_id FROM ask_turn_sources WHERE turn_id = ?", arguments: [turnID])
                let inputIDs = try Int64.fetchSet(db, sql: "SELECT local_id FROM ask_turn_input_sources WHERE turn_id = ?", arguments: [turnID])
                return (materials, history, ids, inputs, inputIDs)
            }
            materials = packet.0; history = packet.1; offeredIDs = packet.2; inputs = packet.3; offeredInputIDs = packet.4
        } catch {
            try? await db.write { try AskStore.fail(turnID, reason: "读取本轮材料失败：\(error)", now: stamp, in: $0) }
            await refresh(); return
        }

        // ③ 云。历史只带已答过的轮次(§4.7.3 上下文裁剪:不喂全库,也不重喂旧材料)
        guard let config = ProxySettings.config else {
            try? await db.write { db in
                try AskStore.fail(turnID, reason: "云代理还没配 —— 去设置里填地址和令牌",
                                  now: stamp, in: db)
            }
            await refresh()
            return
        }
        let messages = AskPrompt.messages(question: question, materials: materials,
                                          history: history, inputs: inputs)
        do {
            let answer = try await ProxyClient.chat(scene: "ask", messages: messages,
                                                    config: config)
            // ④ 只收在材料里真出现过的出处 —— 编造的那些丢掉,
            //    否则界面会渲染出点不开的链接,而那长得像「出处功能坏了」
            // 再次接收变化，防止模型运行期间修改/删除的输入来源被旧答案写回。
            let finalRefresh = await InputMemorySourceSync.shared.refresh(in: db, config: ProxySettings.config, freshWatermark: true)
            if case .failed(let message) = finalRefresh { inputRefreshFailure = message }
            if !offeredInputIDs.isEmpty && finalRefresh != .complete {
                throw InputMemorySource.Failure.invalid("输入法来源未能再次核对，本轮回答未保存，请重试")
            }
            let citedInputs = AskPrompt.citedInputIDs(in: answer, allowed: offeredInputIDs)
            let cited = AskPrompt.citedLineIDs(in: answer, allowed: offeredIDs)
            try await db.write { db in
                try AskStore.answer(turnID, text: answer, citedLineIDs: cited, citedInputIDs: citedInputs,
                                    now: stamp, in: db)
            }
        } catch {
            // 原因要说人话并留着 —— G5:显示原因与重试
            try? await db.write { db in
                try AskStore.fail(turnID, reason: "\(error)", now: stamp, in: db)
            }
        }
        await refresh()
    }
}

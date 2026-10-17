import SwiftUI
import GRDB

// 当前主聊天与手动话题界面；规则见 docs/PRD.md。
//
// ## 这一页刻意不做的三件事
//
// 1. **不显示「正在思考」的假进度。** 只有一句「正在翻记录」(§4.7.3 超时文案),
//    因为我们确实不知道进度 —— 一根走到 90% 就卡住的进度条比没有更糟。
// 2. **不把失败的那一轮从列表里抹掉。** G5 要求保留用户已输入的问题,
//    所以失败的轮子仍然显示,带原因与重试。
// 3. 出处用稳定 line_id 跳转，界面只显示「原话」；本轮出处列表不会被下一次检索改写。

struct AskView: View {

    /// 历史列表(M2-B6)。
    @State private var showingHistory = false
    @StateObject var model: AskViewModel
    @ScaledMetric(relativeTo: .subheadline) private var citationWidth: CGFloat = 110
    /// 当一格(`M5-1`:中间那格就是问问)时没有「关闭」—— tab 不需要出口,点别的格就走了。
    var isTab = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 当一格时顶栏交给系统导航栏(玻璃 + 滚动边缘效果);全屏盖时还是自画那条,
            // 因为那时它要带「关闭」—— `fullScreenCover` 下滑关不掉,那是唯一出口。
            if !isTab {
                topBar
                Divider().overlay(DS.C.line)
            }
            if let label = model.contextLabel {
                HStack(alignment: .top, spacing: 10) {
                    AptGlyph(kind: .source, size: 18).foregroundStyle(DS.C.dim)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("带着背景 · \(label)").font(.subheadline.weight(.medium)).foregroundStyle(DS.C.ink)
                            .lineLimit(2)
                        Text("基于已收到的原话。下一问会读取新到的片段。")
                            .font(.caption).foregroundStyle(DS.C.dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { Task { await model.clearBackground() } } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 44, height: 44)
                    }.foregroundStyle(DS.C.dim).disabled(model.inFlight || model.isSwitching).accessibilityLabel("移除这份背景")
                }
                .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.C.panel2, in: RoundedRectangle(cornerRadius: DS.S.radiusSm))
                .padding(.horizontal, DS.S.side).padding(.top, 8)
            }
            if let failure = model.readFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure).font(DS.F.meta).foregroundStyle(DS.C.ink)
                    Button("重新读取") { Task { await model.load() } }.disabled(model.inFlight || model.isSwitching)
                    if model.scope != nil { Button("移除背景，继续聊") { Task { await model.clearBackground() } }.disabled(model.inFlight || model.isSwitching) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let failure = model.inputRefreshFailure {
                Text("\(failure)；本轮未使用未刷新的输入法记忆。")
                    .font(DS.F.meta).foregroundStyle(DS.C.danger).padding(.horizontal, 16).padding(.vertical, 8)
            }
            transcript
            AskComposer(model: model)
        }
        .toolbar {
            if isTab {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Mascot(working: model.turns.last?.status == .asking, size: 32)
                        Text(model.conversationTitle).font(.headline).foregroundStyle(DS.C.ink).lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHistory = true } label: {
                        Image(systemName: "line.3.horizontal").frame(width: 44, height: 44)
                    }.disabled(model.inFlight || model.isSwitching).accessibilityLabel("聊天与话题")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // 🔴 **出处链接在这里被拦下来,不交给系统。**
        // 不拦的话系统会去找谁能处理 `growth-line://` —— 没人能,于是什么都不发生,
        // 而那正好长得像「出处功能坏了」。
        .environment(\.openURL, OpenURLAction { url in
            guard let id = AnswerText.lineID(from: url) else { return .systemAction }
            quoteLineID = id
            return .handled
        })
        .sheet(item: Binding(get: { quoteLineID.map(IdentifiedLine.init) },
                             set: { quoteLineID = $0?.id })) { target in
            AskQuoteSheet(lineID: target.id, turnID: quoteTurnID, database: model.database)
        }
        .sheet(item: Binding(get: { quoteInputID.map(IdentifiedLine.init) }, set: { quoteInputID = $0?.id })) { target in
            AskInputQuoteSheet(localID: target.id, turnID: quoteTurnID, database: model.database)
        }
        .background(DS.C.bg)
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRemoval.changed)) { _ in Task { await model.load() } }
        .sheet(isPresented: $showingHistory) { AskHistoryView(model: model) }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack {
            if isTab {
                Color.clear.frame(width: 44, height: 1)
            } else {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(DS.C.ink)
                // 只有图标的按钮必须自己报名字 —— 不报的话 VoiceOver 念出来是「按钮」,
                // 而这是**这一屏唯一的出口**(`fullScreenCover` 下滑关不掉)。
                .accessibilityLabel("关闭")
                .frame(width: 44, height: 44, alignment: .leading)
            }
            Spacer()
            VStack(spacing: 0) {
                Mascot(working: model.turns.last?.status == .asking, size: 44)
                Text(model.conversationTitle).font(.subheadline.weight(.semibold)).foregroundStyle(DS.C.ink)
            }
            Spacer()
            // ~~历史入口留位但不放假动作:会话历史列表是下一格的活~~
            // **2026-08-19(M2-B6)接上了。** 那一格就是 `AskHistoryView`:
            // 能列出所有对话、能开新的一段。
            Button { showingHistory = true } label: {
                Text("话题").font(.system(size: 15)).foregroundStyle(DS.C.brand)
            }
            .frame(width: 44, height: 44, alignment: .trailing)
            .disabled(model.inFlight || model.isSwitching)
            .accessibilityLabel("聊天与话题")
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(DS.C.panel)
    }

    // MARK: - 对话

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.turns.isEmpty { emptyHint }
                    ForEach(model.turns, id: \.id) { turn in
                        turnView(turn).id(turn.id)
                    }
                }
                .padding(.horizontal, DS.S.side).padding(.vertical, 20)
            }
            .onChange(of: model.turns.count) { _, _ in
                withAnimation(DS.motion) { proxy.scrollTo(model.turns.last?.id, anchor: .bottom) }
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.contextLabel != nil ? "带着背景，继续聊。" : (model.isMain ? "从这里，接着想。" : "这件事，慢慢聊。"))
                .font(DS.pageTitle).foregroundStyle(DS.C.ink)
            // ⚠️ 这段话是**能力边界的如实说明**,不是营销词:
            // §4.7.4 规则 3「给材料不给建议」,用户一开始就该知道这一点,
            // 否则他会问「我该怎么跟他谈」然后拿到一句「这个我没有记录」。
            Text(model.isMain ? "回想刚才，也聊聊接下来。提到你的记录时，会带上能核对的原话。" : "围绕这个话题接着想，聊天会一直保留在这里。")
                .font(.body).foregroundStyle(DS.C.dim).lineSpacing(4)
            VStack(alignment: .leading, spacing: 10) {
                suggestion("最近收到的内容里，定了哪些事？")
                suggestion("这件事还有什么没有说清楚？")
                suggestion("帮我找一下相关的原话")
            }.padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private func suggestion(_ text: String) -> some View {
        Button { model.draft = text } label: {
            HStack(spacing: 12) {
                Text(text).font(.subheadline).foregroundStyle(DS.C.sub)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.left").font(.caption.weight(.semibold)).foregroundStyle(DS.C.brand)
            }.padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(DS.C.panel, in: DS.panelShape())
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func turnView(_ turn: AskTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 问。用 `HStack { Spacer(); … }` 而不是
            // `.frame(maxWidth: .infinity, alignment: .trailing)` ——
            // 后者会把气泡的**底色**也拉满整宽,右对齐的只是里面的字。
            //
            // ⚠️ **更正一条我自己写错的注释(2026-08-17)**:这里原本写着
            // 「实拍看到 SwiftUI 把一行字均摊成 `di dwe s et t le`」——**那是假的**。
            // 查库发现存进去的字符串本身就是 `di dwe s et t le…`:
            // 是模拟器逐字符注入比 TextField 处理得快、字符错位了,**不是渲染问题**。
            // 教训是**验证工具自己会骗人**:先分清「数据坏了」还是「显示坏了」,
            // 再去改代码 —— 我差一点为一个不存在的 SwiftUI 行为改了布局。
            HStack {
                Spacer(minLength: 40)
                Text(turn.question)
                    .font(DS.F.body).foregroundStyle(DS.C.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(DS.C.brandSoft, in: DS.panelShape())
            }

            switch turn.status {
            case .asking:
                HStack(spacing: 8) {
                    Mascot(working: true, size: 26)
                    Text("正在翻记录").font(.subheadline).foregroundStyle(DS.C.dim)
                }.accessibilityElement(children: .combine)

            case .answered:
                if model.outdatedAnswerIDs.contains(turn.id) {
                    Text("依据已变化 · 这条旧回答仅供回看，新的问题会重新核验。")
                        .font(.caption).foregroundStyle(DS.C.dim)
                }
                answerView(turn)

            case .failed:
                // G5:显示原因与重试,而问题原样留在上面 —— 用户不必重打。
                // ⚠️ **和回答用同一个卡片容器**:实拍时失败态是裸贴在左边距上的,
                // 而回答有卡片 —— 两种状态视觉上不成对,失败那条看着像一段掉出来的调试文字。
                VStack(alignment: .leading, spacing: 8) {
                    Label(turn.error ?? "没答上来", systemImage: "exclamationmark.triangle")
                        .font(DS.F.meta).foregroundStyle(DS.C.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") { Task { await model.retry(turn) } }
                        .font(DS.F.meta).foregroundStyle(DS.C.brand)
                }
                .padding(DS.S.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.C.panel, in: DS.panelShape())
                .overlay(DS.panelShape()
                    .stroke(DS.C.danger.opacity(0.35), lineWidth: 1))
            }
        }
        .contextMenu {
            // §4.7.3「单轮可删除」—— 删除单位是轮,不是整段对话
            Button("删掉这一轮", role: .destructive) { Task { await model.delete(turn) } }
        }
    }

    /// 点开的那条出处。
    @State private var quoteLineID: Int64?
    @State private var quoteInputID: Int64?
    @State private var quoteTurnID: Int64?

    private func answerView(_ turn: AskTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AptGlyph(kind: .ask, size: 16)
                Text("APT · 回答").font(.caption.weight(.medium))
            }.foregroundStyle(DS.C.dim)
            // 🔴 **出处要真的点得开。** 上一版是 `Text(turn.answer ?? "")` 纯文本,
            // `[#123]` 按字面渲染,而屏上、`AskPrompt` 的注释、这里的注释
            // **三处都在承诺一个不存在的交互**。
            //
            // 出处不是装饰:答案是模型生成的,`[#123]` 是它唯一可核对的锚 ——
            // 点不开就等于「相信我」,而这个产品全部的价值在于「你可以去看原话」。
            answerBody(turn)
                .font(DS.F.body).foregroundStyle(DS.C.ink)

            if !turn.citedLineIDs.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "quote.opening").font(.system(size: 10))
                    Text("\(turn.citedLineIDs.count) 处原话")
                }
                .font(DS.F.meta).foregroundStyle(DS.C.dim)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: citationWidth), alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(Array(turn.citedLineIDs.enumerated()), id: \.element) { index, id in
                            Button { quoteTurnID = turn.id; quoteLineID = id } label: {
                                HStack(spacing: 6) {
                                    AptGlyph(kind: .source, size: 16)
                                    Text("原话 \(index + 1)")
                                }
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12).frame(minHeight: 44)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .background(DS.C.brandSoft, in: Capsule())
                            }.buttonStyle(.plain).foregroundStyle(DS.C.brand)
                        }
                }
            }
            if !turn.citedInputIDs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(turn.citedInputIDs.enumerated()), id: \.element) { index, id in
                            Button { quoteTurnID = turn.id; quoteInputID = id } label: {
                                Label("输入草稿 \(index + 1)", systemImage: "keyboard")
                                    .font(DS.F.meta).padding(.horizontal, 12).frame(minHeight: 44)
                                    .background(DS.C.brandSoft, in: Capsule())
                            }.buttonStyle(.plain).foregroundStyle(DS.C.brand)
                        }
                    }
                }
            }
        }
        .padding(DS.S.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.panel, in: DS.panelShape())
        .overlay(DS.panelShape().stroke(DS.C.line, lineWidth: 1))
        .environment(\.openURL, OpenURLAction { url in
            if let id = AnswerText.inputID(from: url), turn.citedInputIDs.contains(id) {
                quoteTurnID = turn.id; quoteInputID = id; return .handled
            }
            guard let id = AnswerText.lineID(from: url), turn.citedLineIDs.contains(id) else { return .systemAction }
            quoteTurnID = turn.id; quoteLineID = id; return .handled
        })
    }

    /// 把回答拼成「普通文字 + 可点的出处」。
    ///
    /// 用 `Text` 相加而不是 `AttributedString` 的链接:链接要一个 URL scheme,
    /// 而这里要的是**在本 App 内弹一个 sheet**,给它编一个假 URL 再解析回来
    /// 是绕远路。`Text` 拼接换来的代价是整段不能再 `textSelection` ——
    /// 而「能点开原话」比「能选中复制」重要得多。
    private func answerBody(_ turn: AskTurn) -> Text {
        var s = AttributedString()
        for piece in AnswerText.pieces(of: turn.answer ?? "", cited: turn.citedLineIDs, inputCited: turn.citedInputIDs) {
            switch piece {
            case .text(let plain):
                s += AttributedString(plain)
            case .citation(let lineID, _):
                var chunk = AttributedString("原话")
                chunk.foregroundColor = DS.C.brand
                chunk.font = DS.F.body.bold()
                // 自定义 scheme,由下面那个 `openURL` 拦下来 —— 见 `AnswerText.scheme`
                // 那段注释:用 https 的话,漏掉一次拦截就是把用户踢去浏览器。
                chunk.link = AnswerText.url(lineID: lineID)
                s += chunk
            case .inputCitation(let localID, _):
                var chunk = AttributedString("输入草稿")
                chunk.foregroundColor = DS.C.brand
                chunk.font = DS.F.body.bold()
                chunk.link = AnswerText.inputURL(localID: localID)
                s += chunk
            }
        }
        return Text(s)
    }

}

// MARK: - 出处

/// `sheet(item:)` 要一个 `Identifiable`,而 `Int64` 不是。
private struct IdentifiedLine: Identifiable { let id: Int64 }

/// 点开一条出处:那句原话的前后各 3 句(PRD §4.2.5,与纪要里跳原话同一份投影)。
///
/// **不另写一套取上下文的查询** —— 两处各写一份的话,同一条 `line_id`
/// 在纪要里和在问问里会看到不一样的上下文,而那种不一致没人查得出来。
private struct AskQuoteSheet: View {
    let lineID: Int64
    let turnID: Int64?
    let database: DatabaseQueue

    @State private var context: QuoteContext?
    @State private var snapshot: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                DS.C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let snapshot {
                            Text("本轮用到的原文 · 长句可能为节选").font(DS.F.meta).foregroundStyle(DS.C.dim)
                            Text(snapshot).font(DS.F.body).foregroundStyle(DS.C.ink)
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(DS.C.brandSoft, in: RoundedRectangle(cornerRadius: 16))
                            Text("当前原话与前后文").font(DS.F.meta).foregroundStyle(DS.C.dim).padding(.top, 12)
                        }
                        if context == nil {
                            // 出处指向的行不在了(移出记忆过、或者库换过)——
                            // **说出来**,不给一张白纸:白纸会被当成「点了没反应」。
                            Text("这条出处找不到了 —— 它引用的那一行可能已经移出记忆。")
                                .font(DS.F.meta).foregroundStyle(DS.C.dim)
                        }
                        ForEach(context?.lines ?? []) { LineRow(line: $0) }
                    }
                    .padding(.horizontal, DS.S.side).padding(.vertical, 16)
                }
            }
            .navigationTitle("原话 · 前后各 3 句")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRemoval.changed)) { _ in load() }
    }

    private func load() {
        context = try? SessionDetailProjection.quoteContext(lineID: lineID, in: database)
        snapshot = nil
        if let turnID { snapshot = try? database.read { try AskStore.sourceText(turnID: turnID, lineID: lineID, in: $0) } }
    }
}

/// 输入来源不提供音频按钮、说话人或伪造的转写场次。
private struct AskInputQuoteSheet: View {
    let localID: Int64
    let turnID: Int64?
    let database: DatabaseQueue
    @State private var source: InputMemorySource?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let source {
                        Text("输入过不代表已发送或事情已发生。粘贴内容不代表本人观点。")
                            .font(DS.F.meta).foregroundStyle(DS.C.dim)
                        Text("\(source.record.app) · \(source.record.created)")
                            .font(DS.F.meta).foregroundStyle(DS.C.dim)
                        if source.record.partial { Text("这条记录是未完整捕获的片段").font(DS.F.meta) }
                        Text(source.record.text).font(DS.F.body).textSelection(.enabled)
                        if !source.record.pasted.isEmpty {
                            Text("粘贴来源区间").font(.headline)
                            Text(source.record.pasted.joined(separator: "\n")).font(DS.F.body).textSelection(.enabled)
                        }
                        if !source.record.voiced.isEmpty {
                            Text("语音输入区间").font(.headline)
                            Text(source.record.voiced.joined(separator: "\n")).font(DS.F.body)
                        }
                    } else { Text(failure ?? "这条输入来源已修改或移出记忆，不能再展示旧原文。") }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.background(DS.C.bg)
                .navigationTitle("本轮输入草稿").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.task { load() }
            .onReceive(NotificationCenter.default.publisher(for: MemoryRemoval.changed)) { _ in load() }
    }

    private func load() {
        do {
            source = try database.read { db in
                guard let turnID, try AskStore.sourcesAreCurrent(turnID, in: db) else { return nil }
                return try AskStore.inputSource(turnID: turnID, localID: localID, in: db)
            }
            failure = nil
        } catch { source = nil; failure = "输入来源读不出来：\(error)" }
    }
}

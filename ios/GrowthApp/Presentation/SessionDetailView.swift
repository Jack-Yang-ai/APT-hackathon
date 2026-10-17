import SwiftUI
import GRDB

/// 一场(`M5-1` spec §三;界面真值是设计画布 02、03、04)。
///
/// 「重点 / 详情」两栏 + 导航栏右上「原话 ›」。
///
/// - **重点**:一句话 · 定了什么 · 你要做的(我说的承诺)· 别人答应的 · 还没定。
///   ~~表态按说话人分组~~ 2026-10-12 拿掉:它属于「人」那条线,人页已撤。
/// - **详情**:按事件分段(两阶段抽取的 `events[]`)。老产物没有事件 ⇒ 如实说,不编。
///
/// **G6 空态两分法**:内容块没内容就整块隐藏,不显示「暂无」。
struct SessionDetailView: View {
    let sessionID: Int64
    let database: DatabaseQueue?
    let eventID: Int64?
    init(sessionID:Int64,database:DatabaseQueue?,eventID:Int64?=nil) {
        self.sessionID=sessionID;self.database=database;self.eventID=eventID
    }

    @State private var detail: SessionDetail?
    @State private var loadFailure: String?
    @State private var quoteTarget: SummaryItem?
    @State private var tab: Pane = .highlights
    @State private var openTranscriptAt: Int64?
    @State private var showTranscript = false

    enum Pane: String, CaseIterable { case highlights = "重点", details = "详情" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let d = detail {
                    header(d)
                    Picker("看哪一栏", selection: $tab) {
                        ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 8)
                    speakerNote(d)
                    switch tab {
                    case .highlights: highlights(d)
                    case .details: details(d)
                    }
                } else if let f = loadFailure {
                    // 读不出来要说出来。空白页会被当成「这一场什么都没有」,
                    // 而事实是「我们没能把它读出来」—— 差得远。
                    Text(f)
                        .font(DS.F.lead)
                        .foregroundStyle(DS.C.ink)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(DS.C.panel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openTranscriptAt = detail?.keyPoints.first?.lineID ?? detail?.events.first?.topics.first?.firstLineID
                    showTranscript = true
                } label: {
                    Label("原话", systemImage: "text.alignleft").labelStyle(.titleOnly)
                }
            }
        }
        .navigationDestination(isPresented: $showTranscript) {
            TranscriptView(sessionID: sessionID, database: database,
                           onAttributionChanged: { load() }, focusLineID: openTranscriptAt, eventID: eventID)
        }
        .task { load() }
        .sheet(item: $quoteTarget) { item in
            QuoteContextSheet(item: item, database: database, eventID: eventID)
        }
        // 原话里改完说话人回到这一页,重点要跟着变 —— 「你要做的」依赖归属。
        .onAppear { if detail != nil { load() } }
    }

    private func load() {
        detail = nil
        loadFailure = nil
        guard let database else { loadFailure = "主库没打开,这一场读不出来"; return }
        do { detail = try SessionDetailProjection.detail(sessionID: sessionID, eventID:eventID, in: database) }
        catch { loadFailure = "读这一场出错:\(error)" }
        if detail == nil && loadFailure == nil {
            // 🔴 **说出为什么,不要三种原因一句话。** 云代理没配 / 一块音频都没有 / 断网
            // 对应的动作完全不同,同一句话把它们都盖住,用户就无从判断。
            loadFailure = SessionStallText.explain(
                (try? TaskQueue.lastWord(sessionID: sessionID, in: database)) ?? nil)
        }
    }

    // MARK: - 头

    private func header(_ d: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // 标题 = 第一个事件的标题;没有事件就拿一句话(它本来就是整场结论)。
            Text(d.title ?? d.oneLiner ?? "这一场还没出一句话")
                // 一句话当标题时往往有三四十字,28 粗体压得透不过气 ⇒ 退到 22。
                .font(.system(size: d.title == nil ? 22 : 28, weight: .bold))
                .foregroundStyle(d.title == nil && d.oneLiner == nil ? DS.C.dim : DS.C.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(meta(d))
                .font(.system(size: 15))
                .foregroundStyle(DS.C.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.bottom, 18)
    }

    private func meta(_ d: SessionDetail) -> String {
        var parts = [d.startTime]
        if d.durationMinutes > 0 { parts.append("\(d.durationMinutes) 分钟") }
        if d.speakerCount > 0 { parts.append("\(d.speakerCount) 人") }
        if d.source == SessionSource.watch { parts.append("手表") }
        return parts.joined(separator: " · ")
    }

    /// 🔴 **没有分人要说出来**(M1-34,用户 2026-08-19 拍板「要看见」)。
    /// 「会自己好」与「不会自己变」分开说(M2-认6 界面半)。不用红色。
    @ViewBuilder
    private func speakerNote(_ d: SessionDetail) -> some View {
        if d.linesWithoutSpeaker > 0 {
            let working = ["queued", "running", "retrying"].contains(d.voiceprintState ?? "")
            Text(working
                 ? "有 \(d.linesWithoutSpeaker) 句还没分出说话人，正在整理，会自己补上"
                 : "有 \(d.linesWithoutSpeaker) 句没分出说话人，在原话里长按可以改")
                .font(DS.F.meta)
                .foregroundStyle(DS.C.dim)
                .padding(.top, 6)
        }
    }

    // MARK: - 重点

    @ViewBuilder
    private func highlights(_ d: SessionDetail) -> some View {
        if let one = d.oneLiner, d.title != nil {
            // 有标题时一句话放在这里当摘要;没标题时它已经是标题了,不重复。
            Text(one)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DS.C.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
        let others = d.commitments.filter { c in !d.myCommitments.contains { $0.lineID == c.lineID } }
        SummaryBlock(title: "定了什么", items: d.keyPoints, numbered: true, onQuote: { quoteTarget = $0 })
        SummaryBlock(title: "你要做的", items: d.myCommitments, onQuote: { quoteTarget = $0 })
        SummaryBlock(title: "纪要中的其他承诺", items: others, withheld: d.commitmentsWithheld,
                     showsSpeaker: true, onQuote: { quoteTarget = $0 })
        SummaryBlock(title: "还没定", items: d.pendings, onQuote: { quoteTarget = $0 })
        if let eventID { ContextualAskButton(database:database,scope:AskScope(sessionID:sessionID,eventID:eventID),title:"问问这件事").padding(.top,16) }
    }

    // MARK: - 详情

    @ViewBuilder
    private func details(_ d: SessionDetail) -> some View {
        if d.events.isEmpty {
            // 老产物(v1 单阶段)没有事件。**如实说,不拿别的东西拼一段出来。**
            Text("这一场是旧版整理的，没有详情。重点和原话都在。")
                .font(DS.F.lead)
                .foregroundStyle(DS.C.dim)
                .padding(.top, 20)
        } else {
            ForEach(Array(d.events.enumerated()), id: \.element.id) { i, ev in
                if i > 0 { Divider().padding(.vertical, 4) }
                VStack(alignment: .leading, spacing: 8) {
                    let sub = [ev.clockRange, ev.speakers.isEmpty ? nil : ev.speakers.joined(separator: "、")]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !sub.isEmpty {
                        Text(sub).font(DS.F.meta).foregroundStyle(DS.C.dim)
                    }
                    if !ev.title.isEmpty {
                        Text(ev.title)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(DS.C.ink)
                    }
                    Text(ev.summary)
                        .font(.system(size: 17))
                        .lineSpacing(5)
                        .foregroundStyle(DS.C.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ContextualAskButton(database: database,
                        scope: AskScope(sessionID: sessionID, eventID: ev.id))
                    if !ev.topics.isEmpty {
                        // 🔴 话题一多就换行 —— 不能用 `HStack`,理由见 `WrapRow`。
                        WrapRow(spacing: 8) {
                            ForEach(ev.topics, id: \.self) { t in
                                Button {
                                    openTranscriptAt = t.firstLineID
                                    showTranscript = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(t.key).lineLimit(1)
                                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(DS.C.ink)
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                                    .background(DS.C.panel2, in: Capsule())
                                    // 胶囊看着 30 高,点击区垫到 44(触控区下限)。
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
            }
        }
    }
}

// MARK: - 换行的横排

/// 一行放不下就换行。**给参与人药丸用,不是通用组件** —— 只有它需要。
///
/// ## 🔴 为什么 `HStack` 在这里是缺陷,而不是「多了会挤一点」
///
/// `HStack` 不换行:它的**最小宽度是各子项最小宽度之和**,压无可压时它就
/// 直接比屏幕宽。而它坐在 `ScrollView { VStack }` 里 ⇒ 整个 `VStack` 被撑到
/// 一千多 pt，竖向 `ScrollView` 又会把超宽内容**居中**显示 ⇒
/// **整页每一行正文都被挪出屏幕**:只剩卡片底色、几条边框线,
/// 和一行被裁掉两头的大标题。
///
/// ⚠️ 关键是**症状与病灶不在一处**:坏的是页面最底下那一行参与人,
/// 而看到的是整页坏掉 —— 现场完全指不到这里。2026-08-31 用户真机实拍到这一屏,
/// 同日在模拟器上把某场次的说话人灌到 30 个,**一模一样地复现**
/// (12 个还只是药丸被压成竖排单字,25 个往上就整页推出去)。
///
/// 说话人多到二十几个不是异常数据:分人模型每个文件从头编号、开集拒识匹配不上的
/// 都各自成簇,一场长会认出二三十个簇是常态。
///
/// ## 判据:`sizeThatFits` 返回的宽度**永远不超过 proposal**
///
/// 这是这个类型存在的全部意义。任何「把内容宽度还给父视图」的写法都会把
/// 上面那个故障再造一遍。
private struct WrapRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = fit(view, limit: limit)
            if x > 0 && x + size.width > limit { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        // ⚠️ `min` 不能去掉 —— 它就是上面那道判据。
        return CGSize(width: min(widest, limit), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let limit = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = fit(view, limit: limit)
            if x > 0 && x + size.width > limit { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// 单个子项也要夹住:一个长到超过一行的名字同样能把整行顶出去。
    private func fit(_ view: LayoutSubview, limit: CGFloat) -> CGSize {
        let natural = view.sizeThatFits(.unspecified)
        guard natural.width > limit else { return natural }
        return view.sizeThatFits(ProposedViewSize(width: limit, height: nil))
    }
}

// MARK: - 一块

/// 重点里的一块。**没条目就整块不出现**(G6:内容块无内容时隐藏,不显示「暂无」)。
private struct SummaryBlock: View {
    let title: String
    let items: [SummaryItem]
    var withheld: Int = 0
    var numbered: Bool = false
    var showsSpeaker: Bool = false
    let onQuote: (SummaryItem) -> Void

    var body: some View {
        if !items.isEmpty || withheld > 0 {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(title)
                    if !items.isEmpty { Text("\(items.count)") }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.C.dim)
                .padding(.bottom, 4)

                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().padding(.leading, numbered ? 28 : 0) }
                    ItemRow(item: item, index: numbered ? i + 1 : nil,
                            showsSpeaker: showsSpeaker, onQuote: onQuote)
                }

                // ⚠️ 被挡下的条目**必须说出来**:「不列」不等于「不说」,
                // 悄悄丢掉条目正是仓规 §3.2 点名的错法,而漏掉承诺是纪要最贵的失误。
                if withheld > 0 {
                    Text("另有 \(withheld) 条承诺没抽全（缺「对谁」或「什么」），没有列出")
                        .font(DS.F.meta)
                        .foregroundStyle(DS.C.dim)
                        .padding(.top, 6)
                }
            }
            .padding(.top, 26)
        }
    }
}

/// 一条:(序号)主文 + 副文 + 「HH:MM ›」看原话。
private struct ItemRow: View {
    let item: SummaryItem
    var index: Int? = nil
    var showsSpeaker: Bool = false
    let onQuote: (SummaryItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let index {
                Text("\(index)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DS.C.dim)
                    .frame(width: 16, alignment: .leading)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.lead)
                    .font(.system(size: 17))
                    .foregroundStyle(DS.C.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let d = item.detail, !d.isEmpty {
                    Text(showsSpeaker ? "\(item.speaker ?? "还不知道是谁") → \(d)" : d)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.C.sub)
                }
                HStack(spacing: 8) {
                    if item.canJumpToQuote {
                        Button { onQuote(item) } label: {
                            Text("\(SessionCardView.stamp(item.atMillis)) 看原话 ›")
                                .font(.system(size: 13))
                                .foregroundStyle(DS.C.brand)
                                .padding(.vertical, 12)
                                .padding(.trailing, 12)
                                .contentShape(Rectangle())
                        }
                        .padding(.vertical, -12)
                        .buttonStyle(.plain)
                    }
                    // 挂起原因原样显示。「归属未定」与「出处待核」是两回事,别压成一句。
                    if let why = item.pendingReason {
                        Text(why)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.C.dim)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DS.C.panel2, in: Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - 原话上下文

/// PRD §4.2.5:前后各 3 句,本条高亮。设计里是 `session-quote-context-v1.html`。
private struct QuoteContextSheet: View {
    let item: SummaryItem
    let database: DatabaseQueue?
    var eventID: Int64? = nil

    @State private var context: QuoteContext?
    @State private var loadFailure: String?
    /// 长按要改人的那一行。
    ///
    /// 🔴 **同一个 `LineRow`,两处行为不同,而界面上没有任何区分。**
    /// 逐字稿页传了 `onReassign`,这一屏没传 —— 用户在逐字稿里学会「长按改人」,
    /// 到这儿长按就没反应,而两行字长得一模一样。他只会以为「有时候能改」。
    @State private var reassigning: QuoteContext.Line?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                DS.C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("原话")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.C.dim)
                        if let loadFailure { Text(loadFailure).foregroundStyle(DS.C.ink) }
                        ForEach(context?.lines ?? []) { line in
                            LineRow(line: line) { reassigning = $0 }
                        }
                    }
                    .padding(.horizontal, DS.S.side)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle(eventID == nil ? "前后各 3 句" : "这件事的原话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $reassigning) { line in
                ReassignSpeakerSheet(line: line, database: database) {
                    // 改完重读这一屏 —— 不重读的话刚改过的那行还挂着旧名字,
                    // 用户会再改一遍。
                    reload()
                }
            }
        }
        .task { reload() }
    }

    private func reload() {
        context = nil
        guard let database else { loadFailure="主库尚未打开";return }
        do {
            context = try SessionDetailProjection.quoteContext(lineID: item.lineID, eventID: eventID, in: database)
            loadFailure = context?.lines.isEmpty == true ? "这句原话已不可用，请回到最新事件。" : nil
        } catch { loadFailure="原话读不出来：\(error)" }
    }
}

/// 一行转写。空洞占位行**长得和真行不一样** —— 它代表「这段没录到」,
/// 画成普通行等于把缺失伪装成内容。
///
/// 长按可改说话人(M1-3,PRD §三:§4.4.11 归 M3,但**M1 保留长按改人/不是我**)。
/// 空洞行与抹除行没有原话,长按对它们没有意义,所以不给入口。
struct LineRow: View {
    let line: QuoteContext.Line
    var onReassign: ((QuoteContext.Line) -> Void)? = nil
    /// 「移出记忆」(§3.1.7)。**撤不回来**,调用方负责二次确认。
    var onRemove: ((QuoteContext.Line) -> Void)? = nil
    /// 「改错字」(M1-20)。走 `TranscriptRevision.revise` —— 唯一写方。
    var onRevise: ((QuoteContext.Line) -> Void)? = nil
    /// 这一行改过几次。非空就挂一个看得见的标记 ——
    /// 🔴 **不标的话,界面上「模型听对了」与「我后来改过」长得一模一样**,
    /// 而这两件事在回看时的可信度完全不同。
    var revisions: [TranscriptRevision.Revision] = []
    var onShowOriginal: ((QuoteContext.Line) -> Void)? = nil
    var selfConfirmationTitle: String? = nil
    var onConfirmSelf: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                // 画布 04:名字与时间一行,正文另起一行;不加框线,白底上靠留白分句。
                HStack(spacing: 8) {
                        if let s = line.speaker {
                            Text(s)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.C.ink)
                        }
                        Text(SessionCardView.stamp(line.atMillis))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(DS.C.dim)
                        if let selfConfirmationTitle, let onConfirmSelf {
                            Button(selfConfirmationTitle, action: onConfirmSelf)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.C.brand)
                                .frame(minHeight: 44)
                                .buttonStyle(.plain)
                        }
                        if !revisions.isEmpty {
                            Button { onShowOriginal?(line) } label: {
                                Text(revisions.count == 1 ? "改过" : "改过 \(revisions.count) 次")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DS.C.sub)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(DS.C.panel2, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(onShowOriginal == nil)
                        }
                }
                Text(line.isGap ? "(这段没录到)" : line.text)
                    .font(.system(size: 17))
                    .lineSpacing(3)
                    .foregroundStyle(line.isGap ? DS.C.dim : DS.C.ink)
                    .italic(line.isGap)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 跳过来的那一句打底色;其余白底无框(画布 04)。
        .background(line.isTarget ? DS.C.brandSoft : .clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        // 长按出菜单,而不是直接改人。
        //
        // ⚠️ **两个动作共用同一个手势是刻意的**:左滑在这个 App 里已经许给了
        // 发现抽屉(§4.5.5「只做左滑一个手势」),而给「移出记忆」另找一个手势
        // 会让用户在两处都不敢动。`contextMenu` 在 iOS 上本来就是长按 ——
        // 手势没变,只是长按之后多了一个选项。
        //
        // 空洞行与抹除行没有原话:改人对它们没有意义,移出记忆对它们已经做过了。
        .contextMenu {
            if !line.isGap && !line.isRedacted {
                if let onReassign {
                    Button { onReassign(line) } label: {
                        Label("这句是谁说的", systemImage: "person.crop.circle")
                    }
                }
                // 改错字(M1-20)。**与「移出记忆」放在同一个菜单**:
                // 用户在这里已经学会了「长按这一行来纠正它」,再给改字另找一个手势
                // 只会让他两个都不敢用。
                if let onRevise {
                    Button { onRevise(line) } label: {
                        Label("改错字", systemImage: "character.cursor.ibeam")
                    }
                }
                if let onRemove {
                    Button(role: .destructive) { onRemove(line) } label: {
                        Label("移出记忆", systemImage: "eye.slash")
                    }
                }
            }
        }
    }
}

// MARK: - 整场逐字稿

/// 设计里是 `session-transcript-v1.html`。
struct TranscriptView: View {
    let sessionID: Int64
    let database: DatabaseQueue?
    /// 改过人就通知上一层重投。
    var onAttributionChanged: (() -> Void)? = nil
    /// 打开时滚到并高亮这一行(`M5-1`:详情页点话题进来)。
    var focusLineID: Int64? = nil
    var eventID: Int64? = nil

    @State private var lines: [QuoteContext.Line] = []
    @State private var reassigning: QuoteContext.Line?
    /// 等确认移出记忆的那一行。**撤不回来,必须二次确认。**
    @State private var pendingRemoval: QuoteContext.Line?
    /// 屏底那一行结果。**改人 / 移出记忆 / 改错字共用一个** ——
    /// 各挂各的 overlay 会在两件事挨着做时叠在一起,而叠上去的那一条谁也读不全。
    @State private var note: Notice?
    @State private var loadFailure: String?
    /// 正在改错字的那一行(M1-20)。
    @State private var revising: QuoteContext.Line?
    /// 这一场改过的行 → 修订记录。**每次 `load()` 重读** ——
    /// 标记若不跟着刷新,刚改完的那一行看上去还是「没改过」。
    @State private var revisions: [Int64: [TranscriptRevision.Revision]] = [:]
    /// 正在回看原文的那一行。
    @State private var showingOriginal: QuoteContext.Line?
    @State private var selfCandidates: [Int64: SpeakerReviews.SelfCandidate] = [:]
    @State private var confirmingSelf: SpeakerReviews.SelfCandidate?

    var body: some View {
        ZStack {
            DS.C.panel.ignoresSafeArea()
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // ⚠️ 「读不出来」和「这一场没有行」是两件事,不能画成同一张白纸。
                    if let f = loadFailure {
                        Text(f).font(.system(size: 13)).foregroundStyle(DS.C.danger)
                    } else if lines.isEmpty {
                        Text(eventID == nil ? "这一场还没有逐字稿。" : "这件事暂未标出原话范围。")
                            .font(.system(size: 13)).foregroundStyle(DS.C.dim)
                    }
                    // 长按任一行 → 改人 / 改错字 / 移出记忆(设计:
                    // `speaker-correction-v1.html` 与 `session-more-delete-v1.html`)。
                    ForEach(lines) { line in
                        LineRow(line: line.id == focusLineID ? line.focused() : line,
                                onReassign: { reassigning = $0 },
                                onRemove: { pendingRemoval = $0 },
                                onRevise: { revising = $0 },
                                revisions: revisions[line.id] ?? [],
                                onShowOriginal: { showingOriginal = $0 },
                                selfConfirmationTitle: selfCandidates[line.id].map {
                                    $0.isClusterConfirmation ? "是你吗？" : "复查这句"
                                },
                                onConfirmSelf: selfCandidates[line.id].map { candidate in
                                    { confirmingSelf = candidate }
                                })
                        .id(line.id)
                    }
                }
                .padding(.horizontal, DS.S.side)
                .padding(.vertical, 16)
            }
            .onChange(of: lines.count) { _, _ in
                if let focusLineID { proxy.scrollTo(focusLineID, anchor: .center) }
            }
            }
        }
        .navigationTitle("原话")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .sheet(item: $reassigning) { line in
            ReassignSpeakerSheet(line: line, database: database) {
                load()
                onAttributionChanged?()
            }
        }
        .alert("把这句移出记忆?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("取消", role: .cancel) { pendingRemoval = nil }
            Button("移出", role: .destructive) {
                if let l = pendingRemoval { remove(l) }
                pendingRemoval = nil
            }
        } message: {
            // 🔴 **代价要说在按之前。** 音频按 5 分钟一块存,删不了半块 ——
            // 同一块里别的话会跟着听不了。不说的话用户下次想听那段,
            // 只会以为「音频功能坏了」。
            Text("这句的文字会换成墓碑、搜不到,行本身留着(引用它的判断不会悬空)。\n"
               + "⚠️ 它所在那 5 分钟的音频会**整块删掉** —— 同一块里别的话也听不了了。\n"
               + "撤不回来。")
        }
        .sheet(item: $revising) { line in
            ReviseLineSheet(line: line, database: database) { result in
                load()
                note = Self.reviseNote(result)
                // 上一层无条件重投。**不按 `quotesUpdated > 0` 判**:纪要那五块里
                // 除了 quote 还有跳原话的落点,而原话已经变了 —— 只有引文变了才刷新的话,
                // 退回去点「看原话」看到的仍然是缓存里的旧句子。
                // (回调名字叫 `onAttributionChanged` 是历史称呼,它做的事就是重读这一场。)
                onAttributionChanged?()
            }
        }
        .sheet(item: $showingOriginal) { line in
            RevisionHistorySheet(line: line, revisions: revisions[line.id] ?? [])
        }
        .sheet(item: $confirmingSelf) { candidate in
            SelfVoiceSheet(candidate: candidate, database: database, onDone: {
                load()
                onAttributionChanged?()
            })
        }
        .overlay(alignment: .bottom) {
            if let note {
                Text(note.text)
                    .font(DS.F.meta)
                    .foregroundStyle(note.isError ? DS.C.danger : DS.C.sub)
                    .multilineTextAlignment(.leading)
                    .padding(12)
                    .background(DS.C.panel2, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, DS.S.side)
                    .padding(.bottom, 24)
                    // 做完要说结果 —— 静默成功和静默失败在屏上一模一样。
                    // ⚠️ 出错那一条**不自动消失**:用户可能正低头没看屏,
                    // 而「改字没落上」是他必须知道的事。
                    .task {
                        guard !note.isError else { return }
                        try? await Task.sleep(for: .seconds(4))
                        self.note = nil
                    }
                    .onTapGesture { self.note = nil }
            }
        }
    }

    /// 改完的那句话。**`quotesUpdated` 与 `staleQuotes` 都要说出来。**
    ///
    /// 🔴 `staleQuotes` 尤其不能吞:那几条卡片现在引的话与原话对不上了,
    /// 下一次跑校验它们会变红,而那时没人会把红归因到这次改字。
    static func reviseNote(_ r: TranscriptRevision.Result) -> Notice {
        var s = "改好了。"
        if r.quotesUpdated > 0 { s += "顺带更新了 \(r.quotesUpdated) 条引文。" }
        guard !r.staleQuotes.isEmpty else { return .info(s) }
        return .error(s + "\n⚠️ 还有 \(r.staleQuotes.count) 条引文对不上新原文了"
                        + "(\(r.staleQuotes.map(\.table).joined(separator: " / ")))"
                        + " —— 那几张卡片引的话需要你回头看一眼。")
    }

    /// 走 `MemoryRemoval`(§3.1.7 唯一受控的 redact 通道)。**不自己写 UPDATE** ——
    /// A1 触发器会 ABORT,而绕过去就是第二个写方。
    private func remove(_ line: QuoteContext.Line) {
        guard let database else { note = .error("主库没打开,移不出去"); return }
        do {
            // 那一行所在的**整块**。块号为 nil 的行定位不到音频 ——
            // 那时只立墓碑,并如实说明音频没删掉(不猜块号,见 `LineAudio`)。
            let blockSeq = try database.read { db in
                try Int.fetchOne(db, sql: "SELECT block_seq FROM transcript_lines WHERE line_id = ?",
                                 arguments: [line.id])
            }
            let audio = blockSeq.map { seq in
                ProcessingPump.blocks(of: sessionID, ext: "m4a", in: database)
                    .filter { $0.blockSeq == seq }.map(\.fileURL)
            } ?? []
            let r = try MemoryRemoval.removeLines([line.id], audioFiles: audio, in: database)
            ProcessingEvents.record(
                trigger: .foreground, outcome: "移出记忆:场次 \(sessionID) 的 1 行",
                detail: "\(r.redactedLines) 行置墓碑 · 删掉 \(r.deletedAudioFiles) 个音频块"
                      + (blockSeq == nil ? "(这一行没有块号,音频定位不到,没删)" : ""),
                in: database)
            note = blockSeq == nil
                ? .info("移出记忆了。⚠️ 这一行定位不到音频(录得早,没有块号),那段声音还在盘上。")
                : .info("移出记忆了 —— 文字置墓碑,那 5 分钟的音频已删。")
            load()
            onAttributionChanged?()
        } catch {
            // 失败要说原因。尤其「音频没删干净」那一条 ——
            // 用户以为清掉了而它还在,是这里最贵的一种静默失败。
            note = .error("没能移出去:\(error)")
        }
    }

    private func load() {
        guard let database else { loadFailure = "主库没打开,逐字稿读不出来"; return }
        do {
            lines = try SessionDetailProjection.transcript(sessionID: sessionID, eventID: eventID, in: database)
            // 改过的行要挂标记 —— 与正文同一次读出来,不然刚改完那一行还是「没改过」。
            revisions = try TranscriptRevision.revisions(sessionID: sessionID, in: database)
            selfCandidates = Dictionary(uniqueKeysWithValues:
                try SpeakerReviews.selfCandidates(sessionID: sessionID, in: database).map { ($0.lineID, $0) })
            loadFailure = nil
        } catch {
            lines = []
            loadFailure = "读逐字稿出错:\(error)"
        }
    }
}

// MARK: - 改错字(M1-20)

/// 长按「改错字」弹的那一屏。ASR 把「Claude」听成「cloud」,用户要改的就是这一个字。
///
/// ## 这一屏**不自己写 `UPDATE`**
///
/// 只调 `TranscriptRevision.revise` —— 与「移出记忆」只调 `MemoryRemoval` 是同一条纪律。
/// 而这次连纪律都不必靠:v18 的冻结层通道二要求先有一条对得上的修订记录,
/// 绕过去的 UPDATE 会被触发器 ABORT。
///
/// ## 预填原文,不给空框
///
/// 用户要改的是**一个字**。空框等于逼他把整句重打一遍 ——
/// 重打过程里顺手改掉的别的字,就是一次没人察觉的原话篡改。
struct ReviseLineSheet: View {
    let line: QuoteContext.Line
    let database: DatabaseQueue?
    let onDone: (TranscriptRevision.Result) -> Void

    @State private var draft: String
    @State private var note: Notice?
    @Environment(\.dismiss) private var dismiss

    init(line: QuoteContext.Line, database: DatabaseQueue?,
         onDone: @escaping (TranscriptRevision.Result) -> Void) {
        self.line = line
        self.database = database
        self.onDone = onDone
        _draft = State(initialValue: line.text)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("原话")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.C.dim)
                        Text(line.text)
                            .font(.system(size: 14))
                            .foregroundStyle(DS.C.sub)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(DS.C.panel2,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("改成")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.C.dim)
                            .padding(.top, 4)
                        TextEditor(text: $draft)
                            .font(.system(size: 15))
                            .foregroundStyle(DS.C.ink)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 120)
                            .padding(8)
                            .background(DS.C.panel,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(DS.C.line, lineWidth: 1))

                        if let note {
                            Text(note.text)
                                .font(.system(size: 13))
                                .foregroundStyle(note.isError ? DS.C.danger : DS.C.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // 代价说在按之前:改过的行会永久留一条痕,而这是刻意的。
                        Text("改字会留下一条修订记录(原文可以回看,删不掉)。"
                           + "版本不会变,时间轴与说话人一个字都不动。")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.C.dim)
                            .padding(.top, 6)
                    }
                    .padding(.horizontal, DS.S.side)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("改错字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存下来") { save() }
                        .disabled(draft == line.text || draft.isEmpty)
                }
            }
        }
    }

    private func save() {
        guard let database else { note = .error("主库没打开,改不了"); return }
        do {
            let r = try TranscriptRevision.revise(
                lineID: line.id, to: draft, actor: "user",
                now: ISO8601DateFormatter.growth.string(from: Date()), in: database)
            onDone(r)
            dismiss()
        } catch {
            // 写不进去要说出来。默默关掉,用户会以为改上了。
            note = .error("没能改:\(error)")
        }
    }
}

/// 「改过」那个标记点开之后看到的东西:**原文是什么**。
///
/// 不做逐字 diff —— 用户要回答的问题是「当时听到的原话是哪一句」,
/// 一屏两句话就够;高亮到字符级只会让人去研究界面而不是内容。
struct RevisionHistorySheet: View {
    let line: QuoteContext.Line
    let revisions: [TranscriptRevision.Revision]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                DS.C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("现在是")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.C.dim)
                        block(line.text, background: DS.C.brandSoft)

                        // 正序排,最早那条在最上面 —— 「一开始听成了什么」是这一屏的主问题。
                        ForEach(revisions, id: \.id) { r in
                            Text("\(r.at) · \(r.actor) 改的,改之前是")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.C.dim)
                                .padding(.top, 6)
                            block(r.before, background: DS.C.panel2)
                        }
                    }
                    .padding(.horizontal, DS.S.side)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("这一行改过什么")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func block(_ text: String, background: Color) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(DS.C.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

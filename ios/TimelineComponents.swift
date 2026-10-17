import SwiftUI

// 首页的叶子组件。全部是纯渲染:只吃 Presentation/ 里的展示模型,自己不取数、不改数。
//
// 纪律(对应 docs 设计哲学「文案纪律」):
//   · 全部陈述句,只说发生了什么,不评价、不要求回应
//   · 字段缺失 = 那一块不渲染,绝不用占位数据顶上
//   · 颜色不是唯一编码,场景色条永远跟着场景文字一起出现
//
// ── 2026-08-08 按 PRD 收窄(M0-1b,拍板 A)─────────────────────────
//
// 这个文件从旧仓搬来时绑的是 `SurfaceModels.swift`——那是旧仓服务端下发的报文契约,
// 且 `Episode` 带 `who`。搬进来等于给新仓塞进**第二个归属真相源**(铁律 3),
// 所以改绑 `Presentation/HomeModels.swift`,**「谁说的」一个字段都不再经过这里**;
// 要显示说话人,由上层现查归属层,不从卡片模型里取。
//
// 删掉的六个组件——都是 PRD 里没有对应概念、或不属于 M1 的(原文可从 git 取回):
//   TLSpanRow      空白段  · PRD 全文零命中
//   TLFragsBlock   零碎块  · PRD 只有折叠成一行的「还有 N 段零碎」,没有展开块
//   TLReviewCard   周回顾  · 属 M4
//   TLDayRow       日行档  · 场景泳道与标记在 PRD 里没有依据;「更早」只是按天折叠
//   TLEraCard      纪元    · PRD 全文零命中,这个概念已经没有了
//   TLEmergenceDrawer 浮现抽屉 · PRD 里改名「发现抽屉」且属 M3(M1 只预留容器位)
//
// 留下的四个正好覆盖 PRD §4.2.2 首页四块:
//   TLNotice 提示条 · TLEpisodeCard 场次卡 · TLFoldBar 零碎折叠行 · TLDayHeader 按天折叠

// MARK: - 排版工具

/// 时间线自己的小工具集（命名前缀 TL，避免和另外两条工作线撞名）。
enum TL {
    /// 左右留白：所有 feed 行共用，让 sticky 日界的底色能盖满整行宽度
    static let gutter: CGFloat = DS.S.pad
    /// 时刻栏 / 主干线的固定宽度——三类元素靠它对齐成一条竖线
    static let railW: CGFloat = 58
    static let spineW: CGFloat = 16
    /// 折叠段到几条为止就地摊开，超过就收成一条聚合条
    static let foldInlineMax = 4

    /// 标记色注册表：加一种标记只加一行，日行渲染逻辑不动
    static let markColors: [String: Color] = [
        "决策": DS.C.vio, "冲突": DS.C.danger, "承诺": DS.C.grn,
    ]
    static func markColor(_ reason: String?) -> Color {
        guard let reason else { return DS.C.gray }
        return markColors[reason] ?? DS.C.gray
    }

    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "2026-07-25" → "07月25日"；解析不出就把原文照抄，不猜
    static func md(_ d: String) -> String {
        let p = d.split(separator: "-")
        guard p.count == 3 else { return d }
        return "\(p[1])月\(p[2])日"
    }

    /// "2026-07-25" → "周六"；解析不出返回 nil（那一块就不渲染）
    static func weekday(_ d: String) -> String? {
        guard let date = ymd.date(from: d) else { return nil }
        let i = Calendar(identifier: .gregorian).component(.weekday, from: date) - 1
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        guard i >= 0, i < names.count else { return nil }
        return names[i]
    }

    /// 分钟 → "8h32m"（日总时长用）
    static func dur(_ min: Int) -> String { "\(min / 60)h\(String(format: "%02d", min % 60))m" }

    /// 分钟 → "43分钟" / "2.3h"（空白段用）
    static func hm(_ min: Int) -> String {
        min >= 60 ? String(format: "%.1fh", Double(min) / 60) : "\(min)分钟"
    }
}

extension View {
    /// feed 行的左右留白。放在行内而不是外层容器上，sticky 日界才能盖满整行。
    func tlGutter() -> some View { padding(.horizontal, TL.gutter) }
}

// MARK: - 主干线

private struct VLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}

/// 时间线主干：实线 = 有记录，虚线 = 空白段。dot 非空时在 dotTop 处点一颗场景色的节点。
struct TLSpine: View {
    var dashed: Bool = false
    var lineColor: Color = DS.C.line
    var dot: Color? = nil
    var dotTop: CGFloat = 19
    var dotSize: CGFloat = 9
    var hollow: Bool = false

    var body: some View {
        VLine()
            .stroke(lineColor, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 5] : []))
            .frame(width: TL.spineW)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) {
                if let dot {
                    Group {
                        if hollow {
                            Circle().strokeBorder(dot, lineWidth: 1.5).background(Circle().fill(DS.C.bg))
                        } else {
                            Circle().fill(dot)
                        }
                    }
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: dotTop)
                }
            }
    }
}

/// 左侧时刻栏。没有墙钟起点的片段写「只知顺序」——不编时间。
struct TLRail: View {
    let top: String
    var bottom: String? = nil
    var topPad: CGFloat = 16

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(top).font(DS.F.meta.monospacedDigit()).foregroundStyle(DS.C.sub)
            if let bottom { Text(bottom).font(DS.F.meta).foregroundStyle(DS.C.dim) }
        }
        .frame(width: TL.railW, alignment: .trailing)
        .padding(.top, topPad)
    }
}

// MARK: - 提示条（缺口 / 只知顺序 / 没筛）

struct TLNotice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DS.F.meta)
            .foregroundStyle(DS.C.amb)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(DS.C.amb.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: DS.S.radiusSm, style: .continuous)
                .strokeBorder(DS.C.amb.opacity(0.35), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.S.radiusSm, style: .continuous))
            .padding(.vertical, 4)
            .tlGutter()
    }
}

// MARK: - 日界

struct TLDayHeader: View {
    let date: String
    let cover: String?
    let isLatest: Bool
    /// nil = 这个日界不可点（d0 本来就是完整的，没有可切的档）
    let zoomLabel: String?
    let action: (() -> Void)?

    private var titleText: String {
        var s = TL.md(date)
        if let w = TL.weekday(date) { s += " · \(w)" }
        if isLatest { s += " · 最新" }
        return s
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { row.contentShape(Rectangle()) }.buttonStyle(.plain)
            } else {
                row
            }
        }
        .frame(minHeight: 44)
        .tlGutter()
        .background(DS.C.bg)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(action == nil ? "" : "切换这一天的详略")
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(titleText).font(DS.F.cardTitle).foregroundStyle(DS.C.ink)
            if let cover, !cover.isEmpty {
                Text(cover).font(DS.F.meta.monospacedDigit()).foregroundStyle(DS.C.dim)
            }
            Spacer(minLength: 4)
            if let zoomLabel {
                Text(zoomLabel)
                    .font(DS.F.meta).foregroundStyle(DS.C.sub)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(DS.C.line, lineWidth: 1))
                    .fixedSize()
            }
        }
        .padding(.top, 12).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 事件卡

struct TLEpisodeCard: View {
    let card: SessionCard
    let lite: Bool
    let open: Bool
    let toggle: () -> Void

    private var summary: SessionSummary? { card.state.summary }
    private var durText: String { TL.dur(card.durationMinutes) }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            TLRail(top: card.startTime, bottom: durText, topPad: lite ? 11 : 16)
            TLSpine(dot: DS.C.vio, dotTop: lite ? 14 : 19, dotSize: lite ? 7 : 9)
            body_
        }
        .tlGutter()
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { head.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text([summary?.title, summary?.oneLiner]
                    .compactMap { $0 }.joined(separator: "，")))
                .accessibilityValue(Text(open ? "已展开" : "已收起"))
                .accessibilityHint(Text("展开这一场的要点和原话"))
                .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
            if open, summary != nil { detail }
        }
        .background(lite ? Color.clear : DS.C.panel)
        .clipShape(RoundedRectangle(cornerRadius: DS.S.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.S.radius, style: .continuous)
            .strokeBorder(DS.C.line, lineWidth: lite ? 0 : 1))
        .padding(.vertical, lite ? 5 : 7)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = summary {
                Text(s.title).font(DS.F.cardTitle).foregroundStyle(DS.C.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(s.oneLiner).font(DS.F.lead).foregroundStyle(DS.C.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Text(open ? "收起" : "展开").font(DS.F.meta).foregroundStyle(DS.C.dim)
            } else {
                // 还没出纪要:只说状态,不编标题。PRD §4.1.7 的文案由 stateText 给。
                Text(stateText).font(DS.F.lead).foregroundStyle(DS.C.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, lite ? 9 : 11)
        .frame(minHeight: 44)
    }

    /// PRD §4.1.7 的十个展示态文案。没有纪要的那几个态靠它说话。
    private var stateText: String {
        switch card.state {
        case .recording(let m):        return "记录中 · \(TL.dur(m))"
        case .waitingForNetwork:       return "等网络好了就传"
        case .uploading(let p):        return "上传中 \(p)%"
        case .queued(let ahead):       return "排队中，前面还有 \(ahead) 段"
        case .processing:              return "整理中"
        case .attributionPending:      return "已出纪要，说话人还在整理"
        case .done:                    return ""
        case .partialFailure(let what): return "\(what)没提取出来"
        // ⚠️ **失败那句不在这里写第二遍。** 它要分「会自己好 / 不会自己好」，
        // 而两处各写一份的话，迟早只有一处跟上——那时同一场在两个界面上
        // 一个说「重试中」、一个说「不会自己好了」，用户信哪个都是错的。
        case .failed:                  return card.state.presentation.label
        case .degraded:                return "只保留了文字记录"
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            let points = summary?.keyPoints ?? []
            if points.isEmpty {
                Text("这一场没有成句的要点。").font(DS.F.body).foregroundStyle(DS.C.dim).padding(.top, 11)
            } else {
                Text("要点").font(DS.F.tag).foregroundStyle(DS.C.vio).padding(.top, 11)
                ForEach(points, id: \.lineID) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.text).font(DS.F.body).foregroundStyle(DS.C.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        // 逐字引文单独一行:它是能跳回原话的那一份,和上面可改写的自由文本不是一回事
                        Text("「\(p.quote)」").font(DS.F.body).foregroundStyle(DS.C.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 11)
                    .overlay(alignment: .leading) { Rectangle().fill(DS.C.line2).frame(width: 2) }
                    .padding(.top, 9)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.bottom, 12)
        .overlay(alignment: .top) { Rectangle().fill(DS.C.line).frame(height: 1) }
    }
}

// MARK: - 折叠成一行的场次

struct TLFoldRow: View {
    let card: SessionCard
    let toggle: () -> Void

    private var title: String { card.state.summary?.title ?? "没出纪要的一段" }

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: 7) {
                Text(card.startTime)
                    .font(DS.F.meta.monospacedDigit()).foregroundStyle(DS.C.dim)
                    .frame(width: TL.railW, alignment: .trailing)
                TLSpine()
                    .overlay(alignment: .center) {
                        Circle().strokeBorder(DS.C.gray, lineWidth: 1.5)
                            .background(Circle().fill(DS.C.bg)).frame(width: 7, height: 7)
                    }
                HStack(spacing: 5) {
                    Text(title).font(DS.F.meta).foregroundStyle(DS.C.sub).lineLimit(1)
                    Text("· \(TL.dur(card.durationMinutes))")
                        .font(DS.F.meta).foregroundStyle(DS.C.dim).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .tlGutter()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("折进零碎的一段，\(title)"))
        .accessibilityHint(Text("展开这一段"))
    }
}

struct TLFoldBar: View {
    let count: Int
    let range: String?
    let gist: String?
    let open: Bool
    let toggle: () -> Void

    private var text: String {
        var s = "另外 \(count) 段没入镜"
        if let range { s += " · \(range)" }
        if let gist, !gist.isEmpty { s += " · \(gist)" }
        return s
    }

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 6) {
                Text(text).font(DS.F.meta).foregroundStyle(DS.C.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.dim)
            }
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .tlGutter()
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(DS.C.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(DS.C.line).frame(height: 1) }
        .accessibilityValue(Text(open ? "已展开" : "已收起"))
        .accessibilityHint(Text("展开这批没入镜的片段"))
        .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
    }
}

import SwiftUI
import UIKit

/// growth 设计系统（DS）—— Apple 系统风格，全项目唯一视觉真值。
///
/// ## 2026-10-12：从米底墨绿换成 Apple 系统色（`M5-1`）
///
/// 用户嫌「纸面」那版丑，要参考 Apple 重做；界面真值是设计画布（`docs/intents/M5-1/spec.md`）。
/// 语义名全部保留 —— 旧调用点一行不用改，换的只是值。
///
/// 🔴 **不用红色做任何状态与提醒**（用户 2026-10-12：「压迫性太强」）。
/// `danger` / `red` 两个名字还在（30 处调用），**值已改指中性深色**：
/// 出错靠文字说清楚，不靠颜色吓人。系统删除确认框里 `.destructive` 的红字是 iOS 惯例，不在此列。
/// `eval/checks/test_opaque_bars.py` 扫源码，界面层写红色会红。
///
/// 2026-10-13 M5-2：浅蓝底、白色表面与蓝色追问入口。
/// 实算对比度（对白底 / 对 `#F4F7FC`）：ink 15.83 / 14.74 · sub 9.48 / 8.83 · dim 5.33 / 4.97 · brand 6.02 / 5.60，
/// 浅蓝背景 `#EAF0FF` 上最低正文对比度为 dim 4.67:1。
/// 都过 WCAG AA 正文 4.5:1。
enum DS {

    // MARK: - 颜色

    enum C {
        // 表面：分组底 → 卡片白 → 卡内浅灰
        static let bg     = Color(hex: 0xF4F7FC)
        static let panel  = Color(hex: 0xFFFFFF)   // 卡片
        static let panel2 = Color(hex: 0xEDF2F9)
        static let well   = panel2
        // 分隔线
        static let line   = Color(hex: 0xDCE4F0)
        static let line2  = Color(hex: 0xB6C4D9)
        // 文字三级
        static let ink    = Color(hex: 0x17223A)
        static let sub    = Color(hex: 0x39465F)
        static let dim    = Color(hex: 0x5D6C83)

        /// 主色。文字、主按钮底色（白字压上去 6.02:1）。
        static let brand     = Color(hex: 0x3657D6)
        static let brandSoft = Color(hex: 0xEAF0FF)
        /// 「在听」的状态点。只当圆点用，不当文字色（绿字过不了对比度）。
        static let live      = Color(hex: 0x34C759)
        /// ~~出问题 / 冲突 `#A33C36`~~ **2026-10-12 改指中性深色**，见文件头。
        static let danger    = ink

        // MARK: 旧色名 —— 场景色降级后的去处（2026-08-14 起单色 + 文字标签，见 sceneColor）
        static let vio    = brand
        static let cy     = dim
        static let amb    = dim
        static let grn    = brand
        static let gray   = dim
    }

    // MARK: - 字号

    enum F {
        static let title     = Font.headline
        static let cardTitle = Font.headline
        static let body      = Font.body
        static let lead      = Font.subheadline
        static let meta      = Font.caption
        static let tag       = Font.caption.weight(.semibold)
    }

    // MARK: - 间距

    enum S {
        /// 页面左右留白。设计里是 `--side:20px`(窄于 375pt 收到 16)。
        /// 与 `pad` 分开:`pad` 是**卡内**的,改一个不该带动另一个。
        static let side: CGFloat     = 20
        static let pad: CGFloat      = 18    // 卡内边距
        static let gap: CGFloat      = 14    // 卡与卡
        static let radius: CGFloat   = 18    // 留白卡片
        static let radiusSm: CGFloat = 14    // 小块圆角
    }

    // MARK: - 注册表：加一个场景只加一行，渲染逻辑不动

    /// 场景 → （色，短标签）。
    /// ⚠️ 色这一列现在**全部同色**（降级的结果），真正区分靠标签。留着这一列是因为
    /// 加回色相时只改这里；`sceneColor` 的调用点不用动。
    private static let sceneTable: [String: (Color, String)] = [
        "办公室会议": (C.vio,  "会议"),
        "工位":      (C.cy,   "工位"),
        "餐厅":      (C.amb,  "饭"),
        "通勤":      (C.gray, "通勤"),
        "家":        (C.grn,  "家"),
        "户外":      (C.grn,  "户外"),
        "电话/线上":  (C.amb,  "线上"),
        "其他":      (C.gray, "其他"),
    ]

    /// 场景 → 色。没登记过的一律归 dim，不猜。
    ///
    /// ⚠️ **2026-08-14 起这个函数几乎不携带信息了** —— 除「在动/出错」走 danger 外
    /// 其余场景同色。**任何只画色点不画 `sceneLabel` 的界面，从此就是没信息的界面。**
    /// 深色版里这还只是无障碍建议，现在它是唯一的区分手段。
    static func sceneColor(_ scene: String) -> Color {
        sceneTable[scene]?.0 ?? C.dim
    }

    /// 场景 → 文字标签。颜色永远不能是唯一编码，色点旁边必须有这个。
    /// 没登记过的原样回显（报文里写的是什么就显示什么），空的才叫「其他」。
    static func sceneLabel(_ scene: String) -> String {
        if let hit = sceneTable[scene]?.1 { return hit }
        return scene.isEmpty ? "其他" : scene
    }

    /// 线的状态 → 色。tone ∈ hot/stuck/done/open/calm。
    ///
    /// 从五色收到**三色**：新设计只出 brand / danger / 中性三档，凑不出五个色相。
    /// 保留 danger 这一档是刻意的 —— 「卡住了」和「平静」长得一样是缺陷不是简化。
    static func toneColor(_ tone: String) -> Color {
        switch tone {
        case "hot", "stuck": return C.danger   // 要人管的
        case "done":         return C.brand    // 了了的
        case "open", "calm": return C.dim
        default:             return C.dim
        }
    }

    // MARK: - 动效降级

    /// 系统开了「减弱动态效果」就返回 nil（`withAnimation(DS.motion)` 直接退化成无动画）。
    static var motion: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : .snappy(duration: 0.22)
    }

    // MARK: - 复用块

    static let cardRadius: CGFloat = S.radius
    static let cardPad: CGFloat = S.pad
    static let cardSpacing: CGFloat = S.gap

    /// 当前三页统一的标题层级，随系统字号缩放。
    static let pageTitle = Font.title2.weight(.semibold)

    /// 展示层统一白色内容面板；不改变业务内容或状态。
    static func panelShape() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: S.radius, style: .continuous)
    }

    /// 面板卡：白底、无描边、无投影（iOS 分组卡的样子）。
    static func card<Content: View>(@ViewBuilder _ content: () -> Content,
                                    radius: CGFloat = S.radius,
                                    pad: CGFloat = S.pad) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(pad)
            .background(C.panel)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// 区块标题：一行 13pt 粗体 + 可选右侧统计。
    static func sectionTitle(_ s: String, trailing: String? = nil) -> some View {
        HStack(spacing: 7) {
            Text(s).font(F.tag).tracking(1.2).foregroundStyle(C.sub)
            if let trailing {
                Spacer()
                Text(trailing).font(F.meta).foregroundStyle(C.dim)
            }
        }
    }

    /// 页面底色。浅色版几乎是平的 —— 设计里 `--bg` 就是一个纯色，
    /// 这里留一档极浅的渐变只为让长列表滚到底时有个收口。
    static var bgGradient: LinearGradient {
        LinearGradient(colors: [C.bg, C.well], startPoint: .top, endPoint: .bottom)
    }

    // MARK: - 旧名兼容层
    //
    // ChatView / SpeakerConfirmView / VoiceEnrollView 还在用 `DS.Colors.*`（都在 `_legacy/`，
    // 不进 target）。这一版不动那几个文件，所以旧名保留、值全部改指浅色盘。
    // 等它们退役可以整段删。
    enum Colors {
        static let ink    = C.ink
        static let body   = C.sub
        static let sub    = C.sub
        static let faint  = C.dim
        /// 旧 iris 既当文字色又当气泡底色。浅底下前景要够深，气泡里压白字也要够深——
        /// brand `#3F7469` 两头都成立（文字 4.92:1，白字压上去 5.37:1）。
        static let iris   = C.brand
        /// 旧 irisD 是「更深的紫」。浅底下它仍然要更深，取 brand-deep。
        static let irisD  = Color(hex: 0x315F56)
        static let irisBg = C.brandSoft
        static let amber  = C.amb
        static let coral  = C.danger
        static let teal   = C.brand
        static let card   = C.panel
        static let hair   = C.line
        static let shadow = Color.black.opacity(0.08)
        static let bgTop  = C.bg
        static let bgBot  = C.well
    }
}

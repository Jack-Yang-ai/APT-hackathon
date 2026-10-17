import SwiftUI

/// 本次图标方案的模板矢量：颜色由使用位置决定，旁边保留文字含义。
struct AptGlyph: View {
    enum Kind: String {
        case now, ask, me, record, source
        var asset: String { "apt-" + rawValue }
    }

    let kind: Kind
    var size: CGFloat = 20

    var body: some View {
        Image(kind.asset)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

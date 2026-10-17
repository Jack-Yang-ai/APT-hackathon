import SwiftUI

/// 共用雾蓝团子母版；工作状态只作轻微形变，不另维护一套角色。
struct Mascot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var working = false
    var size: CGFloat = 48

    var body: some View {
        Image("AptAgent")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .scaleEffect(working ? 0.96 : 1)
            .rotationEffect(.degrees(working ? -4 : 0))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: working)
            .accessibilityHidden(true)
    }
}

/// 手机只知道已同步账本是否收尾,不能据此声称手表此刻仍在收音。
enum WatchRecordingStatus: Equatable {
    case awaiting, unclosed

    init(sessionOpen: Bool) { self = sessionOpen ? .unclosed : .awaiting }
    var label: String { self == .unclosed ? "手表未收尾" : "手表录音" }
    var dot: Color { DS.C.line2 }
}

struct StatusPill: View {
    let status: WatchRecordingStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.dot).frame(width: 7, height: 7)
            Text(status.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.C.ink)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

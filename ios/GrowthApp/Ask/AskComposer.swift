import SwiftUI

/// 主页面与聊天共享同一输入组件；模型负责草稿、请求锁与问题落盘。
struct AskComposer: View {
    @ObservedObject var model: AskViewModel
    var sending = false
    var enabled = true
    var showsBackground = false
    var onSend: (() -> Void)?
    private var canSend: Bool { enabled && !sending && model.canSend }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsBackground, enabled, let label = model.contextLabel {
                HStack {
                    Text("带着背景 · \(label)").lineLimit(2)
                    Spacer(minLength: 0)
                    Button { Task { await model.clearBackground() } } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.disabled(model.inFlight || model.isSwitching).accessibilityLabel("移除这份背景")
                }.font(.caption).foregroundStyle(DS.C.dim)
            }
            if let failure = model.draftFailure { Text(failure).font(.caption).foregroundStyle(DS.C.ink) }
            if showsBackground, let failure = model.readFailure { Text(failure).font(.caption).foregroundStyle(DS.C.ink) }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("从这里接着想", text: enabled ? $model.draft : .constant(""), axis: .vertical)
                    .font(DS.F.body).lineLimit(1...4)
                    .padding(.leading, 6).padding(.vertical, 10)
                    .disabled(model.isSwitching || sending || !enabled)
                    .accessibilityLabel("向问问提问")
                Button {
                    if let onSend { onSend() } else { Task { await model.send() } }
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 44, height: 44)
                        .background(canSend ? DS.C.brand : DS.C.line2, in: Circle())
                }.disabled(!canSend).accessibilityLabel("发送问题")
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(DS.C.panel, in: DS.panelShape())
            .overlay(DS.panelShape().stroke(DS.C.line, lineWidth: 1))
            .shadow(color: DS.C.ink.opacity(0.06), radius: 8, y: 2)
        }
        .padding(.horizontal, DS.S.side).padding(.vertical, 10)
        .background(DS.C.bg)
    }
}

import SwiftUI
import GRDB

/// 所有页面复用的追问入口：只带背景和预填问题，由用户发送。
struct ContextualAskButton: View {
    let database: DatabaseQueue?
    let scope: AskScope
    var question = "这件事目前定了什么，还有哪些没定？"
    var title = "继续问"
    @EnvironmentObject private var navigation: AskNavigation

    var body: some View {
        Button { navigation.open(scope: scope, question: question) } label: {
            HStack(spacing: 7) {
                AptGlyph(kind: .ask, size: 18)
                Text(title).fixedSize(horizontal: false, vertical: true)
            }
                .font(DS.F.tag).foregroundStyle(DS.C.brand)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(DS.C.brandSoft, in: Capsule())
        }
        .buttonStyle(.plain).disabled(database == nil)
    }
}

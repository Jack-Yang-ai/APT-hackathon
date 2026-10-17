import SwiftUI

// 录音相关的零件。首页本身在 `HomeView`。
//
// ⚠️ 这里曾经还有 `StartRecordingCard`(未开始时那个大圆钮)与 `TodayRecordings`
// (今天录了几场的列表)。**M1-1 把首页铺开之后两个都被顶替了**:
// 前者换成设计里的 `.record` 条(`HomeView.RecordEntry`),后者换成真正的场次卡
// —— 场次卡走的是 `HomeProjection`,而 `TodayRecordings` 直接读账本,
// 留着它等于让首页上有两份「今天录了什么」,而两份迟早不一样。
//
// `TodayRecordings` 当初是因为用户 2026-08-10 试用时说「录音结果也没有了」才加的。
// 那个需求现在由场次卡承接,已在模拟器上实拍确认。

// ~~`RecordingStatusBar`(录音中常驻的状态条:已录时长 · 状态 · 暂停 · 结束)~~
// 2026-10-12 `M5-1` 退役:状态进了此刻页顶部的胶囊(在听 / 暂停录音中),
// 时长与暂停进了录音卡,「结束」收进暂停按钮的长按菜单。

/// 重开 App 时那条如实的提示,以及内核抛出来的失败。
///
/// 两者都**不自动消失**:录音是「一次没录上就永远补不回来」的东西,
/// 一闪而过的提示等于没提示。要用户自己点掉。
struct RecordingNotices: View {
    @ObservedObject var vm: RecordingViewModel

    var body: some View {
        VStack(spacing: DS.S.gap) {
            if let notice = vm.relaunchNotice {
                banner(notice, tint: DS.C.amb) { vm.relaunchNotice = nil }
            }
            if let failure = vm.failure {
                banner("录音出错:\(failure)", tint: DS.C.danger) { vm.failure = nil }
            }
            // 库的问题与录音的问题分开说:录音坏了是「这一场没了」,
            // 库坏了是「录下来的东西进不了库」——用户该做的事完全不同。
            if let failure = vm.databaseFailure {
                banner(failure, tint: DS.C.danger) { vm.databaseFailure = nil }
            }
        }
    }

    private func banner(_ text: String, tint: Color,
                        dismiss: @escaping () -> Void) -> some View {
        DS.card {
            HStack(alignment: .top, spacing: DS.S.gap) {
                Text(text)
                    .font(DS.F.lead)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("知道了", action: dismiss)
                    .font(DS.F.lead)
                    .foregroundStyle(DS.C.sub)
            }
        }
    }
}

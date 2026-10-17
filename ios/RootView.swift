import SwiftUI

/// App 的根。**只负责持有 `RecordingViewModel` 的生命周期**,画面全在 `HomeView`。
///
/// 之前这里就是首页本身(M0 期只有录音一件事)。M1-1 把首页铺开之后,
/// 内容搬进了 `HomeView` —— 根视图不该同时是某一屏,否则以后加 tab 时
/// 「哪一屏是根」和「根上有什么」会缠在一起。
struct RootView: View {
    @StateObject private var recording = RecordingViewModel()

    var body: some View {
        AppShell(vm: recording)
    }
}

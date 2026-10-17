import SwiftUI

// import 在这里的作用是让「GRDB 真的链上了」变成一个编译期事实,
// 而不是只写在 project.yml 里的一行声明。主库层见 M0-2a。
import GRDB

@main
struct GrowthAppMain: App {

    // 真后台要的两个回调 SwiftUI 没有对应物(M1-4c):
    // · App **被杀之后**、系统为送传输回调把它冷启动起来 —— 入口只有 AppDelegate
    // · `BGTaskScheduler.register` 必须在 didFinishLaunching 返回前调完
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                // 这一套设计只有浅色一版(`docs/design-h5/` 50 页里只有 1 页写了
                // prefers-color-scheme,还是被否掉的那页)。DS 的色值全是写死的,
                // 所以界面本身在系统暗色下也照样渲染成浅色 —— **但状态栏不会**:
                // 系统会按暗色给它白字,压在我们的米白底上等于看不见。
                // 钉死浅色是承认「没有暗色版」这个事实,不是偷懒。真要做暗色版,
                // 改 DS.C 那一段并删掉这行,两件事必须一起做。
                .preferredColorScheme(.light)
        }
    }
}

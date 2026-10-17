import XCTest
@testable import GrowthApp

/// 「听一下这句」那个按钮。
///
/// ## 🔴 这条守的是一个**会自锁的形状**,不是某一次的 bug
///
/// 2026-08-31 用户实机:认人页上**一个播放入口都没有** —— 没有按钮,也没有
/// 那个「说出原因的灰喇叭」。而同一时刻投影层判定这个候选**能听**
///(听不了的候选已经被 `PeopleProjection.pendingSpeakers` 滤掉了),
/// 同一件事两处答案相反。
///
/// 根因:`resolved` 的初值是 `nil`,而 `nil` 那一支渲染 `EmptyView()`。
/// **SwiftUI 里只产出 `EmptyView` 的视图不生成布局节点,挂在它上面的 `.task`
/// 就不会触发** ⇒ `resolved` 永远是 nil ⇒ 永远渲染 `EmptyView`。
/// 视图把自己锁死了,而且**锁得静默**:屏幕上「读不出来」与「这条本来就没音频」
/// 长得一模一样。
///
/// ⚠️ 讽刺的是这个文件顶上第一句就是「说出原因,不给一个灰掉的喇叭」,
/// 而 `nil` 那一支给的是**什么都不给** —— 比灰喇叭更糟:灰喇叭至少证明代码跑过。
/// 原注释写的「不占位、不闪,静默即可」,那个「静默」正是病灶。
///
/// ## 为什么是源码断言
///
/// 这是 SwiftUI 的视图生命周期,单测打不到(要真起一个渲染树);走查台又要一份
/// 灌好音频的真库。而**这个错法只有一个形状**:让加载态渲染成空。
/// ⇒ 直接钉住那个形状。这条红了不代表 `EmptyView` 本身有罪,
/// 代表**有人又把「还没加载出来」画成了空**,而那正是它自锁的入口。
final class SampleAudioButtonTests: XCTestCase {

    /// 🔴 加载态**必须是一个真的视图**。
    func testLoadingStateIsNeverRenderedAsEmptyView() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // GrowthAppTests
            .deletingLastPathComponent()      // ios
            .appendingPathComponent("GrowthApp/Presentation/SampleAudioButton.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(src.isEmpty, "源码没读到,这条断言是空转的")

        // 注释里可以提它(上面那段解释就提了),代码里不许有。
        let code = src.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("EmptyView"), """
            `SampleAudioButton` 又把某个状态画成了 `EmptyView`。
            SwiftUI 不会给它布局节点 ⇒ `.task` 不触发 ⇒ 状态永远停在初值 ⇒ 永远是空。
            现场表现是「认人页没有播放入口」,与「这条录音没有音频」分不出来。
            要占位就给一个真的视图(现在是「读取音频…」)。
            """)
    }

    /// 三种状态都要**看得见**:能听给按钮,不能听给原因,还没读出来给「读取中」。
    /// 少一种就有一种情况在屏幕上是空白,而空白没有信息。
    func testEveryStateRendersSomethingVisible() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GrowthApp/Presentation/SampleAudioButton.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        for needle in ["听一下这句", "why.reason", "读取音频"] {
            XCTAssertTrue(src.contains(needle),
                          "少了「\(needle)」那一支 —— 有一种状态在屏幕上会是空白")
        }
    }

    /// 每一种「放不了」都说得出口。少一条就会有一种情况静默。
    func testEveryUnavailableReasonHasWords() {
        for why in [LineAudio.Unavailable.noBlockSeq, .fileMissing, .noSuchLine,
                    .noSampleLine, .lookupFailed] {
            XCTAssertFalse(why.reason.isEmpty, "\(why) 没有给用户的说法")
        }
    }
}

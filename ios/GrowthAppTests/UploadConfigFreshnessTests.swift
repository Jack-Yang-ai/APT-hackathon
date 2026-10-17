import XCTest
import GRDB
@testable import GrowthApp

/// 上传腿的配置**在用的时候读**,不吃启动时的快照(M1-13c)。
///
/// 🔴 **这条测试守的是一个命中「第一次用这个 App」的缺陷**:
/// `BackgroundUploadCenter` 原来把 config 缓存在一个只在 `didFinishLaunching`
/// 赋值一次的属性里,配套的 `updateConfig(_:)` **全仓没有调用方**。于是标准流程
/// 「启动(还没配)→ 去设置页填地址与令牌 → 探活显示通了」之后,上传腿在这个进程的
/// 剩余生命周期里**一直是没配**,只会烧 attempts 直到 dead —— 而 dead 没有复活路径。
/// 用户看到的是「我明明配好了,它却一直失败」,**杀掉重开才会好**。
///
/// ## 为什么这么测
///
/// `handOff` 头两道 guard 的顺序是「先看配置,再看文件在不在」。所以**拿一个不存在的
/// 文件**去调它,两种配置状态给出两种可区分的错误,而且**一行网络都不会走**:
/// · 没配 ⇒ `Failure.notConfigured`
/// · 配了 ⇒ 越过配置这道闸,倒在文件那道上(`PermanentUploadFailure`)
///
/// ⚠️ 有人把缓存加回去的话,这个 suite 里 `start()` 从没带过配置 ⇒
/// 「配了」那一半会退回 `notConfigured`,**当场红**。这正是它要挡的。
final class UploadConfigFreshnessTests: XCTestCase {

    /// 单例上动过的东西跑完要还回去,否则会污染同进程里别的 suite。
    override func tearDownWithError() throws {
        BackgroundUploadCenter.shared.configProvider = { ProxySettings.config }
    }

    /// 不存在的文件。用它把 `handOff` 停在头两道 guard 上。
    private var missingFile: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("m1-13c-不存在的块.m4a")
    }

    // MARK: - 没配

    func testHandOffRejectsWhenProxyNotConfigured() {
        BackgroundUploadCenter.shared.configProvider = { nil }

        XCTAssertThrowsError(
            try BackgroundUploadCenter.shared.handOff(
                fileURL: missingFile, to: "inbox/x.wav", tag: "t1",
                trigger: .foreground)
        ) { error in
            guard case BackgroundUploadCenter.Failure.notConfigured = error else {
                return XCTFail("没配的时候该说「没配」,实际抛的是:\(error)")
            }
        }
    }

    /// **只有地址没有令牌也算没配。** 这一条打的是 `ProxySettings.config` 自己的口径
    /// (它要求两样齐了才返回值),所以这里**不走注入的缝**,直接验那个真实现 ——
    /// 缺令牌会被云代理 401,而 401 看起来像「服务坏了」,实际是「你还没填」。
    ///
    /// ⚠️ 只读不写,所以不碰 Keychain:`token` 在测试环境里本来就读不出来,
    /// 而这一条要断言的正是「读不出令牌 ⇒ config 为 nil」。
    func testHalfConfiguredCountsAsNotConfigured() {
        let saved = ProxySettings.baseURL
        defer { ProxySettings.baseURL = saved }
        ProxySettings.baseURL = URL(string: "https://api.example.com")

        XCTAssertNil(ProxySettings.config,
                     "只有地址没有令牌时 config 必须是 nil —— 缺一样都不能发请求")
    }

    // MARK: - 🔴 配完不用重启

    /// **本文件的理由就是这一条。**
    ///
    /// `start()` 从头到尾没带过任何配置(与生产一致:`AppDelegate` 启动时
    /// 也不再传)。配置是在这里、`handOff` 之前才写进 `ProxySettings` 的 ——
    /// 也就是「App 已经起来了,用户才去设置页填」的那个真实时序。
    /// 它必须能越过配置这道闸。
    func testConfigSetAfterStartTakesEffectWithoutRestart() throws {
        // 模拟 didFinishLaunching:此刻还没配。
        var current: ProxyClient.Config?
        BackgroundUploadCenter.shared.configProvider = { current }

        let db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        BackgroundUploadCenter.shared.start(writer: db)

        // 用户这才去设置页填上 —— App 已经起来了,没有重启。
        current = ProxyClient.Config(baseURL: URL(string: "https://api.example.com")!,
                                     token: "tok-m1-13c")

        XCTAssertThrowsError(
            try BackgroundUploadCenter.shared.handOff(
                fileURL: missingFile, to: "inbox/x.wav", tag: "t3",
                trigger: .foreground)
        ) { error in
            if case BackgroundUploadCenter.Failure.notConfigured = error {
                return XCTFail("配完还说没配 —— 上传腿又在吃启动时的快照了(M1-13c 回归)")
            }
            // 越过了配置那道闸,倒在「文件不在」上 —— 正是期望。
            XCTAssertTrue(error is PermanentUploadFailure,
                          "该倒在文件那道 guard 上,实际抛的是:\(error)")
        }
    }
}

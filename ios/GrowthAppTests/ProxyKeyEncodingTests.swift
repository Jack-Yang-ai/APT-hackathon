import XCTest
@testable import GrowthApp

/// 云代理 `?key=` 的编码(2026-08-25 实测的那个 400)。
///
/// 🔴 **`+` 是 query 里的合法字符,`URLQueryItem` 不会编码它** ——
/// 而服务端 `URLSearchParams` 按表单编码解,把 `+` 解成**空格**。
/// 快照的 key 里正好有一个 `+`(ISO 时间的时区偏移 `+08:00`),于是每一拍都 400。
///
/// ⚠️ 后果不是「少一个备份」:`M2-认8` 之后快照是 **Mac 判决的输入** ——
/// 推不上去 = Mac 一直拿着旧底库判人,而**两端都不报错**。
final class ProxyKeyEncodingTests: XCTestCase {

    /// 复刻 `ProxyClient.putObject` 里那段编码,断言 `+` 被编成 `%2B`。
    ///
    /// ⚠️ 这条**不是**把实现抄一遍当测试 —— 它钉的是 `urlQueryAllowed` 这个
    /// 系统字符集**放行 `+`** 这件事。哪天 Foundation 改了它,这条会红,
    /// 而那正是需要有人重新想一遍的时刻。
    func testTheQueryAllowedSetLetsPlusThroughSoWeMustRemoveIt() {
        let key = "snapshots/voiceprints/2026-08-25T16-37-00+08-00.json"

        // 前提:系统那套字符集确实放行 `+`(所以 `URLQueryItem` 会原样发出去)
        let naive = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        XCTAssertEqual(naive, key, "`urlQueryAllowed` 不再放行 `+` 了?那这条修复的前提变了")

        // 修法:把 `+` 从放行集里剔掉
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        let escaped = key.addingPercentEncoding(withAllowedCharacters: allowed)
        XCTAssertEqual(escaped, "snapshots/voiceprints/2026-08-25T16-37-00%2B08-00.json")
        XCTAssertFalse(escaped?.contains("+") ?? true, "还有裸加号 —— 服务端会把它读成空格")
    }

    /// 快照的 key **确实**会带一个 `+` —— 否则上面那条测的是个不存在的问题。
    func testASnapshotKeyReallyContainsAPlus() {
        let key = RegistrySnapshotIO.key(takenAt: "2026-08-25T16:37:00+08:00")
        XCTAssertTrue(key.contains("+"),
                      "快照 key 里没有加号了(\(key))—— 那这组测试的前提没了,回来重想")
        XCTAssertFalse(key.contains(":"), "冒号该被换掉,本地目录里用不了")
    }
}

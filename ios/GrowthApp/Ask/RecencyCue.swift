import Foundation

/// 这句问的是**近况**还是**属性**。`M2-检2` §1.1 的判据那一半。
///
/// ## ⚠️ 今天它没有消费方,这是有意的
///
/// 它要服务的是 **L2 的相关度排序**(检索方案 §四 ②定位):只有在「按相关度排」
/// 存在时,「要不要向新的倾斜」才是一个问题。L1 本来就按时间倒序,不需要这个判断。
/// 消费点写在 `docs/intents/M2-检2/plan.md` 批 B —— 那一批施工时直接拿这个函数,
/// 不必到时候再补词表和测试。
///
/// 🔴 **仓里有一条相反的教训**(`docs/方案-词库与候选挖掘.md` §1.2):
/// 「写进去的东西没人读,正是『成功地写进了错的地方』」。
/// 这里之所以仍然先建,是因为它是**纯函数 + 数据文件**,不写库、不接线、不产生
/// 任何可以「落在错的地方」的东西 —— 那条教训针对的是**往库里写**。
/// 若批 B 最终不做,删掉这两个文件即可,不留残迹。
///
/// ## 为什么要分这一刀
///
/// VoiceMem 实测:对**所有**查询按时间加权时,「我在哪读书」的正确答案
/// (半年前记下的,相似度全场最高 0.810)乘上 0.752 之后掉到 0.609,
/// 被一条 0.773 的无关记忆挤到第六。**长期属性的答案天然是旧的** ——
/// 专业、过敏、老家、性格都没有更新的版本,罚旧等于罚对。
enum RecencyCue {

    /// 词表读不出来的次数。同 `RelativeDates.lexiconLoadFailures`:
    /// 增强件挂了不阻塞主线,但**必须留下计数**(仓规 6)。
    private(set) nonisolated(unsafe) static var lexiconLoadFailures = 0

    private nonisolated(unsafe) static var cache: [String: [String]] = [:]

    /// 词表。读一次,之后复用。
    static func cues(bundle: Bundle = .main) -> [String] {
        if let cached = cache[bundle.bundlePath] { return cached }
        let loaded = load(bundle: bundle)
        cache[bundle.bundlePath] = loaded
        return loaded
    }

    private static func load(bundle: Bundle) -> [String] {
        guard let url = bundle.url(forResource: "recency_cues", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cues = root["cues"] as? [String], !cues.isEmpty
        else {
            lexiconLoadFailures += 1
            return []
        }
        return cues
    }

    /// → 这句问的是近况吗。词表为空时恒 false(**不是崩**,见类型注释)。
    ///
    /// 大小写不敏感:英文那几条在 ASR 转写与用户打字里大小写都不稳定。
    static func wantsRecency(_ question: String, bundle: Bundle = .main) -> Bool {
        let lowered = question.lowercased()
        return cues(bundle: bundle).contains { lowered.contains($0.lowercased()) }
    }
}

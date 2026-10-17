import Foundation

/// 几乎重复的行,折成一条。
///
/// ## 为什么全时录音必须做这个
///
/// 一天录 8 小时,同一件事会用几乎一样的话说很多遍。搜「交付时间」是这样:
///
///     14:08  交付时间要重排一下
///     14:15  交付时间得重排
///     14:22  这个交付时间要重排
///     …还有 27 条
///
/// **前三条有用,后面全是噪音** —— 而且它们把真正不一样的那条
/// (「交付时间**不用**改了」)挤到了屏幕外面。
///
/// 这件事在别的产品里可有可无,在全时录音里是刚需:重复率天然高。
///
/// ## 只在同一场次内折,跨场次不折 —— 这一条是产品语义,不是性能优化
///
/// 同一场会里说三遍,是啰嗦;**跨三场会都在说,是信号** ——
/// 「他第 3 次提到交付时间」正是 PRD §4.5.4 的「反复关切」类发现。
/// 跨场次折叠会把这个产品最想抓的东西亲手抹掉。
///
/// ## 折了要说,不能悄悄丢
///
/// 折叠是**丢弃信息**。悄悄丢的后果是用户以为「只有这一条」,
/// 而实际有五条 —— 而「说了几遍」本身就是他想知道的。
/// 所以每条命中带一个 `foldedCount`,界面照实说「还有 N 条几乎一样的」。
enum NearDuplicate {

    /// 重合度阈值。
    ///
    /// 这个数来自旧仓(`~/growth-agent` 的 `_too_similar`),而那边注明
    /// 「**同库有效,主库重测**」。搬过来当起点用,**重测过了**,见下面 `gramSize`。
    static let similarityThreshold = 0.55

    /// n-gram 的 n。**旧仓用 4,本仓用 2 —— 这是重测出来的,不是抄的。**
    ///
    /// 旧仓那个 4 是对**较长文本**(原子、摘要)用的。转写行是**短句**,
    /// 短句里改一个字会毁掉四个 4-gram,于是「该折的折不起来」:
    ///
    /// |  | 2 字组 | 3 字组 | 4 字组 |
    /// |---|---|---|---|
    /// | 「要重排」vs「**得**重排」 ← 该折 | **0.60** | 0.40 | **0.20** ✗ |
    /// | 加个前缀「这个…」 ← 该折 | 0.80 | 0.78 | 0.75 |
    /// | 「要重排」vs「**不用改了**」 ← **不该折** | 0.30 | 0.22 | 0.12 |
    ///
    /// 4 字组下,该折的只有 0.20、不该折的 0.12 —— **没有任何阈值能把两边分开**。
    /// 2 字组下该折 0.60/0.80、不该折 0.30/0.25,阈值 0.55 两边各留 0.25 的余量。
    ///
    /// 中文的词大多是两个字,所以短句上双字组才是自然单位。
    ///
    /// ⚠️ 误折比漏折严重得多:把「要改」和「不用改」当成同一句,
    /// **是把反义句吃掉**。所以调这个数时先看不该折那两行有没有被顶上来。
    static let gramSize = 2

    /// → 相似度 0…1(Jaccard:交集 / 并集)。
    static func similarity(_ a: String, _ b: String) -> Double {
        let ga = grams(a), gb = grams(b)
        guard !ga.isEmpty, !gb.isEmpty else { return a == b ? 1 : 0 }
        let inter = ga.intersection(gb).count
        let union = ga.union(gb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    static func grams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= gramSize else { return chars.isEmpty ? [] : [String(chars)] }
        return Set((0...(chars.count - gramSize)).map { String(chars[$0..<($0 + gramSize)]) })
    }

    /// 把 `items` 里几乎重复的折起来。**保留先出现的那一条** ——
    /// 调用方按时间倒序传进来,于是留下的是**最近一次**说的,
    /// 而「最近一次是什么时候说的」正是这个产品最常见的问法。
    ///
    /// - Parameters:
    ///   - key: 取分组键(场次 id)。只在同一组内折。
    ///   - text: 取要比对的文本。
    /// - Returns: 折叠后的元素,与各自被折掉的条数。
    static func fold<T>(_ items: [T],
                        key: (T) -> Int64,
                        text: (T) -> String) -> [(item: T, folded: Int)] {
        var kept: [(item: T, folded: Int)] = []
        // 每组留一份「已保留文本」的索引,避免每次都跟全表比。
        var keptTextsByKey: [Int64: [(index: Int, grams: Set<String>)]] = [:]

        for item in items {
            let k = key(item)
            let g = grams(text(item))
            var mergedInto: Int?
            for entry in keptTextsByKey[k] ?? [] {
                let inter = g.intersection(entry.grams).count
                let union = g.union(entry.grams).count
                let sim = union == 0 ? 0 : Double(inter) / Double(union)
                if sim >= similarityThreshold { mergedInto = entry.index; break }
            }
            if let i = mergedInto {
                kept[i].folded += 1
            } else {
                kept.append((item, 0))
                keptTextsByKey[k, default: []].append((kept.count - 1, g))
            }
        }
        return kept
    }
}

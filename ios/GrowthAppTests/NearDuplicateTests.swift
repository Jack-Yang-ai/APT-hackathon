import XCTest
@testable import GrowthApp

/// 近重复折叠(`dc8a761`)+ 与 Python 那份实现的跨语言一致(`M2-检2` §1.4)。
///
/// 行级去重跑在这里(Swift),条目级去重跑在 Mac 上(`shared/near_duplicate.py`)。
/// **两份实现一个算法**,而这个仓最贵的事故形状正是「一件事两个出处,只有一份被维护」。
/// 两边各自对着 `shared/fixtures/recall/near_dup_vectors.json` 断言,谁漂了谁红。
final class NearDuplicateTests: XCTestCase {

    private struct Pair: Decodable {
        let why: String
        let a: String
        let b: String
        let gram2: Double
        let gram3: Double
    }

    private func fixturePairs() throws -> [Pair] {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "near_dup_vectors", withExtension: "json"),
            "near_dup_vectors.json 没进测试 target(project.yml 里补一行)")
        struct Root: Decodable { let pairs: [Pair] }
        return try JSONDecoder().decode(Root.self, from: Data(contentsOf: url)).pairs
    }

    /// 两个 n 值都比 —— 只比生产在用的那个(2)的话,换 n 时两边会各自漂到不同的地方。
    private func similarity(_ a: String, _ b: String, gramSize: Int) -> Double {
        let ga = grams(a, gramSize), gb = grams(b, gramSize)
        guard !ga.isEmpty, !gb.isEmpty else { return a == b ? 1 : 0 }
        let union = ga.union(gb).count
        return union == 0 ? 0 : Double(ga.intersection(gb).count) / Double(union)
    }

    private func grams(_ s: String, _ n: Int) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= n else { return chars.isEmpty ? [] : [String(chars)] }
        return Set((0...(chars.count - n)).map { String(chars[$0..<($0 + n)]) })
    }

    // MARK: - 跨语言夹具

    /// 🔴 谁改了算法而没改另一边,这条红。
    func testEveryFixturePairMatchesThisImplementation() throws {
        let pairs = try fixturePairs()
        XCTAssertGreaterThanOrEqual(pairs.count, 10, "夹具被删过?")
        for p in pairs {
            XCTAssertEqual(similarity(p.a, p.b, gramSize: 2), p.gram2, accuracy: 1e-12,
                           "2 字组对不上:\(p.a) / \(p.b)(\(p.why))")
            XCTAssertEqual(similarity(p.a, p.b, gramSize: 3), p.gram3, accuracy: 1e-12,
                           "3 字组对不上:\(p.a) / \(p.b)(\(p.why))")
        }
    }

    /// 生产用的那条路(`NearDuplicate.similarity`)必须与夹具一致 ——
    /// 上面那个 `similarity` 是测试自己写的参照实现,两者都对得上才说明没漂。
    func testTheShippedSimilarityAgreesWithTheFixtureAtTheProductionGramSize() throws {
        XCTAssertEqual(NearDuplicate.gramSize, 2, "生产 n 变了 —— 夹具那一列要跟着换")
        for p in try fixturePairs() {
            XCTAssertEqual(NearDuplicate.similarity(p.a, p.b), p.gram2, accuracy: 1e-12,
                           "\(p.a) / \(p.b)(\(p.why))")
        }
    }

    // MARK: - 行为

    private func fold(_ texts: [String], keys: [Int64]? = nil) -> [(item: (Int64, String), folded: Int)] {
        let items = zip(keys ?? Array(repeating: 1, count: texts.count), texts).map { ($0, $1) }
        return NearDuplicate.fold(items, key: { $0.0 }, text: { $0.1 })
    }

    /// 保留先出现的那一条:调用方按时间倒序传进来,留下的就是**最近一次**说的。
    func testFoldingKeepsTheFirstOccurrenceAndCountsTheRest() {
        let kept = fold(["今天感到很累,可能与明天下午的会议有关",
                         "最近感到很累,可能与明天下午的会议有关"])
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].item.1.hasPrefix("今天"), "留下的不是先出现的那条")
        XCTAssertEqual(kept[0].folded, 1)
    }

    /// 🔴 只在同一场次内折。**跨三场都在说是信号,不是噪音** ——
    /// 「他第 3 次提到交付时间」正是 PRD §4.5.4 的「反复关切」,跨场折叠会把它亲手抹掉。
    func testFoldingNeverCrossesSessions() {
        let same = "今天感到很累,可能与明天下午的会议有关"
        let kept = fold([same, same], keys: [1, 2])
        XCTAssertEqual(kept.count, 2, "跨场次被折了")
        XCTAssertTrue(kept.allSatisfy { $0.folded == 0 })
    }

    /// 短反义句不许折。**误折比漏折严重得多** —— 把「要改」和「不用改」折成一条
    /// 是把答案吃掉,而界面上看不出来。
    func testShortOppositeSentencesAreNotFolded() {
        for (a, b) in [("交付时间要重排一下", "交付时间不用改了"),
                       ("老周同意了", "老周不同意"),
                       ("下周三交付", "下周三不交付")] {
            XCTAssertLessThan(NearDuplicate.similarity(a, b), NearDuplicate.similarityThreshold,
                              "\(a) / \(b)")
        }
    }

    /// 🔴 **已知缺陷,登记在 `TASKS.md` `M2-检3`**:共享前缀越长,一个「不」字被
    /// 稀释得越厉害,于是意思相反的两句会被折成一条。
    ///
    /// 这条钉的是**现状,不是应该**。修法要等 §1.4 的标注数据 ——
    /// 现在凭感觉调阈值正是仓规「金标治理 > 机制调参」说的那个错。
    /// **修好之后这条会红**,那时把它并进上面那条。
    func testANegationBuriedInALongSharedPrefixIsAKnownHole() {
        for (a, b) in [("这个方案可以", "这个方案不可以"),
                       ("首页结构先收敛,再补推荐逻辑", "首页结构先收敛,不补推荐逻辑")] {
            XCTAssertGreaterThanOrEqual(
                NearDuplicate.similarity(a, b), NearDuplicate.similarityThreshold,
                "\(a) / \(b) 现在不折了 —— 缺陷修好了?把这条并进 testShortOppositeSentencesAreNotFolded")
        }
    }
}

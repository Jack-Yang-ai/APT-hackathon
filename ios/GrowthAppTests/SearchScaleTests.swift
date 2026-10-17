import XCTest
import GRDB
@testable import GrowthApp

/// U-检索1:三个月语料量下的检索延迟实测([docs/技术方案-检索.md](../../docs/技术方案-检索.md) §6.3)。
///
/// ## 为什么现在做
///
/// PRD 把「3 个月语料量下延迟仍达标」写成 M2 的验收点。但**M1 末就该知道答案** ——
/// 如果 trigram 在这个量级上过不了 100ms,整个 L1 的技术选型要重来,**越晚发现越贵**。
///
/// ## 怎么跑
///
///     xcodebuild test -scheme GrowthAppScale -destination 'id=<真机 UDID>' …
///
/// 它要造 22.5 万行、真机上要几分钟,所以默认那个 `GrowthApp` scheme 把它
/// `skippedTests` 掉了,另开了 `GrowthAppScale` 专门跑它(见 `project.yml`)。
///
/// 🔴 **别用 `-only-testing:` 去点名它** —— `skippedTests` **盖得过 `-only-testing:`**,
/// 2026-08-18 实测得到的是 `** TEST SUCCEEDED **` 配 `Executed 0 tests`:
/// 一条没跑,退出码 0,终端上全是绿的。
///
/// ⚠️ 也不用环境变量做开关:`GROWTH_PERF=1 xcodebuild …` 与 `TEST_RUNNER_` 前缀
/// **都传不进单元测试进程**(后者只对 UI 测试有效)。试过两次,是死路。
///
/// ## 为什么应该在真机上跑
///
/// 指标是「**手机上** <100ms」。模拟器跑在 Mac 的 CPU 与 SSD 上,数字系统性偏乐观 ——
/// 拿它当结论就是在为一台不存在的设备优化。
final class SearchScaleTests: XCTestCase {

    /// 全时录音一天约 8 小时,人声约 60%,按 3 字/秒 ≈ **5 万字/天**;三个月 ≈ **450 万字**。
    private let targetChars = 4_500_000
    /// 一行的目标长度,贴近真实口语的短句。
    private let charsPerLine = 20
    /// **三个月 = 90 天 = 90 场。** 全时录音一天收一场,这个数不是估的。
    /// 它直接决定折叠的分组数,见灌库那段的说明。
    private let sessionCount = 90

    private var dir: URL!
    private var dbURL: URL { dir.appendingPathComponent("scale.sqlite") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if dir != nil { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - 造语料

    // MARK: - 语料的两层词汇,以及它为什么必须分两层
    //
    // 🔴 **2026-08-18:上一版语料只有 24 个词组,把命中行数放大了约 20 倍。**
    //
    // 不用随机汉字是对的(随机字让每个 trigram 几乎唯一,倒排表短得不真实,
    // 数字会偏好看)。但只用 24 个词组是掉进了**另一头**:每行约 3.1 个词组,
    // 任一词组因此出现在 **13.1%** 的行里 —— 而这正好是本条的成本主项,
    // 因为病灶是 `USE TEMP B-TREE FOR ORDER BY`(**排序所有命中行**,LIMIT 停不了工)。
    //
    // 拿真实数据标定过了(`~/growth-agent` 的 `episode_quotes`,**4157 条真实原话**,
    // 平均 28.4 字。⚠️ 只在 Mac 上量,数字抄进这里,**原话不进版本库**):
    //
    // | | 真实语料 | 折算到 22.5 万行 |
    // |---|---|---|
    // | 口水词「这个 / 就是 / 我们」 | 19.7% / 16.1% / 15.7% | ~4.4 万行 |
    // | **用户真会搜的词**(用户 3.42% · 产品 5.58% · 模型 2.50% · 场景 1.64% · 成本 0.77% · 交付 0.29% · 飞轮 0.12%) | **中位数 0.67%** | **~1,515 行** |
    // | ~~上一版夹具的词组~~ | ~~13.1%~~ | ~~29,475 行~~ |
    //
    // ⇒ 分两层:**口水词高频、内容词低频,而查询打的是内容词** —— 这才是真实形态。
    // 用户不会搜「这个」,他搜的是人名、项目、概念。

    /// 口水词。对应真实语料里的「这个 19.7%」「就是 16.1%」「我们 15.7%」,
    /// 它们撑起 trigram 倒排表的长尾,**不参与查询**。
    private let fillers = [
        "他说", "要重排一下", "这个事情", "我们先看", "别急着", "下周三之前",
        "得给下游一个说法", "的意思是", "先把", "新人上手要三周", "保证不了",
        "什么时候给", "我这边没问题", "那就这么定了", "回头再确认一次",
        "这个前提还没验证", "能不能批", "到底是什么", "先算一下",
        "这个月已经花了", "明天早上再说", "我记一下",
    ]

    /// 内容词(二字)。**30 个** —— 每行放一个,任一个的命中率 1/30 ≈ **3.3%**,
    /// 对齐真实语料里「用户 3.42%」「产品 5.58%」那一档(用户搜得最多的那类词)。
    private let nouns = [
        "用户", "产品", "成本", "数据", "模型", "声纹", "录音", "记忆", "检索", "交付",
        "预算", "招聘", "定位", "飞轮", "场景", "隐私", "架构", "评测", "排期", "范围",
        "质量", "壁垒", "节奏", "清单", "口径", "闸门", "语料", "归属", "证据", "余量",
    ]
    /// 内容词的后半截。`nouns × verbs` = **300 个四字词组**,
    /// 任一个的命中率 1/300 ≈ **0.33%**,对齐真实的「交付 0.29%」「飞轮 0.12%」那一档。
    private let verbs = [
        "重排", "砍掉", "验证", "批复", "对齐", "回填", "作废", "收敛", "拆开", "锁死",
    ]

    /// 定死种子的伪随机 —— 换机器、重跑,语料一模一样,数字才可比。
    private struct Seeded {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
    }

    /// 一行 = **恰好一个四字内容词** + 口水词垫到目标长度。
    /// 内容词只放一个,是为了让「任一四字词组的命中率 = 1/300」这个标定成立。
    private func makeLine(_ rng: inout Seeded) -> String {
        var s = nouns[rng.next(nouns.count)] + verbs[rng.next(verbs.count)]
        while s.count < charsPerLine {
            s += fillers[rng.next(fillers.count)]
        }
        return s
    }

    // MARK: - 实测

    func testPhraseQueryLatencyAtThreeMonthsOfCorpus() throws {
        let db = try AppDatabase.open(at: dbURL)
        let lineCount = targetChars / charsPerLine

        // ── 灌库 ──────────────────────────────────────────────
        var rng = Seeded(state: 20_260_813)
        let buildStart = CFAbsoluteTimeGetCurrent()

        // 🔴 **分批提交,不是一个大事务。**
        //
        // 上一版把 22.5 万行灌在**一个** `db.write { }` 里。模拟器跑在 Mac 上,
        // 内存管够;**真机上被系统直接杀掉** —— 表现是「测试进程启动后立刻没了」,
        // 而 xcodebuild 报的是 `Restarting after unexpected exit`。
        //
        // ⚠️ **2026-08-13 板上把它判成了「设备状态(多半锁屏),与本次代码无关」** ——
        // 前半句碰巧沾边(锁屏确实会让 xcodebuild 卡住),但**后半句是错的**,
        // 而当时没做对照就下了结论。2026-08-18 补了对照:同一台手机、同一次连接,
        // `SpeechGateTests` 5 条**跑得好好的**(`Executed 5 tests`),
        // 所以崩的原因在这条测试自己 —— 就是下面这个大事务。
        //
        // 🔴 **改的是夹具,不是指标。** 分批之后落进库的行、文本、索引内容
        // 都由同一个种子决定,**一模一样**;验收量的是查询延迟与索引体积,
        // 不是灌库耗时。**没有放宽任何一条判据。**
        //
        // ── 第二处夹具修正:三个月是 90 天 90 场,不是一场 ──────────
        //
        // 🔴 上一版把 450 万字全挂在**一条 session** 上。那不是「保守估计」,
        // 是**任何用户都到不了的状态** —— 全时录音一天收一场,三个月就是 90 场。
        //
        // 它为什么要命:`TranscriptSearch` 取回 200 行之后要折几乎重复的,
        // 而折叠**只在同一场次内比**(`NearDuplicate.fold(key: \.sessionID)`)。
        // 全挂一场 = 200 行全在一个组里两两比;90 场 = 每组两三行,比一比就完。
        // 2026-08-18 真机实测这两种布局差 **116.8 ms vs 4.1 ms** —— 而当时
        // 长句 P95 一共才 150.9 ms。**夹具自己贡献了七成的耗时。**
        //
        // ⚠️ 这不是把指标放松。判据仍是「三个月语料下 P95 <100ms」,变的是
        // 「三个月语料」这四个字指的东西 —— 从一个不存在的状态,改成真实的那个。
        // 单场很长的最坏情况没有被扫到地毯下面:它由下面那条折叠诊断专门量着。
        let batch = 5_000
        let linesPerSession = lineCount / sessionCount

        // 90 场:一天一场,起始时间逐日递增(检索按 started_at 倒序,顺序要真)。
        let tids: [Int64] = try db.write { d in
            var out: [Int64] = []
            for n in 0..<sessionCount {
                let day = String(format: "2026-%02d-%02d", 3 + n / 30, 1 + n % 30)
                try d.execute(sql: """
                    INSERT INTO sessions (started_at, day, source, status)
                    VALUES (?, ?, 'recording', 'closed')
                    """, arguments: ["\(day)T09:00:00+08:00", day])
                let sid = d.lastInsertedRowID
                try d.execute(sql: """
                    INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at, frozen_at)
                    VALUES (?, 1, 1, 'perf', 'frozen', ?, ?)
                    """, arguments: [sid, "\(day)T18:00:00+08:00", "\(day)T18:00:00+08:00"])
                let tid = d.lastInsertedRowID
                try d.execute(sql: "UPDATE sessions SET active_transcript_id = ? WHERE id = ?",
                              arguments: [tid, sid])
                out.append(tid)
            }
            return out
        }

        // 行分批灌:每批一个事务,提交之后内存就放掉了。
        var seq = 0
        while seq < lineCount {
            let upper = min(seq + batch, lineCount)
            try autoreleasepool {
                try db.write { d in
                    for i in seq..<upper {
                        let text = makeLine(&rng)
                        // 场内序号与场内时间轴 —— 挂到第 i / linesPerSession 场上
                        let inSession = i % linesPerSession
                        try d.execute(sql: """
                            INSERT INTO transcript_lines
                              (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                            VALUES (?, ?, ?, ?, ?, 0, 0)
                            """, arguments: [tids[min(i / linesPerSession, sessionCount - 1)],
                                             inSession, inSession * 4000, inSession * 4000 + 3500,
                                             text])
                        try WordIndex.index(lineID: d.lastInsertedRowID, text: text,
                                            isGap: false, in: d)
                    }
                }
            }
            seq = upper
        }
        let buildSeconds = CFAbsoluteTimeGetCurrent() - buildStart

        // ── 量体积 ────────────────────────────────────────────
        let bytes = try FileManager.default
            .attributesOfItem(atPath: dbURL.path)[.size] as? Int ?? 0
        let mb = Double(bytes) / 1_048_576

        // ── 量延迟 ────────────────────────────────────────────
        // 三类查询分开量:它们走的腿不一样,慢在哪要能分辨。
        //
        // 🔴 **查询打的是内容词,不是口水词** —— 用户搜的是人名、项目、概念,
        // 没有人搜「这个」。上一版的查询词正好是高频词组,那是把最坏情况当常态量。
        let cases: [(String, [String])] = [
            // 命中率 1/30 ≈ 3.3%,对齐真实的「用户 3.42% / 产品 5.58%」
            ("两字 · 只走词索引", ["用户", "成本", "声纹", "排期", "范围"]),
            // 命中率 1/300 ≈ 0.33%,对齐真实的「交付 0.29% / 飞轮 0.12%」
            ("四字 · 两条腿都走", ["用户重排", "成本对齐", "声纹收敛", "记忆作废", "语料回填"]),
            // 更长 ⇒ 更罕见,真实里长短语本来就少见
            ("长句 · 两条腿都走", ["用户重排他说", "成本对齐这个事情", "声纹收敛先把",
                                  "检索验证我记一下", "归属锁死明天早上再说"]),
        ]

        var report = ["", "════ U-检索1 实测 ════",
                      "语料 \(lineCount) 行 / 约 \(targetChars / 10_000) 万字 / \(sessionCount) 场",
                      String(format: "灌库 %.1f 秒 · 库文件 %.1f MB(约为原文的 %.1f 倍)",
                             buildSeconds, mb, mb * 1_048_576 / Double(targetChars * 3))]

        /// 量一轮,返回最差的一档 P95。
        func measure(_ tag: String) throws -> Double {
            var worst = 0.0
            report.append("── \(tag) ──")
            for (label, queries) in cases {
                var samples: [Double] = []
                for _ in 0..<10 {
                    for q in queries {
                        let t0 = CFAbsoluteTimeGetCurrent()
                        _ = try db.read { try TranscriptSearch.search(q, limit: 50, in: $0) }
                        samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    }
                }
                samples.sort()
                let p50 = samples[samples.count / 2]
                let p95 = samples[Int(Double(samples.count) * 0.95)]
                worst = max(worst, p95)
                report.append(String(format: "%@  P50 %6.1f ms · P95 %6.1f ms · 最慢 %6.1f ms",
                                     label, p50, p95, samples.last!))
            }
            return worst
        }

        _ = try measure("第一轮(含冷启动)")
        // 第二轮:缓存已热。**判据取它** —— 冷启动那一次单独看(§6.3 已记),
        // 拿它混进 P95 会让「日常搜索快不快」和「第一次搜索慢不慢」两件事分不开。
        let worstP95 = try measure("第二轮(热)")

        // ── 诊断零:搜口水词(最坏情况) ─────────────────────────
        //
        // 🔴 **判据打在真实查询上,但最坏情况不许消失。**
        //
        // 判据用内容词是有依据的(真实语料标定,见上面词汇那两层的说明):
        // 用户搜的是人名、项目、概念,没有人搜「这个」。
        // 但「没有人搜」不等于「搜不出来」—— 真搜了就是这个数,它必须留在报告里,
        // 否则「按真实查询标定」就变成了把坏消息扫到地毯下面。
        var worstCase: [Double] = []
        for q in ["这个事情", "我记一下", "明天早上再说"] {
            for _ in 0..<10 {
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = try db.read { try TranscriptSearch.search(q, limit: 50, in: $0) }
                worstCase.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
        }
        worstCase.sort()
        report.append(String(format: "口水词(最坏情况,判据不打它)  P50 %6.1f ms · P95 %6.1f ms",
                             worstCase[worstCase.count / 2],
                             worstCase[Int(Double(worstCase.count) * 0.95)]))

        // ── 诊断:碎片占多少 ───────────────────────────────────
        //
        // 🔴 **这一段是诊断,不是判据。** 断言仍然打在上面那个 `worstP95` 上。
        //
        // 为什么要量它:分批提交会让词索引的 b-tree 碎片化,而**生产里的数据本来
        // 就是三个月里一笔笔写进去的** —— 所以碎片是真实状态,不是夹具的毛病。
        // (2026-08-13 那次「一个大事务灌完」得到的 19.6/39.3/53.8ms 才是失真的那个:
        //  索引一次性顺序建好,现实中不会有这种库。那组数**据此作废**。)
        //
        // 如果 VACUUM 之后数字掉回去,说明瓶颈是碎片而不是 trigram 选型,
        // 那么出路是**加一条维护动作**(定期 VACUUM / `PRAGMA optimize`),
        // 而不是重做 L1。两者的代价差着数量级,所以这一次量值得跑。
        try db.writeWithoutTransaction { try $0.execute(sql: "VACUUM") }
        let vacuumedMB = Double(
            (try FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int) ?? 0
        ) / 1_048_576
        let afterVacuum = try measure(String(format: "VACUUM 之后(诊断,库 %.1f MB)", vacuumedMB))
        report.append(String(format: "碎片这一项值 %.1f ms(%.0f%%)",
                             worstP95 - afterVacuum,
                             (worstP95 - afterVacuum) / worstP95 * 100))

        // ── 诊断二:折叠这一项值多少,以及夹具在这里失真多少 ──────────
        //
        // 🔴 同样是诊断,不是判据。
        //
        // 每次查询实际取回 `limit × overFetchFactor` = 200 行再折
        // (`TranscriptSearch.overFetchFactor`),折叠是**每条跟同组已保留的比**,
        // 所以成本由**组内保留数**决定,而组 = 场次。
        //
        // ⚠️ **这个夹具把三个月塞进了一个场次** —— 灌库那段只建了 1 条 session。
        // 真实的三个月是 90+ 场,折叠的分组一散,两两比较也跟着散掉。
        // 所以这里量两次:1 组(夹具的样子)与 90 组(真实的样子),差值就是**夹具的失真**。
        var probe = Seeded(state: 99)
        let sample = (0..<(50 * TranscriptSearch.overFetchFactor)).map { _ in makeLine(&probe) }
        func timeFold(groups: Int) -> Double {
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<20 {
                _ = NearDuplicate.fold(Array(sample.enumerated()),
                                       key: { Int64($0.offset % groups) },
                                       text: { $0.element })
            }
            return (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 20
        }
        let fold1 = timeFold(groups: 1)
        let fold90 = timeFold(groups: 90)
        report.append(String(format: "折叠 %d 行(孤立跑,随机行):夹具(1 场)%.1f ms · 真实(90 场)%.1f ms",
                             sample.count, fold1, fold90))
        report.append("  ⚠️ 这是折叠的**上界**,不是它在真实查询里的份额 —— 见下面那条")

        // ── 诊断三:钱花在「找+排」还是「取回来的行数」上 ──────────
        //
        // 🔴 **先做这条,再谈优化。** 2026-08-18 我在同一天错判过两次:
        // 先怪索引碎片(VACUUM 对照否掉,值 2~5 ms),再怪折叠(90 场对照否掉 ——
        // 分组散开之后总时间没降)。两次都是**先归因再验证**,顺序反了。
        //
        // 这条用现成的公开口做减法,不重抄一遍 SQL(重抄就是第二个真相源):
        // `limit: 1` ⇒ 只取回 4 行(overFetch),`limit: 50` ⇒ 取回 200 行。
        // 两者**命中集合、排序、扫描完全一样**,差的只是取回行数与折叠量。
        //
        //   两者接近  ⇒ 钱花在「找 + 排」上(FTS5 命中太多、ORDER BY 要全排),
        //              出路是查询计划,不是折叠参数;
        //   差很多    ⇒ 钱花在取回与折叠上,那 overFetchFactor 才是能调的旋钮。
        // 扫一条曲线:`limit` × `overFetchFactor` = 真正取回的行数。
        // 有了它,「把 overFetchFactor 从 4 调到 N」的代价就是量出来的,不是推算的。
        report.append("── 取回行数 → P95(overFetchFactor 的取舍曲线) ──")
        for (label, queries) in cases {
            var line = "\(label)  "
            for lim in [1, 12, 25, 50] {
                var samples: [Double] = []
                for _ in 0..<10 {
                    for q in queries {
                        let t0 = CFAbsoluteTimeGetCurrent()
                        _ = try db.read { try TranscriptSearch.search(q, limit: lim, in: $0) }
                        samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    }
                }
                samples.sort()
                line += String(format: "%d行 %6.1f · ",
                               min(lim * TranscriptSearch.overFetchFactor,
                                   TranscriptSearch.maxRowsScanned),
                               samples[Int(Double(samples.count) * 0.95)])
            }
            report.append(line + "ms(P95)")
        }

        report.append("════════════════════")
        print(report.joined(separator: "\n"))
        add(XCTAttachment(string: report.joined(separator: "\n")))

        // PRD §4.7.3 的硬指标。**不达标就红** —— 不要偷偷放宽,
        // 那样只会让「三个月后卡顿」变成一个上线后才发现的问题。
        XCTAssertLessThan(worstP95, 100,
                          "三个月语料下 P95 是 \(String(format: "%.1f", worstP95))ms,超了 100ms 的硬指标 —— "
                        + "trigram 这个选型要重新评估,别放宽指标")
    }
}

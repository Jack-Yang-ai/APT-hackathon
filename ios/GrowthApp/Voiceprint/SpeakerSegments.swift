import Foundation
import GRDB

// 取段:从一场里挑出用来判人的那几小段音频(方案 S5)。
//
// **挑哪些行、切哪一段是判断,解码只是执行** —— 所以选段这部分是纯函数,
// 能脱开音频与数据库单独被打。
//
// ## 三条依据,每条都有出处
//
// · **每簇最多 5 行**:P4f 实测模板数在 5 条之后收益走平(1 条 5.9% / 5 条 2.2% /
//   8 条 1.8% / 不限 1.8%)。再多是白花 CPU。
// · **挑最长的几行**:P4a 只量过长句(≥20 字,ASR 分人错误率 10%),
//   碎句只知道「更差」、**没量过**。用长句是拿已知的那一半做决定。
// · **每行取中段 4 秒,下限 3 秒**:底库模板是 3~8 秒的人工判决段
//   (min 3.0 / 中位 4.48),**查询侧必须和模板侧同域**;
//   而 P4e 的时长曲线上 3.0s=1.4% / 5.0s=0.0%,3 秒以下掉得很快
//   (1.5s=10.2%)。⚠️ **4 秒本身没有被直测过**,是 3s 与 5s 之间的插值。
//   ⚠️ 而且那条曲线出自 p4e,而 `p4e_eval.py` 的留一分组已知有泄漏 ——
//   真实错误率只会更高,所以 **3 秒是下界不是安全线**。
enum SpeakerSegments {

    static let maxLinesPerCluster = 5
    static let targetSeconds: Double = 4
    /// 一段最短多长才切得出来。
    ///
    /// 🔴 **2026-08-21 用户拍板:「你只要能切割开就认,不用做任何限制」。**
    /// 于是这里只剩**物理下限** —— 嵌入器的梅尔前端要求至少 `winLength` 个采样点
    /// (`MelFrontend.swift` 那句 `guard samples.count >= winLength`),16 kHz 下 = 25 毫秒。
    /// **不写死 0.025**:它从 `MelFrontend` 推出来,那边改了这边跟着改(铁律 4)。
    ///
    /// ## 为什么原来的 3 秒可以撤掉
    ///
    /// 3 秒守的是「短段嵌入不可靠」,而**在旧判据下不可靠 = 安错名字**
    /// (绝对分 ≥0.640 就给名字,而短段的分数可能虚高)。
    /// 换成 τ 差距判据(`M2-认3`)之后,**短段的失败模式变了**:
    /// 嵌入不稳 ⇒ 它跟两个人的分数**咬得近** ⇒ 差距不够 ⇒ **自动拒识**。
    /// 定案 §六③ 说的就是这条:「切不开的靠差距判据天然拒识」。
    /// ⇒ 多一个短段,最坏是白算一次,最好是多一票 —— 不再是「多一次安错名字的机会」。
    ///
    /// **实测**:把它设成 3.0 / 2.0 / 1.5 各跑一次端到端(`VoiceprintChainTests`,
    /// 带真值:两个登记者必须被认出、另两个必须保持匿名)—— **三档都 8/8 全过**。
    ///
    /// ⚠️ **这不等于「短段和长段一样好」**,只等于「短段不再制造错名」。
    /// 而且那份夹具是近讲素材;预研 §5.2 按场景拆开后,**全时录音那两列在 1.5 秒是负的
    /// (（场次略） 给到 30 秒仍然为负)** —— 撤掉这条下限解决的是「材料被白白扔掉」,
    /// **不是**「全时场景认得出」。后者的变量是场景里有没有混淆对,不是段有多长。
    static let minSeconds: Double =
        Double(MelFrontend.winLength) / Double(MelFrontend.sampleRate)

    /// 一段要送去嵌入的音频。
    struct Window: Equatable {
        let clusterTag: String
        let lineID: Int64
        let blockSeq: Int
        /// 块内起止(毫秒)。
        let startMs: Int
        let endMs: Int
        var seconds: Double { Double(endMs - startMs) / 1000 }
    }

    /// 选段的输入。**只要这几个字段** —— 依赖越少,这一层越好测。
    struct Candidate: Equatable {
        let clusterTag: String
        let lineID: Int64
        /// v15 那列。**为 nil 的行直接出局** —— 它定位不到音频,
        /// 而唯一能用来兜底的算法(`t_start_ms / 300_000`)有歧义,
        /// 会取到另一个人的声音(见 `LineAudio`)。
        let blockSeq: Int?
        /// 块内起止(已减掉块偏移)。
        let startMs: Int
        let endMs: Int
        let charCount: Int
    }

    /// 挑段。**纯函数。**
    ///
    /// 返回按簇分组的窗口;某一簇一段都挑不出来时,那一簇**不出现在结果里** ——
    /// 而不是给一个空数组假装挑过。下游据此判「这簇没法判」。
    static func select(_ candidates: [Candidate]) -> [String: [Window]] {
        var out: [String: [Window]] = [:]
        let byTag = Dictionary(grouping: candidates, by: \.clusterTag)

        for (tag, rows) in byTag {
            let windows = rows
                // 定位不到音频的行直接出局 —— 见 `Candidate.blockSeq`
                .filter { $0.blockSeq != nil }
                // 长的在前:长句是唯一被量过的那一档
                .sorted { a, b in
                    a.charCount != b.charCount ? a.charCount > b.charCount
                                               : a.lineID < b.lineID   // 稳定,便于复现
                }
                .prefix(maxLinesPerCluster)
                .compactMap(window(of:))
            if !windows.isEmpty { out[tag] = windows }
        }
        return out
    }

    /// 一行 → 它中间那 4 秒。行不足 3 秒时**返回 nil**(不参与),
    /// 不把一段 1.5 秒的音频硬塞进去 —— 那一档实测错误率是 3 秒的 7 倍。
    static func window(of c: Candidate) -> Window? {
        guard let blk = c.blockSeq else { return nil }
        let durMs = c.endMs - c.startMs
        guard durMs >= Int(minSeconds * 1000) else { return nil }

        let takeMs = min(durMs, Int(targetSeconds * 1000))
        // 取**中段**:一句话的头尾常粘着上一个人的尾音与下一个人的起头,
        // 而中间那几秒最干净。
        let start = c.startMs + (durMs - takeMs) / 2
        return Window(clusterTag: c.clusterTag, lineID: c.lineID, blockSeq: blk,
                      startMs: start, endMs: start + takeMs)
    }

    // MARK: - 从库里取候选

    /// 这一场里,每个簇有哪些行可以用来判人。
    ///
    /// **只读当前生效那一版转写**,并且**跳过占位行与脱敏行** ——
    /// 占位行没有音频(它代表一段缺失),脱敏行的音频按 §隐私不该再被读出来。
    /// - Parameter offsets: 每块的真实起点(`BlockTiming.offsets`)。
    ///   🔴 **必须传真值,不许再用 `blockSeq × 300_000` 反算** ——
    ///   冻结层 2026-08-17 起按账本真值拼时间轴(块长 270–330 秒),
    ///   按名义值减会让偏移**逐块累积**,而漂的形态是
    ///   **取到块里错误的位置、不报错**:声纹会拿别人的声音去判人。
    /// - Parameter includingAutoAttributed: 连**已经被自动判过**的簇一起重来
    ///   (S5.5「对这一场重跑归属」)。
    ///
    ///   🔴 **无论开关怎么设,用户确认过的行都不会被改** —— 那道闸在
    ///   `assignSpeaker` 里(`blockedByUserConfirmation`),不在这儿。
    ///   把它放在入口而不是查询里是刻意的:查询有好几个,而入口只有一个。
    ///
    ///   为什么需要这个开关:底库里新进一个人之后,上一次判成「拒识」的簇
    ///   现在可能认得出来了 —— 而默认那条 `person_id IS NULL` 只会跳过
    ///   已经写过的,让重跑变成一次空转。
    static func candidates(sessionID: Int64, offsets: [Int: Int],
                           includingAutoAttributed: Bool = false,
                           in db: Database) throws -> [Candidate] {
        let identityFilter = includingAutoAttributed
            // 自动来源的可以重判;用户确认过的连碰都不碰(省得白算一遍再被入口挡下)
            ? "(ls.person_id IS NULL OR ls.source <> '\(AttributionSource.userConfirmed.rawValue)')"
            : "ls.person_id IS NULL"
        return try Row.fetchAll(db, sql: """
            SELECT ls.cluster_tag AS tag, l.line_id AS line_id, l.block_seq AS blk,
                   l.t_start_ms AS s, l.t_end_ms AS e, LENGTH(l.text) AS n
              FROM line_speakers ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
              JOIN sessions        ss ON ss.id = t.session_id
                                     AND ss.active_transcript_id = t.id
             WHERE ss.id = ?
               AND ls.cluster_tag IS NOT NULL
               AND \(identityFilter)
               AND l.is_gap = 0 AND l.redacted = 0
            """, arguments: [sessionID]).map { row -> Candidate in
            // 块内偏移由 `BlockTiming` 一处算 —— 各算各的迟早再漂一次,
            // 而这种漂没有任何报错。
            let blk = row["blk"] as Int?
            let within = blk.flatMap {
                BlockTiming.withinBlock(startMs: row["s"], endMs: row["e"],
                                        blockSeq: $0, offsets: offsets)
            }
            return Candidate(clusterTag: row["tag"], lineID: row["line_id"],
                             // 算不出块内偏移 ⇒ 这一行定位不到音频,当作没有块号
                             blockSeq: within == nil ? nil : blk,
                             startMs: within?.start ?? 0, endMs: within?.end ?? 0,
                             charCount: row["n"])
        }
    }
}

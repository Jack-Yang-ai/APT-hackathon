import Foundation
import GRDB

/// 把「块音频 → 切段 → 人声门 → 嵌入 → 比对 → 写 `person_id`」串起来(M1-9 的 ②③)。
///
/// ## 这一层只做编排,一个判断都不下
///
/// 判决在 `SpeakerMatch`(纯函数)、选段在 `SpeakerSegments`(纯函数)、
/// 人声门在 `SpeechGate`(纯函数)、写回只走 `assignSpeaker`(铁律 3)。
/// 这里负责的是**解码一次、按块分组、把结果喂给它们** —— 编排错了会漏认,
/// 但不会认错人;而判断错了会把一整簇话记到别人名下。两者分开是刻意的。
///
/// ## 🔴 一块只解一次
///
/// 一块 5 分钟的 m4a 解成 16k Float 是 19 MB,而一簇最多取 5 段、
/// 一场可能有五六个簇 —— 按段解码就是把同一块解十几遍。
/// 所以先按 `blockSeq` 分组,一块解一次、切出这块里要的所有段。
///
/// ## 拒识什么都不写
///
/// 判不出来的簇**一个字都不往归属层写**。写一条「不确定」进去,
/// 下游没有任何地方读得懂它,而它长得和真归属一模一样。
enum VoiceprintChain {

    struct Outcome: Equatable {
        /// 认出来的簇数。
        let matched: Int
        /// 判不出来的簇数(拒识)。**它不是失败** —— 底库只有 2 个人,
        /// 一场里大多数人本来就不在库里。
        let rejected: Int
        /// 被人声门挡掉的段数。这个数**要能看见**:它异常高就说明
        /// ASR 把噪声聚成了说话人,或者门定得太严。
        let gatedOut: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case noRegistry
        case singlePersonRegistry
        var description: String {
            switch self {
            case .noRegistry: return "底库里一条向量都没有 —— 先导入声纹种子"
            case .singlePersonRegistry:
                return "底库里只有一个人 —— 判据是「第一名减第二名 ≥ τ」,"
                     + "没有第二名就判不了。再登记一个人,或者只能靠用户手动认。"
            }
        }
    }

    /// 跑一场。
    ///
    /// - Parameter rerun: **对这一场重跑归属**(S5.5)。
    ///   平时(`false`)只判还没身份的簇;重跑时连自动判过的一起重来 ——
    ///   底库里新进一个人之后,上次拒识的簇现在可能认得出来。
    ///   ⚠️ **用户确认过的行任何时候都不会被改**,那道闸在 `assignSpeaker` 里。
    ///
    /// 🔴 ~~四条 `ProcessingEvents.record` 把 trigger 写死成前台;前提是
    /// `run` 只有一条到达路径(用户当面点「重新认人」)~~ —— **2026-08-19 前提消失**:
    /// `M1-9b` 把这条链接进了泵(冻结之后自动跑一次),后台唤醒**现在到得了这里**。
    ///
    /// ⇒ 照那段注释自己写的处置办了(和 M1-4c 那次一样):`trigger` 提成入参往上传,
    /// 本文件已加进 `TriggerTruthTests` 的 `guarded` 清单,四处字面量清零。
    /// **没有留一个「合法的 `.foreground`」** —— 两个调用方都传真值。
    @discardableResult
    static func run(sessionID: Int64, now: String,
                    embedder: RedimnetBody, vad: SileroVAD,
                    rerun: Bool = false,
                    trigger: ProcessingEvents.Trigger,
                    in db: DatabaseQueue) async throws -> Outcome {

        let registry = try await db.read { try VoiceprintRegistry.entries(in: $0,
                                                                   model: VoiceprintModel.current) }
        guard !registry.isEmpty else { throw Failure.noRegistry }
        // 🔴 **判据要第二名,所以底库里少于两个人时判不了。**
        // 编一个「第二名 = 0」会让第一名的绝对分直接变成差距 ⇒ 退回那条被作废的
        // 绝对分数线,而且**没有任何东西会红**。宁可明说判不了。
        guard Set(registry.map(\.personID)).count >= 2 else {
            throw Failure.singlePersonRegistry
        }
        let templates = registry.map { (personID: $0.personID, vector: floats($0.embedding)) }

        // 选段。**块起点从账本取真值**,不是「块号 × 300 秒」——
        // 后者在块跑满时会取到另一个人的声音(M1-13a 修过的同一个坑)。
        let offsets = BlockTiming.offsets(sessionID: sessionID, in: db)
        let candidates = try await db.read {
            try SpeakerSegments.candidates(sessionID: sessionID, offsets: offsets,
                                           includingAutoAttributed: rerun, in: $0)
        }
        let byCluster = SpeakerSegments.select(candidates)
        // 🔴 **一段都取不出来时,必须说出来是「取不出段」,不能报成「0 簇」。**
        //
        // 2026-08-21 实测代价:用户按我说的录了一段验判据,两句各 2.88 / 2.68 秒,
        // 都短于 `SpeakerSegments.minSeconds = 3` ⇒ 唯一那个簇一段都切不出来
        // ⇒ 这里直接早返回 ⇒ 事件写的是「认人:0 个认出 · **0 簇判不出**」。
        // 而库里明明有 1 个簇 —— 「没有簇」与「有簇但全是碎句」被写成了同一句话,
        // **于是那一轮验证白做,还差点让人以为是判据不工作。**
        //
        // ⚠️ 同一个文件下面那段注释早就点出过这个形态(「拿它当全集的话,全是碎句的
        // 那些簇就悄悄没了 —— 而『碎句多到取不出段』恰恰是最该被看见的一种」),
        // 并为**部分**簇取不出段的情况补了兜底 —— 而**全部**取不出时的这条早返回
        // 一直绕过了它。写对了一半的规则,比没写更容易让人以为已经守住了。
        guard !byCluster.isEmpty else {
            let tags = Set(candidates.map(\.clusterTag))
            if !tags.isEmpty {
                let shortest = candidates.map { ($0.endMs - $0.startMs) / 1000 }.max() ?? 0
                ProcessingEvents.record(
                    trigger: trigger,
                    outcome: "认人:\(tags.count) 簇一段都取不出来",
                    detail: "场次 \(sessionID) —— 行太碎(最长的一行 \(shortest) 秒,"
                          + "而一段至少要 \(Int(SpeakerSegments.minSeconds)) 秒),或都定位不到音频。"
                          + "这不是判不出,是没材料可判。", in: db)
            }
            return Outcome(matched: 0, rejected: 0, gatedOut: 0)
        }

        // 一块只解一次:把所有簇要的段按块号摊平重分组。
        let blocks = Dictionary(
            ProcessingPump.blocks(of: sessionID, ext: "m4a", in: db).map { ($0.blockSeq, $0) },
            uniquingKeysWith: { a, _ in a })
        let windowsByBlock = Dictionary(grouping: byCluster.values.flatMap { $0 },
                                        by: \.blockSeq)

        var scores: [String: [SpeakerMatch.SegmentScore]] = [:]
        var gated = 0

        for (blockSeq, windows) in windowsByBlock.sorted(by: { $0.key < $1.key }) {
            guard let block = blocks[blockSeq] else { continue }
            guard let pcm = try? await decode(block.fileURL) else {
                // 解不开的块**跳过并留痕**,不拖垮整场(同 `ProcessingPump` 的处置)。
                ProcessingEvents.record(
                    trigger: trigger, outcome: "声纹:块 \(blockSeq) 解不开,跳过",
                    detail: "场次 \(sessionID) —— 这一块里的段不参与判决", in: db)
                continue
            }
            for w in windows {
                guard let slice = cut(pcm, startMs: w.startMs, endMs: w.endMs) else { continue }
                // 🔴 人声门在**取段这一步**,不在判决层 —— S3 定阈证明了
                // 背景音靠阈值挡不住(见 `SpeechGate` 那段注释里的界线)。
                // 抛上去,不吞:VAD 解不出输出是**模型坏了**,不是这一段的数据条件。
                // 吞掉的形态是「每段都判无人声 ⇒ 一个人都不认 ⇒ 不报错」。
                guard SpeechGate.passes(try probabilities(of: slice, vad: vad)) else {
                    gated += 1
                    continue
                }
                // 同上:嵌入器抛出也是**系统性**的(模型没打进包、算子集不对、
                // 输出名变了),不是这一段的问题。上一版 `try?` + `continue` 的形态是
                // **每段都跳过 ⇒ matched 恒为 0 ⇒ 底库里的人一个都认不出,而且不报错**。
                let v = try embed(slice, with: embedder)
                let best = templates
                    .map { (personID: $0.personID, score: cosine(v, $0.vector)) }
                    .reduce(into: [Int64: Float]()) { acc, x in
                        // 多模板取 max —— 与留一验收同协议
                        acc[x.personID] = Swift.max(acc[x.personID] ?? -1, x.score)
                    }
                // 🔴 **第一名和第二名都要留下。** 判据是「第一名 − 第二名 ≥ τ」
                // (定案 §一),而 2026-08-21 之前这里取完 top1 就把其余丢掉 ——
                // **差距在下游想算也算不了**,于是实现退化成了一条绝对分数线。
                let ranked = best.sorted { $0.value > $1.value }
                guard let top = ranked.first else { continue }
                scores[w.clusterTag, default: []]
                    .append(.init(personID: top.key, score: top.value,
                                  // 底库只有一个人时没有第二名。这一层不编一个 0 顶上 ——
                                  // 上面那道 guard 已经把这种底库整个挡在外面了。
                                  runnerUp: ranked.count > 1 ? ranked[1].value : 0))
            }
        }

        // 判决 + 写回
        var verdicts: [String: SpeakerMatch.Verdict] = [:]
        for (tag, segs) in scores { verdicts[tag] = SpeakerMatch.judge(segments: segs) }
        // 🔴 **每一个簇都必须有判决,一个都不许凭空消失。**
        //
        // 簇的全集来自 `candidates`(这一场所有还没身份的行),**不是** `byCluster`:
        // `SpeakerSegments.select` 对「一段都挑不出来的簇」是**整簇不出现**
        // (那是它刻意的设计,见 `testAClusterWithNoUsableLineIsAbsentNotEmpty`)。
        // 拿它当全集的话,全是碎句的那些簇就悄悄没了 —— 而「碎句多到取不出段」
        // 恰恰是最该被看见的一种,它说明这一场的分人质量本身有问题。
        //
        // 离线台第一次跑就抓到了这个:4 个簇只回来 3 个判决。
        let allTags = Set(candidates.map(\.clusterTag))
        for tag in allTags where verdicts[tag] == nil {
            verdicts[tag] = .rejected(
                why: byCluster[tag] == nil
                    ? "一段都挑不出来(行太碎,或都定位不到音频)"
                    : "取到的段一个都没用上(人声门挡下或解码失败)")
        }

        let (kept, displaced) = SpeakerMatch.enforceOnePersonPerSession(verdicts)
        for d in displaced {
            ProcessingEvents.record(
                trigger: trigger, outcome: "声纹:簇 \(d.tag) 让位",
                detail: "场次 \(sessionID) —— 人 \(d.personID) 在同一场里被另一簇"
                      + String(format: "以更高票比赢走(本簇 %.2f)", d.ratio), in: db)
        }

        var matched = 0, rejected = 0
        for (tag, verdict) in kept {
            guard case .matched(let personID, let votes, let of, let confidence) = verdict else {
                rejected += 1
                if case .rejected(let why) = verdict {
                    ProcessingEvents.record(
                        trigger: trigger, outcome: "声纹:簇 \(tag) 没认出来",
                        detail: "场次 \(sessionID) —— \(why)", in: db)
                }
                continue
            }
            let lines = candidates.filter { $0.clusterTag == tag }.map(\.lineID)
            guard !lines.isEmpty else { continue }
            // 🔴 **归属只有一条路可写。** confidence 写的是**票比**,
            // 不是相似度也不是正确率 —— 相似度没有概率语义。
            _ = try AssignSpeaker.assignSpeaker(
                lines: lines, person: personID, clusterTag: tag,
                source: .voiceprint, confidence: confidence, actor: .system,
                now: now, in: db)
            matched += 1
            ProcessingEvents.record(
                trigger: trigger,
                outcome: "声纹:簇 \(tag) → 人 \(personID)",
                detail: "场次 \(sessionID) —— \(votes)/\(of) 段同意,"
                      + String(format: "票比 %.2f;%d 行写回", confidence, lines.count), in: db)
        }
        return Outcome(matched: matched, rejected: rejected, gatedOut: gated)
    }

    // MARK: - 音频

    /// 一块 m4a → 16k 单声道 Float。走 `AudioImport.decode` ——
    /// **不另写一份解码**:两份解码的重采样细节迟早不一样,
    /// 而嵌入器对输入域很敏感(模板侧与查询侧必须同域)。
    static func decode(_ url: URL) async throws -> [Float] {
        var out: [Float] = []
        try await AudioImport.decode(url: url) { out += $0 }
        return out
    }

    /// 块内毫秒 → 样本切片。越界返回 nil,**不夹取** ——
    /// 夹出来的段会短于 3 秒下限,而那一档的错误率是 3 秒的 7 倍。
    static func cut(_ pcm: [Float], startMs: Int, endMs: Int) -> [Float]? {
        let rate = AudioImport.sampleRate
        let a = startMs * rate / 1000, b = endMs * rate / 1000
        guard a >= 0, b > a, b <= pcm.count else { return nil }
        return Array(pcm[a..<b])
    }

    /// 🔴 **抛出要传上去,不能吞。**
    ///
    /// 上一版是 `if let p = try? vad.probability(...)` —— 抛出时**这一帧被悄悄丢掉**。
    /// 而 `SileroVAD` 的文件开头就写着这条纪律,连后果都写全了:
    ///
    /// > 换个算子集的 .onnx、或 ORT 升级后输出名变了,每一帧都返回 0/失败 ⇒
    /// > 「VAD 说全程没人说话」⇒ 什么都不做,**而且不报错**。
    ///
    /// 它在 `probability` 里把 `try?` 改成了抛,**而调用方这里又把它吞了回去** ——
    /// 纪律写在被调方,作废在调用方(2026-08-18 复核抓到,铁律四的形状)。
    /// 全帧失败的表现会是 `out` 为空 ⇒ 语音占比 0 ⇒ 整块被门挡掉 ⇒
    /// **声纹链一个人都不认,而没有任何地方报错**。
    static func probabilities(of samples: [Float], vad: SileroVAD) throws -> [Float] {
        vad.reset()
        var out: [Float] = []
        var i = 0
        while i + SileroVAD.frameSamples <= samples.count {
            out.append(try vad.probability(frame: Array(samples[i..<(i + SileroVAD.frameSamples)])))
            i += SileroVAD.frameSamples
        }
        return out
    }

    /// ⚠️ 由 `private` 改成内部可见(2026-08-18,M1-19):切点探针要用同一条嵌入路径。
    /// **不另写一份** —— 前端参数(窗、mel、CMN)写错不报错,只让向量悄悄变质,
    /// 两份实现迟早对不上而账面看不出来。
    static func embed(_ samples: [Float], with body: RedimnetBody) throws -> [Float] {
        let mel = try MelFrontend.melSpectrogram(samples)
        return try body.embed(mel: mel.values, frames: mel.frames)
    }

    // MARK: - 向量

    static func floats(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// 余弦相似度。两边都不归一化的话结果会随音量变 ——
    /// 而底库那侧是别的运行时算出来的,量纲对不上就全盘失真。
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}

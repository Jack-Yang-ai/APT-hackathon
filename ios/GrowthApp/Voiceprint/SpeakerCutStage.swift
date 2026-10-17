import Foundation

/// 切分接进流水线的那一步:**装配之后、冻结之前**(M1-19 第三块)。
///
/// ## 为什么是这个位置
///
/// 冻结保护的是「出稿之后不许**就地覆盖**」。刀落在冻结**之前**,产出的行
/// 天生一行一个人,一条触发器都碰不到 —— 这是用户 2026-08-18 拍板走
/// 「真的切成两行」时定的顺序(而不是「先冻结、后打补丁」)。
///
/// ## 🔴 两个坐标系,搞混不报错
///
/// | 谁 | 时间轴 |
/// |---|---|
/// | ASR 报文里的 `utterances[].words[].start_time` | **裁过的音频**(VAD 裁段之后送检的那份 wav) |
/// | 盘上的 `block-%04d.m4a` | **没裁的**整块 |
///
/// 探针只能跑在盘上那份(裁过的 wav 是上传时的临时文件,传完就没了)。
/// 所以每一行要先经 `TranscriptFreeze.restoreToBlockTime` 换算到块坐标才能取音频。
///
/// ⚠️ **换算错了不会报错** —— 取到的是同一块里**别处**的声音,探针照样给出一个
/// 看着正常的切点,而那个切点与这一行毫无关系。本仓已经在
/// 「`blockSeq × 300_000` 反推偏移」上栽过同一个形状(M1-13a)。
///
/// 回程不做逆映射:切点在块坐标上找到之后,**挑出第一个越过它的词**,
/// 再拿那个词自己的裁过坐标去切。刀本来就只落在词边界上,所以这不是近似,是精确。
enum SpeakerCutStage {

    /// 🔴 **灰度:只切不写。**
    ///
    /// 方案的落地第 3 步原话:「灰度『只切不写』(1 周):并行跑,**只记日志不改归属**,
    /// 对账切分行为」。而现在还多一条硬理由:`SpeakerCut.separationMargin`
    /// **没有实测依据**(见它的注释),参数定版要在 50 段人工金标上扫。
    ///
    /// 打开它之前必须先有那个定版结果 —— 否则就是拿一个猜出来的数去切用户的话。
    /// 打开的方式是把这里改成 `true`,**不要加运行时开关**:开关会被忘记关上,
    /// 而这个仓已经有一条「没有开关可开」的先例(`transcript_lines` 的冻结触发器)。
    static let appliesCuts = false

    /// 一个待切的点。
    struct Plan: Equatable {
        let blockSeq: Int
        /// 在 `BlockTranscript.lines` 里的下标
        let lineIndex: Int
        /// 切点,**裁过坐标**(与 `ASRWord.startMs` 同一个轴,可直接喂 `SpeakerCut.split`)
        let atTrimmedMs: Int
        /// 切点,块坐标 —— 只为记日志时说人话用
        let atBlockMs: Int
    }

    /// 值得一探的最短行长(毫秒)。
    ///
    /// 比这更短的行探针**结构上**就会返回 nil(左右各一个整窗 + 中位数基线要
    /// `minCandidates` 个候选点),所以这里不是性能优化,是**把注定为 nil 的前向省掉**。
    /// 顺带:全时录音里绝大多数 ASR 行都短于它,这一条把探针的开销压在少数长行上。
    static var minProbeMs: Int {
        SpeakerCut.windowMs * 2 + SpeakerCut.stepMs * (SpeakerCut.minCandidates - 1)
    }

    /// 给一块找出所有该切的点。
    ///
    /// - Parameters:
    ///   - block: 装配出来的一块(`lines` 的时间是**裁过坐标**)
    ///   - samples: 这一块**没裁**的整块音频(16k 单声道)
    ///   - embed: 注入的嵌入器。生产传 `VoiceprintChain.embed`,**同一条嵌入路径**
    /// - Returns: 该块里每一个待切点。空 = 没有该切的。
    ///
    /// 单行失败(换算不出块坐标、音频不够长)**跳过这一行,不拖垮整块** ——
    /// 方案定的三条 fail-open 之一。而嵌入器抛出是系统性失败,**往上抛不吞**
    /// (吞掉的形态是「所有行都不切」,和「本来没有需要切的行」一模一样)。
    static func plan(for block: BlockTranscript,
                     samples: [Float],
                     embed: ([Float]) throws -> [Float]) throws -> [Plan] {
        guard !block.keptIntervals.isEmpty else { return [] }
        let rate = AudioImport.sampleRate
        var out: [Plan] = []

        for (i, line) in block.lines.enumerated() {
            guard line.words.count >= 2,
                  line.endMs - line.startMs >= minProbeMs else { continue }

            // 裁过坐标 → 块坐标。换算不出来就跳过这一行(fail-open)。
            guard let s = try? TranscriptFreeze.restoreToBlockTime(
                      trimmedMs: line.startMs, keptIntervals: block.keptIntervals, blockSeq: block.blockSeq),
                  let e = try? TranscriptFreeze.restoreToBlockTime(
                      trimmedMs: line.endMs, keptIntervals: block.keptIntervals, blockSeq: block.blockSeq),
                  e > s
            else { continue }

            let from = s * rate / 1000, to = min(e * rate / 1000, samples.count)
            guard to > from else { continue }

            guard let cutInLine = try SpeakerCut.changePoint(
                      in: Array(samples[from..<to]), embed: embed)
            else { continue }

            // 块坐标的切点 → 第一个越过它的词 → 拿那个词**自己的裁过坐标**去切。
            // 不做逆映射:刀只落在词边界上,所以这是精确的,不是近似。
            let cutBlockMs = s + cutInLine
            guard let word = line.words.first(where: {
                      (try? TranscriptFreeze.restoreToBlockTime(
                          trimmedMs: $0.startMs, keptIntervals: block.keptIntervals, blockSeq: block.blockSeq))
                          .map { $0 >= cutBlockMs } ?? false
                  })
            else { continue }

            out.append(Plan(blockSeq: block.blockSeq, lineIndex: i,
                            atTrimmedMs: word.startMs, atBlockMs: cutBlockMs))
        }
        return out
    }

    /// 把计划落到行上。**纯函数**,不碰库、不碰盘。
    ///
    /// 🔴 切出来的两半**簇标签一律置空**(`SpeakerCut.split` 已经这么做了)。
    /// ASR 给的 `speaker` 是整句一个,而「这两半是不同的人」正是我们要推翻它的地方;
    /// 照抄的后果是**切是切开了,两半仍挂同一个人,看起来一切正常**。
    static func apply(_ plans: [Plan], to blocks: [BlockTranscript]) -> [BlockTranscript] {
        guard !plans.isEmpty else { return blocks }
        let byBlock = Dictionary(grouping: plans, by: \.blockSeq)

        return blocks.map { block in
            guard let ps = byBlock[block.blockSeq] else { return block }
            let cutAt = Dictionary(ps.map { ($0.lineIndex, $0.atTrimmedMs) },
                                   uniquingKeysWith: { a, _ in a })
            var lines: [ASRLine] = []
            for (i, line) in block.lines.enumerated() {
                if let at = cutAt[i], let (head, tail) = SpeakerCut.split(line, atMs: at) {
                    lines.append(head)
                    lines.append(tail)
                } else {
                    // 计划有、切不动(词边界不合、片太短)⇒ 留原行。
                    // `split` 自己会因为这些理由返回 nil,那是它的 fail-open。
                    lines.append(line)
                }
            }
            return BlockTranscript(blockSeq: block.blockSeq, offsetMs: block.offsetMs,
                                   keptIntervals: block.keptIntervals, lines: lines)
        }
    }
}

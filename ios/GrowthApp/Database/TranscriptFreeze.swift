import Foundation
import GRDB

// 转写冻结链路(§3.1.6)。
//
// 这一层存在的理由是一句话:**落盘分段 ≠ 转写分段**。
// 5 分钟一段只为「断电不丢」与「边录边传」,是文件单位;而 transcript_lines 要求
// 一次性批量插入、行序无洞、char_offset 全文连续 —— 逐段插入会出截断句、行序出洞、
// 偏移算不出来三件事。所以块可以并行转写,但必须**按 block_seq 排序拼接、场次为单位
// 一次事务落库**。在那之前不存在 line_id,因此没有任何东西能引用一个未冻结的转写。

/// 一块的 VAD 保留区间,单位是**块内原始毫秒**。
/// 裁剪后的音频就是这些区间首尾相接的结果 —— 时间轴还原全靠它。
struct KeptInterval: Equatable {
    let startMs: Int
    let endMs: Int
    var durationMs: Int { endMs - startMs }
}

/// ASR 返回的一个词,自带起止(裁剪后时间轴)。
///
/// 🔴 **它是「按词切行」的全部依据**(M1-19)。刀是滑窗在**音频**上找出来的,
/// 而行上挂的是**文字** —— 没有逐词时间戳,就只能按比例摊字,那是猜。
/// 实测:StepFun 的报文 **37/37 句都带**(`utterances[].words[]`)。
///
/// ⚠️ 拼接不加分隔符:中文的词自带标点(「下。」),逐词拼起来正好等于整句原文。
/// 换成有词间空格的语言时这条要重看 —— 那时拼出来会少掉空格,
/// 而**少掉的空格不会报错**,只会让「引文是原文子串」这条校验莫名其妙地挂掉。
struct ASRWord: Equatable {
    let startMs: Int
    let endMs: Int
    let text: String
}

/// ASR 返回的一行。时间戳在**裁剪后**的时间轴上,不是块内原始时间轴。
struct ASRLine: Equatable {
    let startMs: Int
    let endMs: Int
    let text: String
    /// 这一句的**簇标签**(ASR 自带的分人,如 `speaker_0`)。上游没开分人时是 nil。
    ///
    /// ⚠️ **必须和文本长在同一个结构体上,不能另开一个数组按下标对。**
    /// 解析会丢掉空句与时间戳倒挂的句子,两个数组的下标从那一刻起就错开了 ——
    /// 而错开的表现是「这句话被算成了另一个人说的」,不报错,只是把归属悄悄搞乱。
    /// 而归属搞乱正是这个仓最贵的历史事故(旧仓实测悬空 1979 条)。
    let speaker: String?

    /// 逐词时间戳。上游没给就是空 —— **空就不许切**(见 `SpeakerCut.split`)。
    let words: [ASRWord]

    init(startMs: Int, endMs: Int, text: String,
         speaker: String? = nil, words: [ASRWord] = []) {
        self.startMs = startMs; self.endMs = endMs; self.text = text
        self.speaker = speaker; self.words = words
    }
}

/// 一块的转写结果。
struct BlockTranscript: Equatable {
    let blockSeq: Int
    /// 该块起点在场次内的绝对毫秒
    let offsetMs: Int
    let keptIntervals: [KeptInterval]
    let lines: [ASRLine]
}

/// 一块缺失(超过计时窗口仍没到齐)。
struct MissingBlock: Equatable {
    let blockSeq: Int
    let offsetMs: Int
    let durationMs: Int
    var noRecognizedText = false
}

struct FreezeResult: Equatable {
    let transcriptID: Int64
    /// `frozen`(全到齐)或 `partial`(有缺块)
    let status: String
    let lineCount: Int
    let gapCount: Int

    /// ASR 自带的分人标签:`line_id → 簇标签`。上游没开分人时是空的。
    ///
    /// ⚠️ **这不是归属,是「上游说了什么」。** 冻结层不写 `line_speakers`
    /// (归属只有一条路可写 —— `assignSpeaker`,铁律 3),但它是唯一同时握着
    /// 「新写的 line_id」和「那一行的簇标签」的地方,所以由它把映射交出来。
    ///
    /// 靠**同一个结构体**传递而不是靠下标对齐:解析会丢掉空句与时间戳倒挂的句子,
    /// 另开一个数组按下标对,从丢掉第一句起就全错位了 —— 而错位的表现是
    /// 「这句话被算成了另一个人说的」,不报错。
    let speakerByLine: [Int64: String]
}

enum TranscriptFreeze {

    enum Failure: Error, CustomStringConvertible {
        case duplicateBlockSeq(Int)
        case noBlocks
        case timestampOutOfKeptRange(blockSeq: Int, trimmedMs: Int, keptTotalMs: Int)
        case linesOutOfOrder(blockSeq: Int)
        case emptyKeptIntervals(blockSeq: Int)

        var description: String {
            switch self {
            case .duplicateBlockSeq(let s):
                return "block_seq \(s) 重复 —— 拼接顺序无法确定,不能猜"
            case .noBlocks:
                return "一块都没有,没有可冻结的内容"
            case .timestampOutOfKeptRange(let s, let t, let total):
                return "块 \(s) 的 ASR 时间戳 \(t)ms 超出保留区间总长 \(total)ms —— "
                     + "保留区间表与送检音频对不上,还原出来的时间轴会是错的"
            case .linesOutOfOrder(let s):
                return "块 \(s) 的 ASR 行不是按时间递增的 —— 这是上游的缺陷,不在这里悄悄重排"
            case .emptyKeptIntervals(let s):
                return "块 \(s) 有转写行却没有保留区间,时间轴无从还原"
            }
        }
    }

    /// 缺口占位行的文本。§3.1.6 定死这个字样。
    static func gapText(seconds: Int) -> String { "〔此处缺失 \(seconds) 秒〕" }

    /// 缺块**而且长度不详**时的占位文本(M1-30 ①)。
    ///
    /// 🔴 **为什么不能复用 `gapText(seconds: 0)`** —— 那会写出「此处缺失 0 秒」,
    /// 是一句**当场就假**的话。这一块的长度只在账本里,而账本正是丢掉的那一份。
    /// 「不知道多长」与「0 秒」差着一整个量级:后者会让人以为这儿没丢东西。
    static let gapTextUnknownExtent = "〔此处缺失一段,长度不详 —— 账本里没有这一块〕"

    // MARK: - 时间轴还原

    /// 把**裁剪后**时间轴上的毫秒,经保留区间表还原为**块内原始**毫秒。
    ///
    /// VAD 把静音挖掉之后,送检音频是各保留区间首尾相接的结果。所以还原就是:
    /// 沿区间累加时长,落在哪个区间里,就用那个区间的起点加上区间内偏移。
    /// 超出总长直接抛 —— 那意味着保留区间表和送检音频对不上,
    /// 硬凑出来的时间戳会让分人 spans 与行时长的重叠率抽查(A8)悄悄失真。
    static func restoreToBlockTime(trimmedMs: Int, keptIntervals: [KeptInterval],
                                   blockSeq: Int) throws -> Int {
        var consumed = 0
        for interval in keptIntervals {
            if trimmedMs < consumed + interval.durationMs {
                return interval.startMs + (trimmedMs - consumed)
            }
            consumed += interval.durationMs
        }
        // 正好落在末尾边界上是合法的(一行的 end 常常就是音频结尾)
        if trimmedMs == consumed, let last = keptIntervals.last {
            return last.endMs
        }
        throw Failure.timestampOutOfKeptRange(blockSeq: blockSeq, trimmedMs: trimmedMs,
                                              keptTotalMs: consumed)
    }

    /// `restoreToBlockTime` 的**反向**:块内原始毫秒 → 裁剪后时间轴。
    ///
    /// ## 🔴 为什么需要它(`M2-认10` ③,2026-09-01)
    ///
    /// 送去 Mac 判声纹的是**裁过的 wav**,而 `transcript_lines` 的时间戳是
    /// **块内原始**毫秒(`ProcessingPump` 用 `restoreToBlockTime` 还原过)。
    /// 出题时直接把原始毫秒交出去,Mac 就拿它当 wav 下标 —— **两条时间轴,一个下标**。
    ///
    /// 实测(用户真机,某场次):`kept_json = [[94512, 330126]]`,block2 前 94.5 秒
    /// 被裁掉,而 Mac 照样从「原始第 X 毫秒」取音频 ⇒ **每一句都取到 94.5 秒之后的内容**。
    /// 全场共约 130 句被从错的地方取音,另有 275 句因「超出块尾」被直接跳过。
    ///
    /// ⚠️ 它**一直不会红**:入库那条腿在手机上读本地 m4a(没裁过),所以确认→入库全对;
    /// 只有送 Mac 那条腿错位。两条腿各自看都正常 —— 这正是
    /// `ProcessingPump.assemble` 那段注释警告过的形状,只是那道防线没延伸到出题这一步。
    ///
    /// - Returns: 裁剪后时间轴的毫秒;**落在被裁掉的空隙里返回 nil**
    ///   ——「这一刻的音频没送上去」和「它在第 0 毫秒」是两回事,别用同一个值表示。
    static func trimmedTime(blockMs: Int, keptIntervals: [KeptInterval]) -> Int? {
        var consumed = 0
        for interval in keptIntervals {
            if blockMs < interval.startMs { return nil }   // 落在这一段之前的空隙里
            if blockMs < interval.endMs { return consumed + (blockMs - interval.startMs) }
            consumed += interval.durationMs
        }
        // 正好落在末尾边界上是合法的(与 `restoreToBlockTime` 同口径)
        return blockMs == keptIntervals.last?.endMs ? consumed : nil
    }

    /// 一整行在**裁剪后**时间轴上的位置。取不到就返回 nil,调用方丢掉这一行。
    ///
    /// 三种取不到,处置相同(都是「这一行没法在送上去的音频里定位」):
    /// · 起点落在被裁掉的空隙里 · 终点落在空隙里
    /// · **跨过一条裁剪缝** —— 它在 wav 里是被拼接过的,中间那段已经不在了,
    ///   取一段连续音频等于把两处话接在一起。判据是「裁剪后时长 ≠ 原始时长」。
    static func wavRange(blockStart: Int, blockEnd: Int,
                         keptIntervals: [KeptInterval]) -> (start: Int, end: Int)? {
        guard let a = trimmedTime(blockMs: blockStart, keptIntervals: keptIntervals),
              let b = trimmedTime(blockMs: blockEnd, keptIntervals: keptIntervals),
              b - a == blockEnd - blockStart
        else { return nil }
        return (a, b)
    }

    // MARK: - 拼接

    /// 拼接结果的一行:时间戳已经是**场次绝对毫秒**。
    struct AssembledLine: Equatable {
        let startMs: Int
        let endMs: Int
        let text: String
        let isGap: Bool
        /// ASR 自带的簇标签,一路带到写库那一步。占位行没有。
        /// **和文本长在同一个结构体上** —— 见 `ASRLine.speaker` 那段注释。
        var speaker: String? = nil
        /// 这一行来自哪一块。**必须一路带到写库**(迁移 v15)。
        ///
        /// 🔴 下游(声纹取段)要按它去找 `block-%04d.m4a`,而**不能从 `t_start_ms` 反推**:
        /// 真实块长是 `[270s, 330s]`(`BlockCutPolicy`),而块偏移用的是名义值
        /// `blockSeq * 300_000` —— 块 0 第 310 秒与块 1 第 10 秒的 `t_start_ms`
        /// **都是 310000**。反推会读到另一个人的音频,而且不报错。
        ///
        /// 拼接本来就是按块分组做的,这个信息一直在手上,以前只是写库时丢了。
        ///
        /// ⚠️ **故意不给默认值**:每一行都确实来自某一块(占位行来自缺的那一块),
        /// 没有「不知道」这个合法情况。给默认值等于让漏传的地方悄悄变成一个假块号,
        /// 而那正是这一列要消灭的错法 —— 让编译器去挡。
        let blockSeq: Int
    }

    /// 把块与缺块按 block_seq 排成一条无洞的行序。**纯函数,不碰数据库**,
    /// 好让时间轴这套算术能单独被打。
    static func assemble(blocks: [BlockTranscript],
                         missing: [MissingBlock],
                         unplaceable: [Int] = []) throws -> [AssembledLine] {
        let allSeqs = blocks.map(\.blockSeq) + missing.map(\.blockSeq) + unplaceable
        guard !allSeqs.isEmpty else { throw Failure.noBlocks }
        var seen = Set<Int>()
        for seq in allSeqs where !seen.insert(seq).inserted {
            throw Failure.duplicateBlockSeq(seq)
        }

        // 每个 block_seq 产出一段行,最后按 seq 排好再摊平。
        // 缺块那一段就是一条占位行 —— 它占着位置,行序才不会出洞(A2)。
        var chunks: [(seq: Int, lines: [AssembledLine])] = missing.map { g in
            (g.blockSeq, [AssembledLine(startMs: g.offsetMs,
                                        endMs: g.offsetMs + g.durationMs,
                                        text: g.noRecognizedText ? "〔此段未识别到文字，录音已保留〕"
                                            : gapText(seconds: g.durationMs / 1000),
                                        isGap: true, blockSeq: g.blockSeq)])
        }
        // 账本里没有的块也占一行(M1-30 ①)。**行序按 `seq` 排,不按毫秒**
        // (见上面那句「最后按 seq 排好再摊平」)⇒ 位置是**对的**,
        // 不知道的只是它在时间轴上的具体毫秒与长度。
        // ⇒ 时间戳落 0 而**文案说清长度不详** —— 不谎报长度,也不让这个洞消失。
        chunks += unplaceable.map { seq in
            (seq, [AssembledLine(startMs: 0, endMs: 0,
                                 text: gapTextUnknownExtent,
                                 isGap: true, blockSeq: seq)])
        }

        for b in blocks {
            guard !b.lines.isEmpty else { chunks.append((b.blockSeq, [])); continue }
            guard !b.keptIntervals.isEmpty else {
                throw Failure.emptyKeptIntervals(blockSeq: b.blockSeq)
            }
            var lines: [AssembledLine] = []
            var previousStart = -1
            for line in b.lines {
                guard line.startMs >= previousStart else {
                    throw Failure.linesOutOfOrder(blockSeq: b.blockSeq)
                }
                previousStart = line.startMs
                let s = try restoreToBlockTime(trimmedMs: line.startMs,
                                               keptIntervals: b.keptIntervals,
                                               blockSeq: b.blockSeq)
                let e = try restoreToBlockTime(trimmedMs: line.endMs,
                                               keptIntervals: b.keptIntervals,
                                               blockSeq: b.blockSeq)
                lines.append(AssembledLine(startMs: b.offsetMs + s,
                                           endMs: b.offsetMs + e,
                                           text: line.text, isGap: false,
                                           speaker: line.speaker,
                                           blockSeq: b.blockSeq))
            }
            chunks.append((b.blockSeq, lines))
        }

        return chunks.sorted { $0.seq < $1.seq }.flatMap(\.lines)
    }

    // MARK: - 冻结

    /// 拼接 → 一次事务落库 → 冻结。
    ///
    /// 有缺块就是 `partial`,但**仍然一次性落库**(§3.1.6):partial 即终态,
    /// 后补块不回填文本,要完整文本走显式重转成 v2。
    ///
    /// 顺带把 `sessions.active_transcript_id` 指过来 —— 这一步不在任务终态里,
    /// 但 §3.1.4 说界面默认展示 active_transcript_id;不指过去的话,
    /// 冻结成功了界面却找不到它,是「写进了没人看得见的地方」。
    /// 第一次冻结用的版本与分片。
    ///
    /// ⚠️ **提成常量,是因为它们有第二个消费方了**:`ProcessingOrchestrator.freeze`
    /// 要先查「这一场是不是已经冻结过」才敢再冻(否则撞
    /// `UNIQUE(session_id, version, part)`)。两边各写一个 `1`,
    /// 哪天首版号改了就会**查一个版本、写另一个版本** —— 查不到、照插、照撞,
    /// 而报出来的还是那句 `SQLite error 19`。
    static let firstVersion = 1
    static let firstPart = 1

    @discardableResult
    static func freeze(sessionID: Int64,
                       asrModel: String,
                       version: Int = TranscriptFreeze.firstVersion,
                       part: Int = TranscriptFreeze.firstPart,
                       blocks: [BlockTranscript],
                       missing: [MissingBlock] = [],
                       unplaceable: [Int] = [],
                       now: String,
                       onFrozen: ((Database, FreezeResult) throws -> Void)? = nil,
                       in writer: some DatabaseWriter) throws -> FreezeResult {

        let assembled = try assemble(blocks: blocks, missing: missing, unplaceable: unplaceable)
        // 🔴 **「这一场缺东西」与「缺的那块摆在哪」是两件事**(M1-30 ①,2026-08-20)。
        //
        // `missing` 两件都管:它既把状态推成 partial,又带着 offset/duration 去插占位行。
        // 但账本(磁盘文件)与 `upload_jobs`(库)会分叉 —— 账本丢了某一块时,
        // 那一块**从 `missing` 里整个消失**(`missing` 就是拿账本作差算的),
        // 于是缺口既不进 partial 也不插占位行,**这一场自称完整地落库**。
        // 这正是本仓最贵的失败形态:exit code 全绿、行数在涨,而结果是错的。
        //
        // ⇒ `unplaceable` 只管**第一件**:我们知道这些块存在(它们在 `upload_jobs` 里),
        // 但**不知道它们在场次里的哪个位置**——「块的真实起点与时长只在账本里」。
        // 编一个位置正是这段代码在别处明确拒绝做的事(见 `assemble` 里那句
        // 「退回 `blockSeq * 300_000` 是把一个已知会错的时间戳写进冻结层,
        // 而冻结层是不可变的 —— 写错就永久错」)。
        //
        // ⚠️ **它照样有占位行,只是不谎报长度。** 行序按 `blockSeq` 排(不按毫秒),
        // 所以那一行**摆的位置是对的**;不知道的只是它在时间轴上的毫秒与长度
        // ⇒ 时间戳落 0、文案写「长度不详」(`gapTextUnknownExtent`)。
        // 用 `gapText(seconds: 0)` 会写出「此处缺失 0 秒」——**一句当场就假的话**。
        let status = (missing.isEmpty && unplaceable.isEmpty) ? "frozen" : "partial"

        return try writer.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at, frozen_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [sessionID, version, part, asrModel, status, now, now])
            let transcriptID = db.lastInsertedRowID

            // char_offset 是**冻结口径**:一次算定,下游不许按 text 重算。
            // 占位行按它自己的占位文本长度参与累计(§3.1.2 明写),否则
            // 缺块前后的偏移会错开,而错开是没人会注意到的那种错。
            var charOffset = 0
            var speakerByLine: [Int64: String] = [:]
            for (seq, line) in assembled.enumerated() {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (transcript_id, seq, t_start_ms, t_end_ms, text, char_offset,
                       is_gap, block_seq)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [transcriptID, seq, line.startMs, line.endMs,
                                     line.text, charOffset, line.isGap ? 1 : 0,
                                     line.blockSeq])

                // 按词的第二条索引(迁移 v10)。切词在**写入时做一次**,查询时不重切。
                // 走 `WordIndex` 这个唯一入口 —— 少填一行不报错,只会让那一行从此搜不到。
                let lineID = db.lastInsertedRowID
                try WordIndex.index(lineID: lineID, text: line.text,
                                    isGap: line.isGap, in: db)
                // 占位行不带簇标签 —— 它不是谁说的,是一段缺失(A6)
                if !line.isGap, let spk = line.speaker { speakerByLine[lineID] = spk }
                charOffset += line.text.count
            }

            try db.execute(sql: "UPDATE sessions SET active_transcript_id = ? WHERE id = ?",
                           arguments: [transcriptID, sessionID])

            let result = FreezeResult(transcriptID: transcriptID, status: status,
                                      lineCount: assembled.count,
                                      gapCount: assembled.filter(\.isGap).count,
                                      speakerByLine: speakerByLine)
            try onFrozen?(db, result)
            return result
        }
    }
}

import Foundation
import GRDB

/// 用户确认过的行 → 底库(`M2-认1`)。**把断掉的闭环接上。**
///
/// ## 为什么必须有这一步
///
/// 2026-08-20 实测,真机上一场 68 分钟的录音,四个簇**一个都没认出来**:
///
/// | 簇 | 拒识原因 |
/// |---|---|
/// | speaker_0 | 票不够 1/4(要 67%) |
/// | speaker_1 | 没有一段过阈值(最高 **0.618** < 0.640) |
/// | speaker_2 | 没有一段过阈值(最高 0.573) |
/// | speaker_3 | 只切出 1 段,不够判 |
///
/// 分数差的那一点点不是偶然:**底库里全是随包带的种子模板,来自另一个采集域**,
/// 而手机自己录的才是域内数据。`EnrollCommand(` 在此之前**全仓只有一个构造点**
/// (`VoiceprintSeed.swift`)—— 也就是说用户认得再多,底库一条都不长。
///
/// 于是四步死循环:种子不同域 ⇒ 分数差一点 ⇒ 拒识 ⇒ 簇键带场次(`c:<场次>:<簇>`)
/// ⇒ **每一场都重新问用户** ⇒ 用户确认只改归属、零模板进库 ⇒ 回到第一步。
///
/// ⚠️ **这一步不动阈值。** 调阈值是拿「安错名字」换「少问几次」,那是要用户拍的取舍
/// (`M2-认2`);回流底库是把「域漂移」这个真因直接消掉,不牺牲任何准确率。
///
/// ## 复用,不另写一份
///
/// 取段用 `SpeakerSegments.select`(同一条「长句优先、每簇最多 5 段」的规则),
/// 解块/切片/人声门/嵌入全部走 `VoiceprintChain` 的那几个函数 ——
/// **嵌入路径只有一条**,另写一份的后果是两处算出来的向量比不了分。
enum VoiceprintEnroll {

    struct Outcome: Equatable {
        /// 真进底库的模板数。
        let enrolled: Int
        /// 幂等挡下的(同一段音频重复 enroll)。
        let skipped: Int
        /// 人声门挡下的段。
        let gatedOut: Int
        /// 一段都取不出来的行数。
        let noSegment: Int
    }

    /// 这一批行的语音进 `personID` 的底库。
    ///
    /// - Parameter lineIDs: 用户刚确认过的行。**可能跨场次**(`p:` 那种键是全库唯一的),
    ///   所以内部按场次分组:块偏移是每场一套的。
    ///
    /// ⚠️ **失败 fail-open 但留痕**:认人是锦上添花,enroll 失败不该让「确认」这个
    /// 动作看起来没成功 —— 归属那一步早就落库了。但**不许静默**:
    /// 悄悄不 enroll 的表现就是「下一场还是认不出」,而那正是这条要修的东西。
    static func fromConfirmed(personID: Int64, lineIDs: [Int64], now: String,
                              embedder: RedimnetBody, vad: SileroVAD,
                              trigger: ProcessingEvents.Trigger,
                              in db: DatabaseQueue) async throws -> Outcome {
        guard !lineIDs.isEmpty else { return Outcome(enrolled: 0, skipped: 0,
                                                     gatedOut: 0, noSegment: 0) }

        // 行属于哪些场次 —— 块内偏移要按场次算(`BlockTiming` 一处算,别各算各的)。
        let marks = Array(repeating: "?", count: lineIDs.count).joined(separator: ",")
        let bySession: [Int64: [Row]] = try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.session_id AS sid, l.line_id AS line_id, l.block_seq AS blk,
                       l.t_start_ms AS s, l.t_end_ms AS e, LENGTH(l.text) AS n
                  FROM transcript_lines l
                  JOIN transcripts t ON t.id = l.transcript_id
                 WHERE l.line_id IN (\(marks))
                   AND l.is_gap = 0 AND l.redacted = 0
                """, arguments: StatementArguments(lineIDs))
            return Dictionary(grouping: rows, by: { $0["sid"] as Int64 })
        }

        var enrolled = 0, skipped = 0, gatedOut = 0, noSegment = 0

        for (sessionID, rows) in bySession.sorted(by: { $0.key < $1.key }) {
            let offsets = BlockTiming.offsets(sessionID: sessionID, in: db)
            // 借 `SpeakerSegments` 的选段规则。簇标签在这里没有意义(这些行的身份
            // 已经由用户定死),给一个固定键让它当成「一簇」挑。
            let candidates: [SpeakerSegments.Candidate] = rows.map { row in
                let blk = row["blk"] as Int?
                let within = blk.flatMap {
                    BlockTiming.withinBlock(startMs: row["s"], endMs: row["e"],
                                            blockSeq: $0, offsets: offsets)
                }
                return .init(clusterTag: "enroll", lineID: row["line_id"],
                             blockSeq: within == nil ? nil : blk,
                             startMs: within?.start ?? 0, endMs: within?.end ?? 0,
                             charCount: row["n"])
            }
            let windows = SpeakerSegments.select(candidates)["enroll"] ?? []
            if windows.isEmpty { noSegment += rows.count; continue }

            let blocks = Dictionary(
                ProcessingPump.blocks(of: sessionID, ext: "m4a", in: db).map { ($0.blockSeq, $0) },
                uniquingKeysWith: { a, _ in a })

            for (blockSeq, ws) in Dictionary(grouping: windows, by: \.blockSeq)
                                    .sorted(by: { $0.key < $1.key }) {
                guard let block = blocks[blockSeq],
                      let pcm = try? await VoiceprintChain.decode(block.fileURL) else {
                    noSegment += ws.count; continue
                }
                for w in ws {
                    guard let slice = VoiceprintChain.cut(pcm, startMs: w.startMs, endMs: w.endMs)
                    else { noSegment += 1; continue }
                    // 人声门同样在**取段这一步** —— 把背景音 enroll 进底库,
                    // 等于往「我」的模板里掺进空调声,之后每一次比对都被它拖着。
                    guard SpeechGate.passes(try VoiceprintChain.probabilities(of: slice, vad: vad))
                    else { gatedOut += 1; continue }
                    let v = try VoiceprintChain.embed(slice, with: embedder)
                    let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
                    let cmd = EnrollCommand(
                        action: .enroll, personID: personID, embedding: data, dim: v.count,
                        model: VoiceprintModel.current,
                        // source 带上出处:将来要撤销「用户确认带进来的那批」时按它筛。
                        source: "confirmed/\(sessionID)", id: nil)
                    guard let d = try VoiceprintRegistry.applyConfirmed(cmd, lineID: w.lineID, now: now, in: db)
                    else { skipped += 1; continue } // 用户在解码/嵌入期间改判或删掉了这句,不能再回流。
                    if d.execute { enrolled += 1 } else { skipped += 1 }
                }
            }
        }

        let out = Outcome(enrolled: enrolled, skipped: skipped,
                          gatedOut: gatedOut, noSegment: noSegment)
        // 四个数都记。**只记 enrolled 会让「一段都取不出来」看起来像「没什么可学的」** ——
        // 而前者说明这一场碎句太多,是该被看见的。
        ProcessingEvents.record(
            trigger: trigger,
            outcome: "底库:确认带进 \(enrolled) 条模板",
            detail: "人 \(personID) · 幂等挡下 \(skipped) · \(gatedOut) 段不是人声 · "
                  + "\(noSegment) 行取不出段", in: db)
        return out
    }
}

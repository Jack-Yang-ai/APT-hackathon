import Foundation
import GRDB

// 「一行的场次绝对毫秒 → 它在自己那一块里的偏移」。
//
// ## 🔴 为什么要单独一层:那个减法已经错过一次
//
// 2026-08-17 之前,冻结层用 `offsetMs = blockSeq × 300_000` 拼场次时间轴,
// 于是下游反算块内偏移就是 `t_start_ms − blockSeq × 300_000`。
// 当天下午冻结层改成**从账本取每块的真实起点**(块长实际 270–330 秒),
// 而那两处减法**没有跟着改** —— 减出来的偏移开始逐块漂,
// 而漂的形态是**取到块里错误的位置、不报错**:
// 声纹会拿错的音频去判人,「听一下这句」会放出别人的话。
//
// 所以这里把它收成**一个口**。各算各的迟早再漂一次,而这种漂没有任何报错。
enum BlockTiming {

    /// 这一场每一块的真实起点(场次内毫秒)。取自录音账本 ——
    /// `asr_jobs` / `upload_jobs` 都不存时间,账本是唯一有真值的地方。
    static func offsets(sessionID: Int64, in db: DatabaseQueue) -> [Int: Int] {
        // 复用 `ProcessingPump.blocks` 那条路径:它已经处理了
        // 「按这一场自己的日期找目录」「按起始时刻对上账本里的场次」两件事,
        // 而那两件都踩过坑(拿别人的音频当这一场的)。
        Dictionary(uniqueKeysWithValues:
            ProcessingPump.blocks(of: sessionID, ext: "m4a", in: db).map { ($0.blockSeq, $0.offsetMs) })
    }

    /// `Database` 版 —— 投影层在一次 `read` 里判「这一句能不能听」时用。
    static func offsets(sessionID: Int64, in db: Database) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues:
            ProcessingPump.blocks(of: sessionID, ext: "m4a", in: db).map { ($0.blockSeq, $0.offsetMs) })
    }

    /// 一行在它自己那块里的起止(毫秒)。
    ///
    /// **块号必须由调用方给**(来自 `transcript_lines.block_seq`)——
    /// 这里不从时间反推块号,那正是 v15 那列要消灭的错法。
    ///
    /// → nil 表示这一块的真实起点查不到(账本没了 / 这一场不在盘上)。
    /// 那时**不要猜**:退回名义 300 秒会在长块上偏出几十秒,
    /// 而几十秒足够跨到另一个人说话。
    static func withinBlock(startMs: Int, endMs: Int, blockSeq: Int,
                            offsets: [Int: Int]) -> (start: Int, end: Int)? {
        guard let base = offsets[blockSeq] else { return nil }
        let s = startMs - base, e = endMs - base
        // 负偏移说明块号与时间戳对不上 —— 数据坏了,不是「早了一点」
        guard s >= 0, e > s else { return nil }
        return (s, e)
    }
}

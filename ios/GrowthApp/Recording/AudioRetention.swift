import Foundation
import GRDB

/// 音频保留期(PRD §4.1.10 存储组:**默认 7 天**)。
///
/// ## 不删的话它只进不出
///
/// 48 kbps 单声道 ≈ 21.6 MB/小时,全时录音一天 12 小时 ≈ **260 MB/天**。
/// 在这之前唯一的出口是设置里手动「清空全部录音」——
/// 而那是个全有全无的按钮,用户为了腾空间会连昨天的一起清掉。
///
/// ## 🔴 判据不是「够不够老」,是「还需不需要它」
///
/// 只按天数删会在一种情况下丢掉不可恢复的东西:**这一场还没转写完**。
/// 那时音频是唯一的原始材料,删了就永远没有了 —— 而「还没转写完」在
/// 断网、云代理没配、任务卡死(M1-13b/d)之后是常态,不是意外。
///
/// 所以两个条件都要满足:
/// 1. 早于保留期;
/// 2. **这一场已经冻结**(`transcripts.status` 是 `frozen` 或 `partial`)——
///    冻结层是不可变的,转写落进去之后音频就只剩「听一下这句」的用途了。
///
/// 判据是「冻结」而不是「出了纪要」:抽取失败可以重跑(报文存在 `asr_jobs`),
/// 而重跑不需要音频。
///
/// ## 与重试期限对得上
///
/// `TaskQueue.deadlineMinutes` = 6 天,PRD §1.3 写明「重试期限**必须短于
/// 音频保留期(7 天)减 1 天**」。7 − 1 = 6 ✓。改这里的 7 就要一起看那个 6。
///
/// ## ⚠️ 一个已知的缺口
///
/// PRD §4.4 写着「说话人确认所需的代表片段需**单独留存**(几秒/条),
/// 不受 7 天保留期影响,否则拉取式的确认区几周后必然试听不了」——
/// **那个单独留存还不存在**(要等 M1-9 声纹链)。
/// 所以现在:超过 7 天的场次,认人页上的「听一下这句」会说「音频已经清掉了」。
/// 这是**如实降级**(`LineAudio.Unavailable.fileMissing` 会说出来),不是静默失效。
enum AudioRetention {

    /// 保留几天。PRD §4.1.10 的默认值。
    static let days = 7

    struct Outcome: Equatable {
        let filesDeleted: Int
        let bytesFreed: Int64
        /// 清掉音频的场次数。
        let sessionsSwept: Int
        /// 够老了、但**还没冻结**所以留着的场次数。**这个数要能看见** ——
        /// 它一直不降就说明有场次卡住了(而卡住的场次会一直占着空间)。
        let keptUnfinished: Int
    }

    /// 扫一遍,把过期且已冻结的场次的音频删掉。**账本不动**
    /// (它是场次的真相源,而且一天几 KB —— 同 `AudioWipe` 的口径)。
    @discardableResult
    static func sweep(now: Date = Date(), days: Int = AudioRetention.days,
                      fileManager fm: FileManager = .default,
                      in db: DatabaseQueue) throws -> Outcome {
        let cutoff = dayKey(now.addingTimeInterval(-Double(days) * 86_400))

        // 一次查完:够老的场次,连同「它冻结了没有」。
        // ⚠️ 用 `EXISTS` 而不是 JOIN —— 一场有多个 part,JOIN 会把它数很多遍。
        let rows = try db.read { d in
            try Row.fetchAll(d, sql: """
                SELECT id,
                       EXISTS (SELECT 1 FROM transcripts t
                                WHERE t.session_id = s.id
                                  AND t.status IN ('frozen', 'partial')) AS frozen
                  FROM sessions s
                 WHERE s.day < ?
                 ORDER BY s.id
                """, arguments: [cutoff])
        }

        var files = 0, sessions = 0, kept = 0
        var bytes: Int64 = 0
        for row in rows {
            guard let id = row["id"] as Int64? else { continue }
            guard (row["frozen"] as Int? ?? 0) == 1 else {
                // 还没冻结 —— 音频是唯一的原始材料,删了就永远没有了。
                kept += 1
                continue
            }
            var touched = false
            for b in ProcessingPump.blocks(of: id, ext: "m4a", in: db)
            where fm.fileExists(atPath: b.fileURL.path) {
                bytes += ((try? fm.attributesOfItem(atPath: b.fileURL.path))?[.size]
                          as? NSNumber)?.int64Value ?? 0
                // 删不掉就跳过这一块:一块删不掉不该让整场的清理停下,
                // 而下一次扫描还会再碰到它(所以不会被永久忘记)。
                if (try? fm.removeItem(at: b.fileURL)) != nil { files += 1; touched = true }
            }
            if touched { sessions += 1 }
        }
        return Outcome(filesDeleted: files, bytesFreed: bytes,
                       sessionsSwept: sessions, keptUnfinished: kept)
    }

    static func dayKey(_ d: Date) -> String { BlockLedger.dayKey(d) }
}

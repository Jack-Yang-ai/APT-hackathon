import Foundation
import GRDB

// 混合行的落盘与两条下游纪律(预研 P4 §7.2③ / §8 第 7 条)。
//
// 检测本身是纯函数(`MixedLineDetector`),这里只管两件事:
//   ① 把结果存下来 —— 归属可能在几小时后才由 Mac 兜底回流,那时 ASR 的
//      utterance 早就不在内存里了,不存就等于没检测过;
//   ② **卡住下游**。终态说命中的行「不给真名、不进声纹匹配」,
//      而这两件事若靠调用方自觉,迟早有人忘 —— 与铁律 3 同一个道理,
//      所以判断收在这里,`assignSpeaker` 与声纹匹配都从这儿问。
enum MixedLineStore {

    /// 一行的检测结果。
    struct Mark: Equatable {
        let lineID: Int64
        let overlapMs: Int
    }

    /// 覆盖式写入:换阈值重跑就是**整场重写**,不是往上叠。
    /// 叠加的话,上一次用旧阈值标出来的行会永远留着,而没人查得出来它是旧的。
    static func record(_ marks: [Mark], transcriptID: Int64, thresholdMs: Int,
                       now: String, in writer: some DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM mixed_lines WHERE line_id IN
                  (SELECT line_id FROM transcript_lines WHERE transcript_id = ?)
                """, arguments: [transcriptID])
            for m in marks {
                try db.execute(sql: """
                    INSERT INTO mixed_lines (line_id, overlap_ms, threshold_ms, detected_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [m.lineID, m.overlapMs, thresholdMs, now])
            }
        }
    }

    static func isMixed(_ lineID: Int64, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mixed_lines WHERE line_id = ?)",
                          arguments: [lineID]) ?? false
    }

    static func mixedIDs(among lines: [Int64], in db: Database) throws -> Set<Int64> {
        guard !lines.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: lines.count).joined(separator: ",")
        return Set(try Int64.fetchAll(
            db, sql: "SELECT line_id FROM mixed_lines WHERE line_id IN (\(marks))",
            arguments: StatementArguments(lines)))
    }

    /// 能进声纹匹配的行。
    ///
    /// 混合行的嵌入是**两个人的声音混在一起**算出来的,拿它去比对,
    /// 比出来的分数既不属于甲也不属于乙 —— 而分数照样会落在某个区间里,
    /// 看起来完全正常。这是最难查的一类污染,所以在入口就滤掉。
    static func eligibleForVoiceprint(_ lines: [Int64],
                                      in reader: some DatabaseReader) throws -> [Int64] {
        let mixed = try reader.read { db in try mixedIDs(among: lines, in: db) }
        return lines.filter { !mixed.contains($0) }
    }
}

import Foundation
import GRDB

/// 把**上游(ASR 文件腿)的分人标签**从 `asr_jobs.result_json` 重新落回归属层。
///
/// ## 🔴 为什么需要这么一条通道(`M2-认9`,2026-08-31)
///
/// `VoiceprintRemote.merge` 把 Mac 的判决写进 `line_speakers` 时,
/// **直接覆盖了 ASR 那份分人**(`assignSpeaker` 没有优先级闸,后写覆盖先写,
/// 见 `M2-审28`)。而 Mac 那一版是自己重聚的碎簇:
///
/// | 场次 | ASR 判的 | 覆盖后 |
/// |---|---|---|
/// | 若干场 | 上游判出的人数 | 覆盖后的人数明显偏多 |
///
/// 其中一场有用户口述真值。覆盖之后 `line_speakers.cluster_tag` 里再也
/// 找不到 `speaker_0/1/2` —— 而 `M2-认9` 的新出题正是按它分组,
/// **不修的话这些场次会被新逻辑判成「没有分人、不判」**,永远停在碎簇状态。
///
/// 判断日志也救不了:`judgments.payload` 记的是**写入后**的状态,不是写入前。
/// 唯一还留着上游那份事实的地方就是 `asr_jobs.result_json`。
///
/// ## 纪律
///
/// · **只改 `source = '声纹识别'` 的行。** 用户确认过的、以及本来就是
///   `系统整理` 的行一个字都不碰 —— 前者不可覆盖,后者本来就是对的。
/// · **行数对不上就整场跳过。** utterance 与转写行是不是 1:1 由数据决定,
///   不由假设决定;对不上时错位写入的表现是「每个人的话都挪了一格」,
///   而那比不修坏得多,且没有任何东西会红。
/// · **`speaker` 为空的 utterance 跳过那一行**(走 SSE 的块会这样),
///   不给它编一个标签。
///
/// ## 🔴 本文件**一句写库的 SQL 都没有**,这是刻意的
///
/// `assignSpeaker` 收的是 `DatabaseWriter` 且自己开事务,迁移闭包手上只有
/// `Database`,在里面再 `write` 会死锁 —— 所以这次修复只能在 API 线以下写。
/// 而铁律 3 有一道**源码对撞**守着
///(`ReassignSpeakerTests.testNothingOutsideAssignSpeakerWritesToTheAttributionTable`),
/// 它只豁免 `AssignSpeaker.swift` 与 `AppDatabase.swift` 两个路径。
///
/// ⚠️ 我第一版把改归属表的那句 SQL 写在这里,**当场被那条测试抓住** ——
/// (连这段注释都不能把那个动词和表名连着写:闸是文本扫描的,
///  写了它照样红 —— 这不是误报,是它宁可错杀也不放过的设计。)
/// 而正确的处置不是把本文件加进豁免名单(那会把闸变成一张可以随时加名字的白名单),
/// 是**把风险和写入拆开**:
///   · 风险全在这里 —— JSON 解析、行与 utterance 的对齐、三道守卫,可单测;
///   · 写入在 `AppDatabase.applyUpstreamDiarizationRepair`(已豁免的迁移文件里),
///     只是照 `Plan` 机械地 UPDATE 一遍。
/// 闸一点都没松。
enum UpstreamDiarizationRepair {

    /// 该改哪些行、改成什么。**只描述,不执行。**
    struct Plan: Equatable {
        /// 场次 → [(行, 要写回的上游标签)]。
        var repaired: [Int64: [Item]] = [:]
        /// 跳过的场次 → 为什么。**必须留下来** —— 静默跳过与「本来就没问题」
        /// 在结果上一模一样。
        var skipped: [Int64: String] = [:]

        var changedLines: Int { repaired.values.reduce(0) { $0 + $1.count } }
    }

    struct Item: Equatable {
        let lineID: Int64
        let clusterTag: String
    }

    /// 从一块的 `result_json` 里按顺序取出每条 utterance 的说话人标签。
    /// 取不出结构就返回 nil(与「这一块没有 utterance」区分开)。
    static func speakers(inResultJSON json: String) -> [String?]? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["result"] as? [[String: Any]]
        else { return nil }
        var out: [String?] = []
        for r in results {
            for u in (r["utterances"] as? [[String: Any]]) ?? [] {
                out.append((u["speaker"] as? [String: Any])?["id"] as? String)
            }
        }
        return out
    }

    static func plan(in db: Database) throws -> Plan {
        var report = Plan()

        let sessions = try Int64.fetchAll(db, sql: """
            SELECT DISTINCT session_id FROM asr_jobs
             WHERE result_json IS NOT NULL ORDER BY session_id
            """)

        for sessionID in sessions {
            // 上游那份:按块序拼起来。
            var tags: [String?] = []
            var unreadable = false
            for json in try String.fetchAll(db, sql: """
                SELECT result_json FROM asr_jobs
                 WHERE session_id = ? AND result_json IS NOT NULL ORDER BY block_seq
                """, arguments: [sessionID]) {
                guard let part = speakers(inResultJSON: json) else { unreadable = true; break }
                tags += part
            }
            if unreadable {
                report.skipped[sessionID] = "有一块的 result_json 解析不出结构"
                continue
            }
            guard tags.contains(where: { $0 != nil }) else {
                report.skipped[sessionID] = "上游本来就没给分人(SSE 形态)"
                continue
            }

            // 现在这一份:生效转写的实句,按 seq。
            let lines = try Row.fetchAll(db, sql: """
                SELECT l.line_id AS line_id, ls.source AS source
                  FROM transcript_lines l
                  JOIN transcripts  t  ON t.id = l.transcript_id
                  JOIN sessions     ss ON ss.id = t.session_id
                                      AND ss.active_transcript_id = t.id
                  LEFT JOIN line_speakers ls ON ls.line_id = l.line_id
                 WHERE ss.id = ? AND l.is_gap = 0 AND l.redacted = 0
                 ORDER BY l.seq
                """, arguments: [sessionID])

            // 🔴 对不上就整场跳过。错位写入会让每个人的话都挪一格,而没有东西会红。
            guard lines.count == tags.count else {
                report.skipped[sessionID] = "行数 \(lines.count) ≠ utterance 数 \(tags.count)"
                continue
            }

            var changed: [Item] = []
            for (row, tag) in zip(lines, tags) {
                guard let tag else { continue }              // SSE 的块:不编标签
                // 只夺回被声纹覆盖掉的那些。用户确认过的、以及已经是系统整理的都不碰。
                guard (row["source"] as String?) == AttributionSource.voiceprint.rawValue
                else { continue }
                changed.append(Item(lineID: row["line_id"], clusterTag: tag))
            }
            guard !changed.isEmpty else {
                report.skipped[sessionID] = "没有被声纹覆盖过的行,不用修"
                continue
            }
            report.repaired[sessionID] = changed
        }
        return report
    }
}

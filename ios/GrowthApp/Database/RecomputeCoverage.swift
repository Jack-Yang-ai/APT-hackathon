import Foundation
import GRDB









enum RecomputeCoverage {






    static let downstream: [(item: Int, table: String, target: RecomputeTarget?)] = [
        (2, "summary_stances",      .summaryStances),   // 纪要「表态」块 —— M0
        (3, "summary_commitments",  .summaryCommits),   // 纪要「承诺」块 —— M0
        (4, "thing_perspectives",   nil),               // 事的三视角 —— M2
        (5, "matter_timeline",      .matterProgress),   // 事的脉络/进展 —— M2-0c 建表(v19)
        (6, "person_brief",         .personBrief),     // 人的档案 —— M3-0c v28







        (7, "discovery_evidence",   .personDiscoveries),   // 关于人的发现 —— M3-0c v26
        (7, "observation_evidence", .observations),    // 关于人与我的观察 —— M3-0c v28






        (8, "self_stances",         .selfStances),     // 立场本体 —— M3-0c v29
        (8, "self_stance_evidence", .selfStances),     // 立场与原则 —— M3-0c v29



        (9, "cards",                .cards),           // 卡片 —— M3-0c v27
    ]








    static let exempt: Set<String> = [
        "line_speakers",        // 归属层自己,不是下游
        "summary_key_points",
        "summary_pendings",
        "summary_topic_keys",



        "summary_events",




        "personal_actions",



        "action_candidates",



        "action_dismissals",



        "ask_turn_sources",




        "mixed_lines",











        "speaker_reviews",




        "transcript_line_tokens",



        "transcript_line_revisions",



        "matter_open_questions",












        "matter_progress_cards",
    ]


    static func gaps(schemaTables: Set<String>, registered: Set<RecomputeTarget>) -> [String] {
        var problems: [String] = []


        for entry in downstream where schemaTables.contains(entry.table) {
            guard let target = entry.target else {
                problems.append("清单第 \(entry.item) 项的表 \(entry.table) 已经建出来了,却没定义重算目标")
                continue
            }
            if !registered.contains(target) {
                problems.append("清单第 \(entry.item) 项的表 \(entry.table) 存在,但 \(target.rawValue) 没注册")
            }
        }


        for target in registered {
            let hasTable = downstream.contains { $0.target == target && schemaTables.contains($0.table) }
            if !hasTable {
                problems.append("\(target.rawValue) 注册了,但它对应的表不在 schema 里")
            }
        }



        let registeredTables = Set(downstream.filter { $0.target.map(registered.contains) ?? false }
                                             .map(\.table))
        for table in schemaTables.subtracting(exempt).subtracting(registeredTables) {
            if downstream.contains(where: { $0.table == table }) { continue }  // 已由 ① 管
            problems.append("\(table) 带 line_id 却既没注册重算、也不在豁免名单里 —— 二选一,别都不做")
        }
        return problems
    }













    static func attributionConsumingTables(_ db: Database) throws -> Set<String> {
        var out: Set<String> = []
        for name in try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'
            """) where name != "transcript_lines" {
            if try db.columns(in: name).contains(where: { $0.name.hasSuffix("line_id") }) {
                out.insert(name)
            }
        }
        return out
    }
}

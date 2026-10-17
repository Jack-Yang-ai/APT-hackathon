import XCTest
import GRDB
@testable import GrowthApp

/// 跨运行时编排的两个「口」(判 8)。
///
/// 判 8 定了:地基是 Swift 真身,编排与验收脚本是 Python,两边靠**同一个 SQLite 文件**
/// 对接。冻结(`TranscriptFreeze`)与落库(`ExtractionStore`)只能从 Swift 调,
/// 而链路上下游都在 Python —— 中间需要一个口。
///
/// 照 `SchemaFixtureTests` 的先例做成**读写文件的 XCTest**:入参 JSON 进,DB 与结果 JSON 出。
/// 不新造 CLI、不把 DDL 在 Python 里重抄一遍(那就是两份 schema,迟早分叉,
/// 而分叉的时候断言脚本还会报绿)。
///
/// 没有入参文件时 `XCTSkip` —— 平时跑测试套件不受影响,只有编排器摆好入参才会真跑。
final class OrchestrationPortTests: XCTestCase {

    /// 仓库根。`#filePath` 是 ios/GrowthAppTests/…,往上三级。
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var workDir: URL { repoRoot.appendingPathComponent(".orchestration") }

    private func input(_ name: String) throws -> [String: Any] {
        let url = workDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("没有 \(name),不是编排跑 —— 跳过")
        }
        let raw = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw Failure.badInput(name)
        }
        return dict
    }

    /// 写产出,然后**把入参删掉**。
    ///
    /// 入参是一次性工单不是配置:留在原地的话,下一次跑全量测试套件会悄悄把这两个口
    /// 再跑一遍、覆盖掉编排产出的库,而且用的是上一跑的旧工单 —— 出错了看起来
    /// 完全正常。失败时不删,好留着排查。
    private func emit(_ payload: [String: Any], to name: String, consuming input: String) throws {
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: workDir.appendingPathComponent(name), options: .atomic)
        try FileManager.default.removeItem(at: workDir.appendingPathComponent(input))
    }

    enum Failure: Error, CustomStringConvertible {
        case badInput(String)
        var description: String {
            switch self {
            case .badInput(let n): return "\(n) 不是一个 JSON 对象"
            }
        }
    }

    // MARK: - ⑦ 冻结

    /// 入:`freeze_in.json`。出:`freeze_out.json` + 建好的库。
    ///
    /// 顺带把冻结后的行**原样导出**给下游(播报闸、抽取、三项校验都要 line_id 与文本)。
    /// 这不是数据修补,是把这一步真正写进去的东西读回来 —— 下游据此工作,
    /// 中间任何一层想「顺手改一下」都会当场对不上。
    func testFreezePort() throws {
        let cfg = try input("freeze_in.json")

        let dbPath = workDir.appendingPathComponent("session.sqlite").path
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        let queue = try DatabaseQueue(path: dbPath)
        try AppDatabase.makeMigrator().migrate(queue)

        let session = cfg["session"] as? [String: Any] ?? [:]
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (1, ?, ?, ?, 'closed')
                """, arguments: [session["startedAt"] as? String ?? "",
                                 session["day"] as? String ?? "",
                                 session["source"] as? String ?? "recording"])
        }

        let blocks = (cfg["blocks"] as? [[String: Any]] ?? []).map { b in
            BlockTranscript(
                blockSeq: b["blockSeq"] as? Int ?? 0,
                offsetMs: b["offsetMs"] as? Int ?? 0,
                keptIntervals: (b["keptIntervals"] as? [[String: Any]] ?? []).map {
                    KeptInterval(startMs: $0["startMs"] as? Int ?? 0,
                                 endMs: $0["endMs"] as? Int ?? 0)
                },
                lines: (b["lines"] as? [[String: Any]] ?? []).map {
                    ASRLine(startMs: $0["startMs"] as? Int ?? 0,
                            endMs: $0["endMs"] as? Int ?? 0,
                            text: $0["text"] as? String ?? "",
                            // ⚠️ **簇标签要读进来。** 不读的话这条链路上
                            // `cluster_tag` 恒为 null,而「说话人一致」那项校验
                            // 要求它非空 ⇒ **那道检查一次都不会触发**,
                            // 于是「模型挂错行」在这条链路上永远测不出来。
                            speaker: $0["speaker"] as? String)
                })
        }
        let missing = (cfg["missing"] as? [[String: Any]] ?? []).map {
            MissingBlock(blockSeq: $0["blockSeq"] as? Int ?? 0,
                         offsetMs: $0["offsetMs"] as? Int ?? 0,
                         durationMs: $0["durationMs"] as? Int ?? 0)
        }

        let result = try TranscriptFreeze.freeze(
            sessionID: 1,
            asrModel: cfg["asrModel"] as? String ?? "unknown",
            blocks: blocks, missing: missing,
            now: cfg["now"] as? String ?? "", in: queue)

        // 🔴 **簇标签落库(§1.2 ⑨ 在 ⑪ 之前)。走唯一入口,不新开写路径(铁律 3)。**
        //
        // ~~「本链路没有分人步骤,所以 cluster_tag 会是 null」~~ **2026-08-18 作废**:
        // 那句话在 `ASRLine.speaker` 落地之后就不成立了,而它留着的后果很具体 ——
        // 这条链路上「说话人一致」那项校验**一次都不会触发**,
        // 于是 M0-6 那条挂起规则只能拿手写假 JSON 验(仓规 6)。
        try ProcessingPump.writeClusterTags(result.speakerByLine,
                                            now: cfg["now"] as? String ?? "",
                                            trigger: .foreground, in: queue)

        // 导出行:person_id / cluster_tag 走 line_speakers 左连接。
        // `person_id` 仍然是 null(这条链路不做认人)—— 三项校验据此把条目判成
        // 「挂起」,那是如实的结果,不是缺陷。
        let lines: [[String: Any]] = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.line_id, l.seq, l.text, l.is_gap, l.t_start_ms, l.t_end_ms,
                       s.person_id, s.cluster_tag
                FROM transcript_lines l
                LEFT JOIN line_speakers s ON s.line_id = l.line_id
                WHERE l.transcript_id = ? ORDER BY l.seq
                """, arguments: [result.transcriptID]).map { row in
                var d: [String: Any] = [
                    "line_id": row["line_id"] as Int64, "seq": row["seq"] as Int,
                    "text": row["text"] as String, "is_gap": row["is_gap"] as Int,
                    "t_start_ms": row["t_start_ms"] as Int, "t_end_ms": row["t_end_ms"] as Int,
                ]
                d["person_id"] = (row["person_id"] as Int64?) ?? NSNull()
                d["cluster_tag"] = (row["cluster_tag"] as String?) ?? NSNull()
                return d
            }
        }
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }

        try emit(["transcriptID": result.transcriptID, "status": result.status,
                  "lineCount": result.lineCount, "gapCount": result.gapCount,
                  "lines": lines], to: "freeze_out.json", consuming: "freeze_in.json")
    }

    // MARK: - ⑫ 落库

    /// 入:`store_in.json`(三项校验之后的干净产出)。出:`store_out.json`。
    func testStorePort() throws {
        let cfg = try input("store_in.json")
        guard let payload = cfg["payload"] as? [String: Any] else {
            throw Failure.badInput("store_in.json 的 payload")
        }
        let queue = try DatabaseQueue(path: workDir.appendingPathComponent("session.sqlite").path)

        let stored = try ExtractionStore.store(
            payload,
            transcriptID: Int64(cfg["transcriptID"] as? Int ?? 0),
            now: cfg["now"] as? String ?? "", in: queue)

        let counts: [String: Any] = try queue.read { db in
            var out: [String: Any] = [:]
            for table in ["summary_key_points", "summary_commitments",
                          "summary_stances", "summary_pendings", "summaries"] {
                out[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return out
        }
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }

        try emit(["stored": stored, "counts": counts], to: "store_out.json",
                 consuming: "store_in.json")
    }
}

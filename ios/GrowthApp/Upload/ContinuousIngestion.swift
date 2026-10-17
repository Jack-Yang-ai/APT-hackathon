import Foundation
import GRDB

/// 采集会话一直开着；已经完成的块成为不可变 part。只追加，不重冻前半场。
/// stream_blocks 是恢复游标，抽取和检索复用正式 transcript/line_id。
enum ContinuousIngestion {
    struct Appended: Equatable {
        var blockSeqs: [Int] = []
        var lines = 0
    }
    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { if case .invalid(let s) = self { return s }; return "分片接入失败" }
    }

    static func isStreaming(_ sessionID: Int64, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM stream_sessions WHERE session_id = ?)",
                          arguments: [sessionID]) ?? false
    }

    /// 先到的后块等前块达到终态；块号来自镜像账本，可能不是从 0 开始。
    /// freezeBlock 只冻结指定的一块，已有产物直接恢复映射，不再调用它。
    static func append(sessionID: Int64, blocks: [PendingBlock], jobs: [ASRJobStore.Job],
                       skipped: Set<Int>, now: String,
                       knownBlockSeqs: Set<Int> = [],
                       freezeBlock: (PendingBlock, Int, @escaping (Database, FreezeResult) throws -> Void) throws -> FreezeResult,
                       in writer: some DatabaseWriter) throws -> Appended? {
        let eligible = try writer.write { db -> Bool in
            guard let row = try Row.fetchOne(db, sql: "SELECT source, status, removed_at FROM sessions WHERE id = ?",
                                            arguments: [sessionID]),
                  row["source"] as String == SessionSource.watch,
                  row["removed_at"] as String? == nil else { return false }
            if try isStreaming(sessionID, in: db) {
                let version = try Int.fetchOne(db, sql: "SELECT MAX(version) FROM transcripts WHERE session_id = ?",
                                               arguments: [sessionID]) ?? 1
                guard version == TranscriptFreeze.firstVersion else {
                    throw Failure.invalid("持续录音被重新整理为另一版本，请先同步手表收尾")
                }
                return true
            }
            guard row["status"] as String == SessionBridge.Status.open else { return false }
            // 已有整场产物的旧数据保持原口径，不能把 part 1 猜成第一个分片。
            let hasTranscript = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM transcripts WHERE session_id = ?)",
                                                  arguments: [sessionID]) ?? false
            guard !hasTranscript else { return false }
            try db.execute(sql: "INSERT INTO stream_sessions(session_id, created_at) VALUES(?, ?)",
                           arguments: [sessionID, now])
            return true
        }
        guard eligible else { return nil }
        guard Set(blocks.map(\.blockSeq)).count == blocks.count,
              Set(jobs.map(\.blockSeq)).count == jobs.count else {
            throw Failure.invalid("账本或转写块号重复，不能猜接入顺序")
        }
        let bySeq = Dictionary(uniqueKeysWithValues: jobs.map { ($0.blockSeq, $0) })
        let cursors = try writer.read { db in
            try Int.fetchSet(db, sql: "SELECT block_seq FROM stream_blocks WHERE session_id = ?", arguments: [sessionID])
        }
        let recorded = Set(blocks.map(\.blockSeq))
        let known = knownBlockSeqs.union(jobs.map(\.blockSeq)).union(skipped).union(cursors)
        guard known.isSubset(of: recorded) else {
            throw Failure.invalid("这些分片在上传/转写记录里，但账本已缺失：\(known.subtracting(recorded).sorted())。无法定位，停止追加，不能自称完整。")
        }
        var out = Appended()
        // 镜像重编号可能是 [3,1]；顺序由账本追加顺序给出，块号只做身份。
        for (index, block) in blocks.enumerated() {
            guard block.blockSeq >= 0, block.blockSeq < Int.max,
                  block.offsetMs >= 0, block.durationMs >= 0, block.durationMs <= Int.max - block.offsetMs else {
                throw Failure.invalid("分片时间或编号无效")
            }
            if let old = try writer.read({ db in
                try Row.fetchOne(db, sql: "SELECT b.offset_ms, b.duration_ms, t.part FROM stream_blocks b JOIN transcripts t ON t.id = b.transcript_id WHERE b.session_id = ? AND b.block_seq = ?",
                                 arguments: [sessionID, block.blockSeq])
            }) {
                guard old["offset_ms"] as Int == block.offsetMs,
                      old["duration_ms"] as Int == block.durationMs,
                      old["part"] as Int == index + 1 else {
                    throw Failure.invalid("已接入分片的账本时间发生变化，停止追加以免原话错位")
                }
                continue
            }
            // failed 留在可重试的 ASR 层，不提前冻成不可修补的正式 gap。
            let terminal = bySeq[block.blockSeq].map { $0.state == .done } ?? false
            guard terminal || skipped.contains(block.blockSeq) else { break }
            let part = index + 1
            let old = try writer.read { db in
                try Row.fetchOne(db, sql: "SELECT id, status FROM transcripts WHERE session_id = ? AND version = ? AND part = ?",
                                 arguments: [sessionID, TranscriptFreeze.firstVersion, part])
            }
            let tid: Int64
            let count: Int
            if let old {
                tid = old["id"]
                count = try writer.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_lines WHERE transcript_id = ?", arguments: [tid]) ?? 0
                }
                // 兼容旧崩溃窗口；已有 part 不能仅靠 part 号猜它对应哪个块。
                try writer.write { db in
                    try map(sessionID: sessionID, block: block, part: part, transcriptID: tid, now: now, in: db)
                }
            } else {
                let result = try freezeBlock(block, part) { db, result in
                    try map(sessionID: sessionID, block: block, part: part, transcriptID: result.transcriptID, now: now, in: db)
                }
                tid = result.transcriptID
                count = result.lineCount
            }
            let mapped = try writer.read { try Int64.fetchOne($0, sql: "SELECT transcript_id FROM stream_blocks WHERE session_id = ? AND block_seq = ?", arguments: [sessionID, block.blockSeq]) }
            guard mapped == tid else { throw Failure.invalid("分片冻结未执行原子接入，停止追加") }
            out.blockSeqs.append(block.blockSeq)
            out.lines += count
        }
        return out
    }

    /// 冻结、声纹标签、游标和排抽取一起提交；恢复旧产物也核实实际块身份与时间起点。
    private static func map(sessionID: Int64, block: PendingBlock, part: Int, transcriptID: Int64,
                            now: String, in db: Database) throws {
        guard let removed = try Row.fetchOne(db, sql: "SELECT removed_at FROM sessions WHERE id = ?", arguments: [sessionID]),
              removed["removed_at"] as String? == nil else { throw Failure.invalid("录音已移出记忆，不能补回分片") }
        guard let t = try Row.fetchOne(db, sql: "SELECT session_id, version, part FROM transcripts WHERE id = ?", arguments: [transcriptID]),
              t["session_id"] as Int64 == sessionID, t["version"] as Int == TranscriptFreeze.firstVersion,
              t["part"] as Int == part else { throw Failure.invalid("分片冻结产物与输入身份不一致") }
        let rows = try Row.fetchAll(db, sql: "SELECT block_seq, t_start_ms, t_end_ms FROM transcript_lines WHERE transcript_id = ?", arguments: [transcriptID])
        guard !rows.isEmpty, rows.allSatisfy({ row in
            (row["block_seq"] as Int?) == block.blockSeq && (row["t_start_ms"] as Int) >= block.offsetMs
            // ASR 末尾可能有编码帧误差；装配层保留 padding，不在这里再硬截时长。
        }) else { throw Failure.invalid("已有分片的实际块身份或时间与账本不符，拒绝复用") }
        try db.execute(sql: "INSERT INTO stream_blocks(session_id, block_seq, transcript_id, offset_ms, duration_ms) VALUES(?, ?, ?, ?, ?)",
                       arguments: [sessionID, block.blockSeq, transcriptID, block.offsetMs, block.durationMs])
        try enqueue(ProcessingOrchestrator.Kind.extract, sessionID: sessionID, now: now, in: db)
    }

    /// 新材料只重新唤起已完成任务；失败和退避不因新块到达而被洗掉。
    static func enqueue(_ kind: String, sessionID: Int64, now: String, in db: Database) throws {
        try db.execute(sql: """
            UPDATE tasks SET state = 'queued', next_retry_at = NULL, last_error = NULL
             WHERE session_id = ? AND kind = ? AND state IN ('done', 'degraded')
            """, arguments: [sessionID, kind])
        try db.execute(sql: """
            INSERT INTO tasks(kind, session_id, state, priority, created_at, attempts)
            SELECT ?, ?, 'queued', 0, ?, 0
             WHERE NOT EXISTS(SELECT 1 FROM tasks WHERE session_id = ? AND kind = ?)
            """, arguments: [kind, sessionID, now, sessionID, kind])
    }
}

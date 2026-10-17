import Foundation
import GRDB

/// 转写作业的落盘状态(M1-4)。
///
/// ## 它存在的唯一理由:**提交转写要花钱,而编排必须能重放**
///
/// M1-4 的准入条件是「整条链路能从落盘状态恢复,不依赖 App 一直活着」。
/// 而恢复意味着**同一段编排会被跑很多遍** —— App 被杀、后台唤醒、用户重开,
/// 每一次都要从任务表捡起没做完的往下走。
///
/// 「提交一块去转写」如果没有落盘的去重,重放一次就是**再花一次钱**,
/// 而且会得到第二个 task_id —— 之后哪个算数没人说得清。
/// `PRIMARY KEY (session_id, block_seq)` 让重放变成 no-op,这是整张表的全部意义。
enum ASRJobStore {

    static let legacyEmptyResultError = "转写报文没有可用文字，未冻结，可重试"

    /// 修复旧版把合法空转写改成 failed 的状态；复用原报文，不重提、不改其他失败。
    static func recoverEmptyRecognitions(now: String, in writer: some DatabaseWriter) throws -> Int {
        try writer.write { db in
            let jobs = try Row.fetchAll(db, sql: """
                SELECT j.* FROM asr_jobs j JOIN sessions s ON s.id = j.session_id
                 WHERE j.state = 'failed' AND j.last_error = ?
                   AND s.source = ? AND s.removed_at IS NULL
                   AND NOT EXISTS(SELECT 1 FROM transcripts t WHERE t.session_id = s.id AND t.version <> ?)
                   AND (EXISTS(SELECT 1 FROM stream_sessions x WHERE x.session_id = s.id)
                        OR (s.status = ?
                            AND NOT EXISTS(SELECT 1 FROM transcripts t WHERE t.session_id = s.id)))
                """, arguments: [legacyEmptyResultError, SessionSource.watch,
                    TranscriptFreeze.firstVersion, SessionBridge.Status.open]).map(job(from:))
            var recovered = 0
            for job in jobs where ASRResponseParser.isEmptyRecognition(rawJSON: job.resultJSON ?? "") {
                try db.execute(sql: """
                    UPDATE asr_jobs SET state = 'done', last_error = NULL, updated_at = ?
                     WHERE session_id = ? AND block_seq = ?
                    """, arguments: [now, job.sessionID, job.blockSeq])
                // 上次空段异常可能已使任务退避或判死。只唤醒有确切恢复材料的场次。
                // attempts 和原始报文都保留；其他 failed 块仍不会自动付费重提。
                try db.execute(sql: """
                    UPDATE tasks SET state = 'queued', next_retry_at = NULL
                     WHERE session_id = ? AND kind = 'transcribe'
                       AND state IN ('queued', 'retrying', 'dead', 'degraded', 'waiting_network')
                    """, arguments: [job.sessionID])
                recovered += 1
            }
            return recovered
        }
    }

    enum State: String {
        case submitted, done, failed
        /// **上游明说不认识这个 task_id。**
        ///
        /// 🔴 与 `failed` 不是一回事,分开是刻意的:
        /// · `failed` = 转写这件事失败了(音频有问题、上游拒了)—— 重来多半还是失败;
        /// · `lost`   = **我们的记录错了**,那一块根本没被转写过 —— 重来是对的。
        /// 混成一个的后果:要么该重的不重(当成失败放弃),
        /// 要么不该重的乱重(每次失败都重提,一次次买单)。
        case lost
    }

    /// 因「上游不认识」最多重提几次。
    ///
    /// ⚠️ **重提要花钱**,所以必须有上限 —— 没有上限的自愈会变成
    /// 「上游每忘一次我们就买一次单」,而那种烧钱**不会有任何东西红**。
    /// 取 2:一次偶发(任务过期/上游清理)够救,连丢三次就不是偶发了。
    static let maxResubmits = 2

    struct Job: Equatable {
        let sessionID: Int64
        let blockSeq: Int
        let remoteID: String
        let state: State
        let resultJSON: String?
        let lastError: String?
        /// 提交出去的时刻。**判「等太久了」用它**(M1-30 ②)——
        /// 不带出来的话上层只能拿退避序列估,而那是模型值不是真实耗时
        /// (同 `M1-30 ③` 的教训)。
        let createdAt: String
    }

    /// 记下「这一块已经提交出去了」。
    ///
    /// **已经有记录就原样返回旧的,不覆盖** —— 调用方据此知道「不用再提交一次」。
    /// 返回 `inserted == false` 时,`remoteID` 是**上一次**那个,不是这次传进来的。
    @discardableResult
    static func claim(sessionID: Int64, blockSeq: Int, remoteID: String,
                      now: String, in writer: some DatabaseWriter) throws
        -> (job: Job, inserted: Bool) {
        try writer.write { db in
            if let existing = try fetch(db, sessionID: sessionID, blockSeq: blockSeq) {
                return (existing, false)
            }
            try db.execute(sql: """
                INSERT INTO asr_jobs
                  (session_id, block_seq, remote_id, state, created_at, updated_at)
                VALUES (?, ?, ?, 'submitted', ?, ?)
                """, arguments: [sessionID, blockSeq, remoteID, now, now])
            return (Job(sessionID: sessionID, blockSeq: blockSeq, remoteID: remoteID,
                        state: .submitted, resultJSON: nil, lastError: nil,
                        createdAt: now), true)
        }
    }

    /// 转写回来了。**存原始报文**,不存解析后的 ——
    /// 解析器改了要能拿回原文重跑,而重新提交是要花钱的。
    static func finish(sessionID: Int64, blockSeq: Int, resultJSON: String,
                       now: String, in writer: some DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE asr_jobs SET state = 'done', result_json = ?, last_error = NULL,
                                    updated_at = ?
                 WHERE session_id = ? AND block_seq = ?
                """, arguments: [resultJSON, now, sessionID, blockSeq])
        }
    }

    /// 转写失败。
    ///
    /// ⚠️ **不删记录。** 删了的话下一次重放会重新提交 —— 而失败往往是内容特性
    /// (实测约 15% 的场次落到兜底腿,**重试救不了**),重提只是再花一次钱。
    /// 要重来得是显式动作,不能靠「记录没了所以又跑一遍」。
    /// 上游说不认识它 —— 记录作废。
    ///
    /// 还没到上限就落 `lost`(等着被重提),到了上限就落 `failed`(别再买单了)。
    /// **两种都写 `last_error`** —— 「为什么这一块没有转写」必须查得到。
    /// - Returns: 是否还会重提。
    @discardableResult
    static func markLost(sessionID: Int64, blockSeq: Int, error: String,
                         now: String, in writer: some DatabaseWriter) throws -> Bool {
        try writer.write { db in
            let used = try Int.fetchOne(
                db, sql: "SELECT resubmits FROM asr_jobs WHERE session_id = ? AND block_seq = ?",
                arguments: [sessionID, blockSeq]) ?? 0
            let willRetry = used < maxResubmits
            try db.execute(sql: """
                UPDATE asr_jobs SET state = ?, last_error = ?, updated_at = ?,
                                    resubmits = resubmits + 1
                 WHERE session_id = ? AND block_seq = ?
                """, arguments: [(willRetry ? State.lost : State.failed).rawValue,
                                 error, now, sessionID, blockSeq])
            return willRetry
        }
    }

    static func fail(sessionID: Int64, blockSeq: Int, error: String,
                     now: String, in writer: some DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE asr_jobs SET state = 'failed', last_error = ?, updated_at = ?
                 WHERE session_id = ? AND block_seq = ?
                """, arguments: [error, now, sessionID, blockSeq])
        }
    }

    static func fetch(_ db: Database, sessionID: Int64, blockSeq: Int) throws -> Job? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM asr_jobs WHERE session_id = ? AND block_seq = ?
            """, arguments: [sessionID, blockSeq]).map(job(from:))
    }

    /// 一场里还在等结果的块。
    static func pending(sessionID: Int64, in reader: some DatabaseReader) throws -> [Job] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM asr_jobs WHERE session_id = ? AND state = 'submitted'
                 ORDER BY block_seq
                """, arguments: [sessionID]).map(job(from:))
        }
    }

    /// 一场里所有转写作业,不分状态,按块序。
    ///
    /// 编排用它回答一个**冻结之前必须问清楚**的问题:
    /// 「已经传上去的块,是不是每一块都有终态了?」
    /// 只看 `pending` 空不空是不够的 —— 一块**提交失败、压根没进这张表**的块,
    /// 在 `pending` 里同样看不见。两者长得一模一样,而处置完全相反:
    /// 前者可以冻结,后者冻结就等于把那块音频**悄悄丢了**。
    static func all(sessionID: Int64, in reader: some DatabaseReader) throws -> [Job] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM asr_jobs WHERE session_id = ? ORDER BY block_seq
                """, arguments: [sessionID]).map(job(from:))
        }
    }

    /// 一场里所有已完成的块的原始报文,按块序。
    static func finished(sessionID: Int64, in reader: some DatabaseReader) throws -> [Job] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM asr_jobs WHERE session_id = ? AND state = 'done'
                 ORDER BY block_seq
                """, arguments: [sessionID]).map(job(from:))
        }
    }

    private static func job(from row: Row) -> Job {
        Job(sessionID: row["session_id"], blockSeq: row["block_seq"],
            remoteID: row["remote_id"],
            state: State(rawValue: row["state"]) ?? .failed,
            resultJSON: row["result_json"], lastError: row["last_error"],
            createdAt: row["created_at"])
    }
}

import Foundation
import GRDB

/// 块级上传态的落盘(M1-4c)。**判断在 `BlockUploader`,URLSession 在
/// `BackgroundUploadCenter`,这里只管把状态写对。**
///
/// ## 为什么上传也需要一张表(转写已经有 `asr_jobs` 了)
///
/// 因为**后台上传的结果在另一个进程生命周期里才回来**。
/// 前台上传可以「调用返回 = 传完了」,后台上传的语义是「交给系统,以后再说」——
/// 而「以后」可能是 App 被系统杀掉、几小时后因传输完成被重新拉起的那一刻。
/// 那时内存里的进度早没了,所以进度只能是库里的一行。
///
/// ## 三态为什么不能合并
///
/// `handed` 与 `failed` 该做的事**完全相反**:一个要等,一个要重来。
/// 合成「未完成」的话,一个永久失败的块会被当成「还在传」等到天荒地老,
/// 而用户看到的是一直「整理中」。
enum UploadJobStore {

    struct Job: Equatable {
        let sessionID: Int64
        let blockSeq: Int
        let key: String
        let state: String
        let httpStatus: Int?
        let lastError: String?
        let updatedAt: String
        /// 这一次**到底送上去了哪几段**(`SpeechTrim.encode` 的形状)。
        ///
        /// ⚠️ **nil 与 `"[]"` 不是一回事**:nil = 没裁过(整块送,或这行早于 M1-4d),
        /// `"[]"` = 一个采样点都没送。冻结时按它把 ASR 的时间戳还原回块内原始时间轴,
        /// 弄混两者的后果是跳原话跳到别人那句,**而且不报错**。
        let keptJSON: String?

        var isPermanentFailure: Bool { state == "failed" && httpStatus == UploadJobStore.permanentStatus }
    }

    /// 这一块交出去了。**已有行原样返回**,不覆盖 ——
    /// 覆盖会把一次已完成的传输打回「在传」,于是重传一遍。
    ///
    /// 返回 `inserted` 说明这次真的是新交的;`false` 说明之前交过了。
    @discardableResult
    static func claim(sessionID: Int64, blockSeq: Int, key: String, now: String,
                      in writer: some DatabaseWriter) throws -> (job: Job, inserted: Bool) {
        try writer.write { db in
            if let existing = try fetch(db, sessionID: sessionID, blockSeq: blockSeq) {
                return (existing, false)
            }
            try db.execute(sql: """
                INSERT INTO upload_jobs
                  (session_id, block_seq, r2_key, state, created_at, updated_at)
                VALUES (?, ?, ?, 'handed', ?, ?)
                """, arguments: [sessionID, blockSeq, key, now, now])
            // 占行时还不知道裁哪几段 —— 计划要等 `handOff` 解完音频才有,
            // 由它回填(`recordKept`)。顺序不能反,见 `BlockUploader` 那段
            // 「先占住行再交」的注释。
            return (Job(sessionID: sessionID, blockSeq: blockSeq, key: key, state: "handed",
                        httpStatus: nil, lastError: nil, updatedAt: now, keptJSON: nil), true)
        }
    }

    static func fetch(_ db: Database, sessionID: Int64, blockSeq: Int) throws -> Job? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM upload_jobs WHERE session_id = ? AND block_seq = ?
            """, arguments: [sessionID, blockSeq]).map(job(from:))
    }

    static func all(sessionID: Int64, in reader: some DatabaseReader) throws -> [Job] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM upload_jobs WHERE session_id = ? ORDER BY block_seq
                """, arguments: [sessionID]).map(job(from:))
        }
    }

    /// 回填「这一次送上去的是哪几段」(M1-4d)。
    ///
    /// 🔴 **必须和真正写进 wav 的那份计划是同一个值。** 两者一旦分叉,
    /// 送检音频与还原表就对不上 —— `restoreToBlockTime` 要么抛
    /// (任务永久停在 `running`),要么**算出一个看起来合理的错位置**。
    /// 所以调用方是 `BackgroundUploadCenter.handOff`:它在同一个函数里
    /// 用同一个 `plan` 既裁 wav 又写这里,想分叉都分叉不了。
    static func recordKept(sessionID: Int64, blockSeq: Int, json: String,
                           in writer: some DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE upload_jobs SET kept_json = ? WHERE session_id = ? AND block_seq = ?
                """, arguments: [json, sessionID, blockSeq])
        }
    }

    /// 系统回话说成了。
    static func finish(sessionID: Int64, blockSeq: Int, status: Int, now: String,
                       in writer: some DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE upload_jobs SET state = 'done', http_status = ?, last_error = NULL,
                                       updated_at = ?
                 WHERE session_id = ? AND block_seq = ?
                """, arguments: [status, now, sessionID, blockSeq])
        }
    }

    /// 系统回话说没成。**记原因** —— 不记的话这一行只是「失败了」,
    /// 而排查时最想知道的恰恰是 4xx 还是断网。
    static func fail(sessionID: Int64, blockSeq: Int, status: Int?, error: String,
                     now: String, in writer: some DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE upload_jobs SET state = 'failed', http_status = ?, last_error = ?,
                                       updated_at = ?
                 WHERE session_id = ? AND block_seq = ?
                """, arguments: [status, error, now, sessionID, blockSeq])
        }
    }

    /// 这一块**永远传不上去**了(音频文件读不出来 / 不在了)。
    ///
    /// 🔴 与「传输失败」分开是刻意的:后者重试有意义,前者重试一万次也一样。
    /// 2026-08-17 真机:一场录音的最后一块是结束那一刻开的空块,`AVFoundation`
    /// 读它报 -11800 —— 而那一块把**整场**卡在了退避里,后面的转写、纪要全不动。
    /// 而 §3.1.6 本来就允许缺块以 `partial` 落库:**一块坏音频不该挡住一整场。**
    ///
    /// 用 `http_status = -1` 当哨兵:它不是 HTTP 状态,而 HTTP 里也没有负数,
    /// 所以不会和真状态码撞上。
    static let permanentStatus = -1

    static func failPermanently(sessionID: Int64, blockSeq: Int, error: String,
                                now: String, in writer: some DatabaseWriter) throws {
        try fail(sessionID: sessionID, blockSeq: blockSeq, status: permanentStatus,
                 error: error, now: now, in: writer)
    }

    /// 把一行抹掉,让它下次重新交给系统。
    ///
    /// ⚠️ **只在「已经记过一次任务级失败」之后调。** 直接抹掉重交等于绕开
    /// `TaskQueue` 的退避与 `dead` 终态 —— 一个永远传不上去的块会被无限重交,
    /// 而任务表上看不出任何异常。
    static func reset(sessionID: Int64, blockSeq: Int,
                      in writer: some DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM upload_jobs WHERE session_id = ? AND block_seq = ?",
                           arguments: [sessionID, blockSeq])
        }
    }

    /// 交出去了但系统那边已经没这个传输任务的行 —— **传输丢了**。
    ///
    /// 会发生:App 被强杀的瞬间任务还没真正入队、系统清理、设备重启。
    /// 不管的话这一行会永远停在 `handed`,而这一场永远等不到上传完成。
    ///
    /// ⚠️ **`grace` 不能是 0。** App 因「传输完成」被冷启动时,回调要过一小会儿
    /// 才送达,而这期间那个任务已经不在 `allTasks` 里了 —— 宽限期为 0 会把
    /// 一次**刚刚成功**的传输判成丢失,然后白传一遍。
    @discardableResult
    static func resetLost(sessionID: Int64? = nil, liveTags: Set<String>, now: Date,
                          grace: TimeInterval = 600,
                          in writer: some DatabaseWriter) throws -> [Job] {
        let cutoff = ISO8601DateFormatter.growth.string(from: now.addingTimeInterval(-grace))
        return try writer.write { db in
            var sql = "SELECT * FROM upload_jobs WHERE state = 'handed' AND updated_at < ?"
            var args: [DatabaseValueConvertible?] = [cutoff]
            if let sessionID { sql += " AND session_id = ?"; args.append(sessionID) }
            let stale = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map(job(from:))
            let lost = stale.filter { !liveTags.contains(tag(sessionID: $0.sessionID, blockSeq: $0.blockSeq)) }
            for j in lost {
                try db.execute(sql: """
                    UPDATE upload_jobs SET state = 'failed', last_error = ?, updated_at = ?
                     WHERE session_id = ? AND block_seq = ?
                    """, arguments: ["传输任务在系统里找不到了 —— 多半是 App 被强杀或设备重启",
                                     ISO8601DateFormatter.growth.string(from: now),
                                     j.sessionID, j.blockSeq])
            }
            return lost
        }
    }

    // MARK: - 标识

    /// 交给系统的传输任务上挂的标识。回调回来时**只有它**能把结果对回某一块 ——
    /// 回调可能发生在冷启动的进程里,那时内存里什么都没有。
    static func tag(sessionID: Int64, blockSeq: Int) -> String { "\(sessionID)/\(blockSeq)" }

    static func parse(tag: String) -> (sessionID: Int64, blockSeq: Int)? {
        let parts = tag.split(separator: "/")
        guard parts.count == 2, let s = Int64(parts[0]), let b = Int(parts[1]) else { return nil }
        return (s, b)
    }

    private static func job(from row: Row) -> Job {
        Job(sessionID: row["session_id"], blockSeq: row["block_seq"], key: row["r2_key"],
            state: row["state"], httpStatus: row["http_status"],
            lastError: row["last_error"], updatedAt: row["updated_at"],
            keptJSON: row["kept_json"])
    }
}

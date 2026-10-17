import Foundation
import GRDB

/// 结束录音 → 出稿的编排(M1-4)。
///
/// ## 一条纪律:**`task_queue` 是唯一真相源**
///
/// 这个类型**不持有任何进度状态**。每次 `tick` 都从库里重新读「还有什么没做完」,
/// 做一步、把结果写回库、返回。App 被杀掉再起来,从库里读出来的还是那个状态。
///
/// M1-4 的准入条件原文:「整条链路能从落盘状态恢复,不依赖『App 一直活着』。
/// 做不到这一条,再多后台权限也救不了。」——**先把这条做对,后台配置最后加**。
///
/// ## 编排口径对齐 `scripts/run_single_session.py`
///
/// 分块(录音内核边录边落)→ VAD → 上传 → 转写 → 冻结 → 抽取。
/// 那个脚本是 M0-12a 跑通过的参照,**不在这里重新发明一套顺序**。
///
/// ## 每一步都必须幂等
///
/// 重放会发生,而且很频繁。判据:同一个 `tick` 连跑两次,第二次不该产生
/// 任何新的副作用 —— 尤其**不该再花一次钱**(见 `ASRJobStore`)。
enum ProcessingOrchestrator {

    /// 一次 tick 做了什么。供编排、测试和设置页的最近处理记录使用。
    /// 正常等待必须和真正失败分开。
    enum Outcome: Equatable {
        case idle                                   // 没有可跑的任务
        case uploaded(sessionID: Int64, blocks: [Int])
        /// 交给系统了、还没回话。**既不是完成也不是失败** —— 有它在就说明
        /// 这一场还得再来看一眼,而「再来看一眼」可能发生在几小时后的另一个进程里。
        case waitingForUpload(sessionID: Int64, inFlight: Int)
        case held(sessionID: Int64, reason: String) // 闸不通过,不是失败
        case submitted(sessionID: Int64, blocks: [Int])
        case waitingForASR(sessionID: Int64, pending: Int)
        /// 云端任务已排队、产物尚未返回。等待不会计为失败。
        case waitingForExtraction(sessionID: Int64, transcriptID: Int64, part: Int)
        case waitingForVoiceprint(sessionID: Int64)
        case frozen(sessionID: Int64, lines: Int, status: String)
        /// 抽完了。`items` 是**落库的**条目数(丢弃的已剔除),
        /// `discarded` 单独带出来 —— 丢了多少必须看得见,不能只报「成功」。
        case extracted(sessionID: Int64, items: Int, discarded: Int)
        /// 比完了。`silent` 静默入脉络、`cards` 出确认卡、`failures` 校验没过的条数。
        /// **三个数都要带出来** —— 只报「成功」的话,「这一场没有进展」与
        /// 「模型说了五条但一条都过不了校验」长得一模一样。
        case progressed(sessionID: Int64, silent: Int, cards: Int, failures: Int)
        /// 声纹判完并合并(M2-认8)。四个数都带 —— 「一个都没认出」与
        /// 「Mac 没跑」在界面上必须分得开。
        case speakersJudged(sessionID: Int64, matched: Int, anonymous: Int, tagged: Int)
        case failed(sessionID: Int64?, error: String)
    }

    /// 任务表里的 kind。
    enum Kind {
        static let upload = BlockUploader.taskKind      // "upload_audio"
        static let transcribe = "transcribe"
        static let extract = "extract"
        /// 进展归属(M2-B3)。
        ///
        /// 🔴 **它必须是一种独立的任务,不能挂在抽取那一步里。**
        /// 抽取花钱、进展也花钱 —— 合在一起的话,进展失败后的每一次重试
        /// 都会**把抽取一起重跑**,而 `ExtractionRunner` 的去重只保证不重复落库,
        /// 挡不住重复调用。这个仓在「重放 = 重复付费」上栽过不止一次
        /// (`ASRJobStore.claim` 那道闸就是为它建的)。
        static let progress = "progress"
        /// 声纹认人(M2-认8):排队给 Mac 判、取回合并。**执行方只有 Mac**
        /// (方案 §3.1 单执行方),手机侧只出题、收卷。
        static let voiceprint = "voiceprint"
    }

    /// 一块提交出去之后,**最多等这么久**(M1-30 ②)。
    ///
    /// 🔴 **不设它的后果**:上游一直回「还在算」或一直回**看不懂的报文**时,
    /// 这一场会**永远**停在「整理中」—— 任务回 `queued`、`attempts` 不加、
    /// 永不 `dead`,而 `last_error` 每拍被覆盖。本仓历史上出过两次这个形状。
    ///
    /// ⚠️ **`.unknown` 尤其救不回来**:它是「报文形状不认识」,
    /// 同一份报文每拍都会得到同一个结论 —— 重试**永远**不会成功。
    /// 而云代理那道 6 小时兜底只覆盖「已提交但还没出结果」的,
    /// **覆盖不到「出了结果但看不懂」的**。
    ///
    /// 🔴 **8 小时这个数不是拍的,是被两个已有时限夹出来的**:
    /// | 谁 | 多久 | 干什么 |
    /// |---|---|---|
    /// | `mac/asr_fallback.py` 的 `STUCK_AFTER_SEC` | 10 分钟 | 换 SSE 兜底 |
    /// | `worker/src/collector.js` 的 `PENDING_TTL_MS` | 6 小时 | 云端判失败 |
    /// | **这里** | **8 小时** | 手机放弃 |
    ///
    /// **顺序必须是这个顺序**:手机放弃得比兜底晚,否则**兜底还没来得及救,
    /// 手机已经判了失败** —— 而那个现场与「上游真的挂了」一模一样。
    /// ⚠️ 三个数在三种语言里,交叉了**没有任何东西会报错**(铁律 4)
    /// ⇒ `eval/checks/test_stall_thresholds.py` 扫源码钉住这个次序。
    static let asrStallMinutes = 8 * 60

    /// 录音结束时调一次:把这一场排进队列。
    ///
    /// **幂等**:同一场调两次只会有一个上传任务 —— 靠的是先查再插,
    /// 而不是靠调用方记得只调一次(调用方会被重放)。
    @discardableResult
    static func enqueueSession(_ sessionID: Int64, now: String,
                               in writer: some DatabaseWriter) throws -> Bool {
        try writer.write { db in
            let existing = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tasks WHERE session_id = ? AND kind = ?
                """, arguments: [sessionID, Kind.upload]) ?? 0
            guard existing == 0 else { return false }
            try db.execute(sql: """
                INSERT INTO tasks (kind, session_id, state, priority, created_at, attempts)
                VALUES (?, ?, 'queued', 0, ?, 0)
                """, arguments: [Kind.upload, sessionID, now])
            return true
        }
    }

    // MARK: - 再试一次(M1-13d)

    struct Revival: Equatable {
        /// 重新排上队的任务数。0 表示这一场没有死掉的任务。
        let tasks: Int
        /// 提前放行的「正在重试」任务数。
        ///
        /// 🔴 与 `tasks` **分开报**,因为两者的代价完全不同:复活 dead 要重新
        /// 提交转写(**花钱**),放行只是把退避的计时器归零(不花钱、不动 attempts)。
        /// 合成一个数的话,二次确认里那句「会花钱」就有一半是假的。
        let released: Int
        /// 清掉的失败转写作业数 —— **它们会被重新提交,而提交是花钱的**。
        let resubmittedBlocks: Int
    }

    struct RetryableSession: Identifiable, Equatable {
        let id: Int64
        let startedAt: String
        let issue: String
        let blockedReason: String?
    }

    /// 旧的非流式 partial 不能通过再次提交填入已有冻结层；先拦住无效付费。
    private static func retryBlockedReason(_ sessionID: Int64, in db: Database) throws -> String? {
        let resumesASR = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM asr_jobs WHERE session_id = ? AND state = 'failed')
                OR EXISTS(SELECT 1 FROM tasks k WHERE k.session_id = ? AND k.kind = 'transcribe'
                          AND (\(retryableTaskPredicate)))
            """, arguments: [sessionID, sessionID]) ?? false
        // 重排整理／归属／声纹本身不改原话，不能被原话版本误拦。
        guard resumesASR else { return nil }
        let partial = try Bool.fetchOne(db, sql: """
            SELECT (EXISTS(SELECT 1 FROM transcripts WHERE session_id = ? AND status = 'partial')
                    AND NOT EXISTS(SELECT 1 FROM stream_sessions WHERE session_id = ?))
                OR (EXISTS(SELECT 1 FROM stream_sessions WHERE session_id = ?)
                    AND COALESCE((SELECT MAX(version) FROM transcripts WHERE session_id = ?),0) > ?)
            """, arguments: [sessionID, sessionID, sessionID, sessionID, TranscriptFreeze.firstVersion]) ?? false
        return partial ? "这份录音已有需要保留的原话版本，补齐需要保全原有标注，暂不能直接重试。原录音和已有内容仍保留。" : nil
    }

    private static let retryableTaskPredicate = """
        k.state IN ('dead','degraded') OR
        (k.state = 'retrying' AND k.priority = 0 AND k.next_retry_at IS NOT NULL)
        """

    /// 跨日期读取实际可重试的处理任务；不把语义事件列表退回录音列表。
    static func retryableSessions(in reader: some DatabaseReader) throws -> [RetryableSession] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.id, s.started_at,
                    COALESCE((SELECT NULLIF(k.last_error,'') FROM tasks k
                              WHERE k.session_id = s.id AND (\(retryableTaskPredicate))
                              ORDER BY CASE k.state WHEN 'dead' THEN 0 WHEN 'degraded' THEN 1 ELSE 2 END,
                                       k.task_id DESC LIMIT 1), '有录音片段未能处理，可以重试') AS issue
                FROM sessions s
                WHERE NOT (\(MemoryRemoval.removedSessionPredicate)) AND (
                    EXISTS(SELECT 1 FROM tasks k WHERE k.session_id = s.id AND (\(retryableTaskPredicate)))
                    OR (EXISTS(SELECT 1 FROM stream_sessions WHERE session_id = s.id)
                        AND EXISTS(SELECT 1 FROM asr_jobs WHERE session_id = s.id AND state = 'failed')
                        AND EXISTS(SELECT 1 FROM tasks WHERE session_id = s.id AND kind = 'transcribe'
                                   AND state IN ('queued','retrying','waiting_network','done'))))
                ORDER BY julianday(s.started_at) DESC, s.id DESC
                """).map { row in
                    try RetryableSession(id: row["id"], startedAt: row["started_at"], issue: row["issue"],
                        blockedReason: retryBlockedReason(row["id"], in: db))
                }
        }
    }

    /// 用户说「再试一次」。
    ///
    /// ## 口径:**重置这一行,不插新行**
    ///
    /// 任务行按 `(session_id, kind)` 查重,全仓三处 `NOT EXISTS` 都依赖
    /// 「一场一个任务」这条不变式。插新行等于让那三处同时失效,
    /// 换来的只是留住一行 `attempts`。
    ///
    /// 失败历史不丢 —— 它去 `processing_events`,那张表本来就是
    /// 「最近真的发生了什么」。**队列行是工作台,不是账本。**
    ///
    /// `attempts` 归 0 是刻意的:手动重试是一次新的开始。留着 27 次的话,
    /// 下一次失败会立刻再判 dead —— 那等于按钮没按。
    ///
    /// ## 🔴 只重置任务行是不够的,那会是个假按钮
    ///
    /// 最常见的 degraded 是「一块都没转出来」。只把任务打回 `queued` 的话:
    /// 提交那一步看见 `asr_jobs` 里已有行就 `continue`(去重),
    /// 轮询那一步只捡 `submitted`,冻结那一步还是拿不到 `done` ⇒ **原地又 degraded**。
    /// 所以失败的作业行要一并清掉,让它们重新提交。
    ///
    /// ⚠️ **重新提交是花钱的**(`ASRJobStore.finish` 的注释就写着这句)。
    /// 调用方必须在二次确认里说出来 —— 这是本仓唯一一个由用户**主动**触发花钱的动作。
    @discardableResult
    static func retrySession(_ sessionID: Int64, now: String,
                             in writer: some DatabaseWriter) throws -> Revival {
        let (r, detail) = try writer.write { db -> (Revival, String?) in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sessions s WHERE s.id = ? AND NOT (\(MemoryRemoval.removedSessionPredicate)))", arguments: [sessionID]) == true else {
                throw ContinuousIngestion.Failure.invalid("录音已移出记忆或不存在，不能重新处理")
            }
            if let reason = try retryBlockedReason(sessionID, in: db) {
                throw ContinuousIngestion.Failure.invalid(reason)
            }
            // 🔴 **先放行「正在重试」的。** 2026-08-19 加。
            //
            // 在此之前,`retrying` 的任务用户**没有任何办法让它现在就试** ——
            // 界面上那颗「再试一次」只动 dead / degraded,按下去只会回一句
            // 「它还在自己重试,再等等」。08-18 那两场就卡在这儿:退避已经
            // 躺到 6 小时封顶,而网络早就好了,用户看着一个不肯动的按钮。
            //
            // 放行**不花钱、不动 attempts**:只是把退避的计时器归零。
            // attempts 留着是因为它是 6 天总期限那条判据的一半 —— 清零等于
            // 让一条永远好不了的任务只要用户多点几次就永远不会 dead。
            // ⚠️ **不在这里写第二份 SQL。** 对抗审查抓到过:这里原本内联了一份,
            // 少了 `priority = 0` 那个条件,于是「什么叫放行」有两个答案,
            // 而**对不上时不会有任何东西红**(第四条铁律点名的形状)。
            let released = try TaskQueue.releaseBackoff(sessionID: sessionID, in: db)

            // 开着的流仍会轮询后续块，失败的前块尚未冻结；手动重试也必须能清掉它。
            if try ContinuousIngestion.isStreaming(sessionID, in: db) {
                try db.execute(sql: """
                    UPDATE tasks SET state = 'degraded', last_error = '有分片转写失败，手动重试'
                     WHERE session_id = ? AND kind = 'transcribe' AND state IN ('queued','retrying','waiting_network','done')
                       AND EXISTS(SELECT 1 FROM asr_jobs WHERE session_id = ? AND state = 'failed')
                    """, arguments: [sessionID, sessionID])
            }

            // 先立墓志铭再重置 —— 反过来的话 attempts 与 last_error 已经没了。
            let epitaphs = try Row.fetchAll(db, sql: """
                SELECT kind, state, attempts, last_error FROM tasks
                 WHERE session_id = ? AND state IN ('dead', 'degraded')
                """, arguments: [sessionID])
            guard !epitaphs.isEmpty else {
                return (Revival(tasks: 0, released: released, resubmittedBlocks: 0),
                        released > 0 ? "放行 \(released) 个正在重试的任务(不花钱)" : nil)
            }

            try db.execute(sql: """
                DELETE FROM asr_jobs WHERE session_id = ? AND state = 'failed'
                """, arguments: [sessionID])
            let blocks = db.changesCount

            try db.execute(sql: """
                UPDATE tasks
                   SET state = 'queued', attempts = 0, next_retry_at = NULL, last_error = NULL
                 WHERE session_id = ? AND state IN ('dead', 'degraded')
                """, arguments: [sessionID])

            let epitaph = epitaphs.map {
                "\($0["kind"] as String? ?? "?")(\($0["state"] as String? ?? "?")"
                + " · \($0["attempts"] as Int? ?? -1) 次):\($0["last_error"] as String? ?? "没说原因")"
            }.joined(separator: " · ")
            return (Revival(tasks: epitaphs.count, released: released, resubmittedBlocks: blocks),
                    "重置前:\(epitaph)。清掉 \(blocks) 块失败的转写作业(会重新提交,花钱)。"
                    + (released > 0 ? " 另放行 \(released) 个正在重试的任务(不花钱)。" : ""))
        }
        if let detail {
            ProcessingEvents.record(
                trigger: .foreground,
                outcome: "场次 \(sessionID) 手动重试 \(r.tasks) 个任务 · 放行 \(r.released) 个",
                detail: detail, in: writer)
        }
        return r
    }

    // MARK: - 一拍

    /// 跑一拍。**做一步就返回** —— 不在一个 tick 里把整条链跑完。
    ///
    /// 理由是可中断:后台唤醒给的时间是有限的,而「做一步就落盘」意味着
    /// 任何时候被打断都不会丢进度。一口气跑完的写法在被杀时会退回上一个落盘点,
    /// 而那个点可能在十分钟之前。
    static func tick(now: Date, deps: Dependencies,
                     in writer: some DatabaseWriter) async throws -> Outcome {
        let iso = ISO8601DateFormatter.growth.string(from: now)
        guard let taskID = try TaskQueue.nextRunnable(now: iso, in: writer) else {
            return .idle
        }
        let row = try await writer.read { db in
            try Row.fetchOne(db, sql: "SELECT kind, session_id FROM tasks WHERE task_id = ?",
                             arguments: [taskID])
        }
        guard let row, let sessionID = row["session_id"] as Int64? else {
            // 没有场次的任务跑不了。**标死而不是无限重试** ——
            // 它每被捡起一次就挡住一次真任务,而它永远不会成功。
            try await writer.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET state = 'dead', last_error = '任务没有 session_id'
                     WHERE task_id = ?
                    """, arguments: [taskID])
            }
            return .failed(sessionID: nil, error: "任务 \(taskID) 没有 session_id")
        }

        // 🔴 **任务被取走去跑,就必须以三种终态之一收场:done / 失败记账 / 明确让出。
        // 「抛出」不是终态。**
        //
        // 在这道 catch 之前它就是:`runX` 抛出 → 一路抛穿 `tick` → 被 `pump` 的
        // do/catch 接住 → 只记一条事件 → **任务留在 `running`、`attempts` 不加**
        // ⇒ `stateAfterFailure` 那道「烧到 dead」的保险丝**根本不通电**。
        //
        // ⚠️ **实测代价(2026-08-25 真机拉库)**:任务 74(`transcribe` / 某场次)
        // 在 `running` 上活了**五天**,`attempts` 始终 0。每一拍:
        // `reclaimInterrupted` 把它捡回 → 它按 `(priority, task_id)` **永远赢排序**
        // → 撞同一个 `UNIQUE(session_id, version, part)` → 抛 → 回到 `running`。
        // 而今天那场录音的上传任务(91)排在它后面,`attempts = 0` 等了六小时,
        // **一块音频都没传上去** —— 界面上就是一直「转写中」。
        //
        // 🔴 **`M2-B9`(把 `running` 捡回来)让这件事从「躺尸」变成了「绞肉机」**:
        // 修之前那个任务只是不动,不挡别人;修之后它每拍复活一次、每拍失败一次,
        // 把整条队列饿死。两个都是缺陷,而第二个更贵 —— 它是**沉默的**。
        //
        // ⚠️ 记账是尽力而为(`try?`):记不上也要把原异常抛出去,
        // 别让「记账失败」把「任务失败」这件事本身吃掉。
        do {
            return try await dispatch(row["kind"] as String?, taskID, sessionID, now, iso, deps, writer)
        } catch {
            try? TaskQueue.recordFailure(taskID: taskID, error: "\(error)", at: now, in: writer)
            throw error
        }
    }

    private static func dispatch(_ kind: String?, _ taskID: Int64, _ sessionID: Int64,
                                 _ now: Date, _ iso: String, _ deps: Dependencies,
                                 _ writer: some DatabaseWriter) async throws -> Outcome {
        switch kind {
        case Kind.upload:     return try await runUpload(taskID, sessionID, now, iso, deps, writer)
        case Kind.transcribe: return try await runTranscribe(taskID, sessionID, iso, deps, writer)
        case Kind.extract:    return try await runExtract(taskID, sessionID, now, iso, deps, writer)
        case Kind.progress:   return try await runProgress(taskID, sessionID, now, iso, deps, writer)
        case Kind.voiceprint: return try await runVoiceprint(taskID, sessionID, iso, deps, writer)
        case let other:
            try await writer.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET state = 'dead', last_error = ? WHERE task_id = ?
                    """, arguments: ["不认识的任务类型:\(other ?? "nil")", taskID])
            }
            return .failed(sessionID: sessionID, error: "不认识的任务类型:\(other ?? "nil")")
        }
    }

    /// 这一场还在录吗。**「还会不会有新块」这个判断只有这一个出处** ——
    /// 上传腿(还要不要留着)与转写腿(能不能冻结)都读它,
    /// 各写一份的话迟早一边认为录完了、另一边还在等(第四条铁律)。
    /// 上游是不是明说「不认识这个 task_id」。
    ///
    /// 🔴 **判据只认上游自己的话,不猜。** StepFun 对不认识的任务回
    /// `400 {"error":{"message":"task not found","type":"request_params_invalid"}}`,
    /// 而云代理把原文透传在 `body` 里(`worker/src/index.js` 的 `query`)。
    /// ⚠️ 放宽到「任何 400」是不行的:参数写错也是 400,而那种**重提一万次也没用**,
    /// 只会一次次买单。宁可漏判(退回普通失败,行为与今天一样)也不错判。
    static func upstreamForgotTheTask(_ reason: String) -> Bool {
        reason.contains("task not found")
    }

    private static func stillRecording(_ sessionID: Int64,
                                       _ reader: some DatabaseReader) async throws -> Bool {
        try await reader.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM sessions WHERE id = ?",
                                arguments: [sessionID])
        } == SessionBridge.Status.open
    }

    // MARK: - 上传

    private static func runUpload(_ taskID: Int64, _ sessionID: Int64, _ now: Date,
                                  _ iso: String, _ deps: Dependencies,
                                  _ writer: some DatabaseWriter) async throws -> Outcome {
        let blocks = try deps.blocks(sessionID)
        let recording = try await stillRecording(sessionID, writer)
        guard !blocks.isEmpty else {
            // 🔴 **还在录的场次「暂时还没有块」是正常的**,不是失败。
            // 第一块要 4.5–5.5 分钟才切出来,而边录边传意味着任务在那之前
            // 就已经排上了。这里标死的话,这一场的音频**永远不会被传**。
            guard !recording else {
                try await writer.write { db in
                    try db.execute(sql: """
                        UPDATE tasks SET state = 'queued', last_error = NULL, next_retry_at = ?
                         WHERE task_id = ?
                        """, arguments: [nextPoll(iso, deps), taskID])
                }
                return .waitingForUpload(sessionID: sessionID, inFlight: 0)
            }
            // 已经封场了还一块都没有 —— 那才是真失败。标死并说清楚,
            // 悄悄标 done 的话,下游会等一份永远不来的转写。
            try await writer.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET state = 'dead', last_error = '这一场一块音频都没有'
                     WHERE task_id = ?
                    """, arguments: [taskID])
            }
            return .failed(sessionID: sessionID, error: "这一场一块音频都没有")
        }

        let r = try BlockUploader.run(taskID: taskID, sessionID: sessionID, blocks: blocks,
                                      reachability: deps.reachability(), wifiOnly: deps.wifiOnly,
                                      ext: deps.audioExt,
                                      // 还在录 ⇒ 已知的块传完了也不算这一场传完
                                      moreBlocksComing: recording,
                                      at: now,
                                      transport: deps.transport,
                                      trigger: deps.trigger,
                                      // 「等传输完成」和「等转写完成」是同一件事:
                                      // 还没好,隔一会儿再看。两个各写各的间隔迟早会漂。
                                      pollInterval: deps.pollInterval, in: writer)
        if let held = r.heldReason { return .held(sessionID: sessionID, reason: held) }
        if let failed = r.failed { return .failed(sessionID: sessionID, error: failed) }
        // 还有在传的 → **不排转写**。转写要拿 R2 上的对象去提交,
        // 而那个对象还没落地 —— 提前提交换来的是 StepFun 报 invalid audio url,
        // 一次白花的调用。
        if r.inFlight > 0 { return .waitingForUpload(sessionID: sessionID, inFlight: r.inFlight) }

        // 传完了 → 排转写。**在同一个事务里**:上传标 done 而转写没排上的话,
        // 这一场就永远停在「传完了但没人管」,而任务表看起来一切正常。
        //
        // 🔴 **还在录也要排。** 转写腿自己会挡住冻结(见 `runTranscribe` 末尾),
        // 所以让它现在就把已经传上去的块提交出去 —— 等用户按下结束时,
        // 前面几块的文字多半已经回来了。这就是「边录边传」的那一半价值:
        // 传是省时间,提交是省等待。
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (kind, session_id, state, priority, created_at, attempts)
                SELECT ?, ?, 'queued', 0, ?, 0
                 WHERE NOT EXISTS (SELECT 1 FROM tasks WHERE session_id = ? AND kind = ?)
                """, arguments: [Kind.transcribe, sessionID, iso, sessionID, Kind.transcribe])
        }
        return .uploaded(sessionID: sessionID, blocks: r.uploaded)
    }

    // MARK: - 转写

    /// 提交没提交过的块 → 轮询在跑的 → 全好了就冻结。
    ///
    /// 三件事在一个任务里,因为它们共享同一个「这一场的块」清单,
    /// 而拆成三个任务要在任务表里再造两个 kind 与两次状态迁移 —— 没有换来任何东西。
    private static func runTranscribe(_ taskID: Int64, _ sessionID: Int64, _ iso: String,
                                      _ deps: Dependencies,
                                      _ writer: some DatabaseWriter) async throws -> Outcome {
        guard deps.proxy != nil else {
            return try await parkUntilConfigured(taskID, sessionID, iso, deps, writer)
        }

        try await writer.write { db in
            try db.execute(sql: "UPDATE tasks SET state = 'running' WHERE task_id = ?",
                           arguments: [taskID])
        }
        // 这一拍真实走掉多久,只有墙钟知道;下面算退避起点要用它。
        let began = Date()
        var workFinishedAt: String {
            ISO8601DateFormatter.growth.string(from: (ISO8601DateFormatter.growth.date(from: iso) ?? began)
                .addingTimeInterval(Date().timeIntervalSince(began)))
        }

        // 🔴 **先取结果,再提交。这个顺序是 2026-08-19 改的,不是风格问题。**
        //
        // 原来是「先把没提交的块全提交完,再轮询」,而提交任意一块失败就
        // `recordFailure` 让整条任务回退。08-18 实测的后果:某场次 共七块,
        // 炸在第 4 块 —— 前三块的转写结果**早就在云端躺着**(41 KB / 51 KB 的正文),
        // 而手机每一轮都在同一块上重新炸掉,一次都没走到轮询那一步。
        // 等于**为了一块没提交出去的音频,把已经花钱买到的三块一起扣着**。
        //
        // 取结果不花钱,也不依赖任何还没提交的块 —— 它没有理由排在提交后面。
        let uploadedSeqs = Set(try UploadJobStore.all(sessionID: sessionID, in: writer)
            .filter { $0.state == "done" }.map(\.blockSeq))

        // 这一拍遇到的网络失败。**攒起来,最后只记一次。**
        // 每块记一次的话,七块全炸就把 attempts 烧掉七次 —— 一次网络抖动
        // 直接把任务推向 dead(见 `TaskQueue.stateAfterFailure` 的两条判据)。
        var troubles: [String] = []
        var unknowns: [String] = []

        // ① 取已经提交出去那些块的结果
        for job in try ASRJobStore.pending(sessionID: sessionID, in: writer) {
            let answer: ProxyClient.QueryResult
            let t0 = Date()
            do {
                answer = try await deps.query(job.remoteID)
            } catch {
                // 🔴 **记下来,继续下一块。** 原来是 `return` —— 一块查不通,
                // 后面几块连问都不问,而它们的结果可能早就好了。
                troubles.append("轮询 \(job.remoteID)(等了 \(spent(since: t0))):\(error)")
                continue
            }
            switch answer {
            case .pending:
                try giveUpIfStalled(job, kind: "上游一直说还在算", detail: "",
                                    iso: iso, in: writer)
                continue
            case .unknown(let body):
                // 看不懂的报文按 pending 处理(不敢当成功),**但留痕** ——
                // 不留的话「上游还在算」和「这条路根本走不通」在库里长得一模一样,
                // 而后者会一直「还在跑」到任务超期,期间没有任何地方说得出为什么。
                unknowns.append("块 \(job.blockSeq):\(body.prefix(200))")
                try giveUpIfStalled(job, kind: "报文看不懂", detail: String(body.prefix(200)),
                                    iso: iso, in: writer)
                continue
            case .done(let raw):
                try ASRJobStore.finish(sessionID: sessionID, blockSeq: job.blockSeq,
                                       resultJSON: raw, now: iso, in: writer)
            case .failed(let why):
                // 失败**记在作业上,不是记在任务上** —— 一块转不出来不等于整场失败,
                // 而 §3.1.6 允许缺块以 partial 落库。
                try ASRJobStore.fail(sessionID: sessionID, blockSeq: job.blockSeq,
                                     error: why, now: iso, in: writer)
            }
        }

        // ② 提交还没提交过的块。**去重在 `ASRJobStore`,不在这里** ——
        //    这个函数会被重放很多遍,而提交是花钱的。
        // 🔴 **只提交真的传上去了的块。**
        // 上传层会跳过永久坏掉的块(音频读不出来),让这一场以 partial 落库;
        // 而提交一个 R2 里不存在的键 = 花一次钱换 StepFun 一句「下载不了」。
        let ledger = try deps.blocks(sessionID)
        let candidates = Set(ledger.map(\.blockSeq)).intersection(uploadedSeqs)
        let known = Set(try ASRJobStore.all(sessionID: sessionID, in: writer).map(\.blockSeq))
        // 🔴 **按块序去重再遍历。** 账本里同一个 seq 出现两次是这个仓库
        // 已经承认可能发生的形态(`ProcessingPump` 那边专门用 `uniquingKeysWith:`
        // 防过它,而 `BlockLedger.sessions` 只是 append、不去重)。
        // 直接遍历账本的话,重复的那一块会被**提交两次 = 付两次钱**。
        // 手机侧原本靠「每块提交前重查一次 asr_jobs」挡着,改成循环前取快照之后
        // 那道闸就没了 —— 现在只剩云代理那道幂等闸,而板上刚写下
        // 「手机侧没有第二道闸」。至少别把本来就有的这道主动丢掉。
        let firstBySeq = Dictionary(ledger.map { ($0.blockSeq, $0) }, uniquingKeysWith: { a, _ in a })

        var submitted: [Int] = []
        for seq in candidates.sorted() where !known.contains(seq) {
            guard let block = firstBySeq[seq] else { continue }
            let key = R2Layout.audioKey(sessionID: sessionID, blockSeq: block.blockSeq,
                                        ext: deps.audioExt)
            let t0 = Date()
            do {
                let remote = try await deps.submit(key, deps.seconds(block))
                let claim = try ASRJobStore.claim(sessionID: sessionID, blockSeq: block.blockSeq,
                                                  remoteID: remote, now: iso, in: writer)
                if claim.inserted { submitted.append(block.blockSeq) }
            } catch {
                // 🔴 **记下来,继续下一块。** 原来是 `return` —— 于是失败那一块
                // 之后的所有块**永远轮不到提交**。（场次略） 的第 5/6/7 块从头到尾
                // 一次都没被提交过,而任务表上只说「提交第 4 块失败」。
                troubles.append("提交 \(key)(等了 \(spent(since: t0))):\(error)")
                continue
            }
        }

        if !unknowns.isEmpty {
            // 写进任务的 last_error:它是「这个任务最近发生了什么」唯一看得见的地方。
            // 状态**不动**(还是等),只是把看不懂的原文摆出来。
            try await writer.write { db in
                try db.execute(sql: "UPDATE tasks SET last_error = ? WHERE task_id = ?",
                               arguments: ["转写查询回了看不懂的报文(仍按未完成处理):"
                                         + unknowns.joined(separator: " | "), taskID])
            }
        }

        // ③ 这一拍落在哪
        let jobs = try ASRJobStore.all(sessionID: sessionID, in: writer)
        let stillPending = jobs.filter { $0.state == .submitted }
        // Watch 完成分片在整场冻结闸之前接入，后续块只追加新的 part。
        let stream = try deps.ingestCompletedBlocks?(sessionID, jobs)
        // 🔴 **冻结前的守卫:传上去了、却一条转写作业都没有的块。**
        // 只看 `pending` 空不空是不够的 —— 提交失败的块压根没进 `asr_jobs`,
        // 在 pending 里同样看不见。两者长得一模一样,而处置完全相反:
        // 前者可以冻结,后者冻结就是**把那块音频悄悄丢了,而且不报错**。
        // 这是本仓最贵的失败形态,新的容错顺序如果不配这道守卫就会造出它。
        // `lost` 的块要重新排进提交队列 —— 作业行留着(为了那个重提计数),
        // 但那一行记的是一个**上游已经不认识**的 task_id,不能算数。
        let lostSeqs = Set(jobs.filter { $0.state == .lost }.map(\.blockSeq))
        let neverSubmitted = candidates
            .subtracting(jobs.map(\.blockSeq))
            .union(candidates.intersection(lostSeqs))
        if !neverSubmitted.isEmpty && troubles.isEmpty {
            // 走到这里说明上面的提交循环既没给它建作业、也没报错 —— 不该发生。
            // **变成一条看得见的失败**,而不是在下面那个分支里无限等下去:
            // 无限等不烧 attempts,永远不会 dead,用户看到的是永远「整理中」。
            troubles.append("这些块传上去了却没有转写作业,也没报错:\(neverSubmitted.sorted())")
        }

        if !troubles.isEmpty {
            // 一拍只记一次失败。`.failed` 不等于这一场废了 ——
            // 这一拍拿到的结果都已经落盘,退避之后接着往下走。
            // 🔴 **退避从「真的失败了」那一刻算,不是从这一拍开始那一刻算。**
            //
            // 一拍现在可能连着发好几个网络请求,每个最长 90 秒 —— 七块全超时
            // 就是十分钟。用这一拍开始的时刻去加 1 分钟,算出来的「下次重试时刻」
            // **已经是过去**,于是下一拍立刻又跑 ⇒ 退避形同虚设,attempts 被
            // 快速烧向 dead,而看起来一切正常。
            //
            // ⚠️ 写法上**不能直接用 `Date()`** —— 那会把注入的时钟(`now:`)
            // 和真实时钟混在一起,测试就再也控制不了时间了。本仓在时间口径上
            // 栽过一次(2026-08-17 退避因时区串比较而整体失效),所以这里
            // 老老实实用「注入的起点 + 这一拍真实走掉的时长」。
            try TaskQueue.recordFailure(
                taskID: taskID,
                error: String(troubles.joined(separator: " | ").prefix(500)),
                at: (ISO8601DateFormatter.growth.date(from: iso) ?? began)
                    .addingTimeInterval(Date().timeIntervalSince(began)),
                in: writer)
            return .failed(sessionID: sessionID, error: troubles.joined(separator: " | "))
        }

        if !stillPending.isEmpty || !neverSubmitted.isEmpty {
            // 还没齐 —— 退避后再来。attempts **不加**:等云上算完不是失败。
            //
            // ⚠️ **提交完必须把任务放回可跑状态。** 上面把它置成了 `running`,
            // 而 `nextRunnable` 只捡 queued/retrying/waiting_network ——
            // 不放回去的话这一场就永远停在「提交出去了但没人去取结果」,
            // 而任务表看起来一切正常(状态是 running,像是在干活)。
            try await writer.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET state = 'queued', next_retry_at = ? WHERE task_id = ?
                    """, arguments: [nextPoll(workFinishedAt, deps), taskID])
            }
            return submitted.isEmpty
                ? .waitingForASR(sessionID: sessionID, pending: stillPending.count)
                : .submitted(sessionID: sessionID, blocks: submitted)
        }

        // ④ 持续流的完成分片已在上面追加；整场仍等手表收尾。旧场次才走一次性整场冻结。
        //
        // 🔴 冻结是**一次性、不可回改**的(冻结层的触发器把 UPDATE/DELETE 直接
        // RAISE(ABORT)),而这一场后面还会切出新块。冻在半截等于把这一场
        // 永久截断成前半段,**而且不报错** —— 后面那些块的转写将来无处可去。
        // 边录边传只解锁「传」和「提交」,不解锁「冻」。
        guard !(try await stillRecording(sessionID, writer)) else {
            try await writer.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET state = 'queued', next_retry_at = ? WHERE task_id = ?
                    """, arguments: [nextPoll(workFinishedAt, deps), taskID])
            }
            return .waitingForASR(sessionID: sessionID, pending: 0)
        }
        if stream != nil {
            return try await finishStream(taskID, sessionID, workFinishedAt, deps, writer)
        }
        return try await freeze(taskID, sessionID, iso, deps, writer)
    }

    private static func finishStream(_ taskID: Int64, _ sessionID: Int64, _ iso: String,
                                     _ deps: Dependencies,
                                     _ writer: some DatabaseWriter) async throws -> Outcome {
        let expected = Set(try deps.blocks(sessionID).map(\.blockSeq))
        let received = try await writer.read { db in
            try Int.fetchSet(db, sql: "SELECT block_seq FROM stream_blocks WHERE session_id = ?", arguments: [sessionID])
        }
        guard !expected.isEmpty, expected.isSubset(of: received) else {
            let failed = Set(try ASRJobStore.all(sessionID: sessionID, in: writer).filter { $0.state == .failed }.map(\.blockSeq))
            let missing = expected.subtracting(received)
            let blocked = !missing.intersection(failed).isEmpty
            try await writer.write { db in
                try db.execute(sql: "UPDATE tasks SET state = ?, last_error = ?, next_retry_at = ? WHERE task_id = ?",
                               arguments: [blocked ? "degraded" : "queued",
                                 blocked ? "有分片转写失败，已保留录音；重试后继续接入" : "收尾已收到，仍在等待尾部录音转写",
                                 blocked ? nil : nextPoll(iso, deps), taskID])
            }
            return blocked ? .failed(sessionID: sessionID, error: "有分片未转写，重试后继续接入")
                : .waitingForASR(sessionID: sessionID, pending: missing.count)
        }
        let counts = try await writer.write { db -> (Int, Bool) in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.status, (SELECT COUNT(*) FROM transcript_lines WHERE transcript_id = t.id) AS n
                  FROM transcripts t JOIN stream_blocks b ON b.transcript_id = t.id WHERE b.session_id = ?
                """, arguments: [sessionID])
            guard !rows.isEmpty else { throw ContinuousIngestion.Failure.invalid("收尾后没有已接入分片") }
            let partial = rows.contains { $0["status"] as String == "partial" }
            try db.execute(sql: "UPDATE stream_sessions SET finished_at = COALESCE(finished_at, ?) WHERE session_id = ?", arguments: [iso, sessionID])
            try db.execute(sql: "UPDATE tasks SET state = ?, last_error = ? WHERE task_id = ?",
                           arguments: [partial ? "degraded" : "done", partial ? "部分分片缺失，已保留可用内容" : nil, taskID])
            try ContinuousIngestion.enqueue(Kind.voiceprint, sessionID: sessionID, now: iso, in: db)
            try ContinuousIngestion.enqueue(Kind.extract, sessionID: sessionID, now: iso, in: db)
            return (rows.reduce(0) { $0 + ($1["n"] as Int) }, partial)
        }
        return .frozen(sessionID: sessionID, lines: counts.0, status: counts.1 ? "partial" : "frozen")
    }

    /// 下一次来看结果的时刻。云上还在算不是失败,所以只推迟、不加 attempts。
    /// 「云代理还没配」—— **三条腿唯一的一种写法。**
    ///
    /// 🔴 这不是重构洁癖,是一条实打实的堵塞。转写腿原先把 `next_retry_at`
    /// 置成 `iso`(**就是「现在」**),而 `nextRunnable` 按 `priority, task_id` 排序、
    /// 所有任务 priority 都是 0 ⇒ **每一拍都选中它**,一拍 12 步全砸在同一个任务上,
    /// 前台每 30 秒一拍 ⇒ 后面所有任务一次机会都排不到,而它永不 dead。
    ///
    /// 而抽取腿写的是 `nextPoll`(现在 +30 秒),上传腿更糟 —— 抛 `notConfigured`
    /// 走 `recordFailure`、**烧 attempts**,配好之前就把自己烧到 dead 了
    /// (而 dead 没有复活路径,见 M1-13d)。同一个「没配」,三种下场。
    ///
    /// 口径定死:**暂时性 · 不烧 attempts · 退到下一拍之后再看**。
    /// 「没配」不是任务的错,用户填完设置它就该自己跑起来。
    private static func parkUntilConfigured(
        _ taskID: Int64, _ sessionID: Int64, _ iso: String,
        _ deps: Dependencies, _ writer: some DatabaseWriter) async throws -> Outcome {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE tasks SET state = 'retrying', last_error = ?, next_retry_at = ?
                 WHERE task_id = ?
                """, arguments: [Self.notConfiguredReason, nextPoll(iso, deps), taskID])
        }
        return .failed(sessionID: sessionID, error: Self.notConfiguredReason)
    }

/// 云端队列还没把这一块抽完。**不是失败** —— 接住它的地方要 park,不能记 attempts。
    struct ExtractNotReady: Error {
        let transcriptID: Int64
        let part: Int
    }

    static let notConfiguredReason = "云代理还没配"

    /// 「等了 12.3 秒」。**失败原因里必须带上它** —— 「超时」这两个字
    /// 分不出「一秒就断」和「挂满九十秒」,而这两者的修法完全不同:
    /// 前者是根本没连上,后者是连上了对方不回话。
    /// 08-18 那次事故就卡在这个分辨率上:库里只有「请求超时」四个字。
    private static func spent(since: Date) -> String {
        String(format: "%.1f 秒", Date().timeIntervalSince(since))
    }

    private static func nextPoll(_ iso: String,
                                 _ deps: Dependencies) -> String {
        let base = ISO8601DateFormatter.growth.date(from: iso) ?? Date()
        return ISO8601DateFormatter.growth.string(
            from: base.addingTimeInterval(deps.pollInterval))
    }

    private static func freeze(_ taskID: Int64, _ sessionID: Int64, _ iso: String,
                               _ deps: Dependencies,
                               _ writer: some DatabaseWriter) async throws -> Outcome {
        let done = try ASRJobStore.finished(sessionID: sessionID, in: writer)
        guard !done.isEmpty else {
            try await writer.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET state = 'degraded', last_error = '这一场没有一块转写成功'
                     WHERE task_id = ?
                    """, arguments: [taskID])
            }
            return .failed(sessionID: sessionID, error: "这一场没有一块转写成功")
        }
        // 🔴 **已经冻结过就不要再冻一次 —— 那活早就干完了,只是没来得及标 done。**
        //
        // 冻结层是不可变的,而 `transcripts` 上有 `UNIQUE(session_id, version, part)`。
        // 任务在「冻结已写库」与「标 done」之间被打断(App 退出 / 后台时间用完),
        // 重跑时必然撞这个唯一键 —— 而抛出来的是一句
        // `SQLite error 19: UNIQUE constraint failed`,离真因隔着好几跳。
        //
        // ⚠️ 实测:某场次 的转写 08-20 17:55 就落库了,而任务 74 到 08-25
        // 还在每拍重试同一件已经做完的事(真机拉库确认)。
        // ⇒ 判据是**产物在不在**,不是「任务标没标完」——
        // 产物是事实,任务状态只是关于事实的记账,而记账会丢。
        if let existing = try await writer.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT id, status FROM transcripts
                 WHERE session_id = ? AND version = ? AND part = ?
                """, arguments: [sessionID, TranscriptFreeze.firstVersion, TranscriptFreeze.firstPart])
        }) {
            let status: String = existing["status"]
            try await writer.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET state = ?, last_error = ? WHERE task_id = ?
                    """, arguments: [status == "partial" ? "degraded" : "done",
                                     "这一场已经冻结过了(转写 \(existing["id"] as Int64)),"
                                     + "本次不重复冻结 —— 上次是在标完成之前被打断的",
                                     taskID])
            }
            let n = try await writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_lines WHERE transcript_id = ?",
                                 arguments: [existing["id"] as Int64]) ?? 0
            }
            return .frozen(sessionID: sessionID, lines: n, status: status)
        }

        let result = try deps.freeze(sessionID, done)

        // 🔴 **转写回来了、但一行都没有 —— 不许当成功。**
        //
        // `done.isEmpty` 那一条挡的是「一块都没转出来」;这一条挡的是它的孪生兄弟:
        // **块都「成功」了,加起来零行**。两者对用户是同一件事 —— 界面显示「好了」,
        // 点进去里面什么都没有 —— 而后者在任务表上看起来完全正常。
        //
        // 2026-08-17 实测正在发生:m4a 冒充 mp3 送检,StepFun 返回
        // `result:[{}]`,五块全是这个形状。
        let zeroLines = result.lines == 0
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE tasks SET state = ?, last_error = ? WHERE task_id = ?
                """, arguments: [zeroLines || result.status == "partial" ? "degraded" : "done",
                                 zeroLines ? "转写回来了,但一行都没有 —— 送检的音频格式或内容有问题"
                                           : nil,
                                 taskID])
            // 冻结完就排抽取,**和标完成在同一个事务里** —— 分开写的话,
            // 冻结标了 done 而抽取没排上的那一场会永远停在「有逐字稿、没纪要」,
            // 而任务表看起来一切正常。上传 → 转写那一跳同理。
            //
            // ⚠️ partial 也抽。缺了几块不等于剩下的不值得抽,而 §3.1.6 里
            // partial 就是终态 —— 等一份永远不会变完整的转写等于永远不抽。
            // 认人也在同一个事务里排(M2-认8)。**排在抽取之前** ⇒ task_id 更小
            // ⇒ 首页「最新任务行」跟着抽取/进展走,不会被一个等 Mac 的认人任务
            // 挂成永远「排队中」。认人的可见性走详情页(「N 句没有说话人」)。
            try db.execute(sql: """
                INSERT INTO tasks (kind, session_id, state, priority, created_at, attempts)
                SELECT ?, ?, 'queued', 0, ?, 0
                 WHERE NOT EXISTS (SELECT 1 FROM tasks WHERE session_id = ? AND kind = ?)
                """, arguments: [Kind.voiceprint, sessionID, iso, sessionID, Kind.voiceprint])
            try db.execute(sql: """
                INSERT INTO tasks (kind, session_id, state, priority, created_at, attempts)
                SELECT ?, ?, 'queued', 0, ?, 0
                 WHERE NOT EXISTS (SELECT 1 FROM tasks WHERE session_id = ? AND kind = ?)
                """, arguments: [Kind.extract, sessionID, iso, sessionID, Kind.extract])
        }
        return .frozen(sessionID: sessionID, lines: result.lines, status: result.status)
    }

    // MARK: - 抽取

    /// 抽这一场活跃版本的每一份转写。
    ///
    /// ⚠️ **去重在 `ExtractionRunner`(靠 `summaries` 主键),不在这里。**
    /// 这个函数会被重放,而抽取一次比转写一次贵得多 ——
    /// 靠「调用方记得只调一次」的方案在第一次重放时就破了。
    private static func runExtract(_ taskID: Int64, _ sessionID: Int64, _ now: Date,
                                   _ iso: String, _ deps: Dependencies,
                                   _ writer: some DatabaseWriter) async throws -> Outcome {
        guard let call = deps.extract else {
            return try await parkUntilConfigured(taskID, sessionID, iso, deps, writer)
        }

        let transcripts = try await writer.read { db in
            try ExtractionRunner.activeTranscripts(db, sessionID: sessionID)
        }
        guard !transcripts.isEmpty else {
            try await writer.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET state = 'dead', last_error = '这一场没有冻结的转写'
                     WHERE task_id = ?
                    """, arguments: [taskID])
            }
            return .failed(sessionID: sessionID, error: "这一场没有冻结的转写")
        }

        try await writer.write { db in
            try db.execute(sql: "UPDATE tasks SET state = 'running' WHERE task_id = ?",
                           arguments: [taskID])
        }

        var items = 0, discarded = 0
        for transcriptID in transcripts {
            // 🔴 **走云端队列时,`call` 换成「排队 + 取回」**(`M2-B8`)。
            //
            // `ExtractionRunner.run` 逐块调一次 `call`,而块的切法是确定的
            // (同一份行 → 同一批块)⇒ **块号跨拍稳定**,可以直接当队列键。
            // 键用 `transcriptID` 而不是 `sessionID`:一场可能有多份转写,
            // 用场次做键会让第二份 part 0 撞上第一份的产物 —— 而撞上不报错,
            // 只是**把别人的纪要落到这一份头上**。
            //
            // 取不到就抛 `notReady`,由下面接住 → park(**不加 attempts**):
            // 轮询不是失败,算成失败的话一场抽取会被自己的轮询推向 dead。
            let perTranscript: (String) async throws -> String
            if let enqueue = deps.enqueueExtract, let fetch = deps.fetchExtract {
                var part = 0
                perTranscript = { prompt in
                    // 合并那次很小(约 200 进 / 50 出)且**只在分了块时才发生** ——
                    // 为它多跑一趟云不划算,同步打完就走。
                    if prompt.contains("合成**整场的一句话**") { return try await call(prompt) }
                    let p = part
                    part += 1
                    // 🔴 **键由云端算,手机只拿着 ticket**(`M2-审11`)。
                    // 从前手机用 `transcriptID + part` 自己当键 ——
                    // 那是 SQLite 的自增行号,**重装之后从头再来**,
                    // 新场次会撞上旧安装留在云端的产物,拿到别人那一场的纪要;
                    // 而改了 prompt 或换了模型时,旧产物照样被当成有效结果。
                    let ticket = try await enqueue(transcriptID, p, prompt)
                    guard let got = try await fetch(ticket) else {
                        throw ExtractNotReady(transcriptID: transcriptID, part: p)
                    }
                    return got
                }
            } else {
                perTranscript = call
            }
            // 🔴 **两阶段(v2.5)优先**(`M2-成7`)。给了 `enqueueExtractLines` 就走它:
            // 手机只交行材料,渲染/切块/多次调用全在 Mac。取不到产物同样抛 `notReady`
            // 由下面 park —— 轮询不是失败。
            var linesCall: (([ExtractValidate.Line]) async throws -> String)?
            if let enqueueLines = deps.enqueueExtractLines, let fetch = deps.fetchExtract {
                linesCall = { lines in
                    var payload: [[String: Any]] = lines.map { l in
                        var d: [String: Any] = ["line_id": l.lineID, "text": l.text,
                                                "is_gap": l.isGap]
                        if let p = l.personID { d["person_id"] = p }
                        if let c = l.clusterTag { d["cluster_tag"] = c }
                        if let t = l.startSeconds { d["t_sec"] = t }
                        if let t = l.endSeconds { d["t_end_sec"] = t }
                        return d
                    }
                    if !payload.isEmpty {
                        let (streaming, context) = try await writer.read { db in
                            let streaming = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM stream_blocks WHERE transcript_id = ?)", arguments: [transcriptID]) ?? false
                            return (streaming, try StreamContinuity.context(transcriptID, in: db))
                        }
                        payload[0]["recipe"] = StreamContinuity.recipe
                        payload[0]["streaming"] = streaming
                        payload[0]["stream_context"] = context
                    }
                    // part 恒 0:两阶段不分块(切分由候选块自己做),
                    // 手机再切一次会把它的分组切碎。
                    if !payload.isEmpty { payload[0]["action_protocol"] = ActionExtraction.protocolVersion }
                    if !payload.isEmpty { payload[0]["action_request"] = try await writer.read { try String.fetchOne($0, sql: "SELECT COALESCE(NULLIF(action_request_token,''),created_at) FROM tasks WHERE task_id=?", arguments: [taskID]) ?? iso } }
                    if !payload.isEmpty { payload[0]["source_revision"] = try await writer.read { try Int64.fetchOne($0, sql: "SELECT COALESCE(MAX(r.id),0) FROM transcript_line_revisions r JOIN transcript_lines l ON l.line_id=r.line_id WHERE l.transcript_id=?", arguments: [transcriptID]) ?? 0 } }
                    let ticket = try await enqueueLines(transcriptID, 0, payload)
                    guard let got = try await fetch(ticket) else {
                        throw ExtractNotReady(transcriptID: transcriptID, part: 0)
                    }
                    return got
                }
            }
            do {
                let r = try await ExtractionRunner.run(transcriptID: transcriptID, now: iso,
                                                       call: perTranscript,
                                                       linesCall: linesCall, requireActions: deps.enqueueExtract != nil || deps.enqueueExtractLines != nil, in: writer)
                items += r.stored
                discarded += r.stats?.discarded ?? 0
                // 事件被跳过 / 范围被去掉要留痕(仓规 6:校验失败要计数)——
                // 不记的话「详情少了一段」与「这场本来就只有一段」长得一样。
                if let s = r.stats, s.eventsDropped + s.eventRangesDropped > 0 {
                    ProcessingEvents.record(
                        trigger: deps.trigger,
                        outcome: "抽取:事件有 \(s.eventsDropped) 段缺标题或摘要被跳过,"
                               + "\(s.eventRangesDropped) 段行范围不合法被去掉",
                        detail: "转写 \(transcriptID)", in: writer)
                }
            } catch let notReady as ExtractNotReady {
                // 云端还在跑。**park 而不是记失败** —— 这一拍什么都不欠。
                try await writer.write { db in
                    try db.execute(sql: """
                        UPDATE tasks SET state = 'queued', last_error = ?, next_retry_at = ?
                         WHERE task_id = ?
                        """, arguments: ["云端正在抽第 \(notReady.part + 1) 块,等它",
                                          nextPoll(iso, deps), taskID])
                }
                return .waitingForExtraction(sessionID: sessionID,
                                             transcriptID: notReady.transcriptID, part: notReady.part)
            } catch let error as ActionExtraction.TerminalFailure {
                try await writer.write { try $0.execute(sql: "UPDATE tasks SET state=?,last_error=?,next_retry_at=NULL WHERE task_id=?", arguments: ["dead",error.message,taskID]) }
                return .failed(sessionID: sessionID, error: error.message)
            } catch {
                // 抽取失败**不动已经落库的那几份** —— 多 part 时前面成功的照样算数,
                // 重试会跳过它们(`summaries` 去重)。
                try TaskQueue.recordFailure(taskID: taskID, error: "抽取 \(transcriptID):\(error)",
                                            at: now, in: writer)
                return .failed(sessionID: sessionID, error: "\(error)")
            }
        }

        let canFinalizeActions = try await writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT s.status='closed' AND NOT EXISTS(SELECT 1 FROM stream_sessions WHERE session_id=s.id AND finished_at IS NULL) FROM sessions s WHERE s.id=?", arguments: [sessionID]) ?? false
        }
        if canFinalizeActions, let enqueue = deps.enqueueExtractLines, let fetch = deps.fetchExtract {
            let input = try await writer.read { db in
                (try ActionCandidateStore.sessionLines(sessionID, in: db),
                 try ActionCandidateStore.sessionRevision(sessionID, in: db),
                 try ActionCandidateStore.isSessionCurrent(sessionID, in: db),
                 try String.fetchOne(db, sql: "SELECT COALESCE(NULLIF(action_request_token,''),created_at) FROM tasks WHERE task_id=?", arguments: [taskID]) ?? iso)
            }
            if !input.2 && input.0.contains(where: { !$0.isGap }) {
                do {
                    let scopes = try await writer.read { db -> [Int64: Int64] in
                        var result: [Int64: Int64] = [:]
                        for row in try Row.fetchAll(db, sql: "SELECT l.line_id,l.transcript_id FROM transcript_lines l JOIN transcripts t ON t.id=l.transcript_id WHERE t.session_id=?", arguments: [sessionID]) {
                            result[row["line_id"]] = row["transcript_id"]
                        }
                        return result
                    }
                    var material: [[String: Any]] = input.0.map { line in
                        var item: [String: Any] = ["line_id":line.lineID,"text":line.text,"is_gap":line.isGap ? 1 : 0]
                        if let tag=line.clusterTag { item["cluster_tag"]=tag }
                        if let person=line.personID { item["person_id"]=person; item["actor_tag"]="已归属人物\(person)" }
                        else { item["actor_tag"]="未确认人物\(scopes[line.lineID] ?? 0):\(line.clusterTag ?? String(line.lineID))" }
                        return item
                    }
                    material[0]["action_protocol"]=ActionExtraction.protocolVersion
                    material[0]["action_only"]=true
                    material[0]["action_request"]=input.3
                    material[0]["source_revision"]=input.1
                    let ticket = try await enqueue(transcripts[0], 0, material)
                    guard let raw = try await fetch(ticket) else {
                        try await writer.write { db in
                            try db.execute(sql: "UPDATE tasks SET state=?,last_error=?,next_retry_at=? WHERE task_id=?", arguments: ["queued","正在核对整场个人行动",nextPoll(iso,deps),taskID])
                        }
                        return .waitingForExtraction(sessionID: sessionID, transcriptID: transcripts[0], part: 0)
                    }
                    let payload = try ExtractValidate.parseModelOutput(raw)
                    guard payload["action_protocol"] as? String == ActionExtraction.protocolVersion || payload["terminal"] as? Bool == true else {
                        throw ExtractValidate.Failure.schema("整场产物缺个人行动识别协议")
                    }
                    items += try ActionCandidateStore.storeSession(payload, sessionID: sessionID, now: iso, expectedLines: input.0, expectedRevision: input.1, in: writer)
                } catch let error as ActionExtraction.TerminalFailure {
                    try await writer.write { try $0.execute(sql: "UPDATE tasks SET state=?,last_error=?,next_retry_at=NULL WHERE task_id=?", arguments: ["dead",error.message,taskID]) }
                    return .failed(sessionID: sessionID, error: error.message)
                } catch {
                    try TaskQueue.recordFailure(taskID: taskID, error: "个人行动识别：\(error)", at: now, in: writer)
                    return .failed(sessionID: sessionID, error: "\(error)")
                }
            }
        }

        try await writer.write { db in
            try db.execute(sql: """
                UPDATE tasks SET state = 'done', last_error = NULL WHERE task_id = ?
                """, arguments: [taskID])
            // 抽完就排进展,**和标完成在同一个事务里** —— 与上面「冻结完排抽取」
            // 同一条理由:分开写的话,抽取标了 done 而进展没排上的那一场会永远
            // 停在「有纪要、事上没有进展」,而任务表看起来一切正常。
            let openStream = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM stream_sessions WHERE session_id = ? AND finished_at IS NULL)", arguments: [sessionID]) ?? false
            if !openStream { try db.execute(sql: """
                INSERT INTO tasks (kind, session_id, state, priority, created_at, attempts)
                SELECT ?, ?, 'queued', 0, ?, 0
                 WHERE NOT EXISTS (SELECT 1 FROM tasks WHERE session_id = ? AND kind = ?)
                """, arguments: [Kind.progress, sessionID, iso, sessionID, Kind.progress]) }
        }
        return .extracted(sessionID: sessionID, items: items, discarded: discarded)
    }

    /// 等太久了就把**这一块**判失败(M1-30 ②)。
    ///
    /// ⚠️ **判的是块,不是整场** —— 与上面 `.failed` 那条同一条口径:
    /// 一块转不出来不等于整场失败,而 §3.1.6 允许缺块以 partial 落库。
    /// 判死之后冻结那一步会把它算进 `missing`,逐字稿里留占位行,
    /// **卡片不会说「好了」** —— 这就是那条「看得见的出口」。
    /// ⚠️ **时刻从注入的 `iso` 派生,不用 `Date()`** —— 上一轮(M1-30 ③)刚因为
    /// 夹具混用两个时钟打红过三条测试。这一层的所有时间都走同一个来源。
    private static func giveUpIfStalled(_ job: ASRJobStore.Job, kind: String, detail: String,
                                        iso: String,
                                        in writer: some DatabaseWriter) throws {
        guard let born = ISO8601DateFormatter.growth.date(from: job.createdAt),
              let nowDate = ISO8601DateFormatter.growth.date(from: iso) else { return }
        let minutes = Int(nowDate.timeIntervalSince(born) / 60)
        guard minutes >= asrStallMinutes else { return }
        try ASRJobStore.fail(
            sessionID: job.sessionID, blockSeq: job.blockSeq,
            error: "提交后 \(minutes / 60) 小时仍无终态(\(kind))—— 超过 "
                 + "\(asrStallMinutes / 60) 小时的等待上限,判这一块失败。"
                 + (detail.isEmpty ? "" : "最后一次的报文:\(detail)"),
            now: iso, in: writer)
    }

    // MARK: - 声纹认人(M2-认8)

    /// pump 侧那一整步的结果。
    enum VoiceprintStep {
        case noLines               // 这一场没有可判的行(全是占位/脱敏)
        case waiting               // 排上了,Mac 还没判完
        case merged(matched: Int, anonymous: Int, tagged: Int)
    }

    /// 排队给 Mac 判、取回合并。**手机永远不判**(方案 §3.1 单执行方)。
    ///
    /// 「还没好」park 而不记失败(照抽取那条的先例):轮询不是失败,
    /// 算成失败的话一场认人会被自己的轮询推向 dead。
    private static func runVoiceprint(_ taskID: Int64, _ sessionID: Int64, _ iso: String,
                                      _ deps: Dependencies,
                                      _ writer: some DatabaseWriter) async throws -> Outcome {
        guard let step = deps.voiceprint else {
            return try await parkUntilConfigured(taskID, sessionID, iso, deps, writer)
        }
        try await writer.write { db in
            try db.execute(sql: "UPDATE tasks SET state = 'running' WHERE task_id = ?",
                           arguments: [taskID])
        }
        do {
            switch try await step(sessionID) {
            case .noLines:
                try await writer.write { db in
                    try db.execute(sql: """
                        UPDATE tasks SET state = 'done',
                               last_error = '这一场没有可判的行,认人跳过' WHERE task_id = ?
                        """, arguments: [taskID])
                }
                return .speakersJudged(sessionID: sessionID, matched: 0, anonymous: 0, tagged: 0)
            case .waiting:
                // park 回 queued + next_retry_at(照抽取 ExtractNotReady 的先例):
                // attempts 不动 —— 轮询不是失败。
                // ⚠️ 刻意**不用** `attributing` 态:nextRunnable 只捡 queued/retrying/
                // waiting_network,park 进别的态就再也没人捡了(（场次略） 那个形状)。
                // 「说话人整理中」的展示语义由详情页负责,不靠这行任务态。
                try await writer.write { db in
                    try db.execute(sql: """
                        UPDATE tasks SET state = 'queued',
                               last_error = 'Mac 正在判这一场的说话人,等它',
                               next_retry_at = ? WHERE task_id = ?
                        """, arguments: [nextPoll(iso, deps), taskID])
                }
                return .waitingForVoiceprint(sessionID: sessionID)
            case .merged(let m, let a, let t):
                try await writer.write { db in
                    try db.execute(sql: """
                        UPDATE tasks SET state = 'done', last_error = NULL WHERE task_id = ?
                        """, arguments: [taskID])
                }
                return .speakersJudged(sessionID: sessionID, matched: m, anonymous: a, tagged: t)
            }
        } catch {
            // 真失败(网络、model 对不上、合并抛)才烧 attempts。
            try TaskQueue.recordFailure(taskID: taskID, error: "认人:\(error)",
                                        at: now(iso), in: writer)
            return .failed(sessionID: sessionID, error: "\(error)")
        }
    }

    private static func now(_ iso: String) -> Date {
        ISO8601DateFormatter.growth.date(from: iso) ?? Date()
    }

    // MARK: - 进展归属(M2-B3)

    /// 把这一场的新材料与活跃的事比一遍,产出进展。
    ///
    /// ⚠️ **它是一种独立任务**(见 `Kind.progress` 的注释):抽取与进展都花钱,
    /// 合在一起的话进展失败的每一次重试都会把抽取一起重跑。
    private static func runProgress(_ taskID: Int64, _ sessionID: Int64, _ now: Date,
                                    _ iso: String, _ deps: Dependencies,
                                    _ writer: some DatabaseWriter) async throws -> Outcome {
        let pendingStream = try await writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM stream_sessions s WHERE s.session_id = ?
                  AND (s.finished_at IS NULL OR EXISTS(SELECT 1 FROM stream_blocks b
                    WHERE b.session_id = s.session_id AND NOT EXISTS(SELECT 1 FROM summaries m
                      WHERE m.transcript_id = b.transcript_id AND TRIM(m.one_liner) != ''))))
                """, arguments: [sessionID]) ?? false
        }
        if pendingStream {
            try await writer.write { db in
                try db.execute(sql: "UPDATE tasks SET state = 'queued', last_error = '等待尾部内容整理完成', next_retry_at = ? WHERE task_id = ?",
                               arguments: [nextPoll(iso, deps), taskID])
            }
            return .held(sessionID: sessionID, reason: "等待尾部内容整理完成")
        }
        guard let call = deps.progressCall else {
            return try await parkUntilConfigured(taskID, sessionID, iso, deps, writer)
        }

        let outcome: ProgressAttributionRunner.Outcome
        do {
            outcome = try await ProgressAttributionRunner.run(sessionID: sessionID,
                                                              call: call, in: writer)
        } catch {
            try TaskQueue.recordFailure(taskID: taskID, error: "进展归属:\(error)",
                                        at: now, in: writer)
            return .failed(sessionID: sessionID, error: "\(error)")
        }

        let landed = try await writer.write { db in
            try MatterProgressStore.land(outcome.judged, sessionID: sessionID, in: db, now: iso)
        }

        // 🔴 **校验失败要计数并可见**(§3.2,本条验收点名)。
        // 设置页已经在渲染 `ProcessingEvents` 的 `outcome + detail`,
        // ⇒ 记一条就等于接上了,不用另做一个界面。
        // ⚠️ **理由要带上**:只给一个数的话,「模型在编」与「归属还没到位」
        // 在界面上长得一模一样,而两者的处置完全相反。
        try await writer.write { db in
            if outcome.validationFailures > 0 || !outcome.droppedForBudget.isEmpty
                || outcome.heldCount > 0 || landed.alreadyLanded > 0 {
                try ProcessingEvents.record(
                    trigger: .background,
                    outcome: "场次 \(sessionID) 比对:静默 \(landed.toTimeline) · "
                           + "待确认 \(landed.toCards) · 校验没过 \(outcome.validationFailures)",
                    detail: [
                        outcome.failureReasons.isEmpty ? nil
                            : "校验没过:" + outcome.failureReasons.prefix(5).joined(separator: " | "),
                        outcome.heldCount > 0
                            ? "挂起 \(outcome.heldCount) 条(归属还没到位,会自己好,不弹卡打扰你)" : nil,
                        outcome.droppedForBudget.isEmpty ? nil
                            : "超输入预算砍掉的事:\(outcome.droppedForBudget)",
                        landed.alreadyLanded > 0
                            ? "重放撞幂等闸 \(landed.alreadyLanded) 条(上一拍已落过,不是没产出)" : nil,
                    ].compactMap { $0 }.joined(separator: "\n"),
                    in: db)
            }
            try db.execute(sql: """
                UPDATE tasks SET state = 'done', last_error = NULL WHERE task_id = ?
                """, arguments: [taskID])
        }
        return .progressed(sessionID: sessionID, silent: landed.toTimeline,
                           cards: landed.toCards, failures: outcome.validationFailures)
    }

    // MARK: - 依赖

    /// 编排要用的外部能力,**全部注入**。
    ///
    /// 这样整条编排能在没有网络、没有音频文件的情况下被测 ——
    /// 而这一层最该测的恰恰是「重放会不会多花钱」「断在哪一步能不能续上」,
    /// 那些和真网络无关。
    struct Dependencies {
        /// 🔴 **这一拍是谁叫起来的。它不是一项「能力」,而是一个真值,
        /// 放在这里只有一个理由:让它在整拍里只有一个出处。**
        ///
        /// 这一拍要在两条支路上被记进 `processing_events`:上传那条
        /// (`BlockUploader.run` → `UploadTransport.handOff`)与冻结那条
        /// (`freeze` 闭包 → `ProcessingPump.assemble` / `writeClusterTags`)。
        /// 若改成给 `tick` 加参数,`freeze` 闭包仍拿不到它,`ProcessingPump`
        /// 就得在建依赖时和调 `tick` 时**各传一次** —— 那就是两份同一件事,
        /// 而两份迟早对不上(§3.1 第四条铁律)。
        ///
        /// 所以真相源只有一个:`ProcessingPump.pump(trigger:)` 的入参,
        /// 经 `dependencies(in:trigger:)` 灌进这里,下游一律读它、不许自己写死。
        var trigger: ProcessingEvents.Trigger
        /// 这一场有哪些块(从落盘账本来,账本是块的真相源)
        var blocks: (Int64) throws -> [PendingBlock]
        /// 一块多少秒(记账要用)
        var seconds: (PendingBlock) -> Int
        var reachability: () -> Reachability
        var wifiOnly: Bool
        var audioExt: String
        var transport: UploadTransport
        var proxy: ProxyClient.Config?
        var submit: (String, Int) async throws -> String
        var query: (String) async throws -> ProxyClient.QueryResult
        /// 冻结。返回 (行数, `frozen`/`partial`)
        var freeze: (Int64, [ASRJobStore.Job]) throws -> (lines: Int, status: String)
        /// 抽取:把 prompt 送出去、拿模型正文回来。`nil` = 云代理还没配。
        ///
        /// 注进来而不是直接调 `ProxyClient`,是为了让「重放不多花钱」这条
        /// 能在没有网络的情况下被测 —— 那正是这一层最该测的东西。
        var extract: ((String) async throws -> String)?
        /// 进展归属的模型调用。**与抽取分开的那个闭包**,不是同一条 ——
        /// 两者的 `scene` 不同,而记账按 `scene` 分组:合用一个的话
        /// 「转写一天花多少」与「比对一天花多少」会混成一个数,
        /// 而降本时最需要知道的正是这两者各占多少。
        var progressCall: ((String) async throws -> String)?

        /// 把一块 prompt 排进云端队列(`M2-B8`)。给了就走云端,没给就同步跑。
        ///
        /// ⚠️ **两条路并存不是过渡期的凑合**:同步那条是离线/自测时唯一能跑的,
        /// 而且 `ExtractionRunner` 的全部测试都靠它。删掉它等于让这一层没法测。
        var enqueueExtract: ((Int64, Int, String) async throws -> String)?
        /// 取一块的产物。**还没好给 nil** —— 「在跑」不是错。
        /// ⚠️ 入参是 **ticket**(`M2-审11`),不是 (key, part) —— 产物的键含一个
        /// 只在云那侧算的指纹,手机自己拼键就是第二个出处(铁律 4)。
        var fetchExtract: ((String) async throws -> String?)?
        /// 两阶段抽取(`M2-成7`):把行材料排进队列,返回 ticket。
        /// 给了就走 v2.5;没给就退回 v1 的「渲染 prompt 分块跑」。
        /// ⚠️ **两条路并存不是过渡期的凑合** —— v1 那条是离线/自测唯一能跑的,
        /// `ExtractionRunner` 的全部测试都靠它。
        var enqueueExtractLines: ((Int64, Int, [[String: Any]]) async throws -> String)?
        /// 声纹认人的一整步(M2-认8):出题 → 排队 → 取回 → 合并,全在 pump 侧做,
        /// 这里只拿结果决定任务态。`nil` = 云代理还没配。
        var voiceprint: ((Int64) async throws -> VoiceprintStep)?
        var ingestCompletedBlocks: ((Int64, [ASRJobStore.Job]) throws -> ContinuousIngestion.Appended?)? = nil
        /// 还没好(在传 / 在转)时隔多久再看一眼
        var pollInterval: TimeInterval = BlockUploader.pollInterval
    }
}

extension ISO8601DateFormatter {
    /// 全仓统一的时间戳格式 —— 与 `SessionBridge.iso` 同口径(本地时区 + 偏移)。
    /// 两处各写一个格式化器,写进库的串迟早不一样,而 `strftime` 会按 UTC 解释没偏移的串,
    /// 差 8 小时。
    static let growth: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
}

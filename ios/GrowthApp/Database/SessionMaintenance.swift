import Foundation
import GRDB

// 一场录音的两件维护动作:**重新冻结**与**删除**。
//
// 两件都是破坏性的,所以收在一处 —— 各处自己写一份 DELETE 的话,
// 迟早有一处漏掉某张表,而漏掉的形态是「删过了,但它还在某个查询里冒出来」。
enum SessionMaintenance {

    // MARK: - 重新冻结

    /// 拿**已经存着的转写报文**重拼一遍时间轴,落成新的一版。
    ///
    /// ## 一分钱不花
    ///
    /// `asr_jobs.result_json` 存的是**原始报文**,它的注释当初就写着
    /// 「解析器改了要能拿回原文重跑,而重新提交是要花钱的」——
    /// 这个场景正是它留的口。所以「时间轴算错了」不需要重转写。
    ///
    /// ## 出新版本,不改旧的
    ///
    /// 冻结层的纪律是**永不改**(§3.1.6),所以这里落的是 `version + 1`,
    /// 旧那版原样留着。`active_transcript_id` 指到新版 —— 界面看的是它。
    /// ⚠️ 旧版产出的纪要**不会自动跟过来**:抽取是按 transcript 走的,
    /// 新版要重新抽。这里只负责冻结那一步,不替编排做决定。
    struct RefreezeResult: Equatable {
        let version: Int
        let lines: Int
        let status: String
        let clustersTagged: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case noStoredTranscripts
        /// 报文在,但**账本里定位不到任何一块**。
        ///
        /// 🔴 **与上一条分开是必须的。** 两者的处置完全不同:
        /// 没报文 → 只能重转写(要花钱);账本没了 → 重转写也白搭
        /// (块的位置永远回不来了),而且**原因是「清除全部录音」删过账本**。
        /// 混成一句「没有存下来的转写报文」会让用户去点一个解决不了问题的按钮。
        case noLedger
        case noSuchSession
        case captureStillOpen

        var description: String {
            switch self {
            case .noStoredTranscripts:
                return "这一场没有存下来的转写报文 —— 重新冻结无从下手,只能重转写(要花钱)"
            case .noLedger:
                return "报文还在,但账本里定位不到这一场的块 —— "
                     + "账本可能被「清除全部录音」删掉了。重整没法进行(重转写也一样)"
            case .noSuchSession: return "找不到这一场"
            case .captureStillOpen: return "先在手表结束并同步收尾，再重新整理时间轴"
            }
        }
    }

    @discardableResult
    static func refreeze(sessionID: Int64, now: String,
                         in db: DatabaseQueue) throws -> RefreezeResult {
        let open = try db.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ? AND status = ?)", arguments: [sessionID, SessionBridge.Status.open]) ?? false }
        guard !open else { throw Failure.captureStillOpen }
        let jobs = try db.read { d in
            try Row.fetchAll(d, sql: """
                SELECT block_seq, result_json FROM asr_jobs
                 WHERE session_id = ? AND state = 'done' AND result_json IS NOT NULL
                 ORDER BY block_seq
                """, arguments: [sessionID])
        }
        guard !jobs.isEmpty else { throw Failure.noStoredTranscripts }

        // 块的真实起点与时长 —— 与生产同一条路径,否则重冻出来的时间轴
        // 和正常冻结的不一样,而那种不一致没人查得出来。
        // 🔴 **和正常冻结走同一份装配** —— 见 `ProcessingPump.assemble` 的注释:
        // 2026-08-18 复核之前,这里自己写了一份,于是
        // ① **不传 `missing:`** ⇒ 缺块被静默抹平,重整出来的转写自称 `frozen`,
        //    卡片说「好了」而逐字稿有洞(**M1-14a 那个 BUG,换了个入口**);
        // ② 块起点用 `blockSeq * 300_000` 兜底 ⇒ 逐块累积偏移,跳原话跳错位置
        //    (**M1-13a 那个 BUG,同样换了个入口**)。
        // 两个都只修了 `ProcessingPump` 那一个调用点。现在只有一份装配。
        let done = jobs.compactMap { row -> ASRJobStore.Job? in
            guard let raw = row["result_json"] as String? else { return nil }
            // `createdAt` 从行里取真值,不给空串 —— 它现在是「等太久了」那条判据的
            // 输入(M1-30 ②),编一个会让重新冻结出来的作业看起来「刚提交」。
            return ASRJobStore.Job(sessionID: sessionID, blockSeq: row["block_seq"],
                                   remoteID: "", state: .done, resultJSON: raw, lastError: nil,
                                   createdAt: row["created_at"] as String? ?? "")
        }
        // ⚠️ **这里的「前台」是真值,不是省事** —— 前提写在一起(仓规 6):
        // `refreeze` 只有一条到达路径,`HomeView` 的「重新整理时间轴」→
        // `RecordingViewModel.refreeze`,那是用户当面点的。**后台唤醒到不了这里**
        // (`ProcessingOrchestrator` 不排 refreeze 任务)。
        // 🔴 哪天有人把它接进编排或 `BGProcessingTask`,这个常量当场变成假话,
        // 那时必须把 `trigger` 提成 `refreeze` 的入参往上传,而不是留着这一行。
        let a = ProcessingPump.assemble(sessionID: sessionID, jobs: done, ext: "m4a",
                                        trigger: .foreground, in: db)
        // 报文有、块一个都装配不出来 ⇒ 账本定位不到(`assemble` 已经逐块记了事件)。
        // **说准原因**:这时重转写也救不回来,块的位置在账本里,不在报文里。
        guard !a.blocks.isEmpty else { throw Failure.noLedger }

        let nextVersion = (try db.read { d in
            try Int.fetchOne(d, sql: "SELECT MAX(version) FROM transcripts WHERE session_id = ?",
                             arguments: [sessionID])
        } ?? 0) + 1

        let r = try TranscriptFreeze.freeze(
            sessionID: sessionID, asrModel: "stepaudio-2.5-asr",
            version: nextVersion, blocks: a.blocks, missing: a.missing,
            unplaceable: a.unplaceable, now: now, in: db)
        try ProcessingPump.writeClusterTags(r.speakerByLine, now: now,
                                            trigger: .foreground, in: db)

        ProcessingEvents.record(
            trigger: .foreground,
            outcome: "场次 \(sessionID) 重新冻结成 v\(nextVersion)",
            detail: "\(r.lineCount) 行 · \(r.status)"
                  + (a.missing.isEmpty ? "" : " · 缺 \(a.missing.count) 块(逐字稿里留占位行)")
                  + (a.unplaceable.isEmpty ? "" :
                     " · 另有 \(a.unplaceable.count) 块账本里没有(定不了位,无占位行)")
                  + " · 用的是已存的转写报文,没有重新提交(零花费)",
            in: db)

        return RefreezeResult(version: nextVersion, lines: r.lineCount,
                              status: r.status, clustersTagged: r.speakerByLine.count)
    }

    // MARK: - 移出记忆不在这里
    //
    // 🔴 **redact 只有一条通道:`MemoryRemoval.removeSession`。**
    //
    // 我 2026-08-17 在这里另写了一份 `redact(sessionID:placeholder:)` —— 而那条通道
    // 早就在 `Database/MemoryRemoval.swift` 里,写得比我那份严:
    // · 墓碑文案是**常量**(各处各写一个的话,将来没法用一条断言查「哪些行是墓碑」)
    // · 删完音频**回读一次**,只要还有文件在就抛;我那份用 `try?`,
    //   「以为删了其实没删」会被静默计成成功 —— 隐私上最贵的一种失败
    // · 顺序是先提交库再删音频;反过来落库失败就成了「音频没了、墓碑也没有」
    //
    // 而我那份里唯一多出来的东西(清词索引)**是多余的**:
    // v10 的 `transcript_line_tokens_redact` 触发器在 `redacted 0→1` 时自己会删。
    //
    // 所以整段删掉,`RecordingViewModel.deleteSession` 直接调那条通道。
    // 留这段话是因为「删掉这一场」听起来太像一件本地小事,下一个人还会想在这儿写。
}

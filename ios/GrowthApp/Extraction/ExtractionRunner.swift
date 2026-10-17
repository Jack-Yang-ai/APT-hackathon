import Foundation
import GRDB

/// 一份转写 → 一份纪要(M1-4b)。
///
/// 把「读行 → 渲染 prompt → 调云代理 → 解析 → 三项校验 → 落库」串成一步。
/// 它不做判断、也不排队 —— 那些在 `ProcessingOrchestrator` 里。
///
/// ## 幂等靠自然键,不靠调用方
///
/// `summaries.transcript_id` 是主键,所以「这份转写抽过没有」在库里是一个
/// **可查的事实**,不是一个要靠调用方记住的约定。编排会被重放很多遍,
/// 而抽取**花钱** —— 靠调用方自觉的方案在第一次重放时就破了。
///
/// ## 为什么按 transcript 抽,不按 session
///
/// `summaries` 是以 `transcript_id` 为主键的(M0-2d 定的),而一场可以有多份
/// 转写(多 part、或重转的新 version)。按场次抽就得先回答「哪一份算数」,
/// 而库里已经有答案:活跃版本的那几份。今天 part 恒为 1,所以一场就是一份。
enum ExtractionRunner {
    /// 这条腿在任务表里的 kind。
    ///
    /// 🔴 **它存在的唯一理由是让「谁花钱」有一个能被机器检查的出处**(`M2-审7`)。
    /// 这个 `run` 收 `call:` —— 先花钱、再解析,解析一抛就等于原价再买一次
    /// ⇒ 它必须落在 `TaskQueue.paidRetryKinds` 里。漏了不会有任何东西报错,
    /// 所以有一道源码对撞盯着这一对:`eval/checks/test_paid_retry_kinds.py`。
    /// ⚠️ 引用 `ProcessingOrchestrator.Kind`,**不另写字面量** —— 写死就是第二个出处。
    static let taskKind = ProcessingOrchestrator.Kind.extract


    enum Failure: Error, CustomStringConvertible {
        case noLines(Int64)

        var description: String {
            switch self {
            case .noLines(let t): return "转写 \(t) 一行都没有,没什么可抽的"
            }
        }
    }

    struct Result: Equatable {
        let transcriptID: Int64
        /// 落库的条目数
        let stored: Int
        /// 已经抽过、这次跳过了(重放路径)
        let skipped: Bool
        let stats: ExtractValidate.Stats?
    }

    /// 读这份转写的行,连着归属一起 —— 三项校验里的「说话人一致」要用。
    ///
    /// ⚠️ `LEFT JOIN`,不是 `JOIN`。没有归属行的转写行**必须出现在结果里**,
    /// 它们只是 `person_id` 为空(→ 引用它们的条目挂起)。用内连接会让这些行
    /// 从 prompt 里整个消失,而模型看不到的内容不会被抽出来 —— 那是一种
    /// 「少抽了但没人知道」的静默丢失。
    /// 一块最多几行(M1-27)。
    ///
    /// **由实测定,不是拍的**(`eval/extract_pilot`,2026-08-19):
    /// 1,165 行 → 输出 12,627(占 `MAX_TOKENS` 20,000 的 63%);2,232 行 → 19,998 顶死。
    /// 800 行留出约四成余量 —— 输出量还取决于内容密度(一场吵架比一场发呆吐得多),
    /// 所以余量要留在「行数」这一侧,不能卡着实测点。
    static let chunkSize = 800

    static func lines(_ db: Database, transcriptID: Int64) throws -> [ExtractValidate.Line] {
        try Row.fetchAll(db, sql: """
            SELECT l.line_id, l.text, l.is_gap, l.t_start_ms, l.t_end_ms, ls.person_id, ls.cluster_tag
              FROM transcript_lines l
              LEFT JOIN line_speakers ls ON ls.line_id = l.line_id
             WHERE l.transcript_id = ? AND l.redacted = 0
             ORDER BY l.seq
            """, arguments: [transcriptID]).map { row in
            ExtractValidate.Line(
                lineID: row["line_id"],
                text: row["text"],
                isGap: (row["is_gap"] as Int? ?? 0) == 1,
                personID: row["person_id"],
                clusterTag: row["cluster_tag"],
                startSeconds: Double(row["t_start_ms"] as Int) / 1000,
                endSeconds: Double(row["t_end_ms"] as Int) / 1000)
        }
    }

    /// 抽一份转写。已经抽过就直接返回,**不再花一次钱**。
    ///
    /// `call` 注入的是「把 prompt 送出去、拿正文回来」这一件事 ——
    /// 整条链因此能在没有网络的情况下被测,而这一层最该测的
    /// (重放会不会多花钱、校验统计对不对、脏产出会不会落库)和真网络无关。
    /// - Parameter linesCall: **两阶段抽取(`M2-成7`,v2.5)** —— 给了就走它:
    ///   把整份行材料交出去,由 Mac 跑 `worker/extract_two_stage.py`
    ///   (候选块代码预切、模型逐块打标、event 边界与 event_id 全由代码派生),
    ///   拿回**已经是最终形状的 payload JSON**。
    ///
    ///   🔴 **拿回来仍然在手机上再校验一遍。** 远端已经校验过一次(那边也有行),
    ///   但落库这道口是手机把的 —— 信一份没验过的远端 payload 就是新开一个洞,
    ///   而三项校验是纯字符串比对、便宜得很。两份实现由金标对齐,不是两个真相源。
    ///
    ///   ⚠️ 走这条时**不分块**:切分由两阶段自己按候选块做(`TARGET_CHARS`),
    ///   手机再切一次会把它的分组切碎。
    static func run(transcriptID: Int64, now: String,
                    call: (String) async throws -> String,
                    linesCall: (([ExtractValidate.Line]) async throws -> String)? = nil,
                    reassessActions: Bool = false,
                    requireActions: Bool = false,
                    in writer: some DatabaseWriter) async throws -> Result {

        // ⚠️ **`TRIM(one_liner) <> ''` 不是多余的**:库里可能已经躺着空产物
        // (2026-08-20 之前 `ExtractionStore` 不查非空)。不加这半句,那些转写
        // 会被永久跳过 —— 而「跳过因为抽过了」与「跳过因为抽出来是空的」
        // 在任务表上一模一样。加上之后它们会重抽一次,**之后再也不会有空的**
        // (store 已经拦下),所以这不是一个会反复花钱的口子。
        let already = try await writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM summaries
                               WHERE transcript_id = ? AND TRIM(one_liner) <> '')
                """, arguments: [transcriptID]) ?? false
        }
        let assessed = try await writer.read { try ActionCandidateStore.isCurrent(transcriptID, in: $0) }
        if already && (!reassessActions || assessed) { return Result(transcriptID: transcriptID, stored: 0, skipped: true, stats: nil) }

        let input = try await writer.read { db -> ([ExtractValidate.Line], Int64) in
            let revision = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(r.id),0) FROM transcript_line_revisions r JOIN transcript_lines l ON l.line_id=r.line_id WHERE l.transcript_id=?", arguments: [transcriptID]) ?? 0
            return (try self.lines(db, transcriptID: transcriptID), revision)
        }
        let lines = input.0
        let capturedRevision = input.1
        if already && (lines.isEmpty || lines.allSatisfy(\.isGap)) {
            return Result(transcriptID: transcriptID, stored: 0, skipped: true, stats: nil)
        }
        func persist(_ clean: [String: Any], lines: [ExtractValidate.Line]) throws -> Int {
            if already {
                guard clean["action_protocol"] as? String == ActionExtraction.protocolVersion else {
                    throw ExtractValidate.Failure.schema("执行端尚未更新个人行动识别，请稍后重试")
                }
                return try ActionCandidateStore.store(clean, transcriptID: transcriptID, now: now, expectedLines: lines, expectedRevision: capturedRevision, in: writer)
            }
            return try ExtractionStore.store(clean, transcriptID: transcriptID, now: now, expectedLines: lines, expectedRevision: capturedRevision, in: writer)
        }

        if lines.isEmpty {
            let deleted = try await writer.read { db in
                try Bool.fetchOne(db, sql: "SELECT COUNT(*) > 0 AND MIN(redacted) = 1 FROM transcript_lines WHERE transcript_id = ?", arguments: [transcriptID]) ?? false
            }
            guard deleted else { throw Failure.noLines(transcriptID) }
            var empty: [String: Any] = ["one_liner": MemoryRemoval.tombstoneText, "events": []]
            for kind in ExtractValidate.allKinds { empty[kind] = [[String: Any]]() }
            let stored = try ExtractionStore.store(empty, transcriptID: transcriptID, now: now, expectedLines: [], in: writer)
            return Result(transcriptID: transcriptID, stored: stored, skipped: false, stats: .init())
        }
        let streaming = try await writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM stream_blocks WHERE transcript_id = ?)", arguments: [transcriptID]) ?? false
        }
        if streaming && lines.allSatisfy(\.isGap) {
            var empty: [String: Any] = ["one_liner": "这段转写缺失，尚无可用内容。", "events": []]
            for kind in ExtractValidate.allKinds { empty[kind] = [[String: Any]]() }
            let stored = try ExtractionStore.store(empty, transcriptID: transcriptID, now: now, expectedLines: lines, in: writer)
            return Result(transcriptID: transcriptID, stored: stored, skipped: false, stats: .init())
        }

        // 🔴 **分块跑(M1-27)。整场一次调用会在全天录音上必然失败。**
        //
        // 2026-08-19 实测(`eval/extract_pilot`):78 行 → 输出 9,020;1,165 行 → 12,627;
        // **2,232 行 → 19,998,顶到 `MAX_TOKENS` 20,000,JSON 解不开**。
        // 输出**不随输入线性增长,而是饱和** —— 所以问题不是「上下文放不放得下」,
        // 是**吐不吐得完**。而这个产品是全时录音,一天远超 2,232 行 ⇒ 必然撞。
        //
        // ⚠️ 更贵的那种失败:截断**恰好落在合法的 JSON 边界**上 ⇒ 拿到一份静默残缺的纪要,
        // 而它和「这一场就这么点内容」长得一模一样。分块是为了根本不走到那一步。
        // 🔴 **两阶段那条:整份交出去,不分块。**
        if let linesCall {
            let raw = try await linesCall(lines)
            let payload = try ExtractValidate.parseModelOutput(raw)
            if streaming, payload["pipeline_version"] as? String != StreamContinuity.recipe {
                throw ExtractValidate.Failure.schema("Mac 的语义管线版本尚未更新，不能把独立分片冒充同一件事的延续")
            }
            if streaming {
                guard let events = payload["events"] as? [[String: Any]] else { throw ExtractValidate.Failure.schema("持续分片产物缺事件数组") }
                let usable = Set(lines.filter { !$0.isGap }.map(\.lineID))
                for event in events {
                    guard let title = event["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let summary = event["summary"] as? String, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let from = event["line_from"] as? Int, let to = event["line_to"] as? Int,
                          from <= to, usable.contains(Int64(from)), usable.contains(Int64(to)) else {
                        throw ExtractValidate.Failure.schema("持续分片的事件标题、摘要或原话范围无效，拒绝缓存残缺理解")
                    }
                }
            }
            if (requireActions || reassessActions) && payload["action_protocol"] as? String != ActionExtraction.protocolVersion {
                throw ExtractValidate.Failure.schema("执行端尚未更新个人行动识别")
            }
            let (clean, stats) = try ExtractValidate.validate(payload, lines: lines)
            let stored = try persist(clean, lines: lines)
            return Result(transcriptID: transcriptID, stored: stored,
                          skipped: false, stats: stats)
        }

        let chunks = lines.chunked(into: chunkSize)
        var merged: [String: Any] = [:]
        var totalStats = ExtractValidate.Stats()
        var oneLiners: [String] = []

        for chunk in chunks {
            let raw = try await call(ExtractPrompt.renderWithActions(lines: chunk))
            // 解析与校验都可能抛,**让它抛** —— 抛出去会被任务表记成失败并退避重试,
            // 而吞掉会变成「这场没抽到内容」,和真的没内容长得一模一样。
            let payload = try ExtractValidate.parseModelOutput(raw)
            // ⚠️ **只拿这一块的行去校验**:拿全场的行校验,会让「模型引用了本块之外的行号」
            // 这种真错误蒙混过关 —— 而那正是分块最可能引入的新错法。
            if (requireActions || reassessActions) && payload["action_protocol"] as? String != ActionExtraction.protocolVersion {
                throw ExtractValidate.Failure.schema("这段尚未完成个人行动识别")
            }
            let (part, stats) = try ExtractValidate.validate(payload, lines: chunk)
            if let s = part["one_liner"] as? String, !s.isEmpty { oneLiners.append(s) }
            for kind in ExtractValidate.allKinds {
                let existing = merged[kind] as? [[String: Any]] ?? []
                merged[kind] = existing + ((part[kind] as? [[String: Any]]) ?? [])
            }
            if part["action_protocol"] as? String == ActionExtraction.protocolVersion {
                merged["action_protocol"] = ActionExtraction.protocolVersion
                merged["personal_actions"] = (merged["personal_actions"] as? [[String: Any]] ?? []) + (part["personal_actions"] as? [[String: Any]] ?? [])
            }
            totalStats.add(stats)
        }

        // 一句话:**整场只该有一句**(`summaries.transcript_id` 是主键)。
        // 只有一块时原样用;多块时再跑一次**很小**的合并调用(约 200 进 / 50 出)。
        // ⚠️ 不取「最后一块的」—— 那等于断言结论总在最后;也不拼接 —— 拼出来不是人话。
        merged["one_liner"] = oneLiners.count <= 1
            ? (oneLiners.first ?? "")
            : try await call(ExtractPrompt.mergeOneLiners(oneLiners))
                .trimmingCharacters(in: .whitespacesAndNewlines)

        let clean = merged
        let stats = totalStats

        let stored = try persist(clean, lines: lines)
        return Result(transcriptID: transcriptID, stored: stored, skipped: false, stats: stats)
    }

    /// 这一场里该抽的转写:**活跃版本的全部 part**。
    ///
    /// 和 `SessionDetailProjection.activeTranscripts` 同一个口径 ——
    /// 两处各写一个「哪一份算数」的定义,迟早会给出不同的答案,
    /// 而那时界面显示的和抽取跑的就不是同一份转写了。
    static func activeTranscripts(_ db: Database, sessionID: Int64) throws -> [Int64] {
        try SessionDetailProjection.activeTranscripts(db, sessionID: sessionID)
    }
}

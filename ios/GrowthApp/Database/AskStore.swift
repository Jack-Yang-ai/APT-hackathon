import Foundation
import GRDB

// 自由提问的对话记录(PRD §4.7.3,migration v16)。
//
// **这个文件是 `ask_conversations` / `ask_turns` 的唯一写入口。**
//
// ## 它**不**碰判断库
//
// §4.7.4 规则 2:「对话不直接改库,结论经收尾卡或对话内确认后写入」。
// 在这里问一句「他是不是反对过」,不该在归属层留下任何痕迹 ——
// 所以这一层与 `assignSpeaker` / `judgments` 完全无关,将来「对话内确认」
// 那条路要另外走那两个入口。
//
// ## 生命周期只有一条路:`open` → `askBegin` → `answer` 或 `fail`
//
// 🔴 **`askBegin` 必须在发请求之前调用。** G5 要求「失败时保留用户已输入的问题」,
// 而唯一能兑现它的做法是**先落盘再发请求** —— 反过来做(成功才写)的话,
// 请求超时或 App 被杀,用户敲的那段话就没了,而那正是他最不想重打的东西。

struct AskTurn: Equatable {
    enum Status: String {
        case asking   = "提问中"
        case answered = "已回答"
        case failed   = "失败"
    }
    let id: Int64
    let conversationID: Int64
    let seq: Int
    let askedAt: String
    let question: String
    let answer: String?
    let status: Status
    let error: String?
    /// 这一轮喂给模型的行。既是 G3 的出处,也是成本审计。
    let citedLineIDs: [Int64]
    var sourcesTracked = false
    var citedInputIDs: [Int64] = []
}

struct AskConversation: Equatable {
    let id: Int64
    let startedAt: String
    let updatedAt: String
    /// 可空 —— 建出来还没问第一句时**就是没有标题**。
    let title: String?
    var isMain = false
    var archived = false
}

enum AskStore {

    enum Failure: Error, CustomStringConvertible {
        case emptyQuestion
        case noSuchTurn(id: Int64)
        case invalidTopicName
        case protectedMain

        var description: String {
            switch self {
            case .emptyQuestion:
                return "问题是空的 —— 空问题发上去只会烧一次钱换一句废话"
            case .noSuchTurn(let id):
                return "没有 id 为 \(id) 的这一轮"
            case .invalidTopicName:
                return "话题名请用 1～12 个字，不能叫主聊天或问问"
            case .protectedMain:
                return "主聊天不能改名或归档"
            }
        }
    }

    /// 标题取问题的前若干字。**只在第一轮时写**,后面不覆盖 ——
    /// 用最后一问当标题的话,历史列表会随对话推进不断变样,用户找不回来。
    static let titleLimit = 12
    static let topicTitleLimit = 12

    // MARK: - 写

    static func open(now: String, scope: AskScope? = nil, title: String? = nil, in db: Database) throws -> Int64 {
        if let scope { _ = try scope.label(in: db) }
        let name = try title.map(normalizedTopicName)
        try db.execute(sql: """
            INSERT INTO ask_conversations (started_at, updated_at, context_session_id, context_event_id, title) VALUES (?, ?, ?, ?, ?)
            """, arguments: [now, now, scope?.sessionID, scope?.eventID, name])
        return db.lastInsertedRowID
    }

    /// 默认会话单独建行；存量对话保留为话题，不搬动其消息。
    static func main(now: String, in db: Database) throws -> Int64 {
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM ask_conversations WHERE is_main = 1") { return id }
        try db.execute(sql: "INSERT INTO ask_conversations(started_at, updated_at, title, is_main) VALUES(?, ?, '主聊天', 1)", arguments: [now, now])
        return db.lastInsertedRowID
    }

    static func normalizedTopicName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= topicTitleLimit, !["主聊天", "问问"].contains(name) else { throw Failure.invalidTopicName }
        return name
    }

    static func rename(_ id: Int64, title: String, in db: Database) throws {
        let name = try normalizedTopicName(title)
        try db.execute(sql: "UPDATE ask_conversations SET title = ? WHERE id = ? AND is_main = 0", arguments: [name, id])
        guard db.changesCount == 1 else { throw Failure.protectedMain }
    }

    static func archive(_ id: Int64, archived: Bool, in db: Database) throws {
        try db.execute(sql: "UPDATE ask_conversations SET archived = ? WHERE id = ? AND is_main = 0", arguments: [archived, id])
        guard db.changesCount == 1 else { throw Failure.protectedMain }
    }

    /// 开一轮。**发请求之前调用**,见文件头。
    static func askBegin(conversation: Int64, question: String, now: String,
                         in db: Database) throws -> Int64 {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw Failure.emptyQuestion }

        let seq = (try Int.fetchOne(db, sql:
            "SELECT MAX(seq) FROM ask_turns WHERE conversation_id = ?",
            arguments: [conversation]) ?? -1) + 1

        try db.execute(sql: """
            INSERT INTO ask_turns
              (conversation_id, seq, asked_at, question, status) VALUES (?, ?, ?, ?, ?)
            """, arguments: [conversation, seq, now, q, AskTurn.Status.asking.rawValue])
        let id = db.lastInsertedRowID

        // 第一轮才定标题 —— 见 `titleLimit` 那段注释
        if seq == 0 {
            try db.execute(sql: "UPDATE ask_conversations SET title = COALESCE(title, ?), updated_at = ?, archived = 0 WHERE id = ?",
                           arguments: [String(q.prefix(titleLimit)), now, conversation])
        } else {
            try db.execute(sql: "UPDATE ask_conversations SET updated_at = ?, archived = 0 WHERE id = ?",
                           arguments: [now, conversation])
        }
        return id
    }

    /// 答上了。`citedLineIDs` 是这一轮实际喂进去的行 —— **空数组是合法的**,
    /// 它的意思是「一条材料都没检索到」,而那时回答应当是「这个我没有记录」(P5)。
    static func answer(_ turnID: Int64, text: String, citedLineIDs: [Int64], citedInputIDs: [Int64] = [],
                       now: String, in db: Database) throws {
        let tracked = try Bool.fetchOne(db, sql: "SELECT sources_tracked FROM ask_turns WHERE id = ?", arguments: [turnID]) ?? false
        if tracked { try validateSources(turnID, in: db) }
        try db.execute(sql: """
            UPDATE ask_turns SET answer = ?, status = ?, error = NULL, cited_line_ids = ?, cited_input_ids = ?
             WHERE id = ?
            """, arguments: [text, AskTurn.Status.answered.rawValue,
                             encode(citedLineIDs), encode(citedInputIDs), turnID])
        try touch(turnID, now: now, in: db)
    }

    /// 失败。**问题那一行原样留着** —— 这就是 G5 要的「保留用户已输入的问题」。
    static func fail(_ turnID: Int64, reason: String, now: String, in db: Database) throws {
        try db.execute(sql: """
            UPDATE ask_turns SET status = ?, error = ?, answer = NULL, cited_line_ids = '[]', cited_input_ids = '[]' WHERE id = ?
            """, arguments: [AskTurn.Status.failed.rawValue, reason, turnID])
        try touch(turnID, now: now, in: db)
    }

    /// 删一轮(§4.7.3「单轮可删除」)。**删除单位是轮,不是对话。**
    static func deleteTurn(_ turnID: Int64, in db: Database) throws {
        try db.execute(sql: "DELETE FROM ask_turns WHERE id = ?", arguments: [turnID])
        guard db.changesCount > 0 else { throw Failure.noSuchTurn(id: turnID) }
    }

    /// 进程刚起来时,把停在「提问中」的轮子收干净。
    ///
    /// 它们是**上一个进程死掉时留下的**:请求发出去了,而回调再也不会来。
    /// 不收的话界面会永远转圈 —— 与 `TaskQueue.reclaimInterrupted` 同一个道理。
    @discardableResult
    static func reclaimInterrupted(now: String, in db: Database) throws -> Int {
        try db.execute(sql: """
            UPDATE ask_turns SET status = ?, error = ? WHERE status = ?
            """, arguments: [AskTurn.Status.failed.rawValue,
                             "App 上次被关掉时这一问还没答完,重试一次",
                             AskTurn.Status.asking.rawValue])
        return db.changesCount
    }

    private static func touch(_ turnID: Int64, now: String, in db: Database) throws {
        try db.execute(sql: """
            UPDATE ask_conversations SET updated_at = ?
             WHERE id = (SELECT conversation_id FROM ask_turns WHERE id = ?)
            """, arguments: [now, turnID])
    }

    // MARK: - 读

    static func conversations(in db: Database, limit: Int = 50) throws -> [AskConversation] {
        try Row.fetchAll(db, sql: """
            SELECT id, started_at, updated_at, title, is_main, archived FROM ask_conversations
             ORDER BY is_main DESC, archived, updated_at DESC LIMIT ?
            """, arguments: [limit]).map {
            AskConversation(id: $0["id"], startedAt: $0["started_at"],
                            updatedAt: $0["updated_at"], title: $0["title"], isMain: $0["is_main"], archived: $0["archived"])
        }
    }

    static func conversation(_ id: Int64, in db: Database) throws -> AskConversation? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM ask_conversations WHERE id = ?", arguments: [id]) else { return nil }
        return AskConversation(id: row["id"], startedAt: row["started_at"], updatedAt: row["updated_at"], title: row["title"], isMain: row["is_main"], archived: row["archived"])
    }

    static func turns(of conversation: Int64, in db: Database) throws -> [AskTurn] {
        try Row.fetchAll(db, sql: """
            SELECT id, conversation_id, seq, asked_at, question, answer, status,
                   error, cited_line_ids, sources_tracked, cited_input_ids
              FROM ask_turns WHERE conversation_id = ? ORDER BY seq
            """, arguments: [conversation]).map {
            AskTurn(id: $0["id"], conversationID: $0["conversation_id"], seq: $0["seq"],
                    askedAt: $0["asked_at"], question: $0["question"],
                    answer: $0["answer"],
                    // CHECK 约束保证了取值合法,解不出来只可能是 schema 被人改过
                    status: AskTurn.Status(rawValue: $0["status"]) ?? .failed,
                    error: $0["error"], citedLineIDs: decode($0["cited_line_ids"]), sourcesTracked: $0["sources_tracked"], citedInputIDs: decode($0["cited_input_ids"]))
        }
    }

    /// 未完整刷新或固定会议背景时，排除依赖全库输入的历史答案。
    static func history(of conversation: Int64, excluding turnID: Int64,
                        allowInputSources: Bool, in db: Database) throws -> [AskTurn] {
        let candidates = Array(try turns(of: conversation, in: db)
            .filter { $0.id != turnID && $0.status == .answered && $0.sourcesTracked }.suffix(8))
        return try candidates.filter {
            try sourcesAreCurrent($0.id, in: db) && (allowInputSources || !hasInputSources($0.id, in: db))
        }
    }

    static func scope(of conversation: Int64, in db: Database) throws -> AskScope? {
        guard let row = try Row.fetchOne(db, sql: "SELECT context_session_id, context_event_id FROM ask_conversations WHERE id = ?", arguments: [conversation]) else {
            throw ContinuousIngestion.Failure.invalid("这段问答已经不存在")
        }
        guard let sid = row["context_session_id"] as Int64? else { return nil }
        return AskScope(sessionID: sid, eventID: row["context_event_id"])
    }

    /// 记录全部实际提供的材料，连着所提供历史的依赖；不限于模型引用出来的那几条。
    static func recordSources(_ turnID: Int64, materials: [AskRetrieval.Material], history: [AskTurn], inputs: [InputMemorySource] = [], in db: Database) throws {
        var sources: [Int64: String] = [:]
        for material in materials {
            let id = material.hit.lineID, text = material.hit.text
            if let old = sources[id], !old.hasPrefix(text) && !text.hasPrefix(old) {
                throw ContinuousIngestion.Failure.invalid("同一条原文出现了不同内容，请重新读取")
            }
            if (sources[id]?.count ?? 0) < text.count { sources[id] = text }
        }
        for turn in history {
            guard try sourcesAreCurrent(turn.id, in: db) else {
                throw ContinuousIngestion.Failure.invalid("历史回答的来源或归属已变化，请重新提问")
            }
            for row in try Row.fetchAll(db, sql: "SELECT line_id, text FROM ask_turn_sources WHERE turn_id = ?", arguments: [turn.id]) {
                let id: Int64 = row["line_id"], text: String = row["text"]
                if let old = sources[id], !old.hasPrefix(text) && !text.hasPrefix(old) {
                    throw ContinuousIngestion.Failure.invalid("历史引用的原文已更正，请开一段新对话")
                }
                if (sources[id]?.count ?? 0) < text.count { sources[id] = text }
            }
        }
        for (id, text) in sources {
            let who = try Row.fetchOne(db, sql: "SELECT person_id,source FROM line_speakers WHERE line_id=?", arguments: [id])
            let revision = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id),0) FROM transcript_line_revisions WHERE line_id=?", arguments: [id]) ?? 0
            try db.execute(sql: "INSERT INTO ask_turn_sources(turn_id,line_id,text,speaker_id,attribution,attribution_tracked,source_revision) VALUES(?,?,?,?,?,1,?)",
                           arguments: [turnID, id, text, who?["person_id"] as Int64?, who?["source"] as String?, revision])
        }
        var inputSources: [Int64: InputMemorySource] = [:]
        for source in inputs {
            if let old = inputSources[source.localID], old != source {
                throw ContinuousIngestion.Failure.invalid("同一输入来源出现不同版本")
            }
            inputSources[source.localID] = source
        }
        for turn in history {
            for row in try Row.fetchAll(db, sql: "SELECT local_id, record_json FROM ask_turn_input_sources WHERE turn_id = ?", arguments: [turn.id]) {
                let id: Int64 = row["local_id"], json: String = row["record_json"]
                let source = InputMemorySource(localID: id, record: try JSONDecoder().decode(InputMemoryRecord.self, from: Data(json.utf8)))
                if let old = inputSources[id], old != source {
                    throw ContinuousIngestion.Failure.invalid("历史引用的输入来源已修改，请重新提问")
                }
                inputSources[id] = source
            }
        }
        for source in inputSources.values {
            try db.execute(sql: "INSERT INTO ask_turn_input_sources(turn_id,local_id,revision,content_hash,record_json) VALUES(?,?,?,?,?)", arguments: [turnID, source.localID, source.record.revision, source.hash, source.record.canonicalJSON])
        }
        try db.execute(sql: "UPDATE ask_turns SET sources_tracked = 1 WHERE id = ?", arguments: [turnID])
        try validateSources(turnID, in: db)
    }

    static func validateSources(_ turnID: Int64, in db: Database) throws {
        guard let status = try String.fetchOne(db, sql: "SELECT status FROM ask_turns WHERE id = ?", arguments: [turnID]),
              status == AskTurn.Status.asking.rawValue else {
            throw ContinuousIngestion.Failure.invalid("这轮问题已经取消，或使用的记录已移出记忆")
        }
        guard try sourcesAreCurrent(turnID, in: db) else {
            throw ContinuousIngestion.Failure.invalid("回答所用的记录已更正、重新整理或移出记忆，请重新提问")
        }
    }

    /// 旧答案的来源过时后仍可回看，但不能再次作为新问题的事实背景。
    static func sourcesAreCurrent(_ turnID: Int64, in db: Database) throws -> Bool {
        for row in try Row.fetchAll(db, sql: """
            SELECT src.text AS snapshot, l.text, l.redacted, s.removed_at,
                   src.speaker_id AS expected_speaker,src.attribution AS expected_attribution,src.attribution_tracked,
                   src.source_revision AS expected_revision,COALESCE((SELECT MAX(id) FROM transcript_line_revisions WHERE line_id=l.line_id),0) AS current_revision,
                   ls.person_id AS current_speaker,ls.source AS current_attribution,
                   t.version = (SELECT MAX(version) FROM transcripts WHERE session_id = t.session_id) AS active
              FROM ask_turn_sources src JOIN transcript_lines l ON l.line_id = src.line_id
              JOIN transcripts t ON t.id = l.transcript_id JOIN sessions s ON s.id = t.session_id
              LEFT JOIN line_speakers ls ON ls.line_id=l.line_id WHERE src.turn_id = ?
            """, arguments: [turnID]) {
            guard row["attribution_tracked"] as Bool,
                  row["expected_revision"] as Int64 == row["current_revision"] as Int64,
                  row["expected_speaker"] as Int64? == row["current_speaker"] as Int64?,
                  row["expected_attribution"] as String? == row["current_attribution"] as String?,
                  row["redacted"] as Int == 0, row["removed_at"] as String? == nil,
                  row["active"] as Bool,
                  (row["text"] as String).hasPrefix(row["snapshot"] as String) else {
                return false
            }
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT s.revision AS expected_revision, s.content_hash AS expected_hash,
                   m.revision, m.content_hash, m.deleted FROM ask_turn_input_sources s
              LEFT JOIN input_memory_sources m ON m.local_id = s.local_id WHERE s.turn_id = ?
            """, arguments: [turnID]) {
            guard row["deleted"] as Int? == 0,
                  row["revision"] as Int64? == row["expected_revision"] as Int64,
                  row["content_hash"] as String? == row["expected_hash"] as String else { return false }
        }
        return true
    }

    static func hasInputSources(_ turnID: Int64, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ask_turn_input_sources WHERE turn_id = ?)", arguments: [turnID]) ?? false
    }

    static func inputSource(turnID: Int64, localID: Int64, in db: Database) throws -> InputMemorySource? {
        guard let json = try String.fetchOne(db, sql: "SELECT record_json FROM ask_turn_input_sources WHERE turn_id = ? AND local_id = ?", arguments: [turnID, localID]) else { return nil }
        return InputMemorySource(localID: localID, record: try JSONDecoder().decode(InputMemoryRecord.self, from: Data(json.utf8)))
    }

    static func removeInputDependentAnswers(localID: Int64, in db: Database) throws {
        let affected = try Row.fetchAll(db, sql: """
            SELECT a.conversation_id, MIN(a.seq) AS first_seq FROM ask_turns a
             JOIN ask_turn_input_sources s ON s.turn_id = a.id WHERE s.local_id = ?
             GROUP BY a.conversation_id
            """, arguments: [localID])
        try clearDependentAnswers(affected, in: db)
    }

    static func sourceText(turnID: Int64, lineID: Int64, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT text FROM ask_turn_sources WHERE turn_id = ? AND line_id = ?", arguments: [turnID, lineID])
    }

    static func removeDependentAnswers(lineFilter: String, arguments: StatementArguments, in db: Database) throws {
        let affected = try Row.fetchAll(db, sql: """
            SELECT conversation_id, MIN(seq) AS first_seq FROM ask_turns a WHERE
             EXISTS(SELECT 1 FROM ask_turn_sources src WHERE src.turn_id = a.id AND src.line_id IN
               (SELECT line_id FROM transcript_lines WHERE \(lineFilter)))
             OR EXISTS(SELECT 1 FROM json_each(CASE WHEN json_valid(a.cited_line_ids) THEN a.cited_line_ids ELSE '[]' END) c
               WHERE c.value IN (SELECT line_id FROM transcript_lines WHERE \(lineFilter)))
             GROUP BY conversation_id
            """, arguments: arguments + arguments)
        try clearDependentAnswers(affected, in: db)
    }

    private static func clearDependentAnswers(_ affected: [Row], in db: Database) throws {
        for row in affected {
            let cid: Int64 = row["conversation_id"], seq: Int = row["first_seq"]
            try db.execute(sql: """
                DELETE FROM ask_turn_sources WHERE turn_id IN (SELECT id FROM ask_turns WHERE conversation_id = ? AND seq >= ?)
                """, arguments: [cid, seq])
            try db.execute(sql: "DELETE FROM ask_turn_input_sources WHERE turn_id IN (SELECT id FROM ask_turns WHERE conversation_id = ? AND seq >= ?)", arguments: [cid, seq])
            try db.execute(sql: """
                UPDATE ask_turns SET answer = NULL, cited_line_ids = '[]', cited_input_ids = '[]', status = ?, error = ?
                 WHERE conversation_id = ? AND seq >= ?
                """, arguments: [AskTurn.Status.failed.rawValue, "所用记录已移出记忆，相关回答已清除", cid, seq])
        }
    }

    // MARK: - 工具

    private static func encode(_ ids: [Int64]) -> String {
        (try? String(data: JSONEncoder().encode(ids), encoding: .utf8) ?? "[]") ?? "[]"
    }

    private static func decode(_ s: String?) -> [Int64] {
        guard let s, let d = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Int64].self, from: d)) ?? []
    }
}

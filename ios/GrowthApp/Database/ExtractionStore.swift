import Foundation
import GRDB
import CoreFoundation

/// 把抽取产出落进内容层。
///
/// 入参就是 `worker/extract.py` 里 `validate()` 交出来的那份 JSON:丢弃的已剔除,
/// 挂起的带 `pending: true`,`speaker_hint` 已经剥掉。这一层**不再做校验**——
/// 校验在抽取那侧做完了,这里再做一遍就是两套口径,迟早会分叉。
///
/// 这里一个「谁说的」字段都不存(铁律 3)。挂起的条目**留着**,归属到位后由
/// `assignSpeaker` 触发重算翻回来,不是丢掉等重抽。
enum ExtractionStore {

    enum Failure: Error, CustomStringConvertible {
        case missingOneLiner
        case emptyOneLiner
        case unknownLines([Int64])
        case missingField(kind: String, field: String)
        case staleSource

        var description: String {
            switch self {
            case .missingOneLiner:
                return "抽取产出缺 one_liner —— PRD §4.2.3 写明它必有"
            case .emptyOneLiner:
                // 🔴 **空串曾经一路畅通**(2026-08-20 查实)。三处都只判「有这个键、
                // 是字符串」—— 而上面那句报错原文写的就是「必有」,**必有却没查非空**。
                // 后果两层,都不报错:
                // ① 界面上 `d.oneLiner ?? "这一场还没出一句话"` 拿到的是**空串不是 nil**,
                //    连兜底文案都不显示,标题一片空白;
                // ② `summaries` 有行了 ⇒ `ExtractionRunner` 的去重从此**永久跳过**这份转写
                //    —— 钱花了、纪要空着、而且再也不会重跑。
                return "抽取回来了,但整场结论是空的 —— 这不是「这一场没内容」,"
                     + "是这一次抽取没产出。空产物落库之后会永久挡住重跑,所以在这里拦下。"
            case .unknownLines(let ids):
                return "这些 line_id 不在 transcript_lines 里,内容会挂空:\(ids)"
            case .missingField(let kind, let field):
                return "\(kind) 的条目缺字段 \(field) —— §4.2 契约里它是必填。"
                     + "注意 JSON 字段名与 DDL 列名不是一回事(key_points 的字段叫 point,列叫 text)"
            case .staleSource:
                return "抽取期间原话已更正、移出记忆或重新整理，拒绝写回旧内容"
            }
        }
    }

    /// 四类带 line_id + quote 的产出。
    ///
    /// ⚠️ `field`(§4.2 契约里的 JSON 字段名)与 `column`(DDL 里的列名)**必须分开写**。
    /// 它们只是碰巧在 commitments/stances/pendings 上重名;`key_points` 契约里是
    /// `point`、列名是 `text`,合成一个就会去读一个不存在的字段 ——
    /// 之前正是这么写的,而单元测试喂的也是 `text`,实现与测试共享同一个错误信念,
    /// 测试永远抓不到。M0-12a 拿另一侧的真契约跑端到端才炸出来。
    private static let itemKinds: [(json: String, table: String, field: String, column: String)] = [
        ("key_points",  "summary_key_points",  "point",  "text"),
        ("commitments", "summary_commitments", "what",   "what"),
        ("stances",     "summary_stances",     "stance", "stance"),
        ("pendings",    "summary_pendings",    "issue",  "issue"),
    ]

    @discardableResult
    static func store(_ payload: [String: Any],
                      transcriptID: Int64,
                      now: String,
                      expectedLines: [ExtractValidate.Line]? = nil,
                      expectedRevision: Int64? = nil,
                      in writer: some DatabaseWriter) throws -> Int {

        guard let oneLiner = payload["one_liner"] as? String else { throw Failure.missingOneLiner }
        // 「必有」= 有这个键 **且有内容**。少了后半句,空串就是一份合法的空纪要。
        guard !oneLiner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyOneLiner
        }

        return try writer.write { db in
            if let expectedLines {
                let active = try Bool.fetchOne(db, sql: """
                    SELECT s.removed_at IS NULL AND t.version = (SELECT MAX(version) FROM transcripts WHERE session_id = t.session_id)
                      FROM transcripts t JOIN sessions s ON s.id = t.session_id WHERE t.id = ?
                    """, arguments: [transcriptID]) ?? false
                let current = try Row.fetchAll(db, sql: "SELECT line_id, text, is_gap FROM transcript_lines WHERE transcript_id = ? AND redacted = 0 ORDER BY seq", arguments: [transcriptID])
                guard active, current.count == expectedLines.count,
                      zip(current, expectedLines).allSatisfy({ row, line in
                          row["line_id"] as Int64 == line.lineID && row["text"] as String == line.text && (row["is_gap"] as Int == 1) == line.isGap
                      }) else { throw Failure.staleSource }
            }
            // 行必须真实存在。内容挂在不存在的行上,就是新造一批悬空引用。
            var referenced = Set<Int64>()
            for kind in itemKinds {
                for item in (payload[kind.json] as? [[String: Any]] ?? []) {
                    if let l = item["line_id"] as? Int { referenced.insert(Int64(l)) }
                }
            }
            for ev in (payload["events"] as? [[String: Any]] ?? []) {
                for k in ["line_from", "line_to"] {
                    if let l = ev[k] as? Int { referenced.insert(Int64(l)) }
                }
            }
            if !referenced.isEmpty {
                let marks = Array(repeating: "?", count: referenced.count).joined(separator: ",")
                let found = try Int64.fetchSet(db, sql: """
                    SELECT line_id FROM transcript_lines WHERE line_id IN (\(marks))
                    """, arguments: StatementArguments(Array(referenced)))
                let missing = referenced.subtracting(found).sorted()
                guard missing.isEmpty else { throw Failure.unknownLines(missing) }
            }

            // 🔴 **只清掉「空产物」那一行,再写新的。**
            //
            // 2026-08-20 之前落下的空 `one_liner` 行不会自己消失,而
            // `summaries.transcript_id` 是主键 ⇒ 重抽时 INSERT 直接撞 UNIQUE,
            // 于是「放行重抽」那一半白做了(这条是被测试当场抓到的)。
            //
            // ⚠️ **条件里的 `TRIM(one_liner) = ''` 不能去掉。** 无条件删的话,
            // 对一份**已经有好纪要**的转写再调一次 store 就会静默覆盖 ——
            // 而撞主键报错才是那时该发生的事(重复落库是缺陷,不是需要兜底的情况)。
            // ⚠️ 关联条目一并删:只删 summaries 而留下旧条目,重抽会在旧条目上**叠一份**,
            // 而界面上「要点有两份」与「模型这次多抽了几条」长得一模一样。
            let hadEmpty = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM summaries
                               WHERE transcript_id = ? AND TRIM(one_liner) = '')
                """, arguments: [transcriptID]) ?? false
            if hadEmpty {
                for table in itemKinds.map(\.table) + ["summary_topic_keys", "summary_events"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE transcript_id = ?",
                                   arguments: [transcriptID])
                }
                try db.execute(sql: "DELETE FROM summaries WHERE transcript_id = ?",
                               arguments: [transcriptID])
            }

            // 记录此产物真正读取的修订水位，不用请求开始时间猜改字先后。
            let sourceRevision = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(MAX(r.id),0) FROM transcript_line_revisions r
                JOIN transcript_lines l ON l.line_id=r.line_id WHERE l.transcript_id=?
                """, arguments: [transcriptID]) ?? 0
            if let expectedRevision, expectedRevision != sourceRevision { throw Failure.staleSource }
            try db.execute(sql: """
                INSERT INTO summaries (transcript_id,one_liner,created_at,source_revision) VALUES (?,?,?,?)
                """, arguments: [transcriptID, oneLiner, now, sourceRevision])

            var stored = 0
            for kind in itemKinds {
                let items = payload[kind.json] as? [[String: Any]] ?? []
                for (seq, item) in items.enumerated() {
                    try insert(item, seq: seq, kind: kind, transcriptID: transcriptID, db: db)
                    stored += 1
                }
            }

            for topic in (payload["topic_keys"] as? [[String: Any]] ?? []) {
                let ids = (topic["line_ids"] as? [Int] ?? []).map(String.init).joined(separator: ",")
                try db.execute(sql: """
                    INSERT INTO summary_topic_keys (transcript_id, key, line_ids) VALUES (?, ?, ?)
                    """, arguments: [transcriptID, topic["key"] as? String ?? "", "[\(ids)]"])
            }

            // 事件(`M5-1`,两阶段抽取才有;v1 单阶段没有这个键 ⇒ 什么都不写,详情页如实说「没有详情」)。
            // 标题与摘要是契约必填:缺了点名报错,不塞空串 —— 空串会让详情页出现一段没有字的「段落」。
            // 行范围 `line_from / line_to` 是 worker 机械算的,键名由跨语言对撞钉着。
            for (seq, ev) in (payload["events"] as? [[String: Any]] ?? []).enumerated() {
                guard let title = ev["title"] as? String else {
                    throw Failure.missingField(kind: "events", field: "title")
                }
                guard let summary = ev["summary"] as? String else {
                    throw Failure.missingField(kind: "events", field: "summary")
                }
                let number = ev["continuation_id"] as? NSNumber
                let prior = number.flatMap { n -> Int64? in
                    guard CFGetTypeID(n) != CFBooleanGetTypeID(), n.int64Value > 0,
                          n == NSNumber(value: n.int64Value) else { return nil }
                    return n.int64Value
                }
                if ev["continuation_id"] != nil, prior == nil {
                    throw ContinuousIngestion.Failure.invalid("事件延续身份不是整数")
                }
                var storedPrior: Int64?
                if let prior {
                    guard seq == 0,
                          ev["line_from"] != nil, ev["line_to"] != nil,
                          let expected = try StreamContinuity.previousEvent(transcriptID, in: db),
                          expected["id"] as Int64 == prior else {
                        throw ContinuousIngestion.Failure.invalid("事件延续引用不是这份分片的前一件事，拒绝落错")
                    }
                    storedPrior = try StreamContinuity.root(of: prior, in: db)
                }
                try db.execute(sql: """
                    INSERT INTO summary_events
                      (transcript_id, seq, title, summary, first_line_id, last_line_id, continuation_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [transcriptID, seq, title, summary,
                                     ev["line_from"] as? Int, ev["line_to"] as? Int, storedPrior])
            }
            _ = try ActionCandidateStore.write(payload, transcriptID: transcriptID, now: now, expectedLines: expectedLines, expectedRevision: expectedRevision, in: db)
            return stored
        }
    }

    private static func insert(_ item: [String: Any], seq: Int,
                               kind: (json: String, table: String, field: String, column: String),
                               transcriptID: Int64, db: Database) throws {
        // 字段缺了就点名说缺哪个。靠 NOT NULL 约束报错也拦得住,但错误信息是
        // 「NOT NULL constraint failed」—— 拦住了却看不出是契约字段名对不上,
        // 下一个人还要再查一遍。
        guard let freeText = item[kind.field] as? String else {
            throw Failure.missingField(kind: kind.json, field: kind.field)
        }
        // 挂起标记原样带过来:抽取那侧判的,这里不重判
        let pending = (item["pending"] as? Bool ?? false) ? 1 : 0
        var columns = ["transcript_id", "line_id", "seq", kind.column, "quote", "pending"]
        var values: [DatabaseValueConvertible?] = [
            transcriptID, item["line_id"] as? Int, seq,
            freeText, item["quote"] as? String, pending,
        ]
        // 各类自己多出来的那几列
        switch kind.table {
        case "summary_commitments":
            columns.append("to_whom_text"); values.append(item["to_whom_text"] as? String)
        case "summary_stances":
            columns.append("premise");         values.append(item["premise"] as? String)
            columns.append("premise_line_id"); values.append(item["premise_line_id"] as? Int)
        case "summary_pendings":
            let parties = (item["parties_text"] as? [String]) ?? []
            columns.append("parties_text")
            values.append(parties.isEmpty ? nil : parties.joined(separator: "\u{1F}"))
        default: break
        }
        let marks = Array(repeating: "?", count: columns.count).joined(separator: ",")
        try db.execute(sql: "INSERT INTO \(kind.table) (\(columns.joined(separator: ","))) VALUES (\(marks))",
                       arguments: StatementArguments(values))
    }

    /// 归属变了之后,重判这些行上条目的挂起标记。
    ///
    /// 这就是 §3.2.3 清单第 2、3 项的实质:**「说话人一致」这项校验的结论会随归属改变**。
    /// 归属到位 → 条目从挂起翻成正常;归属被撤回 → 翻回挂起。
    /// 幂等:同样的库状态跑两次结果一样(§3.5.2 断言 3)。
    @discardableResult
    static func recomputePending(_ db: Database, table: String, lines: [Int64]) throws -> Int {
        guard !lines.isEmpty else { return 0 }
        let marks = Array(repeating: "?", count: lines.count).joined(separator: ",")
        try db.execute(sql: """
            UPDATE \(table)
               SET pending = CASE WHEN (
                     SELECT ls.person_id FROM line_speakers ls WHERE ls.line_id = \(table).line_id
                   ) IS NULL THEN 1 ELSE 0 END,
                   pending_reason = CASE WHEN (
                     SELECT ls.person_id FROM line_speakers ls WHERE ls.line_id = \(table).line_id
                   ) IS NULL THEN '归属未定' ELSE NULL END
             WHERE line_id IN (\(marks))
            """, arguments: StatementArguments(lines))
        return db.changesCount
    }
}

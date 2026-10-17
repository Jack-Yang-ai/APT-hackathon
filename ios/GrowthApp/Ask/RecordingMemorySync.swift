import Foundation
import CryptoKit
import GRDB

/// The phone remains the content writer. This outbox contains only versioned read projections.
enum RecordingMemoryProjection {
    struct Record: Codable, Equatable, Sendable {
        let id: String
        let session_id: Int64
        let transcript_id: Int64
        var revision: Int64
        let created: String
        var updated: String
        let title: String
        let text: String
        let partial: Bool
        let deleted: Bool
    }
    struct Batch: Codable, Sendable {
        var schema = "apt.recording-memory.batch/1"
        let device_id: String
        let records: [Record]
    }
    enum Failure: Error { case oversizedLine, invalidDate, invalidReceipt, versionConflict }
    static func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func sourceID(_ key: String) -> String {
        let hex = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let chars = Array(hex.prefix(32))
        return "apt_recording_" + String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16]) + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32])
    }
    /// Reconciliation and revision assignment share a transaction. Crashes cannot lose a queued edit.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
    static func reconcile(now: String, in db: Database) throws {
        guard let instant = ISO8601DateFormatter.growth.date(from: now) else { throw Failure.invalidDate }
        let updatedAt = timestamp(instant)
        let transcripts = try Row.fetchAll(db, sql: """
            SELECT t.*,s.started_at,s.source FROM transcripts t JOIN sessions s ON s.id=t.session_id
             WHERE s.removed_at IS NULL AND t.status IN ('frozen','partial')
               AND t.version=(SELECT MAX(version) FROM transcripts WHERE session_id=t.session_id)
             ORDER BY t.id
            """)
        var desired: [String: Record] = [:]
        for t in transcripts {
            let tid: Int64 = t["id"], sid: Int64 = t["session_id"], started: String = t["started_at"]
            guard let start = ISO8601DateFormatter.growth.date(from: started) else { throw Failure.invalidDate }
            let all = try Row.fetchAll(db, sql: """
                SELECT l.*,p.name,ls.person_id,ls.source AS attribution_source FROM transcript_lines l
                LEFT JOIN line_speakers ls ON ls.line_id=l.line_id LEFT JOIN persons p ON p.id=ls.person_id
                WHERE l.transcript_id=? ORDER BY l.seq
                """, arguments: [tid])
            let lines = all.filter { ($0["redacted"] as Int) == 0 }
            let partial = (t["status"] as String) == "partial" || all.contains { ($0["redacted"] as Int) == 1 || ($0["is_gap"] as Int) == 1 }
            let currentRevision = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(r.id),0) FROM transcript_line_revisions r JOIN transcript_lines l ON l.line_id=r.line_id WHERE l.transcript_id=?", arguments: [tid]) ?? 0
            let summaryRevision = try Int64.fetchOne(db, sql: "SELECT source_revision FROM summaries WHERE transcript_id=?", arguments: [tid])
            let events = summaryRevision == currentRevision ? try Row.fetchAll(db, sql: "SELECT * FROM summary_events WHERE transcript_id=? AND first_line_id IS NOT NULL AND title!=? ORDER BY seq", arguments: [tid, MemoryRemoval.tombstoneText]) : []
            var index = 0
            while index < lines.count {
                var end = min(index + 8, lines.count)
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
                let firstDate = start.addingTimeInterval(Double(lines[index]["t_start_ms"] as Int) / 1000)
                for next in (index + 1)..<end {
                    let date = start.addingTimeInterval(Double(lines[next]["t_start_ms"] as Int) / 1000)
                    if !calendar.isDate(firstDate, inSameDayAs: date) { end = next; break }
                }
                var body = "", title = "录音原话"
                while true {
                    let group = Array(lines[index..<end])
                    let first: Int64 = group.first!["line_id"], last: Int64 = group.last!["line_id"]
                    let relevant = events.filter { ($0["first_line_id"] as Int64) <= last && ($0["last_line_id"] as Int64) >= first }
                    let eventObjects: [[String: Any]] = try relevant.map { event in
                        let eventID: Int64 = event["id"]
                        let root = try StreamContinuity.root(of: eventID, in: db)
                        let a: Int64 = event["first_line_id"], b: Int64 = event["last_line_id"]
                        var item: [String: Any] = ["event_id": eventID, "semantic_id": root, "title": event["title"] as String, "first_line_id": a, "last_line_id": b]
                        // A summary is offered only together with its complete, unredacted evidence.
                        if a >= first && b <= last && !all.contains(where: { ($0["line_id"] as Int64) >= a && ($0["line_id"] as Int64) <= b && ($0["redacted"] as Int) == 1 }) {
                            item["ai_summary"] = event["summary"] as String
                        }
                        return item
                    }
                    let originals: [[String: Any]] = group.map { row in
                        var line: [String: Any] = ["line_id": row["line_id"] as Int64, "seq": row["seq"] as Int,
                            "start_ms": row["t_start_ms"] as Int, "end_ms": row["t_end_ms"] as Int,
                            "text": row["text"] as String, "is_gap": (row["is_gap"] as Int) == 1]
                        if let person: Int64 = row["person_id"] { line["person_id"] = person; line["speaker"] = (row["name"] as String?) ?? (person == -1 ? "本人" : "未命名") }
                        if let method: String = row["attribution_source"] { line["attribution_source"] = method }
                        return line
                    }
                    let object: [String: Any] = ["schema": "apt.recording-source/1", "session_id": sid, "transcript_id": tid,
                        "transcript_version": t["version"] as Int, "transcript_part": t["part"] as Int,
                        "source": t["source"] as String, "session_started_at": started, "fragment": true,
                        "partial": partial, "events": eventObjects, "lines": originals]
                    body = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
                    title = utf16Prefix(relevant.first.map { $0["title"] as String } ?? "录音原话", limit: 256)
                    if body.utf16.count <= 15000 { break }
                    if end == index + 1 {
                        let first: Int64 = group[0]["line_id"]
                        let created = timestamp(start.addingTimeInterval(Double(group[0]["t_start_ms"] as Int) / 1000))
                        for record in try fragments(object: object, sid: sid, tid: tid, first: first, created: created, now: updatedAt, title: title, partial: partial) { desired[record.id] = record }
                        body = ""
                        break
                    }
                    end -= 1
                }
                let first: Int64 = lines[index]["line_id"]
                let created = timestamp(start.addingTimeInterval(Double(lines[index]["t_start_ms"] as Int) / 1000))
                let id = sourceID("session/\(sid)/transcript/\(tid)/line/\(first)")
                if !body.isEmpty { desired[id] = Record(id: id, session_id: sid, transcript_id: tid, revision: 1, created: created, updated: max(created, updatedAt), title: title, text: body, partial: partial, deleted: false) }
                index = end
            }
            let projected = desired.values.filter { $0.transcript_id == tid }
            let projectedBytes = try projected.reduce(0, { $0 + (try encoded($1)).utf8.count })
            if projected.count > 900 || projectedBytes > 6 * 1024 * 1024 {
                // Keep the original on the phone; publish an explicit unavailable source instead of blocking every other transcript.
                desired = desired.filter { $0.value.transcript_id != tid }
                let text = try encoded(["coverage": "原话过长，手机完整保留；本段正文尚未同步，不能据此回答或统计。", "session_id": String(sid), "transcript_id": String(tid)])
                let id = sourceID("session/\(sid)/transcript/\(tid)/unavailable")
                desired[id] = Record(id: id, session_id: sid, transcript_id: tid, revision: 1, created: timestamp(start), updated: max(timestamp(start), updatedAt), title: "录音原话待同步", text: text, partial: true, deleted: false)
            }
        }
        let existing = try Row.fetchAll(db, sql: "SELECT id,record_json FROM recording_memory_outbox")
        var prior: [String: Record] = [:]
        for row in existing { prior[row["id"] as String] = try JSONDecoder().decode(Record.self, from: Data((row["record_json"] as String).utf8)) }
        for (id, old) in prior where desired[id] == nil && !old.deleted {
            desired[id] = Record(id: id, session_id: old.session_id, transcript_id: old.transcript_id, revision: old.revision, created: old.created, updated: max(old.created, updatedAt), title: "已移出记忆", text: "", partial: old.partial, deleted: true)
        }
        for (id, var record) in desired {
            if let old = prior[id] {
                if record.created == old.created && record.title == old.title && record.text == old.text && record.partial == old.partial && record.deleted == old.deleted { continue }
                record.revision = old.revision + 1
            }
            try db.execute(sql: "INSERT INTO recording_memory_outbox(id,session_id,transcript_id,revision,record_json) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,record_json=excluded.record_json", arguments: [id, record.session_id, record.transcript_id, record.revision, try encoded(record)])
        }
    }
    private static func utf16Prefix(_ value: String, limit: Int) -> String {
        let units = Array(value.utf16)
        var end = min(limit, units.count)
        if end < units.count && end > 0 && (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
        return String(decoding: units.prefix(end), as: UTF16.self)
    }
    /// A long legal original never blocks unrelated sources or queued deletions. Keep exact UTF-16 spans.
    private static func fragments(object: [String: Any], sid: Int64, tid: Int64, first: Int64, created: String, now: String, title: String, partial: Bool) throws -> [Record] {
        var base = object
        var line = (object["lines"] as! [[String: Any]])[0]
        let units = Array((line["text"] as! String).utf16)
        line["text"] = ""
        line["line_text_fingerprint"] = SHA256.hash(data: Data(((object["lines"] as! [[String: Any]])[0]["text"] as! String).utf8)).map { String(format: "%02x", $0) }.joined()
        // A split line cannot carry a summary whose entire evidence is not in that fragment.
        base["events"] = (object["events"] as! [[String: Any]]).map { event in event.filter { $0.key != "ai_summary" } }
        base["lines"] = [line]
        if try JSONSerialization.data(withJSONObject: base).count > 4000 {
            base["events"] = []; base["event_metadata_omitted"] = true
            line.removeValue(forKey: "speaker"); base["lines"] = [line]
        }
        var result: [Record] = [], offset = 0
        repeat {
            var end = min(offset + 1000, units.count)
            if end < units.count && end > offset && (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            line["text"] = String(decoding: units[offset..<end], as: UTF16.self)
            line["char_from_utf16"] = offset; line["char_to_utf16"] = end; line["line_fragment"] = true
            base["lines"] = [line]; base["partial"] = true
            let text = String(decoding: try JSONSerialization.data(withJSONObject: base, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            guard text.utf16.count <= 15000 else { throw Failure.oversizedLine }
            let id = sourceID("session/\(sid)/transcript/\(tid)/line/\(first)/char/\(offset)")
            result.append(Record(id: id, session_id: sid, transcript_id: tid, revision: 1, created: created, updated: max(created, now), title: title, text: text, partial: true, deleted: false))
            offset = end
        } while offset < units.count
        return result
    }
    static func batch(destination: String, in db: Database) throws -> Batch {
        let device = try String.fetchOne(db, sql: "SELECT device_id FROM recording_memory_identity WHERE singleton=1")!
        let transcriptID = try Int64.fetchOne(db, sql: """
            SELECT o.transcript_id FROM recording_memory_outbox o LEFT JOIN recording_memory_receipts r
            ON r.destination=? AND r.id=o.id WHERE o.revision>COALESCE(r.revision,0)
            ORDER BY json_extract(o.record_json,'$.deleted') DESC,o.transcript_id LIMIT 1
            """, arguments: [destination])
        guard let transcriptID else { return Batch(device_id: device, records: []) }
        // A whole transcript's changed projections commit together in Worker D1. Group boundaries never mix versions.
        var rows = try Row.fetchAll(db, sql: """
            SELECT o.record_json FROM recording_memory_outbox o LEFT JOIN recording_memory_receipts r
            ON r.destination=? AND r.id=o.id WHERE o.revision>COALESCE(r.revision,0) AND o.transcript_id=?
            ORDER BY json_extract(o.record_json,'$.deleted') DESC,o.id
            """, arguments: [destination, transcriptID])
        if rows.count > 2000 || rows.reduce(0, { $0 + ($1["record_json"] as String).utf8.count }) >= 7 * 1024 * 1024 {
            rows = try rows.filter { try JSONDecoder().decode(Record.self, from: Data(($0["record_json"] as String).utf8)).deleted }.prefix(2000).map { $0 }
            guard !rows.isEmpty else { throw Failure.oversizedLine }
        }

        return Batch(device_id: device, records: try rows.map { try JSONDecoder().decode(Record.self, from: Data(($0["record_json"] as String).utf8)) })
    }
    static func acknowledge(_ data: Data, sent: Batch, destination: String, in db: Database) throws {
        struct Ack: Decodable { let id: String; let revision: Int64; let fingerprint: String? }
        struct Receipt: Decodable { let schema: String; let accepted: [Ack]; let stale: [Ack]; let conflicts: [Ack] }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        let expected = Dictionary(uniqueKeysWithValues: sent.records.map { ($0.id, $0.revision) })
        guard receipt.schema == "apt.recording-memory.receipt/1", receipt.stale.isEmpty, receipt.conflicts.isEmpty,
              receipt.accepted.count == expected.count, Set(receipt.accepted.map(\.id)).count == expected.count,
              receipt.accepted.allSatisfy({ expected[$0.id] == $0.revision && $0.fingerprint?.count == 64 }) else { throw Failure.invalidReceipt }
        for ack in receipt.accepted {
            try db.execute(sql: "INSERT INTO recording_memory_receipts(destination,id,revision) VALUES(?,?,?) ON CONFLICT(destination,id) DO UPDATE SET revision=MAX(revision,excluded.revision)", arguments: [destination, ack.id, ack.revision])
        }
    }
}

actor RecordingMemorySync {
    static let shared = RecordingMemorySync()
    typealias Send = @Sendable (RecordingMemoryProjection.Batch) async throws -> Data
    private var tasks: [String: Task<Void, Never>] = [:]
    func schedule(in db: DatabaseQueue, config: ProxyClient.Config?, trigger: ProcessingEvents.Trigger, send: Send? = nil) {
        guard let config else { return }
        let key = String(describing: ObjectIdentifier(db))
        guard tasks[key] == nil else { return }
        tasks[key] = Task {
            // Drain the existing bounded batch budget now; waiting for another timer tick
            // between every transcript makes initial backfill stall on phone auto-lock.
            do { _ = try await Self.sync(in: db, config: config, send: send) }
            catch { ProcessingEvents.record(trigger: trigger, outcome: "录音记忆尚未同步到输入法", detail: "正式记录已保留，下次处理机会继续同步：\(error)", in: db) }
            tasks[key] = nil
        }
    }
    static func sync(in db: DatabaseQueue, config: ProxyClient.Config, maxBatches: Int = 20, send: Send? = nil) async throws -> Int {
        guard config.baseURL.scheme == "https", config.baseURL.host != nil, config.baseURL.user == nil, config.baseURL.password == nil,
              config.baseURL.query == nil, config.baseURL.fragment == nil, ["", "/"].contains(config.baseURL.path) else { throw ProxyClient.Failure.notConfigured }
        let destination = config.baseURL.absoluteString
        var count = 0
        for _ in 0..<maxBatches {
            try Task.checkCancellation()
            let batch = try await db.write { database in
                try RecordingMemoryProjection.reconcile(now: ISO8601DateFormatter.growth.string(from: Date()), in: database)
                return try RecordingMemoryProjection.batch(destination: destination, in: database)
            }
            if batch.records.isEmpty { return count }
            let data: Data
            if let send { data = try await send(batch) }
            else {
                var request = URLRequest(url: config.baseURL.appendingPathComponent("recording-memory/sync"))
                request.httpMethod = "POST"; request.timeoutInterval = 5
                request.setValue(config.token, forHTTPHeaderField: "X-Growth-Token"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(try RecordingMemoryProjection.encoded(batch).utf8)
                let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 10
                let session = URLSession(configuration: configuration, delegate: RecordingMemoryNoRedirect(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (bytes, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProxyClient.Failure.badResponse("录音来源同步失败；待同步记录已保留") }
                data = bytes
            }
            try Task.checkCancellation()
            try await db.write { try RecordingMemoryProjection.acknowledge(data, sent: batch, destination: destination, in: $0) }
            count += batch.records.count
        }
        return count
    }
}
private final class RecordingMemoryNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

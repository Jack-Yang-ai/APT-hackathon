import Foundation
import CryptoKit
import GRDB

/// 输入法原文是独立来源：不建 transcript/session，不推断本人说过或事情已发生。
struct InputMemoryRecord: Codable, Equatable, Sendable {
    let deviceID: String
    let id: String
    let revision: Int64
    let created: String
    let updated: String
    let app: String
    let text: String
    let pasted: [String]
    let voiced: [String]
    let partial: Bool
    let deleted: Bool
    var eventSeq: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", id, revision, created, updated, app, text, pasted, voiced, partial, deleted
        case eventSeq = "event_seq"
    }

    /// event_seq 是传输位置，不参与来源内容身份。
    var canonicalJSON: String {
        let copy = InputMemoryRecord(deviceID: deviceID.lowercased(), id: id.lowercased(), revision: revision,
            created: created, updated: updated, app: app, text: text, pasted: pasted, voiced: voiced,
            partial: partial, deleted: deleted)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(data: try! encoder.encode(copy), encoding: .utf8)!
    }
    var contentHash: String {
        SHA256.hash(data: Data(canonicalJSON.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard UUID(uuidString: deviceID) != nil,
              id.hasPrefix("local_input_"), UUID(uuidString: String(id.dropFirst("local_input_".count))) != nil,
              revision > 0, revision <= 9_007_199_254_740_991,
              !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, app.utf16.count <= 256,
              text.utf16.count <= 8192,
              let start = Self.strictDate(created), let end = Self.strictDate(updated), start <= end,
              pasted.count <= 128, voiced.count <= 128,
              (pasted + voiced).allSatisfy({ !$0.isEmpty && text.contains($0) }),
              deleted ? (text.isEmpty && pasted.isEmpty && voiced.isEmpty) : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InputMemorySource.Failure.invalid("输入法来源身份、内容、版本或日期无效")
        }
    }

    /// 严格核对日历，不能让 Foundation 把 2 月 31 日自动归一成 3 月。
    private static func strictDate(_ text: String) -> Date? {
        guard let re = try? NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$"#) else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func number(_ group: Int) -> Int? { Int(ns.substring(with: match.range(at: group))) }
        guard let year = number(1), year > 0, let month = number(2), (1...12).contains(month),
              let day = number(3), (1...31).contains(day), let hour = number(4), (0...23).contains(hour),
              let minute = number(5), (0...59).contains(minute), let second = number(6), (0...59).contains(second) else { return nil }
        let zone = ns.substring(with: match.range(at: 8))
        var offset = 0
        if zone != "Z" {
            guard let hours = Int(zone.dropFirst().prefix(2)), let minutes = Int(zone.suffix(2)), hours <= 23, minutes <= 59 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1)
        }
        guard let timeZone = TimeZone(secondsFromGMT: offset) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        var parts = DateComponents(); parts.year = year; parts.month = month; parts.day = day
        parts.hour = hour; parts.minute = minute; parts.second = second
        guard let date = calendar.date(from: parts) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard checked.year == year, checked.month == month, checked.day == day,
              checked.hour == hour, checked.minute == minute, checked.second == second else { return nil }
        if match.range(at: 7).location != NSNotFound {
            let fraction = "0." + ns.substring(with: match.range(at: 7))
            guard let interval = Double(fraction) else { return nil }
            return date.addingTimeInterval(interval)
        }
        return date
    }

}

struct InputMemoryPage: Codable, Sendable {
    let schema: String
    let records: [InputMemoryRecord]
    let cursor: Int64
    let hasMore: Bool
    let watermark: Int64
    enum CodingKeys: String, CodingKey {
        case schema, records, cursor, watermark
        case hasMore = "has_more"
    }
}

struct InputMemorySource: Equatable, Sendable {
    let localID: Int64
    let record: InputMemoryRecord
    var hash: String { record.contentHash }

    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        case incomplete
        var description: String {
            switch self {
            case .invalid(let reason): return reason
            case .incomplete: return "输入法来源尚未接收完整，请稍后重试"
            }
        }
    }

    static func cursor(in db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT cursor FROM input_memory_sync WHERE singleton = 1") ?? 0
    }

    static func source(_ id: Int64, in db: Database) throws -> InputMemorySource? {
        guard let row = try Row.fetchOne(db, sql: "SELECT local_id, record_json FROM input_memory_sources WHERE local_id = ?", arguments: [id]) else { return nil }
        return try decode(row)
    }

    private static func decode(_ row: Row) throws -> InputMemorySource {
        let json: String = row["record_json"]
        return InputMemorySource(localID: row["local_id"], record: try JSONDecoder().decode(InputMemoryRecord.self, from: Data(json.utf8)))
    }

    /// 每页来源、旧答案清理和 cursor 在同一 savepoint 内提交。
    @discardableResult
    static func apply(_ page: InputMemoryPage, after: Int64, through: Int64? = nil, now: String, in db: Database) throws -> Int {
        var changed = 0
        try db.inSavepoint {
            let stored = try cursor(in: db)
            guard stored == after, page.schema == "growth.input-memory.changes/1",
                  page.cursor >= after, page.watermark >= page.cursor,
                  through == nil || through == page.watermark,
                  !page.hasMore || page.cursor > after,
                  page.hasMore || page.cursor == page.watermark,
                  page.records.count <= 100,
                  !page.records.isEmpty || (!page.hasMore && page.cursor == page.watermark),
                  through == nil || through! >= after else {
                throw Failure.invalid("输入法分页水位或游标无效")
            }
            var lastEvent = after
            for record in page.records {
                guard let seq = record.eventSeq, seq > lastEvent, seq <= page.cursor else {
                    throw Failure.invalid("输入法事件顺序无效或缺少 event_seq")
                }
                lastEvent = seq
                // 每日整理文档（echo_day_）不是输入草稿：手机暂不消费，跳过它让镜像继续前进，
                // 不然一页里只要有一条就会让游标永久卡住；未来需要时可在此选择性消费。
                if record.id.hasPrefix("echo_day_") { continue }
                try record.validate()
                let old = try Row.fetchOne(db, sql: "SELECT local_id, revision, content_hash FROM input_memory_sources WHERE device_id = ? AND record_id = ?", arguments: [record.deviceID.lowercased(), record.id.lowercased()])
                if let old {
                    let revision: Int64 = old["revision"]
                    if record.revision < revision { continue }
                    if record.revision == revision {
                        guard old["content_hash"] as String == record.contentHash else { throw Failure.invalid("同版本输入法来源出现不同内容") }
                        continue
                    }
                    try AskStore.removeInputDependentAnswers(localID: old["local_id"], in: db)
                    try db.execute(sql: "UPDATE input_memory_sources SET revision = ?, content_hash = ?, record_json = ?, updated_at = ?, deleted = ? WHERE local_id = ?", arguments: [record.revision, record.contentHash, record.canonicalJSON, record.updated, record.deleted, old["local_id"] as Int64])
                } else {
                    try db.execute(sql: "INSERT INTO input_memory_sources(device_id,record_id,revision,content_hash,record_json,updated_at,deleted) VALUES(?,?,?,?,?,?,?)", arguments: [record.deviceID.lowercased(), record.id.lowercased(), record.revision, record.contentHash, record.canonicalJSON, record.updated, record.deleted])
                }
                changed += 1
            }
            guard page.records.isEmpty || lastEvent == page.cursor else { throw Failure.invalid("输入法游标不是本页最后事件") }
            try db.execute(sql: "UPDATE input_memory_sync SET cursor = ?, last_success_at = ?, last_error = NULL WHERE singleton = 1", arguments: [page.cursor, now])
            return .commit
        }
        return changed
    }

    /// 关键词召回独立输入来源；最多提供 12 条、12000 字，不向模型倾倒全库。
    static func materials(_ question: String, scope: AskScope?, ready: Bool, in db: Database) throws -> [InputMemorySource] {
        guard ready, scope == nil else { return [] }
        return try search(question, in: db)
    }

    static func search(_ question: String, in db: Database, limit: Int = 12, bundle: Bundle = .main) throws -> [InputMemorySource] {
        let tokens = Array(Set(ChineseTokenizer.tokens(question).filter { $0.count > 1 })).sorted().prefix(16)
        let needles = tokens.map { "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%" }
        let filter = needles.isEmpty ? "" : " AND (" + needles.map { _ in "json_extract(record_json, '$.text') LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")"
        var all = try Row.fetchAll(db, sql: "SELECT local_id, record_json FROM input_memory_sources WHERE deleted = 0" + filter + " ORDER BY julianday(updated_at) DESC LIMIT 100", arguments: StatementArguments(needles)).map(decode)
        let wantsRecent = RecencyCue.wantsRecency(question, bundle: bundle)
        if wantsRecent {
            let recent = try Row.fetchAll(db, sql: "SELECT local_id, record_json FROM input_memory_sources WHERE deleted = 0 ORDER BY julianday(updated_at) DESC, local_id DESC LIMIT 6").map(decode)
            let existing = Set(all.map(\.localID))
            all += recent.filter { !existing.contains($0.localID) }
        }
        var ranked: [(source: InputMemorySource, score: Int)] = []
        for source in all {
            var score = 0
            for token in tokens where source.record.text.localizedCaseInsensitiveContains(token) { score += 1 }
            if tokens.isEmpty || score > 0 || wantsRecent { ranked.append((source, score)) }
        }
        ranked.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.source.localID > right.source.localID
        }
        var budget = 12000, result: [InputMemorySource] = []
        for (source, _) in ranked.prefix(max(0, min(limit, 12))) {
            // 不裁掉粘贴来源标记；过长记录留给专门原文读取，不伪造一个截断版本。
            let size = source.record.text.count + source.record.pasted.joined().count + source.record.voiced.joined().count
            guard size <= budget else { continue }
            result.append(source); budget -= size
        }
        return result
    }
}

/// 同一个库的并发刷新共享任务；请求沿用设置里的代理门禁，不引入新身份或 Agent。
actor InputMemorySourceSync {
    static let shared = InputMemorySourceSync()
    enum Result: Equatable, Sendable { case complete, partial, unconfigured, failed(String) }
    private struct Work { let token: UUID; let task: Task<Result, Never> }
    private var active: [String: Work] = [:]
    private var backgroundTasks: [String: Task<Void, Never>] = [:]
    private static let backgroundSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    private func key(for db: DatabaseQueue, config: ProxyClient.Config) -> String {
        String(describing: ObjectIdentifier(db)) + "|" + config.baseURL.absoluteString
            + "|" + SHA256.hash(data: Data(config.token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Actor 持有任务到完成，每次只有一页、总网络超时 5 秒；从不让录音泵 await 此任务。
    func scheduleBackground(in db: DatabaseQueue, config: ProxyClient.Config?, trigger: ProcessingEvents.Trigger,
                            fetch: Fetch? = nil) {
        guard let config else { return }
        let key = key(for: db, config: config)
        guard backgroundTasks[key] == nil, active[key] == nil else { return }
        backgroundTasks[key] = Task {
            let result = await refresh(in: db, config: config, maxPages: 1, background: true, fetch: fetch)
            switch result {
            case .failed(let message): ProcessingEvents.record(trigger: trigger, outcome: "输入法来源未刷新", detail: message, in: db)
            case .partial: ProcessingEvents.record(trigger: trigger, outcome: "输入来源已接收一页", detail: "剩余来源会在下一次机会或提问前接收", in: db)
            default: break
            }
            backgroundTasks[key] = nil
        }
    }

    /// 可观察实际持有的任务，用于生命周期验证。
    func hasBackgroundTask(in db: DatabaseQueue, config: ProxyClient.Config) -> Bool { backgroundTasks[key(for: db, config: config)] != nil }
    func waitForBackground(in db: DatabaseQueue, config: ProxyClient.Config) async {
        if let task = backgroundTasks[key(for: db, config: config)] { await task.value }
    }
    typealias Fetch = @Sendable (Int64, Int64?) async throws -> InputMemoryPage

    func refresh(in db: DatabaseQueue, config: ProxyClient.Config?, maxPages: Int = 20, freshWatermark: Bool = false, background: Bool = false, fetch: Fetch? = nil) async -> Result {
        guard let config else { return .unconfigured }
        let key = key(for: db, config: config)
        if let work = active[key] {
            let result = await work.task.value
            if !freshWatermark { return result }
            // Ask 要求在调用之后建立新水位，不能借用模型运行前已开始的后台同步。
            if let newer = active[key], newer.token != work.token { return await newer.task.value }
            if active[key]?.token == work.token { active[key] = nil }
        }
        let token = UUID()
        let task = Task { await Self.drain(in: db, maxPages: maxPages, allowPartial: background) { after, through in
            if let fetch { return try await fetch(after, through) }
            return try await Self.fetch(after: after, through: through, config: config, background: background)
        } }
        active[key] = Work(token: token, task: task)
        let result = await task.value
        if active[key]?.token == token { active[key] = nil }
        return result
    }

    /// Transport 可替换以测试页间失败，生产只走 fetch。
    static func drain(in db: DatabaseQueue, maxPages: Int = 20, allowPartial: Bool = false, fetch: Fetch) async -> Result {
        do {
            var through: Int64?
            for _ in 0..<maxPages {
                try Task.checkCancellation()
                let after = try await db.read { try InputMemorySource.cursor(in: $0) }
                let expectedWatermark = through
                let page = try await fetch(after, expectedWatermark)
                let stamp = ISO8601DateFormatter.growth.string(from: Date())
                let changed = try await db.write { try InputMemorySource.apply(page, after: after, through: expectedWatermark, now: stamp, in: $0) }
                // 每页已提交就通知；后续页失败不能让已删除的答案继续留在界面。
                if changed > 0 { NotificationCenter.default.post(name: MemoryRemoval.changed, object: nil) }
                through = page.watermark
                if !page.hasMore { return .complete }
            }
            if allowPartial { return .partial }
            throw InputMemorySource.Failure.incomplete
        } catch {
            let message = "输入法来源刷新失败：\(error)"
            do { try await db.write { try $0.execute(sql: "UPDATE input_memory_sync SET last_error = ? WHERE singleton = 1", arguments: [message]) } }
            catch { return .failed("\(message)；失败状态未能保存：\(error)") }
            return .failed(message)
        }
    }

    private static func fetch(after: Int64, through: Int64?, config: ProxyClient.Config, background: Bool = false) async throws -> InputMemoryPage {
        var components = URLComponents(url: config.baseURL.appendingPathComponent("input-memory/changes"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "limit", value: "100")]
        if let through { components.queryItems?.append(URLQueryItem(name: "through", value: String(through))) }
        guard let url = components.url else { throw ProxyClient.Failure.badResponse("输入法同步 URL 无效") }
        var request = URLRequest(url: url); request.setValue(config.token, forHTTPHeaderField: "X-Growth-Token")
        request.timeoutInterval = background ? 2 : 30
        let (data, response) = try await (background ? backgroundSession : ProxyClient.quick).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProxyClient.Failure.badResponse("输入法同步不是 HTTP 回复") }
        guard (200..<300).contains(http.statusCode) else { throw ProxyClient.Failure.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(InputMemoryPage.self, from: data)
    }
}

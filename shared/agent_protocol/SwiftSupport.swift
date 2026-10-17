import Foundation

protocol APTContractMessage: Codable { static var contractName: String { get } }
enum APTProtocolError: Error { case invalid(String) }
indirect enum APTJSONValue: Codable {
    case null, bool(Bool), number(Double), string(String), array([APTJSONValue]), object([String: APTJSONValue])
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let v = try? box.decode(Bool.self) { self = .bool(v) }
        else if let v = try? box.decode(Double.self) { self = .number(v) }
        else if let v = try? box.decode(String.self) { self = .string(v) }
        else if let v = try? box.decode([APTJSONValue].self) { self = .array(v) }
        else { self = .object(try box.decode([String: APTJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .null: try box.encodeNil()
        case .bool(let v): try box.encode(v)
        case .number(let v): try box.encode(v)
        case .string(let v): try box.encode(v)
        case .array(let v): try box.encode(v)
        case .object(let v): try box.encode(v)
        }
    }
    var object: [String: APTJSONValue] { if case .object(let v) = self { return v }; return [:] }
    var array: [APTJSONValue] { if case .array(let v) = self { return v }; return [] }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
}
enum APTAgentContract {
    static func encode<T: APTContractMessage>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        _ = try validateJSON(T.contractName, from: data)
        return data
    }
    static func decode<T: APTContractMessage>(_ type: T.Type, from data: Data) throws -> T {
        _ = try validateJSON(T.contractName, from: data)
        return try JSONDecoder().decode(type, from: data)
    }
    static func validateJSON(_ name: String, from data: Data) throws -> APTJSONValue {
        guard data.count <= 1_048_576 else { throw APTProtocolError.invalid("payload_too_large") }
        guard String(data: data, encoding: .utf8) != nil else { throw APTProtocolError.invalid("invalid_json_encoding") }
        var scanner = APTJSONKeyScanner(raw: Array(data))
        try scanner.scan()
        let value = try JSONDecoder().decode(APTJSONValue.self, from: data)
        try checkJSON(value)
        try validate(name, value: value)
        return value
    }
    static func validate(_ name: String, value: APTJSONValue) throws {
        let root = try JSONDecoder().decode(APTJSONValue.self, from: Data(aptProtocolSchemaText.utf8)).object
        let defs = root["$defs"]!.object
        guard let definition = defs[name] else { throw APTProtocolError.invalid("unknown_contract") }
        try check(definition.object, value, defs)
        let v = value.object
        let authority = name == "Authority" ? v : v["authority"]?.object
        if let a = authority, (a["phase"]?.string == "backend") != ((a["epoch"]?.number ?? 0) > 0) {
            throw APTProtocolError.invalid("authority_epoch_mismatch")
        }
        if name == "SourceSnapshot", v["deleted"]?.bool == true, v["text"]?.string != "" || !(v["attributes"]?.object.isEmpty ?? false) {
            throw APTProtocolError.invalid("tombstone_contains_content")
        }
        if ["ExecutionRequest", "ExecutionReceipt", "CommandEnvelope", "CommandReceipt", "ContentReadRequest", "ContentQueryRequest", "ContentValidateRequest", "CommandReceiptReadRequest"].contains(name), authority?["phase"]?.string != "backend" {
            throw APTProtocolError.invalid("backend_authority_required")
        }
        let target = name == "CommandTarget" ? v : v["target"]?.object
        if let t = target {
            let invalid = t["kind"]?.string == "source" ? t["source"]!.isNull || !t["entity_id"]!.isNull : !t["source"]!.isNull || t["entity_id"]!.isNull
            if invalid { throw APTProtocolError.invalid("invalid_command_target") }
        }
        if name == "CommandReceipt" {
            if v["state"]?.string == "accepted", v["applied_revision"]!.isNull || !v["error"]!.isNull { throw APTProtocolError.invalid("accepted_revision_required") }
            if v["state"]?.string != "accepted", v["error"]!.isNull { throw APTProtocolError.invalid("command_error_required") }
        }
        if name == "ExecutionReceipt" {
            let state = v["state"]!.string!, error = v["error"]!
            if ["failed", "unknown"].contains(state), error.isNull { throw APTProtocolError.invalid("execution_error_required") }
            if state == "unknown", error.object["retryable"]?.bool == true { throw APTProtocolError.invalid("unknown_result_cannot_auto_retry") }
            if state == "succeeded", !error.isNull || (v["result"]!.isNull && v["operation_id"]!.isNull) { throw APTProtocolError.invalid("success_requires_receipt") }
        }
    }
    private static func check(_ s: [String: APTJSONValue], _ value: APTJSONValue, _ defs: [String: APTJSONValue]) throws {
        func fail() throws -> Never { throw APTProtocolError.invalid("invalid_contract_value") }
        if let ref = s["$ref"]?.string { try check(defs[String(ref.dropFirst(8))]!.object, value, defs); return }
        if let alternatives = s["anyOf"] {
            for item in alternatives.array { if (try? check(item.object, value, defs)) != nil { return } }
            try fail()
        }
        if let constant = s["const"]?.string, value.string != constant { try fail() }
        if let allowed = s["enum"], !allowed.array.compactMap(\.string).contains(value.string ?? "") { try fail() }
        switch s["type"]?.string {
        case "null": if !value.isNull { try fail() }
        case "boolean": if value.bool == nil { try fail() }
        case "integer":
            guard let n = value.number, n.isFinite, n.rounded() == n, n >= (s["minimum"]?.number ?? -Double.infinity), n <= (s["maximum"]?.number ?? Double.infinity) else { try fail() }
        case "string":
            guard let text = value.string, text.unicodeScalars.count >= Int(s["minLength"]?.number ?? 0), Double(text.unicodeScalars.count) <= (s["maxLength"]?.number ?? Double.infinity) else { try fail() }
            if let pattern = s["pattern"]?.string {
                guard let match = text.range(of: pattern, options: .regularExpression),
                      match.lowerBound == text.startIndex, match.upperBound == text.endIndex else { try fail() }
            }
            if s["format"]?.string == "date-time" {
                let pattern = #"^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$"#
                guard let match = text.range(of: pattern, options: .regularExpression),
                      match.lowerBound == text.startIndex, match.upperBound == text.endIndex else { try fail() }
                let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fraction = formatter.date(from: text)
                formatter.formatOptions = [.withInternetDateTime]
                guard parts.count == 3, parts[0] > 0, (fraction ?? formatter.date(from: text)) != nil, (1...12).contains(parts[1]) else { try fail() }
                let leap = parts[0] % 4 == 0 && (parts[0] % 100 != 0 || parts[0] % 400 == 0)
                let days = [31, leap ? 29 : 28,31,30,31,30,31,31,30,31,30,31]
                guard (1...days[parts[1]-1]).contains(parts[2]) else { try fail() }
            }
        case "array":
            guard case .array(let items) = value, Double(items.count) <= (s["maxItems"]?.number ?? Double.infinity) else { try fail() }
            for item in items { try check(s["items"]!.object, item, defs) }
        case "object":
            guard case .object(let fields) = value else { try fail() }
            let properties = s["properties"]?.object ?? [:]
            if (s["required"]?.array ?? []).contains(where: { fields[$0.string!] == nil }) { try fail() }
            if s["additionalProperties"]?.bool == false, fields.keys.contains(where: { properties[$0] == nil }) { try fail() }
            for (key, item) in fields { if let property = properties[key] { try check(property.object, item, defs) } else { try checkJSON(item) } }
        default: break
        }
    }
    private static func checkJSON(_ value: APTJSONValue, depth: Int = 0) throws {
        guard depth <= 64 else { throw APTProtocolError.invalid("json_depth_exceeded") }
        switch value {
        case .number(let n): if !n.isFinite || (n.rounded() == n && abs(n) > 9_007_199_254_740_991) { throw APTProtocolError.invalid("unsafe_number") }
        case .array(let items): for item in items { try checkJSON(item, depth: depth + 1) }
        case .object(let fields): for item in fields.values { try checkJSON(item, depth: depth + 1) }
        default: break
        }
    }
}

// Inspect keys before JSONDecoder can silently choose one duplicate value.
// JSONDecoder remains responsible for JSON syntax and Unicode validation.
private struct APTJSONKeyScanner {
    let raw: [UInt8]
    var at = 0
    mutating func scan() throws {
        try value(0)
        space()
        guard at == raw.count else { throw APTProtocolError.invalid("invalid_json_encoding") }
    }
    private mutating func space() {
        while at < raw.count && [32,9,10,13].contains(raw[at]) { at += 1 }
    }
    private mutating func token() throws -> Data {
        let start = at
        at += 1
        while at < raw.count {
            let char = raw[at]
            at += 1
            if char == 92 { at += 1; continue }
            if char == 34 { return Data(raw[start..<at]) }
        }
        throw APTProtocolError.invalid("invalid_json_encoding")
    }
    private mutating func value(_ depth: Int) throws {
        guard depth <= 64 else { throw APTProtocolError.invalid("json_depth_exceeded") }
        space()
        guard at < raw.count else { throw APTProtocolError.invalid("invalid_json_encoding") }
        let char = raw[at]
        if char == 34 { _ = try token(); return }
        if char == 123 || char == 91 {
            let isObject = char == 123, end: UInt8 = isObject ? 125 : 93
            var seen = Set<String>()
            at += 1
            space()
            if at < raw.count && raw[at] == end { at += 1; return }
            while true {
                if isObject {
                    guard at < raw.count && raw[at] == 34 else { throw APTProtocolError.invalid("invalid_json_encoding") }
                    let key = try JSONDecoder().decode(String.self, from: token()).precomposedStringWithCanonicalMapping
                    guard seen.insert(key).inserted else { throw APTProtocolError.invalid("duplicate_json_key") }
                    space()
                    guard at < raw.count && raw[at] == 58 else { throw APTProtocolError.invalid("invalid_json_encoding") }
                    at += 1
                }
                try value(depth + 1)
                space()
                guard at < raw.count else { throw APTProtocolError.invalid("invalid_json_encoding") }
                if raw[at] == end { at += 1; return }
                guard raw[at] == 44 else { throw APTProtocolError.invalid("invalid_json_encoding") }
                at += 1
                space()
            }
        }
        let start = at
        while at < raw.count && ![32,9,10,13,44,125,93].contains(raw[at]) { at += 1 }
        guard at > start else { throw APTProtocolError.invalid("invalid_json_encoding") }
    }
}

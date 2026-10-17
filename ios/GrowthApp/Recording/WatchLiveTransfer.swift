import CryptoKit
import Foundation

/// 可即时通信时主动传送同一外发文件；后台 transferFile 仍持有原文件。
/// 字节片段只用于传输，只有整文件校验及落盘后的回执才能释放外发账。
enum WatchLiveTransfer {
    static let version = 1
    // JSON 的 Data 会展开为 base64，24 KiB 为整份消息留出充分元数据空间。
    static let chunkBytes = 24 * 1024
    static let maxPacketBytes = 64 * 1024
    // 超过此界限走原有文件通道，拒绝主动分配巨量中间文件。
    static let maxFileBytes = 32 * 1024 * 1024

    struct Header: Codable, Equatable {
        var version = WatchLiveTransfer.version
        let message: WatchMessage
        let totalBytes: Int
        let sha256: String
    }
    struct Packet: Codable {
        let header: Header
        let offset: Int
        let bytes: Data
    }
    struct Receipt: Codable, Equatable {
        let key: String
        let sha256: String
        let nextOffset: Int
        let complete: Bool
        var error: String?
    }
    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            if case .invalid(let reason) = self { return reason }
            return "主动同步未完成"
        }
    }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return d
    }
    static func encode(_ packet: Packet) throws -> Data {
        try validate(packet)
        let data = try encoder.encode(packet)
        guard data.count <= maxPacketBytes else { throw Failure.invalid("同步消息过大") }
        return data
    }
    static func decode(_ data: Data) throws -> Packet {
        guard data.count <= maxPacketBytes else { throw Failure.invalid("同步消息过大") }
        let packet = try decoder.decode(Packet.self, from: data)
        try validate(packet)
        return packet
    }
    static func encode(_ receipt: Receipt) throws -> Data { try encoder.encode(receipt) }
    static func receipt(from data: Data, for packet: Packet) throws -> Receipt {
        try validate(packet)
        guard data.count <= maxPacketBytes else { throw Failure.invalid("同步回执过大") }
        let reply = try decoder.decode(Receipt.self, from: data)
        if let error = reply.error { throw Failure.invalid(error) }
        guard reply.key == packet.header.message.key,
              reply.sha256 == packet.header.sha256,
              reply.nextOffset >= packet.offset + packet.bytes.count,
              reply.nextOffset <= packet.header.totalBytes,
              reply.complete == (reply.nextOffset == packet.header.totalBytes) else {
            throw Failure.invalid("手机同步回执与文件不一致")
        }
        return reply
    }
    static func validate(_ packet: Packet) throws {
        let h = packet.header, m = h.message
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard h.version == version, m.v == WatchLink.version,
              !m.installID.isEmpty, m.installID.count <= 128,
              m.installID.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              m.msgSeq >= 0, m.msgSeq < Int.max,
              BlockLedger.date(forDayKey: m.day) != nil,
              h.totalBytes > 0, h.totalBytes <= maxFileBytes,
              h.sha256.count == 64,
              h.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              packet.offset >= 0, packet.offset <= h.totalBytes,
              !packet.bytes.isEmpty, packet.bytes.count <= chunkBytes,
              packet.bytes.count <= h.totalBytes - packet.offset else {
            throw Failure.invalid("主动同步版本、身份或字节边界无效")
        }
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

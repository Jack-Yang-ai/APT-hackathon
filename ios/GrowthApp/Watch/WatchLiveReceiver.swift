import Foundation

/// 由 WatchInbox 的唯一串行收件队列调用。部分字节从不进入 WatchMirror。
enum WatchLiveReceiver {
    struct Result {
        let receipt: WatchLiveTransfer.Receipt
        let landing: WatchInbox.Landing?
    }

    /// 后台原件先送达时，可清掉同一文件的主动传送中间副本；冲突材料不碰。
    static func discardReceivedPartial(for msg: WatchMessage, inbox: URL) throws {
        let dir = inbox.appendingPathComponent("live").appendingPathComponent(msg.key)
        let manifest = dir.appendingPathComponent("header.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(WatchLiveTransfer.Header.self, from: Data(contentsOf: manifest))
        guard try WatchLink.data(header.message) == WatchLink.data(msg) else { return }
        let hash = msg.isBlock
            ? try String(contentsOf: inbox.appendingPathComponent("\(msg.key).sha256"), encoding: .utf8)
            : try WatchLiveTransfer.hash(WatchLink.data(msg))
        guard hash == header.sha256 else { return }
        try FileManager.default.removeItem(at: dir)
    }

    static func accept(_ packet: WatchLiveTransfer.Packet, inbox: URL) throws -> Result {
        try WatchLiveTransfer.validate(packet)
        let header = packet.header, msg = header.message
        try WatchMirror.validateEnvelope(msg)
        let fm = FileManager.default
        // 后台原件可能在两段主动消息之间落盘并清理了 partial；直接确认已核的同一收据。
        let received = inbox.appendingPathComponent("\(msg.key).msg.json")
        if fm.fileExists(atPath: received.path),
           try Data(contentsOf: received) == WatchLink.data(msg) {
            let hash: String?
            if msg.isBlock {
                hash = try? String(contentsOf: inbox.appendingPathComponent("\(msg.key).sha256"), encoding: .utf8)
            } else {
                let marker = try WatchLink.data(msg)
                hash = header.totalBytes == marker.count ? WatchLiveTransfer.hash(marker) : nil
            }
            if hash == header.sha256 {
                try? discardReceivedPartial(for: msg, inbox: inbox)
                return Result(receipt: .init(key: msg.key, sha256: header.sha256,
                    nextOffset: header.totalBytes, complete: true), landing: .duplicate)
            }
        }
        let dir = inbox.appendingPathComponent("live").appendingPathComponent(msg.key)
        let manifest = dir.appendingPathComponent("header.json")
        let payload = dir.appendingPathComponent("payload")
        if fm.fileExists(atPath: manifest.path) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            guard try d.decode(WatchLiveTransfer.Header.self, from: Data(contentsOf: manifest)) == header else {
                throw WatchLiveTransfer.Failure.invalid("同一同步号传来了不同文件，已保留原件")
            }
        } else {
            if fm.fileExists(atPath: dir.path) {
                try fm.moveItem(at: dir, to: dir.appendingPathExtension("orphan-\(UUID().uuidString)"))
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            try e.encode(header).write(to: manifest, options: .atomic)
        }
        if !fm.fileExists(atPath: payload.path) { try Data().write(to: payload, options: .atomic) }
        let handle = try FileHandle(forUpdating: payload)
        let size64 = try handle.seekToEnd()
        guard size64 <= UInt64(header.totalBytes) else {
            try? handle.close()
            throw WatchLiveTransfer.Failure.invalid("同步中间文件的长度异常，原件已保留")
        }
        let size = Int(size64)
        guard packet.offset <= size else {
            try? handle.close()
            throw WatchLiveTransfer.Failure.invalid("同步片段前面有缺口，需要重试")
        }
        do {
            // 回执丢失或重启后的重传必须核重复字节；半次 append 也可从重叠处补完。
            let overlap = min(packet.bytes.count, size - packet.offset)
            if overlap > 0 {
                try handle.seek(toOffset: UInt64(packet.offset))
                guard try handle.read(upToCount: overlap) == packet.bytes.prefix(overlap) else {
                    throw WatchLiveTransfer.Failure.invalid("重复同步片段内容不一致，原件已保留")
                }
            }
            if overlap < packet.bytes.count {
                try handle.seekToEnd()
                try handle.write(contentsOf: packet.bytes.dropFirst(overlap))
            }
            try handle.synchronize()
            let next = Int(try handle.seekToEnd())
            try handle.close()
            guard next == header.totalBytes else {
                return Result(receipt: .init(key: msg.key, sha256: header.sha256,
                    nextOffset: next, complete: false), landing: nil)
            }
        } catch {
            try? handle.close()
            throw error
        }
        guard try WatchLiveTransfer.digest(payload) == header.sha256 else {
            try fm.moveItem(at: dir, to: dir.appendingPathExtension("corrupt-\(UUID().uuidString)"))
            throw WatchLiveTransfer.Failure.invalid("同步文件摘要不符，已保留损坏副本，后台原件仍可恢复")
        }
        if !msg.isBlock {
            guard try Data(contentsOf: payload) == WatchLink.data(msg) else {
                throw WatchLiveTransfer.Failure.invalid("同步标记与消息元数据不一致")
            }
        }
        let landed = try WatchInbox.land(payload, msg: msg, into: inbox)
        // 正式收据已写，删除临时副本失败不影响正式录音或回执。
        try? fm.removeItem(at: dir)
        return Result(receipt: .init(key: msg.key, sha256: header.sha256,
            nextOffset: header.totalBytes, complete: landed != .conflict,
            error: landed == .conflict ? "同一同步号出现不同内容，两份已保留" : nil), landing: landed)
    }
}

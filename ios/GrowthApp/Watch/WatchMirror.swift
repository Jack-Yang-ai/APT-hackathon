import Foundation
import GRDB

/// 收件箱 -> 镜像账本 -> 既有处理队列。由 WatchInbox 的串行队列独占调用。
/// 文件提交顺序:预留块号落盘 -> 音频 -> 账本 -> 同步/入队 -> 游标。
/// 任一步失败都保留收件材料,重开重放;已提交的账本条目不追加第二遍。
enum WatchMirror {
    struct Progress: Codable {
        var next: [String: Int] = [:]
        var blockMap: [String: Int] = [:]
        var blockDigests: [String: String] = [:]
        var blockEntries: [String: LedgerEntry] = [:]
    }
    struct Report: Equatable {
        var applied = 0
        var notices: [String] = []
    }
    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { if case .invalid(let s) = self { return s }; return "手表同步失败" }
    }

    /// 先验证路径身份。未来版本也可以安全留在收件箱,但不应用。
    static func validateEnvelope(_ msg: WatchMessage) throws {
        let valid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !msg.installID.isEmpty, msg.installID.count <= 128,
              msg.installID.unicodeScalars.allSatisfy({ valid.contains($0) }),
              msg.msgSeq >= 0, msg.msgSeq < Int.max,
              BlockLedger.date(forDayKey: msg.day) != nil else {
            throw Failure.invalid("手表消息的安装号、序号或日期无效,录音没有应用")
        }
    }

    static func digest(_ url: URL) throws -> String {
        try WatchLiveTransfer.digest(url)
    }

    static func drain(inbox: URL, root: URL = RecordingPaths.root,
                      now: Date = Date(), in db: DatabaseQueue) throws -> Report {
        try RecordingPaths.withFileAccess { try drainLocked(inbox: inbox, root: root, now: now, in: db) }
    }

    private static func drainLocked(inbox: URL, root: URL, now: Date, in db: DatabaseQueue) throws -> Report {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inbox.path) else { return Report() }
        let progressURL = inbox.appendingPathComponent("progress.json")
        var progress = fm.fileExists(atPath: progressURL.path)
            ? try JSONDecoder().decode(Progress.self, from: Data(contentsOf: progressURL)) : Progress()
        guard progress.next.values.allSatisfy({ $0 >= 0 }),
              progress.blockMap.values.allSatisfy({ $0 >= 0 && $0 <= Int(Int32.max) }) else {
            throw Failure.invalid("手表同步游标损坏,材料仍保留在收件箱")
        }
        guard Set(progress.blockMap.keys) == Set(progress.blockEntries.keys) else {
            throw Failure.invalid("手表块映射的身份记录损坏")
        }
        func save() throws { try JSONEncoder().encode(progress).write(to: progressURL, options: .atomic) }
        let files = try fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        var pending: [String: [Int: WatchMessage]] = [:]
        var conflicts = Set<String>()
        var report = Report()
        for url in files where url.lastPathComponent.hasSuffix(".msg.json") {
            do {
                let msg = try WatchLink.message(from: Data(contentsOf: url))
                try validateEnvelope(msg)
                if url.lastPathComponent.contains(".conflict-") {
                    conflicts.insert(msg.key)
                    report.notices.append("手表第 \(msg.msgSeq) 条传来了不同内容,两份都已保留,请检查同步记录")
                    continue
                }
                guard url.lastPathComponent == "\(msg.key).msg.json" else {
                    throw Failure.invalid("手表消息文件名与身份不一致")
                }
                pending[msg.installID, default: [:]][msg.msgSeq] = msg
            } catch { report.notices.append("手表收件无法读取: \(error)") }
        }
        // 每个已应用号必须仍有收据及对应账本。合法JSON中的跳号也是损坏。
        for (install, expected) in progress.next where expected > 0 {
            let receipts = pending[install] ?? [:]
            guard receipts.keys.filter({ $0 < expected }).count == expected else {
                throw Failure.invalid("手表同步游标越过了消息收据,材料仍保留")
            }
            var ledgers: [String: [LedgerEntry]] = [:]
            for msg in receipts.values where msg.msgSeq < expected {
                if ledgers[msg.day] == nil {
                    let url = RecordingPaths.audioDir(day: msg.day, source: SessionSource.watch, root: root)
                        .appendingPathComponent(AudioWipe.ledgerName)
                    ledgers[msg.day] = try readLedger(url)
                }
                let applied: LedgerEntry
                if let b = msg.entry.block {
                    let key = "\(install)|\(msg.day)|\(b.seq)"
                    guard let seq = progress.blockMap[key], progress.blockEntries[key] == msg.entry else {
                        throw Failure.invalid("手表已应用块的身份记录损坏")
                    }
                    applied = LedgerEntry(block: BlockRecord(seq: seq, startedAt: b.startedAt,
                        endedAt: b.endedAt, hardCut: b.hardCut, fileName: String(format: "block-%04d.m4a", seq)))
                } else { applied = msg.entry }
                guard WatchLink.alreadyApplied(applied, in: ledgers[msg.day] ?? []) else {
                    throw Failure.invalid("手表同步游标与账本不一致,材料仍保留")
                }
            }
        }
        // 同时到达多次安装的录音时,先处理开场较早的一次,避免顺序由UUID决定。
        let installs = pending.keys.sorted {
            let a = pending[$0]?.values.map(\.entry.at).min() ?? .distantFuture
            let b = pending[$1]?.values.map(\.entry.at).min() ?? .distantFuture
            return a == b ? $0 < $1 : a < b
        }
        for install in installs {
            let messages = pending[install] ?? [:]
            let plan = WatchLink.plan(nextExpected: progress.next[install] ?? 0,
                                      pending: Array(messages.keys))
            if let missing = plan.missing {
                report.notices.append("手表还有第 \(missing) 条没传到,后面的录音会等它补齐")
            }
            // 游标提交后清理被打断时留下的第二份音频,不重新应用/恢复已清除的块。
            for seq in plan.duplicates {
                if let msg = messages[seq] {
                    let audio = inbox.appendingPathComponent("\(msg.key).m4a")
                    if fm.fileExists(atPath: audio.path) { try fm.removeItem(at: audio) }
                }
            }
            for seq in plan.apply {
                guard let msg = messages[seq] else { continue }
                do {
                    guard !conflicts.contains(msg.key) else {
                        throw Failure.invalid("手表第 \(seq) 条内容冲突,同步暂时停在这里")
                    }
                    guard msg.v == WatchLink.version else {
                        throw Failure.invalid("手表同步版本 \(msg.v) 暂不支持,请更新手机与手表 App")
                    }
                    let dir = RecordingPaths.audioDir(day: msg.day, source: SessionSource.watch, root: root)
                    let ledgerURL = dir.appendingPathComponent(AudioWipe.ledgerName)
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let entries = fm.fileExists(atPath: ledgerURL.path)
                        ? try readLedger(ledgerURL) : []
                    let entry = try mappedEntry(msg, entries: entries, inbox: inbox, dir: dir,
                                                progress: &progress, saveReservation: { p in
                        try JSONEncoder().encode(p).write(to: progressURL, options: .atomic)
                    })
                    if !WatchLink.alreadyApplied(entry, in: entries) {
                        // 不猜归属,不把旧安装的迟到录音接进新安装的当前场。
                        if let last = entries.last, entry.at < last.at {
                            throw Failure.invalid("手表旧录音的时间早于已同步记录,材料已保留,需要检查后再同步")
                        }
                        try validateContext(entry, message: msg, receipts: messages, entries: entries)
                        try BlockLedger.append(entry, to: ledgerURL)
                    }
                    let all = BlockLedger.sessions(entries: try BlockLedger.read(from: ledgerURL).entries)
                    try SessionBridge.sync(all, day: msg.day, in: db)
                    let ids = try db.read { d in
                        try Int64.fetchAll(d, sql: "SELECT id FROM sessions WHERE day = ? AND source = ? AND removed_at IS NULL",
                                           arguments: [msg.day, SessionSource.watch])
                    }
                    for id in ids {
                        try ProcessingOrchestrator.enqueueSession(id,
                            now: ISO8601DateFormatter.growth.string(from: now), in: db)
                    }
                    progress.next[install] = seq + 1
                    try save()
                    // 消息与摘要留作幂等收据。音频已进保留期管理,不在收件箱占第二份空间。
                    let audio = inbox.appendingPathComponent("\(msg.key).m4a")
                    if fm.fileExists(atPath: audio.path) { try fm.removeItem(at: audio) }
                    report.applied += 1
                } catch {
                    report.notices.append("手表第 \(seq) 条还没同步: \(error)")
                    break // 不越过失败的号。
                }
            }
        }
        report.notices = Array(Set(report.notices)).sorted()
        return report
    }

    private static func readLedger(_ url: URL) throws -> [LedgerEntry] {
        let raw = try Data(contentsOf: url)
        let read = try BlockLedger.read(from: url)
        if read.truncatedTail && raw.last == 0x0A {
            throw Failure.invalid("手表镜像账本已提交的末行损坏,不能跳过")
        }
        // 完整JSON但未写到换行也未提交;与append截断尾行的口径一致。
        return raw.last != 0x0A && !read.truncatedTail ? Array(read.entries.dropLast()) : read.entries
    }

    private static func validateContext(_ entry: LedgerEntry, message: WatchMessage,
                                        receipts: [Int: WatchMessage], entries: [LedgerEntry]) throws {
        // 明确的新开场本身就是边界。BlockLedger.sessions 已会把旧场停在最后
        // 完成块尾部；这里不能再要求旧安装发来可能永远不存在的结束消息。
        if entry.kind == SessionMark.sessionStarted.rawValue { return }
        guard let session = BlockLedger.sessions(entries: entries).last, session.isOpen else {
            throw Failure.invalid("手表这一条没有对应的开场记录")
        }
        // 收据按安装号保留且顺序门已应用此前所有消息。迟到旧块或旧结束即使
        // 时间晚于新开场，也只能属于它自己安装内最近的开场，不能关掉新场。
        let start = receipts.values.filter {
            $0.msgSeq < message.msgSeq && $0.day == message.day
                && $0.entry.kind == SessionMark.sessionStarted.rawValue
        }.max { $0.msgSeq < $1.msgSeq }
        guard start?.entry.at == session.startedAt else {
            throw Failure.invalid("手表旧录音不属于当前场次，材料已保留，未拼入新场")
        }
        if let b = entry.block, let session = BlockLedger.sessions(entries: entries).last {
            guard b.startedAt >= session.startedAt,
                  b.startedAt >= (session.blocks.last?.endedAt ?? session.startedAt) else {
                throw Failure.invalid("手表音频块的起点早于本场或前一块,没有拼入这一场")
            }
        }
    }

    private static func mappedEntry(_ msg: WatchMessage, entries: [LedgerEntry], inbox: URL, dir: URL,
                                    progress: inout Progress,
                                    saveReservation: (Progress) throws -> Void) throws -> LedgerEntry {
        let e = msg.entry
        let secondsLimit = Double(Int.max / 1000) / 4
        let times = [e.at] + (e.block.map { [$0.startedAt, $0.endedAt] } ?? [])
        guard times.allSatisfy({ $0.timeIntervalSince1970.isFinite && abs($0.timeIntervalSince1970) < secondsLimit }) else {
            throw Failure.invalid("手表音频时间超出可表示范围")
        }
        if let b = e.block {
            guard e.kind == LedgerEntry.blockKind, e.source == nil, b.seq >= 0, b.seq < Int(Int32.max),
                  b.startedAt <= b.endedAt, e.at == b.endedAt,
                  b.fileName == String(format: "block-%04d.m4a", b.seq) else {
                throw Failure.invalid("手表音频块契约无效")
            }
            let audio = inbox.appendingPathComponent("\(msg.key).m4a")
            let receipt = inbox.appendingPathComponent("\(msg.key).sha256")
            let hash = FileManager.default.fileExists(atPath: audio.path)
                ? try digest(audio) : try String(contentsOf: receipt, encoding: .utf8)
            if FileManager.default.fileExists(atPath: audio.path) {
                try Data(hash.utf8).write(to: receipt, options: .atomic)
            }
            let mapKey = "\(msg.installID)|\(msg.day)|\(b.seq)"
            if let original = progress.blockEntries[mapKey], original != e {
                throw Failure.invalid("手表同一块号的时间或切点发生变化,没有复用旧音频")
            }
            var mapped = progress.blockMap[mapKey]
            if mapped == nil {
                // 重装重发整本账时,块号可能已经被之前的安装重编号。按音频与时间核同一块。
                mapped = entries.compactMap(\.block).first {
                    $0.startedAt == b.startedAt && $0.endedAt == b.endedAt && $0.hardCut == b.hardCut
                    && progress.blockDigests["\(msg.day)|\($0.seq)"] == hash
                }?.seq
                if mapped == nil {
                    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                    let onDisk = names.compactMap { name -> Int? in
                        guard name.hasPrefix("block-"), name.hasSuffix(".m4a") else { return nil }
                        return Int(name.dropFirst(6).dropLast(4))
                    }
                    let reserved = progress.blockMap.filter { $0.key.contains("|\(msg.day)|") }.map(\.value)
                    guard onDisk.allSatisfy({ $0 >= 0 && $0 <= Int(Int32.max) }) else {
                        throw Failure.invalid("手表目录中的块号损坏")
                    }
                    let used = Set(entries.compactMap { $0.block?.seq } + onDisk + reserved)
                    guard (used.max() ?? -1) < Int(Int32.max) else {
                        throw Failure.invalid("手表音频块号已经用尽,材料仍保留")
                    }
                    mapped = used.contains(b.seq) ? (used.max() ?? -1) + 1 : b.seq
                }
                progress.blockEntries[mapKey] = e
                progress.blockMap[mapKey] = mapped
                progress.blockDigests["\(msg.day)|\(mapped!)"] = hash
                try saveReservation(progress) // 崩在音频/账本中间也必须保留这个号。
            }
            guard let seq = mapped, seq >= 0,
                  progress.blockDigests["\(msg.day)|\(seq)"] == hash else {
                throw Failure.invalid("手表同一块号出现不同音频,没有覆盖原文件")
            }
            let name = String(format: "block-%04d.m4a", seq)
            let result = LedgerEntry(block: BlockRecord(seq: seq, startedAt: b.startedAt,
                endedAt: b.endedAt, hardCut: b.hardCut, fileName: name))
            if !WatchLink.alreadyApplied(result, in: entries) {
                let dest = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: dest.path) {
                    guard try digest(dest) == hash else { throw Failure.invalid("手表目标音频已在且不同,没有覆盖") }
                } else {
                    // 复制中的半文件从不占用最终块名;同目录rename是音频提交点。
                    let staging = dir.appendingPathComponent(".incoming-\(msg.key).m4a")
                    if FileManager.default.fileExists(atPath: staging.path) {
                        try FileManager.default.removeItem(at: staging)
                    }
                    try FileManager.default.copyItem(at: audio, to: staging)
                    guard try digest(staging) == hash else { throw Failure.invalid("手表音频复制不完整") }
                    try FileManager.default.moveItem(at: staging, to: dest)
                }
            }
            return result
        }
        guard let mark = SessionMark(rawValue: e.kind),
              (mark == .sessionStarted ? e.source == SessionSource.watch : e.source == nil) else {
            throw Failure.invalid("手表标记或来源不符合契约")
        }
        return e
    }
}

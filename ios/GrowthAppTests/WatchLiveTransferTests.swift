import XCTest
import GRDB
@testable import GrowthApp

final class WatchLiveTransferTests: XCTestCase {
    private var base: URL!
    private var inbox: URL!
    private var root: URL!
    private var db: DatabaseQueue!
    private let t0 = ISO8601DateFormatter().date(from: "2099-09-30T01:00:00Z")!
    private let day = "2099-09-30"

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("watch-live-\(UUID().uuidString)")
        inbox = base.appendingPathComponent("watch_inbox")
        root = base.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func message(_ seq: Int = 1, install: String = "A", mark: SessionMark? = nil) -> WatchMessage {
        let entry: LedgerEntry
        if let mark {
            entry = LedgerEntry(at: mark == .sessionStarted ? t0 : t0.addingTimeInterval(300),
                mark: mark, source: mark == .sessionStarted ? SessionSource.watch : nil)
        } else {
            entry = LedgerEntry(block: BlockRecord(seq: 0, startedAt: t0,
                endedAt: t0.addingTimeInterval(300), hardCut: true, fileName: "block-0000.m4a"))
        }
        return WatchMessage(v: WatchLink.version, installID: install, msgSeq: seq,
            day: day, entry: entry, sentAt: t0.addingTimeInterval(300), watchBattery: 0.8)
    }
    private func header(_ bytes: Data, msg: WatchMessage? = nil) -> WatchLiveTransfer.Header {
        .init(message: msg ?? message(), totalBytes: bytes.count, sha256: WatchLiveTransfer.hash(bytes))
    }
    private func packet(_ h: WatchLiveTransfer.Header, bytes: Data, offset: Int = 0) throws -> WatchLiveTransfer.Packet {
        // 跑实际线上编解码，日期口径不能只在测试内存里一致。
        try WatchLiveTransfer.decode(WatchLiveTransfer.encode(.init(header: h, offset: offset, bytes: bytes)))
    }
    @discardableResult private func send(_ bytes: Data, msg: WatchMessage? = nil) throws -> WatchLiveReceiver.Result {
        let h = header(bytes, msg: msg)
        var offset = 0
        var result: WatchLiveReceiver.Result!
        while offset < bytes.count {
            let end = min(offset + WatchLiveTransfer.chunkBytes, bytes.count)
            let p = try packet(h, bytes: bytes.subdata(in: offset..<end), offset: offset)
            result = try WatchLiveReceiver.accept(p, inbox: inbox)
            let reply = try WatchLiveTransfer.receipt(from: WatchLiveTransfer.encode(result.receipt), for: p)
            offset = reply.nextOffset
        }
        return result
    }
    private func audio(_ key: String = "A-1") throws -> Data {
        try Data(contentsOf: inbox.appendingPathComponent("\(key).m4a"))
    }
    private func background(_ bytes: Data, msg: WatchMessage) throws -> WatchInbox.Landing {
        let file = base.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        return try WatchInbox.land(file, msg: msg, into: inbox)
    }
    private func scalar(_ sql: String) throws -> Int { try db.read { try Int.fetchOne($0, sql: sql)! } }

    func testCompletedBlockQueuesBeforeSessionEndsAndPartialNeverQueues() throws {
        let start = message(0, mark: .sessionStarted)
        try send(WatchLink.data(start), msg: start)
        let bytes = Data(repeating: 0x61, count: WatchLiveTransfer.chunkBytes + 11)
        let h = header(bytes)
        let first = try WatchLiveReceiver.accept(packet(h, bytes: bytes.prefix(WatchLiveTransfer.chunkBytes)), inbox: inbox)
        XCTAssertFalse(first.receipt.complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("A-1.msg.json").path))
        try WatchMirror.drain(inbox: inbox, root: root, now: t0, in: db)
        // 开场已有占位上传任务，核真正可处理的材料，不能把占位任务当成已上传音频。
        let ledger = RecordingPaths.audioDir(day: day, source: SessionSource.watch, root: root).appendingPathComponent("ledger.jsonl")
        XCTAssertEqual(try BlockLedger.read(from: ledger).entries.compactMap(\.block).count, 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM upload_jobs"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM transcripts"), 0)
        let last = try WatchLiveReceiver.accept(packet(h, bytes: bytes.suffix(11), offset: WatchLiveTransfer.chunkBytes), inbox: inbox)
        XCTAssertTrue(last.receipt.complete)
        try WatchMirror.drain(inbox: inbox, root: root, now: t0, in: db)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status = 'recording' AND ended_at IS NULL"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tasks WHERE kind = 'upload_audio'"), 1)
        let file = RecordingPaths.audioDir(day: day, source: SessionSource.watch, root: root).appendingPathComponent("block-0000.m4a")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testLostReplyAndRestartResumeSavedPrefix() throws {
        let bytes = Data(repeating: 0x37, count: WatchLiveTransfer.chunkBytes * 2 + 9)
        let h = header(bytes)
        let p = try packet(h, bytes: bytes.prefix(WatchLiveTransfer.chunkBytes))
        _ = try WatchLiveReceiver.accept(p, inbox: inbox)
        _ = try WatchLiveReceiver.accept(packet(h, bytes: bytes.subdata(in: WatchLiveTransfer.chunkBytes..<(WatchLiveTransfer.chunkBytes * 2)), offset: WatchLiveTransfer.chunkBytes), inbox: inbox)
        // 接收端不借助内存游标，重新从第一段发送即可核已有前缀并跳到已落盘位置。
        let replay = try WatchLiveReceiver.accept(p, inbox: inbox)
        XCTAssertEqual(replay.receipt.nextOffset, WatchLiveTransfer.chunkBytes * 2)
        try send(bytes)
        XCTAssertEqual(try audio(), bytes)
    }

    func testTornAppendCanBeCompletedWithoutOverwritingPrefix() throws {
        let bytes = Data(repeating: 0x73, count: WatchLiveTransfer.chunkBytes + 3)
        let p = try packet(header(bytes), bytes: bytes.prefix(WatchLiveTransfer.chunkBytes))
        _ = try WatchLiveReceiver.accept(p, inbox: inbox)
        let file = inbox.appendingPathComponent("live/A-1/payload")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(WatchLiveTransfer.chunkBytes / 2)); try handle.close()
        let reply = try WatchLiveReceiver.accept(p, inbox: inbox)
        XCTAssertEqual(reply.receipt.nextOffset, WatchLiveTransfer.chunkBytes)
        try send(bytes)
        XCTAssertEqual(try audio(), bytes)
    }

    func testConflictingRepeatedBytesPreserveOriginal() throws {
        let bytes = Data(repeating: 0x61, count: WatchLiveTransfer.chunkBytes + 1)
        let h = header(bytes)
        _ = try WatchLiveReceiver.accept(packet(h, bytes: bytes.prefix(20)), inbox: inbox)
        XCTAssertThrowsError(try WatchLiveReceiver.accept(packet(h, bytes: Data(repeating: 0x62, count: 20)), inbox: inbox))
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("live/A-1/payload")), bytes.prefix(20))
        try send(bytes)
        XCTAssertEqual(try audio(), bytes)
    }

    func testSameKeyDifferentHeaderDoesNotReplacePartial() throws {
        let first = Data(repeating: 0x61, count: 100)
        _ = try WatchLiveReceiver.accept(packet(header(first), bytes: first.prefix(10)), inbox: inbox)
        let other = Data(repeating: 0x62, count: 100)
        XCTAssertThrowsError(try send(other))
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("live/A-1/payload")), first.prefix(10))
    }

    func testOutOfOrderByteChunkCannotProduceMessageReceipt() throws {
        let bytes = Data(repeating: 0x61, count: 100)
        XCTAssertThrowsError(try WatchLiveReceiver.accept(packet(header(bytes), bytes: bytes.suffix(10), offset: 90), inbox: inbox))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("A-1.msg.json").path))
        try send(bytes)
        XCTAssertEqual(try audio(), bytes)
    }

    func testBadDigestPreservesBadCopyAndBackgroundOriginalStillLands() throws {
        let bytes = Data("correct".utf8), bad = Data("damaged".utf8)
        XCTAssertThrowsError(try WatchLiveReceiver.accept(packet(header(bytes), bytes: bad), inbox: inbox))
        let names = try FileManager.default.contentsOfDirectory(atPath: inbox.appendingPathComponent("live").path)
        XCTAssertTrue(names.contains { $0.hasPrefix("A-1.corrupt-") })
        XCTAssertEqual(try background(bytes, msg: message()), .landed)
        XCTAssertEqual(try audio(), bytes)
    }

    func testBackgroundFirstAndLiveReplayShareOneReceipt() throws {
        let bytes = Data(repeating: 0x61, count: WatchLiveTransfer.chunkBytes + 13)
        XCTAssertEqual(try background(bytes, msg: message()), .landed)
        XCTAssertEqual(try send(bytes).landing, .duplicate)
        XCTAssertEqual(try audio(), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path).filter { $0.hasSuffix(".m4a") }.count, 1)
    }

    func testLiveFirstBackgroundDuplicateAndEndArrivesEarlyDoNotDuplicateQueue() throws {
        let start = message(0, mark: .sessionStarted), end = message(2, mark: .sessionEnded)
        try background(WatchLink.data(end), msg: end)
        try send(WatchLink.data(start), msg: start)
        try WatchMirror.drain(inbox: inbox, root: root, now: t0, in: db)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status = 'recording'"), 1)
        let bytes = Data("audio".utf8)
        try send(bytes)
        XCTAssertEqual(try background(bytes, msg: message()), .duplicate)
        try WatchMirror.drain(inbox: inbox, root: root, now: t0, in: db)
        try WatchMirror.drain(inbox: inbox, root: root, now: t0, in: db)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status = 'closed'"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tasks WHERE kind = 'upload_audio'"), 1)
    }

    func testBackgroundSuccessRemovesOnlyMatchingPartial() throws {
        let bytes = Data(repeating: 0x61, count: 100)
        _ = try WatchLiveReceiver.accept(packet(header(bytes), bytes: bytes.prefix(10)), inbox: inbox)
        try background(bytes, msg: message())
        try WatchLiveReceiver.discardReceivedPartial(for: message(), inbox: inbox)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("live/A-1").path))
        XCTAssertEqual(try audio(), bytes)
        let late = try packet(header(bytes), bytes: bytes.suffix(90), offset: 10)
        let ack = try WatchLiveReceiver.accept(late, inbox: inbox)
        XCTAssertTrue(ack.receipt.complete)
        XCTAssertEqual(ack.landing, .duplicate)
        XCTAssertEqual(try WatchLiveTransfer.receipt(from: WatchLiveTransfer.encode(ack.receipt), for: late).nextOffset, bytes.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("live/A-1").path))
    }

    func testDifferentInstallSameSequenceKeepsBothFiles() throws {
        let a = Data("first".utf8), b = Data("second".utf8)
        try send(a, msg: message(1, install: "A"))
        try send(b, msg: message(1, install: "B"))
        XCTAssertEqual(try audio("A-1"), a)
        XCTAssertEqual(try audio("B-1"), b)
    }

    func testFullChunkPacketStaysWithinWireSizeAndRoundTrips() throws {
        let bytes = Data(repeating: 0xff, count: WatchLiveTransfer.chunkBytes)
        let p = try packet(header(bytes), bytes: bytes)
        let wire = try WatchLiveTransfer.encode(p)
        XCTAssertLessThan(wire.count, WatchLiveTransfer.maxPacketBytes)
        XCTAssertEqual(try WatchLiveTransfer.decode(wire).bytes, bytes)
    }

    func testUnknownProtocolAndOversizedDeclarationsAreRejected() throws {
        let bytes = Data("audio".utf8)
        var future = header(bytes); future.version += 1
        XCTAssertThrowsError(try WatchLiveReceiver.accept(.init(header: future, offset: 0, bytes: bytes), inbox: inbox))
        let large = WatchLiveTransfer.Header(message: message(), totalBytes: WatchLiveTransfer.maxFileBytes + 1, sha256: WatchLiveTransfer.hash(bytes))
        XCTAssertThrowsError(try WatchLiveReceiver.accept(.init(header: large, offset: 0, bytes: bytes), inbox: inbox))
        XCTAssertThrowsError(try WatchLiveTransfer.decode(Data(repeating: 0x20, count: WatchLiveTransfer.maxPacketBytes + 1)))
    }

    func testIllegalPathsAndOverflowOffsetsCannotWriteOrTrap() throws {
        let bytes = Data("audio".utf8)
        let illegal = header(bytes, msg: message(1, install: "../outside"))
        XCTAssertThrowsError(try WatchLiveReceiver.accept(.init(header: illegal, offset: 0, bytes: bytes), inbox: inbox))
        let bad = WatchLiveTransfer.Packet(header: header(bytes), offset: Int.max, bytes: bytes)
        XCTAssertThrowsError(try WatchLiveReceiver.accept(bad, inbox: inbox))
        XCTAssertThrowsError(try WatchLiveTransfer.receipt(from: Data(), for: bad))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path))
    }

    func testWrongOrPrematureReceiptCannotConfirmWholeFile() throws {
        let bytes = Data("audio".utf8), h = header(Data("audio-tail".utf8))
        let p = try packet(h, bytes: bytes)
        let badReplies: [WatchLiveTransfer.Receipt] = [
            .init(key: "B-1", sha256: h.sha256, nextOffset: bytes.count, complete: false),
            .init(key: "A-1", sha256: String(repeating: "0", count: 64), nextOffset: bytes.count, complete: false),
            .init(key: "A-1", sha256: h.sha256, nextOffset: bytes.count, complete: true),
            .init(key: "A-1", sha256: h.sha256, nextOffset: h.totalBytes + 1, complete: true),
            .init(key: "A-1", sha256: h.sha256, nextOffset: 0, complete: false, error: "未落盘")
        ]
        for r in badReplies { XCTAssertThrowsError(try WatchLiveTransfer.receipt(from: WatchLiveTransfer.encode(r), for: p)) }
        let saved = WatchLiveTransfer.Receipt(key: "A-1", sha256: h.sha256, nextOffset: bytes.count, complete: false)
        XCTAssertFalse(try WatchLiveTransfer.receipt(from: WatchLiveTransfer.encode(saved), for: p).complete)
    }

    func testMarkerPayloadMustMatchEnvelope() throws {
        let start = message(0, mark: .sessionStarted)
        XCTAssertThrowsError(try send(Data("unrelated".utf8), msg: start))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("A-0.msg.json").path))
    }

    func testDeliveryCommitFailureKeepsOriginalBookAndPinnedFiles() throws {
        var book = WatchLink.Book(installID: "A")
        let mark = book.enqueue(message(0, mark: .sessionStarted).entry, day: day,
            path: "outbox/A-0.json", now: t0, battery: nil)
        let block = book.enqueue(message().entry, day: day, path: "recordings/block.m4a", now: t0, battery: nil)
        let before = book
        for msg in [mark, block] {
            XCTAssertThrowsError(try book.committingDelivery(msg) { _ in throw CocoaError(.fileWriteNoPermission) })
            XCTAssertEqual(book, before)
            XCTAssertEqual(book.pinnedPaths, ["outbox/A-0.json", "recordings/block.m4a"])
        }
        var saved: WatchLink.Book?
        book = try book.committingDelivery(mark) { saved = $0 }
        XCTAssertEqual(saved, book)
        XCTAssertNil(book.inflight[mark.msgSeq])
        XCTAssertNotNil(book.inflight[block.msgSeq])
        XCTAssertEqual(book.pinnedPaths, ["recordings/block.m4a"])
    }

    func testOldInstallCallbackCannotReleaseNewSequence() throws {
        var book = WatchLink.Book(installID: "B")
        let owned = book.enqueue(message(0, mark: .sessionStarted).entry, day: day,
            path: "outbox/B-0.json", now: t0, battery: nil)
        let stale = message(0, install: "A", mark: .sessionStarted)
        XCTAssertFalse(book.owns(stale))
        var persisted = false
        XCTAssertThrowsError(try book.committingDelivery(stale) { _ in persisted = true })
        XCTAssertFalse(persisted)
        XCTAssertTrue(book.owns(owned))
        XCTAssertNotNil(book.inflight[0])
    }
}

import XCTest
import GRDB
@testable import GrowthApp

/// 直接跑生产接线,核账本/场次/任务/音频,不以报告的applied计数当验收。
final class WatchMirrorTests: XCTestCase {
    private var base: URL!
    private var inbox: URL!
    private var root: URL!
    private var db: DatabaseQueue!
    private let day = "2099-09-30"
    private let t0 = ISO8601DateFormatter().date(from: "2099-09-30T01:00:00Z")!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("watch-mirror-\(UUID().uuidString)")
        inbox = base.appendingPathComponent("watch_inbox")
        root = base.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func message(_ seq: Int, install: String = "A", offset: Double = 0,
                         blockSeq: Int = 0, version: Int = WatchLink.version) -> WatchMessage {
        let at = t0.addingTimeInterval(offset)
        let entry: LedgerEntry
        switch seq % 3 {
        case 0: entry = LedgerEntry(at: at, mark: .sessionStarted, source: SessionSource.watch)
        case 1: entry = LedgerEntry(block: BlockRecord(seq: blockSeq, startedAt: at,
            endedAt: at.addingTimeInterval(300), hardCut: false,
            fileName: String(format: "block-%04d.m4a", blockSeq)))
        default: entry = LedgerEntry(at: at.addingTimeInterval(300), mark: .sessionEnded)
        }
        return WatchMessage(v: version, installID: install, msgSeq: seq, day: day,
                            entry: entry, sentAt: at, watchBattery: 0.7)
    }
    private func land(_ msg: WatchMessage, bytes: String = "audio") throws {
        let u = base.appendingPathComponent(UUID().uuidString)
        try Data(bytes.utf8).write(to: u)
        _ = try WatchInbox.land(u, msg: msg, into: inbox)
    }
    @discardableResult private func drain() throws -> WatchMirror.Report {
        try WatchMirror.drain(inbox: inbox, root: root, now: t0, in: db)
    }
    private var ledgerURL: URL {
        RecordingPaths.audioDir(day: day, source: SessionSource.watch, root: root)
            .appendingPathComponent(AudioWipe.ledgerName)
    }
    private func entries() throws -> [LedgerEntry] { try BlockLedger.read(from: ledgerURL).entries }
    private func scalar(_ sql: String) throws -> Int { try db.read { try Int.fetchOne($0, sql: sql)! } }

    func testWatchSessionLandsInWatchDirAndQueuesOnce() throws {
        let phone = RecordingPaths.audioDir(day: day, source: SessionSource.recording, root: root)
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        let phoneLedger = phone.appendingPathComponent(AudioWipe.ledgerName)
        try Data("phone-ledger\n".utf8).write(to: phoneLedger)
        try Data("phone-audio".utf8).write(to: phone.appendingPathComponent("block-0000.m4a"))
        for n in 0...2 { try land(message(n)) }
        try drain(); try drain()
        XCTAssertEqual(try entries().count, 3)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE source = 'watch' AND status = 'closed'"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tasks WHERE kind = 'upload_audio'"), 1)
        XCTAssertEqual(try String(contentsOf: phoneLedger, encoding: .utf8), "phone-ledger\n")
        XCTAssertEqual(try String(contentsOf: phone.appendingPathComponent("block-0000.m4a"), encoding: .utf8), "phone-audio")
        XCTAssertEqual(try String(contentsOf: ledgerURL.deletingLastPathComponent().appendingPathComponent("block-0000.m4a"), encoding: .utf8), "audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("A-1.m4a").path))
    }

    func testMissingNumberWaitsAndEndCannotCloseEarly() throws {
        try land(message(2)); try land(message(0))
        let report = try drain()
        XCTAssertTrue(report.notices.contains { $0.contains("第 1 条") })
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status = 'recording'"), 1)
        XCTAssertEqual(try entries().count, 1)
        try land(message(1)); try drain()
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status = 'closed'"), 1)
        XCTAssertEqual(try entries().count, 3)
    }

    func testReinstallDifferentAudioGetsNewBlockNumber() throws {
        for n in 0...2 { try land(message(n)) }; try drain()
        for n in 0...2 { try land(message(n, install: "B", offset: 600), bytes: "new") }; try drain()
        XCTAssertEqual(try entries().compactMap { $0.block?.seq }, [0, 1])
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions"), 2)
        let dir = ledgerURL.deletingLastPathComponent()
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("block-0000.m4a"), encoding: .utf8), "audio")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("block-0001.m4a"), encoding: .utf8), "new")
    }

    func testReinstallReplaysWholeLedgerWithoutSecondTask() throws {
        for n in 0...2 { try land(message(n)) }; try drain()
        for n in 0...2 { try land(message(n, install: "B")) }; try drain()
        XCTAssertEqual(try entries().count, 3)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tasks WHERE kind = 'upload_audio'"), 1)
    }

    func testNewInstallationRecoversUnclosedSessionWithoutInventingEndMessage() throws {
        try land(message(0)); try land(message(1)); try drain()
        for n in 0...2 { try land(message(n, install: "B", offset: 600), bytes: "new") }
        XCTAssertEqual(try drain().applied, 3)
        try drain()
        let all = try entries()
        let sessions = BlockLedger.sessions(entries: all)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first?.endedAt, t0.addingTimeInterval(300))
        XCTAssertEqual(sessions.last?.startedAt, t0.addingTimeInterval(600))
        XCTAssertEqual(all.filter { $0.kind == SessionMark.sessionEnded.rawValue }.count, 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status = 'closed'"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tasks WHERE kind = 'upload_audio'"), 2)
        let dir = ledgerURL.deletingLastPathComponent()
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("block-0000.m4a"), encoding: .utf8), "audio")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("block-0001.m4a"), encoding: .utf8), "new")
    }

    func testExplicitRestartInSameInstallationUsesExistingSessionBoundary() throws {
        try land(message(0)); try land(message(1)); try drain()
        for (seq, entry) in [
            (2, LedgerEntry(at: t0.addingTimeInterval(600), mark: .sessionStarted, source: SessionSource.watch)),
            (3, LedgerEntry(block: BlockRecord(seq: 1, startedAt: t0.addingTimeInterval(600), endedAt: t0.addingTimeInterval(900), hardCut: false, fileName: "block-0001.m4a"))),
            (4, LedgerEntry(at: t0.addingTimeInterval(900), mark: .sessionEnded))
        ] {
            try land(WatchMessage(v: WatchLink.version, installID: "A", msgSeq: seq, day: day, entry: entry, sentAt: entry.at, watchBattery: nil))
        }
        XCTAssertEqual(try drain().applied, 3)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status = 'closed'"), 2)
        XCTAssertEqual(try entries().compactMap { $0.block?.seq }, [0, 1])
    }

    func testRestartStillWaitsForMissingNewBlock() throws {
        try land(message(0)); try land(message(1)); try drain()
        try land(message(0, install: "B", offset: 600))
        try land(message(2, install: "B", offset: 600))
        XCTAssertTrue(try drain().notices.contains { $0.contains("第 1 条") })
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status = 'recording'"), 1)
        XCTAssertEqual(try entries().compactMap { $0.block?.seq }, [0])
        try land(message(1, install: "B", offset: 600), bytes: "new")
        try drain()
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status = 'closed'"), 2)
    }

    func testLateOldAudioStaysInInboxAndDoesNotBlockNewInstallation() throws {
        try land(message(0)); try land(message(1)); try drain()
        for n in 0...2 { try land(message(n, install: "B", offset: 600), bytes: "new") }
        try drain()
        let late = WatchMessage(v: WatchLink.version, installID: "A", msgSeq: 2, day: day,
            entry: LedgerEntry(block: BlockRecord(seq: 1, startedAt: t0.addingTimeInterval(300), endedAt: t0.addingTimeInterval(500), hardCut: false, fileName: "block-0001.m4a")),
            sentAt: t0.addingTimeInterval(500), watchBattery: nil)
        try land(late, bytes: "late")
        for n in 3...5 { try land(message(n, install: "B", offset: 1200, blockSeq: 1), bytes: "next") }
        let report = try drain()
        XCTAssertTrue(report.notices.contains { $0.contains("旧录音") })
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions"), 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("A-2.m4a").path))
        XCTAssertEqual(try entries().compactMap { $0.block?.seq }.count, 3)
    }

    func testRestartReplaysAfterLedgerCommitBeforeCursor() throws {
        try land(message(0)); try land(message(1)); try drain()
        for n in 0...2 { try land(message(n, install: "B", offset: 600), bytes: "new") }
        try drain()
        let url = inbox.appendingPathComponent("progress.json")
        var p = try JSONDecoder().decode(WatchMirror.Progress.self, from: Data(contentsOf: url))
        p.next["B"] = 0
        try JSONEncoder().encode(p).write(to: url)
        try drain()
        XCTAssertEqual(try entries().count, 5)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tasks WHERE kind = 'upload_audio'"), 2)
    }

    func testLateOldEndCannotCloseNewSessionEvenWhenItsTimeIsLater() throws {
        try land(message(0)); try land(message(1)); try drain()
        try land(message(0, install: "B", offset: 600)); try drain()
        let end = LedgerEntry(at: t0.addingTimeInterval(900), mark: .sessionEnded)
        try land(WatchMessage(v: WatchLink.version, installID: "A", msgSeq: 2, day: day,
                              entry: end, sentAt: end.at, watchBattery: nil))
        XCTAssertTrue(try drain().notices.contains { $0.contains("不属于当前场次") })
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status='recording'"), 1)
        XCTAssertEqual(try entries().last?.kind, SessionMark.sessionStarted.rawValue)
        try land(message(1, install: "B", offset: 600), bytes: "new")
        try land(message(2, install: "B", offset: 600))
        try drain()
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status='closed'"), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("A-2.msg.json").path))
    }

    func testLateOldBlockCannotAttachToNewSessionDespiteMatchingStartTime() throws {
        try land(message(0)); try land(message(1)); try drain()
        try land(message(0, install: "B", offset: 600)); try drain()
        let block = LedgerEntry(block: BlockRecord(seq: 1, startedAt: t0.addingTimeInterval(600),
            endedAt: t0.addingTimeInterval(900), hardCut: false, fileName: "block-0001.m4a"))
        try land(WatchMessage(v: WatchLink.version, installID: "A", msgSeq: 2, day: day,
                              entry: block, sentAt: block.at, watchBattery: nil), bytes: "late")
        XCTAssertTrue(try drain().notices.contains { $0.contains("不属于当前场次") })
        XCTAssertEqual(try entries().compactMap { $0.block?.seq }, [0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("A-2.m4a").path))
    }

    func testRestartAfterEmptySessionDoesNotInventRecordingDuration() throws {
        try land(message(0)); try drain()
        try land(message(0, install: "B", offset: 600)); try drain()
        let sessions = BlockLedger.sessions(entries: try entries())
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].endedAt, t0)
        XCTAssertEqual(sessions[0].recordedSeconds, 0)
        XCTAssertTrue(sessions[1].isOpen)
    }

    func testCrashAfterLedgerBeforeCursorDoesNotDuplicate() throws {
        for n in 0...2 { try land(message(n)) }; try drain()
        let url = inbox.appendingPathComponent("progress.json")
        var p = try JSONDecoder().decode(WatchMirror.Progress.self, from: Data(contentsOf: url))
        p.next["A"] = 1 // 模拟账本已提交、游标尚未提交。收据与块映射保留。
        try JSONEncoder().encode(p).write(to: url)
        try drain()
        XCTAssertEqual(try entries().count, 3)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM tasks WHERE kind = 'upload_audio'"), 1)
    }

    func testFutureVersionBlocksOnlyThatInstallation() throws {
        try land(message(0, version: 2))
        for n in 0...2 { try land(message(n, install: "B", offset: 600)) }
        XCTAssertTrue(try drain().notices.contains { $0.contains("版本 2") })
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions"), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("A-0.msg.json").path))
    }

    func testSameEnvelopeDifferentAudioIsConflict() throws {
        try land(message(0)); try land(message(1), bytes: "first")
        try land(message(1), bytes: "second"); try land(message(2))
        XCTAssertTrue(try drain().notices.contains { $0.contains("冲突") })
        XCTAssertEqual(try entries().count, 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE status = 'closed'"), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path).filter { $0.hasSuffix(".m4a") }.count, 2)
    }

    func testDuplicateAfterAudioMovedStillUsesReceipt() throws {
        for n in 0...2 { try land(message(n)) }; try drain()
        let file = base.appendingPathComponent("redelivery")
        try Data("audio".utf8).write(to: file)
        XCTAssertEqual(try WatchInbox.land(file, msg: message(1), into: inbox), .duplicate)
        try Data("wrong".utf8).write(to: file)
        XCTAssertEqual(try WatchInbox.land(file, msg: message(1), into: inbox), .conflict)
    }

    func testInvalidPathsCannotEscapeInbox() throws {
        let good = message(0)
        for (install, day) in [("../evil", good.day), ("A", "../../evil"), ("A", "2026-02-30")] {
            let bad = WatchMessage(v: good.v, installID: install, msgSeq: 0, day: day,
                                   entry: good.entry, sentAt: good.sentAt, watchBattery: nil)
            XCTAssertThrowsError(try land(bad))
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions"), 0)
    }

    func testBadCursorFailsVisiblyAndRetainsAudio() throws {
        try land(message(0)); try land(message(1))
        try Data("broken".utf8).write(to: inbox.appendingPathComponent("progress.json"))
        XCTAssertThrowsError(try drain())
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("A-1.m4a").path))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions"), 0)
    }

    func testSameBlockNumberWithChangedTimingIsRejected() throws {
        for n in 0...2 { try land(message(n)) }; try drain()
        for n in 3...5 { try land(message(n, offset: 600)) }
        XCTAssertTrue(try drain().notices.contains { $0.contains("发生变化") })
        XCTAssertEqual(try entries().compactMap { $0.block?.seq }, [0])
    }

    func testInterruptedStagingCopyIsReplayed() throws {
        try land(message(0)); try drain()
        try land(message(1)); try land(message(2))
        let dir = ledgerURL.deletingLastPathComponent()
        try Data("half".utf8).write(to: dir.appendingPathComponent(".incoming-A-1.m4a"))
        try drain()
        XCTAssertEqual(try entries().count, 3)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("block-0000.m4a"), encoding: .utf8), "audio")
    }

    func testCorruptCommittedLedgerTailDoesNotAdvanceCursor() throws {
        try land(message(0)); try drain()
        let h = try FileHandle(forWritingTo: ledgerURL)
        try h.seekToEnd(); try h.write(contentsOf: Data("not-json\n".utf8)); try h.close()
        let progressURL = inbox.appendingPathComponent("progress.json")
        var p0 = try JSONDecoder().decode(WatchMirror.Progress.self, from: Data(contentsOf: progressURL))
        p0.next["A"] = 0
        try JSONEncoder().encode(p0).write(to: progressURL)
        XCTAssertTrue(try drain().notices.contains { $0.contains("坏") || $0.contains("损坏") })
        let p = try JSONDecoder().decode(WatchMirror.Progress.self,
            from: Data(contentsOf: inbox.appendingPathComponent("progress.json")))
        XCTAssertEqual(p.next["A"], 0)
    }

    func testBlockCannotStartBeforeItsSession() throws {
        try land(message(0))
        let good = message(1)
        let bad = WatchMessage(v: good.v, installID: good.installID, msgSeq: good.msgSeq, day: day,
            entry: LedgerEntry(block: BlockRecord(seq: 0, startedAt: t0.addingTimeInterval(-300),
                endedAt: t0.addingTimeInterval(300), hardCut: false, fileName: "block-0000.m4a")),
            sentAt: good.sentAt, watchBattery: nil)
        try land(bad); try land(message(2))
        XCTAssertTrue(try drain().notices.contains { $0.contains("起点") })
        XCTAssertEqual(try entries().count, 1)
    }

    func testExtremeReservedSequenceDoesNotTrap() throws {
        try land(message(0)); try drain(); try land(message(1))
        let url = inbox.appendingPathComponent("progress.json")
        var p = try JSONDecoder().decode(WatchMirror.Progress.self, from: Data(contentsOf: url))
        p.blockMap["B|\(day)|0"] = Int.max
        try JSONEncoder().encode(p).write(to: url)
        XCTAssertThrowsError(try drain())
    }

    func testTimeZoneChangeDoesNotCreateSecondSession() throws {
        // 已有同一时刻的UTC串,新同步在手机当前时区(测试素材为不同字面串)。
        try db.write { d in
            try d.execute(sql: "INSERT INTO sessions(started_at, day, source, status) VALUES(?, ?, 'watch', 'recording')",
                          arguments: ["2099-09-30T01:00:00Z", day])
        }
        for n in 0...2 { try land(message(n)) }; try drain()
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions"), 1)
    }

    func testCursorCannotJumpBeyondReceipts() throws {
        for n in 0...2 { try land(message(n)) }
        var p = WatchMirror.Progress(); p.next["A"] = 999
        try JSONEncoder().encode(p).write(to: inbox.appendingPathComponent("progress.json"))
        XCTAssertThrowsError(try drain())
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions"), 0)
    }

    func testDeletingOpenWatchSessionIsRejectedAtWriter() throws {
        try land(message(0)); try drain()
        let id = try db.read { try Int64.fetchOne($0, sql: "SELECT id FROM sessions")! }
        XCTAssertThrowsError(try MemoryRemoval.removeSession(id, audioFiles: [], in: db))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE removed_at IS NOT NULL"), 0)
    }

    func testPhoneRelaunchDoesNotCloseWatchButClosesImport() throws {
        for source in [SessionSource.watch, SessionSource.imported] {
            try SessionBridge.sync([BlockLedger.SessionSummary(startedAt: t0, endedAt: nil,
                blocks: [], recordedSeconds: 0, source: source)], day: day, in: db)
        }
        XCTAssertEqual(try SessionBridge.closeAbandoned(in: db).count, 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE source = 'watch' AND status = 'recording'"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sessions WHERE source = 'import' AND status = 'closed'"), 1)
    }

    func testWipeKeepsBothLedgersAndClearsBothAudioSources() throws {
        for n in 0...2 { try land(message(n)) }; try drain()
        let phone = RecordingPaths.audioDir(day: day, source: SessionSource.recording, root: root)
        try BlockLedger.append(LedgerEntry(at: t0, mark: .sessionStarted), to: phone.appendingPathComponent(AudioWipe.ledgerName))
        try Data("phone".utf8).write(to: phone.appendingPathComponent("block-0000.m4a"))
        let result = try AudioWipe.run(root: root)
        XCTAssertEqual(result.ledgersKept, 2)
        XCTAssertEqual(result.filesDeleted, 2)
        XCTAssertEqual(try entries().count, 3)
    }

    func testProductionBlocksAndLineAudioUseWatchSource() throws {
        // 真实消费方读Documents;只建专用未来日期目录,不碰任何既有录音。
        let dir = RecordingPaths.audioDir(day: day, source: SessionSource.watch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in 0...2 { try land(message(n)) }
        try WatchMirror.drain(inbox: inbox, in: db)
        let id = try db.read { try Int64.fetchOne($0, sql: "SELECT id FROM sessions")! }
        let blocks = ProcessingPump.blocks(of: id, ext: "m4a", in: db)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.fileURL.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(try HomeProjection.cards(day: day, in: db).first?.source, SessionSource.watch)
        let clip = LineAudio.resolve(blockSeq: 0, startMs: 1000, endMs: 2000, day: day,
                                     source: SessionSource.watch, offsets: [0: 0])
        guard case .success(let resolved) = clip else { return XCTFail("手表原话无法试听") }
        XCTAssertEqual(resolved.url, blocks.first?.fileURL)
        XCTAssertEqual(resolved.start, 1)
        // 手机同号文件同时在,clip必须从SQL读source选择手表。
        let phone = RecordingPaths.audioDir(day: day, source: SessionSource.recording)
        let phoneAudio = phone.appendingPathComponent("block-0000.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: phoneAudio.path))
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        try Data("phone".utf8).write(to: phoneAudio)
        defer { try? FileManager.default.removeItem(at: phoneAudio) }
        try db.write { d in
            try d.execute(sql: "INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(100,?,1,1,'test','frozen','x')", arguments: [id])
            try d.execute(sql: "INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset,block_seq) VALUES(100,100,0,1000,2000,'手表原话',0,0)")
            try d.execute(sql: "UPDATE sessions SET active_transcript_id=100 WHERE id=?", arguments: [id])
        }
        guard case .success(let fromSQL) = try LineAudio.clip(lineID: 100, in: db) else {
            return XCTFail("SQL source未接到手表音频")
        }
        XCTAssertEqual(fromSQL.url.path, resolved.url.path)
        _ = try UploadJobStore.claim(sessionID: id, blockSeq: 0, key: "watch-test", now: "x", in: db)
        let payload = try XCTUnwrap(VoiceprintRemote.jobPayload(sessionID: id, in: db))
        let job = try JSONDecoder().decode(VoiceprintRemote.Job.self, from: payload)
        XCTAssertEqual(job.lines.map(\.line_id), [100])
        XCTAssertEqual(job.lines.map(\.start_ms), [1000])
        XCTAssertEqual(job.lines.map(\.end_ms), [2000])
        let retention = try AudioRetention.sweep(now: t0.addingTimeInterval(10 * 86_400), in: db)
        XCTAssertEqual(retention.filesDeleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: phoneAudio.path), "清理手表场不能误删手机同号音频")
        XCTAssertEqual(try BlockLedger.read(from: dir.appendingPathComponent(AudioWipe.ledgerName)).entries.count, 3)
    }
}

import XCTest
import GRDB
@testable import GrowthApp

final class RecordingMemorySyncTests: XCTestCase {
    private var db: DatabaseQueue!
    private let now = "2026-10-15T12:00:00Z"
    override func setUpWithError() throws {
        db = try DatabaseQueue(); try AppDatabase.makeMigrator().migrate(db)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id,started_at,day,source,status) VALUES(1,'2026-10-15T10:00:00Z','2026-10-15','watch','closed');
                INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(1,1,1,1,'fixture','frozen','2026-10-15T10:00:00Z');
                INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(10,1,0,0,1000,'预算还没有决定。',0),(11,1,1,1000,2000,'周五再确认方案。',9);
                INSERT INTO summaries(transcript_id,one_liner,created_at,source_revision) VALUES(1,'方案讨论','2026-10-15T10:00:00Z',0);
                INSERT INTO summary_events(id,transcript_id,seq,title,summary,first_line_id,last_line_id) VALUES(1,1,0,'方案','周五确认，预算未定。',10,11);
                """)
        }
    }
    private func project() throws -> RecordingMemoryProjection.Batch {
        try db.write { try RecordingMemoryProjection.reconcile(now: now, in: $0); return try RecordingMemoryProjection.batch(destination: "fixture", in: $0) }
    }
    private func ack(_ batch: RecordingMemoryProjection.Batch) throws {
        let data = try JSONSerialization.data(withJSONObject: ["schema": "apt.recording-memory.receipt/1", "accepted": batch.records.map { ["id": $0.id, "revision": $0.revision, "fingerprint": String(repeating: "a", count: 64)] as [String: Any] }, "stale": [], "conflicts": []])
        try db.write { try RecordingMemoryProjection.acknowledge(data, sent: batch, destination: "fixture", in: $0) }
    }
    func testFormalProjectionKeepsOriginalIdentityAndEvidence() throws {
        let batch = try project(), record = try XCTUnwrap(batch.records.first)
        XCTAssertEqual(batch.records.count, 1); XCTAssertNotNil(UUID(uuidString: batch.device_id))
        XCTAssertTrue(record.text.contains("预算还没有决定。")); XCTAssertTrue(record.text.contains("\"line_id\":10"))
        XCTAssertTrue(record.text.contains("\"semantic_id\":1")); XCTAssertTrue(record.text.contains("ai_summary"))
        XCTAssertEqual(record.created, "2026-10-15T10:00:00Z"); XCTAssertFalse(record.partial)
        try ack(batch); XCTAssertTrue(try project().records.isEmpty)
    }
    func testConcurrentRevisionCannotBeAcknowledgedByOldReceipt() throws {
        let first = try project()
        _ = try TranscriptRevision.revise(lineID: 10, to: "预算已经取消。", actor: "user", now: now, in: db)
        let changed = try project(); try ack(first)
        let pending = try project()
        XCTAssertEqual(pending.records, changed.records); XCTAssertGreaterThan(pending.records[0].revision, first.records[0].revision)
        XCTAssertTrue(pending.records[0].text.contains("预算已经取消。")); XCTAssertFalse(pending.records[0].text.contains("周五确认，预算未定。"))
    }
    func testLineRemovalNeverExportsRedactedTextOrOldSummary() throws {
        let first = try project(); try ack(first)
        _ = try MemoryRemoval.removeLines([10], audioFiles: [], in: db)
        let changed = try project()
        XCTAssertTrue(changed.records.contains { $0.deleted && $0.id == first.records[0].id })
        XCTAssertFalse(changed.records.contains { $0.text.contains("预算还没有决定。") || $0.text.contains("周五确认，预算未定。") })
        XCTAssertTrue(changed.records.filter { !$0.deleted }.allSatisfy(\.partial))
    }
    func testSessionRemovalProducesHigherVersionTombstone() throws {
        let first = try project(); try ack(first)
        _ = try MemoryRemoval.removeSession(1, audioFiles: [], now: now, in: db)
        let deleted = try project()
        XCTAssertEqual(deleted.records.count, 1); XCTAssertEqual(deleted.records[0].revision, 2)
        XCTAssertTrue(deleted.records[0].deleted); XCTAssertEqual(deleted.records[0].text, "")
        try ack(deleted); XCTAssertTrue(try project().records.isEmpty)
    }
    func testRetranscriptionRemovesOldVersionAndKeepsNewIdentity() throws {
        let first = try project(); try ack(first)
        try db.write { try $0.execute(sql: """
            INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(2,1,2,1,'fixture','frozen','2026-10-15T11:00:00Z');
            INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(20,2,0,0,1000,'重转后的原话。',0);
            """) }
        let revised = try project()
        XCTAssertEqual(revised.records.count, 1); XCTAssertTrue(revised.records.allSatisfy { $0.deleted && $0.id == first.records[0].id }); try ack(revised)
        let next = try project()
        XCTAssertTrue(next.records.contains { !$0.deleted && $0.text.contains("重转后的原话。") })
    }
    func testAttributionChangesAreVersionedWithoutRewritingOriginals() throws {
        let first = try project(); try ack(first)
        try db.write { try $0.execute(sql: "INSERT INTO line_speakers(line_id,person_id,source,updated_at) VALUES(10,-1,'用户确认',?)", arguments: [now]) }
        let changed = try project()
        XCTAssertEqual(changed.records[0].revision, 2); XCTAssertTrue(changed.records[0].text.contains("用户确认"))
        XCTAssertTrue(changed.records[0].text.contains("预算还没有决定。"))
    }
    func testWrongReceiptDoesNotConsumeOutboxAndOtherDestinationRemainsPending() throws {
        let batch = try project()
        let data = Data(#"{"schema":"apt.recording-memory.receipt/1","accepted":[],"stale":[],"conflicts":[]}"#.utf8)
        XCTAssertThrowsError(try db.write { try RecordingMemoryProjection.acknowledge(data, sent: batch, destination: "fixture", in: $0) })
        XCTAssertEqual(try project().records.count, 1); try ack(batch)
        XCTAssertEqual(try db.read { try RecordingMemoryProjection.batch(destination: "other", in: $0).records.count }, 1)
    }
    func testRealSyncUsesPersistedSourceAndExactReceipt() async throws {
        let config = ProxyClient.Config(baseURL: URL(string: "https://fixture.example")!, token: "fixture")
        let count = try await RecordingMemorySync.sync(in: db, config: config, send: { batch in
            XCTAssertEqual(batch.schema, "apt.recording-memory.batch/1"); XCTAssertEqual(batch.records.count, 1)
            return try JSONSerialization.data(withJSONObject: ["schema": "apt.recording-memory.receipt/1", "accepted": batch.records.map { ["id": $0.id, "revision": $0.revision, "fingerprint": String(repeating: "b", count: 64)] as [String: Any] }, "stale": [], "conflicts": []])
        })
        XCTAssertEqual(count, 1)
        let pending = try await db.read { try RecordingMemoryProjection.batch(destination: config.baseURL.absoluteString, in: $0).records }
        XCTAssertTrue(pending.isEmpty)
    }
    func testOneScheduledOpportunityDrainsMultipleTranscriptBatches() async throws {
        try await db.write { try $0.execute(sql: """
            INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(2,1,1,2,'fixture','frozen','2026-10-15T11:00:00Z');
            INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(20,2,0,300000,301000,'另一段尚未同步的原话。',0);
            """) }
        let config = ProxyClient.Config(baseURL: URL(string: "https://fixture.example")!, token: "fixture")
        let sent = expectation(description: "both transcripts sent without another pump tick")
        sent.expectedFulfillmentCount = 2
        let sync = RecordingMemorySync()
        await sync.schedule(in: db, config: config, trigger: .foreground, send: { batch in
            XCTAssertEqual(batch.records.count, 1, "each transcript remains atomic")
            sent.fulfill()
            return try JSONSerialization.data(withJSONObject: ["schema": "apt.recording-memory.receipt/1", "accepted": batch.records.map { ["id": $0.id, "revision": $0.revision, "fingerprint": String(repeating: "b", count: 64)] as [String: Any] }, "stale": [], "conflicts": []])
        })
        await fulfillment(of: [sent], timeout: 3)
        var pending = true
        for _ in 0..<100 {
            pending = try await db.read { !(try RecordingMemoryProjection.batch(destination: config.baseURL.absoluteString, in: $0).records.isEmpty) }
            if !pending { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(pending, "all receipts persist during the same scheduled opportunity")
    }
    func testRemovalClearsPersistedProjectionWithoutProxyOrAnotherSync() throws {
        let first = try project(); try ack(first)
        _ = try MemoryRemoval.removeLines([10], audioFiles: [], in: db)
        let stored = try db.read { try String.fetchAll($0, sql: "SELECT record_json FROM recording_memory_outbox") }
        XCTAssertFalse(stored.joined().contains("预算还没有决定。"))
        XCTAssertTrue(stored.allSatisfy { $0.contains("\"deleted\":true") })
        let pending = try db.read { try RecordingMemoryProjection.batch(destination: "fixture", in: $0) }
        XCTAssertTrue(pending.records.allSatisfy(\.deleted))
    }
    func testLongLegalLineDoesNotBlockOtherTranscriptTombstoneAndRetainsEveryCharacter() throws {
        let first = try project(); try ack(first)
        try db.write { try $0.execute(sql: """
            INSERT INTO sessions(id,started_at,day,source,status) VALUES(2,'2026-10-15T11:00:00Z','2026-10-15','watch','closed');
            INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(2,2,1,1,'fixture','frozen','2026-10-15T10:00:00Z');
            INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(20,2,0,0,1000,'旧原话。',0);
            """) }
        let second = try project(); try ack(second)
        let long = String(repeating: "长原话👨‍👩‍👧‍👦", count: 2000) + "结尾：没有同意预算。"
        _ = try TranscriptRevision.revise(lineID: 20, to: long, actor: "user", now: now, in: db)
        _ = try MemoryRemoval.removeSession(1, audioFiles: [], now: now, in: db)
        let removal = try project()
        XCTAssertEqual(Set(removal.records.map(\.transcript_id)), [1]); XCTAssertTrue(removal.records.allSatisfy(\.deleted)); try ack(removal)
        let changed = try project()
        XCTAssertGreaterThan(changed.records.count, 10, "one transcript's complete changes must not be divided into arbitrary ten-source batches")
        let fragments = try changed.records.filter { !$0.deleted }.map { record -> [[String: Any]] in
            XCTAssertTrue(record.partial); XCTAssertLessThanOrEqual(record.text.utf16.count, 16000)
            return (try JSONSerialization.jsonObject(with: Data(record.text.utf8)) as! [String: Any])["lines"] as! [[String: Any]]
        }.flatMap { $0 }.sorted { ($0["char_from_utf16"] as! Int) < ($1["char_from_utf16"] as! Int) }
        XCTAssertEqual(fragments.map { $0["text"] as! String }.joined(), long)
        XCTAssertEqual(Set(fragments.map { $0["line_text_fingerprint"] as! String }).count, 1)
    }
    func testCrossPartSemanticIdentityAndUTF16TitleBudget() throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(2,1,1,2,'fixture','frozen','2026-10-15T10:00:00Z');
                INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(20,2,0,300000,301000,'接着讨论方案。',0);
                INSERT INTO summaries(transcript_id,one_liner,created_at,source_revision) VALUES(2,'延续方案','2026-10-15T10:00:00Z',0);
                """)
            try db.execute(sql: "INSERT INTO summary_events(id,transcript_id,seq,title,summary,first_line_id,last_line_id,continuation_id) VALUES(2,2,0,?,'仍是同一件事。',20,20,1)", arguments: [String(repeating: "👨‍👩‍👧‍👦", count: 30)])
        }
        let first = try project(); try ack(first)
        let continuation = try project()
        XCTAssertEqual(continuation.records.count, 1); XCTAssertTrue(continuation.records[0].text.contains("\"semantic_id\":1"))
        XCTAssertLessThanOrEqual(continuation.records[0].title.utf16.count, 300)
    }
    func testMidnightSourceBoundaryPreservesNextDayRecall() throws {
        let initial = try project(); try ack(initial)
        try db.write { try $0.execute(sql: """
            INSERT INTO sessions(id,started_at,day,source,status) VALUES(2,'2026-10-15T15:59:50Z','2026-10-15','watch','closed');
            INSERT INTO transcripts(id,session_id,version,part,asr_model,status,created_at) VALUES(2,2,1,1,'fixture','frozen','2026-10-15T15:59:50Z');
            INSERT INTO transcript_lines(line_id,transcript_id,seq,t_start_ms,t_end_ms,text,char_offset) VALUES(20,2,0,0,1000,'午夜前的原话。',0),(21,2,1,20000,21000,'次日零点后的原话。',8);
            """) }
        let batch = try project()
        XCTAssertEqual(batch.records.count, 2)
        let tomorrow = try XCTUnwrap(batch.records.first { $0.created == "2026-10-15T16:00:10Z" })
        XCTAssertTrue(tomorrow.text.contains("次日零点后的原话。")); XCTAssertFalse(tomorrow.text.contains("午夜前的原话。"))
    }
}

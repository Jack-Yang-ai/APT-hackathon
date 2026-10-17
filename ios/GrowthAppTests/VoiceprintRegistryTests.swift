import XCTest
import GRDB
@testable import GrowthApp





final class VoiceprintRegistryTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var storeRoot: URL!
    private var store: LocalSnapshotStore!
    private let now = "2026-08-10T18:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        storeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        store = LocalSnapshotStore(root: storeRoot)
    }
    override func tearDownWithError() throws { dbQueue = nil; store = nil }



    private func emb(_ seed: UInt8, dim: Int = 192) -> Data {
        Data(repeating: seed, count: dim * 4)
    }
    private func cmd(_ action: EnrollCommand.Action, person: Int64, seed: UInt8,
                     id: String? = nil,
                     model: String = VoiceprintModel.current) -> EnrollCommand {
        EnrollCommand(action: action, personID: person, embedding: emb(seed), dim: 192,
                      model: model, source: "用户确认", id: id)
    }
    private func rows() throws -> [VoiceprintEntry] {
        try VoiceprintRegistry.entries(in: dbQueue, model: VoiceprintModel.current)
    }



    func testEnrollLandsInRegistry() throws {
        let d = try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: 1),
                                             now: now, in: dbQueue)
        XCTAssertTrue(d.execute)
        XCTAssertEqual(try rows().map(\.personID), [7])
    }

    func testSameCommandTwiceOnlyLandsOnce() throws {
        let c = cmd(.enroll, person: 7, seed: 1)
        try VoiceprintRegistry.apply(c, now: now, in: dbQueue)
        let second = try VoiceprintRegistry.apply(c, now: now, in: dbQueue)
        XCTAssertFalse(second.execute)
        XCTAssertEqual(try rows().count, 1)
    }

    func testDatabaseItselfRejectsADuplicateInstructionID() throws {




        try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: 1), now: now, in: dbQueue)
        let key = cmd(.enroll, person: 7, seed: 1).instructionID
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO voiceprints (person_id, embedding, dim, source, created_at, instruction_id)
                VALUES (7, ?, 192, 'x', ?, ?)
                """, arguments: [self.emb(1), self.now, key])
        }, "数据库放行了重复的 instruction_id")
    }

    func testOnePersonCanHoldMultipleTemplates() throws {

        try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: 1), now: now, in: dbQueue)
        try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: 2), now: now, in: dbQueue)
        XCTAssertEqual(try rows().count, 2)
    }

    func testEmptyOrMismatchedEmbeddingIsRejected() throws {
        let empty = EnrollCommand(action: .enroll, personID: 7, embedding: Data(),
                                  dim: 0, model: VoiceprintModel.current,
                                  source: "x", id: nil)
        XCTAssertThrowsError(try VoiceprintRegistry.apply(empty, now: now, in: dbQueue))

        let wrong = EnrollCommand(action: .enroll, personID: 7, embedding: emb(1),
                                  dim: 128, model: VoiceprintModel.current,
                                  source: "x", id: nil)   // 字节还是 192 维的
        XCTAssertThrowsError(try VoiceprintRegistry.apply(wrong, now: now, in: dbQueue))
        XCTAssertEqual(try rows().count, 0)
    }



    func testReplayedEnrollAfterRevokeIsBlockedByTombstone() throws {
        let e = cmd(.enroll, person: 7, seed: 1)
        try VoiceprintRegistry.apply(e, now: now, in: dbQueue)
        try VoiceprintRegistry.apply(cmd(.unenroll, person: 7, seed: 1), now: now, in: dbQueue)
        XCTAssertEqual(try rows().count, 0)

        let replay = try VoiceprintRegistry.apply(e, now: now, in: dbQueue)
        XCTAssertFalse(replay.execute)
        XCTAssertTrue(replay.reason.contains("tombstone"), replay.reason)
        XCTAssertEqual(try rows().count, 0, "撤销之后重放把人写回去了")
    }

    func testRevokeKeepsTheTombstoneInsteadOfDeletingTheLedgerRow() throws {


        try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: 1), now: now, in: dbQueue)
        try VoiceprintRegistry.apply(cmd(.unenroll, person: 7, seed: 1), now: now, in: dbQueue)
        let state = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM enroll_ledger")
        }
        XCTAssertEqual(state, "revoked")
    }



    func testRestoreFromSnapshotAfterLocalWipe() throws {
        try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: 1), now: now, in: dbQueue)
        try VoiceprintRegistry.apply(cmd(.enroll, person: 9, seed: 2), now: now, in: dbQueue)
        try RegistrySnapshotIO.push(takenAt: now, to: store, from: dbQueue)


        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM voiceprints")
            try db.execute(sql: "DELETE FROM enroll_ledger")
        }
        XCTAssertEqual(try rows().count, 0)

        let r = try RegistrySnapshotIO.restoreLatest(from: store, now: now, into: dbQueue)
        XCTAssertEqual(r.inserted, 2)
        XCTAssertEqual(try rows().map(\.personID).sorted(), [7, 9])
        XCTAssertEqual(try rows().map(\.embedding), [emb(1), emb(2)], "嵌入字节要一模一样")
    }



    func testModelSurvivesSnapshotRoundTrip() throws {
        try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: 1),
                                     now: now, in: dbQueue)
        try RegistrySnapshotIO.push(takenAt: now, to: store, from: dbQueue)
        try dbQueue.write { try $0.execute(sql: "DELETE FROM voiceprints") }
        try RegistrySnapshotIO.restoreLatest(from: store, now: now, into: dbQueue)
        XCTAssertEqual(try rows().map(\.model), [VoiceprintModel.current])
    }

    func testRestoreIsIdempotent() throws {
        try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: 1), now: now, in: dbQueue)
        try RegistrySnapshotIO.push(takenAt: now, to: store, from: dbQueue)

        let r = try RegistrySnapshotIO.restoreLatest(from: store, now: now, into: dbQueue)
        XCTAssertEqual(r.inserted, 0)
        XCTAssertEqual(r.alreadyPresent, 1)
        XCTAssertEqual(try rows().count, 1, "恢复不该把已有的再插一遍")
    }



    func testLocalRevokeBeatsTheSnapshot() throws {

        let e = cmd(.enroll, person: 7, seed: 1)
        try VoiceprintRegistry.apply(e, now: now, in: dbQueue)
        try RegistrySnapshotIO.push(takenAt: now, to: store, from: dbQueue)
        try VoiceprintRegistry.apply(cmd(.unenroll, person: 7, seed: 1), now: now, in: dbQueue)

        let r = try RegistrySnapshotIO.restoreLatest(from: store, now: now, into: dbQueue)
        XCTAssertEqual(r.inserted, 0)
        XCTAssertEqual(r.blockedByTombstone, 1)
        XCTAssertEqual(try rows().count, 0, "快照把用户已经删掉的人恢复回来了")
    }

    func testSnapshotRevokeSurvivesAWipeSoReplayStillCannotResurrect() throws {


        let e = cmd(.enroll, person: 7, seed: 1)
        try VoiceprintRegistry.apply(e, now: now, in: dbQueue)
        try VoiceprintRegistry.apply(cmd(.unenroll, person: 7, seed: 1), now: now, in: dbQueue)
        try RegistrySnapshotIO.push(takenAt: now, to: store, from: dbQueue)

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM voiceprints")
            try db.execute(sql: "DELETE FROM enroll_ledger")
        }
        try RegistrySnapshotIO.restoreLatest(from: store, now: now, into: dbQueue)

        let replay = try VoiceprintRegistry.apply(e, now: now, in: dbQueue)
        XCTAssertFalse(replay.execute, "重装之后重放把撤销掉的人写回去了")
        XCTAssertEqual(try rows().count, 0)
    }

    func testNewerLocalEntriesAreNotOverwrittenByAnOlderSnapshot() throws {
        try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: 1), now: now, in: dbQueue)
        try RegistrySnapshotIO.push(takenAt: now, to: store, from: dbQueue)

        try VoiceprintRegistry.apply(cmd(.enroll, person: 9, seed: 2),
                                     now: "2026-08-10T19:00:00+08:00", in: dbQueue)

        try RegistrySnapshotIO.restoreLatest(from: store, now: now, into: dbQueue)
        XCTAssertEqual(try rows().map(\.personID).sorted(), [7, 9],
                       "比快照更新的本地数据被覆盖了")
    }



    func testEachPushIsANewVersionAndOldOnesSurvive() throws {
        try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: 1), now: now, in: dbQueue)
        let k1 = try RegistrySnapshotIO.push(takenAt: "2026-08-10T18:00:00+08:00",
                                             to: store, from: dbQueue)
        try VoiceprintRegistry.apply(cmd(.enroll, person: 9, seed: 2), now: now, in: dbQueue)
        let k2 = try RegistrySnapshotIO.push(takenAt: "2026-08-10T19:00:00+08:00",
                                             to: store, from: dbQueue)

        XCTAssertNotEqual(k1, k2, "每次推是一个新版本,不是覆盖同一个 key")
        let keys = try store.listKeys()
        XCTAssertEqual(keys, [k1, k2].sorted(), "历史版本要留着")
        XCTAssertEqual(keys.last, k2, "key 的字典序必须等于时间序,否则「最新」会取错")
    }

    func testNoSnapshotThrowsInsteadOfPretendingTheRegistryIsEmpty() throws {


        XCTAssertThrowsError(
            try RegistrySnapshotIO.restoreLatest(from: store, now: now, into: dbQueue))
    }

    func testSnapshotStoreHasNoIncrementalWrite() {



        let methods = ["put(_:key:)", "get(key:)", "listKeys()"]
        XCTAssertEqual(methods.count, 3, "SnapshotStore 的口子只有这三个;加了就要在这里说明理由")
    }





    func testEntryWithoutModelIsRejected() throws {
        let noModel = EnrollCommand(action: .enroll, personID: 7, embedding: emb(1),
                                    dim: 192, model: "", source: "x", id: nil)
        XCTAssertThrowsError(try VoiceprintRegistry.apply(noModel, now: now, in: dbQueue))
        XCTAssertEqual(try rows().count, 0)
    }



    func testEntriesAreIsolatedPerModel() throws {
        try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: 1),
                                     now: now, in: dbQueue)
        try VoiceprintRegistry.apply(
            cmd(.enroll, person: 8, seed: 2, model: "campplus/zh-cn-common"),
            now: now, in: dbQueue)

        XCTAssertEqual(try rows().map(\.personID), [7],
                       "ReDimNet-M 的空间里不该出现 CAM++ 那条")
        XCTAssertEqual(try VoiceprintRegistry.entries(
            in: dbQueue, model: "campplus/zh-cn-common").map(\.personID), [8])

        XCTAssertEqual(try dbQueue.read { try VoiceprintRegistry.allEntriesForBackup(in: $0) }
                        .count, 2)
    }



    func testPreV7RowsAreMarkedUnknownAndExcludedFromMatching() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO voiceprints
                  (person_id, embedding, dim, source, created_at, instruction_id)
                VALUES (9, ?, 192, '存量', ?, 'legacy-1')
                """, arguments: [emb(3), now])
        }
        XCTAssertEqual(try rows().count, 0, "来路不明的向量不该进比对")
        let all = try dbQueue.read { try VoiceprintRegistry.allEntriesForBackup(in: $0) }
        XCTAssertEqual(all.map(\.model), [VoiceprintModel.unknownLegacy])
    }



    func testTemplateCountsAreScopedToOneModel() throws {
        for seed in UInt8(1)...UInt8(5) {
            try VoiceprintRegistry.apply(cmd(.enroll, person: 7, seed: seed),
                                         now: now, in: dbQueue)
        }
        try VoiceprintRegistry.apply(cmd(.enroll, person: 8, seed: 9),
                                     now: now, in: dbQueue)
        try VoiceprintRegistry.apply(
            cmd(.enroll, person: 8, seed: 10, model: "campplus/zh-cn-common"),
            now: now, in: dbQueue)

        let n = try VoiceprintRegistry.templateCounts(in: dbQueue,
                                                     model: VoiceprintModel.current)
        XCTAssertEqual(n[7], 5, "够 recommendedTemplates 的那个人")
        XCTAssertEqual(n[8], 1, "另一个模型那条不该算进来")
        XCTAssertEqual(VoiceprintModel.recommendedTemplates, 5)


        try VoiceprintRegistry.apply(cmd(.unenroll, person: 7, seed: 1),
                                     now: now, in: dbQueue)
        XCTAssertEqual(try VoiceprintRegistry.templateCounts(
            in: dbQueue, model: VoiceprintModel.current)[7], 4)
    }








    func testOldSchemaSnapshotIsRejected() throws {
        let old = #"{"schema":"growth.voiceprints/1","takenAt":"x","entries":[],"revoked":[]}"#
        try store.put(Data(old.utf8), key: RegistrySnapshotIO.key(takenAt: "x"))
        XCTAssertThrowsError(
            try RegistrySnapshotIO.restoreLatest(from: store, now: now, into: dbQueue)) { e in
            let msg = "\(e)"
            XCTAssertTrue(msg.contains("growth.voiceprints/1"),
                          "错误里要说清读到的是哪个 schema:\(msg)")
            XCTAssertTrue(msg.contains(RegistrySnapshot.schemaVersion),
                          "错误里要说清期望的是哪个 schema,别只说读失败:\(msg)")
        }
    }







    func testSnapshotWithoutPersonsIsRejectedAsWrongSchemaNotAsParseFailure() throws {
        let v2 = #"{"schema":"growth.voiceprints/2","takenAt":"x","entries":[],"revoked":[]}"#
        try store.put(Data(v2.utf8), key: RegistrySnapshotIO.key(takenAt: "x"))
        XCTAssertThrowsError(
            try RegistrySnapshotIO.restoreLatest(from: store, now: now, into: dbQueue)) { e in
            XCTAssertTrue("\(e)".contains("growth.voiceprints/2"), "\(e)")
            XCTAssertFalse("\(e)".lowercased().contains("keynotfound"),
                           "报成了解析失败,而真相是版本不对:\(e)")
        }
    }






    func testRestoreOntoAFreshDatabaseBringsThePeopleAlong() throws {

        let personA = try PersonStore.create(name: "人物甲", source: .seed, now: now, in: dbQueue)
        for seed in UInt8(1)...UInt8(2) {
            try VoiceprintRegistry.apply(cmd(.enroll, person: personA, seed: seed),
                                         now: now, in: dbQueue)
        }
        try RegistrySnapshotIO.push(takenAt: "2026-08-17T20:00:00+08:00",
                                    to: store, from: dbQueue)


        let fresh = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(fresh)
        XCTAssertEqual(try PersonStore.all(in: fresh).map(\.id), [-1],
                       "前提变了:干净库里不该有别人")

        let r = try RegistrySnapshotIO.restoreLatest(from: store, now: now, into: fresh)
        XCTAssertEqual(r.inserted, 2, "向量没恢复全")

        let restored = try PersonStore.all(in: fresh).first { $0.id == personA }
        XCTAssertEqual(restored?.name, "人物甲")
    }



    func testLocalPersonWinsOverTheSnapshot() throws {
        let id = try PersonStore.create(name: "旧名字", source: .seed, now: now, in: dbQueue)
        try VoiceprintRegistry.apply(cmd(.enroll, person: id, seed: 1), now: now, in: dbQueue)
        try RegistrySnapshotIO.push(takenAt: "2026-08-17T20:00:00+08:00",
                                    to: store, from: dbQueue)

        try PersonStore.rename(id, to: "用户改过的名字", now: now, in: dbQueue)
        try RegistrySnapshotIO.restoreLatest(from: store, now: now, into: dbQueue)

        let after = try dbQueue.read { try PersonStore.find(id, in: $0) }
        XCTAssertEqual(after?.name, "用户改过的名字")
    }
}

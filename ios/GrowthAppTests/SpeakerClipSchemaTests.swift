import XCTest
import GRDB
@testable import GrowthApp

/// 说话人代表片段(`M3-0c` 迁移 v30,PRD §4.4.10)。
///
/// 🔴 这张表存在的全部理由是**它必须活过 7 天音频保留期**。
/// 而落错前缀的表现是:今天一切正常,**第 8 天试听静默失效** ——
/// 认人页还在、播放按钮还在,按了没声音。所以键的前缀由触发器守,不是约定。
final class SpeakerClipSchemaTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private let now = "2026-08-25T16:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (7610, '2026-08-25T14:00:00+08:00', '2026-08-25', 'recording', 'closed')
                """)
            try db.execute(sql: """
                INSERT INTO voiceprint_clusters (cluster_key, session_id, person_id, created_at)
                VALUES ('7610-c0', 7610, 7, ?)
                """, arguments: [self.now])
        }
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func insert(key: String, ratio: Double = 0.9) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO speaker_clips (cluster_key, session_id, r2_key, duration_ms,
                                           speech_ratio, created_at)
                VALUES ('7610-c0', 7610, ?, 4000, ?, ?)
                """, arguments: [key, ratio, self.now])
        }
    }

    /// 🔴 键落在 `clips/` 底下才收 —— 落进音频前缀的当场拒。
    func testAKeyOutsideTheClipPrefixIsRefused() throws {
        XCTAssertNoThrow(try insert(key: R2Layout.clipKey(sessionID: 7610,
                                                          clusterKey: "7610-c0", seq: 0)))
        XCTAssertThrowsError(try insert(key: "inbox/audio/7610/block-0000.m4a"),
                             "片段落进音频前缀也收了 —— 它会跟着 7 天保留期一起没,"
                             + "而表现是第 8 天试听静默失效")
    }

    /// `clipKey` 生成的键必须真的落在 `clipPrefix` 底下 ——
    /// 两处各写一份格式串时,这条是它们对得上的唯一证据。
    func testTheGeneratedKeyLivesUnderTheDeclaredPrefix() {
        let key = R2Layout.clipKey(sessionID: 7610, clusterKey: "7610-c0", seq: 1)
        XCTAssertTrue(key.hasPrefix(R2Layout.clipPrefix), key)
        XCTAssertTrue(key.hasPrefix(R2Layout.clipSessionPrefix(sessionID: 7610)),
                      "键不在本场的片段前缀下 —— 「移出记忆」按场次删就删不到它")
    }

    /// 🔴 **片段挂在簇上,不挂在人上。**
    ///
    /// 匿名人格被命名时改的是 `voiceprint_clusters` 那张映射表,片段一个字都不用动 ——
    /// 条目里那句「人命名并 enroll 之后……已存的照旧能听」靠的就是这一层间接。
    /// 挂在人上的话,命名那一刻要搬一次数据,而搬漏了的表现是**试听按钮消失**。
    func testClipsHangOnTheClusterSoRenamingAPersonMovesNothing() throws {
        try insert(key: R2Layout.clipKey(sessionID: 7610, clusterKey: "7610-c0", seq: 0))
        // 匿名人格被命名 = 映射表改一行
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE voiceprint_clusters SET person_id = 8 WHERE cluster_key = '7610-c0'")
        }
        let reachable = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM speaker_clips c
                  JOIN voiceprint_clusters v ON v.cluster_key = c.cluster_key
                 WHERE v.person_id = 8
                """) ?? -1
        }
        XCTAssertEqual(reachable, 1, "改了映射表之后片段就找不到了 —— 「已存的照旧能听」不成立")
    }

    /// 人声占比是 Mac 算好带过来的,越界的值当场拒 —— 它决定「挑哪几段最听得清」。
    func testAnOutOfRangeSpeechRatioIsRefused() throws {
        XCTAssertThrowsError(try insert(key: "clips/7610/x-0.m4a", ratio: 1.4))
    }

    /// 同一个键不许存两次(重复合并判决 JSON 时的幂等)。
    func testTheSameKeyCannotBeStoredTwice() throws {
        let k = R2Layout.clipKey(sessionID: 7610, clusterKey: "7610-c0", seq: 0)
        try insert(key: k)
        XCTAssertThrowsError(try insert(key: k), "同一段片段落库两次 —— 重放判决就会翻倍")
    }
}

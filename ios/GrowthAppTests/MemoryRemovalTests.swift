import XCTest
import GRDB
@testable import GrowthApp

/// 移出记忆的墓碑通道(§3.1.7,判 3)。
///
/// 三条验收之外,重点打的是「以为删干净了其实没有」这一类:
/// 别的场次被误伤、重复调用炸掉、音频没真删。
final class MemoryRemovalTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var tmpDir: URL!

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MemoryRemovalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try seed()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        dbQueue = nil
    }

    /// 某场次:两行(一条正常、一条占位)。某场次:一行,用来验没被误伤。
    /// 另加一条判断,其 basis_line_ids 指向某场次 的正常行(验 E4)。
    private func seed() throws {
        try dbQueue.write { db in
            for (sid, day) in [(1, "2026-08-08"), (2, "2026-08-09")] {
                try db.execute(sql: """
                    INSERT INTO sessions (id, started_at, day, source, status)
                    VALUES (?, ?, ?, 'recording', 'closed')
                    """, arguments: [sid, "\(day)T14:00:00+08:00", day])
                try db.execute(sql: """
                    INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at, frozen_at)
                    VALUES (?, ?, 1, 1, 'step-asr-v1', 'frozen', ?, ?)
                    """, arguments: [sid, sid, "\(day)T15:00:00+08:00", "\(day)T15:00:00+08:00"])
            }
            try db.execute(sql: """
                INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                VALUES (10, 1, 0, 0, 5000, '今天下午三点开会讨论预算', 0, 0),
                       (11, 1, 1, 5000, 35000, '〔此处缺失 30 秒〕', 12, 1),
                       (20, 2, 0, 0, 4000, '明天上午跟客户对方案', 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO judgments (decided_at, actor, action, target_kind, target_id, basis_line_ids)
                VALUES ('2026-08-08T16:00:00+08:00', 'user', 'accept_nomination', 'thing', '42', '[10]')
                """)
        }
    }

    private func makeAudioFiles(_ names: [String]) throws -> [URL] {
        try names.map { name in
            let url = tmpDir.appendingPathComponent(name)
            try Data("fake audio".utf8).write(to: url)
            return url
        }
    }

    private func ftsHitCount(_ query: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_lines_fts WHERE transcript_lines_fts MATCH ?
                """, arguments: [query]) ?? -1
        }
    }

    // MARK: - 验收第一条:redact 后行仍在

    func testLinesSurviveAsTombstones() throws {
        let audio = try makeAudioFiles(["s1.m4a"])
        let outcome = try MemoryRemoval.removeSession(1, audioFiles: audio, in: dbQueue)
        XCTAssertEqual(outcome, .init(redactedLines: 2, deletedAudioFiles: 1))

        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT line_id, text, redacted, char_offset FROM transcript_lines
                 WHERE transcript_id = 1 ORDER BY seq
                """)
        }
        XCTAssertEqual(rows.count, 2, "行必须还在,永不 DELETE")
        XCTAssertEqual(rows.map { $0["line_id"] as Int64 }, [10, 11], "line_id 原样保留")
        for row in rows {
            XCTAssertEqual(row["text"] as String, MemoryRemoval.tombstoneText)
            XCTAssertEqual(row["redacted"] as Int, 1)
        }
        // char_offset 是冻结口径,不随墓碑文本长度重算(§3.1.2)
        XCTAssertEqual(rows.map { $0["char_offset"] as Int }, [0, 12])
    }

    // MARK: - 验收第二条:basis_line_ids 仍可解析(E4)

    func testBasisLineIDsStillResolve() throws {
        try MemoryRemoval.removeSession(1, audioFiles: [], in: dbQueue)

        let resolved = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                  FROM judgments j
                  JOIN json_each(j.basis_line_ids) b
                  JOIN transcript_lines l ON l.line_id = b.value
                 WHERE j.target_kind = 'thing' AND j.target_id = '42'
                """) ?? -1
        }
        XCTAssertEqual(resolved, 1, "脱敏行仍要能被判断库定位到,只是内容读不出来")
    }

    // MARK: - 验收第三条:FTS 搜不到

    func testRedactedLineIsNotSearchable() throws {
        XCTAssertEqual(try ftsHitCount("\"开会讨论\""), 1, "先证明搜得到,否则下一条断言没意义")
        try MemoryRemoval.removeSession(1, audioFiles: [], in: dbQueue)
        XCTAssertEqual(try ftsHitCount("\"开会讨论\""), 0)
        XCTAssertEqual(try ftsHitCount("\"已移出记忆\""), 0, "墓碑文本本身也不该被搜出来")
    }

    // MARK: - 打自己的实现

    /// 只动目标场次。误伤别的场次是这类操作最贵的 BUG,而且用户看不见。
    func testOtherSessionsAreUntouched() throws {
        try MemoryRemoval.removeSession(1, audioFiles: [], in: dbQueue)

        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT text, redacted FROM transcript_lines WHERE line_id = 20")
        }
        XCTAssertEqual(row?["text"] as String?, "明天上午跟客户对方案")
        XCTAssertEqual(row?["redacted"] as Int?, 0)
        XCTAssertEqual(try ftsHitCount("\"跟客户对\""), 1, "场次 2 仍可搜")
    }

    /// 重复移出同一场次不该炸——第二次是 0 行。
    /// (若通道漏了 `WHERE redacted = 0`,第二次会撞 A1 触发器直接抛。)
    // MARK: - M2-审12:云端那一半

    /// 🔴 **删完本地不等于删完。** 移出记忆之后,这一场必须进「云端待清除」队列。
    ///
    /// 在这之前 `MemoryRemoval` **只动手机** —— 云上的原始音频、ASR 报文、
    /// 抽取产物一个都没删,也没有任何定时清理。而界面上写的是
    /// 「音频、逐字稿、纪要、归属都会删掉,撤不回来」。
    /// **说了删而没删,比不提供删除更糟。**
    func testARemovedSessionIsQueuedForCloudPurge() throws {
        _ = try MemoryRemoval.removeSession(1, audioFiles: [], in: dbQueue)
        let pending = try dbQueue.read { try MemoryRemoval.pendingCloudPurge(in: $0) }
        XCTAssertEqual(pending, [1], "移出记忆的场次没进云端待清除队列 —— 云上那份永远没人删")
    }

    /// 落了 `cloud_purged_at` 才算完 —— 而它只在云端**回读确认空了**之后才落。
    func testCloudPurgeQueueEmptiesOnlyAfterItIsMarked() throws {
        _ = try MemoryRemoval.removeSession(1, audioFiles: [], in: dbQueue)
        try MemoryRemoval.markCloudPurged(1, at: "2026-08-24T12:00:00+08:00", in: dbQueue)
        XCTAssertEqual(try dbQueue.read { try MemoryRemoval.pendingCloudPurge(in: $0) }, [],
                       "标记完还在队列里 ⇒ 每一拍都会重删一遍")
    }

    /// **没被移出记忆的场次不许进队列** —— 否则一次「清除」会把还在用的场次删了。
    func testALiveSessionIsNeverQueuedForPurge() throws {
        XCTAssertEqual(try dbQueue.read { try MemoryRemoval.pendingCloudPurge(in: $0) }, [])
        _ = try MemoryRemoval.removeSession(1, audioFiles: [], in: dbQueue)
        XCTAssertFalse(try dbQueue.read { try MemoryRemoval.pendingCloudPurge(in: $0) }.contains(2),
                       "删场次 1 却把场次 2 也排进了云端清除")
    }

    /// 🔴 **报给云端的号要含全部版本的转写,不只是活跃那一版。**
    ///
    /// 重整产生 v2 之后 v1 按冻结原则保留,而 **v1 同样在云上留过抽取产物**。
    /// 只报活跃版本等于把旧版本的纪要永久留在云端 —— 而界面说的是「都会删掉」。
    func testCloudKeysCoverEveryTranscriptVersionNotJustTheActiveOne() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (session_id, version, part, asr_model, status, created_at, frozen_at)
                VALUES (1, 2, 1, 'x', 'frozen', '2026-08-08T16:00:00+08:00', '2026-08-08T16:00:00+08:00')
                """)
        }
        let keys = try dbQueue.read { try MemoryRemoval.cloudKeys(of: 1, in: $0) }
        XCTAssertEqual(keys.transcripts.count, 2,
                       "只报了活跃版本 —— 旧版本的抽取产物会永远留在云端:\(keys.transcripts)")
    }

    func testRemovalIsIdempotent() throws {
        let first = try MemoryRemoval.removeSession(1, audioFiles: [], in: dbQueue)
        XCTAssertEqual(first.redactedLines, 2)

        let second = try MemoryRemoval.removeSession(1, audioFiles: [], in: dbQueue)
        XCTAssertEqual(second.redactedLines, 0, "已是墓碑的行不再动,也不该抛")
    }

    /// 音频要真删,不是「调了 removeItem 没报错」。
    func testAudioIsActuallyGone() throws {
        let audio = try makeAudioFiles(["a.m4a", "b.m4a", "clip.m4a"])
        let outcome = try MemoryRemoval.removeSession(1, audioFiles: audio, in: dbQueue)

        XCTAssertEqual(outcome.deletedAudioFiles, 3)
        for url in audio {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) 还在")
        }
    }

    /// 音频没删干净必须抛,不能安静地返回成功。
    func testSurvivingAudioIsLoud() throws {
        let audio = try makeAudioFiles(["stubborn.m4a"])

        final class UndeletableFileManager: FileManager {
            override func removeItem(at URL: URL) throws { /* 装作删了,其实没删 */ }
        }

        XCTAssertThrowsError(
            try MemoryRemoval.removeSession(1, audioFiles: audio,
                                            fileManager: UndeletableFileManager(), in: dbQueue)
        ) { error in
            guard case MemoryRemoval.Failure.audioStillOnDisk(let left) = error else {
                return XCTFail("应当报 audioStillOnDisk,实际是 \(error)")
            }
            XCTAssertEqual(left.map(\.lastPathComponent), ["stubborn.m4a"])
        }
    }

    // MARK: - 逐行移出(M1-16b)

    /// 🔴 **验收①②③:那一行立墓碑、对应音频不在盘上、原文再也搜不到。**
    func testRemovingOneLineTombstonesItAndDropsItsBlock() throws {
        let audio = try makeAudioFiles(["block-0000.m4a"])
        XCTAssertEqual(try ftsHitCount("\"开会讨论\""), 1, "前提不成立:本来就搜不到")

        let r = try MemoryRemoval.removeLines([10], audioFiles: audio, in: dbQueue)
        XCTAssertEqual(r, .init(redactedLines: 1, deletedAudioFiles: 1))

        try dbQueue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(
                db, sql: "SELECT text, redacted FROM transcript_lines WHERE line_id = 10"))
            XCTAssertEqual(row["text"] as String, MemoryRemoval.tombstoneText)
            XCTAssertEqual(row["redacted"] as Int, 1)
        }
        XCTAssertEqual(try ftsHitCount("\"开会讨论\""), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio[0].path))
    }

    /// 🔴 **同一场的别的行一个都不许动。** 这是逐行与整场的全部差别,
    /// 而弄错了不会报错:两种都「成功了」,只是一种多抹了几句。
    func testOtherLinesInTheSameSessionAreUntouched() throws {
        try MemoryRemoval.removeLines([10], audioFiles: [], in: dbQueue)
        try dbQueue.read { db in
            // 同一场的占位行 11 不该被碰
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT redacted FROM transcript_lines WHERE line_id = 11"), 0)
            // 别的场次更不该
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT text FROM transcript_lines WHERE line_id = 20"),
                           "明天上午跟客户对方案")
        }
    }

    /// 引用它的判断**不能悬空** —— 行与 `line_id` 都留着(断言 E4)。
    func testTheJudgmentPointingAtTheRemovedLineStillResolves() throws {
        try MemoryRemoval.removeLines([10], audioFiles: [], in: dbQueue)
        let resolved = try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM judgments j
                  JOIN json_each(j.basis_line_ids) b
                  JOIN transcript_lines l ON l.line_id = b.value
                """) ?? -1
        }
        XCTAssertEqual(resolved, 1)
    }

    /// 连点两下不该崩:第二次没有可置墓碑的行,返回 0。
    func testRemovingTheSameLineTwiceIsHarmless() throws {
        try MemoryRemoval.removeLines([10], audioFiles: [], in: dbQueue)
        XCTAssertEqual(try MemoryRemoval.removeLines([10], audioFiles: [], in: dbQueue)
                        .redactedLines, 0)
    }

    /// 空清单是 no-op,不该跑一条 `IN ()` 的坏 SQL。
    func testRemovingNothingIsANoOp() throws {
        XCTAssertEqual(try MemoryRemoval.removeLines([], audioFiles: [], in: dbQueue),
                       .init(redactedLines: 0, deletedAudioFiles: 0))
    }

    /// 音频没删干净同样要**抛** —— 逐行这条路和整场那条共用同一段删除,
    /// 而「以为删了其实没删」在隐私上是最贵的静默失败。
    func testALineRemovalAlsoRefusesToLieAboutAudio() throws {
        let audio = try makeAudioFiles(["stubborn.m4a"])
        final class UndeletableFileManager: FileManager {
            override func removeItem(at URL: URL) throws { }
        }
        XCTAssertThrowsError(try MemoryRemoval.removeLines(
            [10], audioFiles: audio, fileManager: UndeletableFileManager(), in: dbQueue))
    }

    // MARK: - 只有一条 redact 通道

    /// 🔴 **源码断言。** 2026-08-17 我在 `SessionMaintenance` 里另写了一份 redact,
    /// 配了五条测试、全绿 —— **绿的是第二个写方**。数据上两份看不出差别:
    /// 行都立了墓碑、音频都不见了;差别在那份没有的**回读校验**上,
    /// 而「以为删了其实没删」在隐私上是最贵的一种静默失败,它恰恰不产生任何现象。
    ///
    /// 所以扫源码:`redacted = 1` 这个写法只准出现在通道自己和建表迁移里。
    func testNoSecondRedactChannel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GrowthAppTests
            .deletingLastPathComponent()   // ios
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? [])
            .map { (rel: $0.path.replacingOccurrences(of: root.path + "/", with: ""), url: $0) }
            .filter { $0.rel.hasPrefix("GrowthApp/") }
        XCTAssertGreaterThan(files.count, 10, "一个 .swift 都没扫到,这条断言是空转的")

        // 通道自己,和建表/触发器所在的迁移文件 —— 仅有的两处豁免,按相对路径写。
        let exempt = ["GrowthApp/Database/MemoryRemoval.swift",
                      "GrowthApp/Database/AppDatabase.swift"]
        let offenders = try files
            .filter { !exempt.contains($0.rel) }
            .filter { try String(contentsOf: $0.url, encoding: .utf8).contains("redacted = 1") }
            .map(\.rel)
        XCTAssertEqual(offenders, [],
                       "这些文件自己写了一遍 redact —— 移出记忆会有第二个写方:\(offenders)")
    }
}

// MARK: - M1-22 三档全清(用户 2026-08-19 拍板)

extension MemoryRemovalTests {

    /// 造一场:1 行转写 + 四类抽取各一条(带 quote)+ 一句话 + 主题词 + 一条脉络。
    private func seedDerived() throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (7, '2026-08-19T09:00:00+08:00', '2026-08-19', 'mic', 'done');
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status,
                                         created_at, frozen_at)
                VALUES (70, 7, 1, 0, 'm', 'frozen',
                        '2026-08-19T09:05:00+08:00', '2026-08-19T09:05:00+08:00');
                INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms,
                                              text, char_offset, is_gap)
                VALUES (700, 70, 0, 0, 1000, '这句话要被删掉', 0, 0);
                INSERT INTO summaries (transcript_id, one_liner, created_at)
                VALUES (70, '这一场聊了要删掉的东西', '2026-08-19T09:10:00+08:00');
                INSERT INTO summary_topic_keys (transcript_id, key, line_ids)
                VALUES (70, '要删掉的主题', '[700]');
                INSERT INTO summary_key_points (transcript_id, line_id, seq, text, quote)
                VALUES (70, 700, 0, '要删掉的要点', '这句话要被删掉');
                INSERT INTO summary_commitments (transcript_id, line_id, seq, what, quote)
                VALUES (70, 700, 1, '要删掉的承诺', '这句话要被删掉');
                INSERT INTO summary_stances (transcript_id, line_id, seq, stance, quote)
                VALUES (70, 700, 2, '要删掉的立场', '这句话要被删掉');
                INSERT INTO summary_pendings (transcript_id, line_id, seq, issue, quote)
                VALUES (70, 700, 3, '要删掉的悬点', '这句话要被删掉');
                INSERT INTO summary_events (transcript_id, seq, title, summary, first_line_id, last_line_id)
                VALUES (70, 0, '要删掉的标题', '这段聊了要删掉的东西', 700, 700);
                """)
            return 7
        }
    }

    /// 🔴 **删完之后,那句原话不许还能被搜到。**
    ///
    /// 2026-08-19 之前:`MemoryRemoval` 只把 `transcript_lines.text` 立成墓碑,
    /// 而四张表的 `quote` 是**第二份逐字副本**,一个字没动 —— 「移出记忆」
    /// 没有做到它说的事。用户实机问「点了删除之后那条录音还会显示在哪里」问出来的。
    func testDeletingASessionLeavesNoVerbatimCopyAnywhere() async throws {
        let sid = try seedDerived()
        _ = try MemoryRemoval.removeSession(sid, audioFiles: [], in: dbQueue)

        let survivors = try await dbQueue.read { db -> [String] in
            var found: [String] = []
            for (table, cols) in [("summary_key_points", ["text", "quote"]),
                                  ("summary_commitments", ["what", "quote"]),
                                  ("summary_stances", ["stance", "quote"]),
                                  ("summary_pendings", ["issue", "quote"])] {
                for col in cols {
                    let n = try Int.fetchOne(db, sql:
                        "SELECT COUNT(*) FROM \(table) WHERE \(col) LIKE '%要被删掉%' OR \(col) LIKE '%要删掉%'") ?? 0
                    if n > 0 { found.append("\(table).\(col)") }
                }
            }
            let one = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM summaries WHERE one_liner LIKE '%要删掉%'") ?? 0
            if one > 0 { found.append("summaries.one_liner") }
            let topic = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM summary_topic_keys WHERE key LIKE '%要删掉%'") ?? 0
            if topic > 0 { found.append("summary_topic_keys.key") }
            // 事件的标题与摘要(`M5-1`)也是内容的浓缩,一样要清。
            for col in ["title", "summary"] {
                let n = try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM summary_events WHERE \(col) LIKE '%要删掉%'") ?? 0
                if n > 0 { found.append("summary_events.\(col)") }
            }
            return found
        }
        XCTAssertEqual(survivors, [],
                       "移出记忆之后这些地方还留着内容:\(survivors) —— "
                       + "用户以为删干净了,而原话还在库里")
    }

    /// **移出记忆的场次不再出现在首页列表里**(用户:「卡片肯定不要保留」)。
    func testARemovedSessionDisappearsFromTheDayList() async throws {
        let sid = try seedDerived()
        let before = try HomeProjection.cards(day: "2026-08-19", in: dbQueue)
        XCTAssertTrue(before.contains { $0.id == sid }, "造的那一场本来就不在列表里,这条测试没在验东西")

        _ = try MemoryRemoval.removeSession(sid, audioFiles: [], in: dbQueue)
        let after = try HomeProjection.cards(day: "2026-08-19", in: dbQueue)
        XCTAssertFalse(after.contains { $0.id == sid }, "删了之后卡片还在")
    }

    /// 🔴 **还没转写完的场次不许因为「没有行」被当成已删除。**
    ///
    /// 判据若写成「所有行都是墓碑」,对零行的场次是**空真** ——
    /// 用户刚录完还没出稿的那一场会当场从首页消失。
    func testASessionStillBeingProcessedIsNotTreatedAsRemoved() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (8, '2026-08-19T11:00:00+08:00', '2026-08-19', 'mic', 'processing')
                """)
        }
        let list = try HomeProjection.cards(day: "2026-08-19", in: dbQueue)
        XCTAssertTrue(list.contains { $0.id == 8 },
                      "刚录完还没出稿的场次从首页消失了 —— 判据把「零行」当成了「全是墓碑」")
    }
}

extension MemoryRemovalTests {

    /// 🔴 **一场还没转写出行的录音,删了之后卡片必须也消失。**
    ///
    /// 2026-08-19 用户实机:「现在的新包还是删除不了啊,在前端」。
    /// 根因是我 M1-22 那个判据:「**有行,而且全是墓碑**」——
    /// 我加「有行」是为了保护正在处理中的场次不凭空消失,而它顺手也挡住了
    /// **一场根本没转写出行的录音**:删它 ⇒ 0 行置墓碑 ⇒ 判据不成立 ⇒ 卡片永远在。
    ///
    /// 而这种场次恰恰最需要能删:转写失败、卡住、录废了的那些。
    func testDeletingASessionThatNeverTranscribedAlsoRemovesTheCard() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status)
                VALUES (9, '2026-08-19T12:00:00+08:00', '2026-08-19', 'mic', 'closed')
                """)
        }
        let before = try HomeProjection.cards(day: "2026-08-19", in: dbQueue)
        XCTAssertTrue(before.contains { $0.id == 9 }, "造的那一场本来就不在列表里,这条测试没在验东西")

        _ = try MemoryRemoval.removeSession(9, audioFiles: [], in: dbQueue)

        let after = try HomeProjection.cards(day: "2026-08-19", in: dbQueue)
        XCTAssertFalse(after.contains { $0.id == 9 },
                       "一场没转写出行的录音,删了之后卡片还在 —— 用户看到的就是「删不掉」")
    }
}

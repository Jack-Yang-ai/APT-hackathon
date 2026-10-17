import XCTest
import GRDB
@testable import GrowthApp

/// 行级修订(M1-20)。**这一组测试的重心不是「改得成」,是「别的还改不成」。**
///
/// v18 把冻结层的放行口从一条加到三条。加通道的动作天然是在拆护栏 ——
/// 而拆过头了不会有任何东西报错:多放行一种 UPDATE,表现是某天某行被悄悄改掉,
/// 而库里看不出来。所以每一条**不该放行**的形状都在这里真去撞一次。
final class TranscriptRevisionTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    /// seq 0 —— 要改的那一行。「cloud」是 ASR 把「Claude」听错的那个字。
    private let l10 = "老周说cloud的排期下周定"
    /// seq 1 —— 占位行。改它必须被拒(它不是谁说的,是一段缺失)。
    private let l11 = "〔此处缺失 30 秒〕"
    /// seq 2 —— 后面那一行。它的 `char_offset` 要跟着推移,而正文一个字都不许动。
    private let l12 = "那就按这个排期往下走"
    /// seq 3 —— 已经移出记忆的行。偏移要推移,但不该被重新塞回索引。
    private let l13 = MemoryRemoval.tombstoneText

    private let now = "2026-08-18T15:00:00+08:00"

    override func setUpWithError() throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        try TestPeople.seed(in: dbQueue)
        try seed()
    }

    override func tearDownWithError() throws { dbQueue = nil }

    private func seed() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, started_at, day, source, status, active_transcript_id)
                VALUES (1, '2026-08-18T14:00:00+08:00', '2026-08-18', 'recording', 'closed', 1)
                """)
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at, frozen_at)
                VALUES (1, 1, 1, 1, 'step-asr-v1', 'frozen',
                        '2026-08-18T14:30:00+08:00', '2026-08-18T14:30:00+08:00')
                """)
            // char_offset 按冻结口径累计(占位行也参与),在 Swift 里算,免得手抄错。
            var off = 0
            for (lineID, seq, text, isGap) in [
                (Int64(10), 0, l10, false), (11, 1, l11, true),
                (12, 2, l12, false), (13, 3, l13, false),
            ] {
                try db.execute(sql: """
                    INSERT INTO transcript_lines
                      (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                    VALUES (?, 1, ?, ?, ?, ?, ?, ?)
                    """, arguments: [lineID, seq, seq * 5000, (seq + 1) * 5000,
                                     text, off, isGap ? 1 : 0])
                // 词索引由写入方填(`WordIndex` 是唯一入口),触发器填不了 —— 切词要调
                // NLTokenizer,SQL 里调不到。这里照 `TranscriptFreeze` 的做法补上。
                try WordIndex.index(lineID: lineID, text: text, isGap: isGap, in: db)
                off += text.count
            }
            // seq 3 走 redact 通道立成墓碑(直接插 redacted=1 会绕开索引移除)。
            try db.execute(sql: """
                UPDATE transcript_lines SET text = ?, redacted = 1 WHERE line_id = 13
                """, arguments: [MemoryRemoval.tombstoneText])
        }
    }

    // MARK: - 🔴 主会话 2026-08-18 补的三道闸(子 Agent 按契约字面实现,而契约漏了)

    /// **`block_seq` 一个字都不许改 —— 哪怕带着一条合法的修订记录。**
    ///
    /// 子 Agent 交付时点出:三条通道(**包括原来那条 redact**,v15 加列时没回来补)
    /// 都没约束它。后果是「借改错字之名顺手改音频归属」:`LineAudio` 会拿它去找
    /// `block-%04d.m4a`,改掉之后**跳原话会跳到另一块音频**,而没有任何东西报错。
    func testBlockSeqCannotRideAlongOnARevision() throws {
        // 种一行**带 block_seq** 的。不能用 UPDATE 去种 —— 那条 UPDATE 本身
        // 就会被新闸拦下(它不属于三条通道里的任何一条),而那恰好是本条要验的东西。
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset,
                   is_gap, block_seq)
                VALUES (30, 1, 9, 90000, 95000, ?, 999, 0, 0)
                """, arguments: [l10])
        }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcript_line_revisions (line_id, before, after, actor, at)
                VALUES (30, ?, ?, 'user', ?)
                """, arguments: [l10, "改过的", now])
        }
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE transcript_lines SET text = ?, block_seq = 7 WHERE line_id = 30
                """, arguments: ["改过的"])
        }, "带着合法修订记录就把 block_seq 改掉了 —— 跳原话会跳到别的音频块,而不报错")

        XCTAssertEqual(try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT block_seq FROM transcript_lines WHERE line_id = 30")
        }, 0, "整条 UPDATE 该被 ABORT,一个字节都不该落")
    }

    /// **同一条修订记录不许被重放。**
    ///
    /// `EXISTS` 只问「有没有一条 before/after 对得上的」。A→B→A 之后两条记录都在,
    /// 此时再改 A→B **不需要写任何新痕**就能过 —— 那次改动在修订表里查不到。
    /// 窄,但真:它正好绕掉「改字必留痕由数据库强制」这条唯一的地基。
    func testARevisionRecordCannotBeReplayed() throws {
        _ = try TranscriptRevision.revise(lineID: 10, to: "B", actor: "user", now: now, in: dbQueue)
        _ = try TranscriptRevision.revise(lineID: 10, to: l10, actor: "user", now: now, in: dbQueue)
        // 此刻库里有 A→B 与 B→A 两条。直接再改 A→B,**不写新记录**。
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = 'B' WHERE line_id = 10")
        }, "旧那条 A→B 记录被重放了 —— 这次改动在修订表里没有任何痕迹")
        XCTAssertEqual(try text(10), l10, "该被 ABORT")
    }

    /// 🔴 **移出记忆必须把修订表里的原话一起清掉。**
    ///
    /// 修订表存着**改错字之前的原话**。只清 `transcript_lines` 而留着它,
    /// 等于「录到了不该录的东西」这件事根本没被处理 —— 而界面上与「删干净了」
    /// 一模一样,没有任何东西会报错。
    ///
    /// 「留痕不可删」保的是**「这一行改过」这个事实**,不是原文本身:
    /// 行还在、`actor` / `at` 还在,只有内容没了。与冻结层那条 redact 同一个形状。
    func testRemovingFromMemoryAlsoBlanksTheOriginalInTheRevisionTable() throws {
        _ = try TranscriptRevision.revise(lineID: 10, to: "改过的", actor: "user",
                                          now: now, in: dbQueue)
        XCTAssertEqual(try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT before FROM transcript_line_revisions WHERE line_id = 10")
        }, l10, "前提没成立:修订表里本来就没存下原话,下面验的是空气")

        try MemoryRemoval.removeLines([10], audioFiles: [], in: dbQueue)

        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT before, after, actor, at FROM transcript_line_revisions WHERE line_id = 10
                """)
        }
        let r = try XCTUnwrap(row, "修订记录被删掉了 —— 该留痕的是「这行改过」这件事")
        XCTAssertEqual(r["before"] as String, "", "原话还躺在修订表里 —— 移出记忆没做到它说的事")
        XCTAssertEqual(r["after"] as String, "")
        XCTAssertEqual(r["actor"] as String, "user", "谁改的仍然要查得到")
        XCTAssertEqual(r["at"] as String, now, "什么时候改的仍然要查得到")
    }

    /// 上一条的反面:墓碑通道**只准清内容**,不准借它改别的列。
    func testTheRevisionTombstoneChannelCannotBeUsedToRewriteWhoDidIt() throws {
        _ = try TranscriptRevision.revise(lineID: 10, to: "改过的", actor: "user",
                                          now: now, in: dbQueue)
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE transcript_line_revisions SET before = '', after = '', actor = '别人'
                 WHERE line_id = 10
                """)
        }, "借墓碑通道把「谁改的」也改了")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE transcript_line_revisions SET before = '' WHERE line_id = 10
                """)
        }, "只清了 before、after 还留着 —— 半清等于没清")
    }

    // MARK: - 探针

    private func text(_ lineID: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT text FROM transcript_lines WHERE line_id = ?",
                                arguments: [lineID])
        }
    }

    private func offsets() throws -> [Int] {
        try dbQueue.read { db in
            try Int.fetchAll(db, sql:
                "SELECT char_offset FROM transcript_lines WHERE transcript_id = 1 ORDER BY seq")
        }
    }

    /// trigram 那条腿。查询串要 ≥3 个字符才有意义。
    private func trigramHits(_ s: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_lines_fts
                 WHERE transcript_lines_fts MATCH ?
                """, arguments: [TranscriptSearch.phraseLiteral(s)]) ?? -1
        }
    }

    /// 词那条腿。查询串按**与写入同一个切词器**切,短词也搜得到。
    private func wordHits(_ s: String) throws -> Int {
        guard let q = TranscriptSearch.wordQuery(s) else { return -1 }
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM transcript_line_tokens_fts
                 WHERE transcript_line_tokens_fts MATCH ?
                """, arguments: [q]) ?? -1
        }
    }

    private func revisionCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_line_revisions") ?? -1
        }
    }

    /// 手写一条修订记录(不改正文),用来单独打触发器的 `EXISTS` 那一半。
    private func writeRevision(lineID: Int64, before: String, after: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcript_line_revisions (line_id, before, after, actor, at)
                VALUES (?, ?, ?, 'user', ?)
                """, arguments: [lineID, before, after, now])
        }
    }

    // MARK: - 一、照妖镜:仍然会 ABORT 的八种形状

    /// 🔴 **本条是整个任务的核心**:没有留痕就改不动字。
    /// 「改字必留痕」若只靠调用方自觉,少写一次不报错、不崩,只是那一次改字从此无痕。
    func testUpdateTextWithoutRevisionRecordIsRejected() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = ? WHERE line_id = 10",
                           arguments: ["老周说Claude的排期下周定"])
        }, "没有修订记录就改正文,必须 ABORT")
        XCTAssertEqual(try text(10), l10, "抛了错,正文也必须一个字节没动")
    }

    /// 修订记录在,但 `before` 与实际旧文对不上 —— 那条记录记的是**另一次**改动,
    /// 拿它给这一次背书就是伪造留痕。
    func testRevisionRecordWithWrongBeforeIsRejected() throws {
        try writeRevision(lineID: 10, before: "完全不是这一行的原文", after: "老周说Claude的排期下周定")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = ? WHERE line_id = 10",
                           arguments: ["老周说Claude的排期下周定"])
        }, "before 对不上旧文,必须 ABORT")
        XCTAssertEqual(try text(10), l10)
    }

    /// `after` 对不上要写进去的新文,同理 —— 否则「留痕」与「真改了什么」可以各说各话。
    func testRevisionRecordWithWrongAfterIsRejected() throws {
        try writeRevision(lineID: 10, before: l10, after: "改成了别的东西")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = ? WHERE line_id = 10",
                           arguments: ["老周说Claude的排期下周定"])
        }, "after 对不上新文,必须 ABORT")
        XCTAssertEqual(try text(10), l10)
    }

    /// 别人那一行的修订记录不能给这一行背书。
    func testRevisionRecordOfAnotherLineIsRejected() throws {
        try writeRevision(lineID: 12, before: l10, after: "老周说Claude的排期下周定")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = ? WHERE line_id = 10",
                           arguments: ["老周说Claude的排期下周定"])
        }, "line_id 对不上,必须 ABORT")
        XCTAssertEqual(try text(10), l10)
    }

    /// 时间戳属于「这是哪一行」,一毫秒都不许借修订之名动。
    func testShiftingTimestampIsRejectedEvenWithRevisionRecord() throws {
        let new = "老周说Claude的排期下周定"
        try writeRevision(lineID: 10, before: l10, after: new)
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE transcript_lines SET text = ?, t_start_ms = 1 WHERE line_id = 10
                """, arguments: [new])
        }, "顺手改 t_start_ms 必须 ABORT")
        XCTAssertEqual(try text(10), l10)
    }

    func testShiftingSeqIsRejected() throws {
        let new = "老周说Claude的排期下周定"
        try writeRevision(lineID: 10, before: l10, after: new)
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = ?, seq = 99 WHERE line_id = 10",
                           arguments: [new])
        }, "顺手改 seq 必须 ABORT")
        XCTAssertEqual(try text(10), l10)
    }

    /// 改 `transcript_id` = 把这一行搬到另一个版本里去,引用它的一切当场指错地方。
    func testMovingToAnotherTranscriptIsRejected() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
                VALUES (2, 1, 2, 1, 'step-asr-v1', 'frozen', '2026-08-18T16:00:00+08:00')
                """)
        }
        let new = "老周说Claude的排期下周定"
        try writeRevision(lineID: 10, before: l10, after: new)
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE transcript_lines SET text = ?, transcript_id = 2 WHERE line_id = 10
                """, arguments: [new])
        }, "顺手改 transcript_id 必须 ABORT")
        XCTAssertEqual(try text(10), l10)
    }

    /// 占位行没有原话可改。给它改字等于**凭空造一段内容**,而库里看不出这段是编的。
    func testRevisingGapLineIsRejectedBySQLAndByAPI() throws {
        try writeRevision(lineID: 11, before: l11, after: "这段其实说了什么")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = ? WHERE line_id = 11",
                           arguments: ["这段其实说了什么"])
        }, "占位行改字必须 ABORT")
        XCTAssertEqual(try text(11), l11)

        XCTAssertThrowsError(try TranscriptRevision.revise(
            lineID: 11, to: "这段其实说了什么", actor: "user", now: now, in: dbQueue))
    }

    /// 墓碑行改字 = 把移出记忆撤销。
    func testRevisingRedactedLineIsRejectedBySQLAndByAPI() throws {
        try writeRevision(lineID: 13, before: l13, after: "把移出记忆的话弄回来")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_lines SET text = ? WHERE line_id = 13",
                           arguments: ["把移出记忆的话弄回来"])
        }, "墓碑行改字必须 ABORT")
        XCTAssertEqual(try text(13), MemoryRemoval.tombstoneText)

        XCTAssertThrowsError(try TranscriptRevision.revise(
            lineID: 13, to: "把移出记忆的话弄回来", actor: "user", now: now, in: dbQueue))
    }

    /// DELETE 永远不放行 —— v18 一个字都没碰这条。
    func testDeleteStillRejected() throws {
        try writeRevision(lineID: 10, before: l10, after: "随便")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcript_lines WHERE line_id = 10")
        })
        let n = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_lines") ?? -1
        }
        XCTAssertEqual(n, 4)
    }

    /// 修订记录本身 append-only。可改的话就能「先写一条随便的、再改成对得上的形状」,
    /// 留痕当场变成摆设。
    func testRevisionLogIsAppendOnly() throws {
        try writeRevision(lineID: 10, before: l10, after: "甲")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "UPDATE transcript_line_revisions SET after = '乙' WHERE line_id = 10")
        }, "修订记录不许改")
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcript_line_revisions WHERE line_id = 10")
        }, "修订记录不许删")
        XCTAssertEqual(try revisionCount(), 1)
    }

    // MARK: - 二、照妖镜:仍然放行的三种形状

    /// redact 通道照常放行 —— v18 把它原样搬过来了。
    /// (`FrozenLayerTests` 那四条也打的是同一条通道,那边一个字没改。)
    func testRedactChannelStillWorks() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE transcript_lines SET text = ?, redacted = 1 WHERE line_id = 12
                """, arguments: [MemoryRemoval.tombstoneText])
        }
        XCTAssertEqual(try text(12), MemoryRemoval.tombstoneText)
        XCTAssertEqual(try trigramHits("按这个排期"), 0, "墓碑之后不该还搜得到")
    }

    /// 通道三:纯偏移推移(文字逐字相同)放行。
    func testPureOffsetShiftIsAllowed() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE transcript_lines SET char_offset = char_offset + 7 WHERE seq >= 1
                """)
        }
        let base = [0, l10.count, l10.count + l11.count, l10.count + l11.count + l12.count]
        XCTAssertEqual(try offsets(), [base[0], base[1] + 7, base[2] + 7, base[3] + 7])
    }

    /// 通道三只准动偏移:文字若同时变了,`EXISTS` 那一半接手,没有留痕仍然 ABORT。
    func testOffsetShiftCannotSmuggleTextChange() throws {
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE transcript_lines SET char_offset = char_offset + 7, text = '偷改' WHERE line_id = 12
                """)
        }, "借偏移推移之名改文字,必须 ABORT")
        XCTAssertEqual(try text(12), l12)
    }

    // MARK: - 三、真的改一次

    func testReviseHappyPath() throws {
        let new = "老周说Claude的排期下周定"
        let r = try TranscriptRevision.revise(lineID: 10, to: new, actor: "user",
                                              now: now, in: dbQueue)

        XCTAssertEqual(try text(10), new)
        XCTAssertEqual(r.offsetShift, new.count - l10.count)
        XCTAssertEqual(r.offsetShift, 1, "cloud(5)→Claude(6),推 1 个字")

        // 后续行整体推移;**它们的正文一个字都没动**。
        let base = [0, l10.count, l10.count + l11.count, l10.count + l11.count + l12.count]
        XCTAssertEqual(try offsets(), [base[0], base[1] + 1, base[2] + 1, base[3] + 1])
        XCTAssertEqual(try text(11), l11)
        XCTAssertEqual(try text(12), l12)
        XCTAssertEqual(try text(13), MemoryRemoval.tombstoneText)

        // 留痕落对了没有
        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM transcript_line_revisions WHERE id = ?",
                             arguments: [r.revisionID])
        }
        XCTAssertEqual(row?["before"] as String?, l10)
        XCTAssertEqual(row?["after"] as String?, new)
        XCTAssertEqual(row?["actor"] as String?, "user")
        XCTAssertEqual(row?["at"] as String?, now)

        // 时间戳 / seq / 版本一个都没动
        let fixed = try dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT transcript_id, seq, t_start_ms, t_end_ms, is_gap, redacted
                  FROM transcript_lines WHERE line_id = 10
                """)
        }
        XCTAssertEqual(fixed?["transcript_id"] as Int64?, 1)
        XCTAssertEqual(fixed?["seq"] as Int?, 0)
        XCTAssertEqual(fixed?["t_start_ms"] as Int?, 0)
        XCTAssertEqual(fixed?["t_end_ms"] as Int?, 5000)
        XCTAssertEqual(fixed?["is_gap"] as Int?, 0)
        XCTAssertEqual(fixed?["redacted"] as Int?, 0)
    }

    func testReviseRefusesNoOpEmptyAndMissingLine() throws {
        XCTAssertThrowsError(try TranscriptRevision.revise(
            lineID: 10, to: l10, actor: "user", now: now, in: dbQueue), "没改动要抛")
        XCTAssertThrowsError(try TranscriptRevision.revise(
            lineID: 10, to: "", actor: "user", now: now, in: dbQueue), "清空一行要走 redact")
        XCTAssertThrowsError(try TranscriptRevision.revise(
            lineID: 999, to: "无中生有", actor: "user", now: now, in: dbQueue), "行不存在要抛")
        XCTAssertEqual(try revisionCount(), 0, "抛了错就一条痕都不该留下")
        XCTAssertEqual(try text(10), l10)
    }

    /// 改两次:第二次的 `before` 是第一次的结果,两条痕都在。
    func testReviseTwiceKeepsBothTraces() throws {
        _ = try TranscriptRevision.revise(lineID: 10, to: "老周说Claude的排期下周定",
                                          actor: "user", now: now, in: dbQueue)
        _ = try TranscriptRevision.revise(lineID: 10, to: "老周说Claude的排期本周定",
                                          actor: "user", now: now, in: dbQueue)
        let all = try TranscriptRevision.revisions(sessionID: 1, in: dbQueue)[10] ?? []
        XCTAssertEqual(all.map(\.before), [l10, "老周说Claude的排期下周定"])
        XCTAssertEqual(all.map(\.after), ["老周说Claude的排期下周定", "老周说Claude的排期本周定"])
    }

    // MARK: - 四、搜索的照妖镜(两张索引各一次)

    /// 🔴 少了这一组,external content 表写坏了不会有任何东西报错 ——
    /// 表现是「改完的字搜不到」或者「改掉的字还搜得到」,而两者都要等到用户去搜才暴露。
    func testBothSearchLegsFollowTheRevision() throws {
        // 先证明索引本来是活的(不然「搜不到」在一张全坏的索引上也是绿的)
        XCTAssertEqual(try trigramHits("说cloud的"), 1)
        XCTAssertEqual(try wordHits("cloud"), 1)

        _ = try TranscriptRevision.revise(lineID: 10, to: "老周说Claude的排期下周定",
                                          actor: "user", now: now, in: dbQueue)

        // trigram 腿:≥3 字的串
        XCTAssertEqual(try trigramHits("说cloud的"), 0, "旧词还搜得到 = 索引没跟上")
        XCTAssertEqual(try trigramHits("说Claude的"), 1, "新词搜不到 = 索引没补回来")
        // 词腿:一个短词
        XCTAssertEqual(try wordHits("cloud"), 0, "词索引里的旧词没删干净")
        XCTAssertEqual(try wordHits("Claude"), 1, "词索引没按新文重切")

        // 端到端也走一遍 —— 两条腿在 `TranscriptSearch` 里是 OR 起来的,
        // 单测索引表还不能证明查询那一层拿得到。
        let hits = try dbQueue.read { db in try TranscriptSearch.search("Claude", in: db) }
        XCTAssertEqual(hits.map(\.lineID), [10])
        let gone = try dbQueue.read { db in try TranscriptSearch.search("cloud", in: db) }
        XCTAssertTrue(gone.isEmpty, "改掉的词还搜得到")
    }

    /// 🔴 **通道三最容易静默弄坏的东西**:后续行只动了偏移,却被正文索引的
    /// UPDATE 钩子当成 redact 删出索引 —— 表现是「改一个错字,这一场后面全搜不到」。
    /// v18 给那条钩子补了 `NEW.redacted = 1`,这一条就是钉它的。
    func testShiftedLinesStaySearchable() throws {
        XCTAssertEqual(try trigramHits("按这个排期"), 1)

        _ = try TranscriptRevision.revise(lineID: 10, to: "老周说Claude的排期下周定",
                                          actor: "user", now: now, in: dbQueue)

        XCTAssertEqual(try trigramHits("按这个排期"), 1, "被推移的行不该掉出索引")
        // 词索引这条腿用本仓自己的不变量打:每一条该被索引的行都得有词索引。
        // 「搜某个中文短词还搜得到」那种断言依赖 NLTokenizer 怎么切,
        // 而切法随系统词库变 —— 拿它当照妖镜会变成一条随 iOS 版本飘的测试。
        let unindexed = try dbQueue.read { db in try WordIndex.unindexedLineCount(in: db) }
        XCTAssertEqual(unindexed, 0, "改完之后有行掉出了词索引")
        // 墓碑行不该因为推移被塞回索引
        XCTAssertEqual(try trigramHits(MemoryRemoval.tombstoneText), 0)
    }

    // MARK: - 五、引文传播

    private func insertKeyPoint(id: Int64, seq: Int, lineID: Int64, quote: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO summary_key_points (id, transcript_id, line_id, seq, text, quote)
                VALUES (?, 1, ?, ?, '排期定了', ?)
                """, arguments: [id, lineID, seq, quote])
        }
    }

    private func quote(_ id: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT quote FROM summary_key_points WHERE id = ?",
                                arguments: [id])
        }
    }

    /// 改完之后,引了那一行的卡片**仍然过得了 `ExtractValidate` 的逐字判定**。
    /// 不传播的话它当场变红,而那是「改对了反而变红」—— 这种红会训练人去无视它。
    func testQuotePropagationKeepsExtractValidateGreen() throws {
        let new = "老周说Claude的排期下周定"
        try insertKeyPoint(id: 1, seq: 0, lineID: 10, quote: "cloud的排期下周定")
        // 引的是同一行的别处,不含被改的片段 —— 不该被动,也不该被算成失败。
        try insertKeyPoint(id: 2, seq: 1, lineID: 10, quote: "的排期下周定")
        // 引的是别的行 —— 一个字都不该碰(不做「全场替换」)。
        try insertKeyPoint(id: 3, seq: 2, lineID: 12, quote: "cloud")

        let r = try TranscriptRevision.revise(lineID: 10, to: new, actor: "user",
                                              now: now, in: dbQueue)

        XCTAssertEqual(r.quotesUpdated, 1)
        XCTAssertEqual(r.staleQuotes, [])
        XCTAssertEqual(try quote(1), "Claude的排期下周定")
        XCTAssertEqual(try quote(2), "的排期下周定", "不含被改片段的引文不该被动")
        XCTAssertEqual(try quote(3), "cloud", "别的行的引文一个字都不该碰")

        // 尺子用生产那一把:`ExtractValidate` 第②项校验。
        let line = ExtractValidate.Line(lineID: 10, text: new, isGap: false, personID: 7)
        for id in [Int64(1), 2] {
            let verdict = ExtractValidate.check(
                ["line_id": 10, "point": "排期定了", "quote": try quote(id)!], line: line)
            XCTAssertEqual(verdict, .passed, "引文 \(id) 改完仍然要逐字成立")
        }
    }

    /// 🔴 **改不动的要报出来。** 同一个片段在这一行里出现两次、只改了其中一次时,
    /// 逐字替换会把另一次也换掉 —— 换出来的引文不再是新原文的子串。
    /// 这一条钉的是:它进 `staleQuotes` 被带回界面,而不是被静默吞掉。
    func testUnfixableQuoteIsReportedNotSwallowed() throws {
        // 另建一行:同一个词出现两次,只改前面那次。
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcript_lines
                  (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
                VALUES (20, 1, 4, 20000, 25000, 'cloud的排期由cloud组定', 0, 0)
                """)
        }
        try dbQueue.write { db in
            try WordIndex.index(lineID: 20, text: "cloud的排期由cloud组定", isGap: false, in: db)
        }
        try insertKeyPoint(id: 4, seq: 3, lineID: 20, quote: "cloud的排期由cloud组定")

        let r = try TranscriptRevision.revise(lineID: 20, to: "Claude的排期由cloud组定",
                                              actor: "user", now: now, in: dbQueue)

        // 🔴 改不成 ⇒ **一个字都不写**(2026-08-18 主会话改的行为)。
        // 先写后验的话,落库的那条既不是原话、也不是新原文的子串,
        // 是**一句从未在任何地方存在过的话** —— 而「报出来」和「没写坏」是两回事:
        // 报出来只是让人知道有一条坏的,那条坏的已经进了内容库。
        XCTAssertEqual(r.quotesUpdated, 0, "改不成却还是写了 —— 库里多了一句谁都没说过的话")
        XCTAssertEqual(r.staleQuotes, [.init(table: "summary_key_points", id: 4)],
                       "对不上的引文必须被报出来,不许静默跳过")
        // 原样留着:旧引文至少还是**当时那一版**的逐字证据。
        XCTAssertEqual(try quote(4), "cloud的排期由cloud组定",
                       "引文被改写了 —— 这一行里 cloud 出现两次而只改了一次,"
                       + "替换会把另一次也换掉,写出来的是半新半旧的四不像")
        // 尺子确认它相对**新**原文确实对不上了 —— 界面据此提醒用户回头看。
        XCTAssertFalse(TextNormalize.isVerbatim(quote: try quote(4)!,
                                                source: "Claude的排期由cloud组定"))
    }

    /// 四张表都要走到。少一张的表现是那张表的引文从此对不上,而没有任何东西会红。
    func testAllFourQuoteTablesArePropagated() throws {
        let new = "老周说Claude的排期下周定"
        try dbQueue.write { db in
            for (i, t) in ["summary_key_points", "summary_commitments",
                           "summary_stances", "summary_pendings"].enumerated() {
                let extra = ["summary_key_points": "text", "summary_commitments": "what",
                             "summary_stances": "stance", "summary_pendings": "issue"][t]!
                try db.execute(sql: """
                    INSERT INTO \(t) (transcript_id, line_id, seq, \(extra), quote)
                    VALUES (1, 10, ?, '随便', 'cloud的排期')
                    """, arguments: [i])
            }
        }
        let r = try TranscriptRevision.revise(lineID: 10, to: new, actor: "user",
                                              now: now, in: dbQueue)
        XCTAssertEqual(r.quotesUpdated, 4)
        XCTAssertEqual(r.staleQuotes, [])
        for t in TranscriptRevision.quoteTables {
            let q = try dbQueue.read { db in
                try String.fetchOne(db, sql: "SELECT quote FROM \(t) WHERE line_id = 10")
            }
            XCTAssertEqual(q, "Claude的排期", "\(t) 的引文没跟着改")
        }
    }

    // MARK: - 六、事件流水与最小差分

    func testRevisionRecordsAProcessingEvent() throws {
        _ = try TranscriptRevision.revise(lineID: 10, to: "老周说Claude的排期下周定",
                                          actor: "user", now: now, in: dbQueue)
        let e = try ProcessingEvents.latest(in: dbQueue)
        XCTAssertEqual(e?.trigger, ProcessingEvents.Trigger.foreground.rawValue)
        XCTAssertEqual(e?.outcome, "改错字:line 10")
    }

    /// 最小差分:只把真正变了的那一小段拿出来。整行去替换的话,
    /// 引文(本来就是原话的一截)一条都对不上。
    func testChangedFragmentIsMinimal() throws {
        XCTAssertEqual(TranscriptRevision.changedFragment(from: "老周说cloud的排期",
                                                          to: "老周说Claude的排期").0, "cloud")
        XCTAssertEqual(TranscriptRevision.changedFragment(from: "老周说cloud的排期",
                                                          to: "老周说Claude的排期").1, "Claude")
        // 纯插入:旧片段是空的。空串是任何串的子串,替换逻辑必须挡住它。
        XCTAssertEqual(TranscriptRevision.changedFragment(from: "我用它", to: "我用了它").0, "")
        XCTAssertEqual(TranscriptRevision.changedFragment(from: "我用它", to: "我用了它").1, "了")
        // 纯删除
        XCTAssertEqual(TranscriptRevision.changedFragment(from: "我用了它", to: "我用它").0, "了")
        XCTAssertEqual(TranscriptRevision.changedFragment(from: "我用了它", to: "我用它").1, "")
        // 前后缀重叠(「aaa」→「aa」):不许切出越界的片段
        XCTAssertEqual(TranscriptRevision.changedFragment(from: "aaa", to: "aa").0, "a")
        XCTAssertEqual(TranscriptRevision.changedFragment(from: "aaa", to: "aa").1, "")
    }

    // MARK: - 七、界面必须把结果说出来

    /// 🔴 **`staleQuotes` 非空时那句话必须是红的。**
    /// 灰色小字与「一切正常」在屏上长得一样(`Notice` 的 doc 记的就是这次事故),
    /// 而「有几条卡片现在引错话了」恰恰是用户唯一必须看见的一句。
    func testReviseNoteSaysQuotesUpdatedAndNeverSwallowsStale() throws {
        let clean = TranscriptView.reviseNote(.init(revisionID: 1, offsetShift: 1,
                                                    quotesUpdated: 3, staleQuotes: []))
        XCTAssertFalse(clean.isError)
        XCTAssertTrue(clean.text.contains("3"), "顺带改了几条引文要说出来:\(clean.text)")

        let dirty = TranscriptView.reviseNote(.init(
            revisionID: 1, offsetShift: 1, quotesUpdated: 1,
            staleQuotes: [.init(table: "summary_commitments", id: 9)]))
        XCTAssertTrue(dirty.isError, "有引文对不上了,这条提示必须是错误态")
        XCTAssertTrue(dirty.text.contains("summary_commitments"), dirty.text)

        // 一条引文都没动时不该编一个「更新了 0 条」出来。
        let quiet = TranscriptView.reviseNote(.init(revisionID: 1, offsetShift: 0,
                                                    quotesUpdated: 0, staleQuotes: []))
        XCTAssertFalse(quiet.isError)
        XCTAssertFalse(quiet.text.contains("0 条"), quiet.text)
    }

    /// 纯插入时引文若跨过插入点,它已经不成立了 —— 也要报出来。
    /// (「不含旧片段就一定还成立」这句话在纯插入上不成立,所以实现是**回读验一次**,
    /// 不是只看含不含。)
    func testPureInsertionBreakingAQuoteIsReported() throws {
        try insertKeyPoint(id: 5, seq: 4, lineID: 10, quote: "说cloud的")
        let r = try TranscriptRevision.revise(lineID: 10, to: "老周说cloud了的排期下周定",
                                              actor: "user", now: now, in: dbQueue)
        XCTAssertEqual(r.quotesUpdated, 0, "旧片段是空的,不该做替换")
        XCTAssertEqual(r.staleQuotes, [.init(table: "summary_key_points", id: 5)])
        XCTAssertEqual(try quote(5), "说cloud的", "改不动的引文保持原样,只是被报出来")
    }
}

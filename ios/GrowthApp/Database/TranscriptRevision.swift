import Foundation
import GRDB

/// 行级修订(M1-20)——**改一个错字的唯一写方**。
///
/// ASR 把「Claude」听成「cloud」。用户要改的就是这一个字,而在这之前只有两个极端:
/// 整场重出 v2(为一个字太重),或者没辙。这个文件是中间那条路。
///
/// ## 它不是「解冻」
///
/// 冻结层保护的是**内容**,不是偏移量。这一层能改的只有 `text` 与派生的 `char_offset`;
/// `line_id` / `transcript_id` / `seq` / 起止毫秒 / `is_gap` 一个都碰不到 ——
/// 它们回答的是「这是哪一行」,改了就是把一行掉包成另一行,而引用它的判断、
/// 卡片、归属会跟着指错地方,**不报错**。这条边界写死在 v18 的触发器里,不在这里。
///
/// ## 为什么「唯一写方」这次不是口号
///
/// 铁律 3 那次(归属层)靠的是纪律,结果实测悬空 1979 条。这次不一样:
/// v18 的通道二要求**先有一条 before/after 对得上的 `transcript_line_revisions`**,
/// 别的代码路径想绕过这个文件直接 `UPDATE transcript_lines SET text = …`,
/// 会被触发器 ABORT。**不是这里有特权,是这里恰好写出了触发器放行的那种形状。**
///
/// ## 一个事务,七件事
///
/// 改字、推偏移、两张索引、四张表的引文,任何一件单独落地都会留下一份对不上的账:
/// 索引没跟上 ⇒ 改完的字搜不到;引文没跟上 ⇒ 引了这一行的卡片**当场校验不过**,
/// 而那是「改对了反而变红」,这种红会训练人去无视它。所以只有全成或全不成。
enum TranscriptRevision {

    /// 一条对不上的引文。**报出来,不吞。**
    struct StaleQuote: Equatable {
        let table: String
        let id: Int64
    }

    struct Result: Equatable {
        /// 这次留下的那条痕。
        let revisionID: Int64
        /// 后续行整体推移了多少个字。0 = 新旧一样长,没推。
        let offsetShift: Int
        /// 顺带改好的引文条数。
        let quotesUpdated: Int
        /// 🔴 **改完仍然对不上原话的引文。** 界面必须说出来 ——
        /// 静默跳过的话,这几条会在下一次校验时变红,而那时没人知道是这次改字弄的。
        let staleQuotes: [StaleQuote]
    }

    /// 一行改过的历史。界面拿它显示「原文是什么」。
    struct Revision: Equatable {
        let id: Int64
        let lineID: Int64
        let before: String
        let after: String
        let actor: String
        let at: String
    }

    enum Failure: Error, CustomStringConvertible {
        case noSuchLine(Int64)
        case gapLine(Int64)
        case redactedLine(Int64)
        case unchanged
        case emptyText

        var description: String {
            switch self {
            case .noSuchLine(let id):   return "改不了:库里没有 line_id = \(id) 这一行"
            case .gapLine(let id):      return "改不了:line_id = \(id) 是占位行(这段没录到),它没有原话可改"
            case .redactedLine(let id): return "改不了:line_id = \(id) 已经移出记忆,改它等于把移出记忆撤销"
            case .unchanged:            return "没改动:新文与原文一模一样"
            case .emptyText:            return "改不了:新文是空的 —— 清空一行要走「移出记忆」,不是修订"
            }
        }
    }

    /// 四张带 `quote` 的表(§4.2)。`ExtractValidate` 第②项校验要求 quote 是原话的
    /// **逐字子串**,所以原话一变它们就得跟着变 —— 同一个事务里,不许分两步。
    ///
    /// ⚠️ 与 `ExtractionStore.itemKinds` / `RecomputeCoverage` 里的那几份是同一组表名。
    /// 这里只需要表名(它们的 `quote` 列同名、`line_id` 列同名),不需要那两处的
    /// JSON 字段名与自由文本列名,所以没有把三处并成一份。**新增第五张带引文的表时
    /// 三处都要加** —— 少加这一处的后果是那张表的引文永远不跟着改。
    static let quoteTables = [
        "summary_key_points", "summary_commitments", "summary_stances", "summary_pendings",
    ]

    // MARK: - 改

    /// 把一行的正文改成 `newText`。
    ///
    /// - Parameters:
    ///   - actor: 谁改的。落进 `transcript_line_revisions.actor`。
    ///   - now: 本地时区 ISO 串,与全仓同口径(`ISO8601DateFormatter.growth`)。
    @discardableResult
    static func revise(lineID: Int64, to newText: String, actor: String, now: String,
                       in queue: DatabaseQueue) throws -> Result {
        try queue.write { db in
            // ① 读旧行。**先读后判,判完才动手** —— 触发器只挡形状,挡不出人话来。
            guard let row = try Row.fetchOne(db, sql: """
                SELECT transcript_id, seq, text, char_offset, is_gap, redacted
                  FROM transcript_lines WHERE line_id = ?
                """, arguments: [lineID]) else { throw Failure.noSuchLine(lineID) }

            let transcriptID: Int64 = row["transcript_id"]
            let seq: Int = row["seq"]
            let oldText: String = row["text"]
            let charOffset: Int = row["char_offset"]

            guard (row["is_gap"] as Int? ?? 0) == 0 else { throw Failure.gapLine(lineID) }
            guard (row["redacted"] as Int? ?? 0) == 0 else { throw Failure.redactedLine(lineID) }
            // 空文不是修订。清空一行的语义是「移出记忆」,那条路要立墓碑、要删音频、
            // 要二次确认 —— 从这里绕进去会得到一行看着还在、其实什么都没有的行。
            guard !newText.isEmpty else { throw Failure.emptyText }
            guard newText != oldText else { throw Failure.unchanged }

            // ② 先留痕,再改字。**顺序不能反** —— v18 的通道二要查的就是这条记录,
            //    反过来做的话 UPDATE 会被 ABORT(这正是「由 DB 强制」想要的效果)。
            try db.execute(sql: """
                INSERT INTO transcript_line_revisions (line_id, before, after, actor, at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [lineID, oldText, newText, actor, now])
            let revisionID = db.lastInsertedRowID

            // ③ 正文索引:先按**旧文**从 trigram 索引里删掉。
            //    external content 表的 'delete' 要拿被索引时的那份文本去销 token,
            //    所以必须用 oldText,而且必须在这一行还没被别处改动之前算清楚。
            //    v18 收紧了 `transcript_lines_fts_redact` —— 它现在只在
            //    `redacted` 由 0 变 1 那一刻触发,所以下面那条 UPDATE 不会再重复删一次。
            //    删两次会把 external content 索引写坏,而且是静默地坏。
            try db.execute(sql: """
                INSERT INTO transcript_lines_fts(transcript_lines_fts, rowid, text)
                VALUES ('delete', ?, ?)
                """, arguments: [lineID, oldText])
            // 词索引那条腿:它挂在 `transcript_line_tokens` 上,而那张表只有
            // INSERT / DELETE 两个 FTS 钩子(v10),没有 UPDATE 的 —— 所以是删了重插,
            // 不是就地改。就地改会让索引与内容表悄悄分叉。
            try db.execute(sql: "DELETE FROM transcript_line_tokens WHERE line_id = ?",
                           arguments: [lineID])

            // ④ 改字。`char_offset` 按契约一起写:**这一行自己的偏移不会变**
            //    (它等于前面所有行的字数和,而前面的行没动),写的是同一个值。
            //    列在这里是为了让「偏移是这条通道的一部分」在代码里看得见。
            try db.execute(sql: """
                UPDATE transcript_lines SET text = ?, char_offset = ? WHERE line_id = ?
                """, arguments: [newText, charOffset, lineID])

            // ⑤ 后续行整体推移(通道三)。字数没变就一条都不动 ——
            //    不是省事,是别让一次无谓的 UPDATE 去撞触发器。
            let shift = newText.count - oldText.count
            if shift != 0 {
                try db.execute(sql: """
                    UPDATE transcript_lines SET char_offset = char_offset + ?
                     WHERE transcript_id = ? AND seq > ?
                    """, arguments: [shift, transcriptID, seq])
            }

            // ⑥ 两张索引按新文补回来。
            try db.execute(sql: """
                INSERT INTO transcript_lines_fts(rowid, text) VALUES (?, ?)
                """, arguments: [lineID, newText])
            // 走 `WordIndex` 这个唯一入口,切词器与冻结时是同一份(`ChineseTokenizer`)。
            // 自己在这里拼一次 `indexable` 就是第二个切词现场,两处口径迟早分叉。
            try WordIndex.index(lineID: lineID, text: newText, isGap: false, in: db)

            // ⑦ 引文传播。
            let (oldFragment, newFragment) = changedFragment(from: oldText, to: newText)
            let (updated, stale) = try propagateQuotes(
                lineID: lineID, newText: newText,
                oldFragment: oldFragment, newFragment: newFragment, in: db)

            // ⑧ 记一笔。**`.foreground` 是写死的,而它是真的**:
            //    这条路只有用户在逐字稿里长按才走得到 —— 没有任何后台任务会改字,
            //    也没有任何自动链路调 `revise`。哪天有了,这个参数就得跟着变成入参
            //    (`TriggerTruthTests` 抓的正是「写死成 foreground 而后台也会走」那种半诚实)。
            //
            //    ⚠️ **只记改动的那一小段,不记整行。** 事件表是运维仪器,不是内容库;
            //    把整句原话抄进去等于又存了一份原文,而这一份**不受「移出记忆」管**
            //    (`MemoryRemoval` 只动 `transcript_lines`)。片段既够排查,又少一份副本。
            try ProcessingEvents.record(
                trigger: .foreground,
                outcome: "改错字:line \(lineID)",
                detail: "「\(oldFragment.isEmpty ? "(空)" : oldFragment)」→"
                      + "「\(newFragment.isEmpty ? "(空)" : newFragment)」"
                      + " · 后续行偏移 \(shift >= 0 ? "+" : "")\(shift)"
                      + " · 引文改了 \(updated) 条"
                      + (stale.isEmpty ? "" : " · ⚠️ \(stale.count) 条引文对不上了"),
                in: db)

            return Result(revisionID: revisionID, offsetShift: shift,
                          quotesUpdated: updated, staleQuotes: stale)
        }
    }

    // MARK: - 引文传播

    /// 只处理 **`line_id` 等于被改那一行**的引文。
    ///
    /// 🔴 **不做「全场替换」。** 别的行里也出现过「cloud」是很正常的事 ——
    /// 那些地方用户可能真的在说云。一次改字只该改一行,超出这一行的自作主张
    /// 会把「改一个错字」变成一次没人审过的批量改写。
    ///
    /// 三种去向,只有第三种算失败:
    /// · quote 含旧片段 ⇒ 替换,计入 `quotesUpdated`;
    /// · quote 不含旧片段(引的是这一行的别处)⇒ 不用改;
    /// · **改完仍然不是新原文的逐字子串 ⇒ 计进 `staleQuotes` 报出去。**
    ///
    /// ⚠️ 第三种的判定用的是 `TextNormalize.isVerbatim` —— 与 `ExtractValidate`
    /// 第②项校验**同一把尺子**。自己在这里写一遍 `contains` 的话,这里说没问题、
    /// 抽取校验说有问题,而两边都不会报错(铁律 4:同一件事只准有一个出处)。
    private static func propagateQuotes(lineID: Int64, newText: String,
                                        oldFragment: String, newFragment: String,
                                        in db: Database) throws -> (Int, [StaleQuote]) {
        var updated = 0
        var stale: [StaleQuote] = []

        for table in quoteTables {
            for row in try Row.fetchAll(db, sql: """
                SELECT id, quote FROM \(table) WHERE line_id = ?
                """, arguments: [lineID]) {
                let id: Int64 = row["id"]
                let quote: String = row["quote"]

                // 纯插入(旧片段为空)时不做替换:空串是任何串的子串,
                // 照着替换会把新片段插到每一个字符之间去。
                var rewritten = quote
                if !oldFragment.isEmpty, quote.contains(oldFragment) {
                    rewritten = quote.replacingOccurrences(of: oldFragment, with: newFragment)
                }

                // 🔴 **验过再写,不是写完再报。**
                //
                // 先写后验的话,改不成的那一条**已经落库了** —— 而它既不是原话、
                // 也不是新原文的子串,是**一句从未在任何地方存在过的话**。
                // 报出来和没写坏是两回事:报出来只是让人知道有一条坏的,
                // 而这条坏的已经进了内容库,`ExtractValidate` 之外没人再看它。
                //
                // 改不成时原样留着:旧引文至少还是**当时那一版的**逐字证据。
                guard TextNormalize.isVerbatim(quote: rewritten, source: newText) else {
                    stale.append(StaleQuote(table: table, id: id))
                    continue
                }
                // 替换与否都要验(上面那个 guard)。只按「含不含旧片段」分流的话,
                // 纯插入那一类会被判成「不用改」而其实已经断了(原文里插进一个字,
                // 跨过插入点的引文当场不再是子串)—— 那正是最会被漏掉的一种。
                if rewritten != quote {
                    try db.execute(sql: "UPDATE \(table) SET quote = ? WHERE id = ?",
                                   arguments: [rewritten, id])
                    updated += 1
                }
            }
        }
        return (updated, stale)
    }

    /// 新旧两串**真正不一样的那一小段**:掐掉公共前缀与公共后缀剩下的部分。
    ///
    /// 「我们用cloud写代码」→「我们用Claude写代码」得到 `("cloud", "Claude")`,
    /// 于是引文里替换的是那五个字母,而不是整行 —— 引文本来就只是原话的一截,
    /// 拿整行去替换根本对不上。
    ///
    /// 按 `Character`(字素簇)切,不按 `unicodeScalars`:这里切出来的东西要拿去
    /// 做文本替换,从组合符中间劈开会得到一个不成字的片段。
    /// (`TextNormalize` 按码点走是另一回事 —— 它要对齐 Python 的逐码点归一。)
    static func changedFragment(from old: String, to new: String) -> (String, String) {
        let o = Array(old), n = Array(new)
        var head = 0
        while head < o.count, head < n.count, o[head] == n[head] { head += 1 }
        var tail = 0
        while tail < o.count - head, tail < n.count - head,
              o[o.count - 1 - tail] == n[n.count - 1 - tail] { tail += 1 }
        return (String(o[head..<(o.count - tail)]), String(n[head..<(n.count - tail)]))
    }

    // MARK: - 读

    /// 这一场里改过的行 → 它的修订记录(按时间正序)。界面拿它画「改过」标记与原文。
    ///
    /// 按场次查而不是按 line_id 列表查:逐字稿一场可能上万行,
    /// 把上万个 id 拼进 `IN (…)` 既慢又会撞 SQLite 的变量上限。
    static func revisions(sessionID: Int64, in reader: some DatabaseReader) throws
        -> [Int64: [Revision]] {
        try reader.read { db in
            var out: [Int64: [Revision]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT r.id, r.line_id, r.before, r.after, r.actor, r.at
                  FROM transcript_line_revisions r
                  JOIN transcript_lines l ON l.line_id = r.line_id
                  JOIN transcripts      t ON t.id = l.transcript_id
                 WHERE t.session_id = ?
                 ORDER BY r.id
                """, arguments: [sessionID]) {
                let lineID: Int64 = row["line_id"]
                out[lineID, default: []].append(Revision(
                    id: row["id"], lineID: lineID, before: row["before"], after: row["after"],
                    actor: row["actor"], at: row["at"]))
            }
            return out
        }
    }
}

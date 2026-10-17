import Foundation
import GRDB

/// 转写全文检索(PRD §4.7.3 的「关键词检索」那一层)。
///
/// 要求:**跑在手机本地、<100ms、离线可用**。所以这里只有 SQLite,没有网络。
/// 语义检索与问答是另一层(走云),不在这个文件里。
///
/// ## 两条腿,谁也替代不了谁
///
/// | 腿 | 索引 | 覆盖 | 盲区 |
/// |---|---|---|---|
/// | **子串** | `transcript_lines_fts`(trigram) | 任意子串,含跨词的「付时间」 | **少于 3 个字匹配不到** |
/// | **词** | `transcript_line_tokens_fts`(切好词 + unicode61) | 「老周」这类短词;前缀「交付」→「交付时间」 | 词中间的子串 |
///
/// 只有 trigram 那一条腿时,搜「老周」「排期」返回**零结果**,而界面会照实显示「没找到」——
/// 那是**骗人**:那两个字满篇都是。当时只能显式报错「至少输三个字」,
/// 那是把问题说清楚,不是解决。迁移 v10 补上了词那条腿。
///
/// ### 一、用户输入不能直接进 MATCH
///
/// FTS5 的 MATCH 右边是一门**查询语言**:`AND` / `OR` / `NOT` / `NEAR` / `*` / `"` 都有语法含义。
/// 用户搜「产品 OR 定位」会被当成布尔查询,搜一个孤零零的 `"` 直接抛语法错。
/// 这里把整串**包成一个短语字面量**(引号转义),用户输什么就搜什么。
///
/// ### 二、只搜「界面看得见的那一版」
///
/// 重转写会产生新版本(v2),旧版本的行**仍然留在索引里**(§3.1.4:不覆盖、可回看)。
/// 不过滤的话,搜索会返回用户在界面上根本找不到的行。
///
/// ⚠️ 而且**不能按 `transcript_id = active_transcript_id` 过滤**:
/// 超长场次会切成多个 part(§3.1.6),每个 part 是独立的 `transcripts` 行,
/// 而 `TranscriptFreeze` 每冻结一个 part 就把 `active_transcript_id` 指过去——
/// **它最终只指向最后一个 part**。按它过滤会把前面所有 part 的内容搜没,
/// 而 3 小时以上的场次正是全时录音的常态。
/// 正确的口径是按 **(session_id, version)** 过滤,把该版本的所有 part 都算进来。
enum TranscriptSearch {

    /// trigram 那条腿的下限。**不再是整个检索的下限** —— 短词由词索引那条腿接住。
    static let trigramMinimumLength = 3

    enum Failure: Error, CustomStringConvertible {
        case emptyQuery

        var description: String {
            switch self {
            case .emptyQuery: return "没有输入要搜的词"
            }
        }
    }

    /// 一条命中。字段刚好够界面跳回原话(§4.2.5 的三项校验里,位置那一项打的就是 `lineID`)。
    struct Hit: Equatable {
        let lineID: Int64
        let sessionID: Int64
        /// 场次起点,本地时区 ISO。界面按字面截钟点,不要再过一次时区转换。
        let sessionStartedAt: String
        /// **场次内**绝对毫秒(§3.1.2 口径),不是 part 内相对值。
        let atMillis: Int
        /// 整行原文。三项校验的「文本逐字」打的是这个。
        let text: String
        /// 命中片段,命中处用 `⟦⟧` 包起来。界面自己决定怎么渲染。
        let snippet: String
        /// **同一场次里被折掉的、几乎一样的条数。** 0 = 没折。
        ///
        /// 折叠是丢信息,所以要说出来:界面照实写「还有 N 条几乎一样的」。
        /// 悄悄丢的后果是用户以为只有这一条,而「说了几遍」本身就是他想知道的。
        var foldedCount: Int = 0
    }

    /// → 按**时间倒序**的命中。
    ///
    /// 为什么不按相关度(bm25):这里是**字面**检索,每一条命中都完整包含用户输入的那串字,
    /// 相关度之间的差别几乎没有信息;而「最近一次是什么时候说的」恰恰是这个产品里最常见的问法。
    /// 相关度在语义检索那一层才有意义。
    static func search(_ raw: String, limit: Int = 50, in db: Database) throws -> [Hit] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyQuery }

        // 两条腿分别给一个「命中哪些行」的子查询,谁能用就上谁。
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []

        if let word = wordQuery(trimmed) {
            clauses.append("""
                l.line_id IN (SELECT rowid FROM transcript_line_tokens_fts
                              WHERE transcript_line_tokens_fts MATCH ?)
                """)
            args.append(word)
        }
        if trimmed.count >= trigramMinimumLength {
            clauses.append("""
                l.line_id IN (SELECT rowid FROM transcript_lines_fts
                              WHERE transcript_lines_fts MATCH ?)
                """)
            args.append(phraseLiteral(trimmed))
        }
        guard !clauses.isEmpty else { return [] }   // 只剩标点之类,切不出词也够不着 trigram

        // ⚠️ **多取一些再折。** 折叠发生在取回之后,若正好取 `limit` 行,
        // 一场里的 50 条几乎重复会折成 1 条 —— 而第 51 行开始那些**不重复的**
        // 命中根本没被取回来,用户看到的是「只有一条」,那是假的。
        // 多取 4 倍再折,基本够把重复吃掉还剩下 `limit` 条真结果。
        args.append(min(limit * overFetchFactor, maxRowsScanned))

        let rows = try Row.fetchAll(db, sql: """
            SELECT l.line_id, t.session_id, s.started_at, l.t_start_ms, l.text
            FROM transcript_lines l
            JOIN transcripts t      ON t.id = l.transcript_id
            JOIN sessions s         ON s.id = t.session_id
            JOIN transcripts act    ON act.id = s.active_transcript_id
            WHERE t.session_id = act.session_id
              AND t.version    = act.version
              AND l.redacted   = 0
              AND (\(clauses.joined(separator: " OR ")))
            ORDER BY s.started_at DESC, l.t_start_ms ASC
            LIMIT ?
            """, arguments: StatementArguments(args))

        let hits = rows.map { row -> Hit in
            let text: String = row["text"]
            return Hit(lineID: row["line_id"], sessionID: row["session_id"],
                       sessionStartedAt: row["started_at"], atMillis: row["t_start_ms"],
                       text: text, snippet: highlight(text, query: trimmed))
        }

        // 折几乎重复的。**只在同一场次内** —— 跨场次的重复是信号不是噪音
        // (「他第 3 次提到交付时间」正是产品要抓的东西),见 `NearDuplicate`。
        return NearDuplicate.fold(hits, key: \.sessionID, text: \.text)
            .prefix(limit)
            .map { var h = $0.item; h.foldedCount = $0.folded; return h }
    }

    /// 折叠前多取几倍。折叠会吃掉行,不多取就会「取回来的全被折没了」。
    static let overFetchFactor = 4
    /// 多取也有上限 —— 一次搜索不该把几万行拖进内存。
    /// 超出这个数说明重复得离谱,那时少给几条结果是对的。
    static let maxRowsScanned = 400

    /// 词索引那条腿的查询串:把查询也切一遍词,拼成短语,**末尾加 `*` 允许前缀命中**。
    ///
    /// 前缀那一下不是可选的:切词只能整词命中,而「交付」会被切成整体的「交付时间」——
    /// 没有前缀匹配,搜「交付」就找不到「交付时间」,那正是这条腿要解决的问题的变体。
    ///
    /// → nil 表示切不出任何词(纯标点/纯空白),这条腿不参与。
    static func wordQuery(_ s: String) -> String? {
        let tokens = ChineseTokenizer.tokens(s)
        guard !tokens.isEmpty else { return nil }
        return phraseLiteral(tokens.joined(separator: " ")) + "*"
    }

    /// 把用户输入包成 FTS5 的**短语字面量**:整串包一对双引号,内部的双引号翻倍。
    ///
    /// 这样 `AND` / `*` / `NEAR` 全都退化成普通字符,用户输什么就搜什么。
    /// 不做这一步,搜一个 `"` 会直接抛 SQL 语法错,而搜「产品 OR 定位」会悄悄
    /// 变成布尔查询 —— 后者更糟,它**不报错**,只是给出一批解释不了的结果。
    static func phraseLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 高亮在 Swift 侧算,不用 FTS5 的 `snippet()`。
    ///
    /// 两条腿命中的是两张不同的索引表,`snippet()` 只能对其中一张调用 ——
    /// 让高亮依赖「这次是哪条腿命中的」会让同一个查询在不同词长下给出不同形态的结果。
    /// 在原文里找一次子串,两条腿的结果就长得一样。
    static func highlight(_ text: String, query: String) -> String {
        guard let r = text.range(of: query) else { return text }
        return text.replacingCharacters(in: r, with: "⟦\(text[r])⟧")
    }
}

import Foundation
import GRDB

/// 词索引的**唯一写入口**(迁移 v10)。
///
/// ## 为什么要收成一个入口
///
/// 词索引不能由触发器填 —— 切词要调 `NLTokenizer`,SQL 里调不到。
/// 所以它只能由**写入方在插入转写行时顺手填**。
///
/// 而「靠调用方自觉」在本仓已经出过一次事:归属层没有统一入口,
/// 结果实测悬空 1979 条(铁律 3 就是为此立的)。这里是同一个形状的风险:
/// 少填一行不会报错、不会崩,只会让那一行**从此搜不到**,而且没人会发现。
///
/// 于是同样的对策:**一个入口** + **一条能机械检查的不变量**(`unindexedLineCount`)。
enum WordIndex {

    /// 给一行转写建词索引。
    ///
    /// - 占位行(`is_gap=1`)不建:让用户搜到一段根本不存在的内容,比搜不到更糟。
    /// - 已脱敏的行不建:v10 的触发器会在脱敏时删掉已有的那条。
    static func index(lineID: Int64, text: String, isGap: Bool, in db: Database) throws {
        guard !isGap else { return }
        try db.execute(sql: """
            INSERT INTO transcript_line_tokens (line_id, tokens) VALUES (?, ?)
            """, arguments: [lineID, ChineseTokenizer.indexable(text)])
    }

    /// 不变量:**每一条该被索引的转写行,都必须有词索引**。→ 违反的行数。
    ///
    /// 「该被索引」= 非占位、非脱敏。这个数只要不是 0,就说明有写入路径绕过了 `index(...)` ——
    /// 那些行搜不到,而且没有任何东西会报错。
    ///
    /// 测试里断言它恒为 0;将来接导入链路时,这条会第一时间把漏填喊出来。
    static func unindexedLineCount(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM transcript_lines l
            LEFT JOIN transcript_line_tokens t ON t.line_id = l.line_id
            WHERE l.is_gap = 0 AND l.redacted = 0 AND t.line_id IS NULL
            """) ?? 0
    }

    /// 整表重切。**切词器升级之后用它** —— 系统词库随 iOS 更新,
    /// 切法会变,而旧的切法留在库里就是旧的盲区。
    ///
    /// 之所以做得到,是因为词放在独立表:原文那张表冻结后不可改,
    /// 若把 tokens 加成它的一列,这个函数根本写不出来。
    @discardableResult
    static func rebuildAll(in db: Database) throws -> Int {
        try db.execute(sql: "DELETE FROM transcript_line_tokens")
        var n = 0
        let rows = try Row.fetchAll(db, sql: """
            SELECT line_id, text FROM transcript_lines WHERE is_gap = 0 AND redacted = 0
            """)
        for row in rows {
            try index(lineID: row["line_id"], text: row["text"], isGap: false, in: db)
            n += 1
        }
        return n
    }
}

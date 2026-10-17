import Foundation
import NaturalLanguage

/// 中文切词。**用系统自带的 `NLTokenizer`,不搬 jieba。**
///
/// ## 为什么需要它
///
/// 全文索引用的是 `trigram`——按三字一组建。它的代价是**查询串少于 3 个字就匹配不到**:
/// 搜「老周」「排期」返回零结果,而那些词满篇都是。
/// 在这之前只能显式报错「至少输三个字」,那是把问题说清楚,不是解决。
///
/// 切词补的就是这条腿:把「他说交付时间要重排」切成
/// `他 / 说 / 交付时间 / 要 / 重排`,按**词**再建一份索引,两个字的词就搜得到了。
///
/// ## 为什么不搬 jieba
///
/// 旧仓(`~/growth-agent`)用的是 jieba。搬过来要带词典、要维护停用词表,
/// 而词典过期就会切错——切错的后果是**搜不到**,而且不报错。
/// iOS 自带的 `NLTokenizer` 零依赖、随系统更新,效果够用。
///
/// ## 它不是万能的
///
/// 切词只能按**整词**命中。「交付」查不到被切成整体的「交付时间」——
/// 所以查询侧要允许**前缀匹配**(见 `TranscriptSearch`),
/// 而句子中间的任意子串(比如「付时间」)仍然只有 trigram 那条腿能覆盖。
/// **两条腿并用,谁也不能替代谁。**
enum ChineseTokenizer {

    /// → 词序列。空白与标点被丢弃,不进索引。
    ///
    /// 输出用于**索引**:落库时切一次存起来(`transcript_line_tokens.tokens`),
    /// 之后每次查询只切查询串,不重切正文。
    static func tokens(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let t = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            return true
        }
        return out
    }

    /// → 空格分隔的词串,直接存进索引列。
    ///
    /// 存成空格分隔是为了让 FTS5 的 `unicode61` 分词器能切开它——
    /// unicode61 **不切中文**(一整句会变成一个 token,这正是当初不用它的原因),
    /// 但它切空格。所以我们自己先切好、用空格连起来,再交给它。
    static func indexable(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }
}

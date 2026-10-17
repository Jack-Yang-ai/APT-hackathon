import Foundation

/// quote 逐字比对用的归一函数。**`shared/text_normalize.py` 的手机侧实现。**
///
/// 判 4 写死的规则:NFKC + 去全部标点空白 + 全半角/大小写归一,并且**要版本化** ——
/// 改规则就升版本号,历史校验结果不重新解释。
///
/// ## 这里为什么会有第二份实现
///
/// 抽取链路要在**手机上离线跑**(云代理的自我定义是「转发 + 记账,不做别的」,
/// 而判断的写方是手机 —— 铁律 1),判分尺子 `eval/extract_quality.py` 在 Mac 上跑。
/// 两个运行时,躲不掉两份实现。
///
/// 躲不掉就**钉住**:`eval/checks/golden/extract_golden.json` 由 Python 侧生成,
/// 两边测试共读同一个文件 —— 谁先漂谁先红。漂移本身不报错,它只是让
/// 「尺子量的」和「生产跑的」悄悄变成两回事,而那种失真在账面上看不出来。
///
/// ## 两个坑是实测出来的,不是推出来的
///
/// 1. **大小写必须用 `folding(.caseInsensitive)`,不能用 `lowercased()`。**
///    Python 的 `casefold()` 把 `ß` 展成 `ss`、把词尾 `ς` 归到 `σ`,`lowercased()` 都不会。
///    50 个刁钻例子实测:`folding` 全中,`lowercased()` 错 4 个。
/// 2. **必须按 `unicodeScalars` 遍历,不能按 `Character`。**
///    Python 逐**码点**判分类,Swift 的 `Character` 是字素簇 —— 一个带组合符的字
///    在两边会被当成不同的东西。
enum TextNormalize {

    /// 改规则就升这里。历史校验结果按写它时的版本解释,不重新解释。
    static let version = "v1"

    /// 要去掉的 Unicode 大类:标点 P、分隔符 Z(含各种空格)、控制符 C、符号 S。
    ///
    /// 去 S 是因为转写里常有 `~ + = °` 之类,模型改写时会顺手吞掉。
    /// 这一串是 Python 里 `unicodedata.category(ch)[0] in ("P","Z","C","S")`
    /// 那个首字母判断的展开 —— Swift 没有「大类首字母」,只能逐个列全。
    /// **漏一个就是一处静默的口径差**,所以金标向量里每一类都有例子。
    private static let dropped: Set<Unicode.GeneralCategory> = [
        // P
        .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
        .initialPunctuation, .finalPunctuation, .otherPunctuation,
        // Z
        .spaceSeparator, .lineSeparator, .paragraphSeparator,
        // C
        .control, .format, .surrogate, .privateUse, .unassigned,
        // S
        .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
    ]

    /// 归一到可比对的形态。空串进、空串出。
    static func normalize(_ s: String) -> String {
        let folded = s.precomposedStringWithCompatibilityMapping    // NFKC
            .folding(options: [.caseInsensitive], locale: nil)      // ≈ Python casefold()
        return String(String.UnicodeScalarView(
            folded.unicodeScalars.filter { !dropped.contains($0.properties.generalCategory) }))
    }

    /// quote 归一后是否为原文归一后的子串。
    ///
    /// ⚠️ **空 quote 一律判 false。**「没给引文」不该当成「逐字通过」——
    /// 空串是任何串的子串,不挡住的话所有漏写引文的条目都会静默过关。
    static func isVerbatim(quote: String, source: String) -> Bool {
        guard !quote.isEmpty else { return false }
        let q = normalize(quote)
        guard !q.isEmpty else { return false }
        return normalize(source).contains(q)
    }
}

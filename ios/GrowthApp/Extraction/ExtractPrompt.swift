import Foundation

/// 抽取的 prompt。**`worker/extract.py` 里 `EXTRACT_PROMPT` 的手机侧实现。**
///
/// ## 为什么 prompt 在手机上,不在云代理里
///
/// 它是**契约**(技术方案 §4.2 那份 JSON 的字段与硬要求),不是路由配置。
/// 契约已经有 Python(判分尺子那侧)与 Swift(生产那侧)两份实现要对齐,
/// 在云代理里再写一份就是没人测的第三份。云代理只管「用哪个模型」和「记账」。
///
/// ## 字符级对齐,靠测试钉住
///
/// `ExtractionGoldenTests` 拿 `eval/checks/fixtures/extract_prompt_v1.txt`
/// 逐字节比对 —— 那个文件由 Python 侧渲染生成。
/// **改一个标点两边就都得改**,这是刻意的:prompt 里每一条硬要求都对应
/// 校验里的一项,单边改 prompt 会让「模型被要求做的」和「校验在查的」错开,
/// 而那种错开只表现为通过率悄悄变化,不报错。
enum ExtractPrompt {

    /// 改 prompt 就升这里 —— 历史抽取结果按写它时的版本解释。
    static let version = "v1"

    /// §4.2:实测 8000 会被 thinking 吃光、返回空正文。**这是下限不是建议值**。
    ///
    /// ⚠️ 真正生效的值在云代理的 `SCENE_ROUTES` 里(手机不选模型也不定预算)。
    /// 这里留着是给读代码的人一个交代:20000 这个数从哪来。
    static let maxTokens = 20000

    /// 把转写行渲染进 prompt。行号在最前,模型才好照抄。
    static func render(lines: [ExtractValidate.Line]) -> String {
        let body = lines
            .map { "\($0.lineID) | \($0.clusterTag ?? "未分人") | \($0.text)" }
            .joined(separator: "\n")
        return template.replacingOccurrences(of: "{transcript}", with: body)
    }

    static func renderWithActions(lines: [ExtractValidate.Line]) -> String {
        render(lines: lines) + ActionExtraction.prompt
    }
}

extension Array {
    /// 切成每块最多 `size` 个。M1-27 分块抽取用。
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension ExtractPrompt {
    /// 把多块各自的「一句话」合成整场的一句(M1-27)。
    ///
    /// ⚠️ **这是一次额外的付费调用**,但很小(约 200 进 / 50 出),而且**只在分了块时才发生**。
    /// 不这么做的两条路都错:取最后一块的 = 断言「结论总在最后」;拼起来 = 不是人话。
    static func mergeOneLiners(_ parts: [String]) -> String {
        """
        下面是同一场录音分段各自的一句话结论,按时间先后排列。
        把它们合成**整场的一句话**,不超过 40 字。只输出那一句,不要解释、不要引号。

        \(parts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        """
    }
}

// ⚠️ 下面这段**顶格写**是必须的,不是排版没做。
// Swift 的多行字面量按结束定界符的缩进裁剪每一行,而这段 prompt 里
// `  "one_liner"` 这类前导空格是内容的一部分 —— 缩进一进来就要在每行手工补偿,
// 补错了就是一处字节差,而字节差只会表现为「金标测试红了」,查起来很费。
private let template = """
你在读一场录音的逐句转写,每一行都带行号。请抽出这一场的纪要。

只输出一个 JSON 对象,不要解释、不要代码围栏。结构:

{
  "one_liner": "整场结论,不超过 40 字",
  "key_points":  [{"point": "...", "quote": "...", "line_id": 0, "speaker_hint": "说话人2"}],
  "commitments": [{"what": "...", "quote": "...", "line_id": 0, "to_whom_text": "老王", "speaker_hint": "说话人1"}],
  "stances":     [{"stance": "...", "quote": "...", "line_id": 0, "speaker_hint": "说话人3",
                    "premise": null, "premise_line_id": null}],
  "pendings":    [{"issue": "...", "quote": "...", "line_id": 0, "parties_text": ["老王"]}],
  "topic_keys":  [{"key": "...", "line_ids": [0]}]
}

硬要求:

1. **每一条都必须带 line_id**,指向它的依据行。给不出行号的条目直接不要写。
2. **quote 必须是那一行的原文片段,逐字照抄**,不许改写、不许拼接多行。
   自由文本字段(point / what / stance / issue)可以压缩改写,quote 不行——
   前者给人看,后者要拿去和原文比对。
3. **不要写「谁说的」**。没有这个字段,也不要用别的名字塞进来。
   `speaker_hint` 只填你在转写里看到的簇标签原文(如「说话人2」),
   它只用来交叉核对,不会被存下来。
4. `premise` 只在原话里真的说了前提时才填,并给出 `premise_line_id`。
   **没说就填 null,不要替他补一个听起来合理的**。
5. `to_whom_text` / `parties_text` 填原话里出现的称呼字符串,不要猜真名。
6. 一条内容都抽不到时,对应数组给空数组,不要编。

转写(格式:行号 | 簇标签 | 原话):

{transcript}

"""

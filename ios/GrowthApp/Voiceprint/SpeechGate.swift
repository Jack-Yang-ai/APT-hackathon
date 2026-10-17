import Foundation

/// 取段这一步的人声门(S3 定阈推翻方案的第三处)。
///
/// ## 它挡的是哪一类,不挡哪一类
///
/// 🔴 **挡「根本不是人声」,不挡「别人的人声」。** 这条界线必须写清楚,
/// 否则下一个人会以为加了这道门就不会认错人了。
///
/// · **挡得住**:ASR 把空调声、关门声、椅子响聚成了一个「说话人」。
///   实测形态是这样的段**对谁的相似度都低**(0.12–0.19),
///   但它们照样进投票、照样消耗「至少 2 段」的名额,
///   把本来能判的簇拖成拒识。
/// · **挡不住**:电视里另一个人在说话。那是真人声,VAD 会说「是」——
///   它由阈值 + 投票负责(`SpeakerMatch`),不由这道门负责。
///
/// ## 判据:段内语音帧占比
///
/// 不用「平均概率」:一段里有 1 秒真人声、3 秒静音,平均值会被静音拉低到
/// 与全程噪声难以区分;而占比直接回答「这几秒里有多少是在说话」。
///
/// ⚠️ **`minSpeechRatio` 是起点值,不是实测出来的**(同 `SpeakerMatch.minVoteRatio`)。
/// 取 0.6 的依据只是「取的是一句话的中段,理应大半在说话」。
/// 真机跑过之后拿分布回填 —— **在那之前别把它当成量出来的数**。
enum SpeechGate {

    /// 段内至少这么多帧要被判成人声。
    static let minSpeechRatio: Double = 0.6

    /// - Parameter frameProbabilities: `SileroVAD.probability(frame:)` 逐帧的结果。
    /// - Returns: 语音帧占比。**帧数为 0 时返回 0**(不是 1)——
    ///   「什么都没量到」不能算通过,那正好是解码失败的形态。
    static func speechRatio(_ frameProbabilities: [Float]) -> Double {
        guard !frameProbabilities.isEmpty else { return 0 }
        let speech = frameProbabilities.filter { $0 >= SileroVAD.speechThreshold }.count
        return Double(speech) / Double(frameProbabilities.count)
    }

    static func passes(_ frameProbabilities: [Float]) -> Bool {
        speechRatio(frameProbabilities) >= minSpeechRatio
    }
}

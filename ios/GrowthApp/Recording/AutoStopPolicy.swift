import Foundation

/// 忘了按结束时,自己收尾(PRD §4.1.10 录音组第一项)。
///
/// ## 为什么需要它
///
/// 全时录音的产品,「忘了关」是常态不是意外 —— 一晚上就是几小时音频,
/// 而音频只进不出(M1-16a)。更糟的是它会被当成**一场**送去转写:
/// 转写按块收费,一夜八小时是 96 块。
///
/// ## 判据:连续静音,不是「录了多久」
///
/// 按总时长收尾会把一场真的三小时会议劈断 —— 那是**不可逆**的损失,
/// 而多录几小时只是费空间。两种错法的代价差着量级,所以判据只看静音。
///
/// 「连续」由 `EnergyGate` 保证:任何一帧高过底噪就把计时清零。
/// 所以会议中间的沉默、有人咳嗽一声,都不会触发。
///
/// ## 阈值
///
/// PRD §4.1.5 原文:「连续静音超过 **2 小时 (初)** 自动收尾,防止忘记关」。
/// 带「(初)」= 暂定值,拿真实使用数据回填(同 `EnergyGate.speechMarginDB`)。
enum AutoStopPolicy {

    /// 连续静音多久自动收尾。
    static let silenceMs: Int = 2 * 60 * 60 * 1000

    /// - Parameter silentForMs: `SilenceProbe.silentForMs` —— nil = 此刻有声,
    ///   或者这个探针答不上来。**两种都不收尾**:答不上来时宁可多录
    ///   (费空间),也不要把一场真会议劈成两半(不可逆)。
    static func shouldStop(silentForMs: Int?, threshold: Int = silenceMs) -> Bool {
        guard let silentForMs else { return false }
        return silentForMs >= threshold
    }
}

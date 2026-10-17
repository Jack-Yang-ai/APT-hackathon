import Foundation

// 分段切点策略(§3.1.6「切点对齐静音」)。
//
// 为什么是「前瞻」而不是「回溯」:落盘是流式的,写进 AAC 文件的字节收不回来,
// 所以做不到「录满 5 分钟后回头找最近的静音处再切」。可行的形态只有一种 ——
// 进入窗口后每拍问一次「此刻静音吗」,第一个静音点就切;走到窗口右端还没等到,
// 就硬切并把 `hard_cut=true` 写进块元数据。

/// 「此刻是不是静音」。端侧 VAD 接进来之前没有真实现(U6b,本任务禁区)。
protocol SilenceProbe {
    func isSilentNow() -> Bool

    /// 已经连续静音多久(毫秒)。`nil` = 此刻不是静音,或者这个探针答不上来。
    ///
    /// ⚠️ **默认实现返回 nil**,所以不认得这个问题的探针(`NeverSilent`、
    /// 各种测试桩)只会让自动结束**永不触发** —— 那是安全的一边:
    /// 录多了顶多费空间,提前收尾会把一场真会议劈成两半。
    var silentForMs: Int? { get }
}

extension SilenceProbe {
    var silentForMs: Int? { nil }
}

/// U6b 之前的实现:永远回答「不是静音」。
///
/// 这**不是**静默降级。它的后果是每块都走到窗口右端硬切,于是每块的元数据里
/// 都带着 `hard_cut=true` —— 「切点没对齐静音」这件事一直摆在数据里,
/// 谁读块都看得见。真正危险的写法是返回一个假的静音点,那样切点是错的而元数据说它是对的。
struct NeverSilent: SilenceProbe {
    func isSilentNow() -> Bool { false }
}

enum BlockCutPolicy {

    /// 目标块长 5 分钟(§六 录音格式)。
    static let targetMs = 5 * 60 * 1000

    /// 「5 分钟附近」的容差。§3.1.6 只写了「附近」没给数,这里取 ±30 秒:
    /// 窗口太窄等于永远硬切,太宽会让块长方差大到影响「最多丢一段」的口径。
    /// ⚠️ 这个数在 U6b 拿到端侧 VAD 的真实静音分布之前是**暂定值**,届时按分布回填。
    static let windowMs = 30 * 1000

    static var earliestMs: Int { targetMs - windowMs }
    static var latestMs: Int { targetMs + windowMs }

    struct Cut: Equatable {
        /// 切点没落在静音处。进块元数据,下游据此知道这里可能有截断句。
        let hardCut: Bool
    }

    /// 每一拍调一次。`nil` = 继续录,非 nil = 现在切。
    ///
    /// 三段:窗口左端之前一律不切(块太短会把送检次数抬上去);窗口内遇静音就切;
    /// 走到右端无论如何都切(块无限长会让「断电最多丢一段」失效)。
    static func shouldCut(elapsedMs: Int, probe: SilenceProbe) -> Cut? {
        // 先问静音再看死线:恰好在右端那一拍上遇到静音时,这个切点**确实**对齐了静音,
        // 标成 hard_cut 是在如实的数据里掺假话。
        if elapsedMs >= earliestMs, probe.isSilentNow() { return Cut(hardCut: false) }
        if elapsedMs >= latestMs { return Cut(hardCut: true) }
        return nil
    }
}

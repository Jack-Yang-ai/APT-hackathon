import Accelerate
import Foundation

/// 靠音量判断「此刻是不是静音」。
///
/// ## 它解决的是切点,不是「有没有人声」
///
/// ⚠️ **这不是 P4 选型选出来的那个 VAD。** 那次选的是 Silero(ONNX 1.2 MB),
/// 用途是**上传前裁掉非人声**——那一刀直接决定转写花多少钱(实测省约 39%),
/// 裁错了就是把人说的话扔掉,所以必须用真 VAD。
///
/// 这里要回答的是另一个问题:**5 分钟块的切点,落在哪一秒**。
/// 判错的代价小得多——判成静音而其实有人在说,后果是这一块的接缝处可能有半句话
/// (与现在 `NeverSilent` 下**每一块都如此**相比,只会更好);
/// 判成有声而其实是静音,后果是错过一个切点,下一拍再问。
///
/// 所以这里用零依赖的音量门,把 Silero 留给上传那一刀。**两件事,两个器件。**
///
/// ## 为什么不是一个固定阈值
///
/// 安静的会议室与开着空调的办公室,底噪能差 20 dB。固定阈值要么在安静环境下
/// 永远「有声」(等于退回 `NeverSilent`),要么在嘈杂环境下把说话也判成静音。
///
/// 所以跟踪一条**底噪线**:用长期最小值缓慢爬升的方式估当前环境的地板,
/// 「比地板高出 `speechMarginDB`」才算有人在说。地板只在静音期更新——
/// 用说话期的能量去更新地板,地板会被自己的声音顶上去,越说越判不出静音。
final class EnergyGate: SilenceProbe {

    /// 高出底噪多少 dB 算「有人在说」。
    ///
    /// ⚠️ **暂定值。** 真机上拿到静音分布之后按分布回填(与 `BlockCutPolicy.windowMs`
    /// 同一批)。取 12 dB 是因为正常说话比室内底噪高 15–25 dB,留 3 dB 余量;
    /// 太小会把空调声当人声(退回每块硬切),太大会在低声说话时误判静音。
    static let speechMarginDB: Float = 12

    /// 连续静音多久才算「静音」。
    ///
    /// 不加这一条的话,句子之间的换气(200–400ms)会被当成切点——
    /// 那正好把一句话从中间劈开,与硬切没有区别。**0.8 秒是句间停顿的量级。**
    static let sustainedSilenceMs: Int = 800

    /// 底噪估计的爬升速度。**升得慢、降得快**:
    /// 环境突然变吵(有人开了空调)要慢慢跟上,免得把一句话的开头吃掉;
    /// 环境突然变安静要立刻跟上,否则地板卡在高位,之后全判成静音。
    private static let floorRiseRate: Float = 0.02
    private static let floorFallRate: Float = 0.5

    private let lock = NSLock()
    private var noiseFloorDB: Float = -60
    private var silentSinceMs: Int?
    /// 单调时钟的毫秒数。用墙钟会在校时时跳变。
    private var nowMs: Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    /// 每收到一个音频缓冲区调一次。**跑在音频线程上,只做加减法。**
    func feed(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        let db = 20 * log10(max(rms, 1e-7))

        lock.lock(); defer { lock.unlock() }

        let isLoud = db > noiseFloorDB + Self.speechMarginDB
        if isLoud {
            silentSinceMs = nil
        } else {
            // 只在静音期更新地板 —— 用说话期的能量更新会把地板顶上去,越说越判不出静音
            let rate = db < noiseFloorDB ? Self.floorFallRate : Self.floorRiseRate
            noiseFloorDB += (db - noiseFloorDB) * rate
            if silentSinceMs == nil { silentSinceMs = nowMs }
        }
    }

    /// 已经连续静音多久了(毫秒)。`nil` = 此刻不是静音。
    ///
    /// 与 `isSilentNow()` 共用同一个 `silentSinceMs`,**不另起一套计时** ——
    /// 两套计时器迟早对不上,而对不上的表现是「切块说有声、自动结束说静音」。
    var silentForMs: Int? {
        lock.lock(); defer { lock.unlock() }
        return silentSinceMs.map { nowMs - $0 }
    }

    /// 连续静音够久了吗。
    func isSilentNow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let since = silentSinceMs else { return false }
        return nowMs - since >= Self.sustainedSilenceMs
    }

    /// 状态条上那句「有人在说话」。与 `isSilentNow()` **不是互为反面**:
    /// 静音要连续够久才算,而「有人在说」是此刻的判断 —— 换气的那半秒
    /// 不该让界面闪一下「没人说话」。
    var hasSpeechNow: Bool {
        lock.lock(); defer { lock.unlock() }
        return silentSinceMs == nil
    }

    /// 测试用:把内部状态摆到一个确定的位置。生产路径不调。
    func _resetForTesting(noiseFloorDB: Float) {
        lock.lock(); defer { lock.unlock() }
        self.noiseFloorDB = noiseFloorDB
        silentSinceMs = nil
    }
}

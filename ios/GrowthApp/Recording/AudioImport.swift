import Foundation
import AVFoundation

/// 导入已有音视频(PRD §4.1.5)。
///
/// ## 为什么导入也要粗切
///
/// **[拍板 2026-08-12,推翻原「跳过粗切,整体作为一个场次」]**:
/// 分说话人必须以**一整场对话**为单位才成立(同一场里谁是谁要一起判)。
/// 把两场硬粘成一场,归属就判不准 —— 这与录音走粗切是同一个理由,
/// **没有理由对导入网开一面**。
///
/// ## 静音判据用 Silero,不用 `BlockCutPolicy`
///
/// `BlockCutPolicy.isSilentNow` 到 U6b 之前是个桩(「永远回答不是静音」)——
/// 拿它做粗切,结果是整个文件永远切不开,而且不报错。
/// 而 Silero 已经接进来了,离线跑文件正是它擅长的:一帧 32ms,一小时音频约 11 万帧。
///
/// ⚠️ 这里**不复用 `EnergyGate`**:它按 `DispatchTime.now()` 计时,是给实时流用的,
/// 喂离线文件会把「几分钟音频」算成「几毫秒」。
enum AudioImport {

    /// 一场的边界。
    ///
    /// ⚠️ **样本序号在 16kHz 重采样域上,不是源文件的采样率。**
    /// `decode` 统一把任何输入重采样成 16k 单声道(VAD 与嵌入器都要这个域),
    /// 所以一个 44.1kHz 的 mp3 进来,这里的 `startSample` 是**重采样之后**的位置。
    /// 拿它去源文件上定位会差 2.75 倍 —— 而那不会报错,只会切在错的地方。
    /// 换算成秒一律用 `AudioImport.sampleRate`(下面两个计算属性就是),
    /// 别在调用方自己写一个采样率。
    struct Segment: Equatable {
        let startSample: Int
        let endSample: Int
        var startSeconds: Double { Double(startSample) / Double(sampleRate) }
        var endSeconds: Double { Double(endSample) / Double(sampleRate) }
        var durationSeconds: Double { endSeconds - startSeconds }
    }

    static let sampleRate = 16_000

    /// 切一场的静音门槛。PRD §4.1.5 原文:「按 **≥5 分钟**长静音切」。
    static let sessionGapSeconds: Double = 300

    /// 一段连续语音要多长才算「真的有人在说话」。
    ///
    /// ⚠️ **这不是场次时长下限。** 它挡的是咳嗽、关门、椅子响这类孤立高帧 ——
    /// 挡不住的话,5 分钟静音里随便一声杂音就把静音计数清零,整个文件切不开。
    /// 0.5 秒是暂定值,**要拿真实录音的噪声分布回填**(同 `BlockCutPolicy` 那个 ±30 秒)。
    static let minSpeechSeconds: Double = 0.5

    /// 进度回调的最小步长。见 `segments` 里那段注释 —— 0.5% 一档,
    /// 5 小时的文件最多回 200 次。
    static let progressStep: Double = 0.005

    enum Failure: Error, CustomStringConvertible {
        case noAudioTrack
        case unreadable(String)
        case tooLong(hours: Double)

        var description: String {
            switch self {
            case .noAudioTrack:      return "这个文件里没有声音"
            case .unreadable(let m): return "这个文件读不出来:\(m)"
            case .tooLong(let h):
                return String(format: "单个文件最长 5 小时,这个有 %.1f 小时", h)
            }
        }
    }

    /// 单文件上限。PRD §4.1.5:「单文件 ≤5 小时」。
    static let maxHours: Double = 5

    // MARK: - 解码

    /// 把任意音视频解成 16kHz 单声道 Float。视频**只取音轨**(PRD §4.1.5)。
    ///
    /// 逐块回调而不是一次性返回:5 小时 16kHz Float 是 1.1 GB,
    /// 整个读进内存在手机上会被系统直接杀掉。
    static func decode(url: URL, onChunk: ([Float]) throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudioTrack
        }
        // ⚠️ `CMTime.seconds` 在 duration 为 indefinite 时是 **NaN**,而 `nan > 5` 是
        // **false** —— 上一版的上限判断会被直接绕过,PRD 写死的 ≤5 小时形同虚设。
        // 触发的是没下载完的 iCloud 流式文件、被截断的录音。
        // 所以 metadata 只当**参考**,真正的上限由解码出的样本数兜底(见下面 `guard`)。
        let duration = try await asset.load(.duration).seconds
        if duration.isFinite, duration / 3600 > maxHours {
            throw Failure.tooLong(hours: duration / 3600)
        }
        let maxSamples = Int(maxHours * 3600 * Double(sampleRate))
        var decoded = 0

        var dropped = 0
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw Failure.unreadable(String(describing: error)) }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        // 中途抛错时不收摊,reader 会一直停在 reading 直到 dealloc。
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard reader.startReading() else {
            throw Failure.unreadable(String(describing: reader.error))
        }

        while let buf = output.copyNextSampleBuffer() {
            // 用户按了取消:**当场停下**。5 小时的文件要跑十几万帧,
            // 没有取消入口的话,退出这一屏之后它还在后台烧电。
            try Task.checkCancellation()

            // ⚠️ **每块一个自动释放池。** `copyNextSampleBuffer` 与 `CMBlockBuffer`
            // 是 CoreMedia 的 CF 对象,在 async 函数里没有随每次循环收摊的池 ——
            // 5 小时的文件是几万次迭代,池要到函数返回才排空 ⇒ **峰值内存按整个
            // 文件涨**,而这一步的全部设计(逐块回调、不一次性读进内存)
            // 就是为了不让它涨。表现不是崩溃,是被系统直接杀掉,
            // 而用户只看到「导入到一半没了」。
            //
            // 池里**只做取样本**,`onChunk` 放到池外调 —— 调用方可能持有这块数据
            // (`VoiceprintChain` 就在累加),在池里调等于把它的生命周期
            // 也绑在这个池上。
            let samples: [Float]? = try autoreleasepool {
                defer { CMSampleBufferInvalidate(buf) }
                guard let block = CMSampleBufferGetDataBuffer(buf) else { return nil }
                // ⚠️ **不能拿 `totalLength` 当可读长度直接读指针。**
                // CMBlockBuffer 可以是多块链式内存,`dataPointerOut` 只保证
                // `lengthAtOffset` 字节内连续 —— 按 totalLength 读就是越界。
                // 而越界读到的堆垃圾会被当成 Float 音频喂进 VAD:概率乱掉、切分错,
                // 退出码全绿、一条日志都没有。所以这里**拷贝**,不玩指针。
                let length = CMBlockBufferGetDataLength(block)
                guard length >= 4 else { return length > 0 ? nil : [] }
                let count = length / 4
                var out = [Float](repeating: 0, count: count)
                let status = out.withUnsafeMutableBytes { raw -> OSStatus in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4,
                                               destination: raw.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else {
                    // 拷不出来要抛,不能静默跳过 —— 跳过的表现是「时间轴整体提前」,
                    // 而它一路传到 M1-4 切音频时才会显出来,那时已经查不回来了。
                    throw Failure.unreadable("CMBlockBufferCopyDataBytes 失败:\(status)")
                }
                return out
            }
            // nil = 这一块读不出来(没有 data buffer,或长度不足一个 Float)。
            // 空数组 = 长度为 0 的正常空块,不算丢。
            guard let samples else { dropped += 1; continue }
            guard !samples.isEmpty else { continue }

            decoded += samples.count
            // metadata 说不清楚时,这一道才是真的上限。
            guard decoded <= maxSamples else {
                throw Failure.tooLong(hours: Double(decoded) / Double(sampleRate) / 3600)
            }
            try onChunk(samples)
        }
        if reader.status == .failed {
            throw Failure.unreadable(String(describing: reader.error))
        }
        // 丢过采样就**说出来**。时间轴是按累计样本数推的,丢一次其后全部提前。
        if dropped > 0 {
            throw Failure.unreadable("有 \(dropped) 个音频块读不出来,时间轴会整体错位")
        }
    }

    // MARK: - 粗切

    /// 逐帧喂 Silero,按「连续非语音 ≥5 分钟」切场。
    ///
    /// - Parameter frames: 语音概率序列,一帧 512 个采样(32ms)。
    ///
    /// 纯函数,不碰文件也不碰模型 —— 切分规则要能单独测,
    /// 而把它埋进解码循环里就只能靠跑真文件来验。
    static func split(speechProbabilities frames: [Float],
                      threshold: Float = SileroVAD.speechThreshold,
                      gapSeconds: Double = sessionGapSeconds,
                      minSpeechSeconds: Double = minSpeechSeconds) -> [Segment] {
        let frameSamples = SileroVAD.frameSamples
        let perFrame = Double(frameSamples) / Double(sampleRate)
        let gapFrames = Int(gapSeconds / perFrame)
        let runFrames = max(1, Int(minSpeechSeconds / perFrame))

        var segments: [Segment] = []
        var speechStart: Int?          // 帧号
        var lastSpeech: Int?
        var silence = 0
        var speechRun = 0

        for (i, p) in frames.enumerated() {
            if p >= threshold {
                speechRun += 1
                // ⚠️ **孤立的高帧既不算说话,也不打断静音计数。**
                // 第一版是「任何一帧过阈就 silence = 0」,于是 5 分钟静音要求
                // 9375 帧一帧不过阈 —— 会议中场休息里一声咳嗽就够了,
                // 结果是三小时的文件粘成一场,而界面上只是「这一场有点长」。
                if speechRun >= runFrames {
                    if speechStart == nil { speechStart = i - speechRun + 1 }
                    lastSpeech = i
                    silence = 0
                }
            } else {
                speechRun = 0
                silence += 1
                // 攒够 5 分钟静音就收一场。收的是**最后一次说话**的位置,
                // 不是当前帧 —— 把这 5 分钟静音也算进场次时长是错的。
                if silence >= gapFrames, let s = speechStart, let e = lastSpeech {
                    segments.append(Segment(startSample: s * frameSamples,
                                            endSample: (e + 1) * frameSamples))
                    speechStart = nil
                    lastSpeech = nil
                }
            }
        }
        if let s = speechStart, let e = lastSpeech {
            segments.append(Segment(startSample: s * frameSamples,
                                    endSample: (e + 1) * frameSamples))
        }

        // ⚠️ **短片段不许在这里丢掉。**
        //
        // 第一版按「短于 30 秒就不成场」过滤,那是越权替**分级**做决定 ——
        // PRD §4.1.6 的分级发生在**转写之后**,而且「只转写」档的定义就是
        // 「短对话、寒暄、事务性对话 → 存转写,可搜索,首页折叠进零碎」;
        // 「丢弃」档的判据是**无人声**,不是短。技术方案 §5「时长 <2 分钟 → 只转写」同理。
        //
        // 实际后果:转发一条 25 秒的微信语音(PRD §4.1.5 第一句点名的场景)
        // 会得到 0 场 + 一句「整个文件里没有听到人说话」—— 而文件里全是人说话。
        // 分级的保守原则还写着「拿不准时往高了走」,过滤掉正好是反的。
        return segments
    }

    /// 整条:解码 → 逐帧 VAD → 切场。
    ///
    /// - Parameter onProgress: 0…1。5 小时的文件要跑十几万帧,没有进度条用户会以为卡死了。
    static func segments(of url: URL,
                         vad: SileroVAD,
                         onProgress: ((Double) -> Void)? = nil) async throws -> [Segment] {
        var probabilities: [Float] = []
        var carry: [Float] = []
        // 上一次报出去的进度。**初值 -2** 才能让第一次(不论是 0 还是 -1)都报出去。
        var lastReported: Double = -2
        // -1 = 「总长不知道,只能报已经跑了多久」。界面据此显示不确定进度。
        let total = try await AVURLAsset(url: url).load(.duration).seconds
        vad.reset()

        try await decode(url: url) { chunk in
            carry += chunk
            while carry.count >= SileroVAD.frameSamples {
                let frame = Array(carry.prefix(SileroVAD.frameSamples))
                carry.removeFirst(SileroVAD.frameSamples)
                probabilities.append(try vad.probability(frame: frame))
            }
            // total 不可信(NaN / 0)时**不装进度**:上一版这里是 `if total > 0`,
            // NaN 走不进去,于是进度条整个过程钉在 0%,和「卡死」在界面上没有区别。
            // 现在改成按已解码时长报,由界面决定怎么显示「不知道总长」。
            let done = Double(probabilities.count * SileroVAD.frameSamples) / Double(sampleRate)
            let p = total.isFinite && total > 0 ? min(1, done / total) : -1
            // 🔴 **节流:每块回一次太密。**
            // 一块是几十毫秒音频,5 小时的文件是**几万次回调** —— 而调用方
            // (`ImportView`)每次都要跳一趟主线程去改 `@State`。
            // 那不只是浪费:主线程被这些 hop 塞满时,进度条自己都会卡住,
            // 表现成「导入卡死了」,而解码其实跑得好好的。
            //
            // 0.5% 一档:5 小时的文件最多回 200 次,而 200 格在任何屏幕上
            // 都比人眼分得清的还细。`-1`(总长不可信)只在第一次回,
            // 界面据它切成不确定进度条,反复回没有意义。
            if p < 0 ? lastReported >= 0 : (p - lastReported >= progressStep) {
                lastReported = p
                onProgress?(p)
            }
        }
        // 结尾**无条件报 1**:节流可能把最后一档吃掉,而进度条停在 99%
        // 与「卡死了」在屏上是同一个样子。
        onProgress?(1)
        return split(speechProbabilities: probabilities)
    }
}

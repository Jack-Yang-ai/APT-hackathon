import Accelerate
import Foundation

/// ReDimNet 的**梅尔前端**:声波 → 网络能读的那张「时间 × 音高」的图。
///
/// ✅ **2026-08-17:这些常数照 M 抄的,已实测对 S 同样成立** —— 换 S 之后必须核的那一项已核完。
/// 判据不是「参数表看着一样」,而是两条独立的实测(`docs/evidence/p4b-u6b-u5b/export_embedder.json`):
///   ① 同一段波形分别喂 S 与 M 的前端,**最大逐点差 0.000e+00**
///   ② 用 S 重新生成 `mel_golden.json`,与 M 那版**逐字节相同**(sha256 一致)
///
/// ⚠️ 为什么当初不能靠「S 与 M 同家族,前端很可能一样」:窗是 Hamming 不是 Hann、
/// `mel_scale` 是 htk 不是 slaney、CMN 沿时间轴不是频率轴 —— 这三个任意一个错了
/// 都**不会报任何错**,只让嵌入悄悄变质,而变质的表现是「声纹时准时不准」,查起来极贵。
/// 同理,**下次换模型时这一项要重核**:比参数字典是不够的(字典只覆盖抄下来的那几项),
/// 要拿波形逐点比 —— `export_embedder.py` 就是干这件事的,改一个字母重跑即可。
///
/// ## 为什么这一半要手写
///
/// `torch.onnx.export` 整模型导不出来 —— 卡在 STFT(那里要用复数,ONNX 不支持)。
/// 所以按模型自己 `forward` 的天然接缝切成两半:
///
///     声波 ──[本文件:五步 DSP]──▶ (72, T) 梅尔谱 ──[ONNX 网络本体]──▶ 192 维声纹
///
/// 切分几乎不花代价(前端只占总耗时的 0.2%),贵的是**必须一位不差**:
/// 五步、十来个常数,**任何一个写错都不会报错**,只会让声纹悄悄变质。
/// 所以唯一的验收方式是拿 PyTorch 的输出逐位对 —— 见 `MelFrontendTests`,
/// 金标在 `Fixtures/mel_golden.json`(由 `docs/evidence/p4b-u6b-u5b/make_frontend_golden.py` 生成)。
///
/// ## 三个最容易写错、而且写错不报错的地方
///
/// 1. 窗是 **Hamming**,不是 Hann(差一个 0.08 的基座)
/// 2. 梅尔刻度是 **htk**,不是 slaney —— 两套都叫「梅尔」的不同公式
/// 3. 最后减均值沿**时间轴**,不是频率轴
enum MelFrontend {

    // MARK: - 常数(抄自 `MelBanks`;S 与 M 实测同一份前端,改任何一个金标都会红)

    static let sampleRate = 16000
    static let nFFT = 512
    static let hopLength = 160
    static let winLength = 400
    static let nMels = 72
    static let fMin: Float = 20
    static let fMax: Float = 7600
    /// 预加重系数:`y[n] = x[n] − 0.97·x[n−1]`
    static let preemphasis: Float = 0.97
    /// 音量归一的分母保护;与取对数时的偏置**是两个不同的 1e-6**,别合并。
    static let normalizeEps: Float = 1e-6
    static let logOffset: Float = 1e-6

    enum Failure: Error, CustomStringConvertible {
        case tooShort(samples: Int, need: Int)

        var description: String {
            switch self {
            case .tooShort(let n, let need):
                return "音频太短:\(n) 个采样,至少要 \(need) 个 —— "
                     + "短于一帧算不出梅尔谱,与其返回一张空图不如在这里停"
            }
        }
    }

    // MARK: - 主入口

    /// → 行优先的 `(nMels, frames)` 矩阵,与 PyTorch 侧 `m.spec(wav)` 的输出逐位一致。
    ///
    /// 输入是 16 kHz 单声道 float。**不做重采样** —— 采样率不对应当在调用方暴露出来,
    /// 悄悄重采样会让「为什么分数变差了」变成一个查不出来的问题。
    static func melSpectrogram(_ samples: [Float]) throws -> (values: [Float], frames: Int) {
        try melSpectrogram(samples, window: hammingWindow)
    }

    /// 窗可注入的版本。**这个口子只为变异测试存在** —— 要证明「换成 Hann 金标会红」,
    /// 就得真拿 Hann 跑一遍;给结果加个扰动假装换过窗,那种测试什么也证明不了。
    /// 生产路径永远走上面那个无参版本。
    static func melSpectrogram(_ samples: [Float],
                               window: [Float]) throws -> (values: [Float], frames: Int) {
        guard samples.count >= winLength else {
            throw Failure.tooShort(samples: samples.count, need: winLength)
        }

        let normalized = normalizeAudio(samples)          // ①
        let emphasized = preEmphasize(normalized)         // ②
        var power = powerSpectrogram(emphasized, window: window)   // ③ (257, frames)
        let frames = power.count / (nFFT / 2 + 1)

        var mel = applyFilterbank(power: &power, frames: frames)   // ③ 续
        for i in mel.indices { mel[i] = log(mel[i] + logOffset) }  // ④
        subtractRowMeans(&mel, frames: frames)                     // ⑤
        return (mel, frames)
    }

    // MARK: - ① 音量归一(沿时间轴,std 用有偏估计)

    static func normalizeAudio(_ x: [Float]) -> [Float] {
        var mean: Float = 0, meanSquare: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        vDSP_measqv(x, 1, &meanSquare, vDSP_Length(x.count))
        // 有偏(除以 N,不是 N−1)—— PyTorch 那边是 unbiased=False
        let std = (max(meanSquare - mean * mean, 0)).squareRoot()
        var negMean = -mean, scale = 1 / (std + normalizeEps)
        var out = [Float](repeating: 0, count: x.count)
        vDSP_vsadd(x, 1, &negMean, &out, 1, vDSP_Length(x.count))
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(x.count))
        return out
    }

    // MARK: - ② 预加重(左侧 reflect 填充 1 个样本)

    static func preEmphasize(_ x: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        // reflect 填充:x[-1] 取 x[1]。用零填充会让第一个样本偏大,
        // 而那点差别会一路传到梅尔谱的第一帧。
        out[0] = x[0] - preemphasis * (x.count > 1 ? x[1] : x[0])
        for n in 1..<x.count { out[n] = x[n] - preemphasis * x[n - 1] }
        return out
    }

    // MARK: - ③ 功率谱(center=True,reflect 填充;窗居中补零到 nFFT)

    /// 生产用的窗:**Hamming(periodic)** = `0.54 − 0.46·cos(2πn/N)`,**N 不减一**。
    /// 减一是 symmetric,那是另一条曲线,端点差 0.08 —— 足以让金标红。
    /// 长度 `winLength` 的窗**居中补零到 nFFT**(两边各 56),与 torch.stft 一致。
    static let hammingWindow: [Float] = window { 0.54 - 0.46 * cos($0) }

    /// 只给变异测试用的 Hann 窗,证明金标抓得住换窗。
    static let hannWindow: [Float] = window { 0.5 - 0.5 * cos($0) }

    private static func window(_ shape: (Float) -> Float) -> [Float] {
        var w = [Float](repeating: 0, count: nFFT)
        for n in 0..<winLength {
            w[(nFFT - winLength) / 2 + n] = shape(2 * .pi * Float(n) / Float(winLength))
        }
        return w
    }

    /// → 行优先 `(nFFT/2+1, frames)`。
    static func powerSpectrogram(_ x: [Float], window: [Float] = hammingWindow) -> [Float] {
        let bins = nFFT / 2 + 1
        let pad = nFFT / 2
        let padded = reflectPad(x, by: pad)
        let frames = x.count / hopLength + 1        // center=True 下 torch.stft 的帧数

        let log2n = vDSP_Length(round(log2(Double(nFFT))))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var out = [Float](repeating: 0, count: bins * frames)
        var real = [Float](repeating: 0, count: nFFT / 2)
        var imag = [Float](repeating: 0, count: nFFT / 2)
        var frame = [Float](repeating: 0, count: nFFT)

        for t in 0..<frames {
            let start = t * hopLength
            vDSP_vmul(Array(padded[start..<(start + nFFT)]), 1, window, 1,
                      &frame, 1, vDSP_Length(nFFT))
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: nFFT / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(nFFT / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            // vDSP 的实数 FFT 输出整体放大了 2 倍,且把 Nyquist 塞在 imag[0]。
            // 少除这个 2,梅尔谱会整体偏高 —— log 之后是一个常数偏移,肉眼看不出来。
            out[t] = (real[0] * 0.5) * (real[0] * 0.5)
            out[(bins - 1) * frames + t] = (imag[0] * 0.5) * (imag[0] * 0.5)
            for k in 1..<(nFFT / 2) {
                let re = real[k] * 0.5, im = imag[k] * 0.5
                out[k * frames + t] = re * re + im * im
            }
        }
        return out
    }

    private static func reflectPad(_ x: [Float], by pad: Int) -> [Float] {
        var out = [Float](repeating: 0, count: x.count + 2 * pad)
        for i in 0..<pad { out[i] = x[min(pad - i, x.count - 1)] }
        out.replaceSubrange(pad..<(pad + x.count), with: x)
        for i in 0..<pad {
            out[pad + x.count + i] = x[max(x.count - 2 - i, 0)]
        }
        return out
    }

    // MARK: - ③ 续:梅尔滤波器组(htk 刻度,norm=none)

    /// `(nMels, nFFT/2+1)` 行优先。与 torchaudio `melscale_fbanks(htk, norm=None)` 同式。
    static let filterbank: [Float] = {
        let bins = nFFT / 2 + 1
        func hzToMel(_ f: Float) -> Float { 2595 * log10(1 + f / 700) }
        func melToHz(_ m: Float) -> Float { 700 * (pow(10, m / 2595) - 1) }

        let allFreqs = (0..<bins).map {
            Float($0) * Float(sampleRate / 2) / Float(bins - 1)
        }
        let mMin = hzToMel(fMin), mMax = hzToMel(fMax)
        let fPts = (0..<(nMels + 2)).map {
            melToHz(mMin + (mMax - mMin) * Float($0) / Float(nMels + 1))
        }

        var fb = [Float](repeating: 0, count: nMels * bins)
        for m in 0..<nMels {
            let (lo, ctr, hi) = (fPts[m], fPts[m + 1], fPts[m + 2])
            for k in 0..<bins {
                let down = (allFreqs[k] - lo) / (ctr - lo)     // 上升沿
                let up = (hi - allFreqs[k]) / (hi - ctr)       // 下降沿
                fb[m * bins + k] = max(0, min(down, up))
            }
        }
        return fb
    }()

    private static func applyFilterbank(power: inout [Float], frames: Int) -> [Float] {
        let bins = nFFT / 2 + 1
        var mel = [Float](repeating: 0, count: nMels * frames)
        // (nMels × bins) · (bins × frames)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(nMels), Int32(frames), Int32(bins), 1.0,
                    filterbank, Int32(bins), power, Int32(frames), 0.0,
                    &mel, Int32(frames))
        return mel
    }

    // MARK: - ⑤ 沿时间轴逐梅尔通道减均值

    /// ⚠️ **沿时间轴,不是频率轴。** 弄反了整张图还是一张图、维度也对,
    /// 只是每个数都错 —— 没有任何地方会报错。
    static func subtractRowMeans(_ mel: inout [Float], frames: Int) {
        for m in 0..<nMels {
            let base = m * frames
            var mean: Float = 0
            mel.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress! + base, 1, &mean,
                                                     vDSP_Length(frames)) }
            var neg = -mean
            mel.withUnsafeMutableBufferPointer {
                vDSP_vsadd($0.baseAddress! + base, 1, &neg,
                           $0.baseAddress! + base, 1, vDSP_Length(frames))
            }
        }
    }
}

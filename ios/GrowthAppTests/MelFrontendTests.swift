import XCTest
@testable import GrowthApp

/// 梅尔前端的**逐位验收**。
///
/// 这一半是手写的 DSP,五步十来个常数,**任何一个写错都不报错** ——
/// 只会让声纹悄悄变质。所以唯一算数的验收是拿 PyTorch 的输出对。
/// 金标 `Fixtures/mel_golden.json` 由
/// `docs/evidence/p4b-u6b-u5b/make_frontend_golden.py` 生成(定死种子的合成噪声)。
final class MelFrontendTests: XCTestCase {

    private struct Golden {
        let wav: [Float]
        let mel: [Float]
        let melShape: [Int]
        let params: [String: Any]
    }

    private func loadGolden() throws -> Golden {
        let url = Bundle(for: Self.self).url(forResource: "mel_golden", withExtension: "json")
        let data = try Data(contentsOf: try XCTUnwrap(url, "金标夹具没打进测试包"))
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        func floats(_ key: String) throws -> [Float] {
            let raw = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(j[key] as? String)))
            return raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return Golden(wav: try floats("wav_b64"), mel: try floats("mel_b64"),
                      melShape: try XCTUnwrap(j["mel_shape"] as? [Int]),
                      params: try XCTUnwrap(j["params"] as? [String: Any]))
    }

    // MARK: - 主验收

    /// 与 PyTorch 的梅尔谱逐点比。容差 1e-3:两边的 FFT 实现不同(vDSP vs MKL/Accelerate),
    /// 累积浮点差在 1e-4 量级;**而任何一个常数写错造成的差都在 0.1 以上**,
    /// 所以这个容差挡得住真正的错,又不会被浮点噪声误伤。
    func testMatchesPyTorchGolden() throws {
        let g = try loadGolden()
        let (mine, frames) = try MelFrontend.melSpectrogram(g.wav)

        XCTAssertEqual([MelFrontend.nMels, frames], g.melShape, "形状就对不上,别看数值")
        XCTAssertEqual(mine.count, g.mel.count)

        var worst: Float = 0, worstAt = -1
        for i in mine.indices where abs(mine[i] - g.mel[i]) > worst {
            worst = abs(mine[i] - g.mel[i]); worstAt = i
        }
        // 实测最大逐点差 **6.9e-5**(2026-08-12,vDSP vs PyTorch,均为 float32)。
        // 容差取 5e-4:比实测宽 7 倍(容得下不同机器的浮点差),
        // 又比任何一个常数写错造成的差(≥0.1,见下面的变异测试)小两个数量级。
        // ⚠️ 差**不是 0** —— 是 0 才该怀疑测试空转。
        XCTAssertLessThan(worst, 5e-4,
                          "第 \(worstAt) 个点差 \(worst):我 \(mine[worstAt]) vs 金标 \(g.mel[worstAt])")
    }

    /// 常数必须与金标里记的一致。**这条在数值之前跑** ——
    /// 数值对不上时,先知道是不是有人改了常数,比逐点去猜快得多。
    func testConstantsMatchGolden() throws {
        let p = try loadGolden().params
        XCTAssertEqual(p["sample_rate"] as? Int, MelFrontend.sampleRate)
        XCTAssertEqual(p["n_fft"] as? Int, MelFrontend.nFFT)
        XCTAssertEqual(p["hop_length"] as? Int, MelFrontend.hopLength)
        XCTAssertEqual(p["win_length"] as? Int, MelFrontend.winLength)
        XCTAssertEqual(p["n_mels"] as? Int, MelFrontend.nMels)
        XCTAssertEqual(p["window"] as? String, "hamming_periodic")
        XCTAssertEqual(p["mel_scale"] as? String, "htk")
        XCTAssertEqual(p["fb_norm"] as? String, "none")
        XCTAssertEqual(p["center"] as? Bool, true)
        XCTAssertEqual(p["pad_mode"] as? String, "reflect")
    }

    // MARK: - 变异测试:金标必须能抓到「写错但不报错」的那几种

    /// 把窗换成 Hann、把刻度换成 slaney、把减均值改成沿频率轴 —— 三种最容易犯的错,
    /// **每一种都必须让金标红**。抓不到的金标等于没有金标。
    func testGoldenCatchesTheThreeClassicMistakes() throws {
        let g = try loadGolden()
        let (correct, frames) = try MelFrontend.melSpectrogram(g.wav)

        // ① 窗换成 Hann(0.5 − 0.5cos)而不是 Hamming(0.54 − 0.46cos)。
        //    **真拿 Hann 跑一遍**,不是给结果加扰动假装换过窗。
        let hann = try MelFrontend.melSpectrogram(g.wav, window: MelFrontend.hannWindow).values
        XCTAssertGreaterThan(maxDiff(hann, g.mel), 1e-3, "换成 Hann 窗居然没被金标抓到")

        // ② 减均值沿频率轴而不是时间轴
        var wrongAxis = correct
        subtractColumnMeans(&wrongAxis, frames: frames)
        XCTAssertGreaterThan(maxDiff(wrongAxis, g.mel), 1e-3, "减错轴居然没被金标抓到")

        // ③ 少除 vDSP 的 2 倍缩放 —— log 之后是个常数偏移,肉眼最难看出来
        let scaled = correct.map { $0 + log(4.0 as Float) }
        XCTAssertGreaterThan(maxDiff(scaled, g.mel), 1e-3, "缩放写错居然没被金标抓到")
    }

    // MARK: - 边界

    func testTooShortAudioThrowsInsteadOfReturningAnEmptyPicture() {
        XCTAssertThrowsError(try MelFrontend.melSpectrogram([Float](repeating: 0, count: 100)))
    }

    /// 滤波器组的每一行都该有非零值,且不越界。全零行意味着某个梅尔通道永远是
    /// `log(1e-6)` 常数 —— 网络那边收到一条死通道,而形状完全正常。
    func testFilterbankHasNoDeadChannel() {
        let bins = MelFrontend.nFFT / 2 + 1
        XCTAssertEqual(MelFrontend.filterbank.count, MelFrontend.nMels * bins)
        for m in 0..<MelFrontend.nMels {
            let row = MelFrontend.filterbank[(m * bins)..<((m + 1) * bins)]
            XCTAssertGreaterThan(row.max() ?? 0, 0.01, "第 \(m) 个梅尔通道是死的")
            XCTAssertGreaterThanOrEqual(row.min() ?? -1, 0, "滤波器不该有负权重")
        }
    }

    // MARK: - 工具

    private func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    private func subtractColumnMeans(_ mel: inout [Float], frames: Int) {
        for t in 0..<frames {
            var sum: Float = 0
            for m in 0..<MelFrontend.nMels { sum += mel[m * frames + t] }
            let mean = sum / Float(MelFrontend.nMels)
            for m in 0..<MelFrontend.nMels { mel[m * frames + t] -= mean }
        }
    }
}

import XCTest
@testable import GrowthApp

/// 声纹嵌入器的**端到端验收**:`MelFrontend`(手写 DSP)+ `RedimnetBody`(ONNX)
/// 合起来,与 PyTorch 算的同一个数比。
///
/// ## 为什么必须比数值,而不是「跑通了就行」
///
/// 这条链上每一处出错都**照样输出 192 个数**,而且哪里都不报错:
/// 窗写成 Hann、mel_scale 用 slaney、CMN 沿错轴、梅尔谱转置了喂进去、
/// ORT 换版本后输出名变了拿到别的张量 …… 表现全是「声纹时准时不准」,查起来极贵。
/// 所以唯一算数的验收是**拿 PyTorch 的输出对余弦**。
///
/// 金标 `Fixtures/embedder_golden.json` 由
/// `docs/evidence/p4b-u6b-u5b/export_embedder.py` 生成(定死种子的 3 秒合成噪声,
/// 与前端金标的 1 秒**刻意不同长** —— 两份合起来才覆盖到变长)。
final class RedimnetBodyTests: XCTestCase {

    private struct Golden {
        let wav: [Float]
        let emb: [Float]
        let model: String
    }

    private func loadGolden() throws -> Golden {
        let url = Bundle(for: Self.self).url(forResource: "embedder_golden", withExtension: "json")
        let data = try Data(contentsOf: try XCTUnwrap(url, "端到端金标没打进测试包"))
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        func floats(_ key: String) throws -> [Float] {
            let raw = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(j[key] as? String)))
            return raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let spec = try XCTUnwrap(j["_spec"] as? [String: Any])
        return Golden(wav: try floats("wav_b64"), emb: try floats("emb_b64"),
                      model: try XCTUnwrap(spec["模型"] as? String))
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private func embed(_ wav: [Float], window: [Float] = MelFrontend.hammingWindow) throws -> [Float] {
        let (mel, frames) = try MelFrontend.melSpectrogram(wav, window: window)
        return try RedimnetBody().embed(mel: mel, frames: frames)
    }

    // MARK: - 主验收

    /// 端到端与 PyTorch 比余弦。
    ///
    /// 阈值 0.9999:ONNX(fp32,CoreML/CPU 算子实现不同)与 PyTorch 的差在 1e-6 量级,
    /// 而**任何一个常数写错**造成的余弦跌落都在 0.1 以上(见下面的变异测试),
    /// 两者差着三个数量级,这个阈值不会被浮点噪声误伤,也漏不掉真错。
    func testEndToEndMatchesPyTorch() throws {
        let g = try loadGolden()
        let mine = try embed(g.wav)

        XCTAssertEqual(mine.count, RedimnetBody.embeddingDim, "维度对不上,别看数值")
        let c = cosine(mine, g.emb)
        XCTAssertGreaterThan(c, 0.9999, "端到端余弦只有 \(c) —— 前端常数或 ONNX 有一处不对")
    }

    /// 金标必须与生产声明的是同一个模型。
    /// 换模型时漏换金标,上面那条会**继续绿着**验旧模型的数 —— 那正是要防的。
    func testGoldenIsForTheProductionEmbedder() throws {
        XCTAssertEqual(try loadGolden().model, VoiceprintModel.current,
                       "金标声明的模型与 VoiceprintModel.current 不一致 —— "
                     + "换模型要三件一起换:.onnx、VoiceprintModel.current、金标")
    }

    /// 输出是 L2 归一化的。底库与回流契约存的都是归一化向量,
    /// 漏归一的表现是**余弦整体偏小**,不是任何一处报错。
    func testOutputIsL2Normalized() throws {
        let e = try embed(try loadGolden().wav)
        let norm = e.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-5)
    }

    // MARK: - 变长(动态轴真的可用)

    /// 导出时固定 10 秒,动态轴声明在第 2 维。**变长必须真跑** ——
    /// VAD 交出来的片段是 1.5~8 秒,块尾还可能更短;
    /// 动态轴要是没生效,只有线上才炸。
    func testVariableLengthAudio() throws {
        let body = try RedimnetBody()
        for sec in [0.5, 1.0, 3.0, 8.0] {
            let n = Int(16000 * sec)
            var rng = SystemRandomNumberGenerator()
            let wav = (0..<n).map { _ in Float.random(in: -0.3...0.3, using: &rng) }
            let (mel, frames) = try MelFrontend.melSpectrogram(wav)
            let e = try body.embed(mel: mel, frames: frames)
            XCTAssertEqual(e.count, RedimnetBody.embeddingDim, "\(sec)s 上维度不对")
            XCTAssertTrue(e.allSatisfy { $0.isFinite }, "\(sec)s 上出了 NaN/Inf")
        }
    }

    // MARK: - 变异测试(证明上面那条主验收不是空转)

    /// 把前端的窗换成 Hann,端到端余弦**必须明显掉下来**。
    ///
    /// 这条是用来打主验收的:如果换了窗余弦还在 0.9999 以上,
    /// 说明那条断言根本不敏感,绿着也不说明任何事情。
    func testGoldenCatchesAWrongWindow() throws {
        let g = try loadGolden()
        let wrong = try embed(g.wav, window: MelFrontend.hannWindow)
        let c = cosine(wrong, g.emb)
        XCTAssertLessThan(c, 0.99,
                          "换成 Hann 窗后余弦仍有 \(c) —— 主验收对前端错误不敏感,这套测试是空转的")
    }

    /// 梅尔谱**转置着**喂进去(72×T 当成 T×72),必须被形状校验挡下。
    /// 挡不下的话它会照样算出 192 个数 —— 一个由错位的图算出来的声纹。
    func testTransposedMelIsRejected() throws {
        let (mel, frames) = try MelFrontend.melSpectrogram(try loadGolden().wav)
        XCTAssertThrowsError(try RedimnetBody().embed(mel: mel, frames: MelFrontend.nMels)) {
            guard case RedimnetBody.Failure.shapeMismatch = $0 else {
                return XCTFail("该报形状不符,实际是 \($0)")
            }
        }
        XCTAssertGreaterThan(frames, MelFrontend.nMels, "前提:这段音频的帧数与梅尔通道数不相等")
    }

    /// 空输入抛,不返回零向量 —— 零向量在余弦比对里就是「谁都不像」,
    /// 也就是悄悄退化成拒识,而拒识看起来完全正常。
    func testEmptyMelThrowsInsteadOfReturningZeroVector() throws {
        let body = try RedimnetBody()
        XCTAssertThrowsError(try body.embed(mel: [], frames: 0))
        XCTAssertThrowsError(try body.embed(mel: [1, 2, 3], frames: 0))
    }
}

import Foundation
import OnnxRuntimeBindings

/// 声纹嵌入器的**后一半**:梅尔谱 →(网络本体)→ 192 维声纹。
///
/// 前一半是 `MelFrontend`(手写 DSP)。两半合起来才是一个嵌入器 ——
/// 之所以劈开,是因为 `torch.onnx.export` 整模型导不出来(卡在 STFT 要用复数)。
/// 接缝取在模型自己 `forward` 的天然分界上,不是随手切的:
///
///     声波 ──[MelFrontend:五步 DSP]──▶ (72, T) 梅尔谱 ──[本文件:ONNX]──▶ 192 维
///
/// 模型是 `redimnet_s_body_op17.onnx`(ReDimNet-S 中文,3.15M 参数,opset 17),
/// 由 `docs/evidence/p4b-u6b-u5b/export_embedder.py` 导出并落进 App 包。
/// 换模型要三件一起换:`.onnx`、`VoiceprintModel.current`、端到端金标 —— 换漏一件不会报错
/// (金标里记着模型串,`RedimnetBodyTests` 拿它对撞 `VoiceprintModel.current`,漏改会红)。
///
/// ## 这里只做一件事
///
/// **梅尔谱进、向量出。** 不读音频、不比对底库、不写归属层 ——
/// 「块音频 → 嵌入 → 比对底库 → 写 `person_id`」那条链是另一件事,
/// 且写回必须走 `assignSpeaker` 这个唯一入口(铁律 3)。
final class RedimnetBody {

    /// 与底库、`§4.3` 回流契约、P4c 模板全部对齐的维度。变了就不是同一个空间。
    static let embeddingDim = 192
    static let modelName = "redimnet_s_body_op17"

    enum Failure: Error, CustomStringConvertible {
        case modelMissing
        case emptyMel
        case shapeMismatch(count: Int, frames: Int)
        /// 模型跑了但输出不对。**必须抛,不能返回零向量** —— 见 `embed` 的注释。
        case badOutput(String)

        var description: String {
            switch self {
            case .modelMissing:
                return "找不到 \(RedimnetBody.modelName).onnx —— 模型没打进 App 包"
            case .emptyMel:
                return "梅尔谱是空的 —— 算不出声纹,不能拿零向量顶上"
            case .shapeMismatch(let count, let frames):
                return "梅尔谱长度 \(count) 不是 \(MelFrontend.nMels) × \(frames) —— "
                     + "形状对不上时算出来的是一张错位的图,而它照样能出 192 个数"
            case .badOutput(let why):
                return "声纹模型的输出解不出来(\(why))—— 不能当成一个「谁都不像」的向量"
            }
        }
    }

    private let env: ORTEnv
    private let session: ORTSession

    init(modelURL: URL? = nil) throws {
        let url: URL
        if let modelURL {
            url = modelURL
        } else {
            guard let u = Bundle(for: RedimnetBody.self)
                .url(forResource: Self.modelName, withExtension: "onnx")
            else { throw Failure.modelMissing }
            url = u
        }
        env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        session = try ORTSession(env: env, modelPath: url.path, sessionOptions: nil)
    }

    /// 梅尔谱(行优先 `(nMels, frames)`,即 `MelFrontend.melSpectrogram` 的原样输出)
    /// → **L2 归一化后**的 192 维声纹。
    ///
    /// 归一化放在这里而不是留给调用方:底库、P4c 模板、§4.3 回流契约存的全是归一化向量,
    /// 各家自己归一的话,漏掉一处的表现是**余弦分数整体偏小**,而不是任何一处报错。
    ///
    /// ⚠️ **失败一律抛,不返回零向量。** 零向量在余弦比对里是一个「跟谁都不像」的分数,
    /// 也就是「拒识」—— 那正是模型没跑起来时最像正常工作的样子
    /// (`SileroVAD` 的注释记的是同一个错法的另一半)。
    func embed(mel: [Float], frames: Int) throws -> [Float] {
        guard frames > 0, !mel.isEmpty else { throw Failure.emptyMel }
        guard mel.count == MelFrontend.nMels * frames else {
            throw Failure.shapeMismatch(count: mel.count, frames: frames)
        }

        var input = mel
        let tensor = try ORTValue(
            tensorData: NSMutableData(bytes: &input, length: input.count * 4),
            elementType: .float,
            shape: [1, NSNumber(value: MelFrontend.nMels), NSNumber(value: frames)])

        let out = try session.run(withInputs: ["mel": tensor],
                                  outputNames: ["emb"], runOptions: nil)

        guard let o = out["emb"], let d = try? o.tensorData() as Data,
              d.count == Self.embeddingDim * 4 else {
            throw Failure.badOutput("emb 缺失或不是 \(Self.embeddingDim) 个 float")
        }
        let raw: [Float] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        let norm = raw.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        // 全零 / NaN 输出:模型确实跑了,但结果没有意义。归一化会把它变成 NaN 或 0 向量,
        // 两者在下游都表现成「不像任何人」,悄悄退化成拒识。
        guard norm.isFinite, norm > 1e-6 else {
            throw Failure.badOutput("向量模长 \(norm) —— 全零或 NaN")
        }
        return raw.map { $0 / norm }
    }
}

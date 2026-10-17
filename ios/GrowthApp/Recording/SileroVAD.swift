import Foundation
import OnnxRuntimeBindings

final class SileroVAD {

    static let speechThreshold: Float = 0.35

    static let frameSamples = 512
    static let contextSamples = 64
    static let sampleRate: Int64 = 16_000

    enum Failure: Error, CustomStringConvertible {
        case modelMissing
        case badFrameLength(Int)
        case badOutput(String)

        var description: String {
            switch self {
            case .modelMissing:
                return "找不到 silero_vad_16k_op15.onnx —— 模型没打进 App 包"
            case .badFrameLength(let n):
                return "一帧要 \(SileroVAD.frameSamples) 个采样,给了 \(n) 个"
            case .badOutput(let why):
                return "VAD 的输出解不出来(\(why))—— 不能当成「没人说话」"
            }
        }
    }

    private let env: ORTEnv
    private let session: ORTSession
    private var state = [Float](repeating: 0, count: 2 * 128)
    private var context = [Float](repeating: 0, count: contextSamples)

    init(modelURL: URL? = nil) throws {
        let url: URL
        if let modelURL {
            url = modelURL
        } else {
            guard let u = Bundle(for: SileroVAD.self)
                .url(forResource: "silero_vad_16k_op15", withExtension: "onnx")
            else { throw Failure.modelMissing }
            url = u
        }
        env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        session = try ORTSession(env: env, modelPath: url.path, sessionOptions: nil)
    }

    func probability(frame: [Float]) throws -> Float {
        guard frame.count == Self.frameSamples else {
            throw Failure.badFrameLength(frame.count)
        }
        var input = context + frame                       // 576
        var st = state
        var sr = Self.sampleRate

        let inputTensor = try ORTValue(
            tensorData: NSMutableData(bytes: &input, length: input.count * 4),
            elementType: .float, shape: [1, NSNumber(value: input.count)])
        let stateTensor = try ORTValue(
            tensorData: NSMutableData(bytes: &st, length: st.count * 4),
            elementType: .float, shape: [2, 1, 128])
        let srTensor = try ORTValue(
            tensorData: NSMutableData(bytes: &sr, length: 8),
            elementType: .int64, shape: [])

        let out = try session.run(withInputs: ["input": inputTensor,
                                               "state": stateTensor,
                                               "sr": srTensor],
                                  outputNames: ["output", "stateN"],
                                  runOptions: nil)

        guard let sn = out["stateN"], let sd = try? sn.tensorData() as Data,
              sd.count == state.count * 4 else {
            throw Failure.badOutput("stateN 缺失或尺寸不符")
        }
        state = sd.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        context = Array(frame.suffix(Self.contextSamples))

        guard let o = out["output"], let d = try? o.tensorData() as Data, d.count >= 4 else {
            throw Failure.badOutput("output 缺失或不足 4 字节")
        }
        return d.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    func reset() {
        state = [Float](repeating: 0, count: 2 * 128)
        context = [Float](repeating: 0, count: Self.contextSamples)
    }
}

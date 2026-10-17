import Foundation

/// 块 → 16kHz 单声道 16bit PCM wav(M1-4c 收尾,2026-08-17)。
///
/// ## 为什么非 wav 不可
///
/// P4a 那次真跑通过的配置**只有 wav 这一种**,而且它的脚本头上明写着:
///
/// > 喂 wav 别喂 mp3:有损压缩会把说话人并少(**实测 3→2**)
///
/// 分人标签是走文件端点的**全部理由**(判 18:ASR 自带分人比 Mac 本地 pyannote 更准),
/// 拿有损格式去喂等于把这条路的价值先削掉一截。
///
/// 而 2026-08-17 实测更直接:我们传的是 m4a、却在载荷里声明 `format: "mp3"`,
/// StepFun 读出了**正确的时长**(说明音频确实拉到了)、返回的 `result` 却是 `[{}]` ——
/// **一个字都没有**。对格式撒谎的代价不是报错,是静默的空结果。
///
/// ## 为什么不直接录成 wav
///
/// 16kHz 单声道 16bit = 1.92 MB/分钟,一天 8 小时约 920 MB 躺在手机上。
/// 而 m4a 只有约 1/12。录音**留在本地**,wav 只是**送检时的中转格式** ——
/// 转完即删,不占长期空间。
enum WavExport {

    static let sampleRate = 16_000

    enum Failure: Error, CustomStringConvertible {
        case emptyAudio(URL)
        var description: String {
            switch self {
            case .emptyAudio(let u): return "\(u.lastPathComponent) 解出来一个采样点都没有"
            }
        }
    }

    /// 转成 wav 放进临时目录,返回新文件。调用方负责用完删。
    ///
    /// **流式写**,不把整块读进内存:5 分钟块解成 Float 是 19 MB,
    /// 一次性读进来在后台被系统杀掉的概率不低。
    ///
    /// - Parameter keeping: 只写这些区间(块内原始毫秒),区间外的采样点丢掉。
    ///   nil = 整块都写。**区间必须已排序且互不重叠**(`SpeechTrim.plan` 保证),
    ///   这里按顺序流式裁,不回头。
    ///
    /// 🔴 **裁的只是送检的 wav,本地 m4a 一个字节不动。**
    /// 声纹取段、将来的重算、用户回听读的都是本地那份 —— 裁本地等于把原始证据删了。
    static func convert(_ source: URL, to destination: URL? = nil,
                        keeping intervals: [KeptInterval]? = nil) async throws -> URL {
        let out = destination ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".wav")
        try? FileManager.default.removeItem(at: out)
        FileManager.default.createFile(atPath: out.path, contents: nil)

        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        // 先占位写一个头,采样数还不知道 —— 全部写完再回来补长度。
        try handle.write(contentsOf: header(samples: 0))

        // 区间换算成采样点下标。**在这里换算一次**,别在循环里对每个采样点算毫秒:
        // 5 分钟块是 480 万个采样点,循环里做除法会把转换时间拖成秒级。
        let ranges: [Range<Int>]? = intervals.map { list in
            list.map { (Int($0.startMs) * sampleRate / 1000) ..< (Int($0.endMs) * sampleRate / 1000) }
        }
        var cursor = 0                 // 已经流过的采样点数(源音频的绝对下标)
        var rangeIndex = 0             // 当前对齐到第几个保留区间

        var total = 0
        try await AudioImport.decode(url: source) { chunk in
            var pcm = Data(capacity: chunk.count * 2)
            func emit(_ f: Float) {
                // 截到 [-1, 1] 再定标。不截的话超幅的采样点会绕回成反向的尖峰,
                // 听上去是爆音,而 ASR 那头只会表现为「这一段识别得莫名其妙」。
                let clamped = max(-1, min(1, f))
                var v = Int16(clamped * 32767).littleEndian
                withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
                total += 1
            }
            if let ranges {
                for (i, f) in chunk.enumerated() {
                    let idx = cursor + i
                    // 走过的区间就跳过去,不回头 —— 区间是排好序的
                    while rangeIndex < ranges.count, idx >= ranges[rangeIndex].upperBound {
                        rangeIndex += 1
                    }
                    guard rangeIndex < ranges.count else { break }
                    if idx >= ranges[rangeIndex].lowerBound { emit(f) }
                }
            } else {
                for f in chunk { emit(f) }
            }
            cursor += chunk.count
            try handle.write(contentsOf: pcm)
        }
        guard total > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw Failure.emptyAudio(source)
        }

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(samples: total))
        return out
    }

    /// 44 字节的标准 RIFF/WAVE 头。16bit 单声道。
    static func header(samples: Int) -> Data {
        let bytes = samples * 2
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian
                             withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian
                             withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF");  u32(36 + bytes); str("WAVE")
        str("fmt ");  u32(16); u16(1)              // 1 = PCM,无压缩
        u16(1)                                      // 单声道
        u32(sampleRate)
        u32(sampleRate * 2)                         // 字节率 = 采样率 × 块对齐
        u16(2); u16(16)                             // 块对齐 2 字节;位深 16
        str("data"); u32(bytes)
        return d
    }
}

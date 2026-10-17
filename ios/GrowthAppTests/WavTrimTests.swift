import XCTest
import AVFoundation
@testable import GrowthApp

/// 裁剪写 wav 那一步(M1-4d ①)。
///
/// 板上的验收第 1 条是「拿真机那两场重跑,裁剪接近恒等 ⇒ 行数与文本必须一致」。
/// 那一条要真机素材,这里先把它的**充分条件**钉死:
/// **保留区间覆盖整块时,裁剪出来的 wav 必须与不裁一模一样。**
/// 恒等这一步都不成立的话,后面的逐行 diff 不用做了。
final class WavTrimTests: XCTestCase {

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavtrim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if dir != nil { try? FileManager.default.removeItem(at: dir) }
    }

    /// 造一段可辨认的音频:第 n 秒的采样值都是 n/100,
    /// 这样从输出里就能读出「留下来的是原音的哪一秒」。
    private func makeAudio(seconds: Int) throws -> URL {
        let url = dir.appendingPathComponent("src.wav")
        let rate = 16_000
        var data = WavExport.header(samples: seconds * rate)
        for s in 0..<seconds {
            let v = Int16(Float(s) / 100 * 32767)
            for _ in 0..<rate {
                var le = v.littleEndian
                withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
            }
        }
        try data.write(to: url)
        return url
    }

    /// 读回采样点(跳过 44 字节头)。
    private func samples(of url: URL) throws -> [Int16] {
        let d = try Data(contentsOf: url)
        return stride(from: 44, to: d.count - 1, by: 2).map {
            Int16(littleEndian: d[$0..<($0 + 2)].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
        }
    }

    /// 🔴 **恒等:覆盖整块的区间,与不裁必须逐字节相同。**
    func testKeepingTheWholeBlockIsByteIdenticalToNotTrimming() async throws {
        let src = try makeAudio(seconds: 10)
        let plain = try await WavExport.convert(src, to: dir.appendingPathComponent("a.wav"))
        let whole = try await WavExport.convert(src, to: dir.appendingPathComponent("b.wav"),
                                                keeping: [KeptInterval(startMs: 0, endMs: 10_000)])
        XCTAssertEqual(try Data(contentsOf: plain), try Data(contentsOf: whole),
                       "覆盖整块的裁剪不是恒等 —— 后面所有时间轴还原都建立在它之上")
    }

    /// 挖两个洞:留下的必须**正好**是那两段,而且是原音的那两段。
    func testTrimmingKeepsExactlyTheGivenIntervals() async throws {
        let src = try makeAudio(seconds: 10)
        let out = try await WavExport.convert(
            src, to: dir.appendingPathComponent("c.wav"),
            keeping: [KeptInterval(startMs: 1_000, endMs: 3_000),
                      KeptInterval(startMs: 7_000, endMs: 8_000)])
        let s = try samples(of: out)
        XCTAssertEqual(s.count, 3 * 16_000, "留下的采样数不对:\(s.count)")

        // 前 2 秒该是原音的第 1、2 秒;第 3 秒该是原音的第 7 秒
        func secondValue(_ i: Int) -> Int { Int(round(Double(s[i * 16_000 + 8_000]) / 32767 * 100)) }
        XCTAssertEqual(secondValue(0), 1, "第 1 段的开头不是原音第 1 秒")
        XCTAssertEqual(secondValue(1), 2)
        XCTAssertEqual(secondValue(2), 7, "第 2 段没接在第 1 段后面 —— 时间轴会整体错位")
    }

    /// 🔴 **裁剪 + 还原,必须回到原音的位置。**
    /// 这一条是「挖洞验时间轴」的核心:裁掉中间之后,
    /// 后半段每一句话的时间戳仍要能还原回它在原音里的真实位置。
    func testRestoringATrimmedTimestampLandsOnTheOriginalMoment() throws {
        let kept = [KeptInterval(startMs: 1_000, endMs: 3_000),
                    KeptInterval(startMs: 7_000, endMs: 8_000)]
        // 裁剪后第 0 毫秒 = 原音第 1000 毫秒
        XCTAssertEqual(try TranscriptFreeze.restoreToBlockTime(
            trimmedMs: 0, keptIntervals: kept, blockSeq: 0), 1_000)
        // 裁剪后第 1999 毫秒 = 原音第 2999 毫秒(还在第一段里)
        XCTAssertEqual(try TranscriptFreeze.restoreToBlockTime(
            trimmedMs: 1_999, keptIntervals: kept, blockSeq: 0), 2_999)
        // 裁剪后第 2000 毫秒 = 跨进第二段 = 原音第 7000 毫秒(**跳过了中间那 4 秒**)
        XCTAssertEqual(try TranscriptFreeze.restoreToBlockTime(
            trimmedMs: 2_000, keptIntervals: kept, blockSeq: 0), 7_000)
    }

    /// ASR 报得比裁完的音频略长时,只延长**最后一段**,前面每一段一毫秒都不动。
    ///
    /// 越界只可能发生在末尾(编码器收尾那几十毫秒)。整体缩放会把每一句话都挪走一点,
    /// 而不补则是 `restoreToBlockTime` 抛 → **任务永久停在 running**,重启也救不回。
    func testAnOvershootExtendsOnlyTheLastInterval() {
        let recorded = [KeptInterval(startMs: 1_000, endMs: 3_000),
                        KeptInterval(startMs: 7_000, endMs: 8_000)]
        let out = ProcessingPump.keptIntervals(recorded: recorded, blockDurationMs: 300_000,
                                               maxLineEndMs: 3_100)   // 总长 3000,超了 100
        XCTAssertEqual(out.first, recorded.first, "前面的段被动了 —— 前面的句子会集体错位")
        XCTAssertEqual(out.last?.endMs, 8_100, "最后一段没补够,restore 会抛")
        XCTAssertEqual(out.reduce(0) { $0 + $1.durationMs }, 3_100)
    }

    /// 没有裁剪记录(本块早于 M1-4d)⇒ 整块,并保留原来那条「取更大者」的余量。
    func testNoRecordMeansWholeBlockWithTheOldHeadroom() {
        let out = ProcessingPump.keptIntervals(recorded: nil, blockDurationMs: 300_000,
                                               maxLineEndMs: 300_450)
        XCTAssertEqual(out, [KeptInterval(startMs: 0, endMs: 300_450)])
    }
}

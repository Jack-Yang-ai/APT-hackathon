import AVFoundation
import Foundation
import GRDB

// 把一行转写定位回它自己的那段音频。
//
// ## 🔴 这一层存在的全部理由:**不许猜**
//
// 认人的时候放错音频是最贵的错法之一 —— 用户听到的是**别人的声音**,
// 却照着屏幕上的字确认了「这是小李」,于是一整簇话被记到错的人名下,
// 而归属一错,表态与承诺全跟着错。
//
// 而「猜」在这里有一个非常具体的形态:**拿 `t_start_ms / 300_000` 反推块号**。
// 它算出来永远是个合法的块号,不报错、不越界 —— 但真实块长是 `[270s, 330s]`
// (`BlockCutPolicy`),而块偏移用的是名义值 `blockSeq * 300_000`,
// 于是块 0 第 310 秒的行与块 1 第 10 秒的行,`t_start_ms` **都是 310000**。
// 反推会给前者取到后者的音频,而那是另一个人在说话。
//
// 所以这里**只认 `transcript_lines.block_seq`**(迁移 v15 加的列)。
// 存量行那一列是 NULL —— 它们**确实不知道**自己来自哪块,
// 那时正确的做法是**说「定位不到」**,不是给一段可能是别人的声音。
enum LineAudio {

    /// 一行对应的音频片段。
    struct Clip: Equatable {
        let url: URL
        /// 块内起点(秒)。
        let start: TimeInterval
        let duration: TimeInterval
    }

    /// 为什么放不了。**每一种都要说得出口** —— 认人页上一个灰掉的喇叭
    /// 如果不说原因,用户只会以为「这个 App 坏了」。
    enum Unavailable: Error, Equatable {
        /// 这一行是 v15 之前落的,不知道来自哪一块。
        case noBlockSeq
        /// 音频文件不在了(用户清过录音,或换了机器)。
        case fileMissing
        case noSuchLine
        /// 这个说话人一句可播的样本都没挑出来(投影层没给 `line_id`)。
        case noSampleLine
        /// 库没打开,或查块起点时出错。**它必须说出口** —— 见下面 `reason` 那段注释。
        case lookupFailed

        var reason: String {
            switch self {
            case .noBlockSeq:   return "这条录得早,定位不到对应的音频"
            case .fileMissing:  return "音频文件已经不在了"
            case .noSuchLine:   return "找不到这一行"
            case .noSampleLine: return "这个说话人没挑出可播的样本句"
            case .lookupFailed: return "读不出这句话的音频位置"
            }
        }
    }

    static func clip(lineID: Int64, offsets: [Int: Int],
                     in db: Database) throws -> Result<Clip, Unavailable> {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT l.block_seq AS blk, l.t_start_ms AS s, l.t_end_ms AS e,
                   ss.day AS day, ss.source AS source
              FROM transcript_lines l
              JOIN transcripts  t  ON t.id = l.transcript_id
              JOIN sessions     ss ON ss.id = t.session_id
             WHERE l.line_id = ?
            """, arguments: [lineID]) else { return .failure(.noSuchLine) }

        return resolve(blockSeq: row["blk"], startMs: row["s"], endMs: row["e"],
                       day: row["day"], source: row["source"], offsets: offsets)
    }

    /// 「这一行放不放得出声」的**唯一判据**。
    ///
    /// 🔴 提成独立函数是因为它有了第二个消费方:`PeopleProjection.pendingSpeakers`
    /// 要在投影层就把「听不了的候选」滤掉(2026-08-31 用户拍板)。
    /// 两处各写一份的判断会漂,而漂了的样子是**确认页列出一个候选,
    /// 而它的按钮写着「音频文件已经不在了」** —— 两边都「跑得通」。
    /// ⇒ 这里是判据,`clip(lineID:…)` 和投影层都只是它的调用方。
    static func resolve(blockSeq: Int?, startMs: Int, endMs: Int, day: String,
                        source: String = SessionSource.recording,
                        offsets: [Int: Int]) -> Result<Clip, Unavailable> {
        // 🔴 这一句就是这个文件的意义所在。**不要给它加 fallback。**
        guard let blk = blockSeq else { return .failure(.noBlockSeq) }

        let url = RecordingPaths.audioDir(day: day, source: source)
            .appendingPathComponent(String(format: "block-%04d.m4a", blk))
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.fileMissing)
        }

        // 🔴 **块内偏移只能用账本里那一块的真实起点算。**
        // ~~`t_start_ms − blockSeq × 300_000`~~ 那个减法 2026-08-17 起失效了:
        // 冻结层已改成按账本真值拼场次时间轴(块长实际 270–330 秒),
        // 再按名义 300 秒去减,偏移会**逐块累积**,而漂的形态是
        // **取到块里错误的位置、不报错** —— 放出来是别人的话。
        guard let (s, e) = BlockTiming.withinBlock(
            startMs: startMs, endMs: endMs, blockSeq: blk, offsets: offsets)
        else { return .failure(.noBlockSeq) }

        return .success(Clip(url: url,
                             start: TimeInterval(s) / 1000,
                             duration: TimeInterval(e - s) / 1000))
    }

    /// 便利版:自己去账本取块起点。
    static func clip(lineID: Int64, in queue: DatabaseQueue) throws -> Result<Clip, Unavailable> {
        let sessionID = try queue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT t.session_id FROM transcript_lines l
                  JOIN transcripts t ON t.id = l.transcript_id
                 WHERE l.line_id = ?
                """, arguments: [lineID])
        }
        guard let sessionID else { return .failure(.noSuchLine) }
        let offsets = BlockTiming.offsets(sessionID: sessionID, in: queue)
        return try queue.read { try clip(lineID: lineID, offsets: offsets, in: $0) }
    }
}

/// 放一小段。**一次只放一段** —— 认人时同时响两段人就分不清在听谁。
@MainActor
final class LineAudioPlayer: NSObject, ObservableObject {
    @Published private(set) var playingLineID: Int64?

    private var player: AVAudioPlayer?
    private var stopper: Task<Void, Never>?

    func toggle(lineID: Int64, clip: LineAudio.Clip) {
        if playingLineID == lineID { stop(); return }
        stop()
        do {
            // 认人是「放给自己听」,所以用 `.playback`;录音那条链自己管
            // `.playAndRecord`,这里不去动它的类别设置。
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: clip.url)
            p.currentTime = clip.start
            p.play()
            player = p
            playingLineID = lineID
            // AVAudioPlayer 没有「放到某一点就停」,所以自己掐 ——
            // 不掐的话会一直放到块尾(最长 5 分半),而那后面全是别人的话。
            stopper = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(clip.duration * 1_000_000_000))
                await MainActor.run { self?.stop() }
            }
        } catch {
            // 放不出来就当没在放,不留一个永远高亮的按钮
            playingLineID = nil
        }
    }

    func stop() {
        stopper?.cancel(); stopper = nil
        player?.stop(); player = nil
        playingLineID = nil
    }
}

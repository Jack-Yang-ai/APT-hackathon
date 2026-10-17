import Foundation
import AVFoundation
import GRDB

/// 把导入的文件真的**送进处理链**(PRD §4.1.5)。
///
/// ## 在这之前它是个预览器
///
/// `ImportView` 真解码、真跑 Silero、真列出「切成几场」——**然后什么都不做**。
/// 全文件搜不到 `dbQueue` / `SessionBridge` / `TaskQueue`。
/// 而导入是 M1 出口项:一个只会告诉你「这个文件有 3 场」的屏,
/// 和没有导入功能的差别只在用户多花了两分钟。
///
/// ## 🔴 为什么要写成「和录音一模一样的块 + 账本」
///
/// 下游每一步都从**账本**问「这一场的音频在哪」
/// (`ProcessingPump.blocks(of:)` → `recordings/<day>/ledger.jsonl`)。
/// 给导入另开一条「音频在哪」的路,就是第二个真相源 —— 而上传、转写、冻结、
/// 跳原话、认人取段五处都要读它,五处迟早有一处只认得其中一条。
///
/// 所以导入做的事是:**把文件切成和录音同规格的块,写进同一个目录,记进同一本账**。
/// 之后整条链一行代码都不用改。
///
/// ## 归到哪一天
///
/// 归到**文件自己的日期**(创建时间,取不到退回修改时间,再退回「现在」),
/// 不是导入的那一天。导入一段上周的会议,它属于上周 —— 归到今天会让
/// 首页说「今天开了三场会」,而那三场是一年前录的。
///
/// ⚠️ 退回「现在」时用户会看到它归在今天,**这一点要在界面上说出来**
/// (`Outcome.day` 带出去就是为了这个)。
enum ImportIngest {

    /// 一块最长多久。与录音的名义块长同一个数 —— 转写按块收费,
    /// 两条来路用不同的块长会让成本模型对不上。
    static let blockSeconds: Double = 300

    struct Outcome: Equatable {
        let sessionIDs: [Int64]
        let blocks: Int
        /// 这些场次被归到了哪一天(`sessions.day`)。界面要说出来。
        let day: String
        /// 文件自己的日期取不到,退回用了「现在」。**界面必须如实告诉用户。**
        let dateWasGuessed: Bool
    }

    enum Failure: Error, CustomStringConvertible {
        case exportFailed(block: Int, String)
        case noSegments

        var description: String {
            switch self {
            case .noSegments: return "这个文件里没有可以成场的片段,没什么可导入的"
            case .exportFailed(let b, let m): return "第 \(b) 块切不出来:\(m)"
            }
        }
    }

    /// - Parameter segments: `AudioImport.segments(of:vad:)` 的产物。
    static func ingest(url: URL, segments: [AudioImport.Segment],
                       now: Date = Date(),
                       in db: DatabaseQueue) async throws -> Outcome {
        guard !segments.isEmpty else { throw Failure.noSegments }

        let (recordedAt, guessed) = fileDate(of: url, fallback: now)
        let day = dayKey(recordedAt)
        let dir = RecordingPaths.audioDir(day: day, source: SessionSource.imported)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")

        // 🔴 **块号接着账本往下走,不从 0 起。**
        // 目录按天分,块文件名是 `block-%04d.m4a` —— 从 0 起会**覆盖掉**
        // 那一天已有的块(录音那边 2026-08-10 真机踩过一次:第一场被第二场盖了)。
        var seq = RecordingKernel.nextBlockSeq(ledgerURL: ledgerURL)
        let asset = AVURLAsset(url: url)
        var written = 0

        for seg in segments {
            let segStart = recordedAt.addingTimeInterval(seg.startSeconds)
            // 🔴 **来源打在开场那条上**(`M2-审6`)。账本是录音与导入共用的一本
            // (`M1-15c` 刻意如此:音频在哪只能有一个真相源),所以「这一场是谁写的」
            // 必须**跟着条目走**,否则读的人只能猜 —— 而两个读者猜的不一样,
            // 同一场就落两行,同一段音频转写两次。
            try BlockLedger.append(
                LedgerEntry(at: segStart, mark: .sessionStarted,
                            source: SessionBridge.Source.imported), to: ledgerURL)

            var offset = 0.0
            while offset < seg.durationSeconds {
                let length = min(blockSeconds, seg.durationSeconds - offset)
                let fileName = String(format: "block-%04d.m4a", seq)
                try await exportBlock(
                    asset: asset,
                    from: seg.startSeconds + offset, seconds: length,
                    to: dir.appendingPathComponent(fileName), seq: seq)

                // ⚠️ 账本里的两个墙钟戳是**下游算块内偏移的依据**
                // (`BlockTiming.offsets` / `LineAudio`),必须和真切出来的那段对齐。
                try BlockLedger.append(LedgerEntry(block: BlockRecord(
                    seq: seq,
                    startedAt: segStart.addingTimeInterval(offset),
                    endedAt: segStart.addingTimeInterval(offset + length),
                    // 是按固定块长切的,不是按静音切点 —— 如实记 true
                    // (同录音里「时间到了硬切」那一档)。
                    hardCut: true, fileName: fileName)), to: ledgerURL)
                seq += 1
                written += 1
                offset += length
            }

            try BlockLedger.append(
                LedgerEntry(at: segStart.addingTimeInterval(seg.durationSeconds),
                            mark: .sessionEnded), to: ledgerURL)
        }

        // 账本 → `sessions`。**走 SessionBridge,不自己 INSERT** ——
        // 那张表的写方只有它一个(幂等靠 `(source, started_at)` 唯一索引)。
        //
        // ⚠️ **整本同步是对的,别改成「只同步本次导入的那几场」**(`M2-审6`)。
        // 从前它错在把整本**都按 `import` 写**,而不是错在读了整本 ——
        // 现在每条 summary 自带来源,整本同步反而是**幂等且自愈**的:
        // 当天已有的录音场次照样按 `recording` 落,不会被这次导入改掉来路。
        let entries = try BlockLedger.read(from: ledgerURL).entries
        let all = BlockLedger.sessions(entries: entries)
        try SessionBridge.sync(all, day: day, in: db)

        // 入队。**收尾即入队**,与录音同一条口径(PRD §2.1 拍板:不再问第二次)。
        let mine = Set(segments.map { SessionBridge.iso(recordedAt.addingTimeInterval($0.startSeconds)) })
        let ids = try await db.read { d in
            try Int64.fetchAll(d, sql: """
                SELECT id FROM sessions WHERE source = ? AND day = ?
                """, arguments: [SessionBridge.Source.imported, day])
                .compactMap { $0 }
        }
        let iso = ISO8601DateFormatter.growth.string(from: now)
        var enqueued: [Int64] = []
        for id in ids {
            let startedAt = try await db.read { d in
                try String.fetchOne(d, sql: "SELECT started_at FROM sessions WHERE id = ?",
                                    arguments: [id])
            }
            // 只排本次导入的那几场 —— 同一天导过两次时,上次那些早就排过了。
            guard let startedAt, mine.contains(startedAt) else { continue }
            try ProcessingOrchestrator.enqueueSession(id, now: iso, in: db)
            enqueued.append(id)
        }

        ProcessingEvents.record(
            trigger: .foreground,
            outcome: "导入 \(url.lastPathComponent):\(enqueued.count) 场 · \(written) 块",
            detail: "归到 \(day)\(guessed ? "(文件没带日期,用的是今天)" : "") · "
                  + "与录音同一条链路(同目录、同账本、同队列)。", in: db)

        return Outcome(sessionIDs: enqueued, blocks: written, day: day, dateWasGuessed: guessed)
    }

    // MARK: - 切一块

    private static func exportBlock(asset: AVURLAsset, from start: Double, seconds: Double,
                                    to dest: URL, seq: Int) async throws {
        // 重跑要能覆盖 —— 导入失败重来一次是常态,残留的半个文件比没有更糟。
        try? FileManager.default.removeItem(at: dest)
        guard let session = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.exportFailed(block: seq, "这个文件不能导成 m4a")
        }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: seconds, preferredTimescale: 600))
        do {
            try await session.export(to: dest, as: .m4a)
        } catch {
            throw Failure.exportFailed(block: seq, "\(error)")
        }
        // **回读一次**:export 不抛不等于文件在。「以为写了其实没写」会让
        // 这一场一路走到「一块音频都没有」并被标死,而那时已经查不到是哪一步丢的。
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw Failure.exportFailed(block: seq, "导完了但文件不在盘上")
        }
    }

    // MARK: - 日期

    private static func fileDate(of url: URL, fallback: Date) -> (Date, guessed: Bool) {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        if let v = try? url.resourceValues(forKeys: Set(keys)),
           let d = v.creationDate ?? v.contentModificationDate {
            return (d, false)
        }
        return (fallback, true)
    }

    static func dayKey(_ d: Date) -> String { BlockLedger.dayKey(d) }
}

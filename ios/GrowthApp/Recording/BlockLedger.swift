import Foundation

// 落盘块账本(§3.1.6「恢复时从落盘块重建场次状态机」)。
//
// **为什么是文件不是数据库表**:§3.1.6 明写「落盘分段…它是**文件单位**」,
// §3.1.2 的 DDL 里也没有 blocks 表。契约由文档定,这里不擅自造一张跨消费方的表。
// 形态照 `mac/enroll_ledger.py` 的追加式账本,连「坏账本拒绝当空账跑」这条也照搬。
//
// **账本要回答的唯一问题**:重开 App 时,上一次录音停在哪、用户以为在录而实际
// 没录到多久。§六 把这件事说死了 —— 中断未恢复或 App 被杀之后录音停止且系统
// **不会自动重启它**,空洞一直持续到用户下次打开 App,**不是「最多丢一段」**。

/// 一个落盘块。时间戳是墙钟时间 —— 空洞算的是「用户以为在录的那段真实时间」,
/// 音频内部时间轴不参与。
struct BlockRecord: Equatable, Codable {
    let seq: Int
    let startedAt: Date
    let endedAt: Date
    /// 切点没落在静音处(§3.1.6)。U6b 接入端侧 VAD 之前恒为 true。
    let hardCut: Bool
    let fileName: String
}

/// 账本的一行。`kind` 是 `SessionMark` 的 rawValue,或 `"block"`。
struct LedgerEntry: Equatable, Codable {
    let at: Date
    let kind: String
    let block: BlockRecord?

    /// 这一场是**谁写进来的**:录音还是导入(`SessionBridge.Source` 的闭集)。
    ///
    /// 🔴 **只打在 `sessionStarted` 上,而且只有导入会打**(`M2-审6`,2026-08-24)。
    ///
    /// 在这个字段之前,来源是**由谁在读决定**的:`ImportIngest` 读整本账本
    /// 全按 `import` 同步,`RecordingViewModel.syncToDatabase` 读同一本
    /// 全按 `recording` 同步 —— 同一场因此在 `sessions` 里落两行
    /// (唯一索引是 `(source, started_at)`,挡不住)。而 `blocks(of:)` 只按
    /// `started_at` 找块,两行指向**同一批块** ⇒ 同一段音频转写两次,**真花两笔钱**。
    ///
    /// ⚠️ **可选,而且 nil 不编码** —— 录音写出来的账本一个字节都不变,
    /// 老账本也照常读得出来(nil 读成 `recording`,见 `SessionSummary.source`)。
    let source: String?

    init(at: Date, mark: SessionMark, source: String? = nil) {
        self.at = at; self.kind = mark.rawValue; self.block = nil; self.source = source
    }
    init(block: BlockRecord) {
        self.at = block.endedAt; self.kind = LedgerEntry.blockKind
        self.block = block; self.source = nil
    }

    static let blockKind = "block"
}

/// 重开 App 时给用户看的那句话所需要的全部事实。
struct RelaunchReport: Equatable {
    /// 上次是正常收尾的(用户按了结束)。
    let cleanShutdown: Bool
    /// **用户以为在录、实际没录到**的总时长。已经扣掉用户自己按的暂停。
    let gapMs: Int
    /// 最后一块的序号;一块都没落盘就是 nil。
    let lastBlockSeq: Int?
    /// 上次停在用户自己按的暂停上。文案要说「你暂停了录音」,不能说「录音被打断了」——
    /// 把用户的主动操作报成异常,几次之后这条提示就没人看了。
    let endedWhilePaused: Bool
}

extension RelaunchReport {
    /// 重开时给用户看的那句话。手机与手表共用(W1 前在 `RecordingViewModel` 里)。
    ///
    /// 文案由报告的三种形态决定。**三种必须说不同的话**:
    /// 正常收尾 / 你自己暂停了 / 录音被打断了。都说成「中断过 N 分钟」的话,
    /// 用户主动按的暂停会被报成故障,几次之后这条提示就没人看了。
    var noticeText: String? {
        if cleanShutdown { return nil }
        if endedWhilePaused {
            return "上次你暂停了录音,之后 App 退出了。这段时间没有录。"
        }
        guard gapMs > 0 else { return nil }
        let minutes = max(1, Int((Double(gapMs) / 60000).rounded()))
        // 🔴 **不许说「已重新开始」**(`M2-审5`,2026-08-24)。
        // `checkRelaunchGap` 从来不调 `start()` —— 它只算空洞、给上一场补收尾。
        // 说「已重新开始」是在断言一件没发生的事,而这条横幅**不自动消失**,
        // 用户信了它就一路不录。⚠️ 前提与结论写在一起:哪天真做了自动恢复,
        // 改这句话之前先确认 `start()` 在这条路径上被调用了,而且是**起成功之后**才说。
        return "录音中断过约 \(minutes) 分钟,当前未在录音,请重新开始。"
    }
}

enum LedgerError: Error, Equatable, CustomStringConvertible {
    case corruptLine(lineNumber: Int, raw: String)
    case entriesOutOfOrder(index: Int)
    case emptyLedger

    var description: String {
        switch self {
        case .corruptLine(let n, let raw):
            return "账本第 \(n) 行解不开:\(raw.prefix(80)) —— "
                 + "中间的行坏了不能跳过,跳过等于少算一段空洞,而少算出来的结果看着完全正常"
        case .entriesOutOfOrder(let i):
            return "账本第 \(i) 条的时间早于前一条 —— 这是上游的缺陷,不在这里悄悄重排"
        case .emptyLedger:
            return "账本是空的 —— 场次开始时那条记录没写进去,"
                 + "此刻**不能**报「一切正常」,那正好是事实的反面"
        }
    }
}

enum BlockLedger {

    /// 一天一个目录,目录名就是这个(与 `sessions.day` 同口径)。**全仓只有这一份**:
    /// 录音、导入、保留期、手表都调它(W1 之前是四份各写各的)。
    ///
    /// ⚠️ 钉死公历 + POSIX(W1 对抗审查):不钉的话跟着系统日历走,设成佛历的设备
    /// `yyyy` 出来是 2569 —— 目录名错年,保留期按字符串比 `day < cutoff` 也跟着错。
    /// 手表算出来的 `day` 要和手机对得上,这已经是跨设备契约。时区仍跟系统(用户看到的那一天)。
    static func dayKey(_ d: Date) -> String {
        dayFormatter().string(from: d)
    }

    /// 同一契约的反向解析。首页日期筛选也复用它,不维护第二份格式串。
    static func date(forDayKey key: String) -> Date? {
        let f = dayFormatter()
        guard let d = f.date(from: key), f.string(from: d) == key else { return nil }
        return d
    }

    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    // MARK: - 读写

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    /// 追加一行。追加式:已经写下的永不改写,和判断库同一条纪律。
    ///
    /// 🔴 **追加前先切掉没写完的半行**(W1 对抗审查,2026-10-12)。
    /// 进程被杀在 append 中途会留下一截不带换行的尾巴 —— `read` 本来就把它当作
    /// 「那件事没发生」丢掉。不切的话新行粘在它后面,成了一整行坏行:
    /// 这次被当尾巴丢掉(刚补的收尾等于没补),下次追加后落到中间,整本账抛错。
    /// 切掉的只是一条**从未成立过**的记录,与 `read` 的口径完全一致,不算改写历史。
    static func append(_ entry: LedgerEntry, to url: URL) throws {
        var line = try encoder.encode(entry)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let h = try FileHandle(forUpdating: url)
            defer { try? h.close() }
            let end = try h.seekToEnd()
            if end > 0 {
                try h.seek(toOffset: end - 1)
                if h.readData(ofLength: 1) != Data([0x0A]) {
                    // 往回找最后一个换行;一个都没有 = 整个文件就是那半行。
                    try h.seek(toOffset: 0)
                    let all = h.readDataToEndOfFile()
                    let keep = all.lastIndex(of: 0x0A).map { UInt64($0 + 1) } ?? 0
                    try h.truncate(atOffset: keep)
                }
                try h.seekToEnd()
            }
            try h.write(contentsOf: line)
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: url, options: .atomic)
        }
    }

    /// 读账本。返回条目与「尾行是否被截断」。
    ///
    /// **最后一行解不开是正常的,中间的行解不开不是。** App 被 jetsam 杀掉时,
    /// 最后那次 append 可能只写了一半 —— 丢掉半行不影响任何结论(那条记录对应的
    /// 事件本来就没完成)。但中间的行坏掉意味着文件被别的东西破坏了,
    /// 此时跳过它会少算一段空洞,而少算出来的报告看着完全正常 —— 必须炸。
    static func read(from url: URL) throws -> (entries: [LedgerEntry], truncatedTail: Bool) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var entries: [LedgerEntry] = []
        var truncatedTail = false

        for (i, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(LedgerEntry.self, from: data) else {
                if i == lines.count - 1 { truncatedTail = true; break }
                throw LedgerError.corruptLine(lineNumber: i + 1, raw: String(line))
            }
            entries.append(entry)
        }
        return (entries, truncatedTail)
    }

    // MARK: - 空洞

    /// 纯函数,不碰文件 —— 好让这套算术能单独被构造的时间戳打(本任务验收)。
    ///
    /// 算法就一句话:**「用户以为在录」的区间,减去「真落了盘」的区间**。
    ///
    /// · 意图区间由 `sessionStarted` / `resumed` 打开,由 `paused` / `sessionEnded` 闭合。
    /// · `interrupted` **刻意不闭合意图区间** —— 系统中断恰恰就是「用户以为在录、
    ///   实际没在录」的那段,它是空洞的主要来源,闭合了就等于把它算没了。
    /// · 走到末尾仍未闭合 = 死在录音中,用 `now` 闭合:空洞一直持续到此刻。
    /// · 覆盖区间用块的墙钟起止。**没落盘的那截尾巴不算覆盖** —— 它确实丢了。
    ///
    /// 只用「最后一块的块尾」减一下是不够的:用户中途暂停过的话,暂停时长会被
    /// 算进空洞,于是提示「录音中断过 40 分钟」而其中 30 分钟是用户自己按的暂停。
    /// 报错的空洞和不报空洞一样坏,§六 要的是「**如实**提示」。
    static func relaunchReport(entries: [LedgerEntry], now: Date) throws -> RelaunchReport {
        guard let last = entries.last else { throw LedgerError.emptyLedger }
        for i in 1..<max(entries.count, 1) where entries[i].at < entries[i - 1].at {
            throw LedgerError.entriesOutOfOrder(index: i)
        }

        var intended: [(start: Date, end: Date)] = []
        var open: Date?
        var blocks: [BlockRecord] = []

        for e in entries {
            switch e.kind {
            case SessionMark.sessionStarted.rawValue, SessionMark.resumed.rawValue:
                if open == nil { open = e.at }
            case SessionMark.paused.rawValue, SessionMark.sessionEnded.rawValue:
                if let o = open { intended.append((o, e.at)); open = nil }
            case LedgerEntry.blockKind:
                if let b = e.block { blocks.append(b) }
            default:
                break   // interrupted:不闭合,见上面注释
            }
        }
        if let o = open { intended.append((o, now)) }

        let covered = merge(blocks.map { ($0.startedAt, $0.endedAt) })
        var gap: TimeInterval = 0
        for span in intended {
            gap += max(0, span.end.timeIntervalSince(span.start)) - overlap(span, covered)
        }

        return RelaunchReport(
            cleanShutdown: last.kind == SessionMark.sessionEnded.rawValue,
            gapMs: Int((max(0, gap) * 1000).rounded()),
            lastBlockSeq: blocks.map(\.seq).max(),
            endedWhilePaused: last.kind == SessionMark.paused.rawValue)
    }

    // MARK: - 今天录了什么

    /// 一场录音的概览。给界面用 —— 点完「结束」总得看见自己刚录了什么。
    struct SessionSummary: Equatable {
        let startedAt: Date
        let endedAt: Date?
        /// **这一场自己的块。**
        ///
        /// ⚠️ 2026-08-17 补。原来这里只有 `blockCount`,块清单被丢掉了 ——
        /// 于是上传层只能退而求其次「读整个账本、把当天所有块都算成这一场的」。
        /// 真机实测的后果:一天录三场,每一场都上传了当天全部 4 个块,
        /// 12 次上传对应 4 个音频文件;**再往下走就是 12 次转写,而转写按块收费**。
        /// 账本里本来就有场次边界,只是没被带出来。
        let blocks: [BlockRecord]
        /// 真正录到的时长(块时长之和),不是首尾之差 —— 暂停与中断不算。
        let recordedSeconds: TimeInterval

        /// 这一场的来路(`SessionBridge.Source` 的闭集)。
        ///
        /// 🔴 **来自账本条目,不是来自谁在读**(`M2-审6`)。默认 `recording`
        /// 的理由不是「猜一个」:老账本没有这个字段,而那些条目**本来就是
        /// `syncToDatabase` 按 `recording` 写进库的** —— 读成 `recording`
        /// 才是复述既有事实,读成别的会凭空改写历史。
        let source: String

        var isOpen: Bool { endedAt == nil }
        var blockCount: Int { blocks.count }

        init(startedAt: Date, endedAt: Date?, blocks: [BlockRecord],
             recordedSeconds: TimeInterval,
             source: String = SessionSource.recording) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.blocks = blocks
            self.recordedSeconds = recordedSeconds
            self.source = source
        }
    }

    /// 把账本切成一场一场。
    ///
    /// ⚠️ 一个目录一天,一天可能录**很多场**(§1.2 ② 粗切场次)。
    /// 只看最后一条会把今天早上那场当成不存在。
    static func sessions(entries: [LedgerEntry]) -> [SessionSummary] {
        var out: [SessionSummary] = []
        var start: Date?
        var blocks: [BlockRecord] = []
        // 这一场开场那条打的来源。没打 ⇒ 老账本或录音 ⇒ `recording`(见 `SessionSummary.source`)。
        var source = SessionSource.recording

        func close(_ end: Date?) {
            guard let s = start else { return }
            out.append(SessionSummary(
                startedAt: s, endedAt: end, blocks: blocks,
                recordedSeconds: blocks.reduce(0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) },
                source: source))
            start = nil; blocks = []
            source = SessionSource.recording
        }

        for e in entries {
            switch e.kind {
            case SessionMark.sessionStarted.rawValue:
                // 上一场没收尾就先结掉,别把两场并成一场。
                //
                // ⚠️ **收尾时间不能填 nil。** `isOpen == (endedAt == nil)`,填 nil
                // 就是在说「那一场还在录」——而后面又开了一场,它显然已经结束了。
                // 2026-08-13 真机实测:App 崩了三次,库里就留下 5 条 `status=recording`
                // 的僵尸场次(证据:设备上的 growth.sqlite),首页做出来会显示成
                // 5 条「正在录音」,而一条都不在录。
                //
                // 填什么才诚实:**最后一个块的结束时刻** —— 那是我们最后一次有证据
                // 证明它还在录。一个块都没有的场次说明它什么都没录到,用起点收口,
                // 长度为零,如实呈现「开了但没录上」。
                close(blocks.last?.endedAt ?? start)
                start = e.at
                // ⚠️ **必须在 `close` 之后取。** `close` 用的是上一场的来源,
                // 先赋值就会把这一场的来路记到上一场头上。
                source = e.source ?? SessionSource.recording
            case SessionMark.sessionEnded.rawValue:
                close(e.at)
            case LedgerEntry.blockKind:
                if let b = e.block { blocks.append(b) }
            default:
                break
            }
        }
        close(nil)
        return out
    }

    private static func merge(_ spans: [(Date, Date)]) -> [(start: Date, end: Date)] {
        var out: [(start: Date, end: Date)] = []
        for s in spans.sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, s.0 <= last.end {
                out[out.count - 1].end = max(last.end, s.1)
            } else {
                out.append((s.0, s.1))
            }
        }
        return out
    }

    private static func overlap(_ span: (start: Date, end: Date),
                                _ merged: [(start: Date, end: Date)]) -> TimeInterval {
        merged.reduce(0) { sum, c in
            let lo = max(span.start, c.start), hi = min(span.end, c.end)
            return sum + max(0, hi.timeIntervalSince(lo))
        }
    }
}

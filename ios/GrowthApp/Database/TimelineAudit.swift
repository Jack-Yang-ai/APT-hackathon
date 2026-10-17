import Foundation
import GRDB

/// 时间轴体检:**转写行落在场次之外**这件事,现在有东西会发现它。
///
/// ## 为什么需要它 —— 前提与结论写在一起(仓规 6)
///
/// 2026-08-18 从真机拉数据时**偶然**撞见:7 场里有 6 场的转写行落在一个不存在的
/// 时刻上,偏移精确等于 `块号 × 300 秒`。那是 `M1-13a` 修掉的
/// `blockSeq * 300_000` 硬编码在**修复之前**落下的存量脏数据 —— 不是新 BUG。
///
/// 🔴 **真正的缺口不是那 6 场,是没有任何东西会发现它们。**
/// 那次是「不是专门去查的」才撞见的;BUG 修了,而**同一形状的下一次**仍然只能靠撞。
/// 因为这种错法**运行时什么都不发生**:exit code 全绿、行数在涨、卡片说「好了」,
/// 只有跳原话时跳到一段空白 —— 而那一刻没人会想到是时间轴。
/// 仓规 §3.2「失败必须可见」管的是**运行时的失败**,这里根本没有失败,
/// 这是本仓最贵的那一种:**成功地写进了错的地方**。
///
/// 所以这里补的是铁律 4 要的那道**能自动跑的对撞**:
/// 场次自己说它录了多久(`sessions.started_at` / `ended_at`),
/// 转写行自己说它落在哪(`transcript_lines.t_end_ms`,场次内绝对毫秒)——
/// 两处本该一致,对不上而没人报错,就是这一条要堵的缝。
///
/// ⚠️ 它是**照后视镜的**:只发现已经落错的,挡不住下一次落错。
/// 挡住落错是 `ProcessingPump.assemble` 那边的事(它现在从账本取真值)。
enum TimelineAudit {

    // MARK: - 判据

    /// 允许的溢出:**10 秒**。行的最大 `t_end_ms` 超过场次时长 10 秒以上才算问题。
    ///
    /// ### 上界:实测最小的真脏数据是 **274 秒**
    ///
    /// ⚠️ ~~「最小一例是某场次,溢出 116 秒」~~ **那句是错的,2026-08-18 真机实测推翻。**
    /// 它把板上那张表里的「行落在 300 秒」当成了 `MAX(t_end_ms)`,而那一列记的是
    /// **偏移量**(首行落点);真正的 `MAX(t_end_ms)` 是 458 秒 ⇒ 溢出 **274 秒**。
    /// 结论(10 秒)不变而且余量更大,但前提换了,按仓规 6 一起重写而不是只改数字。
    ///
    /// 真机 7 场实测(`growth.sqlite`,SQL 与本文件的 `graceMs` 都从源码抽取、未手抄):
    /// 六场脏数据溢出 274 / 434 / 1495 / 1800 / 2633 / 3226 秒,**全部报出**;
    /// 修复之后处理的某场次 溢出 **−29 秒**(行结束早于场次结束),**放过**。
    ///
    /// 「块是 300 秒粒度,所以宽限给 300 秒」仍然是个该避开的推理 ——
    /// 300 秒会把 274 秒那一例漏掉,而它恰恰是最像正常的那一例。
    ///
    /// 🔴 **这次实测只证了上界,没证下界。** 唯一那场健康数据的溢出是**负的**,
    /// 所以「合法的正向溢出有多大」在真机上仍然是零样本 —— 下面那三条依据
    /// 至今全是读代码推出来的。攒到第二场修复后的场次时回来看一眼。
    ///
    /// ### 下界:合法的溢出是**秒级**的
    ///
    /// 三处合法来源,都不是猜的:
    /// 1. **ASR 报的末句会压过音频真实结尾。** `ProcessingPump.keptIntervals`
    ///    已经为它显式留了余量(`maxLineEndMs > total` 时把最后一段拉长),
    ///    那里写的原因是「送检音频的时长与我们这边算的不会一模一样
    ///    (编码器按帧收尾),差几十毫秒是正常的」。
    /// 2. **时长本身有约 ±1 秒的量化误差。** `started_at` / `ended_at` 是
    ///    `.withInternetDateTime` 的**秒粒度** ISO 串(没有小数秒),两头各截断一次;
    ///    而 `t_end_ms` 是从账本里**全精度**的场次起点量出来的。两把尺子不一样。
    /// 3. **`ended_at` 有时就等于最后一个块的结束时刻**,一点缓冲都没有:
    ///    上一场没收尾就被下一场顶掉时,`BlockLedger.sessions` 填的是
    ///    `close(blocks.last?.endedAt ?? start)` —— 此时第 1 条的溢出直接顶到时长之外。
    ///
    /// ### 为什么偏向宽松而不是偏向严格
    ///
    /// 误报**不是免费的**:用户照着报告点「重整」,`SessionMaintenance.refreeze`
    /// 会落一版新的转写,而它的注释写明「旧版产出的纪要不会自动跟过来,新版要重新抽」——
    /// **重新抽是要花钱的**。所以一个 1.8 秒的溢出该被咽下去,不该变成一条待办。
    ///
    /// 10 秒:比合法溢出大一个数量级,比最小的真脏数据小一个数量级,两边都留着余量。
    static let graceMs = 10_000

    /// 一场对不上的记录。
    struct Finding: Equatable {
        let sessionID: Int64
        /// 场次自己说的时长(`ended_at - started_at`),毫秒。
        let durationMs: Int
        /// 该场次生效那一版里,行的最大 `t_end_ms`(**场次内绝对毫秒**,§3.1.2)。
        let maxLineEndMs: Int
        /// 超出多少毫秒。**= `maxLineEndMs - durationMs`,没有减掉宽限** ——
        /// 给人看的要是「偏了多少」,不是「偏了多少还超出阈值多少」。
        ///
        /// ⚠️ 它**不等于**那个 BUG 的块偏移(`块号 × 300 秒`):场次自己的长度
        /// 吃掉了一部分。某场次 的块偏移是 300 秒,这里量到的是 116 秒。
        /// 拿它去反推「偏了几个块」会得到错的块号。
        let overshootMs: Int
    }

    /// 一次完整体检的结果。
    struct Check: Equatable {
        let findings: [Finding]
        /// **时长解析不出来 ⇒ 根本没被检查过**的场次。
        ///
        /// 它和「查过了没问题」必须分开报:两者在界面上都长成「不在问题名单里」,
        /// 而前者是「不知道」。仓规 §3.2 —— 校验丢掉的条目要计数并说出来,不能悄悄没了。
        let unauditable: [Int64]
    }

    // MARK: - 扫

    /// 量出来的三个数。`durationMs == nil` = 两个时间戳里至少有一个解析不出来。
    private struct Measured {
        let sessionID: Int64
        let durationMs: Int?
        let maxLineEndMs: Int
    }

    /// 一趟 SQL 量完所有场次。**`scan` 与 `check` 共用它** ——
    /// 各写一份 SQL 就是第二个真相源,而两份迟早在过滤条件上分家。
    ///
    /// ⚠️ **按 `(session_id, MAX(version))` 过滤,不按 `transcript_id`。**
    /// 超长场次会切成多个 part(§3.1.6),`TranscriptFreeze` 每冻结一个 part 就把
    /// `active_transcript_id` 指过去 ⇒ **它最终只指向最后一个 part**。
    /// 按它过滤的后果在这里比在别处更毒:最后一个 part 的行天然贴着场次结尾,
    /// 溢出算出来接近 0 ⇒ **每一场都判「没问题」,而这道检查看起来一直在跑**。
    /// 口径与 `SessionDetailProjection.activeTranscripts` 一致(`MAX(version)` 的全部
    /// part),也就是用户在逐字稿上真看到的那一版 —— 查的和看的必须是同一份。
    ///
    /// ⚠️ 占位行(`is_gap`)与墓碑行(`redacted`)**都算数**:
    /// 前者占着缺块那段真实时间(见 `HomeProjection` 取时长那段),
    /// 后者只换了文本、时间戳原样留着。把它们排除掉会让「缺最后一块」的场次
    /// 恰好躲过这道检查。
    private static func measure(in db: Database) throws -> [Measured] {
        try Row.fetchAll(db, sql: """
            SELECT s.id AS session_id,
                   -- 与首页卡的墙钟跨度同一个算法(`HomeProjection`):
                   -- `strftime('%s')` 的整数秒,不用 julianday(浮点会少算一分钟)。
                   -- 解析不出来时 strftime 返回 NULL,整个表达式就是 NULL ——
                   -- 那正是「量不了」,由 `check` 单独报出去。
                   (strftime('%s', s.ended_at) - strftime('%s', s.started_at)) * 1000
                        AS duration_ms,
                   MAX(l.t_end_ms) AS max_end_ms
              FROM sessions s
              JOIN transcripts t ON t.session_id = s.id
               AND t.version = (SELECT MAX(version) FROM transcripts
                                 WHERE session_id = s.id)
              JOIN transcript_lines l ON l.transcript_id = t.id
             -- 还在录的场次没有结束时刻,量不了,跳过。
             -- ⚠️ 这里判 `ended_at IS NULL` **不是拿副作用当判据**
             -- (`HomeProjection` 那条「用 status 不用 ended_at」说的是另一回事):
             -- 我们要的就是那个时间戳本身,没有它就没有比较的另一边。
             WHERE s.ended_at IS NOT NULL
             GROUP BY s.id
            """).map { row in
            Measured(sessionID: row["session_id"],
                     durationMs: (row["duration_ms"] as Int64?).map(Int.init),
                     maxLineEndMs: row["max_end_ms"])
        }
    }

    private static func judge(_ measured: [Measured]) -> [Finding] {
        measured.compactMap { m -> Finding? in
            // 量不出时长的**不是「没问题」**,是「没查」—— 由 `check` 报进 `unauditable`。
            guard let duration = m.durationMs else { return nil }
            let overshoot = m.maxLineEndMs - duration
            guard overshoot > graceMs else { return nil }
            return Finding(sessionID: m.sessionID, durationMs: duration,
                           maxLineEndMs: m.maxLineEndMs, overshootMs: overshoot)
        }
        .sorted { $0.sessionID < $1.sessionID }
    }

    /// 扫一遍,返回**行落在场次之外**的场次。纯读,不写任何东西。
    static func scan(in db: Database) throws -> [Finding] {
        judge(try measure(in: db))
    }

    /// 一次完整体检。**界面走这个,不直接走 `scan`。**
    ///
    /// 差别只有一处、但那一处是必须的:「时长解析不出来」的场次要**记一条事件**
    /// (仓规 §3.2:校验丢掉的条目不能悄悄没了),而记事件要一个写句柄 ——
    /// `scan(in: Database)` 只有只读的那个,给不了。
    static func check(in db: DatabaseQueue) throws -> Check {
        let measured = try db.read { try measure(in: $0) }
        let unauditable = measured.filter { $0.durationMs == nil }
            .map(\.sessionID).sorted()
        if !unauditable.isEmpty {
            ProcessingEvents.record(
                trigger: .foreground,
                outcome: "时间轴体检:\(unauditable.count) 场的时长解析不出来,**没查**",
                detail: "场次 \(unauditable) —— started_at / ended_at 里至少一个不是"
                      + "能解析的 ISO 串,没有这个数就没法判断行落在哪。"
                      + "它们不在问题名单里,但也不等于没问题。",
                in: db)
        }
        return Check(findings: judge(measured), unauditable: unauditable)
    }

    // MARK: - 修

    /// 逐场重整。**一场失败不中断其余场次** —— 6 场里第 2 场炸掉就不修后面 4 场的话,
    /// 用户下次进来看到的还是几乎同一份名单,而他刚刚点过一次「修」。
    ///
    /// ⚠️ **`.foreground` 是真值,不是省事 —— 前提与结论写在一起(仓规 6)。**
    /// 这条路只有一个入口:设置页那个按钮,用户当面点的。没有任何编排、
    /// 也没有 `BGProcessingTask` 会调 `repair`。
    /// 🔴 哪天有人把体检接进后台(比如「每天自己查一遍」),这一行**当场变成假话**:
    /// 事件表会说「你打开 App 才发现的」,而真相是凌晨后台发现的 ——
    /// 那时必须把 `trigger` 提成 `repair` 的入参往上传,而不是留着这一行。
    ///
    /// - Returns: `fixed` = 重整完**复查也过了**的;`failed` = 没修好的,连原因一起带回。
    static func repair(_ findings: [Finding], now: String, in db: DatabaseQueue)
        -> (fixed: [Int64], failed: [(Int64, String)]) {

        var reason: [Int64: String] = [:]
        var refrozen: [Int64] = []
        for f in findings {
            do {
                try SessionMaintenance.refreeze(sessionID: f.sessionID, now: now, in: db)
                refrozen.append(f.sessionID)
            } catch {
                // 原因原样带回(`SessionMaintenance.Failure` 的三条各自对应
                // 完全不同的处置),不吞成一句「没成功」。
                reason[f.sessionID] = "\(error)"
            }
        }

        // 🔴 **复查,不认「跑完了」。** 仓规 §3.3:验「落对没落对」,不验「跑没跑通」。
        // `refreeze` 返回成功只证明它冻出了新的一版,证明不了新那版的时间轴对得上:
        // 账本里这一场的块位置本身就歪的时候,它会**成功地再落一遍同样的错**,
        // 而调用方拿到的是一个 `RefreezeResult` —— 一路绿到用户下次再撞见。
        do {
            let stillBad = Set(try db.read { try scan(in: $0) }.map(\.sessionID))
            for id in refrozen where stillBad.contains(id) {
                reason[id] = "重整跑完了,行还是落在场次之外 —— "
                           + "多半是账本里这一场的块位置本身就不对,重整救不回来"
            }
        } catch {
            // 复查跑不成 ⇒ **不许声称修好了**。「不知道」要说成不知道。
            for id in refrozen {
                reason[id] = "重整跑完了,但复查这一步没跑成(\(error))—— 不能算修好"
            }
        }

        // 一场记一行。**失败那几场尤其**:`refreeze` 抛出来的时候它自己那条事件
        // 根本没走到,不在这里记就彻底没人知道。
        for f in findings {
            let stillBroken = reason[f.sessionID]
            ProcessingEvents.record(
                trigger: .foreground,
                outcome: "时间轴体检:场次 \(f.sessionID) "
                       + (stillBroken == nil ? "重整好了" : "没修好"),
                detail: "行落到 \(f.maxLineEndMs / 1000) 秒,而这一场只有 "
                      + "\(f.durationMs / 1000) 秒,超出 \(f.overshootMs / 1000) 秒"
                      + (stillBroken.map { " —— \($0)" } ?? ""),
                in: db)
        }

        let ids = findings.map(\.sessionID)
        return (fixed: ids.filter { reason[$0] == nil },
                failed: ids.compactMap { id in reason[id].map { (id, $0) } })
    }
}

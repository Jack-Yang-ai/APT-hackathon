import Foundation
import GRDB

/// 手机侧任务表(§1.3)。
///
/// 它替掉的是旧实现「已有任务在处理时新任务被跳过」的丢单行为——
/// 那种跳过是静默的,丢了单没人知道。这里每个任务都有行、有 attempts、有 last_error,
/// **失败留在表上看得见**,App 重启后从表恢复。
enum TaskQueue {

    /// 退避序列:1m / 5m / 15m / 30m,**封顶 30 分钟**。
    ///
    /// 🔴 **2026-08-19 改过,原为 1m / 5m / 30m / 2h 封顶 6h(§1.3 原文)。**
    /// 推翻它的是一次实测:08-18 两场录音的转写都因为一次网络抖动连炸 5 次,
    /// 于是躺进 6 小时封顶 —— 早上打开 App 看到的仍然是「失败」,
    /// 而那时网络已经好了几个小时(同一条路当天实测提交耗时 511–2432 ms)。
    ///
    /// **前提写在这里,别只留结论**:6 小时封顶成立的前提是「重试很贵」。
    /// 而这条链上的重试只是一次几百字节的 POST,失败时连上游都没碰到
    /// (云端账本当天 0 条 ASR 记账)—— 它不贵。真正贵的是**等**:
    /// M1 出口写着「结束录音到出稿 ≤10 分钟」,6 小时封顶让这句话不可能成立。
    ///
    /// 序列改成单调不降(原来的 30m→2h→回落 6h 是个台阶):越试越慢,封顶 30 分钟。
    static let backoffMinutes = [1, 5, 15, 30]
    static let backoffCapMinutes = 30

    /// 总期限:7 天 − 1 = 6 天(比音频保留期短一天,留最后一次人工机会)。
    static let deadlineMinutes = 6 * 24 * 60

    /// attempts 上限。**按 kind 分档 —— 因为「重试贵不贵」按 kind 不同。**
    ///
    /// ⚠️ §1.3 说「attempts 超上限 → dead」但**没给这个数**;给的是总期限 6 天。
    /// 传输腿由退避序列反推:前四次共 1+5+15+30 = 51 分钟,之后每次 30 分钟,
    /// (8640 − 51) / 30 = 286.3 → 再 286 次刚好把 6 天填满,合计 290。
    /// 真正的终态判据是**两条都算**:次数超上限,或总时长超期限。
    ///
    /// 🔴 **抽取腿单独一档,而且小得多(2026-08-19,对抗审查抓到)。**
    /// 上面那个 290 的论证是「这条链上的重试只是一次几百字节的 POST,
    /// 失败时连上游都没碰到 —— 它不贵」。**这句话对提交/轮询是真的,
    /// 对抽取是假的**:`ExtractionRunner.run` 先 `call`(花钱)再
    /// `parseModelOutput` / `validate`,而后两者抛出时什么都没落库
    /// ⇒ 去重不生效 ⇒ **下一次重试原价再买一次**。
    /// 模型输出不合法是**确定性**失败(同一份转写每次都触发),重试永远救不了。
    /// 按单次约 ¥0.025(32 分钟场)到 ¥0.094(3 小时场)算,290 次是 ¥7–27,
    /// 而一期红线是 **≤¥1.5/天**。
    ///
    /// 取 5:够熬过一次网络抖动(1+5+15+30+30 = 81 分钟),而最坏花掉约 ¥0.47。
    /// 判死之后用户会看见,并且可以手动重试 —— 那是**花钱的动作,本来就该由人点**。
    ///
    /// ⚠️ 这些数跟着 `backoffMinutes` / `backoffCapMinutes` 走 ——
    /// 改了退避而不改它们,「次数」与「期限」两条判据就对不上了
    /// (`ContentAndTaskTests.testDeadlineAlsoTerminates` 会红,那是故意的)。
    static let maxAttempts = 290
    static let maxAttemptsForPaidRetry = 5

    /// 这个 kind 的重试**每次都要花钱吗**。
    ///
    /// 判据写在这里而不是散在调用点:将来再加一条花钱的腿,加进这个集合即可,
    /// 而漏加的后果是它悄悄吃到 290 次的额度。
    ///
    /// 🔴 **`progress` 是 2026-08-24 补的,而漏加已经付过账**(`M2-审7`)。
    /// 上面那句「漏加的后果」写下来之后,`progress` 这条腿就是照着它漏的:
    /// `ProgressAttributionRunner.run` 先 `call`(花钱)再 `parse`,
    /// 与抽取一模一样的形状 —— 而它不在集合里 ⇒ 上限 290 次。
    /// 实测代价见 `M2-认7`:某场次 的 progress 任务 `attempts = 58`、
    /// **连崩 6 天**,期间每一拍都占一次 pump,而界面上只是「还在处理」。
    ///
    /// ⚠️ **判据是「失败会不会再买一次」,不是「这一步贵不贵」**:
    /// 提交/轮询那条链失败时连上游都没碰到,重试不花钱;
    /// 而 `call` 成功之后才解析/校验的腿,解析一抛就等于**原价再买一次**。
    /// 漏加不会有任何东西报错 —— 所以有一道源码对撞盯着它:
    /// `eval/checks/test_paid_retry_kinds.py`。
    static let paidRetryKinds: Set<String> = ["extract", "progress"]

    static func maxAttempts(forKind kind: String?) -> Int {
        paidRetryKinds.contains(kind ?? "") ? maxAttemptsForPaidRetry : maxAttempts
    }

    /// 第 n 次重试(n 从 1 开始)之后要等多久。
    static func backoff(afterAttempt n: Int) -> Int {
        guard n >= 1 else { return backoffMinutes[0] }
        return n <= backoffMinutes.count ? backoffMinutes[n - 1] : backoffCapMinutes
    }

    /// 从第 1 次到第 n 次重试累计等待的分钟数。
    ///
    /// ⚠️ **这是「退避序列的模型值」,不是真实耗时** —— 它只累加**等待**,
    /// 不含每一拍真正花掉的时间(网络 + 上游处理;长场次上一拍就是十几分钟)。
    /// ⇒ 判期限**不用它**,用 `created_at` 的差值(见 `stateAfterFailure`)。
    /// 留着它是因为 `maxAttempts = 290` 那个数就是从这个序列反推出来的,
    /// 而那条论证要能被重算。
    static func cumulativeMinutes(through n: Int) -> Int {
        (1...max(n, 1)).reduce(0) { $0 + backoff(afterAttempt: $1) }
    }

    /// 这次失败之后该进哪个态。
    ///
    /// **两条终态判据取先到的那条**:次数超上限,或**真实已经跑了多久**超总期限。
    /// 只看次数会在退避封顶后拖过音频保留期;只看时长会让次数无限涨。
    ///
    /// 🔴 ~~「用 `cumulativeMinutes(through: attempts)` 判期限」~~
    /// **2026-08-20 作废(M1-30 ③,对抗审查抓的)**,仓规 6:
    /// 那是**退避序列的模型值**,只累加等待、不含每一拍真实花掉的时间 ——
    /// 而长场次上一拍就是十几分钟。290 次的模型值是 **5.99 天**,
    /// **真实会显著晚于 6 天**。
    /// ⚠️ 而「6 天」这个数的**全部意义**就是「比音频保留期短一天,
    /// 留最后一次人工机会」—— 晚过去之后,音频先被清掉,
    /// **那条「最后的人工机会」根本不存在**,而任务表上什么都不会显示。
    ///
    /// - Parameter elapsedMinutes: 从 `created_at` 到现在的**真实**分钟数。
    ///   `nil` = 算不出来(`created_at` 读不出或解析不了)⇒ **只按次数判**,
    ///   并且**调用方要把这件事记出来**:静默退回模型值等于把这个 BUG 又藏回去。
    static func stateAfterFailure(attempts: Int, kind: String? = nil,
                                  elapsedMinutes: Int? = nil) -> String {
        if attempts >= maxAttempts(forKind: kind) { return "dead" }
        if let e = elapsedMinutes, e >= deadlineMinutes { return "dead" }
        return "retrying"
    }

    @discardableResult
    static func enqueue(kind: String, sessionID: Int64?, priority: Int = 1,
                        state: String = "queued", now: String,
                        in writer: some DatabaseWriter) throws -> Int64 {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (kind, session_id, attempts, next_retry_at, state, priority, created_at)
                VALUES (?, ?, 0, NULL, ?, ?, ?)
                """, arguments: [kind, sessionID, state, priority, now])
            return db.lastInsertedRowID
        }
    }

    /// 记一次失败:attempts + 1,算出下次重试时刻,超上限落 dead。
    ///
    /// `last_error` 一定写。失败原因不落盘的话,dead 的任务就只是一行「失败了」,
    /// 没人知道为什么——那跟静默丢单差不多。
    @discardableResult
    static func recordFailure(taskID: Int64, error: String, at: Date,
                              in writer: some DatabaseWriter) throws -> (state: String, nextRetryAt: String?) {
        try writer.write { db in
            // kind 一起取:上限按 kind 分档(花钱的腿额度小得多),
            // 而调用点不该为了这件事各自去查一次表 —— 那就是第二个出处。
            let row = try Row.fetchOne(db, sql: """
                SELECT attempts, kind, created_at FROM tasks WHERE task_id = ?
                """, arguments: [taskID])
            let attempts = (row?["attempts"] as Int? ?? 0) + 1
            // **真实跑了多久**,不是退避序列的模型值(M1-30 ③)。
            let elapsed = (row?["created_at"] as String?)
                .flatMap { ISO8601DateFormatter.growth.date(from: $0) }
                .map { Int(at.timeIntervalSince($0) / 60) }
            let state = stateAfterFailure(attempts: attempts, kind: row?["kind"] as String?,
                                          elapsedMinutes: elapsed)
            // 🔴 算不出真实耗时时**说出来**,不静默退回模型值 ——
            // 那样等于把 M1-30 ③ 这个 BUG 又藏回去,而表现是
            // 「这条任务比预期晚了半天才判死」,没有任何东西会报错。
            let elapsedNote = elapsed == nil
                ? "(⚠️ created_at 解析不了,期限只按次数判 —— 可能拖过音频保留期)" : ""
            let next = state == "dead"
                ? nil
                : iso(at.addingTimeInterval(Double(backoff(afterAttempt: attempts)) * 60))
            try db.execute(sql: """
                UPDATE tasks SET attempts = ?, state = ?, next_retry_at = ?, last_error = ?
                 WHERE task_id = ?
                """, arguments: [attempts, state, next, error + elapsedNote, taskID])
            return (state, next)
        }
    }

    /// 该捡哪一个:先看优先级(用户在等的 > 积压回补),再看到点没有。
    ///
    /// `waiting_network` 也要捡:它是「闸没放行」落的态(上传层的仅 Wi-Fi 开关),
    /// 不捡的话任务就搁死在表上 —— 用户连上 Wi-Fi 也不会自己动。
    /// 它不设 `next_retry_at`,所以网一回来这一轮就会被选中。
    static func nextRunnable(now: String, in reader: some DatabaseReader) throws -> Int64? {
        try reader.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT task_id FROM tasks
                 WHERE state IN ('queued', 'retrying', 'waiting_network')
                   AND (next_retry_at IS NULL OR next_retry_at <= ?)
                 ORDER BY priority ASC, task_id ASC LIMIT 1
                """, arguments: [now])
        }
    }

    /// 进程刚起来时,把「在跑」的任务捡回来。
    ///
    /// 🔴 **`running` / `uploading` 是死态,这是 2026-08-17 真机抓到的。**
    /// `nextRunnable` 只捡 queued / retrying / waiting_network,所以一个任务
    /// 只要在 `running` 上被打断(App 被杀、后台时间用完、崩溃),就**永远
    /// 再也捡不起来** —— 而任务表看起来一切正常,状态是「在跑」,像是在干活。
    /// 实测:三个转写任务全卡在 running、attempts=0、next_retry_at 为空。
    ///
    /// M1-4 的准入条件原文是「整条链路能从落盘状态恢复,不依赖 App 一直活着」。
    /// 少了这一步,那句话就是空的。
    ///
    /// **判据是「进程刚起来」,不是超时。** 进程刚起来的那一刻,按定义没有任何
    /// 任务正在跑 —— 于是不需要 `updated_at`(表里也没有这一列),
    /// 也不会误伤真在跑的任务。前提是同一时刻只有一个 pump 在推
    /// (见 `ProcessingPump` 的串行锁),否则这里会把并发跑着的任务打回去。
    ///
    /// **attempts 不加**:被打断不是失败。加了会把任务一路推向 dead,
    /// 而它其实一次都没真的失败过。
    ///
    /// ## 🔴 2026-08-24:「进程刚起来」这条判据**不够**,加了 `states:`
    ///
    /// 真机某场次 的 `transcribe` **在 `running` 上躺了四天**
    /// (`attempts = 0`、`next_retry_at` 为空 —— 一次都没失败过,只是没人捡)。
    /// 而这条补救只挂在 `didFinishLaunching` 上:**App 被系统留在后台、
    /// 一直没冷启动过,它就一次都不会跑**。
    ///
    /// ⚠️ 而用户对这种任务**没有任何可达的补救手段**:`retrySession` 只动
    /// `dead`/`degraded`,`releaseBackoff` 只动 `retrying` —— `running` 三个都不沾。
    /// 首页看到的就是永远的「整理中」。
    ///
    /// ⇒ `ProcessingPump` 每拍**拿到串行锁之后**也捡一次(见那边的调用点),
    /// 判据从「进程刚起来」放宽成「**这一拍是我在跑,那还挂着 `running` 的就是孤儿**」。
    ///
    /// - Parameter states: 捡哪些态。**每拍只捡 `running`**;`uploading` 留给启动那次 ——
    ///   后台 `URLSession` 的传输**在没有任何一拍在跑的时候照样在传**,
    ///   每拍把它打回 `queued` 会让一个正在成功上传的块被重新排队,而那是花钱的。
    @discardableResult
    static func reclaimInterrupted(states: [String] = ["running", "uploading"],
                                   now: String, in writer: some DatabaseWriter) throws -> Int {
        let marks = states.map { _ in "?" }.joined(separator: ",")
        return try writer.write { db in
            try db.execute(sql: """
                UPDATE tasks
                   SET state = 'queued', next_retry_at = NULL,
                       last_error = '上次没跑完就被打断了(App 退出 / 后台时间用完),已重新排队'
                 WHERE state IN (\(marks))
                """, arguments: StatementArguments(states))
            return db.changesCount
        }
    }

    /// 放行退避:让**用户在等的**、正在重试的任务立刻可捡。
    ///
    /// 退避是给「没人看着的时候别死命重试」用的。而用户把 App 打开、
    /// 或者点了「再试一次」,这两件事都明确地说了「我在等」——
    /// 这时还让他对着一个 30 分钟的计时器,是拿一条防上游过载的规矩
    /// 去挡一个已经在场的人。
    ///
    /// **attempts 不清零。** 它是「这条任务已经挣扎了多久」的账,也是
    /// 6 天总期限那条判据的一半;清零等于把期限重新计时,那样一条永远
    /// 好不了的任务只要用户多点几次就永远不会 dead。
    ///
    /// 只放行 `priority = 0`(用户在等的)。积压回补本来就该慢慢来。
    /// - Parameter sessionID: 只放行这一场;`nil` = 全部(用户把 App 拿到眼前)。
    @discardableResult
    static func releaseBackoff(sessionID: Int64? = nil, in db: Database) throws -> Int {
        try db.execute(sql: """
            UPDATE tasks SET next_retry_at = NULL
             WHERE state = 'retrying' AND priority = 0 AND next_retry_at IS NOT NULL
               AND (? IS NULL OR session_id = ?)
            """, arguments: [sessionID, sessionID])
        return db.changesCount
    }

    /// 同上,自己开事务的版本。**两个形态、一份 SQL** ——
    /// `retrySession` 在别人的事务里调,前台那一拍自己开事务。
    @discardableResult
    static func releaseBackoff(sessionID: Int64? = nil,
                               in writer: some DatabaseWriter) throws -> Int {
        try writer.write { try releaseBackoff(sessionID: sessionID, in: $0) }
    }

    /// 这一场的任务最近一次说了什么。→ (内部态, 原因)
    ///
    /// 🔴 **`last_error` 一直在写,而在此之前没有任何投影读它。**
    /// 「云代理还没配」「这一场一块音频都没有」「查询回了看不懂的报文」
    /// 三种原因在界面上塌缩成同一句话或一片灰 —— 用户既不知道发生了什么,
    /// 也就无从判断该等、该改设置、还是该重试。
    ///
    /// 取**最新那一行**:一场可能有上传/转写/抽取三个任务,而用户要问的是
    /// 「它现在卡在哪」,不是「历史上都失败过什么」(那在 `processing_events`)。
    static func lastWord(sessionID: Int64, in reader: some DatabaseReader) throws
        -> (state: String, reason: String?)? {
        try reader.read { db in
            try Row.fetchOne(db, sql: """
                SELECT state, last_error FROM tasks
                 WHERE session_id = ? ORDER BY task_id DESC LIMIT 1
                """, arguments: [sessionID])
                .map { ($0["state"] as String? ?? "?", $0["last_error"] as String?) }
        }
    }

    /// 内部态 → PRD §4.1.7 展示态。查的是映射表,不是代码里的 switch。
    static func displayState(forTaskState state: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT display_state FROM task_state_display WHERE state = ?",
                            arguments: [state])
    }

    /// 🔴 **必须用全仓唯一那个格式化器,不许在这儿再造一个。**
    ///
    /// 2026-08-17 真机抓到:这里原来是本地新建的 `ISO8601DateFormatter`,
    /// **没设 timeZone ⇒ 写的是 UTC**(`2026-08-17T04:00:13Z`),
    /// 而 `nextRunnable` 拿本地串(`2026-08-17T11:59:13+08:00`)去比,
    /// 且比的是**字符串**:`"04" < "11"` 恒成立 ⇒ **退避完全失效**。
    ///
    /// 后果不是「早了一点」,是整套节流塌掉:
    ///   · 失败的任务立刻又被捡起来,一拍 12 次全花在同一个任务上
    ///   · 真正该干的活(有声音的那几场的上传)一次机会都排不到 —— **队头阻塞**
    ///   · attempts 几分钟内烧到 27 上限,任务被判 `dead`,而它一次都没真的退避过
    ///
    /// `ISO8601DateFormatter.growth` 的注释里本来就写着这条会出事
    /// (「两处各写一个格式化器,写进库的串迟早不一样」)—— 而这里就是那第二处。
    private static func iso(_ d: Date) -> String {
        ISO8601DateFormatter.growth.string(from: d)
    }
}

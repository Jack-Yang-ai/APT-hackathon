import Foundation
import GRDB

/// 卡片产出器(`M3-B2`)。把 `CardTrigger` 的判定**落成库里的行**。
///
/// ## 🔴 判定不在这里 —— 这里只负责「落」
///
/// `CardTrigger.decide` 是判定的唯一实现(`M3-0b`,8 条测试钉着)。
/// 在这里再写一遍 `if 立场变了 { 出矛盾卡 }` 就是第二份判定,
/// 而两份漂了的表现是**同一件事一边出卡一边不出**,谁都不报错。
///
/// ## 🔴 排他性粗筛**算不出来**,所以 fail-closed 并记账
///
/// PRD §4.4.6 那张表把三条标准分得很清楚:
///
/// | 标准 | 校验方式 |
/// |---|---|
/// | 跨事复现 | **机械可判** |
/// | 能预测 | 抽样人工判 |
/// | 只属于他 | **prompt 约束 + 抽样盲测** |
///
/// ⇒「只属于他」**不是机械可判的**,产出器里没有任何办法算出它。
/// 那就**不算**:`exclusivityScreen` 返回 `nil` 表示「还没有判据」,
/// 这时**不出原则浮现卡**,并往 `card_drops` 记一笔。
///
/// ⚠️ **不许图省事传 `true`** —— 那会让「跨了 2 件事的口头禅」被立成原则,
/// 而不会有任何东西报错。也不许悄悄传 `false`:那样「粗筛没过」与
/// 「粗筛还没接上」在账上长得一样,而前者是结论、后者是缺口。
enum CardProducer {

    /// 一次产出的结果。**每个数都说出来** —— 只报「出了 N 张」的话,
    /// 「今天没什么可问」与「判定全被挡下」在这一行里长得一模一样。
    struct Outcome: Equatable {
        var emitted: [Int64] = []
        var dropped: [String: Int] = [:]
        var routedToDiscovery: Int = 0
        var appended: Int = 0
        /// 判定出了卡型、但**被 `M3-0f` 挡着不许落库**的条数。
        var blocked: Int = 0
    }

    /// 产出器的外部依赖。**都不给默认值** —— 默认值会把「还没接上」
    /// 伪装成一个具体结论(见类型注释里排他性那段)。
    struct Dependencies {
        /// 排他性粗筛。`nil` = **还没有判据**(不是「没过」)。
        let exclusivityScreen: (CardTrigger.StanceFact) -> Bool?
        /// 这条立场对应的对象(事)现在是什么状态。用来挡「已结案的事不再出卡」。
        ///
        /// ⚠️ **把当前连接传进去,不要让实现方自己再开一个。**
        /// 第一版签名是 `(String) throws -> String?`,实现方于是在
        /// 产出器的 `write` 里又开了一次 `read` ⇒ GRDB 当场
        /// `Database methods are not reentrant` 崩掉。
        /// 签名决定了调用方会怎么写 —— 拿不到连接,他就只能自己造一个。
        let matterState: (Database, String) throws -> String?
    }

    /// §5.3 学习闭环:同一卡型累计这么多次「这问题问得不对」⇒ **停止生成该类卡片**。
    ///
    /// 🔴 **「这问题问得不对」是用户能给提问质量的唯一直接反馈**(PRD §4.6.2)。
    /// 不接这道闸的话,那个按钮就是个装饰:点了有记录、有动画,而系统下周
    /// **一模一样地再问一遍** —— 比不给这个出口更伤,因为用户以为自己已经说过了。
    static let wrongQuestionDisableAt = 3

    /// 已被用户按掉的卡型。
    ///
    /// ⚠️ **口径:数「当前态是『问得不对』的卡」,不是 PRD §5.3 字面的「累计次数」**
    /// (对抗审查 2026-08-26 存疑 1,主模型定,待用户复核):undo 与**改判**都把
    /// 该卡移出计数 —— 用户后来把一张「问得不对」的卡答掉了(确认/先放着),
    /// 等于收回了「这问题不该问」这个反馈,该型可以复活。
    /// 若用户裁决要「累计不减」,改数 `judgments` 原始表并删下面那条 undo 测试。
    ///
    /// 🔴 **数 `judgment_current`,不数 `judgments`。** 判断库是 append-only,
    /// 撤销靠再写一条 undo(D1)。数原始表的话,用户撤销了那次「问得不对」,
    /// 计数**不会减回去** —— 而停用是不可见的:表现只是「这类卡再也没出现过」。
    static func disabledKinds(in db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: """
            SELECT c.kind
              FROM judgment_current jc
              JOIN judgments j ON j.id = jc.judgment_id
              JOIN cards c ON CAST(c.id AS TEXT) = jc.target_id
             WHERE jc.target_kind = 'card' AND j.action = ?
             GROUP BY c.kind HAVING COUNT(*) >= ?
            """, arguments: [Self.wrongQuestionAction, Self.wrongQuestionDisableAt]))
    }

    /// 反查,不写第二份字符串 —— 与 `CardStore` 同一个理由(铁律 4)。
    ///
    /// 🔴 **反查失败就崩,不许静默用旧拼写**(对抗审查 2026-08-26 建议改 1):
    /// 第一版兜底 `?? "card_wrong_question"` 恰恰是它声称不写的第二份字符串 ——
    /// `byAction` 重构后反查落空时,停用闸会拿旧拼写去查一个不存在的 action,
    /// **永远返回空集**:§5.3 静默失效,没有任何东西红。这里崩的话,
    /// 任何一条碰 `disabledKinds` 的测试都会当场把它揪出来。
    private static let wrongQuestionAction: String = {
        guard let key = CardQueueProjection.State.byAction
            .first(where: { $0.value == .wrongQuestion })?.key else {
            preconditionFailure("State.byAction 里没有 .wrongQuestion —— §5.3 停用闸失去唯一口径")
        }
        return key
    }()

    /// 落一条立场类事实的判定。
    ///
    /// - Returns: 这一条的处置。**调用方要把它累加起来报出去**。
    @discardableResult
    static func produce(stance: CardTrigger.StanceFact,
                        sameTopic records: [CardTrigger.StanceRecord],
                        objectKind: String, sessionID: Int64?,
                        body: String, quote: String?, lineID: Int64?,
                        now: String, deps: Dependencies,
                        into db: Database) throws -> Outcome {
        var out = Outcome()

        // 🔴 **排他性三态原样传给判定层,不在这里折。**
        // 折成 `screen ?? false` 的话,判定给的是「静默追加证据」——
        // 缺口连一笔账都没留下。2026-08-25 第一版就是这么写的,是测试逼出来的。
        let decision = CardTrigger.decide(stance: stance, sameTopic: records,
                                          exclusivityScreenPassed: deps.exclusivityScreen(stance))

        switch decision {
        case .appendEvidence:
            out.appended += 1

        case .drop(let reason):
            try recordDrop(reason.rawValue, topic: stance.topicKey, now: now, in: db)
            out.dropped[reason.rawValue, default: 0] += 1

        case .discovery:
            // 不出卡,交给发现层。**这一条也要能被数出来** ——
            // 否则「转给发现层了」与「什么都没发生」在账上一样。
            out.routedToDiscovery += 1

        case .card(let kind):
            // 🔴 **被 `M3-0f` 挡着的卡型:判定照出,落库挡住。**
            // 判定要现在就钉死(否则 0f 出数那天要重新推一遍),
            // 而出卡会真的打扰用户 —— 拿一个召回率未知的前提字段去问
            // 「你的前提变了吗」,问错的代价由用户承担。
            if CardTrigger.blockedPendingPremiseRecall.contains(kind) {
                out.blocked += 1
                return out
            }
            // §5.3:这一卡型已被用户按掉 ⇒ 整型不再生成。**记账,别静默**:
            // 「这类卡停用了」与「今天没什么可问」在界面上长得一模一样。
            if try Self.disabledKinds(in: db).contains(kind.rawValue) {
                let why = "卡型已停用(累计 \(Self.wrongQuestionDisableAt) 次「这问题问得不对」):\(kind.rawValue)"
                try recordDrop(why, topic: stance.topicKey, now: now, in: db)
                out.dropped[why, default: 0] += 1
                return out
            }
            // §4.6.4:指向的事已结案/已删 ⇒ 本来就不该再出。
            if objectKind == "事", let st = try deps.matterState(db, stance.matterID),
               st == "已结案" || st == "已合并" {
                try recordDrop("事已\(st),不再出卡", topic: stance.topicKey, now: now, in: db)
                out.dropped["事已\(st),不再出卡", default: 0] += 1
                return out
            }
            try db.execute(sql: """
                INSERT INTO cards (kind, object_kind, object_id, session_id, body, quote,
                                   line_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [kind.rawValue, objectKind, stance.matterID, sessionID,
                                 body, quote, lineID, now])
            out.emitted.append(db.lastInsertedRowID)
        }
        return out
    }

    /// §4.6.4:**事结案 / 被删 ⇒ 它名下还没处理的卡自动撤回**,不进推送队列。
    ///
    /// 🔴 **只撤没处理过的。** 已经处理过的卡撤掉,等于把用户的判断也一起抹了 ——
    /// 而 PRD §4.6.4 说的是「自动撤回,不进推送队列」,不是「删掉历史」。
    @discardableResult
    static func withdrawCards(forClosedMatter id: String, now: String,
                              in db: Database) throws -> Int {
        try db.execute(sql: """
            UPDATE cards SET withdrawn_at = ?
             WHERE withdrawn_at IS NULL AND object_kind = '事' AND object_id = ?
               AND NOT EXISTS (SELECT 1 FROM judgment_current jc
                                WHERE jc.target_kind = 'card'
                                  AND jc.target_id = CAST(cards.id AS TEXT))
            """, arguments: [now, id])
        return db.changesCount
    }

    private static func recordDrop(_ reason: String, topic: String?,
                                   now: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO card_drops (day, reason, topic_key, created_at)
            VALUES (?, ?, ?, ?)
            """, arguments: [String(now.prefix(10)), reason, topic, now])
    }
}

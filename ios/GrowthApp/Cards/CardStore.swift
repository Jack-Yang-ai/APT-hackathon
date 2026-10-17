import Foundation
import GRDB

/// 卡片写侧的真实现(`M3-B2`)。把 `CardWriting` 的七个动作落进**判断库**。
///
/// ## 🔴 为什么落判断库,而不在 `cards` 上加状态列
///
/// `CardQueueProjection.State` 已经写死了这条:态**全部从判断库派生**。
/// 在 `cards` 上再落一列 `state`,同一件事就有两个出处 ——
/// 而对不上时用户会看到**一张自己明明答过的卡又被问一遍**,谁都不报错。
///
/// ## 🔴 action 名反查 `State.byAction`,写侧不再写第二份字符串
///
/// 读侧靠 `byAction` 把 `card_accept` 映射成「已确认」。写侧要是自己敲一遍
/// `"card_accept"`,两处的拼写就各活各的 —— 写侧改成 `card_accepted` 之后
/// 读侧只会把它当成**没判断过**,于是这张卡照常再推一次。
/// 铁律 4:一件事两个出处,对不上时不会报错。
///
/// ## 🔴 判断不许落在看不见的对象上
///
/// `judgments.target_id` 是 TEXT,**没有指向 `cards` 的外键** —— 给一个不存在的
/// id 写判断会一路成功。而这条判断此后永远不会被任何界面读到:
/// 「用户确认过」在库里是真的,在产品里从没发生过。⇒ 写之前先核卡还在不在、
/// 有没有被撤回,两种情形分别抛,**不合并成一句「失败」**(撤回是正常的业务结局,
/// 不存在是调用方的 bug,处置不同)。
struct CardStore: CardWriting {

    let writer: any DatabaseWriter

    enum Failure: Error, CustomStringConvertible {
        case noSuchCard(Int64)
        case withdrawn(Int64)
        case notWired(String, why: String)
        /// 调用方把一个不是用户动作的态传进了写侧 —— 这是编程错误,不是业务结局。
        case notAUserAction(String)
        case emptyBody
        var description: String {
            switch self {
            case .noSuchCard(let id):   return "卡片 \(id) 不存在 —— 判断没有落点,拒绝写入"
            case .withdrawn(let id):    return "卡片 \(id) 已撤回(§4.6.4),不再接受判断"
            case .notWired(let a, let why): return "卡片的「\(a)」还没接上:\(why)"
            case .notAUserAction(let s): return "「\(s)」不是用户动作,没有对应的 action 名 —— 调用方 bug"
            case .emptyBody:            return "正文不能改成空 ——「改完即确认」+ 空正文 = 一张确认过的空卡"
            }
        }
    }

    // MARK: - 三类语义出口 + 轻出口

    func accept(card id: Int64, now: String) throws { try land(id, .accepted, now: now) }
    func decline(card id: Int64, now: String) throws { try land(id, .declined, now: now) }
    func hold(card id: Int64, now: String) throws { try land(id, .held, now: now) }
    func wrongQuestion(card id: Int64, now: String) throws { try land(id, .wrongQuestion, now: now) }

    /// 🔴 **仍然抛,而且这不是「还没排上」** ——
    /// PRD §4.7.5 写的是「点『追问』→ 卡片置顶为首条消息 → 多轮对话 → 用户结束 →
    /// **系统整理一句话结论生成收尾卡**」。收尾卡是**对话结束的产物**,
    /// 而对话(§4.7)整节不在 M3。
    ///
    /// ⚠️ 在这里写一条 `card_ask_back` 判断然后返回,就是**假装对话存在**:
    /// 界面上「追问」点得动、库里也记了一笔,而用户等的那个对话永远不会出现,
    /// 收尾卡也永远不会来。§3.2:桩必抛,不 no-op。
    func askBack(card id: Int64, now: String) throws {
        throw Failure.notWired("追问", why: "对话层(PRD §4.7)不在 M3;收尾卡由对话结束产生,不是点下去就有")
    }

    // MARK: - 就地可改

    /// 改系统写的那句话,**改完即确认**(PRD §4.6.2)。
    ///
    /// 🔴 **只碰 `body`。** `quote` 是冻结层引来的逐字原话,一个字都不许动 ——
    /// 「记,但不是这么记的」改的是系统的转述,不是他当时说的话。
    ///
    /// 🔴 **这条不吃幂等闸。** 下面四个出口「与当前态一致就不写」,而改正文
    /// 每次都是新内容:已经是「已确认」的卡再改一次正文,若因为态没变就不写判断,
    /// 判断库里那条 `card_accept` 就还指着**旧正文**,而审计链要答的正是
    /// 「他确认的是哪句话」。
    ///
    /// 🔴 **「改动前」跟着判断一起落**(对抗审查 2026-08-26 必须修 1):
    /// PRD §5.3 明写「就地改了系统的措辞 → 记录改动前后的差异,作为该类抽取的负例」。
    /// 原地覆盖而 payload 为 NULL 的话,「前」永久丢失且**不可回填** ——
    /// 而这正是绕幂等闸的全部理由(「他确认的是哪句话」),不落 payload 等于白绕。
    func editBody(card id: Int64, to text: String, now: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyBody
        }
        try writer.write { db in
            _ = try live(id, in: db)
            let before = try String.fetchOne(
                db, sql: "SELECT body FROM cards WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE cards SET body = ? WHERE id = ?", arguments: [text, id])
            // sortedKeys:M2-审20 的教训 —— 不排序的 JSON 键序按运行漂。
            // 这里虽只是审计数据,但「同样的编辑产出逐字节相同的 payload」不花钱。
            let payload = String(
                data: try JSONSerialization.data(
                    withJSONObject: ["edited_from": before ?? "", "edited_to": text],
                    options: [.sortedKeys]),
                encoding: .utf8)
            try write(.accepted, on: id, payload: payload, now: now, in: db)
        }
    }

    // MARK: - 合并卡

    /// 「都先放着」—— 合并卡**唯一**的批量出口(PRD §4.6.2.1)。
    ///
    /// 🔴 **一个事务,全或无。** 逐条各开一次写的话,中间一条抛了就是
    /// 「前三条放下了、后两条没有」—— 而界面已经整张收起来了,
    /// 用户看不出还有两条留在队列里,下次照推。
    ///
    /// 🔴 这里**没有也不许有** `acceptAll`,理由见 `CardWriting` 的类型注释;
    /// 由 `CardQueueProjectionTests.testThereIsNoBulkAccept` 扫源码守着。
    ///
    /// 🔴 **批内撞上已撤回的卡:跳过,不整批失败**(对抗审查 2026-08-26 建议改 2)。
    /// 合并卡渲染在屏上之后,事结案的级联可能撤回其中一张 —— 撤回是**正常的业务结局**
    /// (`Failure.withdrawn` 的注释就这么说),它已不在任何队列里,held 与否没有意义。
    /// 野 id 照旧整批回滚:那是调用方 bug,两者处置必须不同。
    func holdAll(cards ids: [Int64], now: String) throws {
        try writer.write { db in
            for id in ids {
                do { try land(id, .held, now: now, in: db) }
                catch Failure.withdrawn { continue }
            }
        }
    }

    // MARK: - 落判断

    private func land(_ id: Int64, _ state: CardQueueProjection.State, now: String) throws {
        try writer.write { db in try land(id, state, now: now, in: db) }
    }

    private func land(_ id: Int64, _ state: CardQueueProjection.State,
                      now: String, in db: Database) throws {
        let current = try live(id, in: db)
        // 判 11 的幂等:**与当前状态一致才 no-op**。
        // 不做的话,连点两下「先放着」会写出两条一模一样的判断 ——
        // `judgment_current` 取最新的那条,所以**界面完全正常**,
        // 而审计链里凭空多出一次用户从没做过的决定。
        guard current != state else { return }
        try write(state, on: id, now: now, in: db)
    }

    private func write(_ state: CardQueueProjection.State, on id: Int64,
                       payload: String? = nil, now: String, in db: Database) throws {
        // 反查,不写第二份字符串(见类型注释)。`.pending` 不是用户动作,
        // 它没有 action 名 —— 走到这里就是调用方传错了,抛出来。
        guard let action = CardQueueProjection.State.byAction.first(where: { $0.value == state })?.key
        else { throw Failure.notAUserAction(state.rawValue) }
        try db.execute(sql: """
            INSERT INTO judgments
              (decided_at, actor, caused_by, undoes, action, target_kind, target_id,
               payload, basis_line_ids)
            VALUES (?, 'user', NULL, NULL, ?, 'card', ?, ?, NULL)
            """, arguments: [now, action, String(id), payload])
    }

    /// 卡还在不在、撤没撤回;顺带把当前态取出来给幂等闸用。
    @discardableResult
    private func live(_ id: Int64, in db: Database) throws -> CardQueueProjection.State {
        guard let row = try Row.fetchOne(db, sql: "SELECT withdrawn_at FROM cards WHERE id = ?",
                                         arguments: [id])
        else { throw Failure.noSuchCard(id) }
        if (row["withdrawn_at"] as String?) != nil { throw Failure.withdrawn(id) }
        let action = try String.fetchOne(db, sql: """
            SELECT j.action FROM judgment_current jc
              JOIN judgments j ON j.id = jc.judgment_id
             WHERE jc.target_kind = 'card' AND jc.target_id = ?
            """, arguments: [String(id)])
        return CardQueueProjection.State.byAction[action ?? ""] ?? .pending
    }
}

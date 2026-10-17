import Foundation
import GRDB

/// 卡片的**写侧动作契约**(`M3-0e`,对 PRD §4.6.2)。
///
/// 🔴 **未实现的动作一律抛,绝不 no-op**(§3.2)。
///
/// ## 三类语义出口,每张卡都要齐(PRD §4.6.2)
///
/// **接受** · **否定** · **不表态** —— 各至少一个。「追问」是可选的第四类。
/// 外加一个轻出口「这问题问得不对」:它否定的是**提问本身**,不是内容。
///
/// ## 🔴 合并卡**只有「都先放着」,没有「全部确认」**
///
/// PRD §4.6.2.1 明写这条,理由也写了:批量确认会让用户无脑全选,判断质量直接崩掉;
/// 批量搁置只是降负担,不牺牲质量。
///
/// ⚠️ **这是个禁止项,而禁止项最容易在半年后被「顺手补齐」** ——
/// 一个 `acceptAll` 看起来只是对称性上的缺失。所以它由
/// `CardQueueProjectionTests.testThereIsNoBulkAccept` **扫源码**守着,不靠这段注释。
protocol CardWriting {

    // MARK: 三类语义出口

    /// 接受。「是这样」「记下来」「就这么记」——各卡型的措辞不同,语义同一类。
    func accept(card id: Int64, now: String) throws

    /// 否定。「不是」「随口说的」「不用」。
    /// - Note: PRD §4.6.2「否定同等对待」—— 它**一样写进记录**,不是丢弃。
    func decline(card id: Int64, now: String) throws

    /// 不表态:搁置 / 说不准 / 先放着。
    /// - Note: PRD §4.6.2「搁置 = **永不再推送**」,但永久留在产生它的页面。
    ///   做成「稍后再问」的话,这个动作就从「明确信号」退化成了「拖延」。
    func hold(card id: Int64, now: String) throws

    /// 轻出口:「这问题问得不对」。否定**提问本身**(前提错了、根本不该问)。
    /// 进学习闭环(PRD §5.3),对同类提问降权 —— 这是用户能给系统提问质量的唯一直接反馈。
    func wrongQuestion(card id: Int64, now: String) throws

    /// 可选的第四类:追问。结束后出「收尾卡」(不占预算,即时出)。
    func askBack(card id: Int64, now: String) throws

    // MARK: 就地可改(PRD §4.6.2「卡片应该是填空题,不只是判断题」)

    /// 改卡片正文里系统写的那句话,**改完即确认**。
    /// - Note: 改的是 `cards.body`,**绝不碰 `quote` 与冻结层**。
    ///   真实情况常常是「记,但不是这么记的」—— 而原话是不可变的。
    func editBody(card id: Int64, to text: String, now: String) throws

    // MARK: 合并卡

    /// 「都先放着」—— 合并卡**唯一**的批量出口。
    ///
    /// 🔴 这里**没有也不许有** `acceptAll`。见类型注释。
    func holdAll(cards ids: [Int64], now: String) throws
}

/// 还没接上的实现。**每个方法都抛**。
struct UnimplementedCardWriting: CardWriting {
    struct NotWired: Error, CustomStringConvertible {
        let action: String
        /// ⚠️ 这句会显示给用户,不写任务号(挡着它的是 `M3-B2` / `M3-F2`)。
        /// 「抛出来不假装成功」是给开发者的纪律,不是给用户的话 —— 桩照旧抛。
        var description: String { "卡片的「\(action)」还没做出来。" }
    }
    func accept(card id: Int64, now: String) throws { throw NotWired(action: "确认") }
    func decline(card id: Int64, now: String) throws { throw NotWired(action: "不记") }
    func hold(card id: Int64, now: String) throws { throw NotWired(action: "先放着") }
    func wrongQuestion(card id: Int64, now: String) throws { throw NotWired(action: "这问题问得不对") }
    func askBack(card id: Int64, now: String) throws { throw NotWired(action: "追问") }
    func editBody(card id: Int64, to text: String, now: String) throws { throw NotWired(action: "就地改") }
    func holdAll(cards ids: [Int64], now: String) throws { throw NotWired(action: "都先放着") }
}

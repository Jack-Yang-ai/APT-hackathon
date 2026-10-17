import Foundation
import GRDB

/// 事的**写侧动作契约**(M2-0e)。
///
/// ## 为什么先定签名、再实现
///
/// 三条前端线(F1 列表 / F2 详情 / F4 提名卡)与后端 `M2-B2`(状态机)**同时开工**。
/// 前端要能编译、能点、能出夹具截图,而 B2 那一刻还没写完。
/// 契约日定死签名之后,前端接的是**这份协议**,B2 只管把它实现掉。
///
/// 🔴 **未实现的动作一律抛,绝不 no-op**(§3.2)。
/// no-op 的形态是:用户点「单独盯着它」,界面照常收起卡片、照常给个成功的反馈,
/// 而**库里什么都没发生** —— 下次打开又冒出来,而他以为自己已经处理过了。
/// 抛出来最坏也只是「这个功能还没接上」,那是真话。
///
/// ## 用户动作一律写 `judgments`,不新建状态表(H5 §0.3 缺口 B)
///
/// 「不用」「说不准」这类动作**不在 `matter_nominations` 上落列** ——
/// 判断库是全库唯一的「用户说过什么」的账本(§3.3),而在别处再记一份
/// 就是同一件事两个出处,且**对不上时不会报错**。
protocol MatterWriting {

    // MARK: 提名三键(PRD §4.3.5 的卡片底部三颗)

    /// 「单独盯着它」—— 候选 → 活跃。
    /// - Note: 活跃满员(上限 10)时**不许静默挤掉别人**,抛 `.slotsFull`,
    ///   由界面走 PRD 的让位流程(给 2–3 件最久未动的让用户选一件沉睡)。
    func promote(nomination id: Int64, now: String) throws -> Int64

    /// 「不用」—— 候选 → 已拒绝。同组线索不再提名。
    func dismiss(nomination id: Int64, now: String) throws

    /// 「说不准」—— 留在候选区。**它也要写 `judgments`**:
    /// 「用户看过并决定先不决定」与「用户还没看过」是两件事,
    /// 而 30 天静默拒绝那条规则要靠它区分。
    func defer_(nomination id: Int64, now: String) throws

    // MARK: 生命周期

    /// 宣布结案。PRD §4.3.4:**仅用户**,系统永远不能结案。
    func close(matter id: Int64, now: String) throws

    /// 手动沉睡(或让位时被选中)。
    func sleep(matter id: Int64, now: String) throws

    /// 手动唤醒。满员时同样抛 `.slotsFull`,不静默挤人。
    func wake(matter id: Int64, now: String) throws

    /// 关掉一个悬点。
    func closeQuestion(_ id: Int64, now: String) throws
}

enum MatterActionFailure: Error, CustomStringConvertible {
    /// 活跃满员。**带上让位候选**,界面据此直接渲染 PRD 那个让位流程,
    /// 不用再查一次(查两次就是两个口径,而「最久未动」有自由度)。
    case slotsFull(limit: Int, suggestions: [Int64])
    case notFound(kind: String, id: Int64)
    /// 这条流转 PRD 里没有。数据库层也会拦(`matters_legal_transition_only`),
    /// 这里先拦一道是为了给出人话,而不是一句 SQL 报错。
    case illegalTransition(from: String, to: String)
    /// 🔴 **还没接上**。抛它而不是 no-op —— 见文件头。
    ///
    /// 两个受众,两个字段,别再挤回一个字符串里:
    /// - `blockedBy` 给**用户**看的人话(「状态机与流转」),会进 `description`;
    /// - `task` 给**开发者**看的任务号(`M2-B2`),**不进** `description`。
    ///
    /// 2026-09-01 之前只有一个字段,里面写着「M2-B2 状态机与流转」,于是
    /// `Notice.error("没能改:\(error)")` 把任务号原样端到了用户脸上。
    /// 而当时已经有三条测试钉着「报错要说清等谁」—— 两条纪律都对,
    /// 错的是它们共用一个字符串。拆开之后两边都留得住。
    case notImplementedYet(action: String, blockedBy: String, task: String)

    /// 挡着这个动作的任务号。给开发者与测试用,**不显示**。
    var blockingTask: String? {
        if case let .notImplementedYet(_, _, task) = self { return task }
        return nil
    }

    var description: String {
        switch self {
        case let .slotsFull(limit, s):
            return "正在盯着的已经有 \(limit) 件了,先让一件歇一歇(候选 \(s.count) 件)"
        case let .notFound(kind, id): return "找不到这个\(kind)(id \(id))"
        case let .illegalTransition(f, t): return "「\(f) → \(t)」不是一条允许的流转"
        // ⚠️ 这句会**原样出现在用户眼前**(`Notice.error` 直接把 Error 插进文案),
        // 所以 `by` 里不许放任务号 —— 编号对用户是零信息。
        case let .notImplementedYet(a, by, _): return "「\(a)」还没做出来 —— 等\(by)"
        }
    }
}

/// 契约日的桩。**每一个动作都抛**,直到 `M2-B2` 把真实现填进来。
///
/// ⚠️ 它存在的唯一理由是让三条前端线能编译、能跑夹具。
/// 一旦有人拿它当「先跑着」,那就是本仓最贵的失败形态(成功地什么都没做)——
/// 所以这里连一个 `return` 都没有。
struct MatterWritingStub: MatterWriting {
    /// 给用户看的人话。
    static let blockedBy = "状态机与流转"
    /// 给开发者看的任务号。**不进用户文案** —— 见 `notImplementedYet` 的注释。
    static let blockingTask = "M2-B2"
    private func boom(_ action: String) -> MatterActionFailure {
        .notImplementedYet(action: action, blockedBy: Self.blockedBy, task: Self.blockingTask)
    }
    func promote(nomination id: Int64, now: String) throws -> Int64 { throw boom("单独盯着它") }
    func dismiss(nomination id: Int64, now: String) throws { throw boom("不用") }
    func defer_(nomination id: Int64, now: String) throws { throw boom("说不准") }
    func close(matter id: Int64, now: String) throws { throw boom("结案") }
    func sleep(matter id: Int64, now: String) throws { throw boom("让它歇一歇") }
    func wake(matter id: Int64, now: String) throws { throw boom("唤醒") }
    func closeQuestion(_ id: Int64, now: String) throws { throw boom("关掉悬点") }
}

/// 活跃上限(PRD §4.3.4 容量规则:10 件「初」)。
///
/// 🔴 **唯一出处。** 容量闸、让位流程、列表头上那个「正在动的 · 4 件」都读它。
/// 散成三份的后果是改了一处而别处照旧,**而不会有任何东西报错**。
enum MatterCapacity {
    static let activeLimit = 10
}

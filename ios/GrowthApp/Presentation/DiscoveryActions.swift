import Foundation
import GRDB

/// 发现的**写侧动作契约**(`M3-0e`,对 PRD §4.5.5)。
///
/// 🔴 **未实现的动作一律抛,绝不 no-op**(§3.2)。
/// no-op 的形态是:用户左滑,那条发现从界面上消失了,而**库里什么都没发生** ——
/// 下次打开它又回来了,而用户以为自己已经处理过。
///
/// ## 🔴 左滑的 5 秒撤销窗口内**不写任何东西**
///
/// PRD §4.5.5 白纸黑字:「**撤销不留判断记录**」。而判断库是 append-only
/// (`judgments_no_delete` 触发器守着)—— 先写再删根本做不到。
/// ⇒ 唯一自洽的实现是:**界面先乐观隐藏,5 秒窗口关闭之后才调 `dismiss`**。
/// 撤销 = 取消那个待发的调用,库里从头到尾没动过。
///
/// ⚠️ 这条不是实现细节,是契约:把 `dismiss` 放在左滑那一刻调,
/// PRD 那句「撤销不留判断记录」就**永远无法满足**,而界面上看不出任何区别。
///
/// ## 用户动作一律写 `judgments`,不在 `discoveries` 上落状态列
///
/// 判断库是全库唯一的「用户说过什么」的账本(§3.3)。
/// 在内容库再落一个 `removed_at` / `useful` 就是同一件事两个出处,
/// 而两者对不上时,「最近移除」里会有一条抽屉里也还在的发现。
protocol DiscoveryWriting {

    /// 左滑「不感兴趣」。**5 秒撤销窗口关闭之后才调**(见类型注释)。
    ///
    /// 副作用照 PRD §4.5.5:同类型对该对象**降频**。
    /// - Note: 降频写在哪里由 `M3-B1` 定,但它**必须能被读回来** ——
    ///   降了频而没人读得到,与没降一模一样。
    func dismiss(discovery id: Int64, now: String) throws

    /// 从「最近移除」找回(24 小时内,PRD §4.5.5)。
    /// 过期的不该出现在界面上;真调到了要抛,不许静默成功。
    func restore(discovery id: Int64, now: String) throws

    /// 展开后点「有用」。同类型权重上升。
    func markUseful(discovery id: Int64, now: String) throws

    /// 展开后点「不对」——「这个判断是错的」。同类型**全局**降权。
    /// - Parameter why: 用户可选补一句为什么;`nil` 表示他没写。
    ///   **不许用空串顶替 nil** ——「没写」与「写了个空的」在学习闭环里是两件事。
    func markWrong(discovery id: Int64, why: String?, now: String) throws

    /// 读过了。14 天未读会沉入历史(PRD §4.5.4),所以「读过没有」必须被记下来。
    func markRead(discovery id: Int64, now: String) throws
}

/// 还没接上的实现。**每个方法都抛** —— 见 `DiscoveryWriting` 的注释。
struct UnimplementedDiscoveryWriting: DiscoveryWriting {
    struct NotWired: Error, CustomStringConvertible {
        let action: String
        /// ⚠️ 这句会显示给用户,不写任务号(挡着它的是 `M3-B1` / `M3-F1`)。
        var description: String { "发现的「\(action)」还没做出来。" }
    }
    func dismiss(discovery id: Int64, now: String) throws { throw NotWired(action: "移除") }
    func restore(discovery id: Int64, now: String) throws { throw NotWired(action: "找回") }
    func markUseful(discovery id: Int64, now: String) throws { throw NotWired(action: "有用") }
    func markWrong(discovery id: Int64, why: String?, now: String) throws { throw NotWired(action: "不对") }
    func markRead(discovery id: Int64, now: String) throws { throw NotWired(action: "已读") }
}

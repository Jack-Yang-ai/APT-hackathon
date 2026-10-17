import Foundation

/// 屏底那一行提示。**「是不是错误」由构造它的人说了算,不由文案的开头猜。**
///
/// ## 它替掉的是什么
///
/// 三个界面(设置 / 改人 / 认人)原来都写着
/// `note.hasPrefix("没能") ? DS.C.danger : DS.C.dim` —— **拿文案的前缀当错误判据**。
///
/// 后果不是理论上的:同一批代码里就有
/// `note = "主库没打开,读不出待确认的说话人"` —— 它是个实打实的错误,
/// 却因为不以「没能」开头而被画成**和「都过了一遍」一样的灰色小字**。
/// 用户扫一眼过去,以为一切正常。
///
/// 而这种错法**永远不会报错**:改一句文案的开头就会悄悄改变它的颜色,
/// 编译器与测试都拦不住。所以把那一位显式带上。
struct Notice: Equatable {
    let text: String
    /// 出错了吗。**红色只留给「有东西没做成」**,不给「做成了但结果是空的」——
    /// 「没有待确认的说话人」是好消息,画成红的会让人以为坏了。
    let isError: Bool

    static func info(_ text: String) -> Notice { .init(text: text, isError: false) }
    static func error(_ text: String) -> Notice { .init(text: text, isError: true) }
}

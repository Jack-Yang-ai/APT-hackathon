import Foundation
import GRDB
import UIKit

/// 处理事件流水(M1-4c)。**这是验收仪器,不是功能。**
///
/// ## 没有它,「真后台」这件事无法被证明
///
/// 打开 App,看到那一场出稿了 —— 这句话有两种解释:
///   ① 后台在你睡觉时把它跑完了(要的)
///   ② 你一打开 App 它才开始跑,而且刚好很快(不是要的)
///
/// 两种解释在界面上**长得一模一样**。仓规 §3.3:验收验「落对没落对」,
/// 不验「跑没跑通」。带上时间戳与触发源,「凌晨 3:14 由后台唤醒跑完」
/// 才是一个可检验的事实。
///
/// ## 它同时是「为什么这一场没出稿」唯一能回答的地方
///
/// 任务表只有**当前**态:一行 `retrying` 说不出它被推过几次、什么时候推的、
/// 是前台推的还是后台唤醒推的。而这三件事恰恰决定了下一步该查什么。
enum ProcessingEvents {

    enum Trigger: String {
        /// 用户开着 App
        case foreground = "前台"
        /// `BGProcessingTask` 把 App 叫起来了
        case background = "后台唤醒"
        /// 后台 URLSession 传完把 App 唤醒了(可能是冷启动)
        case transferCallback = "传输回调"
        /// **界面还活着、但 App 不在前台**时,界面上那个定时器照样响的那一拍(M1-29)。
        ///
        /// 🔴 **为什么不并进 `background`**:那一档的定义是
        /// 「`BGProcessingTask` 把 App 叫起来了」—— 一个具体的机制。
        /// 而这一档是「进程因为**别的**原因醒着(后台 URLSession 回调、录音在跑),
        /// 界面恰好还在,于是 30 秒定时器响了」。
        /// 并进去等于**重犯这条任务正在修的那个错**:两件不同的事记成同一个值。
        case backgroundTimer = "后台定时器"
    }

    /// 现在**真实**该记哪一档 —— 从应用状态读,不由调用方记。
    ///
    /// 🔴 **M1-29 的根因是「调用方自己就传错了」**:界面上那个 30 秒定时器挂在
    /// 界面上,而进程被后台回调唤醒时**界面还在、定时器照样响**,它却一律传
    /// `.foreground`。⇒ 凌晨 4:27 的事件表里出现了一条「前台」,而那时用户在睡觉。
    ///
    /// ⚠️ **M1-19 那道源码闸扫不到这个**:它扫的是「有没有写死 `.foreground`」,
    /// 不是「写的对不对」。⇒ 治法不是再加一道闸,是**让调用方没得可传** ——
    /// 判据从真值读,而真值只有一处。
    ///
    /// ⚠️ 后果不是「一列不好看」:判「后台到底跑没跑」时会把后台读成前台,
    /// 而 `M1-19` 的两跑验收**正是靠这一列判的**。
    @MainActor
    static var currentTrigger: Trigger {
        appStateProvider() == .active ? .foreground : .backgroundTimer
    }

    /// 仅供测试改写 —— 生产读 `UIApplication.shared.applicationState`。
    @MainActor
    static var appStateProvider: () -> UIApplication.State = {
        UIApplication.shared.applicationState
    }

    struct Event: Equatable {
        let at: String
        let trigger: String
        let outcome: String
        let detail: String?
    }

    /// 只保留最近这些条。
    ///
    /// 一天几十场、每场十几拍,不封顶的话这张表会比内容还大 ——
    /// 而它的用途是「最近发生了什么」,不是长期账本(那是云代理的 `usage/`)。
    static let keep = 200

    /// 记一条。**失败不抛** —— 仪器坏了不该拖垮被测的东西。
    /// 但也不静默:写不进去时打一行 log,免得「事件表是空的」被读成「什么都没发生」。
    static func record(trigger: Trigger, outcome: String, detail: String? = nil,
                       at: Date = Date(), in writer: some DatabaseWriter) {
        do {
            try writer.write { db in
                try record(trigger: trigger, outcome: outcome, detail: detail, at: at, in: db)
            }
        } catch {
            print("[processing_events] 记不进去(不影响处理):\(error)")
        }
    }

    /// 记一条,**在调用方已经开着的事务里**。
    ///
    /// 为什么要这个重载:上面那版自己 `writer.write { }`,而 GRDB 的写不可重入 ——
    /// 从一个已经开着的写事务里调它会当场炸。`TranscriptRevision.revise` 要求
    /// 「改字 + 传播引文 + 记事件」是同一个事务(改一半留下的账比不改更难查),
    /// 所以它只能走这一版。
    ///
    /// ⚠️ 与上面那版的差别只有一处:**这一版不吞异常**。
    /// 在事务里吞掉写不进去的错,等于让「事件没记上」和「事情没发生」长得一样;
    /// 而事务本来就该整个回滚。SQL 是同一份,不重抄(铁律 4)。
    static func record(trigger: Trigger, outcome: String, detail: String? = nil,
                       at: Date = Date(), in db: Database) throws {
        let iso = ISO8601DateFormatter.growth.string(from: at)
        try db.execute(sql: """
            INSERT INTO processing_events (at, trigger, outcome, detail)
            VALUES (?, ?, ?, ?)
            """, arguments: [iso, trigger.rawValue, outcome, detail])
        try db.execute(sql: """
            DELETE FROM processing_events WHERE id <= (
              SELECT MAX(id) - ? FROM processing_events)
            """, arguments: [keep])
    }

    static func recent(limit: Int = 20, in reader: some DatabaseReader) throws -> [Event] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT at, trigger, outcome, detail FROM processing_events
                 ORDER BY id DESC LIMIT ?
                """, arguments: [limit]).map {
                Event(at: $0["at"], trigger: $0["trigger"], outcome: $0["outcome"],
                      detail: $0["detail"])
            }
        }
    }

    /// 最近一次处理发生在什么时候、是谁推的。设置页显示的就是它。
    static func latest(in reader: some DatabaseReader) throws -> Event? {
        try recent(limit: 1, in: reader).first
    }
}

import Foundation
import GRDB

/// 底库快照的**生产存储**:经云代理写 R2(`M2-认8` ④b)。
///
/// ## 🔴 为什么这个文件必须存在
///
/// `RegistrySnapshotIO` 与整套快照语义 2026-08 就写好、测过了 ——
/// 而 2026-08-24 查出来:**全仓只有 `VoiceprintRegistryTests` 在调它,
/// 生产代码零调用点**,R2 上 `snapshots/voiceprints/` 实测 **0 个对象**。
///
/// 后果不是「备份没做」这么轻:Mac 声纹 daemon 的 `load_snapshot` 读不到快照就抛,
/// **整条认人链跑不通** —— 而两端各自都「正常」:手机排得进队列、daemon 心跳健康、
/// Worker 回 200,只有产物永远不出现。
///
/// ⚠️ 同一天里这是第三次「写好了不等于在跑/被调用」(前两次:`M1-34` 兜底没人常驻、
/// 声纹 daemon 没进 launchd)。**这类缺陷没有运行时症状,只能靠「谁调用它」这个问题抓。**
///
/// ## 铁律 2 没被动
///
/// 手机仍是底库的**唯一写方**;R2 上这份是**只读快照**(整份覆盖式版本化,
/// 永不接受增量写)。`SnapshotStore` 协议在**类型上**就没有增量口 ——
/// 想做成「两边都能改再合并」得先改那个协议,改不动就做不成。
enum RemoteSnapshotStore {

    /// 云代理背后的 R2。`put` 走 `/upload?key=`(与音频块同一条路,同一个键校验)。
    struct Store: SnapshotStore {
        let config: ProxyClient.Config

        func put(_ data: Data, key: String) throws {
            // ⚠️ **同步阻塞。** `RegistrySnapshotIO.push` 是同步接口(它要在一个
            // `reader.read` 事务里取整份底库),而这一层只在推快照时被调到 ——
            // 一天最多几次、几十 KB,不值得为它把整条 push 改成 async。
            let sem = DispatchSemaphore(value: 0)
            var thrown: Error?
            Task {
                do { try await ProxyClient.putObject(key: key, data: data, config: config) }
                catch { thrown = error }
                sem.signal()
            }
            sem.wait()
            if let thrown { throw thrown }
        }

        /// 快照只推不拉 —— 恢复那条路(重装后 `restoreLatest`)还没接生产,
        /// 接的时候再实现这两个。**抛而不是返空** :返空会让「桶里没有」与
        /// 「这一侧没实现」长得一模一样,而前者是正常状态、后者是缺陷。
        func get(key: String) throws -> Data {
            throw Failure.notImplemented("从 R2 读快照(恢复那条路还没接生产)")
        }
        func listKeys() throws -> [String] {
            throw Failure.notImplemented("列 R2 上的快照(恢复那条路还没接生产)")
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case notImplemented(String)
        var description: String {
            switch self {
            case .notImplemented(let what): return "还没实现:\(what)"
            }
        }
    }

    /// 多久推一次。
    ///
    /// 🔴 **不是「越勤越好」**:每推一次就在 R2 上多一个版本,而快照永不删。
    /// 一天一次足够 —— 底库只在 enroll 时变,而 enroll 之后**立刻**会推一次
    /// (见 `pushIfNeeded` 的 `force`),定时那次只是兜住「手机换了、enroll 那次没推成」。
    static let intervalSeconds: TimeInterval = 24 * 3600

    private static let lastPushKey = "voiceprint.snapshot.lastPushedAt"

    /// 该不该推,该就推。
    ///
    /// - Parameter force: enroll 之后传 true —— 底库刚变过,那一刻的快照最有价值。
    /// - Returns: 推上去的 key;这次不用推返回 nil。
    ///
    /// ⚠️ **失败要可见**(§3.2):抛给调用方去记事件。悄悄吞掉的表现是
    /// 「Mac 一直判不了」,而那与「Mac 挂了」在任何界面上都一样。
    @discardableResult
    static func pushIfNeeded(force: Bool, now: Date = Date(),
                             in db: DatabaseQueue) throws -> String? {
        guard let config = ProxySettings.config else { return nil }
        let d = UserDefaults.standard
        let last = d.object(forKey: lastPushKey) as? Date
        if !force, let last, now.timeIntervalSince(last) < intervalSeconds { return nil }

        // 底库空就别推。**空快照比没快照更糟** —— Mac 会读到它、判每一段都是陌生人,
        // 而「底库是空的」与「快照还没推」在 daemon 那头是两种完全不同的处置
        // (前者该照常跑并全部拒识,后者该抛「判不了」等人来修)。
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM voiceprints") ?? 0 }
        guard count > 0 else { return nil }

        let key = try RegistrySnapshotIO.push(
            takenAt: ISO8601DateFormatter.growth.string(from: now),
            to: Store(config: config), from: db)
        d.set(now, forKey: lastPushKey)
        return key
    }
}

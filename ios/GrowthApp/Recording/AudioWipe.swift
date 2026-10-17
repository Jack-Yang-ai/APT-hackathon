import Foundation

/// 「清除全部录音」真正该删的东西(PRD §4.1.10 存储组)。
///
/// ## 🔴 账本不能跟着删
///
/// 上一版是「把 `recordings/` 下**每一项**都 `removeItem`」—— 而每一天一个目录,
/// **`ledger.jsonl` 就在里面**。同时弹窗上写着「录音账本、纪要与转写都留着,
/// 不受影响」。那句话在按下去的那一刻就是假的。
///
/// 后果不只是「少个文件」。账本是**场次的真相源**:
/// · `ProcessingPump.blocks(of:)` 读不到它 ⇒ 在跑的任务被判「这一场一块音频都没有」
///   ⇒ **直接标死**,而 dead 需要用户手动救(M1-13d);
/// · `LineAudio` / `SpeakerSegments` 定位不到块 ⇒ 跳原话与认人取段一起失效;
/// · 已经出了纪要的老场次,时间轴也跟着查不回来。
///
/// 而账本是 jsonl,一天几 KB —— **它根本不占空间**。为省空间删它是纯亏。
///
/// ## 音频删了之后,在跑的那些会怎样
///
/// 块文件没了但账本还在 ⇒ 上传层按「这一块永久坏了」跳过它、这一场落 `partial`,
/// 逐字稿里留占位行(M1-14a)。**这是可见的降级,不是静默丢失** ——
/// 所以确认文案里要说出来。
enum AudioWipe {

    /// 账本文件名。**唯一被豁免的东西**,写成常量是为了让下面那条判断
    /// 和 `ProcessingPump` 读的是同一个名字。
    static let ledgerName = "ledger.jsonl"

    struct Outcome: Equatable {
        let filesDeleted: Int
        let bytesFreed: Int64
        /// 保住的账本数(= 有录音的天数)。给界面用来说「账本都留着」。
        let ledgersKept: Int
    }

    /// 删掉 `root` 下的音频,**保留每一天的账本**。
    ///
    /// - 删不掉的**抛出去**,不静默跳过:默默失败会让用户以为空间腾出来了,
    ///   而它还占着(§3.2)。
    @discardableResult
    static func run(root: URL, fileManager fm: FileManager = .default) throws -> Outcome {
        try RecordingPaths.withFileAccess { try runLocked(root: root, fileManager: fm) }
    }

    private static func runLocked(root: URL, fileManager fm: FileManager) throws -> Outcome {
        var deleted = 0, kept = 0
        var freed: Int64 = 0

        func clear(_ dir: URL) throws {
            for item in try fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true {
                    // 手表目录也保留账本。不要把 watch/ 整个当音频删掉。
                    try clear(item)
                } else if item.lastPathComponent == ledgerName {
                    kept += 1
                } else {
                    freed += size(of: item, fm)
                    try fm.removeItem(at: item)
                    deleted += 1
                }
            }
        }
        if fm.fileExists(atPath: root.path) { try clear(root) }
        return Outcome(filesDeleted: deleted, bytesFreed: freed, ledgersKept: kept)
    }

    private static func size(of url: URL, _ fm: FileManager) -> Int64 {
        ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

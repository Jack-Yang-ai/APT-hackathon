import Foundation

/// 录音目录的唯一出处。手机和导入共用当天目录,手机收到的手表音频隔离在 watch/。
enum RecordingPaths {
    private static let fileLock = NSRecursiveLock()

    /// 手表誊写和用户清除音频串行;调用方先拿文件锁,再进入数据库事务。
    static func withFileAccess<T>(_ operation: () throws -> T) rethrows -> T {
        fileLock.lock(); defer { fileLock.unlock() }
        return try operation()
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings")
    }

    static func audioDir(day: String, source: String, root: URL = RecordingPaths.root) -> URL {
        let dayDir = root.appendingPathComponent(day)
        return source == SessionSource.watch ? dayDir.appendingPathComponent("watch") : dayDir
    }
}

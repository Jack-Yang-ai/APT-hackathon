import Foundation
import CryptoKit
import Darwin

// Generated input-source catalogs only. Hold directory descriptors throughout the
// operation so an application replacing its cache directory cannot redirect a move.
enum InputSourceCatalog {
    struct Item: Codable {
        let source: String
        let archive: String
        let sha256: String
        var state: String
    }
    struct Report: Codable {
        var examined = 0
        var items: [Item] = []
        var warnings: [String] = []
        var archivedCount: Int { items.filter { $0.state == "archived" }.count }
    }
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private struct Snapshot {
        let data: Data
        let device: dev_t
        let inode: ino_t
        var hash: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
    private final class Directory {
        let fd: Int32
        let url: URL
        let device: dev_t
        let inode: ino_t
        init(fd: Int32, url: URL) throws {
            guard fd >= 0 else { throw Failure("无法打开输入法缓存目录：\(String(cString: strerror(errno)))") }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                close(fd)
                throw Failure("输入法缓存目录不是当前用户的普通目录。")
            }
            self.fd = fd; self.url = url; device = info.st_dev; inode = info.st_ino
        }
        convenience init(_ url: URL) throws {
            try self.init(fd: open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), url: url)
        }
        deinit { close(fd) }
        func child(_ name: String) throws -> Directory {
            try Directory(fd: openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), url: url.appendingPathComponent(name))
        }
        func names() throws -> [String] {
            let copy = dup(fd)
            guard copy >= 0 else { throw posix() }
            guard let stream = fdopendir(copy) else { close(copy); throw posix() }
            defer { closedir(stream) }
            var names: [String] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw posix() }
                    return names.sorted()
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name != ".", name != "..", !name.contains("/") { names.append(name) }
            }
        }
        func stillAttached(to parent: Directory, name: String) -> Bool {
            var info = stat()
            return fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
                info.st_mode & S_IFMT == S_IFDIR && info.st_dev == device && info.st_ino == inode
        }
    }
    private static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    static var currentUserRoot: URL? {
        let count = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard count > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: count)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, count) == count else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }
    private static func readFile(_ directory: Directory, _ name: String) throws -> Snapshot {
        let fd = openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posix() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size > 0, info.st_size < 2_000_000 else { throw Failure("输入法缓存类型、归属或大小异常。") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < 2_000_000 {
            let count = read(fd, &buffer, min(buffer.count, 2_000_000 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posix() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == info.st_size else { throw Failure("输入法缓存在读取期间发生变化，已保留。") }
        return Snapshot(data: data, device: info.st_dev, inode: info.st_ino)
    }
    private static func move(_ from: Directory, _ name: String, _ to: Directory, _ destination: String) throws {
        guard renameatx_np(from.fd, name, to.fd, destination, UInt32(RENAME_EXCL)) == 0 else { throw posix() }
    }
    private static func save(_ report: Report, _ directory: Directory) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report), temporary = "receipt-" + UUID().uuidString + ".tmp"
        let fd = openat(directory.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix() }
        defer { close(fd); unlinkat(directory.fd, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posix() }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory.fd, temporary, directory.fd, "receipt.json") == 0 else { throw posix() }
    }
    static func repair(root: URL, retired: URL, current: URL, backup: URL,
                       beforeMove: ((URL) throws -> Void)? = nil, afterMove: ((URL) throws -> Void)? = nil) throws -> Report {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: retired.path), fm.fileExists(atPath: current.path) else {
            throw Failure("旧输入法仍在正式路径或当前APT尚未安装，未处理缓存。")
        }
        let rootDirectory = try Directory(root)
        var report = Report(), archiveDirectory: Directory?
        let old = Data(retired.path.utf8), identity = Data(APTInputSource.bundleID.utf8)
        // Only one level of current-UID directories below the system-provided root.
        var directoryNames: [String?] = [nil]
        var rootFiles: [String] = []
        for name in try rootDirectory.names() {
            if isCatalog(name) { rootFiles.append(name); continue }
            var info = stat()
            guard fstatat(rootDirectory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { continue }
            directoryNames.append(name)
        }
        for childName in directoryNames {
            let directory: Directory
            do { directory = try childName.map { try rootDirectory.child($0) } ?? rootDirectory }
            catch { report.warnings.append((childName ?? "缓存根") + "：无法扫描缓存目录：" + error.localizedDescription); continue }
            let files: [String]
            do { files = childName == nil ? rootFiles : try directory.names().filter(isCatalog) }
            catch { report.warnings.append(directory.url.lastPathComponent + "：目录枚举失败：" + error.localizedDescription); continue }
            for name in files {
                let file = directory.url.appendingPathComponent(name)
                do {
                    let before = try readFile(directory, name)
                    report.examined += 1
                    guard before.data.range(of: old) != nil, before.data.range(of: identity) != nil else { continue }
                    if archiveDirectory == nil {
                        let parent = try Directory(backup.deletingLastPathComponent())
                        guard mkdirat(parent.fd, backup.lastPathComponent, 0o700) == 0 else { throw posix() }
                        archiveDirectory = try parent.child(backup.lastPathComponent)
                    }
                    let archive = archiveDirectory!
                    let destination = String(format: "%04d-", report.items.count) + name
                    report.items.append(Item(source: file.path, archive: backup.appendingPathComponent(destination).path, sha256: before.hash, state: "planned"))
                    try save(report, archive) // Persist intent before moving the generated catalog.
                    let again = try readFile(directory, name)
                    guard again.device == before.device, again.inode == before.inode, again.data == before.data else {
                        throw Failure("输入法缓存已被应用更新，已保留。")
                    }
                    try beforeMove?(file)
                    if let childName, !directory.stillAttached(to: rootDirectory, name: childName) {
                        throw Failure("应用缓存目录已更换，已保留。")
                    }
                    try move(directory, name, archive, destination)
                    try afterMove?(file)
                    let moved = try readFile(archive, destination)
                    if moved.device == before.device, moved.inode == before.inode, moved.data == before.data {
                        report.items[report.items.count - 1].state = "archived"
                    } else {
                        report.items[report.items.count - 1].state = "archive_needs_review"
                        do {
                            try move(archive, destination, directory, name)
                            report.items[report.items.count - 1].state = "restored_changed_catalog"
                        } catch {
                            var present = stat()
                            if (error as? POSIXError)?.code == .EEXIST,
                               fstatat(directory.fd, name, &present, AT_SYMLINK_NOFOLLOW) == 0 {
                                report.items[report.items.count - 1].state = "conflict_both_preserved"
                            }
                            report.warnings.append("缓存恢复未覆盖原路径，备份已保留：" + error.localizedDescription)
                        }
                    }
                    try save(report, archive)
                } catch {
                    if let index = report.items.indices.last, report.items[index].source == file.path, report.items[index].state == "planned" {
                        var info = stat()
                        let destination = URL(fileURLWithPath: report.items[index].archive).lastPathComponent
                        report.items[index].state = archiveDirectory.map { fstatat($0.fd, destination, &info, AT_SYMLINK_NOFOLLOW) == 0 } == true ? "archive_needs_review" : "preserved"
                    }
                    report.warnings.append(directory.url.lastPathComponent + "/" + name + "：" + error.localizedDescription)
                    if let archiveDirectory { try? save(report, archiveDirectory) }
                }
            }
        }
        return report
    }
    private static func isCatalog(_ name: String) -> Bool {
        name.range(of: #"^com\.apple\.IntlDataCache[A-Za-z0-9_.-]{0,64}\.kbdx$"#, options: .regularExpression) != nil
    }
}

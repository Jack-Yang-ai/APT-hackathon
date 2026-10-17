import Cocoa
import CryptoKit
import Darwin

struct InstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
struct SessionPending: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct SystemMoveFailure: LocalizedError {
    let message: String
    let diagnostic: String
    var errorDescription: String? { message }
}

struct CommandResult {
    let status: Int32
    let output: String
}

// Output goes to a file so a verbose child cannot block on a full pipe. Only our child is timed out.
enum InstallCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        try await Task.detached { try blocking(executable, arguments, timeout: timeout) }.value
    }
    private static func blocking(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("apt-install-command-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw InstallFailure("无法建立命令输出文件。")
            }
            defer { try? FileManager.default.removeItem(at: file) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = handle
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            if done.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                if done.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = done.wait(timeout: .now() + 2)
                }
                let output = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                throw InstallFailure("操作超时：\(executable) \(arguments.joined(separator: " "))\n\(output)")
            }
            return CommandResult(status: process.terminationStatus, output: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }
}

@MainActor protocol InstallSystem {
    func command(_ executable: String, _ arguments: [String]) async throws -> CommandResult
    func registeredBundles() -> [URL]
    func prepareUpdate() throws -> [String: Any]
    func register(_ bundle: URL) throws -> [String: Any]
    func restoreRegistration(_ bundle: URL) throws
    func moveSystemBundle(from: URL, to: URL) async throws
    func sourceInfo(_ bundle: URL) async throws -> [String: Any]
    func pause(_ nanoseconds: UInt64) async throws
}

@MainActor final class NativeInstallSystem: InstallSystem {
    func command(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await InstallCommand.run(executable, arguments, timeout: executable == "/usr/bin/osascript" ? 180 : 30)
    }
    func registeredBundles() -> [URL] { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: APTInputSource.bundleID) }
    func prepareUpdate() throws -> [String: Any] { try APTInputSource.prepareUpdate() }
    func register(_ bundle: URL) throws -> [String: Any] { try APTInputSource.registerInstalled(at: bundle) }
    func restoreRegistration(_ bundle: URL) throws { _ = try APTInputSource.registerRestored(at: bundle) }
    nonisolated static func systemMoveScript(from: URL, to: URL) throws -> String {
        let installed = "/Library/Input Methods/APT.app"
        let archive = "/Library/Application Support/APT IME Backups"
        func isArchive(_ url: URL) -> Bool {
            url.deletingLastPathComponent().path == archive &&
                url.lastPathComponent.range(of: #"^[A-Za-z0-9-]{1,100}\.app$"#, options: .regularExpression) != nil
        }
        guard (from.path == installed && isArchive(to)) || (to.path == installed && isArchive(from)) else {
            throw InstallFailure("系统包迁移只允许正式 APT 路径与固定系统备份目录之间移动。")
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // Root never executes a user-writable file or writes into a user-controlled directory.
        let script = """
        set -eu
        for apt_dir in '/Library' '/Library/Input Methods' '/Library/Application Support'; do
          test -d "$apt_dir" && test ! -L "$apt_dir"
          test "$(/usr/bin/stat -f %u "$apt_dir")" = 0
          apt_mode=$(/usr/bin/stat -f %Lp "$apt_dir")
          test $((0$apt_mode & 0022)) -eq 0
        done
        apt_archive=\(quote(archive))
        if test ! -e "$apt_archive" && test ! -L "$apt_archive"; then /bin/mkdir -m 755 "$apt_archive"; fi
        test -d "$apt_archive" && test ! -L "$apt_archive"
        test "$(/usr/bin/stat -f %u "$apt_archive")" = 0
        apt_mode=$(/usr/bin/stat -f %Lp "$apt_archive")
        test $((0$apt_mode & 0022)) -eq 0
        apt_from=\(quote(from.path))
        apt_to=\(quote(to.path))
        apt_system_exe='/Library/Input Methods/APT.app/Contents/MacOS/APT'
        for apt_pid in $(/usr/bin/pgrep -x APT || true); do
          apt_program=$(/bin/ps -ww -p "$apt_pid" -o args= || true)
          case "$apt_program" in "$apt_system_exe"|"$apt_system_exe "*) exit 1 ;; esac
        done
        for apt_item in "$apt_from" "$apt_from/Contents" "$apt_from/Contents/Info.plist" "$apt_from/Contents/MacOS" "$apt_from/Contents/MacOS/APT"; do
          test ! -L "$apt_item" && test -e "$apt_item"
          test "$(/usr/bin/stat -f %u "$apt_item")" = 0
          apt_mode=$(/usr/bin/stat -f %Lp "$apt_item")
          test $((0$apt_mode & 0022)) -eq 0
        done
        test ! -e "$apt_to" && test ! -L "$apt_to"
        test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$apt_from/Contents/Info.plist")" = 'local.echo.inputmethod.memory'
        test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$apt_from/Contents/Info.plist")" = 'APT'
        test "$(/usr/libexec/PlistBuddy -c 'Print InputMethodConnectionName' "$apt_from/Contents/Info.plist")" = 'local.echo.inputmethod.memory_Connection'
        /bin/mv -n "$apt_from" "$apt_to"
        test ! -e "$apt_from" && test -d "$apt_to"
        """
        return script
    }
    nonisolated static func systemMoveAppleScript(from: URL, to: URL) throws -> String {
        let shell = try Self.systemMoveScript(from: from, to: to)
        let literal = "\"" + shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
        return "do shell script " + literal + " with administrator privileges"
    }
    func moveSystemBundle(from: URL, to: URL) async throws {
        let script = try Self.systemMoveAppleScript(from: from, to: to)
        let result: CommandResult
        do { result = try await command("/usr/bin/osascript", ["-e", script]) }
        catch { throw SystemMoveFailure(message: "等待系统管理员授权超时或中断。请点击安装／修复，并在 macOS 窗口完成授权。", diagnostic: error.localizedDescription) }
        guard result.status == 0 else { throw SystemMoveFailure(message: "系统旧输入法迁移被取消或未完成，请重新点击安装／修复。", diagnostic: "系统迁移退出 \(result.status)：\(result.output)") }
    }
    // TIS state is cached per process. The GUI predates the package replacement,
    // so it cannot authoritatively recheck its own cached source objects.
    static func inputSourceCommand(_ bundle: URL) async throws -> [String: Any] {
        let installed = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Input Methods/APT.app").standardizedFileURL
        guard bundle.standardizedFileURL.path == installed.path else { throw InstallFailure("只能检查当前用户正式安装的 APT。") }
        let result = try await InstallCommand.run(installed.appendingPathComponent("Contents/MacOS/APT").path,
                                                ["--input-source-info"])
        guard result.status == 0 else { throw SessionPending(message: result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let data = result.output.data(using: .utf8),
              let source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallFailure("输入源检查没有返回有效回执。")
        }
        return source
    }
    func sourceInfo(_ bundle: URL) async throws -> [String: Any] { try await Self.inputSourceCommand(bundle) }
    func pause(_ nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

struct InstallPaths {
    let home: URL
    let resources: URL
    let systemTarget: URL
    let systemArchive: URL
    let catalogRoot: URL?
    init(home: URL, resources: URL, systemTarget: URL = URL(fileURLWithPath: "/Library/Input Methods/APT.app"), systemArchive: URL = URL(fileURLWithPath: "/Library/Application Support/APT IME Backups"), catalogRoot: URL? = InputSourceCatalog.currentUserRoot) {
        self.home = home; self.resources = resources; self.systemTarget = systemTarget
        self.systemArchive = systemArchive
        self.catalogRoot = catalogRoot
    }
    var payload: URL { resources.appendingPathComponent("Payload/APT.app") }
    var target: URL { home.appendingPathComponent("Library/Input Methods/APT.app") }
    var legacy: URL { home.appendingPathComponent("Library/Input Methods/Echo Memory IME.app") }
    var agent: URL { home.appendingPathComponent("Library/LaunchAgents/local.apt.inputmethod.plist") }
    var legacyAgent: URL { home.appendingPathComponent("Library/LaunchAgents/local.echo.inputmethod.memory.plist") }
    var state: URL { home.appendingPathComponent(".local/share/apt/ime-installations") }
    var domain: String { "gui/\(getuid())" }
}

struct PayloadManifest: Codable {
    let version: String
    let build: String
    let sourceFingerprint: String
    let installerFingerprint: String
    let files: [String: String]
}

enum InstallStatus: String { case ready, awaitingSelection = "awaiting_selection", waitingForUserEnable = "waiting_for_user_enable", selectionFailed = "selection_failed", checksPending = "checks_pending", failed }
struct InstallOutcome {
    let status: InstallStatus
    let message: String
    let receipt: URL
    let log: URL
    let canTest: Bool
}

// Notifications can arrive before installation finishes, or after another run starts.
// Only one passive query may finish against the current waiting generation.
struct EnablementRefreshGate {
    private(set) var generation: UInt64 = 0
    private var waiting = false
    private var checking = false
    mutating func reset(waiting: Bool) { generation &+= 1; self.waiting = waiting; checking = false }
    mutating func begin() -> UInt64? {
        guard waiting, !checking else { return nil }
        checking = true; return generation
    }
    mutating func finish(_ token: UInt64) -> Bool {
        guard token == generation, waiting, checking else { return false }
        checking = false; return true
    }
}

@MainActor final class IMEInstaller {
    static let registry = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    private let paths: InstallPaths
    private let system: InstallSystem
    private let fm = FileManager.default
    private var session: URL!
    private var phase = "准备安装"
    private var logHandle: FileHandle?
    private var lock: Int32 = -1
    private var changed = false
    private var hadTarget = false
    private var hadLegacy = false
    private var hadAgent = false
    private var hadLegacyAgent = false
    private var hadSystem = false
    private var previousExecutable: URL?
    private var previousBundle: URL?
    private var previousAgent: URL?
    private var retiredSystem: URL?
    private var payload: PayloadManifest?
    private var selection: [String: Any] = [:]
    private var catalogRepair: InputSourceCatalog.Report?
    var progress: ((String) -> Void)?

    init(paths: InstallPaths, system: InstallSystem) { self.paths = paths; self.system = system }
    deinit { try? logHandle?.close(); if lock >= 0 { close(lock) } }

    static func recordCheck(_ outcome: InstallOutcome, kind: String, value: [String: Any]) throws {
        var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: outcome.receipt)) as? [String: Any] ?? [:]
        if kind == "selection_check" {
            let selected = value["status"] as? String == "selected"
            guard selected || value["status"] as? String == "failed" else { throw InstallFailure("无效的切换检查结果。") }
            if selected {
                let foreground = value["method"] as? String == "foreground_text_input_context"
                let observed = foreground ? value["foreground_selected_id"] as? String : (value["input_source"] as? [String: Any])?["selected_id"] as? String
                guard observed == APTInputSource.modeID, !foreground || value["foreground_active"] as? Bool == true else {
                    throw InstallFailure("切换回执没有确认当前选中 APT。")
                }
            }
            receipt["status"] = selected ? InstallStatus.awaitingSelection.rawValue : InstallStatus.selectionFailed.rawValue
            receipt["api_selection_observed"] = selected
            receipt["selection_verified"] = false
            receipt["message"] = selected ? "检查进程已持续选中 APT；请核对菜单栏并确认实际键盘输入。" : "APT 基础检查通过，但切换失败；原始诊断已保存，请查看日志或重试。"
            receipt.removeValue(forKey: "typing_check")
            receipt.removeValue(forKey: "verification_method")
        } else if kind == "typing_check" {
            guard (receipt["selection_check"] as? [String: Any])?["status"] as? String == "selected" else {
                throw InstallFailure("尚未通过切换检查，不能确认试输。")
            }
            guard value["method"] as? String == "user_reported", value["status"] as? String == "confirmed" else {
                throw InstallFailure("试输确认须保留用户报告来源。")
            }
            receipt["status"] = InstallStatus.ready.rawValue
            receipt["verification_method"] = "user_reported"
            receipt["message"] = "用户已报告在试输框得到“你好”；此记录不是自动键盘验收。"
        } else { throw InstallFailure("未知的安装检查类型。") }
        var check = value
        check["timestamp"] = ISO8601DateFormatter().string(from: Date())
        check["checked_at_unix"] = Date().timeIntervalSince1970
        receipt[kind] = check
        // A user report is preserved separately; neither a TIS response nor text insertion proves real typing.
        receipt["live_typing_verified"] = false
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: outcome.receipt, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outcome.receipt.path)
        let log = try FileHandle(forWritingTo: outcome.log)
        defer { try? log.close() }
        try log.seekToEnd()
        let data = try JSONSerialization.data(withJSONObject: [kind: check], options: [.sortedKeys, .withoutEscapingSlashes])
        try log.write(contentsOf: data + Data([10]))
    }

    func note(_ value: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(phase)] \(value)\n"
        try? logHandle?.write(contentsOf: Data(line.utf8))
    }
    private func step(_ name: String) { phase = name; note(name); progress?(name) }
    private func exists(_ path: URL) -> Bool { fm.fileExists(atPath: path.path) }
    private func json(_ value: [String: Any], _ name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = session.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func begin() throws {
        // Check ancestors before creating the state directory, lock or log.
        try safeDestinations()
        try fm.createDirectory(at: paths.state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lock = open(paths.state.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw InstallFailure("另一个 APT 安装正在进行，请等待它结束后重试。") }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        session = paths.state.appendingPathComponent("\(stamp)-\(getpid())-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: session, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let log = session.appendingPathComponent("install.log")
        guard fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw InstallFailure("无法保存安装日志。") }
        logHandle = try FileHandle(forWritingTo: log)
    }
    private func unlock() {
        try? logHandle?.close(); logHandle = nil
        if lock >= 0 { flock(lock, LOCK_UN); close(lock); lock = -1 }
    }
    @discardableResult private func run(_ exe: String, _ args: [String], required: Bool = true) async throws -> CommandResult {
        note("执行 \(exe) \(args.joined(separator: " "))")
        let result = try await system.command(exe, args)
        note("退出 \(result.status)\n\(result.output)")
        if required && result.status != 0 { throw InstallFailure("\(phase)失败（\(result.status)）：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return result
    }

    nonisolated static func inventory(_ bundle: URL) throws -> [String: String] {
        let fm = FileManager.default
        guard let iterator = fm.enumerator(at: bundle, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: []) else { throw InstallFailure("无法读取安装包。") }
        var files: [String: String] = [:]
        let normalized = bundle.standardizedFileURL.path
        let root = normalized.hasSuffix("/") ? normalized : normalized + "/"
        for case let file as URL in iterator {
            let keys = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            let itemPath = file.standardizedFileURL.path
            guard itemPath.hasPrefix(root) else { throw InstallFailure("无法取得包内相对路径：\(file.path)") }
            let relative = String(itemPath.dropFirst(root.count))
            if keys.isSymbolicLink == true {
                let destination = try fm.destinationOfSymbolicLink(atPath: file.path)
                guard !destination.hasPrefix("/"), file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw InstallFailure("安装包包含越界链接：\(relative)") }
                files[relative] = "link:" + destination
                iterator.skipDescendants()
            } else if keys.isRegularFile == true {
                files[relative] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return files
    }
    private func metadata(_ bundle: URL) throws -> [String: Any] {
        guard let dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] else { throw InstallFailure("安装包信息无效。") }
        return dict
    }
    private func validatePayload() async throws {
        step("检查安装包")
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", paths.resources.deletingLastPathComponent().deletingLastPathComponent().path])
        let manifest = try JSONDecoder().decode(PayloadManifest.self, from: Data(contentsOf: paths.resources.appendingPathComponent("PayloadManifest.json")))
        let inventory = try await Task.detached { try Self.inventory(self.paths.payload) }.value
        guard inventory == manifest.files, !inventory.isEmpty else { throw InstallFailure("安装包文件校验失败，请重新从 GitHub 下载完整版本。") }
        let info = try metadata(paths.payload)
        let modeID = APTInputSource.modeID
        let modes = info["ComponentInputModeDict"] as? [String: Any] ?? [:]
        let mode = (modes["tsInputModeListKey"] as? [String: [String: Any]])?[modeID] ?? [:]
        guard info["CFBundleIdentifier"] as? String == APTInputSource.bundleID,
              info["CFBundleExecutable"] as? String == "APT", info["CFBundleDisplayName"] as? String == APTInputSource.displayName,
              info["CFBundleShortVersionString"] as? String == manifest.version, info["CFBundleVersion"] as? String == manifest.build,
              info["APTSourceFingerprint"] as? String == manifest.sourceFingerprint,
              info["InputMethodConnectionName"] as? String == APTInputSource.bundleID + "_Connection",
              info["InputMethodServerControllerClass"] as? String == "EchoInputController",
              info["TISInputSourceID"] as? String == APTInputSource.bundleID,
              mode["TISInputSourceID"] as? String == modeID, mode["TISIntendedLanguage"] as? String == "zh-Hans",
              (mode["tsInputModeIsVisibleKey"] as? NSNumber)?.objCType.pointee == 99,
              mode["tsInputModeIsVisibleKey"] as? Bool == true,
              (mode["tsInputModeDefaultStateKey"] as? NSNumber)?.objCType.pointee == 99,
              mode["tsInputModeDefaultStateKey"] as? Bool == true,
              modes["tsVisibleInputModeOrderedArrayKey"] as? [String] == [modeID] else { throw InstallFailure("安装包版本或输入源信息不完整。") }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", paths.payload.path])
        payload = manifest
        try fm.copyItem(at: paths.resources.appendingPathComponent("ReleaseNotes.md"), to: session.appendingPathComponent("changelog.md"))
    }
    private func safeDestinations() throws {
        // Refuse redirected user install roots instead of writing through symlinks to arbitrary locations.
        for url in [paths.state, paths.target.deletingLastPathComponent(), paths.agent.deletingLastPathComponent(), paths.target, paths.legacy, paths.agent, paths.legacyAgent] {
            let base = paths.home.standardizedFileURL.path
            guard url.path.hasPrefix(base + "/") else { throw InstallFailure("安装位置不属于当前用户。") }
            var current = paths.home
            // resolvingSymlinksInPath does not resolve existing ancestors of a missing leaf on Darwin.
            // lstat every component, including a dangling link, before mkdir/open/ditto can follow it.
            for component in [""] + String(url.path.dropFirst(base.count + 1)).split(separator: "/").map(String.init) {
                if !component.isEmpty { current.appendPathComponent(component) }
                var value = stat()
                if lstat(current.path, &value) == 0 {
                    guard value.st_mode & S_IFMT != S_IFLNK else { throw InstallFailure("安装路径是链接，未覆盖：\(current.path)") }
                } else if errno != ENOENT { throw InstallFailure("无法检查安装路径：\(current.path)（\(errno)）") }
            }
        }
    }
    private func copy(_ from: URL, _ to: URL) async throws { try await run("/usr/bin/ditto", [from.path, to.path]) }
    private func validateExistingOwners() throws {
        for (bundle, executable) in [(paths.target, "APT"), (paths.legacy, "EchoMemoryIME")] where exists(bundle) {
            let info = try metadata(bundle)
            guard info["CFBundleIdentifier"] as? String == APTInputSource.bundleID,
                  info["CFBundleExecutable"] as? String == executable else {
                throw InstallFailure("安装位置被其它应用占用，未改动它：\(bundle.path)")
            }
        }
        if exists(paths.systemTarget) {
            // Only a fixed, canonical system installation may participate in migration.
            var current = paths.systemTarget.appendingPathComponent("Contents/MacOS/APT")
            let systemRoot = paths.systemTarget.deletingLastPathComponent().deletingLastPathComponent()
            while true {
                var value = stat()
                guard lstat(current.path, &value) == 0, value.st_mode & S_IFMT != S_IFLNK else {
                    throw InstallFailure("系统 APT 安装路径无效或包含链接，未改动它：\(current.path)")
                }
                if current == systemRoot { break }
                current.deleteLastPathComponent()
            }
            let info = try metadata(paths.systemTarget)
            guard info["CFBundleIdentifier"] as? String == APTInputSource.bundleID,
                  info["CFBundleExecutable"] as? String == "APT",
                  info["InputMethodConnectionName"] as? String == APTInputSource.bundleID + "_Connection" else {
                throw InstallFailure("系统安装位置不属于 APT，未改动它：\(paths.systemTarget.path)")
            }
            hadSystem = true
        }
        for (agent, label) in [(paths.agent, "local.apt.inputmethod"), (paths.legacyAgent, "local.echo.inputmethod.memory")] where exists(agent) {
            guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent), format: nil) as? [String: Any],
                  info["Label"] as? String == label,
                  let executable = (info["ProgramArguments"] as? [String])?.first,
                  ([targetExecutable.path, legacyExecutable.path] + (hadSystem ? [systemExecutable.path] : [])).contains(executable) else {
                throw InstallFailure("启动项不属于此 APT 安装，未覆盖它：\(agent.path)")
            }
            if previousExecutable == nil {
                previousExecutable = URL(fileURLWithPath: executable)
                previousBundle = previousExecutable!.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                previousAgent = agent
            }
        }
    }
    private func backup() async throws {
        step("保留旧版本")
        hadTarget = exists(paths.target); hadLegacy = exists(paths.legacy)
        hadAgent = exists(paths.agent); hadLegacyAgent = exists(paths.legacyAgent)
        for (present, from, name) in [(hadTarget, paths.target, "previous.app"), (hadLegacy, paths.legacy, "previous-echo.app"), (hadAgent, paths.agent, "previous-agent.plist"), (hadLegacyAgent, paths.legacyAgent, "previous-echo-agent.plist")] where present {
            try await copy(from, session.appendingPathComponent(name))
        }
        if hadSystem {
            try await copy(paths.systemTarget, session.appendingPathComponent("previous-system.app"))
            try json(["bundle": paths.systemTarget.path, "action": "archive_outside_input_methods_with_admin_authorization"], "system-installation.json")
        }
    }
    private func commands(_ executable: URL) async throws -> [String] {
        let found = try await run("/usr/bin/pgrep", ["-u", String(getuid()), "-x", executable.lastPathComponent], required: false)
        guard found.status == 0 || found.status == 1 else { throw InstallFailure("无法检查输入法进程：\(found.output)") }
        var pids: [String] = []
        for pid in found.output.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard Int32(pid) != nil else { throw InstallFailure("进程编号无效。") }
            let command = try await run("/bin/ps", ["-ww", "-p", pid, "-o", "args="], required: false).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if command == executable.path || command.hasPrefix(executable.path + " ") { pids.append(pid) }
        }
        return pids.sorted()
    }
    private var targetExecutable: URL { paths.target.appendingPathComponent("Contents/MacOS/APT") }
    private var legacyExecutable: URL { paths.legacy.appendingPathComponent("Contents/MacOS/EchoMemoryIME") }
    private var systemExecutable: URL { paths.systemTarget.appendingPathComponent("Contents/MacOS/APT") }
    private func stopInstalled() async throws {
        for executable in [targetExecutable, legacyExecutable] + (hadSystem ? [systemExecutable] : []) {
            for pid in try await commands(executable) {
                // Recheck ownership and the exact executable immediately before signalling.
                guard try await commands(executable).contains(pid) else { continue }
                try await run("/bin/kill", ["-TERM", pid], required: false)
            }
            var stopped = false
            for _ in 0..<50 {
                if try await commands(executable).isEmpty { stopped = true; break }
                try await system.pause(100_000_000)
            }
            guard stopped else { throw InstallFailure("旧输入法尚未退出；保留其文件，请稍后重试。") }
        }
    }
    private func bootout() async throws {
        // Recheck loaded jobs too: an absent/on-disk plist cannot authorize stopping a foreign job.
        try await validateRunningOwners()
        for label in ["local.apt.inputmethod", "local.echo.inputmethod.memory"] {
            let service = paths.domain + "/" + label
            if try await run("/bin/launchctl", ["print", service], required: false).status == 0 {
                try await run("/bin/launchctl", ["bootout", service])
            }
        }
    }
    private func validateRunningOwners(requireSystemProcessOwner: Bool = false) async throws {
        let owned = [(paths.target, targetExecutable), (paths.legacy, legacyExecutable)]
            .filter { exists($0.0) }.map { $0.1.path } + (hadSystem ? [systemExecutable.path] : [])
        var controlledSystemPIDs: Set<String> = []
        for label in ["local.apt.inputmethod", "local.echo.inputmethod.memory"] {
            let result = try await run("/bin/launchctl", ["print", paths.domain + "/" + label], required: false)
            if result.status == 113 { continue }
            let line = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("program = ") }
            guard result.status == 0, let line, owned.contains(String(line.dropFirst("program = ".count))) else {
                throw InstallFailure("已加载的启动项不属于已校验的 APT，未停止它：\(label)（\(result.status)）。\n\(result.output)")
            }
            if String(line.dropFirst("program = ".count)) == systemExecutable.path,
               let range = result.output.range(of: #"\bpid = (\d+)"#, options: .regularExpression) {
                controlledSystemPIDs.insert(result.output[range].split(separator: "=").last!.trimmingCharacters(in: .whitespaces))
            }
        }
        if requireSystemProcessOwner, hadSystem {
            let pids = Set(try await commands(systemExecutable))
            guard pids.isSubset(of: controlledSystemPIDs) else {
                throw InstallFailure("系统目录中的 APT 进程由其它启动方式管理，未停止它。请先停用原启动方式，再点击安装／修复。")
            }
        }
    }
    private func validateOtherSystemUsers() async throws {
        guard hadSystem else { return }
        let found = try await run("/usr/bin/pgrep", ["-x", "APT"], required: false)
        guard found.status == 0 || found.status == 1 else { throw InstallFailure("无法核验系统旧输入法是否被其它账户使用。") }
        for pid in found.output.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard Int32(pid) != nil else { throw InstallFailure("系统输入法进程编号无效。") }
            let result = try await run("/bin/ps", ["-ww", "-p", pid, "-o", "uid=", "-o", "args="], required: false)
            let parts = result.output.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if parts.isEmpty { continue } // The process may exit between pgrep and ps.
            guard parts.count == 2, let owner = UInt32(parts[0]) else { throw InstallFailure("无法核验系统输入法进程归属，未迁移共享安装。") }
            let executable = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if owner != getuid(), executable == systemExecutable.path || executable.hasPrefix(systemExecutable.path + " ") {
                throw InstallFailure("另一个已登录账户正在使用系统目录中的 APT，未移动它。请先由该账户退出 APT，再安装／修复。")
            }
        }
    }
    private func writeAgent(_ url: URL, executable: URL, label: String) throws {
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [executable.path, "--background"], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10, "ProcessType": "Interactive", "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func strictSource(_ source: [String: Any]) throws {
        guard source["name"] as? String == APTInputSource.displayName,
              source["parent_name"] as? String == APTInputSource.displayName,
              source["selectable"] as? Bool == true,
              source["registered_bundle"] as? String == paths.target.path,
              source["resolved_bundle"] as? String == paths.target.path else { throw SessionPending(message: "系统尚未显示正确的 APT 输入源名称、启用状态或安装路径。") }
    }
    private func runtime() async throws -> Int {
        var last = ""
        for _ in 0..<30 {
            let result = try await run("/bin/launchctl", ["print", paths.domain + "/local.apt.inputmethod"], required: false)
            last = result.output
            let systemPIDs = hadSystem ? try await commands(systemExecutable) : []
            guard systemPIDs.isEmpty else { throw InstallFailure("系统目录中的旧 APT 进程仍在运行，未完成迁移；已停止安装并尝试恢复旧版。") }
            if result.status == 0, let range = last.range(of: #"\bpid = (\d+)"#, options: .regularExpression),
               let pid = Int(last[range].split(separator: "=").last!.trimmingCharacters(in: .whitespaces)),
               last.contains("\"" + APTInputSource.bundleID + "_Connection\""),
               try await commands(targetExecutable) == [String(pid)], try await commands(legacyExecutable).isEmpty,
               systemPIDs.isEmpty { return pid }
            try await system.pause(200_000_000)
        }
        note("未取得完整连接回执：\n\(last)")
        throw SessionPending(message: "输入法已复制，但本次登录尚未取得唯一运行进程和 IMK 连接。")
    }
    private func ensureSystemStopped() async throws {
        if hadSystem, try await !commands(systemExecutable).isEmpty {
            throw InstallFailure("系统目录中的旧 APT 进程仍在运行，未完成迁移；已停止安装并尝试恢复旧版。")
        }
    }
    private func result(_ status: InstallStatus, message: String, extra: [String: Any] = [:]) throws -> InstallOutcome {
        var receipt: [String: Any] = ["status": status.rawValue, "message": message, "phase": phase, "bundle": paths.target.path, "backup": session.path, "live_typing_verified": false]
        if let payload { receipt["requested_version"] = payload.version; receipt["requested_build"] = payload.build; receipt["requested_source_fingerprint"] = payload.sourceFingerprint; receipt["installer_fingerprint"] = payload.installerFingerprint }
        if hadSystem {
            receipt["system_duplicate_retained"] = exists(paths.systemTarget)
            if let retiredSystem { receipt["retired_system_bundle"] = retiredSystem.path }
        }
        let fallback = exists(paths.target) ? paths.target : exists(paths.legacy) ? paths.legacy : paths.systemTarget
        let installed = extra["previous_package_restored"] as? Bool == true ? (previousBundle ?? fallback) : fallback
        if let actual = try? metadata(installed) {
            receipt["bundle"] = installed.path
            receipt["version"] = actual["CFBundleShortVersionString"]
            receipt["build"] = actual["CFBundleVersion"]
            receipt["source_fingerprint"] = actual["APTSourceFingerprint"]
        }
        receipt.merge(extra) { _, new in new }
        if let report = catalogRepair {
            var summary: [String: Any] = ["examined": report.examined, "archived": report.archivedCount, "warnings": report.warnings]
            let detail = session.appendingPathComponent("input-source-caches/receipt.json")
            if exists(detail) { summary["detail_receipt"] = detail.path }
            receipt["input_source_cache_repair"] = summary
        }
        note("结果 \(status.rawValue)：\(message)")
        try json(receipt, "receipt.json")
        return InstallOutcome(status: status, message: message, receipt: session.appendingPathComponent("receipt.json"), log: session.appendingPathComponent("install.log"), canTest: extra["installation_checks_passed"] as? Bool == true)
    }
    // A later static recheck must not erase an actual failed selection of this build.
    // A successful new selection supersedes it; neither outcome proves physical typing.
    private func lastSelectionCheck() -> [String: Any]? {
        guard let payload, let folders = try? fm.contentsOfDirectory(at: paths.state, includingPropertiesForKeys: nil) else { return nil }
        var latest: (Date, [String: Any])?
        for folder in folders.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(100) {
            let file = folder.appendingPathComponent("receipt.json")
            guard let folderAttributes = try? fm.attributesOfItem(atPath: folder.path),
                  folderAttributes[.type] as? FileAttributeType == .typeDirectory,
                  let attributes = try? fm.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? Int, size <= 262_144,
                  let data = try? Data(contentsOf: file),
                  let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  receipt["source_fingerprint"] as? String == payload.sourceFingerprint,
                  let check = receipt["selection_check"] as? [String: Any] else { continue }
            let date = (check["checked_at_unix"] as? Double).map(Date.init(timeIntervalSince1970:)) ??
                (check["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            guard let date else { continue }
            if latest == nil || date > latest!.0 { latest = (date, check) }
        }
        return latest?.1
    }
    private func verify(registrationIssue: String? = nil, repairCatalog: Bool = false) async throws -> InstallOutcome {
        step("检查系统输入源和后台连接")
        guard let payload else { throw InstallFailure("尚未核验安装包。") }
        guard exists(paths.target) else {
            let location = exists(paths.systemTarget) ? "检测到系统目录中的旧 APT（\(paths.systemTarget.path)）。" : ""
            throw InstallFailure(location + "当前用户尚未安装此版本，请点击“安装／修复”。")
        }
        let info = try metadata(paths.target)
        guard info["CFBundleShortVersionString"] as? String == payload.version, info["CFBundleVersion"] as? String == payload.build,
              info["APTSourceFingerprint"] as? String == payload.sourceFingerprint else { throw InstallFailure("已安装的版本与此安装程序不同，请点击安装／修复。") }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", paths.target.path])
        guard try await Task.detached(operation: { try Self.inventory(self.paths.target) }).value == payload.files else { throw InstallFailure("已安装的文件与安装包不同，请点击安装／修复。") }
        // A competing live server is a hard error even when TIS also reports a stale cache.
        try await ensureSystemStopped()
        do {
            if let registrationIssue { note("注册进程待刷新，将以新进程复查：\(registrationIssue)") }
            let source = try await system.sourceInfo(paths.target)
            try strictSource(source)
            let pid = try await runtime()
            if repairCatalog, let root = paths.catalogRoot {
                step("检查并备份旧 Echo 输入法目录缓存")
                do {
                    catalogRepair = try InputSourceCatalog.repair(root: root, retired: paths.legacy, current: paths.target, backup: session.appendingPathComponent("input-source-caches"))
                    note("旧输入法缓存：已检查\(catalogRepair!.examined)，已归档\(catalogRepair!.archivedCount)，提示\(catalogRepair!.warnings.count)")
                } catch { note("旧输入法缓存未完成：\(error.localizedDescription)") }
            }
            var evidence: [String: Any] = ["pid": pid, "input_source": source, "selection_before_update": selection, "selection_verified": false, "installation_checks_passed": true, "registration_warning": registrationIssue ?? ""]
            guard source["parent_enabled"] as? Bool != nil, source["enabled"] as? Bool != nil else {
                throw SessionPending(message: "系统未返回明确的 APT 启用状态。")
            }
            if source["parent_enabled"] as? Bool == false || source["enabled"] as? Bool == false {
                evidence["installation_checks_passed"] = false
                evidence["file_runtime_checks_passed"] = true
                if let previous = lastSelectionCheck() { evidence["selection_check"] = previous }
                return try result(.waitingForUserEnable, message: "macOS 尚未启用 APT。请处理系统启用确认；未出现弹窗时，打开键盘设置添加 APT。完成后将自动复查，尚未验证实际输入。", extra: evidence)
            }
            guard source["parent_enabled"] as? Bool == true, source["enabled"] as? Bool == true else {
                throw SessionPending(message: "系统未返回明确的 APT 启用状态。")
            }
            if let previous = lastSelectionCheck(), previous["status"] as? String == "failed" {
                evidence["selection_check"] = previous
                return try result(.selectionFailed, message: "基础检查通过，但此版本上次切换失败。可重试或查看日志；重新检查不会把失败改为成功，不能据此认定需要退出登录。", extra: evidence)
            }
            let repaired = (catalogRepair?.archivedCount ?? 0) > 0 ? "已备份并刷新\(catalogRepair!.archivedCount)份旧Echo输入法目录。" : ""
            return try result(.awaitingSelection, message: "基础检查通过。\(repaired)请保存内容，按⌘Q完全退出先前不能输入的App，再重新打开、选择APT试输；只关窗口不会结束旧连接。仍失败时保留日志重查。", extra: evidence)
        } catch let error as SessionPending {
            return try await pending(error.localizedDescription)
        } catch let error as APTInputSource.Failure where error.requiresLogin {
            return try await pending(error.localizedDescription)
        }
    }
    private func pending(_ reason: String) async throws -> InstallOutcome {
        let source = (try? await system.sourceInfo(paths.target)) ?? [:]
        var evidence: [String: Any] = ["original_error": reason, "input_source": source, "selection_verified": false, "installation_checks_passed": false]
        let previous = lastSelectionCheck()
        if let previous { evidence["selection_check"] = previous }
        return try result(previous?["status"] as? String == "failed" ? .selectionFailed : .checksPending,
                          message: "系统输入源或后台连接检查尚未通过。请查看原始诊断并重试；不能由此认定需要退出登录。", extra: evidence)
    }
    private func restore() async throws -> Bool {
        guard changed else { return false }
        step("恢复旧版本")
        // Stop first; never rename an executable still in use, nor launch another copy beside it.
        try await bootout()
        try await stopInstalled()
        if let retiredSystem, exists(retiredSystem) {
            guard !exists(paths.systemTarget) else { throw InstallFailure("恢复位置已存在另一个系统包，未覆盖它：\(paths.systemTarget.path)") }
            step("恢复系统目录旧输入法（需要管理员授权）")
            try await system.moveSystemBundle(from: retiredSystem, to: paths.systemTarget)
        }
        if retiredSystem != nil, !exists(paths.systemTarget) {
            throw InstallFailure("系统旧包及其系统归档均不在预期位置，未覆盖任何文件；请保留安装日志与 previous-system.app 备份。")
        }
        if exists(paths.target) {
            try await run(Self.registry, ["-u", paths.target.path], required: false)
            try fm.moveItem(at: paths.target, to: session.appendingPathComponent("failed.app"))
        }
        if hadTarget || hadLegacy || hadSystem {
            if hadTarget { try await copy(session.appendingPathComponent("previous.app"), paths.target) }
            if hadLegacy {
                if exists(paths.legacy) { try fm.moveItem(at: paths.legacy, to: session.appendingPathComponent("failed-echo.app")) }
                try await copy(session.appendingPathComponent("previous-echo.app"), paths.legacy)
            }
            for (had, name, to) in [(hadAgent, "previous-agent.plist", paths.agent), (hadLegacyAgent, "previous-echo-agent.plist", paths.legacyAgent)] {
                if exists(to) { try fm.removeItem(at: to) }
                if had { try await copy(session.appendingPathComponent(name), to) }
            }
            let bundle = previousBundle ?? (hadTarget ? paths.target : hadLegacy ? paths.legacy : paths.systemTarget)
            let executable = previousExecutable ?? (hadTarget ? targetExecutable : hadLegacy ? legacyExecutable : systemExecutable)
            let agent = previousAgent ?? (hadLegacy && !hadTarget ? paths.legacyAgent : paths.agent)
            let label = agent == paths.legacyAgent ? "local.echo.inputmethod.memory" : "local.apt.inputmethod"
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
            try await run(Self.registry, ["-f", bundle.path])
            var registrationPending: String?
            do { try system.restoreRegistration(bundle) }
            catch let error as APTInputSource.EnablePending {
                registrationPending = error.localizedDescription
                do { try json(error.evidence, "restored-enablement-pending.json") }
                catch { note("无法写入额外恢复诊断：\(error.localizedDescription)") }
                note("旧包启用待系统确认：\(error.localizedDescription)")
            }
            catch let error as APTInputSource.Failure where error.requiresLogin {
                registrationPending = error.localizedDescription
                note("旧包注册仍待系统刷新：\(error.localizedDescription)")
            }
            if !exists(agent) { try writeAgent(agent, executable: executable, label: label) }
            try await run("/bin/launchctl", ["bootstrap", paths.domain, agent.path])
            // A restored file or PID alone is not a restored input-method server.
            for _ in 0..<25 {
                let service = try await run("/bin/launchctl", ["print", paths.domain + "/" + label], required: false)
                if service.status == 0, let range = service.output.range(of: #"\bpid = (\d+)"#, options: .regularExpression),
                   let pid = Int(service.output[range].split(separator: "=").last!.trimmingCharacters(in: .whitespaces)),
                   service.output.contains("\"" + APTInputSource.bundleID + "_Connection\""),
                   try await commands(executable) == [String(pid)] {
                    if let registrationPending { throw InstallFailure("旧包及后台服务已恢复，但系统输入源仍待刷新：\(registrationPending)") }
                    return true
                }
                try await system.pause(200_000_000)
            }
            throw InstallFailure("旧包已恢复，但未取得其唯一运行进程和 IMK 连接；请重新登录。")
        }
        // A failed first install must not leave an orphan KeepAlive agent behind.
        for agent in [paths.agent, paths.legacyAgent] where exists(agent) { try fm.removeItem(at: agent) }
        return false
    }

    func perform(checkOnly: Bool = false) async throws -> InstallOutcome {
        try begin()
        defer { unlock() }
        do {
            try safeDestinations()
            try await validatePayload()
            try validateExistingOwners()
            try await validateOtherSystemUsers()
            try await validateRunningOwners(requireSystemProcessOwner: true)
            if checkOnly { return try await verify() }
            let registered = system.registeredBundles()
            try json(["paths": registered.map(\.path)], "registered-bundles-before.json")
            try await backup()
            step("准备更新输入法")
            selection = try system.prepareUpdate()
            try json(selection, "selection-before.json")
            let stage = session.appendingPathComponent("new.app")
            try await copy(paths.payload, stage)
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stage.path])
            let stagedFiles = try await Task.detached(operation: { try Self.inventory(stage) }).value
            guard stagedFiles == payload?.files else {
                note("清单差异：实际 \(stagedFiles.keys.sorted())，期望 \(payload?.files.keys.sorted() ?? [])")
                throw InstallFailure("复制后的输入法文件校验失败，未替换旧版本。")
            }
            step("安装输入法")
            changed = true
            try await bootout()
            try await stopInstalled()
            if hadSystem {
                try await validateOtherSystemUsers()
                try await run(Self.registry, ["-u", paths.systemTarget.path], required: false)
                retiredSystem = paths.systemArchive.appendingPathComponent(session.lastPathComponent + ".app")
                try json(["from": paths.systemTarget.path, "archive": retiredSystem!.path], "system-retirement-intent.json")
                step("备份系统目录旧输入法（请在 macOS 窗口授权）")
                try await system.moveSystemBundle(from: paths.systemTarget, to: retiredSystem!)
                guard !exists(paths.systemTarget) else { throw InstallFailure("系统目录旧输入法仍在原位，未安装第二份。") }
            }
            try fm.createDirectory(at: paths.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            if hadTarget { try fm.moveItem(at: paths.target, to: session.appendingPathComponent("replaced.app")) }
            if hadLegacy {
                try await run(Self.registry, ["-u", paths.legacy.path], required: false)
                try fm.moveItem(at: paths.legacy, to: session.appendingPathComponent("replaced-echo.app"))
            }
            if hadLegacyAgent { try fm.moveItem(at: paths.legacyAgent, to: session.appendingPathComponent("retired-echo-agent.plist")) }
            try fm.moveItem(at: stage, to: paths.target)
            step("注册并启用 APT")
            for bundle in Set(registered + [paths.legacy] + (hadSystem ? [paths.systemTarget] : [])) where bundle.standardizedFileURL != paths.target.standardizedFileURL && exists(bundle) {
                guard (try? metadata(bundle)["CFBundleIdentifier"] as? String) == APTInputSource.bundleID else { continue }
                // Stale LaunchServices entries may already be gone; strict final resolution remains mandatory.
                try await run(Self.registry, ["-u", bundle.path], required: false)
            }
            try await run(Self.registry, ["-f", paths.target.path])
            var registrationError: String?
            do { try json(try system.register(paths.target), "input-source-registration.json") }
            catch let error as APTInputSource.EnablePending { registrationError = error.localizedDescription; try json(error.evidence, "input-source-registration.json"); note("等待 macOS 启用确认") }
            catch let error as APTInputSource.Failure where error.requiresLogin { registrationError = error.localizedDescription; note("注册待确认：\(error.localizedDescription)") }
            try writeAgent(paths.agent, executable: targetExecutable, label: "local.apt.inputmethod")
            step("启动 APT 后台输入服务")
            try await run("/bin/launchctl", ["bootstrap", paths.domain, paths.agent.path])
            // Do not kill system agents or roll back a correct new bundle for a per-login cache delay.
            return try await verify(registrationIssue: registrationError, repairCatalog: true)
        } catch {
            let original = (error as? SystemMoveFailure)?.diagnostic ?? error.localizedDescription
            let display = error.localizedDescription
            let failedPhase = phase
            note("原始错误：\(original)")
            var restored = false
            var recoveryError = ""
            var recoveryDisplay = ""
            do { restored = try await restore() } catch {
                recoveryError = (error as? SystemMoveFailure)?.diagnostic ?? error.localizedDescription
                recoveryDisplay = error.localizedDescription
                note("恢复错误：\(recoveryError)")
            }
            let message = "\(failedPhase)未完成：\(display)" + (restored ? "\n已恢复旧版本。" : "") + (recoveryDisplay.isEmpty ? "" : "\n\(recoveryDisplay)")
            return try result(.failed, message: message, extra: ["failed_phase": failedPhase, "original_error": original, "previous_package_restored": restored, "recovery_error": recoveryError])
        }
    }
}

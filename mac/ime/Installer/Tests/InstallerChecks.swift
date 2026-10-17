import Cocoa

@MainActor final class FixtureSystem: InstallSystem {
    let paths: InstallPaths
    var systemMoveDenied = false
    var denyRecoveryMove = false
    var restorationSourcePending = false
    var restorationEnablePending = false
    var otherSystemUser = false
    var hideLoadedJob = false
    var running = false
    var respawnSystem = false
    var respawnActive = false
    var runningExecutable: URL?
    var restoredRegistrations: [URL] = []
    var endpoint = true
    var refuseStop = false
    var bootstrapFailures = 0
    var registrationFailure = false
    var registrationEnablePending = false
    var registrationCount = 0
    var hardRegistrationFailure = false
    var corruptAfterBootstrap = false
    var badSource = ""
    var extraBundles: [URL] = []
    var commands: [(String, [String])] = []
    init(_ paths: InstallPaths) { self.paths = paths }
    func pause(_ nanoseconds: UInt64) async throws {}
    func registeredBundles() -> [URL] { [paths.target] + extraBundles }
    func prepareUpdate() throws -> [String: Any] { ["selected_before": "fixture.abc", "selected_after": "fixture.abc"] }
    func moveSystemBundle(from: URL, to: URL) async throws {
        commands.append(("system-move", [from.path, to.path]))
        if systemMoveDenied { throw SystemMoveFailure(message: "管理员授权已取消，请重试。", diagnostic: "fixture administrator authorization cancelled") }
        if denyRecoveryMove, from.path != paths.systemTarget.path { throw SystemMoveFailure(message: "恢复系统旧包需要管理员验证，请重试。", diagnostic: "fixture reverse move authorization cancelled") }
        guard [from, to].allSatisfy({ $0.path.hasPrefix(paths.home.deletingLastPathComponent().path + "/") }) else { fatalError("system fixture escaped") }
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: from, to: to)
    }
    func restoreRegistration(_ bundle: URL) throws {
        restoredRegistrations.append(bundle)
        if restorationEnablePending { throw APTInputSource.EnablePending(evidence: ["parent_enable_status": 0, "mode_enable_status": -50]) }
        if restorationSourcePending { throw APTInputSource.Failure("fixture restored registration cache pending", requiresLogin: true) }
    }
    func register(_ bundle: URL) throws -> [String: Any] {
        registrationCount += 1
        if registrationEnablePending { throw APTInputSource.EnablePending(evidence: ["input_source": sourceValue(), "parent_enable_status": 0, "mode_enable_status": -50]) }
        if registrationFailure { throw APTInputSource.Failure("fixture 注册缓存原始错误",requiresLogin:true) }
        if hardRegistrationFailure { throw InstallFailure("fixture 注册原始错误 -50") }
        return sourceValue()
    }
    func sourceInfo(_ bundle: URL) async throws -> [String: Any] { sourceValue() }
    private func sourceValue() -> [String: Any] {
        ["name": badSource == "name" ? "Echo" : APTInputSource.displayName, "parent_name": APTInputSource.displayName,
         "enabled": badSource != "mode", "parent_enabled": badSource != "parent", "selectable": true,
         "registered_bundle": paths.target.path, "resolved_bundle": badSource == "path" ? "/fixture/wrong.app" : paths.target.path,
         "selected_id": "fixture.abc"]
    }
    func command(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        commands.append((executable, arguments))
        switch executable {
        case "/usr/bin/ditto":
            guard arguments.allSatisfy({ $0.hasPrefix(paths.home.deletingLastPathComponent().path + "/") }) else { fatalError("fixture copy escaped") }
            try FileManager.default.copyItem(atPath: arguments[0], toPath: arguments[1])
        case "/usr/bin/pgrep":
            let pids = arguments.last == "APT" ? (running ? "31415\n" : "") + (respawnActive ? "31416\n" : "") + (otherSystemUser && !arguments.contains("-u") ? "27182\n" : "") : ""
            return CommandResult(status: pids.isEmpty ? 1 : 0, output: pids)
        case "/bin/ps":
            let path = ["31416", "27182"].contains(arguments[2]) ? paths.systemTarget.appendingPathComponent("Contents/MacOS/APT") : (runningExecutable ?? paths.target.appendingPathComponent("Contents/MacOS/APT"))
            let owner = arguments.contains("uid=") ? "\(getuid() + (arguments[2] == "27182" ? 1 : 0)) " : ""
            return CommandResult(status: 0, output: owner + path.path + " --background\n")
        case "/bin/kill":
            if !refuseStop {
                if arguments.last == "31416" { respawnActive = false } else { running = false }
            }
        case "/bin/launchctl":
            if arguments[0] == "bootstrap" {
                if bootstrapFailures > 0 { bootstrapFailures -= 1; return CommandResult(status: 5, output: "fixture bootstrap ORIGINAL failure") }
                running = true
                let agent = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[2])), format: nil) as! [String: Any]
                runningExecutable = URL(fileURLWithPath: (agent["ProgramArguments"] as! [String])[0])
                if respawnSystem { respawnActive = true; respawnSystem = false }
                if corruptAfterBootstrap {
                    corruptAfterBootstrap = false
                    try "damaged after copying".write(to: paths.target.appendingPathComponent("Contents/MacOS/APT"), atomically: true, encoding: .utf8)
                }
            } else if arguments[0] == "bootout" { if !refuseStop { running = false } }
            else if arguments[0] == "print" {
                if hideLoadedJob { return CommandResult(status: 113, output: "service absent") }
                return CommandResult(status: running && arguments[1].hasSuffix("/local.apt.inputmethod") ? 0 : 113,
                                     output: running ? "program = \((runningExecutable ?? paths.target.appendingPathComponent("Contents/MacOS/APT")).path)\npid = 31415\n" + (endpoint ? "\"local.echo.inputmethod.memory_Connection\"" : "") : "service absent")
            }
        case IMEInstaller.registry:
            if arguments[0] == "-u" { return CommandResult(status: 1, output: "already unregistered -10814") }
        default: break
        }
        return CommandResult(status: 0, output: "")
    }
}

@MainActor final class InstallFixture {
    let root: URL
    let paths: InstallPaths
    let system: FixtureSystem
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("apt-installer-check-\(UUID().uuidString)")
        paths = InstallPaths(home: root.appendingPathComponent("home"), resources: root.appendingPathComponent("resources"), systemTarget: root.appendingPathComponent("system/Input Methods/APT.app"), systemArchive: root.appendingPathComponent("system-backups"), catalogRoot: root.appendingPathComponent("catalogs"))
        system = FixtureSystem(paths)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.catalogRoot!, withIntermediateDirectories: true)
        try makePackage(paths.payload, version: "0.17.2", build: "61")
        try "fixture release notes".write(to: paths.resources.appendingPathComponent("ReleaseNotes.md"), atomically: true, encoding: .utf8)
        try seal()
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func makePackage(_ url: URL, version: String = "0.17.1", build: String = "60") throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": APTInputSource.bundleID, "CFBundleExecutable": "APT", "CFBundleDisplayName": APTInputSource.displayName,
            "CFBundleShortVersionString": version, "CFBundleVersion": build, "APTSourceFingerprint": "fixture-fingerprint",
            "InputMethodConnectionName": APTInputSource.bundleID + "_Connection", "InputMethodServerControllerClass": "EchoInputController", "TISInputSourceID": APTInputSource.bundleID,
            "ComponentInputModeDict": ["tsVisibleInputModeOrderedArrayKey": [APTInputSource.modeID], "tsInputModeListKey": [APTInputSource.modeID: ["TISInputSourceID": APTInputSource.modeID, "TISIntendedLanguage": "zh-Hans", "tsInputModeIsVisibleKey": true, "tsInputModeDefaultStateKey": true]]]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try "fixture executable \(build)".write(to: contents.appendingPathComponent("MacOS/APT"), atomically: true, encoding: .utf8)
    }
    func systemInstall() throws {
        try makePackage(paths.systemTarget)
        try FileManager.default.createDirectory(at: paths.agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["Label": "local.apt.inputmethod", "ProgramArguments": [paths.systemTarget.appendingPathComponent("Contents/MacOS/APT").path, "--background"], "KeepAlive": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: paths.agent)
        system.running = true
        system.runningExecutable = paths.systemTarget.appendingPathComponent("Contents/MacOS/APT")
        system.extraBundles = [paths.systemTarget]
    }
    func seal() throws {
        let value = PayloadManifest(version: "0.17.2", build: "61", sourceFingerprint: "fixture-fingerprint", installerFingerprint: "fixture-installer", files: try IMEInstaller.inventory(paths.payload))
        try JSONEncoder().encode(value).write(to: paths.resources.appendingPathComponent("PayloadManifest.json"))
    }
    func run(checkOnly: Bool = false) async throws -> InstallOutcome { try await IMEInstaller(paths: paths, system: system).perform(checkOnly: checkOnly) }
    func receipt(_ outcome: InstallOutcome) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: outcome.receipt)) as! [String: Any] }
}

@main struct InstallerChecks {
    @MainActor static func main() async throws {
        var passed = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw InstallFailure("CHECK FAILED: " + message) }
        }
        func check(_ name: String, _ body: () async throws -> Void) async throws {
            try await body(); passed += 1; print("PASS \(name)"); fflush(stdout)
        }
        func catalog(_ fixture: InstallFixture, _ client: String, _ content: String, name: String = "com.apple.IntlDataCache.le.kbdx") throws -> URL {
            let folder = fixture.paths.catalogRoot!.appendingPathComponent(client)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name)
            try Data(content.utf8).write(to: file)
            return file
        }
        func stale(_ fixture: InstallFixture) -> String { fixture.paths.legacy.path + "\n" + APTInputSource.bundleID }
        func repair(_ fixture: InstallFixture, before: ((URL) throws -> Void)? = nil, after: ((URL) throws -> Void)? = nil) throws -> InputSourceCatalog.Report {
            try InputSourceCatalog.repair(root: fixture.paths.catalogRoot!, retired: fixture.paths.legacy, current: fixture.paths.target,
                                          backup: fixture.root.appendingPathComponent("catalog-backup"), beforeMove: before, afterMove: after)
        }
        try await check("only retired Echo input catalogs are archived with private receipt and exact hash") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target)
            let old = try catalog(f, "fixture.editor", stale(f))
            let current = try catalog(f, "fixture.current", f.paths.target.path + APTInputSource.bundleID)
            let unrelated = try catalog(f, "fixture.editor", stale(f), name: "dictionary.txt")
            let bytes = try Data(contentsOf: old), result = try repair(f)
            try expect(result.archivedCount == 1 && !FileManager.default.fileExists(atPath: old.path), "old source catalog archived")
            try expect(try Data(contentsOf: URL(fileURLWithPath: result.items[0].archive)) == bytes, "exact backup bytes")
            try expect(FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: unrelated.path), "current catalog and dictionary preserved")
            let folder = f.root.appendingPathComponent("catalog-backup")
            try expect((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) == 0o700, "private folder")
            try expect((try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("receipt.json").path)[.posixPermissions] as? Int) == 0o600, "private receipt")
        }
        try await check("mixed current and retired paths still rebuild the stale catalog") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target)
            _ = try catalog(f, "fixture.mixed", stale(f) + f.paths.target.path)
            try expect(try repair(f).archivedCount == 1, "a current entry does not hide a stale duplicate")
        }
        try await check("linked files, linked directories and hardlinks never redirect catalog repair") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target)
            let outside = f.root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let file = outside.appendingPathComponent("com.apple.IntlDataCache.le.kbdx"); let bytes = Data(stale(f).utf8); try bytes.write(to: file)
            try FileManager.default.createSymbolicLink(at: f.paths.catalogRoot!.appendingPathComponent("linked"), withDestinationURL: outside)
            let link = try catalog(f, "file-link", "placeholder"); try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            let hardlink = try catalog(f, "hard-link", "placeholder"); try FileManager.default.removeItem(at: hardlink)
            try FileManager.default.linkItem(at: file, to: hardlink)
            try expect(try repair(f).archivedCount == 0 && Data(contentsOf: file) == bytes, "no linked content moved or changed")
        }
        try await check("catalog replacement racing archive is restored without claiming repair") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target)
            let file = try catalog(f, "fixture.race", stale(f)), fresh = Data("fresh catalog".utf8)
            let result = try repair(f, before: { try fresh.write(to: $0, options: .atomic) })
            try expect(result.archivedCount == 0 && result.items[0].state == "restored_changed_catalog", "post-move identity detects race")
            try expect(try Data(contentsOf: file) == fresh, "fresh catalog restored")
        }
        try await check("parent directory replacement cannot redirect a catalog archive") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target)
            let file = try catalog(f, "fixture.swap", stale(f)), folder = file.deletingLastPathComponent()
            let outside = f.root.appendingPathComponent("external"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let external = outside.appendingPathComponent(file.lastPathComponent), bytes = Data(stale(f).utf8)
            try bytes.write(to: external)
            let original = f.root.appendingPathComponent("original-cache")
            let result = try repair(f, before: { _ in
                try FileManager.default.moveItem(at: folder, to: original)
                try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
            })
            try expect(result.archivedCount == 0 && result.items[0].state == "preserved", "changed parent is not followed")
            try expect(try Data(contentsOf: external) == bytes && FileManager.default.fileExists(atPath: original.appendingPathComponent(file.lastPathComponent).path), "both original and external files preserved")
        }
        try await check("unreadable application cache directories are reported") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target)
            let file = try catalog(f, "fixture.unreadable", stale(f)), folder = file.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            let result = try repair(f)
            try expect(result.archivedCount == 0 && result.warnings.contains(where: { $0.contains("fixture.unreadable") }), "permission failure cannot be reported as an empty scan")
        }
        try await check("catalog regeneration racing restore preserves both files without overwrite") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target)
            let file = try catalog(f, "fixture.conflict", stale(f)), moved = Data("first fresh catalog".utf8), regenerated = Data("second fresh catalog".utf8)
            let result = try repair(f, before: { try moved.write(to: $0, options: .atomic) }, after: { try regenerated.write(to: $0, options: .atomic) })
            try expect(result.archivedCount == 0 && result.items[0].state == "conflict_both_preserved", "exclusive restore refuses existing file")
            try expect(try Data(contentsOf: file) == regenerated && Data(contentsOf: URL(fileURLWithPath: result.items[0].archive)) == moved, "both versions retained")
        }
        try await check("catalog repair never overwrites an existing backup or a linked root") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target)
            let file = try catalog(f, "fixture.editor", stale(f)), backup = f.root.appendingPathComponent("catalog-backup")
            try Data("preserve existing backup".utf8).write(to: backup)
            try expect(try repair(f).archivedCount == 0 && FileManager.default.fileExists(atPath: file.path), "existing backup not overwritten")
            let alias = f.root.appendingPathComponent("alias-cache"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.paths.catalogRoot!)
            do { _ = try InputSourceCatalog.repair(root: alias, retired: f.paths.legacy, current: f.paths.target, backup: f.root.appendingPathComponent("another-backup")); throw InstallFailure("linked root accepted") }
            catch is InputSourceCatalog.Failure {}
        }
        try await check("live legacy install, oversized catalogs and unrelated identity stay untouched") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target)
            let wrong = try catalog(f, "fixture.foreign", f.paths.legacy.path + "foreign.identity")
            let large = try catalog(f, "fixture.large", stale(f) + String(repeating: "x", count: 2_000_000))
            try expect(try repair(f).archivedCount == 0 && FileManager.default.fileExists(atPath: wrong.path) && FileManager.default.fileExists(atPath: large.path), "no broad cache deletion")
            try f.makePackage(f.paths.legacy)
            do { _ = try repair(f); throw InstallFailure("live legacy install accepted") }
            catch is InputSourceCatalog.Failure {}
        }
        try await check("install repairs stale catalog once, while check-only remains read-only") {
            let f = try InstallFixture(); let file = try catalog(f, "fixture.editor", stale(f))
            let installed = try await f.run()
            try expect(installed.status == .awaitingSelection && (try f.receipt(installed)["input_source_cache_repair"] as? [String: Any])?["archived"] as? Int == 1, "repair is part of install, never claims real input")
            try Data(stale(f).utf8).write(to: file)
            let checked = try await f.run(checkOnly: true)
            try expect(checked.status == .awaitingSelection && FileManager.default.fileExists(atPath: file.path), "recheck does not mutate cache")
        }
        try await check("failed final package verification never archives client catalogs") {
            let f = try InstallFixture(); let file = try catalog(f, "fixture.editor", stale(f))
            f.system.corruptAfterBootstrap = true
            let result = try await f.run()
            try expect(result.status == .failed && FileManager.default.fileExists(atPath: file.path), "cache repair waits for verified installed package")
        }
        try await check("fresh install: exact receipt, files, agent, no personal data") {
            let f = try InstallFixture(); let result = try await f.run()
            if result.status != .awaitingSelection { print(try String(contentsOf: result.log)); fflush(stdout) }
            try expect(result.status == .awaitingSelection, result.message)
            let receipt = try f.receipt(result)
            try expect(receipt["pid"] as? Int == 31415 && receipt["live_typing_verified"] as? Bool == false, "runtime != real typing")
            let agent = try PropertyListSerialization.propertyList(from: Data(contentsOf: f.paths.agent), format: nil) as! [String: Any]
            try expect((agent["ProgramArguments"] as? [String])?.first == f.paths.target.appendingPathComponent("Contents/MacOS/APT").path, "agent path")
            try expect(!f.system.commands.contains(where: { $0.0.contains("python") }), "no runtime Python")
        }
        try await check("update error restores old bytes and running process, keeps original stderr") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target); f.system.running = true; f.system.bootstrapFailures = 1
            let old = try Data(contentsOf: f.paths.target.appendingPathComponent("Contents/MacOS/APT"))
            let result = try await f.run(); let receipt = try f.receipt(result)
            try expect(result.status == .failed && receipt["previous_package_restored"] as? Bool == true, "rollback receipt")
            try expect(receipt["version"] as? String == "0.17.1" && receipt["requested_version"] as? String == "0.17.2", "restored version differs from requested package")
            try expect(try Data(contentsOf: f.paths.target.appendingPathComponent("Contents/MacOS/APT")) == old && f.system.running, "old executable restored")
            try expect((receipt["original_error"] as? String)?.contains("ORIGINAL failure") == true, "original error preserved")
            try expect(try String(contentsOf: result.log).contains("ORIGINAL failure"), "durable original log")
        }
        try await check("refusing old process: no replaced bundle, no duplicate bootstrap") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target); f.system.running = true; f.system.refuseStop = true
            let old = try Data(contentsOf: f.paths.target.appendingPathComponent("Contents/MacOS/APT"))
            let result = try await f.run()
            try expect(result.status == .failed, "refusal failed")
            try expect(try Data(contentsOf: f.paths.target.appendingPathComponent("Contents/MacOS/APT")) == old, "refusing executable untouched")
            try expect(!f.system.commands.contains(where: { $0.1.first == "bootstrap" }), "no duplicate launch")
        }
        for bad in ["path", "name"] {
            try await check("reject incorrect source \(bad) as incomplete") {
                let f = try InstallFixture(); f.system.badSource = bad
                let result = try await f.run()
                try expect(result.status == .checksPending && f.system.running, "source mismatch must not be success")
                try expect(try f.receipt(result)["live_typing_verified"] as? Bool == false, "no fake typing")
            }
        }
        try await check("missing IMK endpoint: no success even though process alive") {
            let f = try InstallFixture(); f.system.endpoint = false
            let result = try await f.run()
            try expect(result.status == .checksPending && f.system.running, "endpoint mandatory")
        }
        try await check("fresh source check supersedes registration process cache without claiming selection") {
            let f = try InstallFixture(); f.system.registrationFailure = true
            let result = try await f.run()
            try expect(result.status == .awaitingSelection && result.canTest && (try f.receipt(result)["registration_warning"] as? String)?.contains("缓存原始错误") == true, "registration warning retained; fresh check still not a selection pass")
        }
        try await check("hard registration error restores old version instead of login guidance") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target); f.system.running = true; f.system.hardRegistrationFailure = true
            let result = try await f.run()
            try expect(result.status == .failed && (try f.receipt(result)["previous_package_restored"] as? Bool) == true, "hard registration rollback")
        }
        for part in ["parent", "mode"] {
            try await check("pending \(part) enable retains installation, Allow recheck never enables again") {
                let f = try InstallFixture(); f.system.badSource = part
                let pending = try await f.run(), receipt = try f.receipt(pending)
                try expect(pending.status == .waitingForUserEnable && !pending.canTest && f.system.running, "consent is pending, not failed or usable")
                try expect(receipt["file_runtime_checks_passed"] as? Bool == true && receipt["installation_checks_passed"] as? Bool == false, "file/runtime evidence kept separate")
                let count = f.system.commands.count
                _ = try await f.run(checkOnly: true)
                try expect(f.system.registrationCount == 1 && !f.system.commands.dropFirst(count).contains(where: { $0.1.first == "bootstrap" || $0.1.first == "bootout" }), "waiting does not re-enable or restart")
                f.system.badSource = ""
                let allowed = try await f.run(checkOnly: true)
                try expect(allowed.status == .awaitingSelection && allowed.canTest && f.system.registrationCount == 1, "Allow followed by full read-only check still requires real input")
            }
        }
        try await check("child enable pending preserves OSStatus and never rolls back the new package") {
            let f = try InstallFixture(); f.system.registrationEnablePending = true; f.system.badSource = "parent"
            let result = try await f.run()
            let evidence = try JSONSerialization.jsonObject(with: Data(contentsOf: result.receipt.deletingLastPathComponent().appendingPathComponent("input-source-registration.json"))) as! [String: Any]
            try expect(result.status == .waitingForUserEnable && f.system.running && f.system.restoredRegistrations.isEmpty, "pending exception must not roll back")
            try expect(evidence["parent_enable_status"] as? Int == 0 && evidence["mode_enable_status"] as? Int == -50, "original statuses preserved")
        }
        try await check("pending enable does not hide missing endpoints or incorrect source identity") {
            for bad in ["endpoint", "path", "name"] {
                let f = try InstallFixture(); f.system.registrationEnablePending = true; f.system.badSource = bad == "endpoint" ? "parent" : bad
                if bad == "endpoint" { f.system.endpoint = false }
                let result = try await f.run()
                try expect(result.status == .checksPending && !result.canTest, "all strict checks still required before waiting state")
            }
        }
        try await check("pending enable keeps an earlier failed selection before and after Allow") {
            let f = try InstallFixture(); let first = try await f.run()
            try IMEInstaller.recordCheck(first, kind: "selection_check", value: ["status": "failed", "original_error": "fixture real selection failure"])
            f.system.badSource = "parent"
            let pending = try await f.run(checkOnly: true)
            try expect(pending.status == .waitingForUserEnable && (try f.receipt(pending)["selection_check"] as? [String: Any])?["original_error"] as? String == "fixture real selection failure", "waiting preserves failed selection")
            f.system.badSource = ""
            let enabled = try await f.run(checkOnly: true)
            try expect(enabled.status == .selectionFailed && enabled.canTest, "Allow does not erase real selection failure")
        }
        try await check("pending enable during rollback still restores old background service") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target); f.system.running = true
            f.system.hardRegistrationFailure = true; f.system.restorationEnablePending = true
            let result = try await f.run(), receipt = try f.receipt(result)
            try expect(result.status == .failed && f.system.running && !f.system.restoredRegistrations.isEmpty, "pending recovery does not skip old service bootstrap")
            try expect((receipt["recovery_error"] as? String)?.contains("启用") == true, "recovery enablement remains unverified")
        }
        try await check("registration classifies async enablement without weakening identity or hard errors") {
            let target = URL(fileURLWithPath: "/fixture/APT.app")
            let base: [String: Any] = ["name": APTInputSource.displayName, "parent_name": APTInputSource.displayName, "registered_bundle": target.path, "resolved_bundle": target.path, "selectable": true, "parent_enabled": false, "enabled": true]
            for status: Int32 in [0, -50] {
                do { _ = try APTInputSource.registrationResult(base, at: target, parentStatus: 0, modeStatus: status, parentEnabledAtModeRequest: false); throw InstallFailure("async consent accepted as enabled") }
                catch is APTInputSource.EnablePending {}
            }
            for bad in ["parentStatus", "modeStatus", "identity"] {
                var value = base
                if bad == "identity" { value["resolved_bundle"] = "/fixture/foreign.app" }
                do { _ = try APTInputSource.registrationResult(value, at: target, parentStatus: bad == "parentStatus" ? -50 : 0, modeStatus: bad == "modeStatus" ? -1 : 0, parentEnabledAtModeRequest: false); throw InstallFailure("bad registration accepted") }
                catch is APTInputSource.Failure {}
            }
        }
        try await check("Allow racing with child paramErr never becomes a hard rollback") {
            let target = URL(fileURLWithPath: "/fixture/APT.app")
            for modeEnabled in [false, true] {
                let value: [String: Any] = ["name": APTInputSource.displayName, "parent_name": APTInputSource.displayName, "registered_bundle": target.path, "resolved_bundle": target.path, "selectable": true, "parent_enabled": true, "enabled": modeEnabled]
                do { _ = try APTInputSource.registrationResult(value, at: target, parentStatus: 0, modeStatus: -50, parentEnabledAtModeRequest: false); throw InstallFailure("raced pending error accepted as final") }
                catch let pending as APTInputSource.EnablePending {
                    try expect(pending.evidence["parent_enabled_at_mode_request"] as? Bool == false, "request-time parent state kept")
                }
            }
        }
        try await check("passive refresh ignores old generations and concurrent notifications") {
            var gate = EnablementRefreshGate()
            try expect(gate.begin() == nil, "no query before waiting result")
            gate.reset(waiting: true); let old = gate.begin()!
            try expect(gate.begin() == nil, "one query in flight")
            gate.reset(waiting: false)
            try expect(!gate.finish(old) && gate.begin() == nil, "cancelled result cannot update a new install")
            gate.reset(waiting: true); let current = gate.begin()!
            try expect(!gate.finish(old) && gate.finish(current), "stale completion cannot consume a current query")
            try expect(gate.begin() != nil, "denial allows later notification without enable retries")
        }
        try await check("post-copy payload damage is failure and rollback, never needs_login") {
            let f = try InstallFixture(); try f.makePackage(f.paths.target); f.system.running = true; f.system.corruptAfterBootstrap = true
            let result = try await f.run()
            try expect(result.status == .failed && (try f.receipt(result)["previous_package_restored"] as? Bool) == true, "damaged file rollback")
        }
        try await check("payload byte tampering fails before copy or service mutation") {
            let f = try InstallFixture()
            try "tampered".write(to: f.paths.payload.appendingPathComponent("Contents/MacOS/APT"), atomically: true, encoding: .utf8)
            let result = try await f.run()
            try expect(result.status == .failed && !FileManager.default.fileExists(atPath: f.paths.target.path), "tamper preflight")
            try expect(!f.system.commands.contains(where: { $0.0 == "/bin/launchctl" }), "no service change")
        }
        try await check("escaping payload symlink rejected") {
            let f = try InstallFixture()
            try FileManager.default.createSymbolicLink(atPath: f.paths.payload.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
            do { _ = try IMEInstaller.inventory(f.paths.payload); throw InstallFailure("escaped") }
            catch { try expect(error.localizedDescription.contains("越界"), "reject escape") }
        }
        try await check("redirected installed app rejected without touching destination") {
            let f = try InstallFixture(); let outside = f.root.appendingPathComponent("outside.app")
            try f.makePackage(outside)
            try FileManager.default.createDirectory(at: f.paths.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: f.paths.target, withDestinationURL: outside)
            do { _ = try await f.run(); throw InstallFailure("symlink accepted") }
            catch { try expect(error.localizedDescription.contains("链接") && f.system.commands.isEmpty, "destination symlink refusal") }
        }
        try await check("state ancestor symlink refused before lock or log is created") {
            let f = try InstallFixture(); let redirected = f.root.appendingPathComponent("redirected")
            try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: f.paths.home.appendingPathComponent(".local"), withDestinationURL: redirected)
            do { _ = try await f.run(); throw InstallFailure("state symlink accepted") }
            catch { try expect(error.localizedDescription.contains("链接"), "state ancestor refusal") }
            try expect(try FileManager.default.contentsOfDirectory(atPath: redirected.path).isEmpty, "no state writes through symlink")
        }
        try await check("Library ancestor link refused while install leaves are absent") {
            let f = try InstallFixture(); let redirected = f.root.appendingPathComponent("redirected-library")
            try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: f.paths.home.appendingPathComponent("Library"), withDestinationURL: redirected)
            do { _ = try await f.run(); throw InstallFailure("Library link accepted") }
            catch { try expect(error.localizedDescription.contains("链接"), "Library refusal") }
            try expect(try FileManager.default.contentsOfDirectory(atPath: redirected.path).isEmpty, "no Library redirect writes")
        }
        try await check("stale same-identity registration is idempotent and files preserved") {
            let f = try InstallFixture(); let competitor = f.root.appendingPathComponent("source copy.app")
            try f.makePackage(competitor); f.system.extraBundles = [competitor]
            let result = try await f.run()
            try expect(result.status == .awaitingSelection && FileManager.default.fileExists(atPath: competitor.path), "unregister not deletion")
        }
        for legacy in [false, true] {
            try await check("foreign identity in \(legacy ? "legacy" : "target") path remains registered and untouched") {
                let f = try InstallFixture(); let occupied = legacy ? f.paths.legacy : f.paths.target
                try f.makePackage(occupied)
                let plist = occupied.appendingPathComponent("Contents/Info.plist")
                var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
                info["CFBundleIdentifier"] = "fixture.unrelated.inputmethod"
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
                let before = try Data(contentsOf: plist)
                let result = try await f.run()
                try expect(result.status == .failed && (try Data(contentsOf: plist)) == before, "foreign bundle untouched")
                try expect(!f.system.commands.contains(where: { $0.0 == "/bin/launchctl" || $0.0 == IMEInstaller.registry || $0.0 == "/bin/kill" }), "no foreign service stop or unregister")
            }
        }
        try await check("foreign launch configuration is never overwritten") {
            let f = try InstallFixture()
            try FileManager.default.createDirectory(at: f.paths.agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = try PropertyListSerialization.data(fromPropertyList: ["Label": "fixture.other", "ProgramArguments": ["/fixture/other"]], format: .xml, options: 0)
            try content.write(to: f.paths.agent)
            let result = try await f.run()
            try expect(result.status == .failed && (try Data(contentsOf: f.paths.agent)) == content, "foreign agent preserved")
        }
        try await check("foreign live job is refused even when user plist is missing") {
            let f = try InstallFixture(); f.system.running = true
            f.system.runningExecutable = f.root.appendingPathComponent("foreign/APT")
            let result = try await f.run()
            try expect(result.status == .failed && result.message.contains("已加载的启动项"), "loaded job ownership mandatory")
            try expect(f.system.running && !f.system.commands.contains(where: { $0.1.first == "bootout" || $0.0 == "/bin/kill" || $0.0 == "/usr/bin/ditto" }), "foreign live job untouched")
        }
        try await check("system process under unknown service is never stopped") {
            let f = try InstallFixture(); try f.systemInstall(); f.system.hideLoadedJob = true
            let result = try await f.run()
            try expect(result.status == .failed && result.message.contains("其它启动方式"), "unknown keepalive must be resolved first")
            try expect(f.system.running && !f.system.commands.contains(where: { $0.1.first == "bootout" || $0.0 == "/bin/kill" || $0.0 == "/usr/bin/ditto" }), "unknown service not killed or copied")
        }
        try await check("recheck verifies retained install without recopy or restart") {
            let f = try InstallFixture(); _ = try await f.run(); f.system.commands.removeAll()
            let result = try await f.run(checkOnly: true)
            try expect(result.status == .awaitingSelection, result.message)
            try expect(!f.system.commands.contains(where: { $0.0 == "/usr/bin/ditto" || ["bootstrap", "bootout"].contains($0.1.first ?? "") }), "read-only installed recheck")
        }
        try await check("system installation migrates its user agent and preserves system bytes") {
            let f = try InstallFixture(); try f.systemInstall()
            let old = try Data(contentsOf: f.paths.systemTarget.appendingPathComponent("Contents/MacOS/APT"))
            let result = try await f.run(); let receipt = try f.receipt(result)
            try expect(result.status == .awaitingSelection, result.message)
            try expect(f.system.runningExecutable == f.paths.target.appendingPathComponent("Contents/MacOS/APT"), "user process replaces system process")
            let archive = URL(fileURLWithPath: receipt["retired_system_bundle"] as! String)
            try expect(try Data(contentsOf: archive.appendingPathComponent("Contents/MacOS/APT")) == old, "system files archived outside input-method search")
            try expect(!FileManager.default.fileExists(atPath: f.paths.systemTarget.path), "duplicate removed from search directory")
            try expect(FileManager.default.fileExists(atPath: result.receipt.deletingLastPathComponent().appendingPathComponent("previous-system.app/Contents/Info.plist").path), "system package backed up")
            try expect(receipt["system_duplicate_retained"] as? Bool == false, "retired duplicate explicit")
            try expect(f.system.commands.contains(where: { $0.0 == IMEInstaller.registry && $0.1 == ["-u", f.paths.systemTarget.path] }), "system registration retired")
        }
        try await check("shared system package in use by another UID is never moved or stopped") {
            let f = try InstallFixture(); try f.systemInstall(); f.system.otherSystemUser = true
            let result = try await f.run()
            try expect(result.status == .failed && result.message.contains("另一个已登录账户"), "shared package requires other user to stop first")
            try expect(f.system.running && !f.system.commands.contains(where: { $0.0 == "system-move" || $0.0 == "/usr/bin/ditto" || $0.0 == "/bin/kill" || $0.1.first == "bootout" }), "other account untouched")
        }
        try await check("system migration failure restores exact agent and running system path") {
            let f = try InstallFixture(); try f.systemInstall(); f.system.bootstrapFailures = 1
            let oldAgent = try Data(contentsOf: f.paths.agent)
            let result = try await f.run(); let receipt = try f.receipt(result)
            try expect(result.status == .failed && receipt["previous_package_restored"] as? Bool == true, "system rollback")
            try expect(try Data(contentsOf: f.paths.agent) == oldAgent, "original system agent bytes restored")
            try expect(f.system.running && f.system.runningExecutable == f.paths.systemTarget.appendingPathComponent("Contents/MacOS/APT"), "system process restored")
            try expect(f.system.restoredRegistrations.map(\.path) == [f.paths.systemTarget.path], "original registration restored")
            try expect(!FileManager.default.fileExists(atPath: f.paths.target.path), "new target removed")
        }
        try await check("migration with both user and system bundles restores original system agent") {
            let f = try InstallFixture(); try f.systemInstall(); try f.makePackage(f.paths.target, version: "0.16.0", build: "50")
            f.system.bootstrapFailures = 1
            let oldUser = try Data(contentsOf: f.paths.target.appendingPathComponent("Contents/MacOS/APT"))
            let result = try await f.run()
            try expect(result.status == .failed && (try Data(contentsOf: f.paths.target.appendingPathComponent("Contents/MacOS/APT"))) == oldUser, "old user copy retained")
            try expect(f.system.runningExecutable?.path == f.paths.systemTarget.appendingPathComponent("Contents/MacOS/APT").path, "original system executable restored")
            let receipt = try f.receipt(result)
            try expect(receipt["bundle"] as? String == f.paths.systemTarget.path && receipt["build"] as? String == "60", "receipt follows running restored system bundle")
        }
        try await check("restored old PID without IMK endpoint never counts as restored server") {
            let f = try InstallFixture(); try f.systemInstall(); f.system.bootstrapFailures = 1; f.system.endpoint = false
            let result = try await f.run(); let receipt = try f.receipt(result)
            try expect(result.status == .failed && receipt["previous_package_restored"] as? Bool == false, "PID alone cannot prove recovery")
            try expect((receipt["recovery_error"] as? String)?.contains("IMK") == true, "missing restored endpoint preserved")
        }
        try await check("restoration cache delay still restarts old server without claiming full recovery") {
            let f = try InstallFixture(); try f.systemInstall(); f.system.bootstrapFailures = 1; f.system.restorationSourcePending = true
            let result = try await f.run(); let receipt = try f.receipt(result)
            try expect(f.system.running && f.system.runningExecutable?.path == f.paths.systemTarget.appendingPathComponent("Contents/MacOS/APT").path, "old server restarts despite TIS cache delay")
            try expect(result.status == .failed && receipt["previous_package_restored"] as? Bool == false && (receipt["recovery_error"] as? String)?.contains("仍待刷新") == true, "cache delay stays explicit")
        }
        try await check("system process respawn is hard failure with rollback instead of login guidance") {
            let f = try InstallFixture(); try f.systemInstall(); f.system.respawnSystem = true
            let result = try await f.run(); let receipt = try f.receipt(result)
            try expect(result.status == .failed && (receipt["original_error"] as? String)?.contains("旧 APT 进程仍在运行") == true, "duplicate process is hard failure")
            try expect(receipt["previous_package_restored"] as? Bool == true && !f.system.respawnActive, "duplicate stopped and original system process restored")
        }
        for stale in ["registration", "path"] {
            try await check("system respawn plus stale \(stale) remains hard failure") {
                let f = try InstallFixture(); try f.systemInstall(); f.system.respawnSystem = true
                f.system.registrationFailure = stale == "registration"
                f.system.badSource = stale == "path" ? "path" : ""
                let result = try await f.run(); let receipt = try f.receipt(result)
                try expect(result.status == .failed && (receipt["original_error"] as? String)?.contains("旧 APT 进程仍在运行") == true, "stale TIS cannot mask duplicate server")
                try expect(receipt["previous_package_restored"] as? Bool == true && !f.system.respawnActive, "duplicate recovered")
            }
        }
        try await check("administrator cancellation restores original installation before replacing it") {
            let f = try InstallFixture(); try f.systemInstall(); f.system.systemMoveDenied = true
            let agent = try Data(contentsOf: f.paths.agent)
            let result = try await f.run(); let receipt = try f.receipt(result)
            try expect(result.status == .failed && receipt["previous_package_restored"] as? Bool == true, "cancelled authorization restores old server")
            try expect((try Data(contentsOf: f.paths.agent)) == agent && FileManager.default.fileExists(atPath: f.paths.systemTarget.path), "original root and agent retained")
            try expect(!FileManager.default.fileExists(atPath: f.paths.target.path), "no second installation on cancelled admin")
            try expect(!result.message.contains("fixture administrator") && (receipt["original_error"] as? String) == "fixture administrator authorization cancelled", "short UI with original diagnostic retained")
        }
        try await check("privileged move permits only fixed system roots and bounded safe leaf names") {
            let source = URL(fileURLWithPath: "/Library/Input Methods/APT.app")
            let archive = URL(fileURLWithPath: "/Library/Application Support/APT IME Backups/2026-10-15-test.app")
            let script = try NativeInstallSystem.systemMoveScript(from: source, to: archive)
            try expect(script.contains("/bin/mv -n") && script.contains("test ! -L") && script.contains("InputMethodConnectionName"), "protected move script")
            _ = try NativeInstallSystem.systemMoveScript(from: archive, to: source)
            let f = try InstallFixture()
            let shellFile = f.root.appendingPathComponent("migration.sh")
            try script.write(to: shellFile, atomically: true, encoding: .utf8)
            let shellSyntax = try await InstallCommand.run("/bin/sh", ["-n", shellFile.path])
            try expect(shellSyntax.status == 0, shellSyntax.output)
            let appleSyntax = try await InstallCommand.run("/usr/bin/osacompile", ["-o", f.root.appendingPathComponent("migration.scpt").path, "-e", NativeInstallSystem.systemMoveAppleScript(from: source, to: archive)])
            try expect(appleSyntax.status == 0, appleSyntax.output)
            for bad in ["/tmp/evil.app", "/Library/Application Support/APT IME Backups/a'evil.app", "/Library/Application Support/APT IME Backups/sub/evil.app"] {
                do { _ = try NativeInstallSystem.systemMoveScript(from: source, to: URL(fileURLWithPath: bad)); throw InstallFailure("unsafe root destination accepted") }
                catch { try expect(error.localizedDescription.contains("只允许"), "root path rejects arbitrary destination") }
            }
        }
        try await check("reverse move failure preserves full recovery diagnostic and concise UI") {
            let f = try InstallFixture(); try f.systemInstall(); f.system.bootstrapFailures = 1; f.system.denyRecoveryMove = true
            let result = try await f.run(); let receipt = try f.receipt(result)
            try expect(result.status == .failed && receipt["previous_package_restored"] as? Bool == false, "reverse move failure explicit")
            try expect(receipt["recovery_error"] as? String == "fixture reverse move authorization cancelled" && !result.message.contains("fixture reverse"), "root recovery stderr retained outside UI")
            try expect(try String(contentsOf: result.log).contains("fixture reverse move authorization cancelled"), "recovery diagnostic durable")
        }
        try await check("system migration refusal to stop never starts a second process") {
            let f = try InstallFixture(); try f.systemInstall(); f.system.refuseStop = true
            let result = try await f.run()
            try expect(result.status == .failed && !FileManager.default.fileExists(atPath: f.paths.target.path), "refusing system path preserved")
            try expect(!f.system.commands.contains(where: { $0.1.first == "bootstrap" }), "no duplicate bootstrap")
        }
        for kind in ["identity", "symlink", "missing"] {
            try await check("invalid system installation \(kind) refused before service mutation") {
                let f = try InstallFixture(); try f.systemInstall()
                if kind == "identity" {
                    let path = f.paths.systemTarget.appendingPathComponent("Contents/Info.plist")
                    var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as! [String: Any]
                    info["CFBundleIdentifier"] = "fixture.foreign"
                    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path)
                } else if kind == "symlink" {
                    let moved = f.root.appendingPathComponent("redirected-system.app")
                    try FileManager.default.moveItem(at: f.paths.systemTarget, to: moved)
                    try FileManager.default.createSymbolicLink(at: f.paths.systemTarget, withDestinationURL: moved)
                } else { try FileManager.default.removeItem(at: f.paths.systemTarget) }
                let oldAgent = try Data(contentsOf: f.paths.agent)
                let result = try await f.run()
                try expect(result.status == .failed && (try Data(contentsOf: f.paths.agent)) == oldAgent, "invalid system migration refused")
                try expect(!f.system.commands.contains(where: { $0.0 == "/bin/launchctl" || $0.0 == "/bin/kill" || $0.0 == IMEInstaller.registry }), "no foreign system mutation")
            }
        }
        try await check("recheck without user target explains install action and retains system install") {
            let f = try InstallFixture(); try f.systemInstall()
            let result = try await f.run(checkOnly: true)
            try expect(result.status == .failed && result.message.contains("尚未安装") && result.message.contains("安装／修复"), "actionable missing target")
            try expect(f.system.running && !f.system.commands.contains(where: { $0.0 == "/bin/kill" || $0.0 == "/usr/bin/ditto" || ($0.0 == "/bin/launchctl" && $0.1.first != "print") }), "read only recheck")
        }
        try await check("failed first install removes new bundle and KeepAlive agent") {
            let f = try InstallFixture(); f.system.bootstrapFailures = 1
            let result = try await f.run()
            try expect(result.status == .failed, "bootstrap failure retained")
            try expect(!FileManager.default.fileExists(atPath: f.paths.target.path) && !FileManager.default.fileExists(atPath: f.paths.agent.path), "no orphan bundle or agent")
        }
        try await check("selection failure downgrades receipt and cannot be erased by static recheck") {
            let f = try InstallFixture(); let result = try await f.run()
            try IMEInstaller.recordCheck(result, kind: "selection_check", value: ["status": "failed", "original_error": "fixture switching reverted"])
            let receipt = try f.receipt(result)
            try expect((receipt["selection_check"] as? [String: Any])?["original_error"] as? String == "fixture switching reverted", "switch original error persisted")
            try expect(receipt["status"] as? String == "selection_failed" && receipt["selection_verified"] as? Bool == false, "failure cannot coexist with ready or imply a login diagnosis")
            do {
                try IMEInstaller.recordCheck(result, kind: "typing_check", value: ["status": "confirmed", "method": "user_reported"])
                throw InstallFailure("typing confirmation accepted after failed selection")
            } catch { try expect(error.localizedDescription.contains("尚未通过"), "confirmation requires successful selection") }
            let checked = try await f.run(checkOnly: true)
            let checkedReceipt = try f.receipt(checked)
            try expect(checked.status == .selectionFailed && checked.canTest && (checkedReceipt["selection_check"] as? [String: Any])?["original_error"] as? String == "fixture switching reverted", "static checks preserve actual failure and allow deliberate retry")
            try expect(try String(contentsOf: result.log).contains("fixture switching reverted"), "switch log persisted")
        }
        try await check("selection success requires current APT and remains separate from user typing report") {
            let f = try InstallFixture(); let result = try await f.run()
            do {
                try IMEInstaller.recordCheck(result, kind: "selection_check", value: ["status": "selected", "input_source": ["selected_id": "fixture.other"]])
                throw InstallFailure("other source accepted")
            } catch { try expect(error.localizedDescription.contains("没有确认"), "actual APT selection mandatory") }
            try IMEInstaller.recordCheck(result, kind: "selection_check", value: ["status": "selected", "input_source": ["selected_id": APTInputSource.modeID]])
            let apiReceipt = try f.receipt(result)
            try expect(apiReceipt["status"] as? String == "awaiting_selection" && apiReceipt["selection_verified"] as? Bool == false && apiReceipt["api_selection_observed"] as? Bool == true, "API selection does not prove a visible menu or active client")
            try IMEInstaller.recordCheck(result, kind: "typing_check", value: ["status": "confirmed", "method": "user_reported"])
            let receipt = try f.receipt(result)
            try expect(receipt["status"] as? String == "ready" && receipt["selection_verified"] as? Bool == false && receipt["verification_method"] as? String == "user_reported", "readiness is explicitly a user report")
            try expect((receipt["typing_check"] as? [String: Any])?["method"] as? String == "user_reported" && receipt["live_typing_verified"] as? Bool == false, "user report never synthetic live pass")
            try IMEInstaller.recordCheck(result, kind: "selection_check", value: ["status": "failed", "original_error": "fixture later failure"])
            try expect(try f.receipt(result)["typing_check"] == nil, "a later failed selection invalidates the earlier confirmation")
        }
        try await check("successful retry supersedes failed selection without recheck claiming ready") {
            let f = try InstallFixture(); let result = try await f.run()
            try IMEInstaller.recordCheck(result, kind: "selection_check", value: ["status": "failed", "original_error": "fixture original failure"])
            let retry = try await f.run(checkOnly: true)
            try IMEInstaller.recordCheck(retry, kind: "selection_check", value: ["status": "selected", "input_source": ["selected_id": APTInputSource.modeID]])
            let checked = try await f.run(checkOnly: true)
            try expect(checked.status == .awaitingSelection && checked.canTest, "latest retry supersedes failure, new static recheck still requires selection")
        }
        try await check("foreground context observation retains differing helper evidence") {
            let f = try InstallFixture(); let result = try await f.run()
            let raw: [String: Any] = ["selected_id": "fixture.other"]
            do {
                try IMEInstaller.recordCheck(result, kind: "selection_check", value: ["status": "selected", "method": "foreground_text_input_context", "input_source": raw, "foreground_selected_id": APTInputSource.modeID, "foreground_active": false])
                throw InstallFailure("inactive context accepted")
            } catch { try expect(error.localizedDescription.contains("没有确认"), "foreground must be active") }
            try IMEInstaller.recordCheck(result, kind: "selection_check", value: ["status": "selected", "method": "foreground_text_input_context", "input_source": raw, "foreground_selected_id": APTInputSource.modeID, "foreground_active": true])
            let check = try f.receipt(result)["selection_check"] as! [String: Any]
            try expect((check["input_source"] as? [String: Any])?["selected_id"] as? String == "fixture.other", "raw helper receipt is never overwritten")
        }
        try await check("failed selection survives a recheck with missing endpoint or stale source") {
            for stale in [false, true] {
                let f = try InstallFixture(); let result = try await f.run()
                try IMEInstaller.recordCheck(result, kind: "selection_check", value: ["status": "failed", "original_error": "fixture actual failure"])
                if stale { f.system.badSource = "path" } else { f.system.endpoint = false }
                let checked = try await f.run(checkOnly: true), receipt = try f.receipt(checked)
                try expect(checked.status == .selectionFailed && !checked.canTest, "pending checks retain failure without allowing an invalid installation to be tested")
                try expect((receipt["selection_check"] as? [String: Any])?["original_error"] as? String == "fixture actual failure" && receipt["original_error"] != nil, "original selection and new check errors both preserved")
            }
        }
        try await check("command failure includes stderr and own timeout terminates") {
            let result = try await InstallCommand.run("/bin/sh", ["-c", "echo fixture-stderr >&2; exit 7"])
            try expect(result.status == 7 && result.output.contains("fixture-stderr"), "stderr status")
            do { _ = try await InstallCommand.run("/bin/sleep", ["5"], timeout: 0.05); throw InstallFailure("timeout missing") }
            catch { try expect(error.localizedDescription.contains("超时"), "bounded command") }
        }
        print("\(passed) installer checks passed (isolated filesystem + simulated registration/runtime; no production writes)")
    }
}

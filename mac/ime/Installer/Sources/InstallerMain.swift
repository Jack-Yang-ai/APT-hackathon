import Cocoa
import Carbon

@MainActor final class InstallerWindow: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let heading = NSTextField(labelWithString: "安装 APT 输入法")
    private let status = NSTextField(wrappingLabelWithString: "点击安装完成文件、注册与后台检查，再核对系统菜单并试输。")
    private let detail = NSTextField(wrappingLabelWithString: "安装到当前用户。迁移系统目录旧 APT 时会请求管理员授权；设置、词库和个人记录保留。")
    private let spinner = NSProgressIndicator()
    private let install = NSButton(title: "安装并启用", target: nil, action: nil)
    private let recheck = NSButton(title: "重新检查", target: nil, action: nil)
    private let logs = NSButton(title: "查看安装日志", target: nil, action: nil)
    private let settings = NSButton(title: "打开键盘设置", target: nil, action: nil)
    private let testButton = NSButton(title: "打开试输框", target: nil, action: nil)
    private let confirmTyping = NSButton(title: "我已输入出“你好”", target: nil, action: nil)
    private let testLabel = NSTextField(wrappingLabelWithString: "从菜单栏选择 APT，再在下面输入 nihao 和空格。")
    private let testField = NSTextView()
    private var outcome: InstallOutcome?
    private var busy = false
    private var enablementGate = EnablementRefreshGate()
    private var enablementTask: Task<Void, Never>?
    private var needsPassiveRecheck = false
    private let preview: Bool

    init(preview: Bool = false) { self.preview = preview }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "退出安装器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = applicationMenu; menu.addItem(item); NSApp.mainMenu = menu
        let editItem = NSMenuItem(), editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu; menu.addItem(editItem)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 530), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "APT 输入法安装"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let root = NSView()
        window.contentView = root
        func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            view.frame = NSRect(x: x, y: y, width: w, height: h)
            root.addSubview(view)
        }
        let icon = NSImageView()
        icon.image = NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("APTAppIcon.icns"))
        icon.imageScaling = .scaleProportionallyUpOrDown
        place(icon, 30, 426, 66, 66)
        heading.font = .systemFont(ofSize: 25, weight: .semibold)
        place(heading, 116, 459, 510, 35)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let subtitle = NSTextField(labelWithString: "版本 \(version)（\(build)） · 当前用户安装")
        subtitle.textColor = .secondaryLabelColor
        place(subtitle, 118, 430, 510, 24)
        status.font = .systemFont(ofSize: 16, weight: .medium)
        place(status, 34, 322, 592, 80)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        place(detail, 34, 244, 592, 72)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        place(spinner, 34, 408, 18, 18)
        testLabel.font = .systemFont(ofSize: 13)
        place(testLabel, 34, 207, 592, 32)
        let scroll = NSScrollView(frame: NSRect(x: 34, y: 143, width: 592, height: 62))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        testField.frame = scroll.contentView.bounds
        testField.isRichText = false
        testField.font = .systemFont(ofSize: 18)
        testField.textContainerInset = NSSize(width: 8, height: 8)
        testField.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = testField; root.addSubview(scroll)
        testField.isEditable = false
        testLabel.textColor = .secondaryLabelColor
        for button in [install, recheck, logs, settings, testButton, confirmTyping] { button.bezelStyle = .rounded; button.target = self }
        install.action = #selector(startInstall); install.keyEquivalent = "\r"
        recheck.action = #selector(startCheck)
        logs.action = #selector(showLogs)
        settings.action = #selector(showSettings)
        testButton.action = #selector(startTyping)
        confirmTyping.action = #selector(typingConfirmed)
        confirmTyping.refusesFirstResponder = true
        place(testButton, 30, 101, 190, 32)
        place(confirmTyping, 222, 101, 200, 32)
        place(settings, 428, 101, 200, 32)
        place(logs, 26, 26, 150, 32)
        place(recheck, 350, 26, 125, 32)
        place(install, 482, 26, 150, 32)
        logs.isEnabled = false; testButton.isEnabled = false; confirmTyping.isEnabled = false
        if preview {
            install.isEnabled = false; recheck.isEnabled = false; settings.isEnabled = false
            status.stringValue = "安装器界面预览"
            detail.stringValue = "隔离预览不会复制、注册、启停输入法或读取个人记录。"
        }
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(enablementChanged), name: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, suspensionBehavior: .deliverImmediately)
        NotificationCenter.default.addObserver(self, selector: #selector(enablementChanged), name: NSApplication.didBecomeActiveNotification, object: NSApp)
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self); NotificationCenter.default.removeObserver(self) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) { cancelEnablementRefresh() }
    func applicationWillTerminate(_ notification: Notification) { cancelEnablementRefresh() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { busy ? .terminateCancel : .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @objc private func startInstall() { start(checkOnly: false) }
    @objc private func startCheck() { start(checkOnly: true) }
    private func start(checkOnly: Bool) {
        guard !busy, !preview else { return }
        cancelEnablementRefresh()
        busy = true; install.isEnabled = false; recheck.isEnabled = false; testButton.isEnabled = false
        confirmTyping.isEnabled = false
        testField.isEditable = false; spinner.startAnimation(nil)
        status.textColor = .labelColor
        status.stringValue = checkOnly ? "正在检查安装状态…" : "正在安装 APT 输入法…"
        detail.stringValue = "请保持安装窗口打开。"
        let core = IMEInstaller(paths: InstallPaths(home: URL(fileURLWithPath: NSHomeDirectory()), resources: Bundle.main.resourceURL!), system: NativeInstallSystem())
        core.progress = { [weak self] phase in self?.detail.stringValue = phase }
        Task { @MainActor in
            do {
                let result = try await core.perform(checkOnly: checkOnly)
                self.outcome = result
                self.logs.isEnabled = true
                switch result.status {
                case .ready, .awaitingSelection:
                    self.status.stringValue = "基础检查通过 · 等待切换验证"
                    self.status.textColor = .systemOrange
                    self.detail.stringValue = result.message
                    self.testButton.isEnabled = true; self.testField.isEditable = true
                case .waitingForUserEnable:
                    self.status.stringValue = "等待 macOS 启用确认"
                    self.status.textColor = .systemOrange
                    self.detail.stringValue = result.message
                    self.enablementGate.reset(waiting: true)
                    self.needsPassiveRecheck = true
                case .selectionFailed, .checksPending:
                    self.status.stringValue = result.canTest ? "上次切换失败 · 等待重试" : "尚未完成系统检查"
                    self.status.textColor = .systemOrange
                    self.detail.stringValue = result.message
                    self.testButton.isEnabled = result.canTest; self.testField.isEditable = result.canTest
                case .failed:
                    self.status.stringValue = checkOnly ? "检查未通过" : "安装未完成"
                    self.status.textColor = .systemRed
                    self.detail.stringValue = result.message
                }
            } catch {
                self.status.stringValue = "无法开始安装"
                self.status.textColor = .systemRed
                self.detail.stringValue = error.localizedDescription
            }
            self.busy = false; self.install.isEnabled = true; self.recheck.isEnabled = true
            self.install.title = "安装／修复"; self.spinner.stopAnimation(nil)
            if self.needsPassiveRecheck { self.needsPassiveRecheck = false; self.refreshEnablementIfWaiting() }
        }
    }
    private func cancelEnablementRefresh() {
        enablementTask?.cancel(); enablementTask = nil
        enablementGate.reset(waiting: false); needsPassiveRecheck = false
    }
    @objc private func enablementChanged() {
        guard !preview else { return }
        if busy || enablementTask != nil { needsPassiveRecheck = true; return }
        refreshEnablementIfWaiting()
    }
    private func refreshEnablementIfWaiting() {
        guard !busy, outcome?.status == .waitingForUserEnable, let token = enablementGate.begin() else { return }
        enablementTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                let target = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Input Methods/APT.app")
                let source = try await NativeInstallSystem.inputSourceCommand(target)
                guard !Task.isCancelled, let self, self.enablementGate.finish(token) else { return }
                self.enablementTask = nil
                // Observing enablement never requests it again, and never selects the IME.
                if source["parent_enabled"] as? Bool == true, source["enabled"] as? Bool == true {
                    self.start(checkOnly: true)
                } else if self.needsPassiveRecheck {
                    self.needsPassiveRecheck = false; self.refreshEnablementIfWaiting()
                }
            } catch {
                guard !Task.isCancelled, let self, self.enablementGate.finish(token) else { return }
                self.enablementTask = nil
                self.detail.stringValue = "仍在等待 macOS 启用确认。可打开键盘设置添加 APT，再点击重新检查。"
                if self.needsPassiveRecheck { self.needsPassiveRecheck = false; self.refreshEnablementIfWaiting() }
            }
        }
    }
    @objc private func showLogs() { if let outcome { NSWorkspace.shared.activateFileViewerSelecting([outcome.log, outcome.receipt]) } }
    @objc private func showSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    @objc private func startTyping() {
        guard !busy, let outcome, outcome.canTest else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(testField)
        // Do not programmatically select an IME during verification: selected-ID
        // responses can coexist with an inactive client. Let the native menu select it.
        status.stringValue = "请从菜单栏选择 APT，再在下方试输"
        status.textColor = .systemOrange
        detail.stringValue = "菜单没有 APT：在键盘设置中添加。旧 Echo 迁移后无“APT 设置…”：先点安装／修复，再保存内容、按⌘Q完全退出并重开受影响的 App；只关窗口不够。"
        testLabel.stringValue = "从菜单栏选 APT，回到下面输入 nihao 和空格。"
        confirmTyping.isEnabled = true
    }
    @objc private func typingConfirmed() {
        guard !busy, let outcome, confirmTyping.isEnabled else { return }
        guard testField.string.trimmingCharacters(in: .whitespacesAndNewlines) == "你好" else {
            testLabel.stringValue = "试输框还没有“你好”。请先从菜单栏选 APT，用键盘输入 nihao 和空格。"
            return
        }
        guard let context = testField.inputContext,
              NSApp.isActive, window.isKeyWindow, window.firstResponder === testField,
              NSTextInputContext.current === context,
              context.selectedKeyboardInputSource == APTInputSource.modeID else {
            testLabel.stringValue = "请保持此窗口在前台并选中 APT；其它输入法的文字不能作为 APT 的试输确认。"
            return
        }
        busy = true; install.isEnabled = false; recheck.isEnabled = false; testButton.isEnabled = false; confirmTyping.isEnabled = false
        Task { @MainActor in
            do {
                let bundle = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Input Methods/APT.app")
                let source = try await NativeInstallSystem.inputSourceCommand(bundle)
                guard NSApp.isActive, window.isKeyWindow, window.firstResponder === testField,
                      NSTextInputContext.current === context,
                      context.selectedKeyboardInputSource == APTInputSource.modeID,
                      testField.string.trimmingCharacters(in: .whitespacesAndNewlines) == "你好" else {
                    throw InstallFailure("确认期间窗口或输入法发生变化，请回到试输框后重试。")
                }
                try IMEInstaller.recordCheck(outcome, kind: "selection_check", value: ["status": "selected", "method": "foreground_text_input_context", "input_source": source, "foreground_selected_id": context.selectedKeyboardInputSource ?? "", "foreground_active": true])
                try IMEInstaller.recordCheck(outcome, kind: "typing_check", value: ["status": "confirmed", "method": "user_reported", "expected": "你好"])
                status.stringValue = "已记录你的 APT 试输确认"
                status.textColor = .systemGreen
                testLabel.stringValue = "你已报告输入“你好”；请继续在常用 App 中核对稳定性。"
            } catch {
                detail.stringValue = "无法保存试输确认：\(error.localizedDescription)"
                confirmTyping.isEnabled = true
            }
            busy = false; install.isEnabled = true; recheck.isEnabled = true; testButton.isEnabled = true
        }
    }

}

@main struct InstallerMain {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let app = NSApplication.shared
        let cli = args == ["--install"] || args == ["--check-installed"] || args == ["--dry-run"]
        if cli {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do {
                    if args.contains("--dry-run") {
                        // Static validation only, with no production registration or filesystem writes.
                        let resources = Bundle.main.resourceURL!
                        let manifest = try JSONDecoder().decode(PayloadManifest.self, from: Data(contentsOf: resources.appendingPathComponent("PayloadManifest.json")))
                        guard try IMEInstaller.inventory(resources.appendingPathComponent("Payload/APT.app")) == manifest.files else { throw InstallFailure("安装包校验失败。") }
                        let signature = try await InstallCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", Bundle.main.bundleURL.path])
                        guard signature.status == 0 else { throw InstallFailure(signature.output) }
                        print("APT 图形安装包校验通过：\(manifest.version) / \(manifest.build)")
                        exit(0)
                    }
                    let core = IMEInstaller(paths: InstallPaths(home: URL(fileURLWithPath: NSHomeDirectory()), resources: Bundle.main.resourceURL!), system: NativeInstallSystem())
                    core.progress = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
                    let outcome = try await core.perform(checkOnly: args.contains("--check-installed"))
                    print(outcome.message + "\n日志：" + outcome.log.path + "\n回执：" + outcome.receipt.path)
                    exit(outcome.status == .ready ? 0 : outcome.status == .failed ? 1 : 3)
                } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
            }
        } else {
            guard args.isEmpty || args == ["--preview"] else { FileHandle.standardError.write(Data("未知安装器参数。\n".utf8)); exit(2) }
            app.setActivationPolicy(.regular)
            let controller = InstallerWindow(preview: args == ["--preview"])
            app.delegate = controller
            withExtendedLifetime(controller) { app.run() }
            return
        }
        app.run()
    }
}

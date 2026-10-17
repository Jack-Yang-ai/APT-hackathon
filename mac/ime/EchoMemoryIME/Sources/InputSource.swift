import Cocoa
import Carbon

// Maintenance commands run before NSApplication is created. A short-lived registration
// process must not check in as another running instance of the actual input method.
enum APTInputSource {
    static let bundleID = "local.echo.inputmethod.memory"
    static let modeID = bundleID + ".hans"
    static let displayName = "APT 输入法"

    static func property(_ source:TISInputSource,_ key:CFString)->AnyObject? {
        guard let pointer=TISGetInputSourceProperty(source,key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
    static func source(_ id:String)->TISInputSource? {
        let filter=[kTISPropertyInputSourceID as String:id] as CFDictionary
        return (TISCreateInputSourceList(filter,true)?.takeRetainedValue() as? [TISInputSource])?.first
    }
    static var currentID:String? {
        guard let current=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return property(current,kTISPropertyInputSourceID) as? String
    }
    static func enabled(_ source:TISInputSource)->Bool { property(source,kTISPropertyInputSourceIsEnabled) as? Bool == true }
    static func info() throws -> [String:Any] {
        guard let parent=source(bundleID),let mode=source(modeID) else { throw Failure("APT 输入源尚未注册。",requiresLogin:true) }
        let icon=property(mode,kTISPropertyIconImageURL) as? URL
        let registeredBundle=icon?.absoluteURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
        return ["bundle_id":bundleID,"mode_id":modeID,
                "parent_name":property(parent,kTISPropertyLocalizedName) as? String ?? "",
                "name":property(mode,kTISPropertyLocalizedName) as? String ?? "",
                "parent_enabled":enabled(parent),"enabled":enabled(mode),
                "selectable":property(mode,kTISPropertyInputSourceIsSelectCapable) as? Bool == true,
                "icon_url":icon?.absoluteString ?? "",
                "registered_bundle":registeredBundle ?? "",
                "resolved_bundle":NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID)?.path ?? "",
                "selected_id":currentID ?? ""]
    }
    struct Failure:LocalizedError {
        let errorDescription:String?
        let requiresLogin:Bool
        init(_ message:String,requiresLogin:Bool=false) { errorDescription=message;self.requiresLogin=requiresLogin }
    }
    struct EnablePending:LocalizedError {
        let evidence:[String:Any]
        var errorDescription:String? { "macOS 尚未启用 APT。请处理系统启用确认；未出现弹窗时，在键盘设置中添加 APT。" }
    }
    static func check(_ status:OSStatus,_ action:String) throws {
        guard status == noErr else { throw Failure("\(action)失败（\(status)）。") }
    }
    static func register() throws -> [String:Any] {
        try registerInstalled(at:Bundle.main.bundleURL)
    }
    // The installer has its own bundle identity and uses the same controlled registration path.
    static func registerInstalled(at candidate:URL) throws -> [String:Any] {
        let url=candidate.standardizedFileURL
        let installed=URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Input Methods/APT.app").standardizedFileURL
        guard url.path == installed.path else { throw Failure("只能注册已安装的 ~/Library/Input Methods/APT.app；检查包不注册为生产输入源。") }
        return try registerSource(at: url)
    }
    // Recovery only accepts known installation roots, never a downloaded/staged copy.
    static func registerRestored(at candidate:URL) throws -> [String:Any] {
        let url=candidate.standardizedFileURL
        let home=URL(fileURLWithPath:NSHomeDirectory())
        let allowed=[home.appendingPathComponent("Library/Input Methods/APT.app"),
                     home.appendingPathComponent("Library/Input Methods/Echo Memory IME.app"),
                     URL(fileURLWithPath:"/Library/Input Methods/APT.app")].map(\.standardizedFileURL)
        guard allowed.contains(where: { $0.path == url.path }) else { throw Failure("只能恢复正式安装目录中的输入法注册。") }
        return try registerSource(at: url)
    }
    private static func registerSource(at installed:URL) throws -> [String:Any] {
        // Enable the parent first: Carbon requires it even when the mode's default state is on.
        try check(TISRegisterInputSource(installed as CFURL),"注册 APT")
        guard let parent=source(bundleID) else { throw Failure("注册后没有找到 APT 输入法父项。",requiresLogin:true) }
        let parentStatus=TISEnableInputSource(parent)
        try check(parentStatus,"启用 APT 父项")
        guard let mode=source(modeID) else { throw Failure("注册后没有找到 APT 中文模式。",requiresLogin:true) }
        let parentEnabledAtModeRequest=enabled(parent)
        // Updating a package must not transiently remove an already-enabled mode.
        let modeStatus=TISEnableInputSource(mode)
        let result=try info()
        return try registrationResult(result,at:installed,parentStatus:parentStatus,modeStatus:modeStatus,parentEnabledAtModeRequest:parentEnabledAtModeRequest)
    }
    // TISEnable can return before the native consent dialog has been answered.
    // A child-mode paramErr is expected while its parent is still awaiting enablement.
    static func registrationResult(_ result:[String:Any],at installed:URL,parentStatus:OSStatus,modeStatus:OSStatus,parentEnabledAtModeRequest:Bool) throws -> [String:Any] {
        try check(parentStatus,"启用 APT 父项")
        guard result["selectable"] as? Bool == true,result["parent_name"] as? String == displayName,
              result["name"] as? String == displayName,
              result["registered_bundle"] as? String == installed.path,
              result["resolved_bundle"] as? String == installed.path else { throw Failure("APT 输入源名称、注册来源或可选择状态尚未更新；需要重新登录后核验。",requiresLogin:true) }
        let evidence:[String:Any] = ["input_source":result,"parent_enable_status":parentStatus,"mode_enable_status":modeStatus,"parent_enabled_at_mode_request":parentEnabledAtModeRequest]
        if modeStatus == paramErr && !parentEnabledAtModeRequest {
            throw EnablePending(evidence:evidence)
        }
        if result["parent_enabled"] as? Bool == false, modeStatus == noErr || modeStatus == paramErr {
            throw EnablePending(evidence:evidence)
        }
        try check(modeStatus,"启用 APT 中文模式")
        if result["parent_enabled"] as? Bool == true,result["enabled"] as? Bool == false {
            throw EnablePending(evidence:evidence)
        }
        guard result["parent_enabled"] as? Bool == true,result["enabled"] as? Bool == true else {
            throw Failure("APT 输入源没有返回明确的启用状态。",requiresLogin:true)
        }
        return result
    }
    static func select() throws -> [String:Any] {
        guard let mode=source(modeID),enabled(mode),let parent=source(bundleID),enabled(parent) else { throw Failure("APT 输入源或父项未启用。") }
        try check(TISSelectInputSource(mode),"切换到 APT")
        // noErr only acknowledges the request; a failed IMK connection can switch back shortly after it.
        for _ in 0..<10 { RunLoop.current.run(until:Date().addingTimeInterval(0.1)) }
        guard currentID == modeID else { throw Failure("macOS 在选择后切回了其它输入法，尚未取得成功切换回执。") }
        return try info()
    }
    static func prepareUpdate() throws -> [String:Any] {
        let before=currentID ?? ""
        if before == modeID || before == bundleID {
            guard let fallback=TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue(),
                  let fallbackID=property(fallback,kTISPropertyInputSourceID) as? String,
                  fallbackID != modeID,fallbackID != bundleID else { throw Failure("更新前无法切到备用输入源；旧输入法保持运行。") }
            // A normal source switch commits the old client's composition before its server stops.
            try check(TISSelectInputSource(fallback),"更新前切到备用输入源")
            for _ in 0..<5 { RunLoop.current.run(until:Date().addingTimeInterval(0.1)) }
            guard let selected=currentID,selected != modeID,selected != bundleID else { throw Failure("更新前未能退出 APT 输入模式；旧输入法保持运行。") }
        }
        return ["selected_before":before,"selected_after":currentID ?? ""]
    }
    static func runCommand(_ arguments:[String])->Int32? {
        guard arguments.contains("--register") || arguments.contains("--input-source-info") || arguments.contains("--select-input-source") || arguments.contains("--registered-input-method-bundles") || arguments.contains("--prepare-input-source-update") else { return nil }
        do {
            let result:[String:Any]
            if arguments.contains("--prepare-input-source-update") {
                result=try prepareUpdate()
            } else if arguments.contains("--registered-input-method-bundles") {
                result=["bundle_id":bundleID,"paths":NSWorkspace.shared.urlsForApplications(withBundleIdentifier:bundleID).map(\.path)]
            } else {
                result = arguments.contains("--register") ? try register() : arguments.contains("--select-input-source") ? try select() : try info()
            }
            let data=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
            FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]));return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));return 1
        }
    }
}

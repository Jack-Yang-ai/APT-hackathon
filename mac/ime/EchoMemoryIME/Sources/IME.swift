import Cocoa
import InputMethodKit
import Carbon


enum IMESessionDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["APT_IMK_DIAGNOSTICS"] == "1"
    static func note(_ stage:String,session:UInt=0,client:IMKTextInput?=nil) {
        guard enabled else { return }
        let clientID=String((client?.bundleIdentifier() ?? "").filter { $0.isLetter || $0.isNumber || ".-_".contains($0) }.prefix(128))
        FileHandle.standardError.write(Data("APT_IMK uptime_ms=\(Int(ProcessInfo.processInfo.systemUptime*1000)) stage=\(stage) pid=\(getpid()) rime_session=\(session) client=\(clientID)\n".utf8))
    }
}

enum EchoTypingMode {
    static var english = UserDefaults.standard.bool(forKey:"englishMode")
    static func toggle() { english.toggle(); UserDefaults.standard.set(english,forKey:"englishMode") }
}


func echoTypedKey(_ event:NSEvent) -> String? {
    let shifted=event.modifierFlags.intersection([.shift,.control,.option]) == .shift
    if shifted,let typed=event.characters,!typed.isEmpty { return typed }
    return event.charactersIgnoringModifiers?.isEmpty == false ? event.charactersIgnoringModifiers : event.characters
}
func echoRimeKey(_ event:NSEvent) -> Int32? {
    let special:[UInt16:Int32] = [36:0xff0d,51:0xff08,117:0xffff,53:0xff1b,123:0xff51,126:0xff52,124:0xff53,125:0xff54,48:0xff09,116:0xff55,121:0xff56]
    return special[event.keyCode] ?? echoTypedKey(event)?.unicodeScalars.first.map { Int32($0.value) }
}
func echoRimeModifiers(_ flags:NSEvent.ModifierFlags) -> Int32 {
    (flags.contains(.shift) ? 1 : 0) | (flags.contains(.control) ? 4 : 0) | (flags.contains(.option) ? 8 : 0)
}
struct ShiftToggle {
    var held=false, used=false, pressedAt:TimeInterval=0


    static var mouseAge:()->TimeInterval = {
        [CGEventType.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel].map { CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:$0) }.min()!
    }
    mutating func observe(_ event:NSEvent) -> Bool {
        if event.type == .keyDown { if held || event.modifierFlags.contains(.shift) { used=true }; return false }
        let now=ProcessInfo.processInfo.systemUptime  // not event.timestamp: synthesized events may carry 0
        let down=event.modifierFlags.contains(.shift), extra = !event.modifierFlags.intersection([.command,.option,.control]).isEmpty
        let mouse = held && (now-Self.mouseAge() >= pressedAt || NSEvent.pressedMouseButtons != 0)
        let toggle = !down && held && !used && !extra && !mouse
        if down && !held { used=extra; pressedAt=now }
        else if down && (extra || ![kVK_Shift,kVK_RightShift].contains(Int(event.keyCode))) { used=true }  // e.g. Caps Lock while Shift is held
        held=down; return toggle
    }
}



enum EchoCapsLock {
    static var defaults=UserDefaults.standard  // tests swap in scratch settings
    static var switchesMode:Bool { defaults.object(forKey:"capsLockSwitchesMode") == nil || defaults.bool(forKey:"capsLockSwitchesMode") }
    static func english(_ flags:NSEvent.ModifierFlags)->Bool { EchoTypingMode.english || (switchesMode && flags.contains(.capsLock)) }

    static func letter(_ event:NSEvent)->String? {
        guard event.modifierFlags.contains(.capsLock),event.modifierFlags.intersection([.command,.control,.option]).isEmpty,
              let text=echoTypedKey(event),text.unicodeScalars.count == 1,let c=text.unicodeScalars.first,
              ("a"..."z").contains(c) || ("A"..."Z").contains(c) else { return nil }
        return text
    }
}


func echoCapsLetter(_ event:NSEvent) -> Bool {
    guard event.modifierFlags.contains(.capsLock),event.modifierFlags.intersection([.command,.control,.option]).isEmpty,
          let scalars=event.charactersIgnoringModifiers?.unicodeScalars,scalars.count == 1,let c=scalars.first else { return false }
    return ("a"..."z").contains(c) || ("A"..."Z").contains(c)
}
final class EchoMemoryHotKey {
    static let shared=EchoMemoryHotKey()
    var memory:EventHotKeyRef?, insertion:EventHotKeyRef?, voice:EventHotKeyRef?, handler:EventHandlerRef?
    var status:OSStatus=noErr, voiceStatus:OSStatus=noErr, memoryBinding="", voiceBinding=""
    var suspended=false  // while the shortcut recorder listens for new keys
    var registered:Bool { memory != nil }
    init() {
        var events=[EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed)),EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _,event,_ in
            var id=EventHotKeyID(signature:0,id:0)
            guard GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id) == noErr, id.signature == 0x4543484f else { return OSStatus(eventNotHandledErr) }

            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { if id.id == 3 { VoiceInput.shared.keyUp(at:GetEventTime(event)) }; return noErr }
            if id.id == 3 {
                if VoiceInput.shared.recording { VoiceInput.shared.keyDown(nil,at:GetEventTime(event)) }
                else if let current=EchoInputController.current { current.triggerVoice(held:true,at:GetEventTime(event)) }
                else { VoiceInput.shared.fillTargetUnavailable() }
            } else if id.id == 2 {
                if EchoInputController.current?.insertPreparedReply() != true { MemoryWorkspace.shared.message("回到目标输入框，再按 ⌃⇧Return 填入。") }
            } else if EchoInputController.current?.active == true { EchoInputController.current?.triggerMemory() }
            else if MemoryWorkspace.shared.visible { MemoryWorkspace.shared.show() }
            else { VoiceInput.shared.fillTargetUnavailable() }
            return noErr
        },events.count,&events,nil,&handler)
    }
    func sync() {
        if MemoryWorkspace.shared.demo { return }
        let active=EchoInputController.current?.active == true && !suspended
        let memoryShortcut=EchoShortcutSlot.memory.current, voiceShortcut=EchoShortcutSlot.voice.current
        if (active || MemoryWorkspace.shared.visible) && !suspended {
            if memory == nil || memoryBinding != memoryShortcut.stored {
                if let memory { UnregisterEventHotKey(memory) }; memory=nil; memoryBinding=memoryShortcut.stored
                status=RegisterEventHotKey(UInt32(memoryShortcut.keyCode),memoryShortcut.carbonModifiers,EventHotKeyID(signature:0x4543484f,id:1),GetApplicationEventTarget(),0,&memory)
            }
        } else { if let memory { UnregisterEventHotKey(memory) }; memory=nil }
        if Self.voiceShouldRegister(active:active,recording:VoiceInput.shared.recording,preparing:VoiceInput.shared.preparing,suspended:suspended) {
            if voice == nil || voiceBinding != voiceShortcut.stored {
                if let voice { UnregisterEventHotKey(voice) }; voice=nil; voiceBinding=voiceShortcut.stored
                voiceStatus=RegisterEventHotKey(UInt32(voiceShortcut.keyCode),voiceShortcut.carbonModifiers,EventHotKeyID(signature:0x4543484f,id:3),GetApplicationEventTarget(),0,&voice)
            }
        } else { if let voice { UnregisterEventHotKey(voice) }; voice=nil }
        if MemoryWorkspace.shared.pendingInsertion != nil && EchoInputController.current?.active == true {
            if insertion == nil { _ = RegisterEventHotKey(UInt32(kVK_Return),UInt32(controlKey|shiftKey),EventHotKeyID(signature:0x4543484f,id:2),GetApplicationEventTarget(),0,&insertion) }
        } else { if let insertion { UnregisterEventHotKey(insertion) }; insertion=nil }
    }
    static func voiceShouldRegister(active:Bool,recording:Bool,preparing:Bool,suspended:Bool)->Bool {
        !suspended && (active || recording || preparing)
    }
}



enum EchoCandidatePanels {
    struct Entry { let server:IMKServer; let panel:IMKCandidates }
    private static var entries:[ObjectIdentifier:Entry]=[:]
    static func panel(for server:IMKServer)->IMKCandidates? {
        let key=ObjectIdentifier(server)
        if let entry=entries[key] { return entry.panel }
        guard let panel=IMKCandidates(server:server,panelType:kIMKSingleRowSteppingCandidatePanel) else { return nil }
        panel.setAttributes([IMKCandidatesSendServerKeyEventFirst as String:true])
        entries[key]=Entry(server:server,panel:panel); return panel
    }
}

@objc(EchoInputController)
final class EchoInputController:IMKInputController {
    static weak var current:EchoInputController?
    static var lastApp:String?
    var session:UInt=0, inputClient:IMKTextInput?, panel:IMKCandidates?
    var shown:[String]=[], preedit="", active=false, shift=ShiftToggle()
    var diagnosticKeySeen=false
    var voiceContext=UUID()  // invalidates an in-flight insertion check when the input field changes
    override init!(server:IMKServer!,delegate:Any!,client:Any!) {
        IMESessionDiagnostics.note("controller_init_requested")
        super.init(server:server,delegate:delegate,client:client)
        inputClient=client as? IMKTextInput; session=ERCreate(); ERSetASCII(session,EchoTypingMode.english)
        panel=EchoCandidatePanels.panel(for:server)
        IMESessionDiagnostics.note("controller_initialized",session:session,client:inputClient)
    }
    deinit { ERDestroy(session) }
    override func recognizedEvents(_ sender:Any!) -> Int { Int(NSEvent.EventTypeMask([.keyDown,.keyUp,.flagsChanged,.leftMouseDown]).rawValue) }
    override func activateServer(_ sender:Any!) {
        IMESessionDiagnostics.note("activation_requested",session:session,client:inputClient)
        diagnosticKeySeen=false
        voiceContext=UUID()
        inputClient=sender as? IMKTextInput; active=true
        if inputClient?.bundleIdentifier() != Bundle.main.bundleIdentifier { Self.current=self }
        shift=ShiftToggle(held:NSEvent.modifierFlags.contains(.shift),used:NSEvent.modifierFlags.contains(.shift))
        ERSetASCII(session,EchoTypingMode.english); EchoMemoryHotKey.shared.sync()
        MemoryInline.shared.resume(self)
        MemoryInline.shared.typingChanged(self)
        InputMemoryRecorder.shared.start(self)
        VoiceInput.shared.observeAppChanges(); VoiceInput.shared.resume(self)
        VoiceInput.shared.prepareRecorder(self)
        IMESessionDiagnostics.note("activation_returned",session:session,client:inputClient)

        if let app=inputClient?.bundleIdentifier(),app != Bundle.main.bundleIdentifier,app != Self.lastApp {
            Self.lastApp=app
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in

                guard let self,self.active else { return }; let anchor=self.memoryAnchor()
                if anchor.height>0 { EchoHint.shared.showMode(english:EchoCapsLock.english(NSEvent.modifierFlags),near:anchor) }
            }
        }
    }
    override func deactivateServer(_ sender:Any!) {
        IMESessionDiagnostics.note("deactivation_requested",session:session,client:inputClient)
        voiceContext=UUID()
        VoiceInput.shared.suspend(self,sameApplication:NSWorkspace.shared.frontmostApplication?.bundleIdentifier == inputClient?.bundleIdentifier())
        InputMemoryRecorder.shared.flush(); InputMemoryRecorder.shared.stop()
        active=false; if Self.current === self { Self.current=nil }
        MemoryInline.shared.suspend(self)
        ERCommit(session); updateRime(); ERClear(session); panel?.hide(); EchoMemoryHotKey.shared.sync()
    }
    override func hidePalettes() { panel?.hide() }
    override func candidates(_ sender:Any!) -> [Any]! { shown }
    func updateRime() {
        let previous=preedit, state=ERSnapshot(session) as! [String:Any]
        preedit=state["preedit"] as? String ?? ""
        if let text=state["commit"] as? String,!text.isEmpty { inputClient?.insertText(text,replacementRange:NSRange(location:NSNotFound,length:0)) }
        let caret=min(state["cursor"] as? Int ?? preedit.utf16.count,preedit.utf16.count)
        if !preedit.isEmpty || !previous.isEmpty { inputClient?.setMarkedText(preedit,selectionRange:NSRange(location:caret,length:0),replacementRange:NSRange(location:NSNotFound,length:0)) }
        shown=state["candidates"] as? [String] ?? []
        if shown.isEmpty { panel?.hide() } else if let panel {
            panel.update(); panel.show(kIMKLocateCandidatesBelowHint)

            if let index=state["highlighted"] as? Int,shown.indices.contains(index) { panel.selectCandidate(withIdentifier:panel.candidateIdentifier(atLineNumber:index)) }
        }
    }

    func toggleMode() {
        ERCommitRaw(session); updateRime(); EchoTypingMode.toggle(); ERSetASCII(session,EchoTypingMode.english); panel?.hide()
        EchoHint.shared.showMode(english:EchoTypingMode.english,near:memoryAnchor())
    }
    func triggerMemory() {
        guard active,inputClient != nil else { return }

        let voice=VoiceInput.shared
        if voice.fillPending(self) { return }
        if voice.busy || voice.pending != nil || voice.terminal {
            EchoHint.shared.show(voice.busy ? "语音进行中，结束后再调用记忆" : "先填入或关闭语音浮条",near:memoryAnchor()); return
        }
        if voice.inserted { voice.cancel() }
        ERCommit(session); updateRime(); panel?.hide()
        InputMemoryRecorder.shared.flush()
        MemoryInline.shared.invoke(self)
    }
    @discardableResult func insertPreparedReply() -> Bool {
        if active,VoiceInput.shared.fillPending(self) { return true }
        guard active, let client=inputClient, client.bundleIdentifier() != Bundle.main.bundleIdentifier,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == client.bundleIdentifier() else { return false }
        guard let originalDraft=memoryDraft() else { return false };let originalContext=voiceContext
        return MemoryWorkspace.shared.fillPrepared { [weak self] text in
            guard let self,self.active,self.voiceContext==originalContext,self.inputClient as AnyObject? === client as AnyObject,
                  self.memoryDraft()==originalDraft,NSWorkspace.shared.frontmostApplication?.bundleIdentifier == client.bundleIdentifier() else { return false }
            self.ERPreparedInsert(text,client:client);return true
        }
    }
    private func ERPreparedInsert(_ text:String,client:IMKTextInput) {
        ERCommit(session); updateRime()
        InputMemoryRecorder.shared.suppressGenerated(self)
        client.insertText(text,replacementRange:NSRange(location:NSNotFound,length:0))
        InputMemoryCapture.noteGenerated(text,app:client.bundleIdentifier())
    }

    override func candidateSelected(_ candidate:NSAttributedString!) {
        guard let index=shown.firstIndex(of:candidate.string) else { return }; _ = ERSelect(session,Int32(index)); updateRime()
        MemoryInline.shared.typingChanged(self)
    }
    override func commitComposition(_ sender:Any!) { ERCommit(session); updateRime() }
    override func handle(_ event:NSEvent!,client sender:Any!) -> Bool {
        guard let event else { return false }
        let nextClient=sender as? IMKTextInput
        if inputClient as AnyObject? !== nextClient as AnyObject? { voiceContext=UUID() }
        inputClient=nextClient; guard inputClient != nil,session != 0 else { return false }
        if IMESessionDiagnostics.enabled,event.type == .keyDown,!diagnosticKeySeen {
            diagnosticKeySeen=true
            IMESessionDiagnostics.note("first_key_received_english_\(EchoTypingMode.english ? 1:0)_caps_\(event.modifierFlags.contains(.capsLock) ? 1:0)",session:session,client:inputClient)
        }

        if inputClient?.bundleIdentifier() == Bundle.main.bundleIdentifier { return false }
        if event.type == .leftMouseDown { voiceContext=UUID(); VoiceInput.shared.userMoved(self); InputMemoryRecorder.shared.willApply(nil,self); MemoryInline.shared.typingChanged(self); return false }

        if event.type == .keyUp { if event.keyCode == EchoShortcutSlot.voice.current.keyCode { VoiceInput.shared.keyUp(at:event.timestamp) }; return false }
        guard event.type == .keyDown || event.type == .flagsChanged else { return false }
        let capsEnglish=EchoCapsLock.switchesMode && event.modifierFlags.contains(.capsLock)

        if shift.observe(event) { if capsEnglish { EchoHint.shared.showMode(english:true,near:memoryAnchor()) } else { toggleMode() } }
        if event.type == .flagsChanged {
            VoiceInput.shared.observeVoiceModifiers(event.modifierFlags,at:event.timestamp)
            if event.keyCode == UInt16(kVK_CapsLock),EchoCapsLock.switchesMode {
                if capsEnglish { ERCommitRaw(session); updateRime(); panel?.hide() }
                EchoHint.shared.showMode(english:EchoCapsLock.english(event.modifierFlags),near:memoryAnchor())
            }
            return false
        }

        let voiceFirst=preedit.isEmpty && VoiceInput.shared.target === self
        if voiceFirst,VoiceInput.shared.handleEndingKey(event) { return true }
        if VoiceBinding.matches(event) { if !event.isARepeat,EchoMemoryHotKey.shared.voice == nil { triggerVoice(held:true,at:event.timestamp) }; return true }
        if voiceFirst,event.keyCode == UInt16(kVK_Escape),event.modifierFlags.intersection([.command,.control,.shift,.option]).isEmpty,VoiceInput.shared.handleEscape() { return true }
        if MemoryBinding.matches(event) { if !EchoMemoryHotKey.shared.registered { triggerMemory() }; return true }
        if preedit.isEmpty,event.keyCode == UInt16(kVK_Tab),event.modifierFlags.intersection([.command,.control,.shift,.option]).isEmpty,
           VoiceInput.shared.fillPending(self) { return true }
        if VoiceInput.shared.busy { voiceContext=UUID(); VoiceInput.shared.userMoved(self) }  // typing, paste, navigation or another command changes the target


        if event.keyCode == UInt16(kVK_ANSI_D),event.modifierFlags.intersection([.command,.control,.shift,.option]) == [.control,.shift] {
            ERCommit(session); updateRime(); panel?.hide(); InputMemoryRecorder.shared.markEdit(self); return false
        }
        let inline=MemoryInline.shared
        if preedit.isEmpty,inline.target === self,inline.valid,inline.panel.isVisible,event.modifierFlags.intersection([.command,.control,.shift,.option]).isEmpty {
            if event.keyCode == UInt16(kVK_Tab),inline.handleTab() { return true }
            if event.keyCode == UInt16(kVK_Escape) { inline.dismiss(); return true }

            if inline.interceptsArrows,event.keyCode == UInt16(kVK_DownArrow) { inline.move(1); return true }
            if inline.interceptsArrows,event.keyCode == UInt16(kVK_UpArrow) { inline.move(-1); return true }
        }
        defer { inline.typingChanged(self) }
        let edit=InputMemoryRecorder.edit(event)
        if edit != nil { VoiceEdits.shared.deleting=[kVK_Delete,kVK_ForwardDelete].contains(Int(event.keyCode)) || (event.modifierFlags.contains(.command) && event.keyCode == UInt16(kVK_ANSI_X)) }
        if edit != nil,event.keyCode == UInt16(kVK_Return),preedit.isEmpty { InputMemoryRecorder.shared.beginSegment() }
        InputMemoryRecorder.shared.willApply(edit,self)
        if event.keyCode == UInt16(kVK_Return),event.modifierFlags.intersection([.command,.control,.shift,.option]) == [.control,.shift],MemoryWorkspace.shared.pendingInsertion != nil {
            if EchoMemoryHotKey.shared.insertion == nil { _ = insertPreparedReply() }; return true
        }
        if event.modifierFlags.contains(.command) { return false }
        if EchoCapsLock.english(event.modifierFlags) {
            if EchoCapsLock.switchesMode,let letter=EchoCapsLock.letter(event) { inputClient?.insertText(letter,replacementRange:NSRange(location:NSNotFound,length:0)); return true }
            return false
        }
        if !EchoCapsLock.switchesMode,echoCapsLetter(event) { if !preedit.isEmpty { ERCommitRaw(session); updateRime() }; return false }
        ERSetASCII(session,false); guard let key=echoRimeKey(event) else { return false }
        let handled=ERProcess(session,key,echoRimeModifiers(event.modifierFlags)); updateRime(); return handled
    }
    override func menu() -> NSMenu! {
        IMESessionDiagnostics.note("menu_requested",session:session,client:inputClient)

        let menu=NSMenu(), hotkeys=EchoMemoryHotKey.shared
        func add(_ title:String,_ action:Selector,on:Bool?=nil) {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:""); item.target=self; if let on { item.state=on ? .on : .off }; menu.addItem(item)
        }
        let english=EchoCapsLock.english(NSEvent.modifierFlags)
        add("中文",#selector(chineseMenu(_:)),on:!english); add(EchoCapsLock.switchesMode ? "英文（⇧ 或 Caps Lock 切换）" : "英文（⇧ 切换）",#selector(englishMenu(_:)),on:english)
        menu.addItem(.separator())
        add("调用记忆（"+MemoryBinding.label+(hotkeys.status != noErr ? " 被占用，请在 APT 设置中更换" : "")+"）",#selector(memoryMenu(_:)))
        add("语音输入（"+VoiceBinding.label+(hotkeys.voiceStatus != noErr ? " 被占用，请在 APT 设置中更换" : "")+"）",#selector(voiceMenu(_:)))
        menu.addItem(.separator())
        add("本地输入记忆…",#selector(libraryMenu(_:)))
        menu.addItem(.separator())
        add("APT 设置…",#selector(settingsMenu(_:)))
        IMESessionDiagnostics.note("menu_returned",session:session,client:inputClient)
        return menu
    }
    @objc func chineseMenu(_ sender:Any?) { if EchoTypingMode.english { toggleMode() } }
    @objc func englishMenu(_ sender:Any?) { if !EchoTypingMode.english { toggleMode() } }
    @objc func memoryMenu(_ sender:Any?) { triggerMemory() }
    @objc func voiceMenu(_ sender:Any?) { triggerVoice() }
    @objc func libraryMenu(_ sender:Any?) { InputMemoryLibrary.shared.show() }
    @objc func workspaceMenu(_ sender:Any?) { MemoryWorkspace.shared.show() }
    @objc func settingsMenu(_ sender:Any?) { EchoSettings.shared.show() }
}
final class EchoApplicationDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) {
        if CommandLine.arguments.contains("--workspace") { MemoryWorkspace.shared.show() }

        guard !CommandLine.arguments.contains(where:{ $0.hasPrefix("--verify-") || $0.hasPrefix("--demo") }) else { return }
        AU05Controller.shared.startIfEnabled()
        MemoryActivityCoordinator.shared.start()
        GrowthMemorySync.catchUp()
        Timer.scheduledTimer(withTimeInterval:60,repeats:true) { _ in GrowthMemorySync.catchUp() }
        DispatchQueue.main.asyncAfter(deadline:.now()+120) { DayDigester.catchUp(); StyleProfile.catchUp(); MeetingNotes.catchUp() }
        Timer.scheduledTimer(withTimeInterval:1800,repeats:true) { _ in StyleProfile.catchUp(); MeetingNotes.catchUp() }
    }

    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool { EchoSettings.shared.show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        AU05Controller.shared.stop { sender.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
}

var verifyLog:URL?


func trialKey(_ source:String) throws -> String {
    switch source {
    case "memory": return try MemoryModelKey.read(interactive:true)
    case "voice": return try StepVoiceKey.read(interactive:true)
    default:
        let parts=source.hasPrefix("keychain:") ? source.dropFirst(9).split(separator:"/",maxSplits:1).map(String.init) : []
        guard parts.count == 2 else { throw MemoryFailure.message("--key is memory, voice or keychain:<service>/<account>") }
        var result:CFTypeRef?
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:parts[0],kSecAttrAccount as String:parts[1],kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,let data=result as? Data,
              let key=String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines),!key.isEmpty else { throw MemoryFailure.message("no keychain item \(parts[0]) / \(parts[1])") }
        return key
    }
}

func dayFixture(_ store:LocalMemoryStore) throws {
    let morning=ISO8601DateFormatter().date(from:"2026-10-09T01:30:00Z")!
    for (minutes,text,pasted) in [(0,"测试角色澄澄：我明天上午把相机检修报告发给小周，周五前定下来。",[String]()),(40,"小周转来：【厂商回复】镜头已更换，防抖模块需要再观察一周。我还没想好要不要继续送修。",["镜头已更换，防抖模块需要再观察一周。"]),(90,"这个预算我觉得可以先批一半，剩下的等测试结果。",[]),(300,"下午记一下：周末要整理发票，下周三前报销。",[])] {
        _ = try store.upsert(text,app:"fixture.live",id:nil,now:morning.addingTimeInterval(Double(minutes*60)),pasted:pasted)
    }
}
@main struct EchoIME {
    static func main() {
        if let result=APTInputSource.runCommand(CommandLine.arguments) { exit(result) }
        if CommandLine.arguments.contains("--agent-info") {
            let info=MemoryAgentHost.version
            let value:[String:Any] = ["schema":"apt.agent.host/1","version":info.version,"build":info.build,"source_fingerprint":info.source_fingerprint,"capabilities":["recording_sources","source_validation","source_range"]]
            if let data=try? JSONSerialization.data(withJSONObject:value) { FileHandle.standardOutput.write(data) }
            return
        }
        let app=NSApplication.shared; app.setActivationPolicy(.accessory)
        if let flag=CommandLine.arguments.firstIndex(of:"--verify-ui-review"),CommandLine.arguments.indices.contains(flag+1) {
            guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil,
                  Bundle.main.bundleIdentifier == "scratch.apt.ime.ui-review" else {
                print("请用 scripts/preview_ime.sh 运行隔离预览。");exit(2)
            }
            let output=URL(fileURLWithPath:CommandLine.arguments[flag+1])
            let data=Bundle.main.resourceURL!.appendingPathComponent("Data"),profile=output.appendingPathComponent("fixtures/Rime")
            try? FileManager.default.createDirectory(at:profile,withIntermediateDirectories:true)
            _ = ERInitialize(data.path,profile.path)
            Task { @MainActor in
                do { try await UIReviewChecks.run(to:output);exit(0) }
                catch { print("FAIL: UI review: "+error.localizedDescription);exit(1) }
            };app.run();return
        }
        if CommandLine.arguments.contains("--agent-answer") {
            signal(SIGTERM,SIG_IGN)
            let cancellation=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
            let job=Task { @MainActor in exit(await MemoryAgentHost.execute()) }
            cancellation.setEventHandler { ModelInFlight.cancelAll();MemoryAgentHost.cancelBridges();job.cancel();DispatchQueue.main.asyncAfter(deadline:.now()+2) { exit(1) } };cancellation.resume()
            withExtendedLifetime(cancellation) { app.run() };return
        }
        if let flag=CommandLine.arguments.firstIndex(of:"--verify-agent-models-live"),CommandLine.arguments.indices.contains(flag+1) {
            let audioPath=CommandLine.arguments[flag+1]
            Task { @MainActor in
                do {
                    _ = try await Task.detached { try MemoryModelKey.read(interactive:true) }.value
                    let key=try await Task.detached { try VoiceASR.readKey(interactive:true) }.value
                    let audio=try Data(contentsOf:URL(fileURLWithPath:audioPath))
                    guard VoiceWave(audio)?.hasSignal == true else { throw VoiceFailure.message("测试音频没有有效语音信号。") }
                    let transcript=try await AgentModels.asr(audio:audio,key:key,language:"zh",hotwords:[],route:VoiceASR.route)
                    _ = try await AgentModels.text(system:VoicePolisher.instructions,prompt:try SmartMemory.encoded(["transcript":transcript,"terms":"APT"]),scene:"voice_polish",background:false,deepReview:false,timeout:30,maxTokens:2048,json:true)
                    _ = try await AgentModels.text(system:"只输出一句话，不需要分析。",prompt:"虚构测试：今天整理了一张卡片。",scene:"style",background:true,deepReview:false,timeout:90,maxTokens:8192,json:false)
                    print("PASS: real common service ASR, voice cleanup and background model; synthetic audio only; no transcript or Key printed")
                    exit(0)
                } catch { print("FAIL: common service live check: "+error.localizedDescription);exit(1) }
            };app.run();return
        }
        if CommandLine.arguments.contains("--connect-growth-memory") {
            Task { @MainActor in
                do {
                    guard let token=ProcessInfo.processInfo.environment["GROWTH_CLIENT_TOKEN"],!token.isEmpty,
                          let url=GrowthMemoryConfig.url(GrowthMemoryConfig.endpoint) else { throw MemoryFailure.message("需要 APT 门禁令牌和 HTTPS 服务根地址。") }
                    try await Task.detached { try GrowthMemoryConfig.saveToken(token,to:url) }.value
                    GrowthMemoryConfig.defaults.set(url.absoluteString,forKey:"growthMemoryEndpoint")
                    GrowthMemoryConfig.defaults.set(true,forKey:"growthMemorySyncEnabled")
                    let count=try await GrowthMemorySync.shared.sync(to:url,token:token)
                    print("APT 同步已连接：确认 \(count) 条来源，令牌只存钥匙串。"); exit(0)
                } catch { print("APT 同步未完成：\(error.localizedDescription)"); exit(1) }
            }; app.run(); return
        }
        let menu=NSMenu(), edit=NSMenu(title:"编辑"), item=NSMenuItem(title:"编辑",action:nil,keyEquivalent:"")
        for (title,action,key) in [("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:action,keyEquivalent:key) }
        item.submenu=edit; menu.addItem(item); app.mainMenu=menu
        if let flag=CommandLine.arguments.firstIndex(of:"--verify-memory-ui-snapshot"),CommandLine.arguments.indices.contains(flag+1) {
            MemoryLog.shared=MemoryLog(root:FileManager.default.temporaryDirectory.appendingPathComponent("EchoMemoryUISnapshot-"+UUID().uuidString))
            verifyLog=MemoryLog.shared.root; atexit { if let folder=verifyLog { try? FileManager.default.removeItem(at:folder) } }
            Task { @MainActor in
                do { try MemoryInlineChecks.snapshot(to:URL(fileURLWithPath:CommandLine.arguments[flag+1])); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }; app.run(); return
        }
        if let flag=CommandLine.arguments.firstIndex(of:"--verify-voice-ui-snapshot"),CommandLine.arguments.indices.contains(flag+1) {
            MemoryLog.shared=MemoryLog(root:FileManager.default.temporaryDirectory.appendingPathComponent("EchoVoiceUISnapshot-"+UUID().uuidString))
            verifyLog=MemoryLog.shared.root; atexit { if let folder=verifyLog { try? FileManager.default.removeItem(at:folder) } }
            Task { @MainActor in
                do { try VoiceChecks.snapshot(to:URL(fileURLWithPath:CommandLine.arguments[flag+1]),finish:CommandLine.arguments.contains("--finish")); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }; app.run(); return
        }
        if CommandLine.arguments.contains("--verify-au05") { Task { @MainActor in do { try await AU05Checks.run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }; app.run(); return }
        if CommandLine.arguments.contains("--demo-au05") { EchoSettings.shared.show(.peripheral); app.run(); return }


        let live=["--verify-memory","--verify-completion","--verify-voice-polish-live","--verify-memory-natural-live","--verify-day-live"]
        if CommandLine.arguments.contains(where:{ live.contains($0) }) { MemoryLog.scenePrefix="verify_" }
        else if CommandLine.arguments.contains(where:{ $0.hasPrefix("--verify-") }) {
            verifyLog=FileManager.default.temporaryDirectory.appendingPathComponent("EchoMemoryLog-"+UUID().uuidString)
            MemoryLog.shared=MemoryLog(root:verifyLog!)
            atexit { if let folder=verifyLog { try? FileManager.default.removeItem(at:folder) } }
        }
        if CommandLine.arguments.contains("--verify-memory") || CommandLine.arguments.contains("--verify-completion") {
            let engine=SmartMemory()
            let query=CommandLine.arguments.contains("--verify-completion") ? "昨天示例项目需求调整的情况是：" : "告诉人物甲昨天会议的结论"
            let mode:MemoryOutputMode = CommandLine.arguments.contains("--verify-completion") ? .continuation : .reply
            Task {
                do {
                    let start=Date(); let reply=try await engine.answer(query,mode:mode,progress:{ print($0); fflush(stdout) })
                    precondition(reply.replies.allSatisfy { body in !body.contains("echo_source_") && !reply.sources.contains(where:{body.contains($0.event_id)}) })
                    print("PASS: model calls \(engine.modelCalls); real model; replies \(reply.replies.count), sources \(reply.sources.count), elapsed \(Int(Date().timeIntervalSince(start)))s; no private content logged")
                    let cached=Date(); _ = try await engine.answer(query,mode:mode)
                    print("PASS: repeated query recovered in \(Int(Date().timeIntervalSince(cached)*1000))ms"); exit(0)
                } catch { print("VERIFY FAILED: \(error.localizedDescription)"); exit(1) }
            }; app.run(); return
        }



        if let flag=CommandLine.arguments.firstIndex(of:"--trial-day") {
            let args=CommandLine.arguments
            func value(_ name:String)->String? { args.firstIndex(of:name).flatMap { args.indices.contains($0+1) ? args[$0+1] : nil } }
            guard args.indices.contains(flag+1),let endpoint=value("--endpoint"),let model=value("--model"),let out=value("--out"),let source=value("--key") else {
                print("usage: --trial-day <yyyy-MM-dd|fixture> --endpoint <url> --model <name> --key memory|voice|keychain:<service>/<account> --out <folder>"); exit(2)
            }
            let suite="echo.trial-day", scratch=UserDefaults(suiteName:suite)!
            scratch.set(endpoint,forKey:"endpoint"); scratch.set(model,forKey:"modelName"); ModelConfig.defaults=scratch
            atexit { UserDefaults.standard.removePersistentDomain(forName:"echo.trial-day") }
            MemoryLog.scenePrefix="trial_"

            let key:String
            do { key=try trialKey(source) } catch { print("Trial: no key: \(error.localizedDescription)"); exit(1) }
            SmartMemory.readKey={ key }
            Task {
                let scratchStore=FileManager.default.temporaryDirectory.appendingPathComponent("EchoDayTrial-"+UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:scratchStore) }
                do {
                    var day=args[flag+1], store=LocalMemoryStore.shared
                    if day == "fixture" { store=LocalMemoryStore(root:scratchStore); try dayFixture(store); day="2026-10-09" }
                    let digester=DayDigester(store:store,engine:SmartMemory(chat:nil,bridge:nil,local:LocalMemoryStore(root:scratchStore.appendingPathComponent("Empty"))),root:URL(fileURLWithPath:out))
                    digester.maxTokens=16384
                    let start=Date()
                    guard let file=try await digester.run(day) else { print("Trial: no drafts that day, or already summarised in \(out)"); exit(1) }
                    let usage=file.provenance.usage, kinds=Dictionary(grouping:file.items,by:\.kind).mapValues(\.count)
                    print("Trial \(model): \(file.segments.count) segments, items \(kinds), rejected \(file.rejected), tokens in \(usage.input ?? -1) out \(usage.output ?? -1), \(Int(Date().timeIntervalSince(start)*1000)) ms")
                    exit(0)
                } catch { print("Trial failed: \(error.localizedDescription)"); exit(1) }
            }; app.run(); return
        }




        if let flag=CommandLine.arguments.firstIndex(of:"--trial-lookup") {
            let args=CommandLine.arguments
            func value(_ name:String)->String? { args.firstIndex(of:name).flatMap { args.indices.contains($0+1) ? args[$0+1] : nil } }
            guard args.indices.contains(flag+1),let endpoint=value("--endpoint"),let model=value("--model"),let out=value("--out"),let source=value("--key"),
                  let lines=try? String(contentsOfFile:args[flag+1],encoding:.utf8) else {
                print("usage: --trial-lookup <questions file> --endpoint <url> --model <name> --key memory|voice|keychain:<service>/<account> --out <file>"); exit(2)
            }
            let scratch=UserDefaults(suiteName:"echo.trial-lookup")!
            scratch.set(endpoint,forKey:"endpoint"); scratch.set(model,forKey:"modelName"); ModelConfig.defaults=scratch
            atexit { UserDefaults.standard.removePersistentDomain(forName:"echo.trial-lookup") }
            MemoryLog.scenePrefix="trial_"
            let key:String
            do { key=try trialKey(source) } catch { print("Trial: no key: \(error.localizedDescription)"); exit(1) }
            SmartMemory.readKey={ key }
            let questions=lines.split(separator:"\n").compactMap { line->(MemoryOutputMode,String)? in
                let parts=line.split(separator:"\t",maxSplits:1).map(String.init)
                guard parts.count == 2,let mode=MemoryOutputMode(rawValue:parts[0]) else { return nil }; return (mode,parts[1])
            }
            Task {
                FileManager.default.createFile(atPath:out,contents:nil,attributes:[.posixPermissions:0o600])
                guard let file=FileHandle(forWritingAtPath:out) else { print("Trial: cannot write \(out)"); exit(1) }
                let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
                for (mode,question) in questions {

                    let trace=MemoryTrace(surface:"trial",trigger:"explicit",query:question,mode:mode.rawValue,recorded:false), started=Date()
                    do { _ = try await SmartMemory().answer(question,mode:mode,trace:trace) }
                    catch { trace.update { $0.error=error.localizedDescription } }
                    let run=trace.run, modelMs=run.calls.reduce(0) { $0+$1.ms }
                    print("\(Int(Date().timeIntervalSince(started)*1000)) ms total, \(modelMs) ms in \(run.calls.count) model calls · \(question.prefix(24))\(run.error.map { " · error: "+$0 } ?? "")"); fflush(stdout)
                    if var line=try? encoder.encode(run) { line.append(0x0a); file.write(line) }
                }
                try? file.close(); exit(0)
            }; app.run(); return
        }

        if CommandLine.arguments.contains("--verify-day-live") {
            Task {
                let folder=FileManager.default.temporaryDirectory.appendingPathComponent("EchoDayLive-"+UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:folder) }
                do {
                    let store=LocalMemoryStore(root:folder.appendingPathComponent("InputMemory")); try dayFixture(store)
                    let digester=DayDigester(store:store,engine:SmartMemory(chat:nil,bridge:nil,local:LocalMemoryStore(root:folder.appendingPathComponent("Empty"))),root:folder.appendingPathComponent("Days"))
                    let start=Date()
                    guard let file=try await digester.run("2026-10-09") else { print("Live by day: no file"); exit(1) }
                    let usage=file.provenance.usage, kinds=Dictionary(grouping:file.items,by:\.kind).mapValues(\.count)
                    print("Live by day: \(file.segments.count) segments, items \(kinds), rejected \(file.rejected), tokens in \(usage.input ?? -1) out \(usage.output ?? -1), usd \(usage.usd.map { String(format:"%.5f",$0) } ?? "null"), \(Int(Date().timeIntervalSince(start)*1000)) ms")
                    exit(file.tldr.isEmpty ? 1 : 0)
                } catch { print("Live by day unavailable: \(error.localizedDescription)"); exit(1) }
            }; app.run(); return
        }
        if CommandLine.arguments.contains("--verify-voice-polish-live") || CommandLine.arguments.contains("--verify-memory-natural-live") {
            Task {
                do {
                    let start=Date()
                    if CommandLine.arguments.contains("--verify-memory-natural-live") {
                        let records=[MemorySource(event_id:"echo_source_1",date:"2026-10-10",title:"训练讨论（虚构）",body:"当天讨论了平举动作、反手动作发力和呼吸要点，没有说明用户实际练了什么，也没有训练时间。"),MemorySource(event_id:"echo_source_2",date:"2026-10-10",title:"训练计划（虚构）",body:"计划明天进行核心训练；没有今天中午训练的记录。")]
                        let prompt="用户请求：我今天中午训练的是什么\n来源资料："+(try SmartMemory.encoded(records))
                        let engine=SmartMemory()
                        let output=try await engine.chat(system:SmartMemory.answerInstructions(.reply),prompt:prompt,scene:"verify")
                        let answer=try SmartMemory.decode(output,as:MemoryAnswer.self)
                        let safe=answer.needs_clarification == true && !(answer.clarification ?? "").isEmpty
                        print("Synthetic ambiguity: clarification required \(safe), model calls \(engine.modelCalls), elapsed \(Int(Date().timeIntervalSince(start)*1000))ms")
                        print("Synthetic hint: \(answer.clarification ?? "")")
                        exit(safe && engine.modelCalls == 1 ? 0 : 1)
                    }
                    let samples=[
                        "嗯，那个，人物甲，我们就是先把 API v2 的那个 review 安排在周五 15:30，然后预算这块呢还是 2000 元，不要动，然后那个上线日期也不要改。",
                        "为什么永远被授权之后，你就能自动退出手机",
                        "这个 UI 呢，细节上面还是比较丑，然后需要你用生图模型重新优化一下",
                        "我觉得可能周五能完成，但是还没确认",
                        "测试一下，把这个 A3 换成 TFS，换成 A3 2.5 吧",
                        "周五 15:30，不对，周六 16:00开会"
                    ]
                    let engine=SmartMemory(); var safe=true
                    for raw in samples {
                        let result:String
                        do { result=try await VoicePolisher(model:engine).polish(raw,terms:["人物甲","Codex","WithEcho"]) }
                        catch is VoiceFailure { result=raw; print("Synthetic rewrite rejected; original retained") }
                        if raw.contains("换成 TFS") { safe = safe && !result.contains("TFS") && result.contains("A3 2.5") }
                        else if raw.contains("15:30，不对") { safe = safe && !result.contains("15:30") && result.contains("16:00") }
                        else { safe = safe && VoicePolisher.faithful(result,from:raw,terms:["人物甲","Codex","WithEcho"]) }
                        print("Synthetic input: \(raw)")
                        print("Synthetic output: \(result)")
                    }
                    print("Live cleanup: model calls \(engine.modelCalls), guarded results \(safe), elapsed \(Int(Date().timeIntervalSince(start)*1000))ms")
                    exit(safe && engine.modelCalls == samples.count ? 0 : 1)
                } catch { print("Live cleanup unavailable: \(error.localizedDescription)"); exit(1) }
            }; app.run(); return
        }
        let demo=CommandLine.arguments.contains("--demo-window") || Bundle.main.object(forInfoDictionaryKey:"EchoUIPreview") as? Bool == true
        let data=Bundle.main.resourceURL!.appendingPathComponent("Data")
        if CommandLine.arguments.contains("--verify-vectors-live") {
            Task { @MainActor in
                do { try await VectorChecks.run(); exit(0) }
                catch { print("Vector check failed: \(error.localizedDescription)"); exit(1) }
            }
            app.run(); return
        }
        let voiceFixture=CommandLine.arguments.contains("--verify-voice") || CommandLine.arguments.contains("--demo-voice") || Bundle.main.object(forInfoDictionaryKey:"EchoVoicePreview") as? Bool == true
        let typingCheck=CommandLine.arguments.contains("--verify-typing")
        let typingReload=typingCheck && CommandLine.arguments.contains("--reload")
        let profile=typingCheck ? "TypingCheckRime" : voiceFixture ? "VoiceCheckRime" : (CommandLine.arguments.contains("--verify-inline") ? "InlineCheckRime" : ((CommandLine.arguments.contains("--demo-inline") || Bundle.main.object(forInfoDictionaryKey:"EchoInlinePreview") as? Bool == true) ? "InlineDemoRime" : (CommandLine.arguments.contains("--verify-editor") || CommandLine.arguments.contains("--verify-settings") || CommandLine.arguments.contains("--verify-activity") || CommandLine.arguments.contains("--verify-day") || CommandLine.arguments.contains("--verify-style") || CommandLine.arguments.contains("--verify-meetings") ? "EditorTestRime" : (demo ? "PreviewRime" : "Rime"))))
        let user=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("EchoMemoryIME/"+profile)

        if typingCheck && !typingReload { try? FileManager.default.removeItem(at:user); TypingChecks.seedLegacyOptions(user) }
        try? FileManager.default.createDirectory(at:user,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        IMESessionDiagnostics.note("rime_initialization_requested")
        FileManager.default.changeCurrentDirectoryPath(data.path); _ = ERInitialize(data.path,user.path)
        IMESessionDiagnostics.note("rime_initialized")
        if typingCheck { if typingReload { TypingChecks.reload() } else { TypingChecks.run() }; return }
        if CommandLine.arguments.contains("--verify-inline") {
            Task { @MainActor in do { try await MemoryInlineChecks.run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }; app.run(); return
        }
        if CommandLine.arguments.contains("--verify-activity") {
            Task { @MainActor in do { try await MemoryActivityChecks.run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }; app.run(); return
        }
        if CommandLine.arguments.contains("--verify-growth-memory") {
            Task { do { try await GrowthMemoryChecks.run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }; app.run(); return
        }
        if CommandLine.arguments.contains("--verify-day") {
            Task { do { try await DayChecks.run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }; app.run(); return
        }
        if CommandLine.arguments.contains("--verify-meetings") {
            Task { @MainActor in do { try await MeetingChecks.run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }; app.run(); return
        }
        if CommandLine.arguments.contains("--verify-style") {
            Task { @MainActor in do { try await StyleChecks.run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }; app.run(); return
        }
        if CommandLine.arguments.contains("--verify-settings") {
            Task { @MainActor in await SettingsChecks.run(); exit(0) }; app.run(); return
        }
        if CommandLine.arguments.contains("--verify-voice") {
            Task { @MainActor in do { try await VoiceChecks.run(); exit(0) } catch { print("FAIL: voice checks failed: \(error.localizedDescription)"); exit(1) } }; app.run(); return
        }
        if CommandLine.arguments.contains("--demo-voice") || Bundle.main.object(forInfoDictionaryKey:"EchoVoicePreview") as? Bool == true {
            app.setActivationPolicy(.regular)
            let preview=VoiceUIDemo(); withExtendedLifetime(preview) { app.run() }; return
        }
        if CommandLine.arguments.contains("--input-library") { InputMemoryLibrary.shared.show(); app.run(); return }
        if CommandLine.arguments.contains("--verify-input-memory") {
            do { try InputMemoryChecks.run(); print("PASS: native recorder excludes secure apps"); precondition(!InputMemoryRecorder.allowedApp("com.apple.Terminal") && !InputMemoryRecorder.allowedApp("com.agilebits.onepassword7") && InputMemoryRecorder.allowedApp("com.apple.TextEdit")); return }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--demo-inline") || Bundle.main.object(forInfoDictionaryKey:"EchoInlinePreview") as? Bool == true {
            app.setActivationPolicy(.regular)
            let demo=MemoryInlineDemo(); withExtendedLifetime(demo) { app.run() }; return
        }
        if CommandLine.arguments.contains("--verify-editor") {
            let view=MemoryPromptView(frame:NSRect(x:0,y:0,width:500,height:86),textContainer:nil)
            view.setQuery("验证文字"); precondition(view.string == "验证文字")
            let original=EchoTypingMode.english; EchoTypingMode.english=false
            ERSetASCII(view.rime,false)
            view.setQuery("")
            func key(_ chars:String,_ code:UInt16=0) { let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:code)!; view.keyDown(with:event) }
            for char in "nihao" { key(String(char)) }; key(" ",49)
            precondition(view.string == "你好")
            EchoTypingMode.english=true; view.setQuery("")
            for char in "Echo123" { key(String(char)) }; precondition(view.string == "Echo123")
            EchoTypingMode.english=original
            print("PASS: independent prompt editor retains text and supports Chinese/English without an external input session")
            return
        }
        if demo { MemoryWorkspace.shared.enableDemo(); MemoryWorkspace.shared.show(prefill:"告诉人物甲昨天会议的结论"); app.run(); return }
        guard let id=Bundle.main.bundleIdentifier,
              let connection=Bundle.main.object(forInfoDictionaryKey:"InputMethodConnectionName") as? String,
              let server=IMKServer(name:connection,bundleIdentifier:id) else { return }
        IMESessionDiagnostics.note("server_registered")
        if IMESessionDiagnostics.enabled {
            let matches=server.bundle()?.bundleURL.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path
            IMESessionDiagnostics.note("server_bundle_matches_main_\(matches ? 1:0)")
        }
        let delegate=EchoApplicationDelegate(); app.delegate=delegate
        withExtendedLifetime((server,delegate)) { app.run() }
    }
}

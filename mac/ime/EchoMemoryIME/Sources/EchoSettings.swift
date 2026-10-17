import Cocoa
import SwiftUI
import AVFoundation
import Carbon

// Every Echo setting in one window, laid out like macOS System Settings. Each control reads and writes
// the same storage the rest of Echo uses, so there is no second copy that could fall out of step.
final class EchoSettingsModel:ObservableObject {
    enum Section:String,CaseIterable,Identifiable {
        case general="通用", shortcuts="快捷键", memory="记忆与来源", voice="语音", peripheral="外设", model="Agent 服务"
        var id:Self { self }
        var symbol:String { ["通用":"gearshape","快捷键":"keyboard","记忆与来源":"sparkle.magnifyingglass","语音":"mic","外设":"keyboard.badge.ellipsis","Agent 服务":"server.rack"][rawValue]! }
    }
    enum Tone { case plain, success, failure }
    enum WithEcho { case checking, connected, needsReconnect, disconnected, unavailable }
    // Tests swap these for scratch versions; nothing here may touch the real keychain or network then.
    // Keychain calls can wait on a macOS prompt, so they run off the main thread that typing needs;
    // everything that changes published state runs on the main actor.
    static var saveModelKey:(String)->Bool = MemoryModelKey.save
    static var removeModelKey:()->Bool = MemoryModelKey.remove
    static var readModelKey:() throws -> String = { try MemoryModelKey.read(interactive:true) }
    static var saveVoiceKey:(String) throws -> Void = StepVoiceKey.save
    static var readStepKey:() throws -> String = { try StepVoiceKey.read(interactive:true) }
    static var testModel:(URL,String,String) async -> (Bool,String) = EchoSettingsModel.liveTest
    static var withEchoStatus:() async throws -> Data = { try await EchoSettingsModel.python("auth.py",["status"]) }
    static var readAgentHealth:() async throws -> Data = liveAgentHealth
    static func liveAgentHealth() async throws -> Data {
        let token=try await Task.detached { try MemoryAgentClient.readToken() }.value
        try Task.checkCancellation()
        var request=URLRequest(url:URL(string:"http://127.0.0.1:18791/health")!)
        request.timeoutInterval=5;request.setValue(token,forHTTPHeaderField:"X-Growth-Token")
        let session=URLSession(configuration:.ephemeral,delegate:MemoryRedirectDelegate(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (bytes,response)=try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,bytes.count<100000 else {
            throw MemoryFailure.message("记忆 Agent 服务未就绪。")
        }
        return bytes
    }
    private var keyOperations=0
    var keyOperationBusy:Bool { keyOperations>0 }
    var keyOperationStarted:()->Void = {}, keyOperationFinished:()->Void = {}
    @MainActor private func keyAccess<T>(_ operation:@escaping () throws -> T) async throws -> T {
        keyOperations += 1; keyOperationStarted()
        defer { keyOperations -= 1; if keyOperations == 0 { keyOperationFinished() } }
        return try await Task.detached(operation:operation).value
    }

    // Leaving the shortcuts page ends a recording, so keys typed elsewhere are never taken as a shortcut.
    @Published var section=Section.general { didSet { if section != oldValue { stopRecording() } } }
    @Published var refreshed=0  // bumped to redraw values read straight from storage
    // Shortcuts
    @Published var recording:EchoShortcutSlot?
    @Published var shortcutNote="点击快捷键后按下新组合键（需包含 ⌃ 或 ⌥），Esc 取消。"
    @Published var shortcutError=false
    private var monitor:Any?
    // Voice
    @Published var voiceKey=""
    @Published var voiceNote=""
    @Published var voiceTone=Tone.plain
    @Published var voiceBusy=false
    // Model & WithEcho
    @Published var endpoint=""
    @Published var modelName=""
    @Published var modelKey=""
    @Published var savedConfig=false
    @Published var modelNote="「保存并测试」只发送一条虚构消息，不含你的记录。"
    @Published var modelTone=Tone.plain
    @Published var testing=false
    @Published var agentRecordingSummary="尚未读取 APT 录音来源。"
    @Published var agentSummary="尚未核验记忆 Agent 服务。"
    @Published var agentChecking=false
    @Published var agentConnected=false
    @Published var agentFeedReady=false
    @Published var agentSources:Int?
    @Published var agentDevices:Int?
    @Published var agentRange="尚无可读来源"
    @Published var agentDiagnostic=""
    static func displaySourceDate(_ value:String)->String {
        let parser=ISO8601DateFormatter();parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let fractional=parser.date(from:value);parser.formatOptions=[.withInternetDateTime]
        guard let date=fractional ?? parser.date(from:value) else { return value == "—" ? "暂无记录" : value }
        let display=DateFormatter();display.locale=Locale(identifier:"zh_CN");display.timeZone = .current;display.dateFormat="yyyy.MM.dd HH:mm"
        return display.string(from:date)
    }
    @MainActor func checkAgent() async {
        guard !agentChecking else { return }
        agentChecking=true;defer { agentChecking=false }
        agentSummary="正在核验记忆 Agent 服务与同步范围…"
        do {
            try Task.checkCancellation()
            let bytes=try await Self.readAgentHealth()
            try Task.checkCancellation()
            guard let value=(try JSONSerialization.jsonObject(with:bytes)) as? [String:Any],
                  let agent=value["agent"] as? [String:Any],agent["ready"] as? Bool == true,
                  let coverage=value["coverage"] as? [String:Any] else { throw MemoryFailure.message("记忆 Agent 服务或执行宿主尚未就绪。") }
            let first=coverage["first_record_at"] as? String ?? "—",last=coverage["last_record_at"] as? String ?? "—"
            agentConnected=true;agentFeedReady=(value["synchronization"] as? [String:Any])?["ready"] as? Bool ?? false
            agentSources=coverage["sources"] as? Int;agentDevices=coverage["devices"] as? Int
            agentRange=Self.displaySourceDate(first)+" — "+Self.displaySourceDate(last)
            agentDiagnostic="原始来源时间：\(first) 至 \(last)。\n"+(agentFeedReady ? "来源流已就绪。" : "来源流尚未就绪，已缓存材料不代表最新完整范围。")
            let recordings=value["recordings"] as? [String:Any]
            let recordingFirst=Self.displaySourceDate(recordings?["first_record_at"] as? String ?? "—"),recordingLast=Self.displaySourceDate(recordings?["last_record_at"] as? String ?? "—")
            let recordingReady=recordings?["ready"] as? Bool == true
            agentRecordingSummary=recordingReady ? "APT 录音：\(recordings?["sources"] as? Int ?? 0) 段已同步来源。\(recordingFirst) — \(recordingLast)。" : "APT 录音暂未就绪，不能据此认为没有记录。"
            agentSummary="记忆 Agent 服务已连接 · \(coverage["sources"] as? Int ?? 0) 条同步草稿 · \(coverage["devices"] as? Int ?? 0) 台设备。"+agentRecordingSummary+"未上传草稿、手机未同步的录音或修改不在本轮范围。"
        } catch is CancellationError { return }
        catch { agentConnected=false;agentFeedReady=false;agentSources=nil;agentDevices=nil;agentSummary="记忆 Agent 服务不可用："+error.localizedDescription;agentDiagnostic=error.localizedDescription }
    }
    @Published var confirmingReset=false
    @Published var backgroundEndpoint=""
    @Published var backgroundModel=""
    @Published var backgroundNote=""
    @Published var backgroundTone=Tone.plain
    @Published var backgroundTesting=false
    @Published var meetingBusy=false
    @Published var meetingNote=""
    @Published var styleBusy=false
    @Published var styleNote=""
    @Published var vectorBusy=false
    @Published var vectorNote=""
    @Published var growthEndpoint=GrowthMemoryConfig.endpoint
    @Published var growthToken=""
    @Published var growthNote=""
    @Published var growthBusy=false
    func connectGrowth() {
        guard let url=GrowthMemoryConfig.url(growthEndpoint) else { growthNote="填写 HTTPS 服务根地址，例如 https://apt-backend.example"; return }
        let token=growthToken.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !token.isEmpty else { growthNote="填写 APT App 使用的门禁令牌。"; return }
        growthBusy=true
        Task { @MainActor in
            do {
                try await Task.detached { try GrowthMemoryConfig.saveToken(token,to:url) }.value
                GrowthMemoryConfig.defaults.set(url.absoluteString,forKey:"growthMemoryEndpoint")
                GrowthMemoryConfig.defaults.set(true,forKey:"growthMemorySyncEnabled")
                growthToken=""; refreshed += 1
                let count=try await GrowthMemorySync.shared.sync(to:url,token:token)
                growthNote="已同步 \(count) 条到 APT；APT 可读取已同步来源。"
            } catch { growthNote=error.localizedDescription }
            growthBusy=false
        }
    }
    static var vectorOperation:SmartMemory.Bridge = { request in try await SmartMemory(chat:{ _,_ in "" }).bridge(request) }
    // Memory lookups recorded on this Mac
    @Published var runCount=0
    @Published var voiceCount=0
    @Published var hasRuns=false
    @Published var confirmingClearRuns=false
    @Published var withEcho=WithEcho.checking
    @Published var withEchoError=""
    @Published var connecting=false

    func refresh(account:Bool=true) {
        endpoint=ModelConfig.endpoint; modelName=ModelConfig.modelName; modelKey=""; savedConfig = !ModelConfig.endpoint.isEmpty
        backgroundEndpoint=ModelConfig.backgroundEndpoint; backgroundModel=ModelConfig.backgroundModel
        voiceKey=""; voiceTone = .plain; countRuns()
        voiceNote=UserDefaults.standard.bool(forKey:"stepVoiceKeyConfigured") ? "已保存 StepFun Key。" : "还没有 StepFun Key：粘贴后点「保存 Key」。"
        refreshed += 1
        if account { Task { @MainActor in await checkWithEcho() } }
    }
    // A switch bound to storage, redrawn on change.
    func toggle(_ get:@escaping ()->Bool,_ set:@escaping (Bool)->Void)->Binding<Bool> {
        Binding(get:{ _ = self.refreshed; return get() },set:{ set($0); self.refreshed += 1 })
    }
    func choice(_ key:String,_ fallback:String)->Binding<String> {
        Binding(get:{ _ = self.refreshed; return UserDefaults.standard.string(forKey:key) ?? fallback },set:{ UserDefaults.standard.set($0,forKey:key); self.refreshed += 1 })
    }

    // MARK: Shortcuts
    func record(_ slot:EchoShortcutSlot,in window:NSWindow?) {
        stopRecording(); recording=slot; shortcutError=false; shortcutNote="按下新的「\(slot.title)」快捷键…"
        EchoMemoryHotKey.shared.suspended=true; EchoMemoryHotKey.shared.sync()  // so the current keys reach the recorder
        monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self,weak window] event in
            guard let self,let window,event.window === window else { return event }
            self.capture(event); return nil
        }
    }
    func capture(_ event:NSEvent) {
        guard let slot=recording else { return }
        if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection(EchoShortcut.relevant).isEmpty { stopRecording(); return }
        guard let shortcut=EchoShortcut(recording:event) else { note("这个键不能用作快捷键。",error:true); return }
        if let problem=slot.problem(shortcut) { note("\(shortcut.label)：\(problem)",error:true); return }
        slot.save(shortcut); stopRecording(); note("「\(slot.title)」已改为 \(shortcut.label)。若按下没反应，可能与其他 App 冲突，换一个即可。")
    }
    func reset(_ slot:EchoShortcutSlot) {
        stopRecording()
        if let problem=slot.problem(slot.fallback) { note("不能恢复为 \(slot.fallback.label)：\(problem)。",error:true); return }
        slot.save(nil); EchoMemoryHotKey.shared.sync(); note("「\(slot.title)」已恢复为 \(slot.current.label)。")
    }
    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor=nil
        if recording != nil { recording=nil; note("已取消录制。"); EchoMemoryHotKey.shared.suspended=false; EchoMemoryHotKey.shared.sync() }
        refreshed += 1
    }
    private func note(_ text:String,error:Bool=false) { shortcutNote=text; shortcutError=error }

    // Counting reads whole month files, so it runs off the main thread that typing needs.
    func countRuns() {
        hasRuns=MemoryLog.shared.hasRuns
        Task { @MainActor in
            let counts=await Task.detached { (MemoryLog.shared.runCount,MemoryLog.shared.voiceCount) }.value
            runCount=counts.0; voiceCount=counts.1
        }
    }
    func clearRuns() {
        // Nothing still being watched or written is attached to records that are gone.
        VoiceEdits.shared.forget(); VoiceInput.shared.run=nil
        VoiceInput.shared.polishHistory.clear(); VoiceInput.shared.polishContext=VoicePolishContext()
        // A reply card still open (or the workspace's reply) then ends without writing to the cleared records.
        MemoryInline.shared.runID=nil; MemoryWorkspace.shared.replyRunID=nil
        do { try MemoryLog.shared.clearRuns() } catch { NSSound.beep() }
        countRuns()
    }
    func checkVectors(clear:Bool=false) {
        guard !vectorBusy else { return }
        vectorBusy=true
        vectorNote=clear ? "正在清空索引缓存…" : "正在检查本机检索服务…"
        let operation=Self.vectorOperation, embeddingModel=MemoryVectors.model
        Task { @MainActor in
            do {
                let response=try await operation(["action":clear ? "index_clear" : "index_status","model":embeddingModel])
                guard clear || embeddingModel == MemoryVectors.model else { throw MemoryFailure.message("检索模型已切换，请重新检查。") }
                guard let info=response.index else { throw MemoryFailure.message("检索服务没有返回状态。") }
                guard clear || info.model == embeddingModel else { throw MemoryFailure.message("检索服务返回了不同模型的状态。") }
                if clear {
                    guard info.state == "cleared" else { throw MemoryFailure.message("未能确认索引已清空。") }
                    MemoryVectors.changed(); vectorNote="已清空向量缓存，下次需要时重新建立；原始记录保留。"
                } else {
                    vectorNote=info.state == "ready" ? "本机检索服务可用 · 已缓存 \(info.chunks) 个正文片段" : MemoryVectors.reason(info.error)+"。"
                }
            } catch { vectorNote="索引操作未完成：\(error.localizedDescription)" }
            vectorBusy=false; refreshed += 1
        }
    }

    // MARK: Voice
    // Only the Key needs saving; an empty field touches neither the keychain nor other settings.
    private func voiceReport(_ text:String,_ tone:Tone = .plain) { voiceNote=text; voiceTone=tone }
    func saveVoiceKey() {
        let key=voiceKey.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !voiceBusy else { return }
        guard !key.isEmpty else { voiceReport("请先粘贴 StepFun API Key。",.failure); return }
        let save=Self.saveVoiceKey; voiceBusy=true
        Task { @MainActor in
            do {
                try await keyAccess { try save(key) }; voiceKey=""
                voiceReport("Key 已保存。回到输入框按住 \(VoiceBinding.label) 说话。",.success)
            } catch { voiceReport(error.localizedDescription,.failure) }
            voiceBusy=false
        }
    }
    func authorizeVoiceKey() {
        guard !voiceBusy else { return }
        voiceBusy=true
        Task { @MainActor in
            do { _ = try await keyAccess(Self.readStepKey); voiceReport("StepFun Key 已授权。",.success) }
            catch { voiceReport(error.localizedDescription,.failure) }
            voiceBusy=false
        }
    }
    // Once denied, macOS never asks again; only System Settings can allow it.
    func microphone() {
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized: voiceReport("麦克风已允许。",.success)
        case .notDetermined:
            Task { @MainActor in
                if await AVCaptureDevice.requestAccess(for:.audio) { voiceReport("麦克风已允许。",.success) }
                else { voiceReport("麦克风未获允许，可在系统设置 › 隐私与安全性 › 麦克风中开启。",.failure) }
            }
        default: NSWorkspace.shared.open(VoiceInput.microphoneSettings); voiceReport("已打开系统设置，请在「麦克风」中允许 APT。")
        }
    }

    // MARK: Model & WithEcho
    var canResetModel:Bool { savedConfig || !endpoint.isEmpty || !modelName.isEmpty || !modelKey.isEmpty }
    private func report(_ text:String,_ tone:Tone = .plain) { modelNote=text; modelTone=tone }
    func saveAndTest() {
        guard !testing else { return }
        endpoint=endpoint.trimmingCharacters(in:.whitespacesAndNewlines); modelName=modelName.trimmingCharacters(in:.whitespacesAndNewlines)
        let typedKey=modelKey.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let url=ModelConfig.url(endpoint),!modelName.isEmpty else { report("请填写以 https:// 开头的服务地址和模型名称。",.failure); return }
        guard !typedKey.isEmpty || savedConfig else { report("请填写 API Key。",.failure); return }
        // The saved Key belongs to the saved address; never send it anywhere else (host, port, scheme or path).
        guard !typedKey.isEmpty || ModelConfig.url(ModelConfig.endpoint) == url else { report("更换了服务地址，请重新填写这个服务的 API Key。",.failure); return }
        let endpoint=endpoint, model=modelName, save=Self.saveModelKey, read=Self.readModelKey
        testing=true; report("正在保存…")
        Task { @MainActor in
            defer { testing=false }
            if !typedKey.isEmpty { guard (try? await keyAccess { save(typedKey) }) == true else { report("钥匙串保存失败，请在 macOS 提示中允许后重试。",.failure); return } }
            ModelConfig.defaults.set(endpoint,forKey:"endpoint"); ModelConfig.defaults.set(model,forKey:"modelName")
            modelKey=""; savedConfig=true; refreshed += 1
            let key:String
            do { key=typedKey.isEmpty ? try await keyAccess(read) : typedKey }
            catch { report("已保存。"+(error.localizedDescription),.failure); return }
            report("已保存，正在测试 \(url.host ?? "模型服务")…")
            let (ok,text)=await Self.testModel(url,model,key)
            report(text,ok ? .success : .failure)
        }
    }
    func syncMeetings() {
        guard !meetingBusy else { return }
        meetingBusy=true; meetingNote="正在同步最近 7 天…"
        MeetingNotes.catchUp(force:true) { [weak self] failure in
            guard let self else { return }
            self.meetingBusy=false; self.meetingNote=failure ?? "已同步。"; self.refreshed += 1
        }
    }
    // Style.md: open it (created from the template if missing) or rewrite its automatic part now.
    func openStyle() {
        do { try StyleProfile.shared.ensureFile(); NSWorkspace.shared.open(StyleProfile.shared.url) }
        catch { styleNote="没能创建文件：\(error.localizedDescription)" }
    }
    func updateStyle() {
        guard !styleBusy else { return }
        styleBusy=true; styleNote="正在总结…"
        StyleProfile.catchUp(force:true) { [weak self] failure in
            guard let self else { return }
            self.styleBusy=false; self.styleNote=failure ?? "已更新，点「打开…」查看。"; self.refreshed += 1
        }
    }
    // Which saved Key the background model would use, for what is typed now.
    var backgroundKeyLabel:String {
        let typed=backgroundEndpoint.trimmingCharacters(in:.whitespacesAndNewlines)
        if typed.isEmpty { return "同实时模型" }
        guard let url=ModelConfig.url(typed) else { return "—" }
        switch ModelConfig.keySource(url) { case .model: return "实时模型的 Key"; case .stepFun: return "StepFun 语音 Key"; case nil: return "不支持这个服务" }
    }
    // Both fields or neither (then By Day uses the realtime model). No Key is typed here: see ModelConfig.route.
    func saveBackground() {
        guard !backgroundTesting else { return }
        backgroundEndpoint=backgroundEndpoint.trimmingCharacters(in:.whitespacesAndNewlines); backgroundModel=backgroundModel.trimmingCharacters(in:.whitespacesAndNewlines)
        func note(_ text:String,_ tone:Tone = .plain) { backgroundNote=text; backgroundTone=tone }
        if backgroundEndpoint.isEmpty && backgroundModel.isEmpty {
            ModelConfig.defaults.removeObject(forKey:"backgroundEndpoint"); ModelConfig.defaults.removeObject(forKey:"backgroundModel")
            refreshed += 1; note("后台整理改用实时模型。",.success); return
        }
        guard let url=ModelConfig.url(backgroundEndpoint),!backgroundModel.isEmpty else { note("请同时填写以 https:// 开头的服务地址和模型名称；都留空则用实时模型。",.failure); return }
        guard let source=ModelConfig.keySource(url) else { note("后台模型只能用与实时模型同一服务，或 StepFun（用本页的语音 Key）。",.failure); return }
        let model=backgroundModel, read=source == .stepFun ? Self.readStepKey : Self.readModelKey
        ModelConfig.defaults.set(backgroundEndpoint,forKey:"backgroundEndpoint"); ModelConfig.defaults.set(model,forKey:"backgroundModel")
        refreshed += 1; backgroundTesting=true; note("已保存，正在测试 \(url.host ?? "模型服务")…")
        Task { @MainActor in
            defer { backgroundTesting=false }
            let key:String
            do { key=try await keyAccess(read) }
            catch { note("已保存。"+error.localizedDescription,.failure); return }
            let (ok,text)=await Self.testModel(url,model,key)
            note(text,ok ? .success : .failure)
        }
    }
    func resetModel() {
        guard !testing else { return }
        let remove=Self.removeModelKey; testing=true
        Task { @MainActor in
            defer { testing=false }
            guard (try? await keyAccess { remove() }) == true else { report("钥匙串里的 Key 没能删除，请在 macOS 提示中允许后重试。",.failure); return }
            ModelConfig.defaults.removeObject(forKey:"endpoint"); ModelConfig.defaults.removeObject(forKey:"modelName")
            endpoint=""; modelName=""; modelKey=""; savedConfig=false; refreshed += 1; report("模型配置已清除。")
        }
    }
    func authorizeModelKey() {
        guard !testing else { return }
        let read=Self.readModelKey; testing=true
        Task { @MainActor in
            defer { testing=false }
            do { _ = try await keyAccess(read); report("模型 Key 已授权。",.success); MemoryInline.shared.authorized() }
            catch { report(error.localizedDescription,.failure) }
        }
    }
    // One fictional message; never follows a redirect, so the Key cannot leak to another host.
    static func liveTest(_ url:URL,_ model:String,_ key:String) async -> (Bool,String) {
        let host=url.host ?? "模型服务"
        do {
            let background=ModelConfig.backgroundSet && ModelConfig.backgroundModel == model && ModelConfig.url(ModelConfig.backgroundEndpoint) == url
            _ = try await AgentModels.text(system:"只回复连接成功。",prompt:"虚构连接测试，不含私人记录。",scene:"settings_test",background:background,deepReview:false,timeout:90,maxTokens:128,json:false,key:key)
            return (true,"记忆 Agent 服务连接成功："+host+" · "+model+"。")
        } catch { return (false,"已保存，但记忆 Agent 服务测试失败："+error.localizedDescription) }
    }
    // Asks the bundled WithEcho script whether this Mac holds an authorisation. Local only, no network.
    @MainActor func checkWithEcho() async {
        struct Status:Decodable { let logged_in:Bool; let missing_scope:[String]? }
        guard let data=try? await Self.withEchoStatus(),let state=try? JSONDecoder().decode(Status.self,from:data) else { withEcho = .unavailable; return }
        withEcho = !state.logged_in ? .disconnected : (state.missing_scope ?? []).contains("daily:read") ? .needsReconnect : .connected
    }
    func connectWithEcho() {
        guard !connecting else { return }
        connecting=true; withEchoError=""
        Task { @MainActor in
            struct Reply:Decodable { let error:String? }
            let data=try? await Self.python("bridge.py",input:Data(#"{"action":"login"}"#.utf8))
            if let reply=data.flatMap({ try? JSONDecoder().decode(Reply.self,from:$0) }) { withEchoError=reply.error ?? "" }
            else { withEchoError="无法启动授权。WithEcho 连接需要 Python 3。" }
            await checkWithEcho(); connecting=false
        }
    }
    static func python(_ script:String,_ arguments:[String]=[],input:Data?=nil) async throws -> Data {
        let path=Bundle.main.resourceURL!.appendingPathComponent(script).path
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/env"); process.arguments=["python3",path]+arguments
                var environment=ProcessInfo.processInfo.environment; environment["PATH"]="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"; process.environment=environment
                let output=Pipe(); process.standardOutput=output; process.standardError=FileHandle.nullDevice
                do {
                    if let input { let pipe=Pipe(); try pipe.fileHandleForWriting.write(contentsOf:input); try pipe.fileHandleForWriting.close(); process.standardInput=pipe }
                    else { process.standardInput=FileHandle.nullDevice }
                    try process.run(); let bytes=output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                    continuation.resume(returning:bytes)
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
}

// Echo has no menu bar of its own, so the window maps the standard editing keys itself (⌃V too, as before).
final class EchoSettingsWindow:NSWindow {
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        let flags=event.modifierFlags.intersection(EchoShortcut.relevant), key=event.charactersIgnoringModifiers?.lowercased() ?? ""
        var action:Selector?
        if flags == [.command] { action=["x":#selector(NSText.cut(_:)),"c":#selector(NSText.copy(_:)),"v":#selector(NSText.paste(_:)),"a":#selector(NSText.selectAll(_:)),"z":Selector(("undo:")),"w":#selector(NSWindow.performClose(_:))][key] }
        else if flags == [.command,.shift],key == "z" { action=Selector(("redo:")) }
        else if flags == [.control],key == "v" { action=#selector(NSText.paste(_:)) }
        if let action,NSApp.sendAction(action,to:nil,from:self) { return true }
        return super.performKeyEquivalent(with:event)
    }
}

final class EchoSettings:NSObject,NSWindowDelegate {
    static let shared=EchoSettings()
    let model:EchoSettingsModel
    var activateApp:()->Void = { NSApp.activate(ignoringOtherApps:true) }
    var presentWindow:(NSWindow)->Void = { $0.makeKeyAndOrderFront(nil) }
    private var restoreAfterKeyAccess=false
    let window=EchoSettingsWindow(contentRect:NSRect(x:0,y:0,width:840,height:720),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    override init() {
        model=EchoSettingsModel(); super.init()
        window.title="APT 设置"; window.isReleasedWhenClosed=false; window.hidesOnDeactivate=false; window.minSize=NSSize(width:760,height:560)
        window.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
        window.contentView=NSHostingView(rootView:EchoSettingsView(model:model,window:window)); window.delegate=self
        model.keyOperationStarted={ [weak self] in
            guard let self,self.window.isVisible else { return }
            self.restoreAfterKeyAccess=true; self.window.level = .floating
        }
        model.keyOperationFinished={ [weak self] in
            guard let self else { return }
            defer { self.restoreAfterKeyAccess=false }
            guard self.restoreAfterKeyAccess,self.window.isVisible else { return }
            self.window.level = .floating; self.activateApp(); self.presentWindow(self.window)
            self.recordWindow("key_access_finished")
        }
        window.center(); _ = window.setFrameAutosaveName("EchoSettings")
    }
    func show(_ section:EchoSettingsModel.Section?=nil) {
        if let section { model.section=section }
        // Reopening keeps what is being typed; a closed window starts from what is saved.
        if !window.isVisible { model.refresh() }
        // Echo has no Dock icon: float while in use so the window is not lost behind the app being typed in.
        window.level = .floating; activateApp(); presentWindow(window); recordWindow("shown")
    }
    func windowDidBecomeKey(_ notification:Notification) { window.level = .floating; model.countRuns(); model.refreshed += 1 }
    // Step back when another app comes forward, e.g. System Settings for the microphone or the browser for WithEcho.
    func windowDidResignKey(_ notification:Notification) { model.stopRecording(); if !model.keyOperationBusy { window.level = .normal }; recordWindow("resigned_key") }
    func windowWillClose(_ notification:Notification) { restoreAfterKeyAccess=false; model.stopRecording(); model.modelKey=""; model.voiceKey=""; recordWindow("closed") }
    private func recordWindow(_ event:String) {
        MemoryLog.shared.settingsWindow(SettingsWindowEvent(event:event,visible:window.isVisible,level:window.level.rawValue,key_access:model.keyOperationBusy,pid:ProcessInfo.processInfo.processIdentifier,version:MemoryLog.appVersion))
    }
}

struct SettingsWindowEvent:Encodable {
    var schema="echo.settings.window/1", at=MemoryLog.timestamp(Date())
    let event:String, visible:Bool, level:Int, key_access:Bool, pid:Int32, version:String
}

// Native controls share one readable layout across all six settings pages.
struct APTSettingsContent<Content:View>:View {
    let content:Content
    init(@ViewBuilder content:()->Content) { self.content=content() }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) { content }
                .padding(.horizontal,26).padding(.bottom,24).frame(maxWidth:760)
                .frame(maxWidth:.infinity,alignment:.topLeading)
        }
    }
}
struct APTSettingsToggleStyle:ToggleStyle {
    func makeBody(configuration:Configuration)->some View {
        HStack(spacing:16) {
            configuration.label
            Spacer(minLength:16)
            Toggle(isOn:configuration.$isOn) { EmptyView() }.labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
        }.frame(minHeight:36)
            .accessibilityRepresentation { Toggle(isOn:configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}
struct APTSettingsSection<Content:View,Header:View,Footer:View>:View {
    let content:Content, header:Header, footer:Footer
    init(@ViewBuilder content:()->Content,@ViewBuilder header:()->Header,@ViewBuilder footer:()->Footer) {
        self.content=content();self.header=header();self.footer=footer()
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            header.font(.system(size:15,weight:.semibold))
            content.font(.system(size:13))
            footer.font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
        }.toggleStyle(APTSettingsToggleStyle()).textFieldStyle(.roundedBorder)
            .padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color(nsColor:EchoUI.cardFill),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(Color(nsColor:EchoUI.stroke)))
    }
}
extension APTSettingsSection where Header == Text,Footer == EmptyView {
    init(_ title:String,@ViewBuilder content:()->Content) { self.init(content:content,header:{ Text(title) },footer:{ EmptyView() }) }
}
extension APTSettingsSection where Header == EmptyView,Footer == EmptyView {
    init(@ViewBuilder content:()->Content) { self.init(content:content,header:{ EmptyView() },footer:{ EmptyView() }) }
}

struct EchoSettingsView:View {
    @ObservedObject var model:EchoSettingsModel
    @State private var showingVoiceKey=false
    weak var window:NSWindow?
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:18) {
                HStack(spacing:10) {
                    Image(nsImage:EchoUI.brandImage("APTLogo")).resizable().scaledToFit()
                        .frame(width:30,height:30).accessibilityHidden(true)
                    Text("APT").font(.system(size:24,weight:.semibold))
                }.padding(.horizontal,20).padding(.top,22)
                List(EchoSettingsModel.Section.allCases,selection:Binding(get:{ Optional(model.section) },set:{ if let section=$0 { model.section=section } })) { section in
                    Label(section.rawValue,systemImage:section.symbol).tag(section).padding(.vertical,8)
                        .listRowBackground(Color.clear)
                }.listStyle(.sidebar).scrollContentBackground(.hidden).background(Color.clear)
            }
            .frame(width:184).background(Color(nsColor:.windowBackgroundColor))
            Divider()
            VStack(alignment:.leading,spacing:0) {
                VStack(alignment:.leading,spacing:6) {
                    Text(model.section.rawValue).font(.system(size:26,weight:.semibold))
                    Text(sectionSubtitle).font(.system(size:13)).foregroundStyle(.secondary)
                }.padding(.horizontal,26).padding(.top,24).padding(.bottom,18)
                Group {
                    switch model.section {
                    case .general: general
                    case .shortcuts: shortcuts
                    case .memory: memory
                    case .voice: voice
                    case .peripheral: AU05SettingsView()
                    case .model: modelPane
                    }
                }.formStyle(.grouped).scrollContentBackground(.hidden)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                .background(Color(nsColor:EchoUI.windowFill))

        }
        .onReceive(NotificationCenter.default.publisher(for:.echoMemoryActivityChanged).receive(on:RunLoop.main)) { _ in model.refreshed += 1 }
    }
    private var sectionSubtitle:String {
        switch model.section {
        case .general: return "让中文与英文切换更顺手。"
        case .shortcuts: return "常用操作，留在你的手边。"
        case .memory: return "选择可查询的材料，也管理记录与同步。"
        case .voice: return "按住说话，松开识别，文字留在当前输入处。"
        case .peripheral: return "连接外设，配置按键、麦克风与反馈。"
        case .model: return "记忆生成与语音共用一套服务，连接和授权都在这里。"
        }
    }
    private func activityDate(_ date:Date?)->String {
        guard let date else { return "—" }
        let format=DateFormatter(); format.dateFormat="MM-dd HH:mm"; return format.string(from:date)
    }
    private func footnote(_ text:String)->some View { Text(text).font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal:false,vertical:true) }
    private func footnoteDetail(_ summary:String,details:String)->some View {
        VStack(alignment:.leading,spacing:8) {
            footnote(summary)
            DisclosureGroup("了解详情") { footnote(details).padding(.top,4) }.font(.system(size:12)).foregroundStyle(.secondary)
        }
    }
    // Results read like the rest of macOS: an icon carries the colour, the words stay readable.
    private func status(_ text:String,_ tone:EchoSettingsModel.Tone,busy:Bool=false)->some View {
        HStack(alignment:.firstTextBaseline,spacing:6) {
            if busy { ProgressView().controlSize(.small) }
            else if tone == .success { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green) }
            else if tone == .failure { Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange) }
            Text(text).foregroundStyle(tone == .plain ? .secondary : .primary).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
        }.font(.system(size:12))
    }

    var general:some View {
        APTSettingsContent {
            APTSettingsSection {
                Toggle("Caps Lock 切换中英文",isOn:model.toggle({ EchoCapsLock.switchesMode },{ EchoCapsLock.defaults.set($0,forKey:"capsLockSwitchesMode") }))
            } header: { Text("中英切换") } footer: {
                footnote("单按 Shift 始终切换中 / 英，已打的字母原样上屏。开启此项后，Caps Lock 灯亮时打英文（字母仍小写，Shift 打大写），灯灭回到 Shift 选的模式；关闭则 Caps Lock 输入大写字母。")
            }
            APTSettingsSection("关于") {
                LabeledContent("版本",value:((Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String) ?? "—")+" / "+((Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String) ?? "—"))
                LabeledContent("拼音方案",value:"明月拼音 · 简化字（Rime）")
            }
        }
    }
    var shortcuts:some View {
        APTSettingsContent {
            APTSettingsSection {
                ForEach(EchoShortcutSlot.allCases,id:\.self) { slot in
                    LabeledContent(slot.title) {
                        HStack {
                            Button(model.recording == slot ? "按下新快捷键…" : slot.current.label) { model.record(slot,in:window) }
                                .frame(minWidth:120)
                            Button("恢复默认") { model.reset(slot) }.controlSize(.small)
                        }
                    }
                }
            } header: { Text("可自定义") } footer: {
                status(model.shortcutNote,model.shortcutError ? .failure : .plain)
            }
            APTSettingsSection {
                LabeledContent("中 / 英切换",value:EchoCapsLock.switchesMode ? "单按 ⇧ 或 Caps Lock" : "单按 ⇧")
                LabeledContent("系统听写",value:"⌃⇧D（macOS）")
            } header: { Text("固定按键") } footer: {
                footnote("自定义快捷键需包含 ⌃ 或 ⌥。macOS 不会告诉 APT 其他 App 是否占用了同一组合，按下没反应时换一个即可。")
            }
        }
    }
    var memory:some View {
        APTSettingsContent {
            withEchoSection
            APTSettingsSection {
                LabeledContent("快捷键",value:MemoryBinding.label)
                Toggle("停顿后自动查找记忆",isOn:model.toggle({ MemoryInline.automatic },{ MemoryInline.setAutomatic($0) }))
            } header: { Text("调用记忆") } footer: {
                footnote("写一句要查的话，按 \(MemoryBinding.label) 查找，再按一次填入。自动查找默认关闭：开启后，含回忆意图的短句停顿约 0.85 秒就会查找，可能产生模型费用。")
            }
            APTSettingsSection {
                Toggle("自动记录输入",isOn:model.toggle({ InputMemoryRecorder.enabled },{ InputMemoryRecorder.setEnabled($0) }))
                Button("管理本地输入记忆…") { InputMemoryLibrary.shared.show() }
            } header: { Text("本地输入记忆") } footer: {
                footnote("在 APT 里打的段落停顿约 2 秒后存到本机，不调用模型；开启 APT 同步后原文也会上传到私有来源库。调用记忆时，相关片段会和问题一起发给模型。终端、密码类应用和安全输入不记录。用 ⌘V 粘贴的文字会单独标出，不当作你说的话。")
            }
            APTSettingsSection {
                Toggle("使用本机向量检索",isOn:model.toggle({ MemoryVectors.enabled },{ MemoryVectors.defaults.set($0,forKey:"memoryVectorsEnabled") }))
                Picker("检索模型",selection:Binding(get:{ _ = model.refreshed; return MemoryVectors.model },set:{ MemoryVectors.defaults.set($0,forKey:"memoryEmbeddingModel"); model.vectorNote=""; model.refreshed += 1 })) {
                    Text("Qwen3 Embedding 0.6B · 轻量").tag(MemoryVectors.models[0])
                    Text("Qwen3 Embedding 4B").tag(MemoryVectors.models[1])
                    Text("Qwen3 Embedding 8B").tag(MemoryVectors.models[2])
                }.disabled(!MemoryVectors.enabled)
                HStack {
                    Button("检查本机服务") { model.checkVectors() }
                    Spacer()
                    Button("清空索引缓存") { model.checkVectors(clear:true) }
                }.disabled(model.vectorBusy)
            } header: { Text("语义查找") } footer: {
                VStack(alignment:.leading,spacing:6) {
                    if !model.vectorNote.isEmpty { status(model.vectorNote,.plain,busy:model.vectorBusy) }
                    else if let info=MemoryVectors.latest,let error=info.error { status(MemoryVectors.reason(error)+"；上次查找使用正文关键词。",.failure) }
                    footnoteDetail("使用本机 Ollama，正文不发送给外部向量服务。失败时降级为正文关键词；关闭不影响关键词检索。",details:"使用本机 Ollama，正文不发往外部 embedding 服务。较长范围用关键词和向量一起查找，再读取连续上下文；正文不变就复用向量，首次建立索引会慢一些。一两天的小范围仍可完整读取。切换模型前需在 Ollama 安装它；清空只删除向量缓存。关闭后使用原来的正文模型匹配。")
                }
            }
            APTSettingsSection {
                Toggle("按输入活动自动整理",isOn:model.toggle({ DayDigester.enabled },{ DayDigester.setEnabled($0) }))
                LabeledContent("状态",value:MemoryActivityCoordinator.shared.status.phase)
                LabeledContent("待整理",value:"\(MemoryActivityCoordinator.shared.status.pending) 条；暂停 \(MemoryActivityCoordinator.shared.status.paused) 天")
                LabeledContent("预计下次",value:activityDate(MemoryActivityCoordinator.shared.status.next))
                LabeledContent("上次完成",value:activityDate(MemoryActivityCoordinator.shared.status.lastCompleted))
                Button("立即整理 / 重试") { MemoryActivityCoordinator.shared.runNow() }
                    .disabled(!DayDigester.enabled || MemoryActivityCoordinator.shared.status.busy)
            } header: { Text("增量整理") } footer: {
                VStack(alignment:.leading,spacing:6) {
                    if !MemoryActivityCoordinator.shared.status.failures.isEmpty { status(MemoryActivityCoordinator.shared.status.failures,.failure) }
                    else if let error=DayDigester.lastError { status("上次整理没有完成：\(error)",.failure) }
                    footnoteDetail("只整理新增或改写的草稿，使用后台模型。最近一批概要不代表完整全天；关闭会删除整理结果，保留原始草稿。",details:"有变化才调用后台模型：正常约 30 分钟，新增或有效改写较多约 15 分钟，零星变化最长 60 分钟；空闲自动延长检查，新输入立即唤醒。只处理新增和修改草稿，按天聚合概要、待办和表态；最近一批概要不代表完整全天。某一天失败不影响其他日期；同一批最多自动尝试两次，之后等草稿变化或手动重试。关闭删除整理，原始草稿保留。")
                }
            }
            APTSettingsSection {
                TextField("APT 服务地址",text:$model.growthEndpoint)
                SecureField("APT 门禁令牌",text:$model.growthToken)
                Button("保存并同步到 APT") { model.connectGrowth() }.disabled(model.growthBusy)
                Toggle("同步输入来源到 APT Agent",isOn:model.toggle({ GrowthMemoryConfig.enabled },{ GrowthMemoryConfig.defaults.set($0,forKey:"growthMemorySyncEnabled"); if $0 { GrowthMemorySync.catchUp() } }))
                if !model.growthNote.isEmpty { Text(model.growthNote).font(.caption) }
                if let error=GrowthMemorySync.status.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("共用 APT 记忆") } footer: {
                footnote("开启后，原始输入和来源标记约每分钟同步到 APT 的私有来源库；断网自动补传。删除和恢复一起同步，版本冲突保留待处理。本机 APT 可读取已同步来源；令牌只存钥匙串。关闭暂停同步，已经同步的来源仍保留。")
            }
            APTSettingsSection {
                Toggle("读取飞书会议纪要",isOn:model.toggle({ MeetingNotes.enabled },{ MeetingNotes.setEnabled($0) }))
                LabeledContent("上次同步",value:MeetingNotes.synced.map { $0.formatted(date:.abbreviated,time:.shortened) } ?? "还没有")
                HStack { Spacer(); Button("立即同步") { model.syncMeetings() }.disabled(model.meetingBusy || !MeetingNotes.enabled) }
            } header: { Text("飞书会议") } footer: {
                VStack(alignment:.leading,spacing:6) {
                    if !model.meetingNote.isEmpty { status(model.meetingNote,.plain,busy:model.meetingBusy) }
                    else if let error=MeetingNotes.lastError { status("上次同步没有完成：\(error)",.failure) }
                    footnote("用你本机已登录的 lark-cli，只读：每半小时把最近 7 天开过的会议和飞书智能纪要的「总结」「待办」同步到本机，调用记忆时作为来源发给文字模型。逐字稿不读取。关闭即删除已同步的纪要。")
                }
            }
            APTSettingsSection {
                Toggle("根据我的输入总结表达习惯",isOn:model.toggle({ StyleProfile.enabled },{ StyleProfile.setEnabled($0) }))
                LabeledContent("上次总结",value:StyleProfile.shared.updated.map { $0.formatted(date:.abbreviated,time:.shortened) } ?? "还没有")
                HStack { Button("打开…") { model.openStyle() }; Spacer(); Button("立即总结") { model.updateStyle() }.disabled(model.styleBusy || !StyleProfile.enabled) }
            } header: { Text("我的表达习惯") } footer: {
                VStack(alignment:.leading,spacing:6) {
                    if !model.styleNote.isEmpty { status(model.styleNote,.plain,busy:model.styleBusy) }
                    else if let error=StyleProfile.lastError { status("上次总结没有完成：\(error)",.failure) }
                    footnoteDetail("使用本人键入、语音和 WithEcho 碎碎念总结表达习惯，不含粘贴和全天录音。整理需要发送给后台模型；「我的补充」由你填写，APT 不修改。",details:"调用记忆照这份文件用你的口吻写字。开启后，每周把你近 30 天亲手打的字和语音输入（不含粘贴）、WithEcho 碎碎念发给「Agent 服务」中的后台模型，总结成本机的 Style.md；文件下半段「我的补充」由你写，APT 不会改。全天录音分不出哪句是你说的，不使用。")
                }
            }
            APTSettingsSection {
                LabeledContent("执行记录",value:"\(model.runCount) 次查找 · \(model.voiceCount) 次语音")
                Button("清空执行记录…") { model.confirmingClearRuns=true }.disabled(!model.hasRuns)
            } header: { Text("改进 APT") } footer: {
                footnoteDetail("查找与语音执行记录只存本机，不上传。清空不影响输入来源和模型用量账本。",details:"每次调用记忆的问句、选中的来源、回复和各步耗时，以及每次语音的识别原文、整理结果和你之后改成的样子（需开启「自动记录输入」），只存在本机，用来找出慢在哪、错在哪（错字出在识别还是整理），不上传。模型用量另记一份只有数字的账本，清空时保留。")
            }
        }
        .alert("清空执行记录？",isPresented:$model.confirmingClearRuns) {
            Button("清空",role:.destructive) { model.clearRuns() }
            Button("取消",role:.cancel) {}
        } message: {
            Text("会删除本机保存的问句、回复与语音记录，不影响本地输入记忆和模型用量账本。")
        }
    }
    var voice:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                voiceCard {
                    HStack(spacing:12) {
                        Image(systemName:"mic.fill").font(.system(size:20,weight:.medium)).foregroundStyle(Color.accentColor)
                            .frame(width:42,height:42).background(Color.accentColor.opacity(0.09),in:RoundedRectangle(cornerRadius:10))
                        VStack(alignment:.leading,spacing:4) {
                            Text("开始说话").font(.system(size:15,weight:.semibold))
                            footnote(VoiceInput.readySoundEnabled ? "听到提示音后开始，松开快捷键识别。" : "浮条显示正在听后开始，松开快捷键识别。")
                        }
                        Spacer(minLength:8)
                        Text(VoiceBinding.label).font(.system(size:16,weight:.medium)).padding(.horizontal,12).padding(.vertical,7)
                            .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:7))
                            .overlay(RoundedRectangle(cornerRadius:7).stroke(Color.primary.opacity(0.08)))
                    }
                    Divider()
                    voiceSwitch("停顿后自动结束",detail:"轻按开启免手动模式，停顿约 1.5 秒结束",isOn:model.toggle({ VoiceInput.automaticEnd },{ UserDefaults.standard.set($0,forKey:"voiceAutomaticEnd") }))
                    voiceSwitch("开始录音提示音",detail:"麦克风收到音频后响一声，避免过早开口",isOn:model.toggle({ VoiceInput.readySoundEnabled },{ VoiceInput.defaults.set($0,forKey:"voiceReadySound") }))
                    footnote("Return 结束 · Esc 取消").padding(.top,2)
                }
                voiceCard {
                    voiceRow("语言") {
                        Picker("语言",selection:model.choice("stepVoiceLanguage","auto")) {
                            Text("中英混说（自动）").tag("auto")
                            Text("中文为主").tag("zh"); Text("英语为主").tag("en")
                        }.labelsHidden().frame(width:206)
                    }
                    Button("麦克风权限…") { model.microphone() }.controlSize(.small)
                    footnote("识别服务与 Key 在「Agent 服务」统一管理。")
                }
                voiceCard {
                    HStack {
                        Text("常用词").font(.system(size:14,weight:.semibold))
                        Spacer()
                        Text("已添加 \(VoiceTerms.all.count) 个词").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    footnote("填写人名、产品名和术语，减少同音错字。")
                    TextField("人名、产品名或术语",text:Binding(get:{ _ = model.refreshed; return VoiceTerms.defaults.string(forKey:"voiceHotwords") ?? "" },set:{ VoiceTerms.defaults.set($0,forKey:"voiceHotwords"); model.refreshed += 1 }),prompt:Text("例如：WithEcho, Codex, StepFun"),axis:.vertical)
                        .lineLimit(2...5).textFieldStyle(.plain).padding(10)
                        .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:7))
                        .overlay(RoundedRectangle(cornerRadius:7).stroke(Color.primary.opacity(0.12)))
                        .accessibilityLabel("常用词")
                    footnote("用逗号或换行分隔 · 最多 100 个 · 自动保存")
                    if StepASR.hotwordsRefused {
                        status("识别服务本次未接受热词，已改为普通识别；整理时仍使用这些写法。",.failure)
                    }
                    DisclosureGroup("这些词如何使用？") {
                        footnote("识别时随录音发给 StepFun；开启轻整理后，也作为纠正同音错字的依据。已添加的数量只表示本地词条，不能保证每次识别都会采用。每个词最多 30 字，重复的词只保留一次。")
                            .padding(.top,4)
                    }.font(.system(size:12)).foregroundStyle(.secondary)
                }
                voiceCard {
                    voiceSwitch("轻整理文字",detail:"去口头禅、重复和补标点，保留原句和语气",isOn:model.toggle({ VoiceInput.polishEnabled },{ VoiceInput.defaults.set($0,forKey:"voicePolishEnabled") }))
                    DisclosureGroup("整理范围") {
                        footnote("保留原句、词语和语气，主要去口头禅、重复和补标点；不把无关中文猜成英文产品名，不添加事实、不回答问题。使用实时模型，每次语音一次请求，不查询记忆；检查发现可能改变原意时改填识别原文。")
                            .padding(.top,4)
                    }.font(.system(size:12)).foregroundStyle(.secondary)
                }
                footnote("设置自动保存").padding(.top,2)
            }
            .padding(.horizontal,26).padding(.bottom,24).frame(maxWidth:760).frame(maxWidth:.infinity,alignment:.topLeading)
        }
        .background(Color(nsColor:.windowBackgroundColor))
    }
    private var voiceConnectionSummary:String {
        let key=UserDefaults.standard.bool(forKey:"stepVoiceKeyConfigured") ? "Key 已保存" : "Key 未配置"
        let microphone=AVCaptureDevice.authorizationStatus(for:.audio) == .authorized ? "麦克风已允许" : "麦克风待授权"
        return key+" · "+microphone
    }
    private func voiceCard<Content:View>(@ViewBuilder _ content:()->Content)->some View {
        APTSettingsSection(content:content)
    }
    private func voiceRow<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View {
        HStack(spacing:12) { Text(title); Spacer(minLength:12); content() }.font(.system(size:13))
    }
    private func voiceSwitch(_ title:String,detail:String,isOn:Binding<Bool>)->some View {
        HStack(spacing:16) {
            VStack(alignment:.leading,spacing:4) { Text(title).font(.system(size:13,weight:.medium)); footnote(detail) }
            Spacer(minLength:12)
            Toggle(title,isOn:isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
        }
    }
    private func modelField<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View {
        HStack(spacing:14) {
            Text(title).font(.system(size:13,weight:.medium)).frame(width:80,alignment:.leading)
            content().textFieldStyle(.roundedBorder).font(.system(size:13))
                .frame(maxWidth:.infinity).accessibilityLabel(title)
        }
    }
    private func serviceStat(_ value:Int?,_ title:String)->some View {
        HStack(alignment:.firstTextBaseline,spacing:6) {
            Text(value.map(String.init) ?? "—").font(.system(size:21,weight:.semibold)).monospacedDigit()
            Text(title).font(.system(size:12)).foregroundStyle(.secondary)
        }.accessibilityElement(children:.combine)
    }
    var modelPane:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                voiceCard {
                    HStack(spacing:12) {
                        Image(systemName:model.agentConnected ? "checkmark.circle.fill" : "server.rack")
                            .font(.system(size:22)).foregroundStyle(model.agentConnected ? Color.accentColor : Color.secondary)
                            .frame(width:42,height:42).background(Color.accentColor.opacity(0.08),in:RoundedRectangle(cornerRadius:10)).accessibilityHidden(true)
                        VStack(alignment:.leading,spacing:4) {
                            Text(model.agentChecking ? "正在核验连接…" : model.agentConnected ? "记忆 Agent 服务已连接" : "记忆 Agent 服务待连接").font(.system(size:16,weight:.semibold))
                            footnote(model.agentConnected ? (model.agentFeedReady ? "来源已就绪，可供记忆查询使用。" : "来源流尚未就绪，缓存不代表最新完整范围。") : "输入记忆和模型调用由本机记忆 Agent 服务执行。")
                        }
                        Spacer(minLength:8)
                        if model.agentChecking { ProgressView().controlSize(.small) }
                    }
                    if model.agentConnected {
                        HStack(spacing:24) { serviceStat(model.agentSources,"条同步草稿");serviceStat(model.agentDevices,"台设备");Spacer(minLength:0) }
                        Text(model.agentSources == 0 ? "尚无同步来源。" : model.agentRange).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if !model.agentChecking,model.agentSummary.hasPrefix("记忆 Agent 服务不可用") { status(model.agentSummary,.failure) }
                    if model.agentConnected { footnote(model.agentRecordingSummary) }
                    footnote("仅覆盖成功同步的材料；手机未同步的录音或修改、未上传草稿不在本轮范围。")
                    HStack {
                        Button("核验连接") { Task { await model.checkAgent() } }.disabled(model.agentChecking)
                        Spacer()
                    }
                    DisclosureGroup("服务详情") { footnote(model.agentDiagnostic.isEmpty ? model.agentSummary : model.agentDiagnostic).textSelection(.enabled).padding(.top,6) }
                        .font(.system(size:12)).foregroundStyle(.secondary)
                }
                voiceCard {
                    Text("实时模型").font(.system(size:15,weight:.semibold))
                    footnote("用于调用记忆和语音整理，优先响应速度。")
                    Group {
                        modelField("服务地址") { TextField("以 https:// 开头",text:$model.endpoint) }
                        modelField("模型名称") { TextField("服务商提供的 model ID",text:$model.modelName) }
                        modelField("API Key") { SecureField(model.savedConfig ? "已保存在钥匙串，留空不变" : "填写 API Key",text:$model.modelKey) }
                    }.disabled(model.testing)
                    Divider()
                    HStack {
                        Button("授权 Key") { model.authorizeModelKey() }.disabled(!model.savedConfig || model.testing)
                            .accessibilityLabel("授权模型 Key")
                        Button("清除配置…") { model.confirmingReset=true }.disabled(!model.canResetModel || model.testing)
                        Spacer(minLength:8)
                        Button(model.testing ? "正在测试…" : "保存并测试") { model.saveAndTest() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.testing)
                    }
                    status(model.modelNote,model.modelTone,busy:model.testing)
                    DisclosureGroup("发送与密钥说明") { footnote("只向配置地址发送本次所需的记录和文字。Key 存于 macOS 钥匙串；更换服务地址需重新填写。「保存并测试」仅发送一条虚构消息，不含你的记录。").padding(.top,6) }.font(.system(size:12)).foregroundStyle(.secondary)
                }
                voiceCard {
                    Text("语音识别").font(.system(size:15,weight:.semibold))
                    footnote("录音发送给 StepAudio 2.5 ASR；语言与录音操作在语音页。")
                    modelField("调用方式") {
                        Picker("调用方式",selection:model.choice("stepVoiceRoute","plan")) {
                            Text("Step Plan").tag("plan");Text("开放平台 API").tag("platform")
                        }.labelsHidden()
                    }.disabled(model.voiceBusy)
                    modelField("StepFun Key") { SecureField("留空保留已保存的 Key",text:$model.voiceKey) }.disabled(model.voiceBusy)
                    Divider()
                    HStack {
                        Button("授权 Key") { model.authorizeVoiceKey() }.disabled(model.voiceBusy).accessibilityLabel("授权语音 Key")
                        Spacer()
                        Button("保存语音 Key") { model.saveVoiceKey() }.disabled(model.voiceBusy)
                    }
                    status(model.voiceNote,model.voiceTone,busy:model.voiceBusy)
                }
                voiceCard {
                    Text("后台模型").font(.system(size:15,weight:.semibold))
                    footnote("用于增量整理和表达习惯总结；留空沿用实时模型。")
                    Group {
                        modelField("服务地址") { TextField("留空沿用实时模型",text:$model.backgroundEndpoint) }
                        modelField("模型名称") { TextField("留空沿用实时模型",text:$model.backgroundModel) }
                    }.disabled(model.backgroundTesting)
                    footnote("使用："+model.backgroundKeyLabel)
                    HStack { Spacer();Button(model.backgroundTesting ? "正在测试…" : "保存并测试") { model.saveBackground() }.disabled(model.backgroundTesting).accessibilityLabel("保存并测试后台模型") }
                    status(model.backgroundNote,model.backgroundTone,busy:model.backgroundTesting)
                    DisclosureGroup("可用服务") { footnote("支持实时模型的同一服务或 StepFun，并复用对应 Key。StepFun 使用本页语音识别 Key，不另存凭据。").padding(.top,6) }.font(.system(size:12)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal,26).padding(.bottom,24).frame(maxWidth:760).frame(maxWidth:.infinity,alignment:.topLeading)
        }
        .task { await model.checkAgent() }
        .alert("清除模型配置？",isPresented:$model.confirmingReset) {
            Button("清除",role:.destructive) { model.resetModel() }
            Button("取消",role:.cancel) {}
        } message: { Text("会删除服务地址、模型名称和钥匙串中的 API Key。重新配置前，调用记忆和语音整理无法使用。") }
    }
    var withEchoSection:some View {
            APTSettingsSection {
                LabeledContent {
                    HStack(spacing:8) {
                        ProgressView().controlSize(.small).opacity(model.connecting ? 1 : 0)  // reserved: no layout jump
                        Button(model.withEcho == .connected || model.withEcho == .needsReconnect ? "重新连接" : "连接 WithEcho") { model.connectWithEcho() }.disabled(model.connecting)
                    }
                } label: {
                    HStack(spacing:6) { Circle().fill(withEchoDot).frame(width:8,height:8); Text(withEchoState) }
                }
            } header: { Text("WithEcho") } footer: {
                if !model.withEchoError.isEmpty && !model.connecting { status(model.withEchoError,.failure) } else { footnote(withEchoDetail) }
            }
    }
    private var withEchoState:String {
        if model.connecting { return "等待浏览器授权…" }
        switch model.withEcho {
        case .checking: return "正在检查…"
        case .connected: return "已连接"
        case .needsReconnect: return "需要重新连接"
        case .disconnected: return "未连接"
        case .unavailable: return "无法确认"
        }
    }
    private var withEchoDot:Color {
        if model.connecting { return .secondary.opacity(0.5) }
        switch model.withEcho {
        case .connected: return .green
        case .needsReconnect,.unavailable: return .orange
        case .checking,.disconnected: return .secondary.opacity(0.5)
        }
    }
    private var withEchoDetail:String {
        if model.connecting { return "请在浏览器完成 WithEcho 授权，最多等待 5 分钟。" }
        switch model.withEcho {
        case .needsReconnect: return "当前授权没有日常读取权限，APT 读不到你的 WithEcho 日常。"
        case .unavailable: return "无法读取本机授权状态。WithEcho 连接需要 Python 3。"
        default: return "调用记忆时读取你在 WithEcho 的日常记录；授权在浏览器中完成。"
        }
    }
}

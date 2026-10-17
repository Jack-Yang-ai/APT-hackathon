import Cocoa
import AVFoundation
import Carbon
import Security

protocol VoiceTarget:AnyObject {
    var acceptsVoice:Bool { get }
    func voicePosition()->VoicePosition?
    func voiceAnchor()->NSRect
    @MainActor func insertVoice(_ text:String,position:VoicePosition) async -> VoiceInsertionResult
    func voiceRefusal()->String  // short reason shown at the caret when voice cannot start or fill in here
    var voiceApp:String? { get }  // the app's bundle id, for the dictation record
    var voiceIdentity:String? { get }  // IMK client identity, preserved across a temporary reactivation
    var voiceFocusStamp:String? { get }  // active input session; changes on focus and user edits
}
extension VoiceTarget { var voiceIdentity:String? { nil }; var voiceFocusStamp:String? { nil } }

protocol VoiceRecorderDevice:AnyObject {
    var delegate:AVAudioRecorderDelegate? { get set }
    var isMeteringEnabled:Bool { get set }
    var currentTime:TimeInterval { get }
    func prepareToRecord()->Bool
    func record()->Bool
    func stop()
    func updateMeters()
    func averagePower(forChannel channel:Int)->Float
}
extension AVAudioRecorder:VoiceRecorderDevice {}

final class VoiceSurface:NSView {
    var radius:CGFloat=22 { didSet { needsDisplay=true } }
    override init(frame:NSRect) {
        super.init(frame:frame)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect:NSRect) {
        let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:radius,yRadius:radius)
        EchoUI.floatingFill.setFill(); path.fill()
        EchoUI.stroke.setStroke(); path.lineWidth=1; path.stroke()
    }
}
final class VoiceActionButton:NSButton {
    override func draw(_ dirtyRect:NSRect) {
        if isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect:bounds,xRadius:6,yRadius:6).fill()
        }
        let label=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium),.foregroundColor:NSColor.controlAccentColor])
        let size=label.size(); label.draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2))
    }
    override var intrinsicContentSize:NSSize { NSSize(width:ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium)]).width)+16,height:26) }
}
final class VoiceCopyButton:NSButton {
    private var hover=false, tracking:NSTrackingArea?, feedback=UUID()
    override init(frame:NSRect) {
        super.init(frame:frame); isBordered=false; refusesFirstResponder=true; imagePosition = .imageOnly
        symbolConfiguration=NSImage.SymbolConfiguration(pointSize:15,weight:.regular); reset()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reset() {
        feedback=UUID(); image=NSImage(systemSymbolName:"doc.on.doc",accessibilityDescription:"复制完整文字")
        title=""; imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor; toolTip="复制完整文字"; setAccessibilityLabel("复制完整转写文字")
    }
    func showCopied() {
        let token=UUID(); feedback=token
        image=NSImage(systemSymbolName:"checkmark",accessibilityDescription:"已复制")
        title=""; imagePosition = .imageOnly
        contentTintColor = .systemGreen; toolTip="已复制完整文字"; setAccessibilityLabel("已复制完整转写文字")
        DispatchQueue.main.asyncAfter(deadline:.now()+1.2) { [weak self] in
            guard let self,self.feedback == token else { return }; self.reset()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); tracking=area
    }
    override func mouseEntered(with event:NSEvent) { hover=true; needsDisplay=true }
    override func mouseExited(with event:NSEvent) { hover=false; needsDisplay=true }
    override func draw(_ dirtyRect:NSRect) {
        if hover || isHighlighted {
            NSColor.black.withAlphaComponent(0.04).setFill()
            NSBezierPath(roundedRect:bounds,xRadius:7,yRadius:7).fill()
        }
        super.draw(dirtyRect)
    }
    override var intrinsicContentSize:NSSize { NSSize(width:28,height:28) }
}
// Draw the small progress arc with the same adaptive accent as the waveform. AppKit's
// inactive-window spinner can disappear against a dark, nonactivating material panel.
final class VoiceSpinner:NSView {
    private var animation:Timer?, angle:CGFloat=0
    func startAnimation(_ sender:Any?) {
        isHidden=false
        guard animation == nil else { return }
        animation=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true) { [weak self] _ in
            guard let self else { return }; self.angle=(self.angle+18).truncatingRemainder(dividingBy:360); self.needsDisplay=true
        }
    }
    func stopAnimation(_ sender:Any?) { animation?.invalidate(); animation=nil; isHidden=true }
    override func draw(_ dirtyRect:NSRect) {
        let path=NSBezierPath(); path.appendArc(withCenter:NSPoint(x:bounds.midX,y:bounds.midY),radius:max(0,min(bounds.width,bounds.height)/2-2),startAngle:angle,endAngle:angle+270)
        path.lineWidth=2; path.lineCapStyle = .round; NSColor.controlAccentColor.setStroke(); path.stroke()
    }
    deinit { animation?.invalidate() }
}

// Allocate the file and recording resources before a press. Preparation never calls record().
// One serial queue owns preparation, consumption and disposal, including a focus change mid-prepare.
final class VoiceRecorderPool {
    struct Prepared { let device:VoiceRecorderDevice, file:URL }
    let queue=DispatchQueue(label:"local.echo.voice.prepare",qos:.userInitiated)
    var factory:(URL) throws -> VoiceRecorderDevice = { url in
        try AVAudioRecorder(url:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000.0,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
    }
    let root:URL
    private var prepared:Prepared?, rootReady=false
    init(root:URL=FileManager.default.temporaryDirectory.appendingPathComponent("EchoVoiceAudio",isDirectory:true)) { self.root=root }
    private func make() throws -> Prepared {
        if !rootReady {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            for old in (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.contentModificationDateKey])) ?? [] where old.pathExtension == "wav" {
                if let date=try? old.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,Date().timeIntervalSince(date)>3600 { try? FileManager.default.removeItem(at:old) }
            }
            rootReady=true
        }
        let file=root.appendingPathComponent(UUID().uuidString+".wav")
        do {
            let device=try factory(file); device.isMeteringEnabled=true
            guard device.prepareToRecord() else { device.stop(); throw VoiceFailure.message("无法准备麦克风，请检查麦克风连接。") }
            do { try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path) }
            catch { device.stop(); throw error }
            return Prepared(device:device,file:file)
        } catch { try? FileManager.default.removeItem(at:file); throw error }
    }
    func prepare() { queue.async { if self.prepared == nil { self.prepared=try? self.make() } } }
    func take() throws -> Prepared { try queue.sync { if let prepared { self.prepared=nil; return prepared }; return try make() } }
    func discard() { queue.async { self.prepared?.device.stop(); if let file=self.prepared?.file { try? FileManager.default.removeItem(at:file) }; self.prepared=nil } }
}

final class VoiceInput:NSObject,AVAudioRecorderDelegate {
    static let shared:VoiceInput = {
        let voice=VoiceInput()
        voice.onActivityChanged={ EchoMemoryHotKey.shared.sync() }
        return voice
    }()
    static var defaults=UserDefaults.standard  // checks swap in scratch settings
    static var polishEnabled:Bool { defaults.object(forKey:"voicePolishEnabled") == nil || defaults.bool(forKey:"voicePolishEnabled") }
    static var automaticEnd:Bool { UserDefaults.standard.object(forKey:"voiceAutomaticEnd") == nil || UserDefaults.standard.bool(forKey:"voiceAutomaticEnd") }
    static var readySoundEnabled:Bool { defaults.object(forKey:"voiceReadySound") == nil || defaults.bool(forKey:"voiceReadySound") }
    static let microphoneSettings=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    let panel=MemoryCandidatePanel(contentRect:NSRect(x:0,y:0,width:288,height:56),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    let header=EchoUI.label("",weight:.medium), hint=EchoUI.label("",size:11,secondary:true), preview=EchoUI.label("")
    let stopButton=NSButton(), cancelButton=NSButton(), copyButton=VoiceCopyButton(frame:.zero), settingsButton=VoiceActionButton()
    let elapsed=EchoUI.label("",size:13,secondary:true)
    let surface=VoiceSurface(frame:.zero), wave=EchoWaveform(), spinner=VoiceSpinner(), check=NSImageView()
    var endedWithReturn=false, polishing=false, inserting=false, inserted=false, terminal=false
    weak var target:VoiceTarget?
    var position:VoicePosition?, recorder:VoiceRecorderDevice?, file:URL?, clock:Timer?, recording=false, preparing=false, processing=false, pending:String?, generation=UUID(), started=Date(), task:Task<Void,Never>?
    // Esc while polishing fills in the raw transcript. Failed recordings are released; the next key starts a new take.
    var transcript:String?
    var run:VoiceRun?  // this dictation's record, written when its text is filled in or kept
    var polishStarted=Date()
    var gearURL:URL?, autoHide:TimeInterval=8
    var transcriber:((Data) async throws -> String)?, polisher:((String) async throws -> String)?, automaticInsertionAllowed=true, keptBecause:String?, pauseDetector:VoicePauseDetector?
    // How long the words spoken first had to wait: key press to the recorder running, then to the first sound.
    var pressedAt:Date?, startMs:Int?, soundMs:Int?, readyMs:Int?, awaitingSamples=false
    let recorderPool=VoiceRecorderPool()
    var readyCue:()->Void = { if VoiceInput.readySoundEnabled,let sound=NSSound(named:"Pop") { sound.volume=0.15; sound.play() } }
    var heldSince:TimeInterval?  // physical press time on Carbon/NSEvent's monotonic clock, before mic setup
    var heldShortcut:EchoShortcut?
    var heldKeyWasDown=false
    var keyClock:()->TimeInterval = { GetCurrentEventTime() }
    var voiceKeyIsDown:(EchoShortcut)->Bool = { shortcut in
        let flags=NSEvent.ModifierFlags(rawValue:UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        return CGEventSource.keyState(.combinedSessionState,key:shortcut.keyCode) && flags.intersection(shortcut.flags) == shortcut.flags
    }
    var onActivityChanged:(()->Void)?  // only the live singleton updates the global shortcut registration
    var originIdentity:String?, originApp:String?, originFocusStamp:String?, originAnchor=NSRect.zero, mayResume=false
    var recordingStarter:((VoiceTarget)->Void)?  // isolated checks bypass microphone and keychain
    let polishHistory=VoicePolishHistory()
    var polishContext=VoicePolishContext()
    var appObserver:NSObjectProtocol?
    var busy:Bool { recording || preparing || processing || inserting }
    override init() {
        super.init(); panel.hidesOnDeactivate=false; panel.isReleasedWhenClosed=false; panel.level = .floating; panel.hasShadow=true; panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.isOpaque=false; panel.backgroundColor = .clear; panel.isMovableByWindowBackground=true
        panel.contentView=surface
        header.lineBreakMode = .byTruncatingTail; hint.lineBreakMode = .byTruncatingTail; EchoUI.wrapping(preview,lines:6)
        spinner.isHidden=true
        check.image=NSImage(systemSymbolName:"checkmark",accessibilityDescription:"已填入")
        check.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:14,weight:.medium); check.contentTintColor = .systemGreen
        EchoUI.icon(stopButton,"stop.circle.fill",label:"结束录音（Return）"); stopButton.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:20,weight:.regular)
        EchoUI.icon(cancelButton,"xmark",label:"取消"); cancelButton.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:10,weight:.regular)
        for button in [copyButton,settingsButton] { button.isBordered=false; button.refusesFirstResponder=true }
        settingsButton.title="打开设置"
        elapsed.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular); elapsed.alignment = .right
        preview.font = .systemFont(ofSize:14); hint.font = .systemFont(ofSize:12); hint.isHidden=true
        for view in [wave,spinner,check,header,hint,elapsed,preview,stopButton,cancelButton,copyButton,settingsButton] { surface.addSubview(view) }
        for button in [stopButton,cancelButton,copyButton,settingsButton] { button.target=self }
        stopButton.action=#selector(stop); cancelButton.action=#selector(dismiss); copyButton.action=#selector(copyText); settingsButton.action=#selector(openSettings)
        let menu=NSMenu()
        let dismissItem=NSMenuItem(title:"取消本次语音",action:#selector(dismiss),keyEquivalent:""); dismissItem.target=self
        menu.addItem(dismissItem); surface.menu=menu
        surface.setAccessibilityRole(.group); surface.setAccessibilityElement(true)
    }

    // Compact capsule (waiting, recording, recognizing, polishing, filled in) with a fixed status slot on the left.
    func showStatus(notice:String?=nil) {
        onActivityChanged?()
        let title:String, note:String
        if recording && awaitingSamples { title="启动麦克风"; note=Self.readySoundEnabled ? "提示音后说话" : "稍候开始" }
        else if recording { title=recordingTitle; note=recordingHint }
        else if preparing { title="等待麦克风"; note="请允许麦克风" }
        else if polishing { title="正在整理"; note="Esc 使用原文" }
        else if processing { title="正在识别"; note="请稍候" }
        else if inserting { title="正在填入"; note="正在核对" }
        else { title=notice == nil ? "已填入" : "已填入原文"; note=notice == nil ? "" : "已使用原文" }
        let width:CGFloat=busy ? 272 : (notice == nil ? 200 : 320)
        let height:CGFloat=busy ? 66 : (notice == nil ? 48 : 82)
        wave.isHidden = !recording || awaitingSamples;wave.frame=NSRect(x:16,y:height/2-13,width:24,height:26)
        spinner.frame=NSRect(x:20,y:height/2-8,width:16,height:16)
        busy && (!recording || awaitingSamples) ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        check.isHidden=busy;check.frame=NSRect(x:16,y:height/2-9,width:18,height:18)
        header.isHidden=false;header.stringValue=title;header.font = .systemFont(ofSize:13,weight:.semibold)
        header.frame=NSRect(x:52,y:busy ? 35 : height-30,width:busy ? 102 : width-94,height:20)
        hint.stringValue=notice ?? note;hint.toolTip=notice ?? note;hint.isHidden=hint.stringValue.isEmpty
        EchoUI.wrapping(hint,lines:notice == nil ? 1 : 2)
        hint.frame=NSRect(x:52,y:busy ? 10 : 12,width:width-66,height:notice == nil ? 18 : 34)
        elapsed.isHidden = !recording;elapsed.stringValue=recordingTime;elapsed.frame=NSRect(x:160,y:35,width:44,height:20)
        stopButton.isHidden = !recording;stopButton.frame=NSRect(x:212,y:30,width:28,height:28)
        stopButton.toolTip="结束录音并识别（Return）";stopButton.setAccessibilityLabel("结束录音并识别")
        cancelButton.isHidden=false;cancelButton.frame=NSRect(x:width-30,y:busy ? 31 : height-30,width:24,height:24)
        cancelButton.toolTip=inserting ? "停止确认，请检查输入框" : busy ? "取消本次语音，不填入文字" : "关闭";cancelButton.setAccessibilityLabel(cancelButton.toolTip)
        surface.toolTip=[title,recording ? recordingTime : "",notice ?? note].filter { !$0.isEmpty }.joined(separator:" · ")
        surface.setAccessibilityLabel(title+" · "+hint.stringValue);surface.menu?.items.first?.title=inserting ? "停止确认，请检查输入框" : busy ? "取消本次语音" : "关闭"
        header.setAccessibilityHelp(notice ?? note)
        preview.isHidden=true;copyButton.isHidden=true;settingsButton.isHidden=true
        present(NSSize(width:width,height:height),radius:16)
    }
    // Text and the next safe action are both visible; a tooltip is only supplementary.
    func showCard(_ title:String,_ body:String,hint note:String,detail:String?=nil) {
        onActivityChanged?()
        let kept=pending != nil,width:CGFloat=kept ? 340 : 380,p:CGFloat=16,inner=width-p*2
        preview.stringValue=body;preview.toolTip=body
        hint.stringValue=note;hint.toolTip=detail ?? note;hint.isHidden=note.isEmpty;EchoUI.wrapping(hint,lines:3)
        let text=EchoUI.fittingHeight(preview,width:inner),hintHeight=note.isEmpty ? 0 : EchoUI.fittingHeight(hint,width:inner)
        let height=p+22+12+text+(hintHeight>0 ? 12+hintHeight : 0)+p
        wave.isHidden=true;spinner.stopAnimation(nil);check.isHidden=true;stopButton.isHidden=true;elapsed.isHidden=true
        header.isHidden=false;header.font = .systemFont(ofSize:13,weight:.semibold);header.textColor = .labelColor
        header.stringValue=title;header.frame=NSRect(x:p,y:height-p-22,width:inner-116,height:22)
        preview.isHidden=false;preview.frame=NSRect(x:p,y:p+hintHeight+(hintHeight>0 ? 12 : 0),width:inner,height:text)
        hint.frame=NSRect(x:p,y:p,width:inner,height:hintHeight)
        cancelButton.isHidden=false;cancelButton.frame=NSRect(x:width-p-28,y:height-p-25,width:28,height:28)
        cancelButton.toolTip=kept ? "放弃这段文字（Esc）" : "关闭（Esc）"
        surface.setAccessibilityLabel(title);surface.menu?.items.first?.title=kept ? "放弃这段文字" : "关闭"
        settingsButton.isHidden=kept;settingsButton.title=gearURL == nil ? "设置" : "系统设置"
        let settingsWidth=settingsButton.intrinsicContentSize.width
        settingsButton.frame=NSRect(x:cancelButton.frame.minX-8-settingsWidth,y:height-p-25,width:settingsWidth,height:28)
        settingsButton.toolTip=gearURL == nil ? "APT 设置 › Agent 服务" : "系统设置 › 麦克风";settingsButton.setAccessibilityLabel(settingsButton.toolTip)
        copyButton.isHidden = !kept;copyButton.reset()
        copyButton.frame=NSRect(x:cancelButton.frame.minX-8-28,y:height-p-25,width:28,height:28)
        surface.toolTip=detail ?? note;header.setAccessibilityHelp(detail ?? note)
        present(NSSize(width:width,height:height),radius:16)
    }
    private func present(_ size:NSSize,radius:CGFloat) {
        surface.radius=radius; surface.needsDisplay=true
        var anchor=target?.voiceAnchor() ?? .zero
        if let frame=(NSScreen.screens.first(where:{$0.frame.intersects(anchor)}) ?? NSScreen.main)?.visibleFrame {
            if anchor == .zero { anchor=NSRect(x:frame.midX-size.width/2,y:frame.midY,width:1,height:1) }
            var y=anchor.minY-size.height-12
            if y<frame.minY { y=min(frame.maxY-size.height,anchor.maxY+12) }
            panel.setFrame(NSRect(x:min(max(anchor.minX,frame.minX),frame.maxX-size.width),y:y,width:size.width,height:size.height),display:true)
        } else { panel.setContentSize(size) }
        panel.orderFrontRegardless(); panel.invalidateShadow()
    }
    var recordingTitle:String { "正在听" }
    var recordingTime:String { let s=max(0,Int(Date().timeIntervalSince(started))); return "\(s/60):"+String(format:"%02d",s%60) }
    var recordingHint:String { !automaticInsertionAllowed ? (keptBecause == "field_unavailable" ? "结束后保留文字" : "位置变化 · 保留文字") : (heldSince != nil ? "松开结束" : "Return 结束") }
    // A message that ends this attempt closes after a while; cards with a transcript stay available.
    func conclude(_ title:String,_ body:String,hint note:String,gear:URL?=nil) {
        AU05Controller.shared.event(.voice,.failure)
        terminal=true; gearURL=gear; showCard(title,body,hint:note)
        let token=generation
        DispatchQueue.main.asyncAfter(deadline:.now()+autoHide) { [weak self] in if let self,self.generation == token,self.terminal { self.cancel() } }
    }
    func needsSetup(_ error:Error) { conclude("开始使用语音","在设置中配置语音 Key，即可开始说话。",hint:error.localizedDescription) }
    func microphoneDenied() { conclude("允许麦克风","在系统设置中允许 APT 使用麦克风。",hint:"隐私与安全性 › 麦克风",gear:Self.microphoneSettings) }
    func noSpeech() { recording=false; cleanupAudio(); conclude("没有听到声音","检查麦克风后，再按快捷键说一次。",hint:"按 \(VoiceBinding.label) 重新录音") }
    private func interrupted() { recording=false; cleanupAudio(); conclude("麦克风中断","录音意外停止，请检查麦克风连接后重试。",hint:"按 \(VoiceBinding.label) 重新录音") }
    func failed(_ error:Error,audio:Data) {
        processing=false; polishing=false; task=nil
        let wave=VoiceWave(audio)
        MemoryLog.shared.voice(VoiceRecognitionFailure(app:originApp ?? target?.voiceApp,model:VoiceASR.model,error:error.localizedDescription,audio_bytes:audio.count,audio:wave?.stats,start_ms:startMs,ready_ms:readyMs,sound_ms:soundMs))
        if case VoiceFailure.emptyTranscript = error,wave?.stats.peak_db == -160 {
            recorderPool.discard()
            conclude("录音没有声音","这段录音的声音数据为空。请检查当前输入麦克风的连接，再重新录音。",hint:"按 \(VoiceBinding.label) 重新录音"); return
        }
        let message=error.localizedDescription, setup=["HTTP 401","HTTP 403","Key","语音配置"].contains { message.contains($0) }
        conclude("识别失败",message,hint:setup ? "打开设置" : "按 \(VoiceBinding.label) 重新录音")
    }

    // Consume the ending key so the host app cannot also submit its message.
    // Holding Return through recognition must not leak repeated Return events.
    func handleEndingKey(_ event:NSEvent)->Bool {
        guard event.type == .keyDown,[UInt16(kVK_Return),UInt16(kVK_ANSI_KeypadEnter)].contains(event.keyCode),event.modifierFlags.intersection([.command,.control,.shift,.option]).isEmpty else { return false }
        if event.isARepeat && endedWithReturn { return true }
        if recording { endedWithReturn=true; if !event.isARepeat { stop() }; return true }
        if preparing || processing || inserting { return true }
        endedWithReturn=false; return false
    }
    // True when Esc was for voice. Polishing is skipped rather than cancelled, so the spoken words still arrive.
    func handleEscape()->Bool {
        if polishing,let transcript {
            generation=UUID(); task?.cancel()
            run?.cleanup = .init(model:ModelConfig.modelName,prompt:VoicePolisher.promptVersion,ms:MemoryTrace.ms(since:polishStarted),text:nil,error:"skipped",used:false)
            processing=false; polishing=false; inserting=true; showStatus()
            let token=generation
            task=Task { @MainActor in
                guard self.generation == token,!Task.isCancelled else { return }
                await self.complete(transcript,notice:"已跳过整理")
            }; return true
        }
        if busy || pending != nil || terminal { dismiss(); return true }
        return false
    }

    // The voice key, as a tap or a hold. A tap works as before (hands-free; a pause or another press ends it).
    // Holding it is push-to-talk: letting go ends the recording, and a pause meanwhile does not.
    static let holdThreshold:TimeInterval=0.35
    private func keyEventTime(_ timestamp:TimeInterval?)->TimeInterval {
        let now=keyClock()
        guard let timestamp,timestamp.isFinite,timestamp>0,timestamp<=now+1 else { return now }
        return timestamp
    }
    func keyDown(_ owner:VoiceTarget?,at timestamp:TimeInterval?=nil) {
        if heldSince != nil,recording || preparing { return }  // key repeat while held
        if recording { stop(); return }  // ending a take does not require an active input field
        guard !busy else { return }
        guard let owner else { fillTargetUnavailable(); return }
        let pressed=keyEventTime(timestamp), shortcut=EchoShortcutSlot.voice.current
        toggle(owner)
        if recording || preparing {
            heldSince=pressed; heldShortcut=shortcut; heldKeyWasDown=voiceKeyIsDown(shortcut); showStatus()
        }
    }
    func keyUp(at timestamp:TimeInterval?=nil) {
        guard let since=heldSince else { return }
        let released=keyEventTime(timestamp)
        guard released>=since else { return }  // queued release from an earlier press
        heldSince=nil; heldShortcut=nil; heldKeyWasDown=false
        if preparing && !recording,released-since >= Self.holdThreshold { cancel(); return }
        guard recording else { return }
        guard released-since >= Self.holdThreshold else { showStatus(); return }  // a tap: keep listening
        if pauseDetector?.heardSpeech == false { noSpeech() } else { stop() }  // silent hold: nothing is sent
    }
    // AU05's chord release may reach Quartz without an IMK/Carbon key-up. Repair that state while
    // listening, including when the original input field is no longer active. Real held repeats stay ignored.
    func observeVoiceKeyRelease() {
        guard heldSince != nil else { return }
        if voiceKeyIsDown(heldShortcut ?? EchoShortcutSlot.voice.current) { heldKeyWasDown=true; return }
        // Carbon hotkeys can stay "up" in Quartz throughout a real hold. An unconfirmed snapshot
        // cannot substitute for a release event; recover only a down -> up transition we actually saw.
        guard heldKeyWasDown else { return }
        keyUp()
    }
    func observeVoiceModifiers(_ flags:NSEvent.ModifierFlags,at timestamp:TimeInterval?=nil) {
        guard let since=heldSince else { return }
        if let timestamp,(!timestamp.isFinite || timestamp<=0 || timestamp>keyClock()+1),!heldKeyWasDown { return }
        let changed=keyEventTime(timestamp)
        guard changed>=since else { return }  // modifier-down events queued before the shortcut press
        let shortcut=heldShortcut ?? EchoShortcutSlot.voice.current
        if flags.intersection(shortcut.flags) != shortcut.flags { keyUp(at:changed) }
    }
    func toggle(_ owner:VoiceTarget) {
        if recording { stop(); return }
        if busy { return }
        if fillPending(owner) { return }
        if let recordingStarter { recordingStarter(owner) } else { begin(owner) }
    }
    // Both the voice key and the external fill/memory key insert kept dictation first.
    // Consume repeats during the asynchronous readback; never send the same pending text twice.
    @discardableResult func fillPending(_ owner:VoiceTarget)->Bool {
        guard pending != nil else { return false }
        if busy { return true }
        if let pending {
            guard owner.acceptsVoice,let position=owner.voicePosition() else {
                if let id=run?.run_id { MemoryLog.shared.voice(VoiceOutcome(run_id:id,kind:"fill_refused")) }
                EchoHint.shared.show(owner.voiceRefusal(),near:owner.voiceAnchor()); return true
            }
            target=owner; self.position=position; inserted=false; inserting=true; showStatus()
            let token=generation
            task=Task { @MainActor in
                guard self.generation == token,!Task.isCancelled else { return }
                let result=await owner.insertVoice(pending,position:position)
                guard self.generation == token,!Task.isCancelled else { return }
                self.inserting=false; self.task=nil
                if result == .confirmed {
                    self.polishHistory.remember(pending,for:owner)
                    if let id=self.run?.run_id { MemoryLog.shared.voice(VoiceOutcome(run_id:id,kind:"filled")); VoiceEdits.shared.watch(run:id,app:owner.voiceApp,text:pending,location:position.selection.location) }
                    self.showInserted()
                } else {
                    if let id=self.run?.run_id { MemoryLog.shared.voice(VoiceOutcome(run_id:id,kind:result == .unconfirmed ? "fill_unconfirmed" : "fill_failed")) }
                    self.keep(pending,unconfirmed:result == .unconfirmed)
                }
            }
            return true
        }
        return false
    }
    func fillTargetUnavailable() {
        guard pending != nil else { return }
        if let id=run?.run_id { MemoryLog.shared.voice(VoiceOutcome(run_id:id,kind:"fill_no_active_target")) }
    }
    // The microphone starts first: people speak as they press the key, and anything said before the recorder runs
    // is lost. Only the quick checks come before it (password fields, terminals, Echo's own windows); reading the
    // caret from the app and the Key from the keychain follow. An unreadable caret needs a bound IMK
    // session for automatic insertion; a disallowed selection or a missing Key drops the recording unsent.
    func begin(_ owner:VoiceTarget) {
        let pressed=Date()
        guard !busy else { return }
        guard owner.acceptsVoice else { EchoHint.shared.show(owner.voiceRefusal(),near:owner.voiceAnchor()); return }
        cancel(); automaticInsertionAllowed=true; target=owner; pressedAt=pressed; let token=generation
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized: startRecorder()
        case .notDetermined:
            preparing=true; showStatus()
            AVCaptureDevice.requestAccess(for:.audio) { allowed in DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.preparing=false
                if allowed { self.startRecorder() } else { self.microphoneDenied() }
            } }
        default: microphoneDenied(); return
        }
        guard let position=owner.voicePosition() else { cancel(); EchoHint.shared.show(owner.voiceRefusal(),near:owner.voiceAnchor()); return }
        capturePosition(position)
        Task { @MainActor [weak self] in
            do { _ = try await Task.detached { try VoiceASR.readKey() }.value }
            catch { guard let self,self.generation == token,self.recording || self.preparing else { return }; self.cancel(); self.needsSetup(error) }
        }
    }
    func capturePosition(_ position:VoicePosition) {
        self.position=position
        if let target { polishContext=polishHistory.context(for:target,prefix:position.prefix) }
        originIdentity=target?.voiceIdentity; originApp=target?.voiceApp; originFocusStamp=target?.voiceFocusStamp; originAnchor=target?.voiceAnchor() ?? .zero; mayResume=false
        automaticInsertionAllowed = !position.requiresConfirmation || matchesOriginalPosition()
        keptBecause = automaticInsertionAllowed ? nil : "field_unavailable"
        if recording { showStatus() }
    }
    private func matchesOriginalPosition()->Bool {
        guard let target,target.acceptsVoice,let position,target.voicePosition() == position else { return false }
        guard position.requiresConfirmation else { return true }
        guard let identity=originIdentity,!identity.isEmpty,let stamp=originFocusStamp,!stamp.isEmpty else { return false }
        return target.voiceIdentity == identity && target.voiceFocusStamp == stamp && target.voiceAnchor() == originAnchor
    }
    private func startRecorder() {
        do {
            let prepared=try recorderPool.take(); file=prepared.file; recorder=prepared.device; recorder?.delegate=self
            guard recorder?.record() == true else { throw VoiceFailure.message("无法开始录音，请连接可用麦克风。") }
            wave.power = -160; started=Date(); pauseDetector=VoicePauseDetector(started:started.timeIntervalSinceReferenceDate)
            startMs=pressedAt.map { MemoryTrace.ms(since:$0) }; soundMs=nil; readyMs=nil; awaitingSamples=true
            recording=true; showStatus()
            clock=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { [weak self] _ in self?.tick() }
        } catch { recording=false; cleanupAudio(); conclude("无法录音",error.localizedDescription,hint:"检查麦克风后按 \(VoiceBinding.label) 重试") }
    }
    func prepareRecorder(_ owner:VoiceTarget) {
        guard !busy,owner.acceptsVoice,AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { return }
        recorderPool.prepare()
    }
    func tick() {
        observeVoiceKeyRelease()
        guard recording else { return }
        if awaitingSamples {
            guard (recorder?.currentTime ?? 0) > 0 else {
                if Date().timeIntervalSince(started)>3 { interrupted() }
                return
            }
            awaitingSamples=false; readyMs=pressedAt.map { MemoryTrace.ms(since:$0) }; readyCue()
            AU05Controller.shared.event(.voice,.listening)
            pauseDetector=VoicePauseDetector(started:Date().timeIntervalSinceReferenceDate)
            clock?.invalidate(); clock=Timer.scheduledTimer(withTimeInterval:0.15,repeats:true) { [weak self] _ in self?.tick() }; showStatus()
        }
        // Another field, caret or app no longer cancels: keep recording, then keep the text for explicit insertion.
        if automaticInsertionAllowed,!matchesOriginalPosition() { automaticInsertionAllowed=false; keptBecause=Self.why(target,position) }
        recorder?.updateMeters(); let power=recorder?.averagePower(forChannel:0) ?? -160
        if soundMs == nil,power > -120 { soundMs=MemoryTrace.ms(since:started) }  // the floor is -160 until samples arrive
        let action=pauseDetector?.sample(power,at:Date().timeIntervalSinceReferenceDate,automatic:Self.automaticEnd && heldSince == nil)
        header.stringValue=recordingTitle; elapsed.stringValue=recordingTime; hint.stringValue=recordingHint; hint.toolTip=recordingHint
        surface.toolTip=recordingTitle+" · "+recordingTime+" · "+recordingHint+" · Esc 取消／右键菜单"; wave.phase += 0.3; wave.power=power
        if action == .finish || Date().timeIntervalSince(started)>=90 { stop(); return }
        if action == .noSpeech { noSpeech() }
    }
    @objc func stop() {
        heldSince=nil; heldShortcut=nil; heldKeyWasDown=false; guard recording else { return }
        let duration=Date().timeIntervalSince(started); recording=false; clock?.invalidate(); clock=nil; recorder?.stop(); recorder=nil
        guard duration>=0.3,let file else { cancel(); return }
        do { let audio=try Data(contentsOf:file); cleanupAudio(); send(audio) }
        catch { cleanupAudio(); conclude("录音读取失败",error.localizedDescription,hint:"按 \(VoiceBinding.label) 重新录音") }
    }
    private func send(_ audio:Data) {
        AU05Controller.shared.event(.voice,.working)
        processing=true; terminal=false; gearURL=nil; showStatus()
        let token=generation, runID=UUID().uuidString, shouldPolish=Self.polishEnabled, model=VoiceASR.model, route=VoiceASR.route, language=UserDefaults.standard.string(forKey:"stepVoiceLanguage") ?? "auto", hotwords=VoiceTerms.all
        task=Task { @MainActor [weak self] in
            guard let self else { return }
            let heardAt=Date()
            do {
                let text:String
                if let transcriber=self.transcriber { text=try await transcriber(audio) }
                else {
                    text=try await AgentModels.asr(audio:audio,key:StepVoiceKey.read(),language:language,hotwords:StepASR.hotwordsRefused ? [] : hotwords,route:route)
                }
                guard self.generation == token else { return }
                try Task.checkCancellation()
                self.run=VoiceRun(run_id:runID,app:self.target?.voiceApp,asr:.init(model:model,ms:MemoryTrace.ms(since:heardAt),text:text,hotwords:StepASR.hotwordsRefused ? 0 : hotwords.count,endpoint:route.endpoint.absoluteString),start_ms:self.startMs,sound_ms:self.soundMs,ready_ms:self.readyMs)
                await self.finishTranscript(text,polish:shouldPolish,token:token)
            } catch {
                guard self.generation == token else { return }
                self.failed(error,audio:audio)
            }
        }
    }
    @MainActor func finishTranscript(_ raw:String,polish enabled:Bool,token:UUID) async {
        guard generation == token,!Task.isCancelled else { return }
        var result=raw, notice:String?
        if enabled {
            polishing=true; transcript=raw; showStatus()
            let started=Date(); polishStarted=started
            do {
                if let polisher { result=try await polisher(raw) }
                else { result=try await VoicePolisher().polish(raw,context:polishContext) }
                try Task.checkCancellation()
                run?.cleanup = .init(model:ModelConfig.modelName,prompt:VoicePolisher.promptVersion,ms:MemoryTrace.ms(since:started),text:result,error:nil,used:true)
            } catch {
                guard generation == token,!Task.isCancelled else { return }
                notice=error is MemoryKeyAuthorization ? "文字模型未授权，见 APT 设置 › Agent 服务" : (error as? VoiceFailure)?.errorDescription ?? "整理未完成，已用原始转写"
                run?.cleanup = .init(model:ModelConfig.modelName,prompt:VoicePolisher.promptVersion,ms:MemoryTrace.ms(since:started),text:nil,error:error.localizedDescription,used:false)
            }
        }
        guard generation == token,!Task.isCancelled else { return }
        await complete(result,notice:notice)
    }
    @MainActor func complete(_ text:String,notice:String?=nil) async {
        guard !Task.isCancelled else { return }
        if mayResume,let owner=EchoInputController.current { resume(owner) }
        processing=false; polishing=false; transcript=nil
        inserted=false
        let token=generation
        var result:VoiceInsertionResult = .failed
        if automaticInsertionAllowed,let target,let position,matchesOriginalPosition() {
            inserting=true; showStatus()
            result=await target.insertVoice(text,position:position)
            guard generation == token,!Task.isCancelled else { return }
        }
        inserting=false; task=nil
        let filled=result == .confirmed
        if var record=run {
            record.result=text; record.outcome=filled ? "inserted" : "kept"
            record.kept_because=filled ? nil : keptBecause ?? (result == .unconfirmed ? "insert_unconfirmed" : Self.why(target,position)); run=record; MemoryLog.shared.voice(record)
            if filled,let position { VoiceEdits.shared.watch(run:record.run_id,app:record.app,text:text,location:position.selection.location) }
        }
        if filled { if let target { polishHistory.remember(text,for:target) }; showInserted(notice:notice) }
        else { keep(text,unconfirmed:result == .unconfirmed,notice:notice) }
    }
    private func showInserted(notice:String?=nil) {
        AU05Controller.shared.event(.voice,.success)
        pending=nil; inserted=true; terminal=false; showStatus(notice:notice)
        let token=generation; DispatchQueue.main.asyncAfter(deadline:.now()+0.9) { [weak self] in if let self,self.generation == token,self.inserted { self.inserted=false; self.panel.orderOut(nil) } }
    }
    static func keptHint(unconfirmed:Bool,notice:String?=nil)->String {
        let next=unconfirmed ? "先检查输入框，确认未填入再按 \(VoiceBinding.label)" : "回到输入框，按 \(VoiceBinding.label) 填入"
        return next+(notice.map { "\n"+$0 } ?? "")
    }
    private func keep(_ text:String,unconfirmed:Bool,notice:String?=nil) {
        pending=text; inserted=false; AU05Controller.shared.event(.voice,.waiting)
        let next=Self.keptHint(unconfirmed:unconfirmed,notice:notice)
        showCard(unconfirmed ? "未确认填入" : "文字已保留",text,hint:next,detail:next)
    }
    // The IME left this field. Recording goes on; the text is then kept for explicit insertion.
    func suspend(_ owner:VoiceTarget,sameApplication:Bool=false) {
        recorderPool.discard()
        if target === owner {
            mayResume = automaticInsertionAllowed && !inserting && sameApplication && originIdentity != nil && originAnchor.height>0 && position?.requiresConfirmation == false
            if automaticInsertionAllowed { keptBecause="left_field" }; automaticInsertionAllowed=false
        }
    }
    // A client can deactivate while its app refreshes the input view. Restore only the same logical
    // field, text, caret and on-screen anchor, with no intervening app switch or user focus movement.
    func resume(_ owner:VoiceTarget) {
        guard mayResume,busy,!inserting,owner.acceptsVoice else { return }
        guard owner.voiceApp == originApp,owner.voiceIdentity == originIdentity,owner.voicePosition() == position else { mayResume=false; return }
        let anchor=owner.voiceAnchor()
        guard abs(anchor.minX-originAnchor.minX)<=2,abs(anchor.minY-originAnchor.minY)<=2,abs(anchor.height-originAnchor.height)<=2 else { mayResume=false; return }
        target=owner; automaticInsertionAllowed=true; keptBecause=nil; mayResume=false
        if recording { showStatus() }
    }
    func userMoved(_ owner:VoiceTarget) {
        polishHistory.clear()
        if target === owner || (busy && owner.voiceApp == originApp) { mayResume=false; automaticInsertionAllowed=false; keptBecause="left_field" }
    }
    func observeAppChanges() {
        guard appObserver == nil else { return }
        appObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] note in
            guard let self,let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,app.bundleIdentifier != self.originApp else { return }
            self.polishHistory.clear()
            guard self.busy else { return }
            self.mayResume=false; self.automaticInsertionAllowed=false; self.keptBecause="left_field"
        }
    }
    deinit { if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) } }
    // Which check stopped a dictation from filling in by itself, for its record.
    static func why(_ target:VoiceTarget?,_ position:VoicePosition?)->String {
        guard let target,target.acceptsVoice,let now=target.voicePosition(),let position else { return "field_unavailable" }
        if now.requiresConfirmation || position.requiresConfirmation { return "field_unavailable" }
        if now.selection.location != position.selection.location { return "caret_moved" }
        if now.prefix != position.prefix { return "text_changed" }
        return now.selected != position.selected || now.selection != position.selection ? "selection_changed" : "insert_failed"
    }
    @objc func cancel() {
        AU05Controller.shared.event(.voice,.idle)
        generation=UUID(); task?.cancel(); task=nil; cleanupAudio(); recording=false; preparing=false; processing=false; polishing=false; inserting=false
        heldSince=nil; heldShortcut=nil; heldKeyWasDown=false; inserted=false; terminal=false; pending=nil; transcript=nil; gearURL=nil; position=nil; target=nil; endedWithReturn=false; run=nil; keptBecause=nil; pressedAt=nil; startMs=nil; soundMs=nil; readyMs=nil; awaitingSamples=false
        originIdentity=nil; originApp=nil; originFocusStamp=nil; originAnchor = .zero; mayResume=false
        polishContext=VoicePolishContext()
        spinner.stopAnimation(nil); panel.orderOut(nil)
        onActivityChanged?()
    }
    private func cleanupAudio() {
        awaitingSamples=false
        clock?.invalidate(); clock=nil; pauseDetector=nil
        recorder?.delegate=nil; recorder?.stop(); recorder=nil
        if let file { try? FileManager.default.removeItem(at:file) }; file=nil
        if let owner=EchoInputController.current { prepareRecorder(owner) }
    }
    @objc func copyText() {
        guard let pending else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pending,forType:.string); copyButton.showCopied()
        if let id=run?.run_id { MemoryLog.shared.voice(VoiceOutcome(run_id:id,kind:"copied")) }
    }
    // Closed by the user (×, Esc): kept text that was never filled in is recorded as discarded.
    @objc func dismiss() {
        if pending != nil,let id=run?.run_id { MemoryLog.shared.voice(VoiceOutcome(run_id:id,kind:"discarded")) }
        cancel()
    }
    @objc func openSettings() { if let gearURL { NSWorkspace.shared.open(gearURL) } else { EchoSettings.shared.show(.model) } }
    func audioRecorderEncodeErrorDidOccur(_ recorder:AVAudioRecorder,error:Error?) { if recording { interrupted() } }
    // A recorder that stopped on its own still holds what was said; send it.
    func audioRecorderDidFinishRecording(_ recorder:AVAudioRecorder,successfully flag:Bool) { if recording { flag ? stop() : interrupted() } }
}

extension EchoInputController:VoiceTarget {
    var acceptsVoice:Bool { acceptsMemory && !IsSecureEventInputEnabled() && inputClient?.bundleIdentifier().map(InputMemoryRecorder.allowedApp) == true }
    func voicePosition()->VoicePosition? {
        guard acceptsVoice,let client=inputClient else { return nil }
        return VoicePosition.capture(selection:client.selectedRange()) { client.attributedSubstring(from:$0)?.string }
    }
    func voiceAnchor()->NSRect { memoryAnchor() }
    var voiceApp:String? { inputClient?.bundleIdentifier() }
    var voiceIdentity:String? { inputClient?.uniqueClientIdentifierString() }
    var voiceFocusStamp:String? { active ? voiceContext.uuidString : nil }
    @MainActor func insertVoice(_ text:String,position:VoicePosition) async -> VoiceInsertionResult {
        guard voicePosition() == position,let client=inputClient else { return .failed }
        let context=voiceContext
        let result=await VoiceInsertion.perform(text,position:position,current:{ self.voicePosition() },
            isCurrent:{ self.voiceContext == context && self.inputClient === client && self.acceptsVoice },
            insert:{ range in InputMemoryRecorder.shared.markVoice(self,text); client.insertText(text,replacementRange:range) },
            substring:{ client.attributedSubstring(from:$0)?.string })
        // Dictation is authored input, so capture it without suppressGenerated.
        if result != .failed { DispatchQueue.main.async { [weak self] in if let self,self.voiceContext == context { InputMemoryRecorder.shared.markEdit(self); InputMemoryRecorder.shared.poll() } } }
        return result
    }
    func voiceRefusal()->String {
        let app=inputClient?.bundleIdentifier() ?? ""
        if IsSecureEventInputEnabled() { return "密码输入时不能使用语音" }
        if app.hasPrefix("local.echo.") { return "APT 自己的窗口里不能使用语音" }
        if !InputMemoryRecorder.allowedApp(app) { return "终端和密码类应用不支持语音" }
        if acceptsMemory,voicePosition() == nil { return "选中的文字太长，最多 16000 字" }
        return "先点一下要输入的位置"
    }
    // held: from the voice key, whose release may end a push-to-talk recording; menu clicks are taps.
    func triggerVoice(held:Bool=false,at timestamp:TimeInterval?=nil) {
        guard active else { return }; ERCommit(session); updateRime(); panel?.hide(); MemoryInline.shared.close()
        held ? VoiceInput.shared.keyDown(self,at:timestamp) : VoiceInput.shared.toggle(self)
    }
}

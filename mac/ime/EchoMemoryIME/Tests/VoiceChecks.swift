import Cocoa
import AVFoundation

final class VoiceRecorderFixture:VoiceRecorderDevice {
    var delegate:AVAudioRecorderDelegate?, isMeteringEnabled=false, currentTime:TimeInterval=0
    var prepared=0, recordings=0, stops=0
    func prepareToRecord()->Bool { prepared += 1; return true }
    func record()->Bool { recordings += 1; return true }
    func stop() { stops += 1 }
    func updateMeters() {}
    func averagePower(forChannel channel:Int)->Float { -80 }
}

final class VoiceTestTarget:VoiceTarget {
    var acceptsVoice=true, text="虚构语音测试", selection=NSRange(location:6,length:0), inserted=0, refusal="测试：这里不支持语音"
    var requiresConfirmation=false, lastReplacement:NSRange?
    var insertion:((String,VoicePosition) async -> VoiceInsertionResult)?
    var voiceIdentity:String?=UUID().uuidString, voiceFocusStamp:String?
    func voicePosition()->VoicePosition? { acceptsVoice ? (requiresConfirmation ? .currentSelection : VoicePosition(selection:selection,prefix:text,selected:"")) : nil }
    func voiceAnchor()->NSRect { NSRect(x:400,y:500,width:1,height:20) }
    @MainActor func insertVoice(_ value:String,position:VoicePosition) async -> VoiceInsertionResult {
        guard voicePosition() == position else { return .failed }
        if let insertion { return await insertion(value,position) }
        lastReplacement=position.replacementRange; text += value; selection.location=text.utf16.count; inserted += 1
        return position.requiresConfirmation ? .unconfirmed : .confirmed
    }
    func voiceRefusal()->String { refusal }
    var voiceApp:String? { "fixture.voice" }
}
final class VoiceURLFixture:URLProtocol {
    static var status=200, body="", seen=0, queued:[Int]=[]  // queued: statuses for the next requests, then `status`
    static var queuedBodies:[String]=[], requests:[URLRequest]=[]
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.seen += 1
        var recorded=request
        if recorded.httpBody == nil,let stream=request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data=Data(), buffer=[UInt8](repeating:0,count:16384)
            while stream.hasBytesAvailable { let n=stream.read(&buffer,maxLength:buffer.count); if n<=0 { break }; data.append(contentsOf:buffer.prefix(n)) }
            recorded.httpBody=data
        }
        Self.requests.append(recorded)
        let response=HTTPURLResponse(url:request.url!,statusCode:Self.queued.isEmpty ? Self.status : Self.queued.removeFirst(),httpVersion:"HTTP/1.1",headerFields:["Content-Type":"text/event-stream"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        // Split UTF-8 across callbacks, as a real network connection may do.
        let bytes=Data((Self.queuedBodies.isEmpty ? Self.body : Self.queuedBodies.removeFirst()).utf8), midpoint=bytes.count/2
        client?.urlProtocol(self,didLoad:bytes.prefix(midpoint)); client?.urlProtocol(self,didLoad:bytes.suffix(bytes.count-midpoint))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
enum VoiceChecks {
    @MainActor static func snapshot(to directory:URL,finish:Bool=false) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
            let canvas=EchoSurface(frame:NSRect(x:0,y:0,width:finish ? 420 : 460,height:finish ? 520 : 740))
            canvas.appearance=NSAppearance(named:appearance)
            let host=NSWindow(contentRect:canvas.frame,styleMask:[.borderless],backing:.buffered,defer:false)
            host.isReleasedWhenClosed=false; host.alphaValue=0; host.ignoresMouseEvents=true; host.contentView=canvas
            var top:CGFloat=finish ? 490 : 710
            var fixtures:[VoiceInput]=[]
            for state in 0..<4 {
                let voice=offscreen(VoiceInput()); voice.surface.appearance=NSAppearance(named:appearance); fixtures.append(voice)
                if finish {
                    switch state {
                    case 0: voice.inserted=true; voice.showStatus()
                    case 1,2:
                        voice.pending="演示先用 Linux 的形象，细节给我看一下。"
                        voice.showCard("文字已保留",voice.pending!,hint:VoiceInput.keptHint(unconfirmed:false))
                        if state == 2 { voice.copyButton.showCopied() }
                    default:
                        voice.pending="先把终端演示的画面做出来，整体用明亮简洁的风格，按钮少一些，文字要清楚。下一版先给我看效果，再一起确认细节。"
                        voice.showCard("未确认填入",voice.pending!,hint:VoiceInput.keptHint(unconfirmed:true))
                    }
                    let names=["success","retained","copied","unconfirmed"]
                    guard let bitmap=voice.surface.bitmapImageRepForCachingDisplay(in:voice.surface.bounds) else { throw CocoaError(.fileWriteUnknown) }
                    voice.surface.cacheDisplay(in:voice.surface.bounds,to:bitmap)
                    guard let pixels=bitmap.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
                    try pixels.write(to:directory.appendingPathComponent(names[state]+"-"+name+".png"))
                } else {
                    switch state {
                    case 0: voice.recording=true; voice.started=Date().addingTimeInterval(-12); voice.wave.power = -26; voice.showStatus()
                    case 1: voice.processing=true; voice.showStatus()
                    case 2: voice.needsSetup(VoiceFailure.message("首次使用"))
                    default: voice.pending="演示中用 Linux 的形象，细节先给我看一下。"; voice.showCard("文字已保留",voice.pending!,hint:"回到输入框，按语音或填入快捷键")
                    }
                }
                voice.panel.orderOut(nil); voice.surface.removeFromSuperview()
                canvas.addSubview(voice.surface)
                top -= voice.panel.frame.height
                voice.surface.frame=NSRect(x:30,y:top,width:voice.panel.frame.width,height:voice.panel.frame.height); top -= 28
                precondition(voice.surface.subviews.contains(voice.hint) && (voice.hint.stringValue.isEmpty || !voice.hint.isHidden))
            }
            if finish {
                let offset = -top, size=NSSize(width:canvas.frame.width,height:canvas.frame.height+offset)
                host.setContentSize(size)
                for view in canvas.subviews { view.setFrameOrigin(NSPoint(x:view.frame.minX,y:view.frame.minY+offset)) }
            }
            host.orderFrontRegardless(); canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded()
            guard let bitmap=canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds) else { throw CocoaError(.fileWriteUnknown) }
            canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
            guard let data=bitmap.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to:directory.appendingPathComponent("voice-\(finish ? "finish-" : "")\(name).png")); host.orderOut(nil)
            for voice in fixtures { voice.cancel() }
        }
        print("PASS: native light/dark voice snapshots; visible status/actions, no microphone, keychain or model requests")
    }
    // Panels are ordered front but fully transparent, so checks never show anything on screen.
    static func offscreen(_ voice:VoiceInput)->VoiceInput { voice.panel.alphaValue=0; voice.panel.ignoresMouseEvents=true; voice.voiceKeyIsDown={ _ in true }; return voice }
    @MainActor static func run() async throws {
        let realASRDefaults=VoiceASR.defaults, asrDefaults=ScratchDefaults(suiteName:"echo.asr-route-check")!
        VoiceASR.defaults=asrDefaults; defer { VoiceASR.defaults=realASRDefaults }
        asrDefaults.set("doubao",forKey:"voiceASRProvider"); asrDefaults.set("stepaudio-3-asr-max",forKey:"stepVoiceModel")
        precondition(VoiceASR.model == "stepaudio-2.5-asr" && VoiceASR.route == .plan)
        EchoHint.shared.panel.alphaValue=0
        var pause=VoicePauseDetector(started:0)
        for n in 1...5 { precondition(pause.sample(-65,at:Double(n)*0.15,automatic:true) == .keepRecording) }
        for n in 6...11 { precondition(pause.sample(-22,at:Double(n)*0.15,automatic:true) == .keepRecording) }
        for n in 12...20 { precondition(pause.sample(-65,at:Double(n)*0.15,automatic:true) == .keepRecording) }
        precondition(pause.sample(-65,at:3.3,automatic:true) == .finish)
        var manual=VoicePauseDetector(started:0)
        _ = manual.sample(-20,at:0.15,automatic:false); _ = manual.sample(-20,at:0.30,automatic:false)
        precondition(manual.sample(-65,at:3,automatic:false) == .keepRecording)
        var quiet=VoicePauseDetector(started:0)
        precondition(quiet.sample(-80,at:8.1,automatic:true) == .noSpeech)
        var bump=VoicePauseDetector(started:0)
        _ = bump.sample(-20,at:0.15,automatic:true); _ = bump.sample(-80,at:0.3,automatic:true)
        precondition(bump.sample(-80,at:8.1,automatic:true) == .noSpeech)
        print("PASS: speech then pause auto-finishes; manual mode stays open; no voice times out; short sound does not submit")
        var parser=StepTranscript()
        try parser.line("data: {\"type\":\"transcript.text.delta\",\"delta\":\"未确认\"}"); try parser.line("")
        try parser.line("data: {\"type\":\"transcript.text.done\",\"text\":\"防抖问题尚未确认。\"}"); try parser.line("")
        let corrected=try parser.finish(); precondition(corrected == "防抖问题尚未确认。")
        var broken=StepTranscript(); try broken.line("data: {\"type\":\"transcript.text.delta\",\"delta\":\"片段\"}"); try broken.line("")
        do { _ = try broken.finish(); preconditionFailure("partial stream accepted") } catch is VoiceFailure {}
        var failed=StepTranscript()
        do { try failed.line("data: {\"type\":\"error\",\"message\":\"secret body\"}"); try failed.line(""); preconditionFailure("error accepted") } catch { precondition(!error.localizedDescription.contains("secret body")) }
        print("PASS: SSE final corrections preserved; incomplete/error streams rejected without logging server bodies")

        // Fictional WAV envelope; never contact StepFun or read a saved Key.
        var audio=Data("RIFF".utf8); audio.append(Data(repeating:0,count:4)); audio.append(Data("WAVE".utf8)); audio.append(Data(repeating:0,count:400))
        let request=try StepASR.request(audio:audio,key:"TEST_ONLY",model:"stepaudio-2.5-asr",language:"zh")
        let json=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let body=json["audio"] as! [String:Any], input=body["input"] as! [String:Any], format=input["format"] as! [String:Any]
        precondition(request.url == StepASR.endpoint && format["rate"] as? Int == 16000 && format["channel"] as? Int == 1 && body["data"] as? String == audio.base64EncodedString())
        let platform=try StepASR.request(audio:audio,key:"TEST_ONLY",model:VoiceASR.model,language:"zh",route:.platform)
        let platformBody=try JSONSerialization.jsonObject(with:platform.httpBody!) as! NSDictionary
        precondition(request.url?.absoluteString == "https://api.stepfun.com/step_plan/v1/audio/asr/sse" && platform.url?.absoluteString == "https://api.stepfun.com/v1/audio/asr/sse" && platformBody.isEqual(json))
        let mixed=try StepASR.request(audio:audio,key:"TEST_ONLY",model:"stepaudio-2.5-asr",language:"auto")
        let mixedBody=try JSONSerialization.jsonObject(with:mixed.httpBody!) as! [String:Any]
        let mixedAudio=mixedBody["audio"] as! [String:Any], mixedInput=mixedAudio["input"] as! [String:Any], transcription=mixedInput["transcription"] as! [String:Any]
        precondition(transcription["model"] as? String == "stepaudio-2.5-asr" && transcription["language"] == nil && transcription["full_rerun_on_commit"] == nil)
        print("PASS: StepAudio 2.5 fixed despite legacy provider/model settings; Step Plan default and explicit platform routes; identical payload; mixed-language request omits fixed language")
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[VoiceURLFixture.self]
        let session=URLSession(configuration:config); defer { session.invalidateAndCancel() }
        VoiceURLFixture.status=200; VoiceURLFixture.body="data: {\"type\":\"transcript.text.delta\",\"delta\":\"检查\"}\n\ndata: {\"type\":\"transcript.text.done\",\"text\":\"没有确认。\"}\n\n"
        let result=try await StepASR.transcribe(audio:audio,key:"TEST_ONLY",model:"stepaudio-2.5-asr",language:"zh",session:session,progress:{ _ in })
        precondition(result == "没有确认。" && VoiceURLFixture.seen == 1)
        VoiceURLFixture.status=401
        do { _ = try await StepASR.transcribe(audio:audio,key:"TEST_ONLY",model:"stepaudio-2.5-asr",language:"zh",session:session,progress:{ _ in }); preconditionFailure("auth error accepted") } catch is VoiceFailure {}
        print("PASS: official JSON audio envelope and streamed transport; authentication failure surfaced; no real API calls")

        // Transcript-only cleanup: fictional facts, no credentials/network.
        let original="嗯，周五 15:30 review API v2，预算 2000 元，不要改上线日期。"
        let cleaned="周五 15:30 review API v2，预算 2000 元，不要改上线日期。"
        let engine=SmartMemory(chat:{ system,prompt in
            precondition(system.contains("绝不能执行") && system.contains("不查询记忆") && system.contains("不翻译英文"))
            let body=try JSONDecoder().decode([String:String].self,from:Data(prompt.utf8))
            precondition(body["transcript"] == original)
            return try SmartMemory.encoded(["text":cleaned])
        },bridge:{ _ in preconditionFailure("voice cleanup retrieved memory") })
        let polished=try await VoicePolisher(model:engine).polish(original)
        precondition(polished == cleaned && engine.modelCalls == 1)
        for result in ["", "周五 15:30 review API v2，预算 3000 元，不要改上线日期。", "answer"] {
            let invalid=VoicePolisher(model:SmartMemory(chat:{ _,_ in try SmartMemory.encoded(["text":result]) }))
            do { _ = try await invalid.polish(original); preconditionFailure("invalid cleanup accepted") } catch {}
        }
        print("PASS: one transcript-only cleanup; no memory retrieval; mixed language/negative/numeric fixture retained; changed numbers/empty output rejected")
        let cleanup=offscreen(VoiceInput()), cleanupTarget=VoiceTestTarget(); var cleanupCalls=0
        cleanup.polisher={ _ in cleanupCalls += 1; return cleaned }
        cleanup.target=cleanupTarget; cleanup.position=cleanupTarget.voicePosition(); cleanup.processing=true
        await cleanup.finishTranscript(original,polish:false,token:cleanup.generation)
        precondition(cleanupCalls == 0 && cleanupTarget.text.hasSuffix(original))
        cleanup.target=cleanupTarget; cleanup.position=cleanupTarget.voicePosition(); cleanup.processing=true
        await cleanup.finishTranscript(original,polish:true,token:cleanup.generation)
        precondition(cleanupCalls == 1 && cleanupTarget.inserted == 2 && cleanupTarget.text.hasSuffix(cleaned))
        cleanup.polisher={ _ in throw VoiceFailure.message("fixture timeout") }
        cleanup.target=cleanupTarget; cleanup.position=cleanupTarget.voicePosition(); cleanup.processing=true
        await cleanup.finishTranscript(original,polish:true,token:cleanup.generation)
        precondition(cleanupTarget.inserted == 3 && cleanupTarget.text.hasSuffix(original) && cleanup.header.stringValue.contains("原文"))
        cleanup.polisher={ _ in cleanupCalls += 1; cleanup.toggle(cleanupTarget); cleanupTarget.selection.location += 1; return cleaned }
        cleanup.target=cleanupTarget; cleanup.position=cleanupTarget.voicePosition(); cleanup.processing=true
        await cleanup.finishTranscript(original,polish:true,token:cleanup.generation)
        precondition(cleanupCalls == 2 && cleanupTarget.inserted == 3 && cleanup.pending == cleaned)
        cleanup.cancel(); cleanup.target=cleanupTarget; cleanup.position=cleanupTarget.voicePosition(); cleanup.processing=true
        cleanup.polisher={ _ in cleanup.cancel(); return cleaned }
        await cleanup.finishTranscript(original,polish:true,token:cleanup.generation)
        precondition(cleanupTarget.inserted == 3 && cleanup.pending == nil && !cleanup.busy)
        cleanup.cancel()
        print("PASS: cleanup off makes zero LLM calls; on inserts once; failure falls back; busy repeat does not submit; changed caret preserves output; cancelled/late cleanup never inserts")

        let target=VoiceTestTarget(), voice=offscreen(VoiceInput()); voice.target=target; voice.position=target.voicePosition(); voice.processing=true
        await voice.complete("语音正文"); precondition(target.inserted == 1 && voice.pending == nil)
        voice.target=target; voice.position=target.voicePosition(); target.selection.location += 1
        await voice.complete("待插入文字"); precondition(target.inserted == 1 && voice.pending == "待插入文字")
        voice.toggle(target); await voice.task?.value; precondition(target.inserted == 2 && voice.pending == nil)
        voice.target=target; voice.position=target.voicePosition(); target.acceptsVoice=false
        await voice.complete("切换后保留"); precondition(target.inserted == 2 && voice.pending != nil)
        voice.cancel(); precondition(voice.pending == nil && !voice.busy && !voice.panel.isVisible)
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav"); try audio.write(to:temp)
        voice.file=temp; voice.preparing=true; voice.target=target; voice.suspend(target)
        precondition(voice.busy && !voice.automaticInsertionAllowed && FileManager.default.fileExists(atPath:temp.path))
        voice.cancel(); precondition(!FileManager.default.fileExists(atPath:temp.path) && !voice.busy)
        print("PASS: transcription inserts once; moved caret/changed focus preserve text; explicit retry inserts; focus loss no longer cancels; cancel removes temporary audio")
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.control,.option],timestamp:0,windowNumber:0,context:nil,characters:"d",charactersIgnoringModifiers:"d",isARepeat:false,keyCode:2)!
        let system=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.control,.shift],timestamp:0,windowNumber:0,context:nil,characters:"d",charactersIgnoringModifiers:"d",isARepeat:false,keyCode:2)!
        precondition(VoiceBinding.matches(event) && !VoiceBinding.matches(system))
        print("PASS: StepFun shortcut is separate from system Dictation")

        let ending=offscreen(VoiceInput()), endingTarget=VoiceTestTarget()
        let endingAudio=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try audio.write(to:endingAudio)
        ending.target=endingTarget; ending.position=endingTarget.voicePosition(); ending.file=endingAudio
        ending.recording=true; ending.started=Date().addingTimeInterval(-1)
        var submissions=0
        ending.polisher={ $0 }
        ending.transcriber={ _ in submissions += 1; return "Enter 测试文字" }
        func enter(_ code:UInt16=36,repeatKey:Bool=false,flags:NSEvent.ModifierFlags=[])->NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:repeatKey,keyCode:code)!
        }
        precondition(!ending.handleEndingKey(enter(flags:.shift)) && ending.recording)
        precondition(ending.handleEndingKey(enter()) && !ending.recording && ending.processing)
        precondition(ending.handleEndingKey(enter(repeatKey:true)))
        precondition(ending.handleEndingKey(enter(76)))
        await ending.task?.value
        precondition(submissions == 1 && endingTarget.inserted == 1)
        precondition(ending.handleEndingKey(enter(repeatKey:true)))
        precondition(!ending.handleEndingKey(enter()) && !ending.handleEndingKey(enter(76)))
        ending.cancel()
        print("PASS: Return ends recording once; keypad Enter supported; ending key/repeats consumed; ordinary Return unchanged")
        try await unreadableClients(audio)
        try await verifiedInsertion()
        try await emptyRecognition()
        try await transientFocus()
        try recorderPreparation(audio)
        try await neverLoseWords(audio)
        try await records(audio)
    }

    @MainActor static func recorderPreparation(_ audio:Data) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoRecorderCheck-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let pool=VoiceRecorderPool(root:root)
        var devices:[VoiceRecorderFixture]=[]
        pool.factory={ file in try audio.write(to:file); let device=VoiceRecorderFixture(); devices.append(device); return device }
        pool.prepare(); pool.prepare(); pool.queue.sync {}
        precondition(devices.count == 1 && devices[0].prepared == 1 && devices[0].recordings == 0)
        let prepared=try pool.take()
        precondition(prepared.device === devices[0] && devices.count == 1)
        let mode=try FileManager.default.attributesOfItem(atPath:prepared.file.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        let voice=offscreen(VoiceInput()), target=VoiceTestTarget(); var cues=0
        voice.target=target; voice.position=target.voicePosition(); voice.recorder=prepared.device; voice.file=prepared.file
        voice.recording=true; voice.awaitingSamples=true; voice.pressedAt=Date(); voice.started=Date(); voice.readyCue={ cues += 1 }
        voice.showStatus(); precondition(voice.header.stringValue == "启动麦克风" && voice.wave.isHidden && !voice.header.isHidden && !voice.hint.isHidden && !voice.cancelButton.isHidden && voice.panel.frame.size == NSSize(width:272,height:66) && voice.surface.menu?.items.first?.action == #selector(VoiceInput.dismiss))
        voice.tick(); precondition(cues == 0 && voice.awaitingSamples && voice.readyMs == nil)
        devices[0].currentTime=0.02; voice.tick()
        precondition(cues == 1 && !voice.awaitingSamples && voice.readyMs != nil && !voice.wave.isHidden && voice.header.stringValue.hasPrefix("正在听"))
        voice.tick(); precondition(cues == 1)
        voice.cancel(); precondition(!FileManager.default.fileExists(atPath:prepared.file.path) && devices[0].stops == 1)
        pool.prepare(); pool.discard(); pool.queue.sync {}
        let remaining=try FileManager.default.contentsOfDirectory(atPath:root.path)
        precondition(devices.count == 2 && devices[1].recordings == 0 && devices[1].stops == 1 && remaining.isEmpty)
        print("PASS: preparation creates no recording, is reused once, and focus disposal deletes its file; ready cue waits for recorded samples and fires once; cancel stops and deletes audio")
    }

    @MainActor static func unreadableClients(_ audio:Data) async throws {
        let current=VoicePosition.currentSelection
        precondition(current.requiresConfirmation && current.replacementRange == NSRange(location:NSNotFound,length:0))
        for range in [NSRange(location:NSNotFound,length:0),NSRange(location:0,length:NSNotFound)] {
            precondition(VoicePosition.capture(selection:range) { _ in preconditionFailure("unreadable selection queried text") } == current)
        }
        let selected=NSRange(location:3,length:2)
        precondition(VoicePosition.capture(selection:selected) { $0 == selected ? "选择" : "前三字" } == VoicePosition(selection:selected,prefix:"前三字",selected:"选择"))
        precondition(VoicePosition.capture(selection:NSRange(location:0,length:0)) { _ in preconditionFailure("empty field queried text") }?.requiresConfirmation == false)
        precondition(VoicePosition.capture(selection:NSRange(location:3,length:0)) { _ in nil } == current)
        precondition(VoicePosition.capture(selection:NSRange(location:3,length:0)) { _ in "短" } == current)
        precondition(VoicePosition.capture(selection:selected) { $0 == selected ? nil : "前三字" } == current)
        precondition(VoicePosition.capture(selection:NSRange(location:0,length:16001)) { _ in preconditionFailure("oversize selection queried text") } == nil)

        let target=VoiceTestTarget(), voice=offscreen(VoiceInput()); target.requiresConfirmation=true
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav"); try audio.write(to:file)
        voice.target=target; voice.file=file; voice.recording=true; voice.started=Date().addingTimeInterval(-1)
        voice.capturePosition(target.voicePosition()!)
        precondition(!voice.automaticInsertionAllowed && voice.recordingHint == "结束后保留文字" && voice.recording)
        voice.polisher={ $0 }; voice.transcriber={ _ in "兼容输入框的文字" }
        voice.stop(); await voice.task?.value
        precondition(target.inserted == 0 && voice.pending == "兼容输入框的文字" && !FileManager.default.fileExists(atPath:file.path))
        target.acceptsVoice=false; voice.toggle(target)
        precondition(target.inserted == 0 && voice.pending != nil)
        target.acceptsVoice=true; voice.toggle(target); await voice.task?.value
        precondition(target.inserted == 1 && target.lastReplacement == current.replacementRange && voice.pending == "兼容输入框的文字" && !voice.inserted && voice.header.stringValue == "未确认填入")
        voice.cancel()
        // With a known, unchanged IMK session an unreadable field gets one automatic write.
        target.voiceFocusStamp=UUID().uuidString
        voice.target=target; voice.capturePosition(current)
        precondition(voice.automaticInsertionAllowed)
        await voice.complete("原会话的文字")
        precondition(target.inserted == 2 && voice.pending == "原会话的文字" && !voice.inserted)
        voice.cancel(); voice.target=target; voice.capturePosition(current); target.voiceFocusStamp=UUID().uuidString
        await voice.complete("切换后保留")
        precondition(target.inserted == 2 && voice.pending == "切换后保留")
        voice.cancel(); voice.target=target; voice.capturePosition(current); voice.userMoved(target)
        await voice.complete("用户编辑后保留")
        precondition(target.inserted == 2 && voice.pending == "用户编辑后保留")
        voice.cancel(); voice.target=target; voice.capturePosition(current); voice.suspend(target,sameApplication:true); voice.resume(target)
        await voice.complete("停用后保留")
        precondition(target.inserted == 2 && voice.pending == "停用后保留")
        voice.cancel()
        print("PASS: unreadable fields with a bound unchanged IMK session receive one auto-write and retain unverifiable text; unbound, changed, edited or deactivated sessions keep text; explicit insertion uses current selection")
    }

    @MainActor static func verifiedInsertion() async throws {
        // A real Cocoa text view exercises current-selection replacement, UTF-16 and multiline text.
        let view=NSTextView(frame:NSRect(x:0,y:0,width:400,height:160)), words="第一行🙂\n第二行 API v2。"
        var sends=0, replacement:NSRange?, currentField=true
        func read(_ range:NSRange)->String? {
            let text=view.string as NSString
            guard range.location>=0,range.length>=0,range.location<=text.length,range.length<=text.length-range.location else { return nil }
            return text.substring(with:range)
        }
        func position()->VoicePosition? { VoicePosition.capture(selection:view.selectedRange(),substring:read) }
        func reset(_ text:String,_ selection:NSRange) { view.string=text; view.setSelectedRange(selection); sends=0; replacement=nil; currentField=true }
        reset("开头🙂选中结尾",("开头🙂选中结尾" as NSString).range(of:"选中"))
        let native=await VoiceInsertion.perform(words,position:position()!,current:position,isCurrent:{ currentField },insert:{ range in
            sends += 1; replacement=range; view.insertText(words,replacementRange:range)
        },substring:read)
        precondition(native == .confirmed && sends == 1 && replacement == VoicePosition.currentSelection.selection && view.string == "开头🙂"+words+"结尾")
        reset("原有文字",NSRange(location:4,length:0))
        var delivery:Task<Void,Never>?
        let delayed=await VoiceInsertion.perform(words,position:position()!,current:position,isCurrent:{ currentField },insert:{ range in
            sends += 1
            delivery=Task { @MainActor in try? await Task.sleep(nanoseconds:180_000_000); view.insertText(words,replacementRange:range) }
        },substring:read)
        await delivery?.value
        precondition(delayed == .confirmed && sends == 1 && view.string == "原有文字"+words)
        reset("原有文字",NSRange(location:4,length:0))
        let ignored=await VoiceInsertion.perform(words,position:position()!,current:position,isCurrent:{ currentField },insert:{ _ in sends += 1 },substring:read)
        precondition(ignored == .unconfirmed && sends == 1 && view.string == "原有文字")
        reset("原有文字",NSRange(location:4,length:0))
        let partial=await VoiceInsertion.perform(words,position:position()!,current:position,isCurrent:{ currentField },insert:{ range in
            sends += 1; view.insertText("第一行",replacementRange:range)
        },substring:read)
        precondition(partial == .unconfirmed && sends == 1)
        reset("完全不同的原有文字",NSRange(location:0,length:0))
        let caretOnly=await VoiceInsertion.perform("缺失",position:position()!,current:position,isCurrent:{ currentField },insert:{ _ in sends += 1; view.setSelectedRange(NSRange(location:2,length:0)) },substring:read)
        precondition(caretOnly == .unconfirmed && sends == 1)
        reset(words,NSRange(location:0,length:0))
        let unchanged=await VoiceInsertion.perform(words,position:position()!,current:position,isCurrent:{ currentField },insert:{ _ in sends += 1 },substring:read)
        precondition(unchanged == .unconfirmed && sends == 1)
        reset("原有文字",NSRange(location:4,length:0))
        let stalePosition=position()!; view.setSelectedRange(NSRange(location:0,length:0))
        let stale=await VoiceInsertion.perform(words,position:stalePosition,current:position,isCurrent:{ currentField },insert:{ _ in sends += 1 },substring:read)
        precondition(stale == .failed && sends == 0)
        let leaving=await VoiceInsertion.perform(words,position:position()!,current:position,isCurrent:{ currentField },insert:{ range in
            sends += 1; view.insertText(words,replacementRange:range); currentField=false
        },substring:read)
        precondition(leaving == .unconfirmed && sends == 1)
        print("PASS: native selected/multiline/emoji text uses current selection; delayed clients are read back once; ignored/partial/caret-only writes are unconfirmed; stale fields are rejected; focus changes cannot confirm")

        let log=MemoryLog.shared, edits=VoiceEdits.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoInsertionCheck-"+UUID().uuidString)
        MemoryLog.shared=MemoryLog(root:root); VoiceEdits.shared=VoiceEdits()
        defer { MemoryLog.shared=log; VoiceEdits.shared=edits; try? FileManager.default.removeItem(at:root) }
        func records()->[[String:Any]] {
            ((try? FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("Voice"),includingPropertiesForKeys:nil)) ?? []).flatMap { url in
                ((try? String(contentsOf:url,encoding:.utf8)) ?? "").split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }
            }
        }
        let voice=offscreen(VoiceInput()), target=VoiceTestTarget(); var attempts=0
        target.insertion={ _,_ in attempts += 1; return .unconfirmed }
        voice.target=target; voice.position=target.voicePosition()
        voice.run=VoiceRun(app:target.voiceApp,asr:.init(model:"fixture",ms:1,text:words,hotwords:0))
        await voice.complete(words)
        precondition(attempts == 1 && voice.pending == words && !voice.inserted && !voice.busy && voice.header.stringValue == "未确认填入" && !voice.copyButton.isHidden)
        precondition(records().last?["outcome"] as? String == "kept" && records().last?["kept_because"] as? String == "insert_unconfirmed" && VoiceEdits.shared.watches.isEmpty)
        voice.toggle(target); await voice.task?.value
        precondition(attempts == 2 && voice.pending == words && !voice.inserted && records().last?["kind"] as? String == "fill_unconfirmed")
        target.insertion={ _,_ in attempts += 1; return .failed }
        voice.toggle(target); await voice.task?.value
        precondition(attempts == 3 && voice.pending == words && !voice.inserted && records().last?["kind"] as? String == "fill_failed")
        target.insertion={ value,_ in
            attempts += 1; try? await Task.sleep(nanoseconds:80_000_000)
            target.text += value; target.selection.location=target.text.utf16.count; return .confirmed
        }
        precondition(voice.fillPending(target)); let confirmation=voice.task
        precondition(voice.busy && voice.inserting && voice.header.stringValue == "正在填入" && voice.check.isHidden && voice.pending == words)
        precondition(voice.fillPending(target))
        await confirmation?.value
        precondition(attempts == 4 && voice.pending == nil && voice.inserted && voice.header.stringValue == "已填入" && records().last?["kind"] as? String == "filled" && VoiceEdits.shared.watches.count == 1)
        voice.cancel()
        target.insertion={ _,_ in
            await withCheckedContinuation { continuation in DispatchQueue.main.asyncAfter(deadline:.now()+0.05) { continuation.resume(returning:()) } }
            return .confirmed
        }
        voice.target=target; voice.position=target.voicePosition()
        let late=Task { @MainActor in await voice.complete(words) }; voice.task=late
        await Task.yield(); precondition(voice.inserting)
        voice.cancel(); await late.value
        precondition(!voice.busy && voice.pending == nil && !voice.inserted && !voice.panel.isVisible)
        voice.target=target; voice.position=target.voicePosition(); voice.pending=words
        voice.toggle(target); let cancelledManual=voice.task; voice.cancel(); await cancelledManual?.value
        precondition(attempts == 4 && voice.pending == nil && !voice.inserted && !voice.panel.isVisible)
        voice.target=target; voice.position=target.voicePosition(); voice.processing=true; voice.polishing=true; voice.transcript=words
        precondition(voice.handleEscape()); let cancelledSkip=voice.task; voice.cancel(); await cancelledSkip?.value
        precondition(attempts == 4 && voice.pending == nil && !voice.busy && !voice.panel.isVisible)
        print("PASS: auto/manual unconfirmed writes retain complete text and copy action, never log success; confirmation alone clears pending text; waiting repeats and cancelled/late acknowledgements cannot report success")
    }

    // A WAV with an odd metadata chunk exercises the real audio container rather than a fake envelope.
    static func waveFixture(silent:Bool=false)->Data {
        func le(_ value:Int,_ count:Int)->Data { Data((0..<count).map { UInt8((value >> ($0*8)) & 255) }) }
        func chunk(_ name:String,_ body:Data)->Data { var data=Data(name.utf8); data.append(le(body.count,4)); data.append(body); if body.count%2==1 { data.append(0) }; return data }
        var format=Data(); for (value,count) in [(1,2),(1,2),(16000,4),(32000,4),(2,2),(16,2)] { format.append(le(value,count)) }
        var samples=Data(); for i in 0..<6400 { samples.append(le(silent ? 0 : (i%2==0 ? 6000 : 59536),2)) }
        var body=Data("WAVE".utf8); body.append(chunk("JUNK",Data([1,2,3]))); body.append(chunk("fmt ",format)); body.append(chunk("data",samples))
        var wave=Data("RIFF".utf8); wave.append(le(body.count,4)); wave.append(body); return wave
    }
    @MainActor static func emptyRecognition() async throws {
        let audio=waveFixture(), wave=VoiceWave(audio)!, silence=waveFixture(silent:true)
        precondition(wave.stats.seconds == 0.4 && wave.stats.peak_db > -20 && wave.hasSignal && wave.pcm.count == 12800)
        precondition(VoiceWave(silence)?.stats.peak_db == -160 && VoiceWave(silence)?.hasSignal == false && VoiceWave(Data(audio.dropLast())) == nil)
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[VoiceURLFixture.self]
        let session=URLSession(configuration:config); defer { session.invalidateAndCancel(); VoiceURLFixture.queuedBodies=[]; VoiceURLFixture.requests=[]; VoiceURLFixture.status=200 }
        let empty="data: {\"type\":\"transcript.text.done\",\"text\":\"\"}\n\n", success="data: {\"type\":\"transcript.text.done\",\"text\":\"完整转写\"}\n\n"
        func reset(_ bodies:[String],status:Int=200) { VoiceURLFixture.seen=0; VoiceURLFixture.requests=[]; VoiceURLFixture.queued=[]; VoiceURLFixture.queuedBodies=bodies; VoiceURLFixture.status=status }
        var retries=0
        reset([empty,success])
        let recovered=try await StepASR.transcribe(audio:audio,key:"TEST_ONLY",model:"stepaudio-2.5-asr",language:"auto",session:session,progress:{ _ in },onPCMRetry:{ retries += 1 })
        precondition(recovered == "完整转写" && retries == 1 && VoiceURLFixture.seen == 2)
        let retryBody=try JSONSerialization.jsonObject(with:VoiceURLFixture.requests[1].httpBody!) as! [String:Any]
        let retryAudio=retryBody["audio"] as! [String:Any], input=retryAudio["input"] as! [String:Any]
        precondition((input["format"] as! [String:Any])["type"] as? String == "pcm" && retryAudio["data"] as? String == wave.pcm.base64EncodedString())
        reset([empty,empty])
        do { _ = try await StepASR.transcribe(audio:audio,key:"TEST_ONLY",model:"stepaudio-2.5-asr",language:"auto",session:session,progress:{ _ in }); preconditionFailure("second empty response accepted") } catch VoiceFailure.emptyTranscript {}
        precondition(VoiceURLFixture.seen == 2)
        for (clip,bodies,status) in [(silence,[empty],200),(audio,[empty],401),(audio,["data: {\"type\":\"transcript.text.delta\",\"delta\":\"片段\"}\n\n"],200)] {
            reset(bodies,status:status)
            do { _ = try await StepASR.transcribe(audio:clip,key:"TEST_ONLY",model:"stepaudio-2.5-asr",language:"auto",session:session,progress:{ _ in }); preconditionFailure("invalid result accepted") } catch {}
            precondition(VoiceURLFixture.seen == 1)
        }
        let oldLog=MemoryLog.shared, root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoFailureCheck-"+UUID().uuidString)
        MemoryLog.shared=MemoryLog(root:root); defer { MemoryLog.shared=oldLog; try? FileManager.default.removeItem(at:root) }
        let voice=offscreen(VoiceInput()), target=VoiceTestTarget(); voice.target=target
        voice.failed(VoiceFailure.emptyTranscript,audio:audio); precondition(voice.header.stringValue == "识别失败" && voice.hint.stringValue.contains("重新录音"))
        voice.cancel(); voice.target=target; voice.failed(VoiceFailure.emptyTranscript,audio:silence)
        precondition(voice.header.stringValue == "录音没有声音" && voice.hint.stringValue.contains("重新录音"))
        let files=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("Voice"),includingPropertiesForKeys:nil)
        let lines=try String(contentsOf:files[0],encoding:.utf8).split(separator:"\n")
        let record=try JSONSerialization.jsonObject(with:Data(lines.last!.utf8)) as! [String:Any]
        precondition(record["schema"] as? String == "echo.voice.failure/1" && (record["audio"] as? [String:Any])?["peak_db"] as? Double == -160 && record["pcm"] == nil)
        voice.cancel()
        print("PASS: WAV metadata/padding and real duration/levels parsed; empty voiced WAV retries exact PCM once; empty retry/silence/auth/partial streams do not loop; failures record levels without audio; silent clips prompt fresh recording")
    }
    @MainActor static func transientFocus() async throws {
        let voice=offscreen(VoiceInput()), original=VoiceTestTarget(), refreshed=VoiceTestTarget()
        refreshed.voiceIdentity=original.voiceIdentity
        func start() { voice.cancel(); voice.target=original; voice.capturePosition(original.voicePosition()!); voice.processing=true }
        start(); voice.suspend(original,sameApplication:true); voice.resume(refreshed)
        precondition(voice.automaticInsertionAllowed && voice.target === refreshed && voice.keptBecause == nil)
        await voice.complete("刷新后仍填入原位置")
        precondition(refreshed.inserted == 1 && voice.inserted)
        start(); voice.suspend(original,sameApplication:true); let other=VoiceTestTarget(); voice.resume(other)
        precondition(!voice.automaticInsertionAllowed && voice.target === original)
        start(); voice.suspend(original,sameApplication:true); refreshed.selection.location += 1; voice.resume(refreshed)
        precondition(!voice.automaticInsertionAllowed); refreshed.selection=original.selection; refreshed.text=original.text
        start(); voice.suspend(original); voice.resume(refreshed); precondition(!voice.automaticInsertionAllowed)
        start(); voice.suspend(original,sameApplication:true); voice.userMoved(original); voice.resume(refreshed); precondition(!voice.automaticInsertionAllowed)
        voice.cancel()
        print("PASS: temporary deactivation restores only identical IMK field/text/caret/anchor; different clients, moved carets, app changes and explicit focus movement keep the text")
    }

    // Fictional audio and text only; transcriber/polisher are injected, so no Key, microphone or network.
    @MainActor static func neverLoseWords(_ audio:Data) async throws {
        func recording(_ voice:VoiceInput,_ target:VoiceTestTarget) throws -> URL {
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav"); try audio.write(to:url)
            voice.target=target; voice.file=url; voice.recording=true; voice.started=Date().addingTimeInterval(-1); voice.capturePosition(target.voicePosition()!)
            return url
        }
        let raw="周五 15:30 review API v2，预算 2000 元。"

        // Esc while polishing fills in the raw transcript once; the late cleanup result never lands.
        let skip=offscreen(VoiceInput()), skipTarget=VoiceTestTarget()
        skip.polisher={ _ in let consumed=skip.handleEscape(); precondition(consumed); return "整理后的文字" }
        skip.target=skipTarget; skip.position=skipTarget.voicePosition(); skip.processing=true
        await skip.finishTranscript(raw,polish:true,token:skip.generation)
        await skip.task?.value
        precondition(skipTarget.inserted == 1 && skipTarget.text.hasSuffix(raw) && !skipTarget.text.contains("整理后") && skip.header.stringValue == "已填入原文" && !skip.busy && skip.pending == nil)
        precondition(!skip.handleEscape())
        skip.cancel()
        print("PASS: Esc while polishing fills in the raw transcript once (「已填入原文」); late cleanup ignored; Esc after filling in is left to the app")

        // After failure the next shortcut starts a new take, never re-sends the old audio.
        let fresh=offscreen(VoiceInput()), freshTarget=VoiceTestTarget(); fresh.autoHide=0.2
        var sent:[Data]=[], starts=0
        fresh.polisher={ $0 }
        fresh.transcriber={ data in sent.append(data); throw VoiceFailure.message("服务暂时不可用，请稍后重试。") }
        let first=try recording(fresh,freshTarget)
        fresh.stop(); await fresh.task?.value
        precondition(sent == [audio] && !fresh.busy && fresh.terminal && fresh.header.stringValue == "识别失败")
        precondition(fresh.hint.stringValue == "按 \(VoiceBinding.label) 重新录音" && fresh.file == nil && !FileManager.default.fileExists(atPath:first.path) && fresh.copyButton.isHidden)
        fresh.recordingStarter={ owner in
            fresh.cancel(); starts += 1; fresh.target=owner; fresh.capturePosition(owner.voicePosition()!); fresh.recording=true; fresh.showStatus()
        }
        fresh.keyDown(freshTarget)
        precondition(starts == 1 && fresh.recording && fresh.heldSince != nil && !fresh.processing && sent == [audio])
        fresh.keyDown(freshTarget); precondition(starts == 1 && fresh.recording)  // held repeat does not immediately stop
        fresh.keyUp(); precondition(fresh.recording && fresh.heldSince == nil)  // a tap stays listening
        fresh.cancel()
        fresh.transcriber={ _ in throw VoiceFailure.message("api.stepfun.com 返回 HTTP 401：Key 未被此服务认可。") }
        let second=try recording(fresh,freshTarget); fresh.stop(); await fresh.task?.value
        precondition(fresh.hint.stringValue == "打开设置" && !FileManager.default.fileExists(atPath:second.path))
        precondition(fresh.handleEscape() && !fresh.terminal && !fresh.panel.isVisible)
        let third=try recording(fresh,freshTarget); fresh.stop(); await fresh.task?.value
        try await Task.sleep(nanoseconds:500_000_000)
        precondition(!fresh.terminal && !fresh.panel.isVisible && !FileManager.default.fileExists(atPath:third.path))
        print("PASS: failure deletes temporary WAV and offers fresh recording; shortcut starts listening rather than resending old audio; held repeats and tap release cannot immediately finish; auth hints settings and failure cards dismiss")

        // Another field, caret or app during recording no longer cancels; the text is kept for explicit insertion.
        let moving=offscreen(VoiceInput()), movingTarget=VoiceTestTarget()
        moving.polisher={ $0 }; moving.transcriber={ _ in "换位置后的文字" }
        let movingFile=try recording(moving,movingTarget)
        moving.tick(); precondition(moving.recording && moving.automaticInsertionAllowed && moving.hint.stringValue == "Return 结束")
        movingTarget.selection.location += 1; moving.tick()
        precondition(moving.recording && !moving.automaticInsertionAllowed && moving.hint.stringValue == "位置变化 · 保留文字" && FileManager.default.fileExists(atPath:movingFile.path))
        movingTarget.selection.location -= 1; moving.tick(); precondition(!moving.automaticInsertionAllowed)
        moving.stop(); await moving.task?.value
        precondition(moving.pending == "换位置后的文字" && movingTarget.inserted == 0 && !moving.busy && !FileManager.default.fileExists(atPath:movingFile.path))
        moving.toggle(movingTarget); await moving.task?.value; precondition(movingTarget.inserted == 1 && moving.pending == nil)
        let away=offscreen(VoiceInput()), awayTarget=VoiceTestTarget()
        away.polisher={ $0 }; away.transcriber={ _ in "切走后的文字" }
        _ = try recording(away,awayTarget)
        away.suspend(awayTarget); away.tick()
        precondition(away.recording && away.hint.stringValue == "位置变化 · 保留文字")
        away.stop(); await away.task?.value
        precondition(away.pending == "切走后的文字" && awayTarget.inserted == 0)
        away.cancel()
        print("PASS: caret move or IME deactivation during recording keeps recording, shows 「位置变了」, ends as kept text; returning the caret does not re-enable auto insertion")

        // Captured AU05 presses/releases can be valid while Quartz always reports the chord as up.
        // That unavailable state must not clear a real hold before the release event arrives.
        let unavailableState=offscreen(VoiceInput()), unavailableTarget=VoiceTestTarget()
        var eventNow:TimeInterval=100, unavailableSent=0
        unavailableState.keyClock={ eventNow }
        unavailableState.voiceKeyIsDown={ _ in false }
        unavailableState.polisher={ $0 }; unavailableState.transcriber={ _ in unavailableSent += 1; return "真实长按松开后的文字" }
        unavailableState.recordingStarter={ owner in _ = try! recording(unavailableState,unavailableTarget) }
        unavailableState.keyDown(unavailableTarget,at:100)
        eventNow=100.02
        unavailableState.tick()
        if unavailableState.heldSince == nil {
            unavailableState.cancel()
            throw VoiceFailure.message("Regression: unavailable Quartz state clears the AU05 hold before its real release event")
        }
        unavailableState.observeVoiceModifiers([],at:0)  // an undated IMK modifier event is not a confirmed release
        unavailableState.observeVoiceModifiers([],at:99.99)
        unavailableState.keyUp(at:99.99)
        precondition(unavailableState.heldSince == 100 && unavailableState.recording)
        eventNow=105.238; unavailableState.tick()
        precondition(unavailableState.recording && unavailableState.heldSince == 100)
        unavailableState.keyUp(at:105.238); unavailableState.keyUp(at:105.238); await unavailableState.task?.value
        precondition(unavailableSent == 1 && unavailableTarget.inserted == 1 && !unavailableState.recording)
        unavailableState.cancel()

        // Microphone setup and queued callbacks must not shorten a physical hold or lengthen a tap.
        let startupHold=offscreen(VoiceInput()), startupTarget=VoiceTestTarget(); var startupNow:TimeInterval=200, startupSent=0
        startupHold.keyClock={ startupNow }; startupHold.voiceKeyIsDown={ _ in false }
        startupHold.polisher={ $0 }; startupHold.transcriber={ _ in startupSent += 1; return "启动延迟后的长按文字" }
        startupHold.recordingStarter={ owner in startupNow=203.5; _ = try! recording(startupHold,startupTarget) }
        startupHold.keyDown(startupTarget,at:200)
        precondition(startupHold.heldSince == 200)
        startupHold.tick(); startupHold.keyUp(at:202); await startupHold.task?.value
        precondition(!startupHold.recording && startupSent == 1 && startupTarget.inserted == 1)
        startupHold.cancel()

        let startupTap=offscreen(VoiceInput()), tapTarget=VoiceTestTarget(); var tapNow:TimeInterval=300, tapSent=0
        startupTap.keyClock={ tapNow }; startupTap.voiceKeyIsDown={ _ in false }
        startupTap.polisher={ $0 }; startupTap.transcriber={ _ in tapSent += 1; return "短按后再按结束的文字" }
        startupTap.recordingStarter={ owner in tapNow=303.5; _ = try! recording(startupTap,tapTarget) }
        startupTap.keyDown(tapTarget,at:300)
        startupTap.tick(); startupTap.keyUp(at:300.145)
        precondition(startupTap.recording && startupTap.heldSince == nil && tapSent == 0)
        startupTap.keyDown(nil); await startupTap.task?.value
        precondition(!startupTap.recording && tapSent == 1 && tapTarget.inserted == 1)
        startupTap.cancel()

        let preparingHold=offscreen(VoiceInput()), preparingTarget=VoiceTestTarget(); var preparingNow:TimeInterval=400
        preparingHold.keyClock={ preparingNow }; preparingHold.voiceKeyIsDown={ _ in false }
        preparingHold.recordingStarter={ owner in preparingHold.preparing=true; preparingHold.target=owner }
        preparingHold.keyDown(preparingTarget,at:400); preparingNow=401; preparingHold.keyUp(at:401)
        precondition(!preparingHold.preparing && !preparingHold.recording && preparingHold.heldSince == nil)
        print("PASS: captured AU05 5.238s hold ends on real release despite unavailable Quartz state; monotonic event times preserve holds/taps across 3.5s microphone setup; stale callbacks ignored; release during preparation cancels safely")

        // AU05 can release the physical chord without IMK/Carbon delivering its key-up to Echo.
        // With no physical voice key held, tick must clear the stale hold so another press ends this take.
        let missedRelease=offscreen(VoiceInput()), missedTarget=VoiceTestTarget(); var missedSent=0
        missedRelease.voiceKeyIsDown={ _ in false }
        missedRelease.polisher={ $0 }; missedRelease.transcriber={ _ in missedSent += 1; return "设备键结束的文字" }
        _ = try recording(missedRelease,missedTarget); missedRelease.heldSince=missedRelease.keyClock(); missedRelease.heldKeyWasDown=true
        missedRelease.tick()
        precondition(missedRelease.recording && missedRelease.heldSince == nil)
        missedRelease.keyDown(nil)  // Carbon can end this take even without a current IMK target
        if missedRelease.recording {
            missedRelease.cancel()
            throw VoiceFailure.message("Regression: a missing AU05 key-up leaves the hold latched and swallows the next stop press")
        }
        await missedRelease.task?.value
        precondition(missedSent == 1 && missedTarget.inserted == 1 && missedRelease.heldSince == nil)
        missedRelease.cancel()

        let modifierRelease=offscreen(VoiceInput()), modifierTarget=VoiceTestTarget(); var modifierSent=0
        modifierRelease.polisher={ $0 }; modifierRelease.transcriber={ _ in modifierSent += 1; return "组合键松开后的文字" }
        _ = try recording(modifierRelease,modifierTarget); modifierRelease.heldSince=modifierRelease.keyClock()
        modifierRelease.heldShortcut=EchoShortcut(keyCode:2,flags:[.control,.option],key:"D")
        modifierRelease.observeVoiceModifiers([.control,.option,.capsLock])
        precondition(modifierRelease.heldSince != nil && modifierRelease.recording)
        modifierRelease.observeVoiceModifiers([.control,.capsLock])
        precondition(modifierRelease.heldSince == nil && modifierRelease.recording)
        modifierRelease.keyDown(nil); modifierRelease.keyUp(); await modifierRelease.task?.value
        precondition(modifierSent == 1 && modifierTarget.inserted == 1)
        modifierRelease.cancel()

        let lostFocus=offscreen(VoiceInput()), lostTarget=VoiceTestTarget(); var focusSent=0, registration:[Bool]=[]
        lostFocus.onActivityChanged={ registration.append(EchoMemoryHotKey.voiceShouldRegister(active:false,recording:lostFocus.recording,preparing:lostFocus.preparing,suspended:false)) }
        lostFocus.polisher={ $0 }; lostFocus.transcriber={ _ in focusSent += 1; return "失焦后保留的文字" }
        _ = try recording(lostFocus,lostTarget); lostFocus.suspend(lostTarget)
        precondition(registration.last == true)
        lostFocus.keyDown(nil); lostFocus.keyDown(nil); lostFocus.keyUp(); await lostFocus.task?.value
        precondition(focusSent == 1 && lostTarget.inserted == 0 && lostFocus.pending == "失焦后保留的文字" && registration.last == false)
        lostFocus.onActivityChanged=nil; lostFocus.cancel()
        precondition(EchoMemoryHotKey.voiceShouldRegister(active:false,recording:false,preparing:true,suspended:false))
        precondition(!EchoMemoryHotKey.voiceShouldRegister(active:false,recording:false,preparing:false,suspended:false))
        precondition(!EchoMemoryHotKey.voiceShouldRegister(active:true,recording:true,preparing:false,suspended:true))
        print("PASS: AU05 missing key-up and modifier-first release recover; next press stops once without an active input field; recording retains its global shortcut across focus loss and keeps text")

        // Push-to-talk: holding the voice key records, letting go ends it; a quick tap keeps listening hands-free.
        let hold=offscreen(VoiceInput()), holdTarget=VoiceTestTarget(); var holdSent=0
        hold.polisher={ $0 }; hold.transcriber={ _ in holdSent += 1; return "按住说的话" }
        _ = try recording(hold,holdTarget); hold.heldSince=hold.keyClock()-1
        hold.tick(); precondition(hold.recording && hold.heldSince != nil)  // a physically held key must not be recovered as a release
        precondition(hold.recordingHint == "松开结束")
        hold.keyDown(holdTarget); precondition(hold.recording && hold.heldSince != nil)  // key repeat while held
        hold.keyUp(); await hold.task?.value
        precondition(!hold.recording && hold.heldSince == nil && holdSent == 1 && holdTarget.inserted == 1 && holdTarget.text.hasSuffix("按住说的话"))
        hold.cancel()
        _ = try recording(hold,holdTarget); hold.heldSince=hold.keyClock()
        hold.keyUp(); precondition(hold.recording && hold.heldSince == nil && hold.recordingHint == "Return 结束" && holdSent == 1)  // a tap
        hold.keyUp(); precondition(hold.recording)  // a later key-up without a hold changes nothing
        hold.cancel()
        let silentFile=try recording(hold,holdTarget); hold.pauseDetector=VoicePauseDetector(started:Date().timeIntervalSinceReferenceDate); hold.heldSince=hold.keyClock()-2
        hold.keyUp()
        precondition(!hold.recording && holdSent == 1 && hold.header.stringValue == "没有听到声音" && !FileManager.default.fileExists(atPath:silentFile.path))
        hold.cancel(); precondition(hold.heldSince == nil)
        _ = try recording(hold,holdTarget); hold.heldSince=hold.keyClock()-1; hold.heldKeyWasDown=true; hold.voiceKeyIsDown={ _ in false }
        hold.tick(); hold.keyUp(); await hold.task?.value
        precondition(!hold.recording && holdSent == 2 && holdTarget.inserted == 2)
        hold.cancel()
        print("PASS: push-to-talk — holding records and letting go recognizes once; key repeat ignored; a quick tap keeps listening; a silent hold sends nothing")

        // Esc: recording and recognizing cancel; kept text and closing cards are dismissed; otherwise the app gets it.
        let esc=offscreen(VoiceInput()), escTarget=VoiceTestTarget()
        precondition(!esc.handleEscape())
        let escFile=try recording(esc,escTarget)
        precondition(esc.handleEscape() && !esc.busy && !FileManager.default.fileExists(atPath:escFile.path) && !esc.panel.isVisible)
        esc.polisher={ $0 }; esc.transcriber={ _ in "迟到的文字" }
        _ = try recording(esc,escTarget)
        esc.stop(); precondition(esc.processing && !esc.polishing)
        let late=esc.task; precondition(esc.handleEscape() && !esc.busy); await late?.value
        precondition(escTarget.inserted == 0 && esc.pending == nil && !esc.panel.isVisible)
        esc.target=escTarget; esc.position=escTarget.voicePosition(); escTarget.selection.location += 1; esc.processing=true
        await esc.complete("保留的文字"); precondition(esc.pending == "保留的文字" && esc.handleEscape() && esc.pending == nil && !esc.panel.isVisible)
        escTarget.selection.location -= 1
        esc.microphoneDenied(); precondition(esc.terminal && esc.gearURL == VoiceInput.microphoneSettings && esc.handleEscape() && !esc.terminal && esc.gearURL == nil)
        esc.target=escTarget; esc.position=escTarget.voicePosition(); esc.processing=true
        await esc.complete("填入的文字"); precondition(escTarget.inserted == 1 && esc.inserted && !esc.handleEscape())
        esc.cancel()
        print("PASS: handleEscape — idle/filled-in false; recording and recognizing cancel (audio deleted, late text ignored); kept text dismissed; mic-denied card closed")

        // Closing cards hide after the delay; unusable places explain themselves at the caret and never drop kept text.
        let hide=offscreen(VoiceInput()); hide.autoHide=0.2
        hide.noSpeech(); precondition(hide.terminal && hide.header.stringValue == "没有听到声音" && hide.panel.isVisible)
        try await Task.sleep(nanoseconds:500_000_000)
        precondition(!hide.terminal && !hide.panel.isVisible)
        let refuse=offscreen(VoiceInput()), refuseTarget=VoiceTestTarget(); refuseTarget.acceptsVoice=false
        refuse.toggle(refuseTarget)
        precondition(!refuse.busy && !refuse.terminal && EchoHint.shared.label.stringValue == refuseTarget.refusal)
        refuse.pending="保留"; EchoHint.shared.label.stringValue=""; refuse.toggle(refuseTarget)
        precondition(refuse.pending == "保留" && refuseTarget.inserted == 0 && EchoHint.shared.label.stringValue == refuseTarget.refusal)
        refuse.cancel()
        print("PASS: closing cards auto-hide; refused start/fill-in shows a caret hint and keeps pending text")
    }

    // Common words, the cleanup gate, and the dictation record: fictional text, a scratch log, no network.
    @MainActor static func records(_ audio:Data) async throws {
        // Common words: separators, duplicates, overlong entries, the cap; sent as hotwords only when there are some.
        check(VoiceTerms.parse("张伟, WithEcho\r\nCodex，张伟、 ;；"+String(repeating:"长",count:31)) == ["张伟","WithEcho","Codex"],"common words parsed (CRLF too), deduplicated, overlong dropped")
        check(VoiceTerms.parse((1...150).map { "词\($0)" }.joined(separator:",")).count == 100,"at most 100 common words")
        func transcription(_ hotwords:[String]) throws -> [String:Any] {
            let request=try StepASR.request(audio:audio,key:"TEST_ONLY",model:"stepaudio-2.5-asr",language:"auto",hotwords:hotwords)
            let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            return ((body["audio"] as! [String:Any])["input"] as! [String:Any])["transcription"] as! [String:Any]
        }
        check(try transcription(["张伟","Codex"])["hotwords"] as? [String] == ["张伟","Codex"] && transcription([])["hotwords"] == nil,"hotwords go to recognition only when set")
        // Hotwords the service refuses are dropped, once, and the words still come back.
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[VoiceURLFixture.self]
        let session=URLSession(configuration:config); defer { session.invalidateAndCancel(); StepASR.hotwordsRefused=false; VoiceURLFixture.queued=[] }
        VoiceURLFixture.status=200; VoiceURLFixture.seen=0; VoiceURLFixture.queued=[400]
        VoiceURLFixture.body="data: {\"type\":\"transcript.text.done\",\"text\":\"热词被拒后的文字\"}\n\n"
        let unhinted=try await StepASR.transcribe(audio:audio,key:"TEST_ONLY",model:"stepaudio-2.5-asr",language:"auto",hotwords:["张伟"],session:session,progress:{ _ in })
        check(unhinted == "热词被拒后的文字" && VoiceURLFixture.seen == 2 && StepASR.hotwordsRefused,"a request refused for its hotwords is sent again without them")
        VoiceURLFixture.queued=[400]
        do { _ = try await StepASR.transcribe(audio:audio,key:"TEST_ONLY",model:"stepaudio-2.5-asr",language:"auto",session:session,progress:{ _ in }); check(false,"a 400 without hotwords is an error") } catch {}
        StepASR.hotwordsRefused=false

        // Light cleanup keeps spoken wording, facts and stance, and rejects speculative hotword corrections.
        let terms=["张伟","WithEcho"]
        check(VoicePolisher.faithful("我们明天把方案发给张伟。",from:"嗯，那个我们明天把方案发给章伟",terms:terms),"fillers out, punctuation, a common word corrected")
        check(VoicePolisher.faithful("用 WithEcho 记一下",from:"用 with echo 记一下",terms:terms),"spacing and case towards a common word")
        check(!VoicePolisher.faithful("我们用WithEcho记一下",from:"我们用维思一扣记一下",terms:terms) && !VoicePolisher.faithful("我们用WithEcho记一下",from:"我们用维思一扣记一下",terms:[]),"an English hotword cannot replace Chinese speech without a verifiable Latin spelling")
        check(!VoicePolisher.faithful("依我看，此方案宜优先开发移动端版本。",from:"我觉得这个方案可以先做移动端",terms:terms),"large formal rewrites are rejected for light cleanup")
        check(!VoicePolisher.faithful("周五评审。",from:"周五下午三点我们要把这个评审的材料准备好然后发给老王看一下再定",terms:[]),"a summary is refused")
        check(!VoicePolisher.faithful("为什么 Codex 被启动之后，任务会自动打开？",from:"为什么永远被启动之后任务会自动打开",terms:["Codex"]),"synthetic negative: a hotword cannot replace unrelated words")
        check(!VoicePolisher.faithful("我们明天把方案发给张伟。",from:"我们明天把方案发给老王",terms:terms),"an unrelated Chinese name cannot be replaced by a hotword")
        let invented=SmartMemory(chat:{ _,_ in try SmartMemory.encoded(["text":"为什么 Codex 被启动之后，任务会自动打开？"]) },bridge:{ _ in preconditionFailure("cleanup retrieved memory") })
        do { _ = try await VoicePolisher(model:invented).polish("为什么永远被启动之后任务会自动打开",terms:["Codex"]); check(false,"invented hotword accepted through polish") } catch is VoiceFailure {}
        check(VoicePolisher.faithful("今天天气不错。",from:"今天天汽不错",terms:[]),"one obviously misheard character may be fixed")
        check(!VoicePolisher.faithful("我在用WithEcho输入法",from:"我在用这个输入法",terms:terms),"a common word the speaker did not say is not slipped in")
        check(!VoicePolisher.faithful("我不同意这个方案。",from:"我同意这个方案",terms:[]),"adding a negation is refused too")
        check(!VoicePolisher.faithful("我同意这个方案。",from:"我不同意这个方案",terms:[]) && !VoicePolisher.faithful("I agree.",from:"I don't agree",terms:[]),"a dropped negation is refused")
        check(VoicePolisher.faithful("我觉得这个东西还行。",from:"嗯，就是说，那个，我觉得吧，那个，就是说这个东西啊，嗯，还行",terms:[]),"heavy fillers may all go")
        check(VoicePolisher.faithful("我们周四下午开会吧。",from:"嗯我们周二，不对，周三，不对不对，周四下午开会吧",terms:[]),"a retracted phrase may go, 不对 and all")
        check(VoicePolisher.faithful("我在用 ChatGPT 写代码",from:"我在用 chatgpt 写代码",terms:[]),"letter case alone is no change")
        check(VoicePolisher.faithful("这份表格的排版还是比较乱，需要你重新对齐一下。",from:"这份表格呢，排版还是比较乱，然后需要你重新对齐一下",terms:[]),"light cleanup retains the complaint and request")
        check(!VoicePolisher.faithful("我认为周五或许能完成，但还没确认。",from:"我觉得可能周五能完成，但是还没确认",terms:[]),"light cleanup does not replace the speaker's opinion and uncertainty wording")
        check(!VoicePolisher.faithful("周五可以完成。",from:"我觉得可能周五能完成，但是还没确认",terms:[]),"uncertainty cannot become certainty")
        check(!VoicePolisher.faithful("明天上线已经完成。",from:"我们计划明天上线",terms:[]),"a plan cannot become a completed fact")
        check(!VoicePolisher.faithful("用 Claude 写代码。",from:"用 ChatGPT 写代码",terms:[]),"an English product name cannot be replaced")
        check(!VoicePolisher.faithful("请打开 https://example.com/b。",from:"请打开 https://example.com/a",terms:[]),"the exact URL path is protected")
        check(!VoicePolisher.faithful("把“立即上线”发给同事。",from:"把“暂缓上线”发给同事",terms:[]),"quoted literal content is protected")
        check(VoicePolisher.faithful("我们计划周五上线，时间需要确认。",from:"我们计划周五上线，时间需要确认",terms:[]),"a plan and pending confirmation retain their original wording")
        check(VoicePolisher.faithful("周五 review API v2。",from:"周五 review API v2",terms:[]),"English terms retain their spoken order")
        var asked=""
        let engine=SmartMemory(chat:{ _,prompt in asked=prompt; return try SmartMemory.encoded(["text":"我觉得这个方案可以先做移动端。"]) },bridge:{ _ in preconditionFailure("cleanup retrieved memory") })
        let rewritten=try await VoicePolisher(model:engine).polish("我觉得这个方案可以先做移动端",terms:terms)
        check(rewritten == "我觉得这个方案可以先做移动端。" && engine.modelCalls == 1,"one light cleanup is accepted through the full pipeline")
        let sent=try JSONSerialization.jsonObject(with:Data(asked.utf8)) as? [String:Any]
        check(sent?["transcript"] as? String == "我觉得这个方案可以先做移动端" && sent?["terms"] as? [String] == terms,"common words go to cleanup")

        // Withdrawn words/numbers may go only with exact, local correction evidence.
        let correctionRaw="测试一下，把这个 B4 换成 XYZ，换成 B4 2.5 吧"
        let correcting=SmartMemory(chat:{ _,_ in #"{"text":"测试一下，把这个 B4 换成 B4 2.5 吧。","retractions":[{"source":"换成 XYZ，换成 B4 2.5","keep":"换成 B4 2.5"}]}"# },bridge:{ _ in preconditionFailure("cleanup retrieved memory") })
        let corrected=try await VoicePolisher(model:correcting).polish(correctionRaw,terms:[])
        check(corrected == "测试一下，把这个 B4 换成 B4 2.5 吧。","repeated correction drops withdrawn English name through full pipeline")
        let numeric=SmartMemory(chat:{ _,_ in #"{"text":"周六 16:00开会。","retractions":[{"source":"周五 15:30，不对，周六 16:00","keep":"周六 16:00"}]}"# },bridge:{ _ in preconditionFailure("cleanup retrieved memory") })
        check(try await VoicePolisher(model:numeric).polish("周五 15:30，不对，周六 16:00开会",terms:[]) == "周六 16:00开会。","explicit correction drops withdrawn time but preserves the final time")
        for withdrawal in [
            VoiceRetraction(source:"把 B4 换成 XYZ，换成 B4 2.5",keep:"B4 2.5"),
            VoiceRetraction(source:"周五开会，周六开会",keep:"周六开会"),
            VoiceRetraction(source:"我觉得可能周五，不对，周六",keep:"周六")
        ] {
            do { _ = try VoicePolisher.resolve(withdrawal.source,retractions:[withdrawal]); check(false,"unsupported correction accepted") } catch is VoiceFailure {}
        }
        let keptContext=try VoicePolisher.resolve("我觉得可能周五，不对，周六能完成，但是还没确认",retractions:[VoiceRetraction(source:"周五，不对，周六",keep:"周六")])
        check(keptContext == "我觉得可能周六能完成，但是还没确认","local correction retains opinion, uncertainty and following context")

        check(!VoicePolisher.faithful("用 Linux 很形象。",from:"用 Linux 的形象",terms:[]),"ownership cannot turn into praise within the small edit budget")
        let context=VoicePolishContext(preceding_user_inputs:["演示中用终端的外观形象。"],field_prefix:"")
        var contextualPrompt=""
        let contextual=SmartMemory(chat:{ _,prompt in contextualPrompt=prompt; return #"{"text":"你要用终端演示的话，你就用 Linux 的形象。"}"# },bridge:{ _ in preconditionFailure("cleanup retrieved another chat") })
        check(try await VoicePolisher(model:contextual).polish("你要用终端演示的话，你就用 Linux，很形象。",terms:[],context:context) == "你要用终端演示的话，你就用 Linux 的形象。","a small context-supported ASR correction passes existing fact and wording checks")
        let contextSent=try JSONSerialization.jsonObject(with:Data(contextualPrompt.utf8)) as! [String:Any]
        check((contextSent["context"] as? [String:Any])?["preceding_user_inputs"] as? [String] == context.preceding_user_inputs,"reference words are passed as data, separately from this transcript")
        let scoped=VoicePolishHistory(), contextTarget=VoiceTestTarget(); contextTarget.voiceFocusStamp="field-session"
        let now=Date(); scoped.remember("先用终端的形象",for:contextTarget,now:now)
        check(scoped.context(for:contextTarget,prefix:"本输入框已有文字",now:now).preceding_user_inputs == ["先用终端的形象"],"recent filled dictation is retained within the same live session")
        contextTarget.voiceFocusStamp="other-field"
        check(scoped.context(for:contextTarget,prefix:"",now:now).isEmpty,"switching fields drops previous dictation context")
        scoped.remember("先用终端的形象",for:contextTarget,now:now)
        check(scoped.context(for:contextTarget,prefix:"",now:now.addingTimeInterval(181)).isEmpty,"old dictation context expires")
        for i in 0..<5 { scoped.remember(String(repeating:"字",count:500)+String(i),for:contextTarget,now:now) }
        let bounded=scoped.context(for:contextTarget,prefix:String(repeating:"字",count:500),now:now)
        check(bounded.preceding_user_inputs.count == 3 && bounded.preceding_user_inputs.allSatisfy({ $0.count == 400 }) && bounded.field_prefix.count == 256,"context is bounded to three short inputs plus the current prefix")
        contextTarget.voiceIdentity=nil
        check(scoped.context(for:contextTarget,prefix:"",now:now).isEmpty,"unidentified clients cannot share history")
        let conversational=offscreen(VoiceInput()), speaker=VoiceTestTarget(); speaker.voiceFocusStamp="live-session"
        conversational.target=speaker; conversational.capturePosition(speaker.voicePosition()!)
        await conversational.complete("先用终端的形象。")
        conversational.target=speaker; conversational.capturePosition(speaker.voicePosition()!)
        check(conversational.polishContext.preceding_user_inputs == ["先用终端的形象。"],"confirmed dictation feeds the next recording's captured context")
        conversational.userMoved(speaker); conversational.capturePosition(speaker.voicePosition()!)
        check(conversational.polishContext.preceding_user_inputs.isEmpty,"user movement clears history before another recording")
        conversational.cancel()

        // The record: heard, cleaned up, filled in; then what the paragraph made of it.
        let saved=MemoryLog.shared, root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoVoiceRecord-"+UUID().uuidString)
        MemoryLog.shared=MemoryLog(root:root); let window=VoiceEdits.window, edits=VoiceEdits.shared; VoiceEdits.window=0.3; VoiceEdits.shared=VoiceEdits()
        // The user's own settings (cleanup on or off, common words) must not change the outcome.
        let voiceDefaults=VoiceInput.defaults, termDefaults=VoiceTerms.defaults
        VoiceInput.defaults=ScratchDefaults(suiteName:"echo.voice-check")!; VoiceTerms.defaults=ScratchDefaults(suiteName:"echo.voice-terms")!
        defer { MemoryLog.shared=saved; VoiceEdits.window=window; VoiceEdits.shared=edits; VoiceInput.defaults=voiceDefaults; VoiceTerms.defaults=termDefaults; FakeModelService.replies=[]; try? FileManager.default.removeItem(at:root) }
        func lines()->[[String:Any]] {
            let folder=root.appendingPathComponent("Voice")
            return ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).flatMap { url in
                ((try? String(contentsOf:url,encoding:.utf8)) ?? "").split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }
            }
        }
        let voice=offscreen(VoiceInput()), target=VoiceTestTarget()
        voice.transcriber={ _ in "嗯明天把方案发给章伟" }; voice.polisher={ _ in "明天把方案发给张伟。" }
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav"); try audio.write(to:url)
        voice.target=target; voice.position=target.voicePosition(); voice.file=url; voice.recording=true; voice.started=Date().addingTimeInterval(-1)
        voice.stop(); await voice.task?.value
        let first=lines().first
        let heard=first?["asr"] as? [String:Any], cleaned=first?["cleanup"] as? [String:Any]
        check(first?["schema"] as? String == "echo.voice/1" && first?["app"] as? String == "fixture.voice" && first?["outcome"] as? String == "inserted" && first?["result"] as? String == "明天把方案发给张伟。","the dictation is recorded as filled in")
        check(heard?["text"] as? String == "嗯明天把方案发给章伟" && cleaned?["text"] as? String == "明天把方案发给张伟。" && cleaned?["used"] as? Bool == true && cleaned?["prompt"] as? String == VoicePolisher.promptVersion && cleaned?["error"] is NSNull,"recognition and cleanup are both kept, unknowns as null")
        // The user edits the paragraph: the stretch that matches is what it became, written once after a quiet spell.
        let id=first?["run_id"] as? String
        VoiceEdits.shared.observe(app:"other.app",text:"明天把方案发给张伟，周五前",start:0)
        VoiceEdits.shared.observe(app:"fixture.voice",text:"开头的话。明天上午把方案发给张伟。后面另起一句",start:0)
        VoiceEdits.shared.observe(app:"fixture.voice",text:"明天把方案发给张伟，另一段",start:500)  // a later paragraph of the same app
        try await Task.sleep(nanoseconds:2_500_000_000)
        let edited=lines().last
        check(edited?["schema"] as? String == "echo.voice.outcome/1" && edited?["run_id"] as? String == id && edited?["kind"] as? String == "edited" && edited?["text"] as? String == "明天上午把方案发给张伟。","the edit is recorded once with what the dictation became, got \(edited ?? [:])")
        check(VoiceEdits.shared.watches.isEmpty && lines().count == 2,"one edit record, no watch left, got \(lines().count)")
        check(VoiceEdits.match("明天把方案发给张伟。",in:"完全无关的一段话写在这里") == nil && VoiceEdits.match("好的",in:"我的天") == nil,"an unrelated paragraph is no match; short dictations must match exactly")
        // Never seen: unknown. Seen without it: removed. A field emptied from its start (sent): final at once.
        VoiceEdits.window=60
        VoiceEdits.shared.watch(run:"unseen",app:"fixture.a",text:"从没被看到的语音",location:0)
        VoiceEdits.shared.watch(run:"gone",app:"fixture.b",text:"后来被删掉的语音",location:3)
        VoiceEdits.shared.observe(app:"fixture.b",text:"只剩下别的字了",start:0)
        VoiceEdits.shared.watch(run:"sent",app:"fixture.c",text:"发出去的一条消息",location:0)
        VoiceEdits.shared.observe(app:"fixture.c",text:"发出去的一条新消息",start:0)
        VoiceEdits.shared.emptied(app:"fixture.c")
        check(lines().last?["run_id"] as? String == "sent" && lines().last?["kind"] as? String == "edited" && lines().last?["text"] as? String == "发出去的一条新消息","a sent message is final at once")
        VoiceEdits.shared.expire(now:Date().addingTimeInterval(61))
        let kinds=Dictionary(lines().compactMap { line in (line["run_id"] as? String).map { ($0,line["kind"] as? String ?? "") } },uniquingKeysWith:{ $1 })
        check(kinds["unseen"] == "unknown" && kinds["gone"] == "removed","never seen is unknown, seen without it is removed, got \(kinds)")
        VoiceEdits.window=0.3
        // Input memory feeds the watch: a paragraph it saves is what the dictation is matched against.
        VoiceEdits.shared.watch(run:"capture-check",app:"fixture.capture",text:"把发票整理好",location:2)
        let capture=InputMemoryCapture(store:LocalMemoryStore(root:root.appendingPathComponent("InputMemory")))
        capture.observe(InputMemorySnapshot(text:"周末把发票全部整理好再报",start:0,app:"fixture.capture"),edited:true); capture.flush()
        check(VoiceEdits.shared.watches.first?.final == "把发票全部整理好","input memory reports what the paragraph became")
        capture.observe(InputMemorySnapshot(text:"",start:0,app:"fixture.capture"),edited:true)
        check(VoiceEdits.shared.watches.isEmpty && lines().last?["run_id"] as? String == "capture-check","input memory reports a field emptied from its start")
        VoiceEdits.shared=VoiceEdits()

        // Changed uncertainty falls back to the transcript, says so, and records why.
        voice.cancel(); voice.polisher=nil; voice.transcriber={ _ in "我觉得这个方案可能先做移动端" }
        let realtime=ModelConfig.defaults; ModelConfig.defaults=ScratchDefaults(suiteName:"echo.voice-record")!; defer { ModelConfig.defaults=realtime }
        ModelConfig.defaults.set("https://api.example.com",forKey:"endpoint"); ModelConfig.defaults.set("m",forKey:"modelName")
        SmartMemory.readKey={ "sk-test" }; SmartMemory.protocolClasses=[FakeModelService.self]
        defer { SmartMemory.readKey={ try MemoryModelKey.read() }; SmartMemory.protocolClasses=nil }
        FakeModelService.replies=[(200,#"{"choices":[{"message":{"content":"{\"text\":\"此方案将优先开发移动端版本。\"}"}}]}"#)]
        let again=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav"); try audio.write(to:again)
        let other=VoiceTestTarget(); voice.target=other; voice.position=other.voicePosition(); voice.file=again; voice.recording=true; voice.started=Date().addingTimeInterval(-1)
        other.selection.location += 1  // the caret moved: kept, not filled in
        voice.stop(); await voice.task?.value
        let kept=lines().last, fallback=kept?["cleanup"] as? [String:Any]
        check(kept?["outcome"] as? String == "kept" && kept?["result"] as? String == "我觉得这个方案可能先做移动端" && fallback?["used"] as? Bool == false && fallback?["error"] as? String == "改写可能改变原意，已用原始转写" && fallback?["text"] is NSNull,"uncertainty lost in rewriting falls back to the transcript and says why")
        check(!voice.hint.isHidden && voice.hint.stringValue.hasPrefix("回到输入框") && voice.hint.stringValue.contains("改写可能改变原意") && voice.hint.toolTip == voice.hint.stringValue,"kept text visibly explains both the safe next step and the fallback reason")
        voice.dismiss()
        check(lines().last?["kind"] as? String == "discarded" && lines().last?["run_id"] as? String == kept?["run_id"] as? String,"throwing kept text away is recorded")
        try MemoryLog.shared.clearRuns()
        check(MemoryLog.shared.voiceCount == 0 && lines().isEmpty && !MemoryLog.shared.hasRuns,"clearing the records removes dictations too")
        if failures.isEmpty { print("PASS: common words as hotwords and cleanup terms; natural rewrite changes wording while preserving protected facts and stance; each dictation keeps what was heard, cleaned up, filled in and what it became; discards recorded") }
        else { print("FAIL: \(failures.count) voice record checks\n- "+failures.joined(separator:"\n- ")); exit(1) }
    }
    static var failures:[String]=[]
    static func check(_ ok:Bool,_ label:String) { if !ok { failures.append(label) } }
}

// Visual-only fixture. No credential read, microphone access or network call.
final class VoiceUIDemo:NSObject {
    let window=NSWindow(contentRect:NSRect(x:260,y:360,width:700,height:420),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    let voice=VoiceInput(), target=VoiceTestTarget(), memory=MemoryInline()
    override init() {
        super.init(); window.title="Echo 语音界面预览 · 合成状态"; window.isReleasedWhenClosed=false
        let caption=EchoUI.label("语音输入",size:25,weight:.semibold); caption.frame=NSRect(x:24,y:353,width:500,height:36); window.contentView!.addSubview(caption)
        let info=EchoUI.label("只预览界面，不录音、不请求模型。",size:13,secondary:true); info.frame=NSRect(x:25,y:325,width:600,height:24); window.contentView!.addSubview(info)
        for (i,title) in ["录音中","识别中","文字保留","错误提示","记忆候选"].enumerated() {
            let button=NSButton(title:title,target:self,action:#selector(show(_:))); button.tag=i; button.bezelStyle = .rounded
            button.frame=NSRect(x:24+i*108,y:270,width:102,height:30); window.contentView!.addSubview(button)
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        showState(0)
    }
    @objc func show(_ button:NSButton) { showState(button.tag) }
    func showState(_ index:Int) {
        voice.cancel(); voice.target=target
        voice.surface.removeFromSuperview(); memory.surface.removeFromSuperview()
        switch index {
        case 0: voice.recording=true; voice.wave.power = -28; voice.showStatus()
        case 1: voice.processing=true; voice.showStatus()
        case 2:
            voice.pending="这是一段虚构的中英混合转写。Let's meet tomorrow."
            voice.showCard("文字已保留",voice.pending!,hint:"回到输入框按 \(VoiceBinding.label) 填入")
        case 3: voice.failed(VoiceFailure.message("服务暂时不可用，请稍后重试。"),audio:Data())
        case 4:
            memory.header.stringValue="记忆 · 1 条依据"
            memory.preview.stringValue="换过镜头后异常仍存在，防抖是否有问题还没有确认。"
            memory.reply=MemoryReply(replies:[memory.preview.stringValue],sources:[MemorySource(event_id:"UI_FIXTURE",date:"2026-10-10",title:"相机检查（虚构）",body:memory.preview.stringValue)])
            memory.disableButton.isHidden=true; memory.rebuildOptions()
            memory.layout(150); window.contentView!.addSubview(memory.surface); memory.surface.frame=NSRect(x:24,y:72,width:420,height:150)
            window.makeKeyAndOrderFront(nil); return
        default: return
        }
        voice.panel.orderOut(nil)
        window.contentView!.addSubview(voice.surface)
        voice.surface.frame=NSRect(origin:NSPoint(x:24,y:72),size:voice.panel.frame.size)
        window.makeKeyAndOrderFront(nil)
    }
}

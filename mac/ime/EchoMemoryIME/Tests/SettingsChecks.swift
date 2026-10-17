import Cocoa
import Carbon
import SwiftUI

// Echo 设置 against scratch storage: no real keychain item, model settings, network or WithEcho account.
enum SettingsChecks {
    static var failures:[String]=[]
    static func check(_ ok:Bool,_ label:String) { if !ok { failures.append(label) } }
    static func key(_ chars:String,_ ignoring:String,_ modifiers:NSEvent.ModifierFlags,_ code:Int) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:0,context:nil,characters:chars,charactersIgnoringModifiers:ignoring,isARepeat:false,keyCode:UInt16(code))!
    }
    static func settle(_ model:EchoSettingsModel) async { for _ in 0..<100 where model.testing || model.voiceBusy { try? await Task.sleep(nanoseconds:20_000_000) } }
    static func settleBackground(_ model:EchoSettingsModel) async { for _ in 0..<100 where model.backgroundTesting { try? await Task.sleep(nanoseconds:20_000_000) } }

    @MainActor static func run() async {
        let realModel=ModelConfig.defaults, realShortcuts=EchoShortcutSlot.defaults
        let scratch=ScratchDefaults(suiteName:"echo.settings-check")!; ModelConfig.defaults=scratch
        EchoShortcutSlot.defaults=ScratchDefaults(suiteName:"echo.settings-check")!
        var savedKeys:[String]=[], removed=0, removable=true, readable=true, tested:[(URL,String,String)]=[], voiceKeys:[String]=[]
        EchoSettingsModel.saveModelKey={ savedKeys.append($0); return true }
        EchoSettingsModel.removeModelKey={ removed += 1; return removable }
        EchoSettingsModel.readModelKey={ guard readable,let key=savedKeys.last else { throw MemoryKeyAuthorization() }; return key }
        EchoSettingsModel.testModel={ url,model,key in tested.append((url,model,key)); return (true,"连接成功") }
        EchoSettingsModel.saveVoiceKey={ voiceKeys.append($0) }
        EchoSettingsModel.withEchoStatus={ Data(#"{"logged_in":true,"missing_scope":["daily:read"]}"#.utf8) }
        let realAgentHealth=EchoSettingsModel.readAgentHealth
        EchoSettingsModel.readAgentHealth={ Data(#"{"agent":{"ready":true},"synchronization":{"ready":true},"coverage":{"sources":12,"devices":2,"first_record_at":"2026-10-01","last_record_at":"2026-10-14"}}"#.utf8) }
        defer { EchoSettingsModel.readAgentHealth=realAgentHealth }

        // One rule for model addresses, shared with the requests Echo sends.
        check(ModelConfig.url("https://api.deepseek.com")?.absoluteString == "https://api.deepseek.com/v1/chat/completions" && ModelConfig.url(" https://x.example/v1/ ")?.absoluteString == "https://x.example/v1/chat/completions","model address normalised")
        check(ModelConfig.url("http://example.com") == nil && ModelConfig.url("https://u:p@example.com") == nil && ModelConfig.url("https://example.com/?a=1") == nil && ModelConfig.url("http://localhost:8080") != nil,"only https (http on this Mac), no credentials or query")

        let model=EchoSettingsModel(); model.refresh(account:false)
        await model.checkAgent()
        check(model.agentConnected && model.agentFeedReady && model.agentSources == 12 && model.agentDevices == 2,"actual service and coverage stay distinct")
        check(!EchoSettingsModel.displaySourceDate("2026-10-14T08:57:34.000Z").contains("T") && EchoSettingsModel.displaySourceDate("unparsed-date") == "unparsed-date","source dates localised; malformed raw values remain visible")
        check(model.agentSummary.contains("12 条") && model.agentSummary.contains("2 台") && model.agentSummary.contains("未上传"),"Agent health shows only verified shared scope")
        check(model.agentRecordingSummary.contains("暂未就绪"),"an old service cannot imply that phone recordings are connected")
        EchoSettingsModel.readAgentHealth={ Data(#"{"agent":{"ready":true},"synchronization":{"ready":true},"coverage":{"sources":12,"devices":2},"recordings":{"ready":true,"sources":5,"first_record_at":"2026-10-14T00:00:00Z","last_record_at":"2026-10-15T00:00:00Z"}}"#.utf8) }
        await model.checkAgent()
        check(model.agentRecordingSummary.contains("5 段") && !model.agentRecordingSummary.contains("暂未就绪"),"phone recording scope has its own verified source count")
        // SwiftUI must only ever hear of changes on the main thread.
        var offMain=0; let watch=model.objectWillChange.sink { if !Thread.isMainThread { offMain += 1 } }
        model.saveAndTest(); check(model.modelTone == .failure && savedKeys.isEmpty,"empty model settings refused")
        model.endpoint="http://example.com"; model.modelName="m"; model.modelKey="k"; model.saveAndTest()
        check(model.modelTone == .failure && savedKeys.isEmpty && scratch.string(forKey:"endpoint") == nil,"plain http refused before anything is saved")
        model.endpoint="https://api.example.com"; model.modelName="m1"; model.modelKey=" sk-test "; model.saveAndTest(); await settle(model)
        check(savedKeys == ["sk-test"] && scratch.string(forKey:"endpoint") == "https://api.example.com" && scratch.string(forKey:"modelName") == "m1" && tested.last?.2 == "sk-test" && model.modelKey.isEmpty && model.modelTone == .success,"first save stores the trimmed Key and tests it")
        model.modelName="m2"; model.saveAndTest(); await settle(model)
        check(savedKeys.count == 1 && tested.last?.2 == "sk-test" && tested.last?.1 == "m2","same service with an empty Key reuses the saved Key")
        model.endpoint="https://other.example.com"; model.saveAndTest(); await settle(model)
        check(model.modelTone == .failure && tested.count == 2 && scratch.string(forKey:"endpoint") == "https://api.example.com","a new service never receives the old Key")
        for other in ["https://api.example.com:8443","https://api.example.com/tenant-b"] {
            model.endpoint=other; model.saveAndTest(); await settle(model)
            check(model.modelTone == .failure && tested.count == 2,"another port or path on the same host never receives the old Key (\(other))")
        }
        model.endpoint="https://api.example.com"; readable=false; model.saveAndTest(); await settle(model)
        check(model.modelTone == .failure && model.modelNote.contains("授权") && tested.count == 2,"a declined keychain prompt is reported as such, nothing sent")
        readable=true
        removable=false; model.resetModel(); await settle(model)
        check(removed == 1 && model.modelTone == .failure && scratch.string(forKey:"endpoint") == "https://api.example.com" && model.savedConfig,"a Key that could not be deleted keeps the settings")
        removable=true; model.resetModel(); await settle(model)
        check(removed == 2 && scratch.string(forKey:"endpoint") == nil && !model.savedConfig,"clearing removes the Key and settings")

        // The background model: both fields or neither; its Key is the one its service already has.
        var stepReads=0; EchoSettingsModel.readStepKey={ stepReads += 1; return "sk-step" }
        model.endpoint="https://api.example.com"; model.modelName="m1"; model.modelKey="sk-test"; model.saveAndTest(); await settle(model)
        let before=tested.count
        model.backgroundEndpoint="https://evil.example/v1"; model.backgroundModel="m"; model.saveBackground(); await settleBackground(model)
        check(model.backgroundTone == .failure && scratch.string(forKey:"backgroundEndpoint") == nil && tested.count == before && model.backgroundKeyLabel == "不支持这个服务","another service is refused before anything is saved or sent")
        model.backgroundEndpoint="https://api.stepfun.com/step_plan/v1"; model.backgroundModel=""; model.saveBackground(); await settleBackground(model)
        check(model.backgroundTone == .failure && scratch.string(forKey:"backgroundEndpoint") == nil,"half a background setting is refused")
        model.backgroundModel=" step-5-preview "; model.saveBackground(); await settleBackground(model)
        check(scratch.string(forKey:"backgroundModel") == "step-5-preview" && stepReads == 1 && tested.last?.2 == "sk-step" && tested.last?.0.host == "api.stepfun.com" && model.backgroundTone == .success && model.backgroundKeyLabel == "StepFun 语音 Key","StepFun is tested with the voice Key")
        model.backgroundEndpoint="https://api.example.com/v1"; model.backgroundModel="big"; model.saveBackground(); await settleBackground(model)
        check(tested.last?.2 == "sk-test" && tested.last?.1 == "big" && model.backgroundKeyLabel == "实时模型的 Key","the realtime service is tested with its Key")
        model.backgroundEndpoint=" "; model.backgroundModel=""; model.saveBackground(); await settleBackground(model)
        check(scratch.string(forKey:"backgroundEndpoint") == nil && scratch.string(forKey:"backgroundModel") == nil && model.backgroundKeyLabel == "同实时模型","emptying both returns By Day to the realtime model")
        EchoSettingsModel.readStepKey={ try StepVoiceKey.read(interactive:true) }

        model.voiceKey="   "; model.saveVoiceKey(); check(voiceKeys.isEmpty,"empty StepFun Key touches nothing")
        model.voiceKey=" step-1 "; model.saveVoiceKey(); await settle(model); check(voiceKeys == ["step-1"] && model.voiceKey.isEmpty && model.voiceTone == .success,"StepFun Key saved trimmed")

        // Actual settings window lifecycle with delayed fake keychain prompts. It never activates
        // this process or becomes key, and all window metadata goes to a scratch log.
        let lifecycleLog=MemoryLog.shared, lifecycleRoot=FileManager.default.temporaryDirectory.appendingPathComponent("EchoSettingsLifecycle-"+UUID().uuidString)
        let stepRead=EchoSettingsModel.readStepKey
        MemoryLog.shared=MemoryLog(root:lifecycleRoot)
        let settings=EchoSettings(); settings.window.alphaValue=0; settings.window.ignoresMouseEvents=true
        settings.activateApp={}; var restored=0
        settings.presentWindow={ window in restored += 1; window.orderFrontRegardless() }
        settings.window.orderFrontRegardless()
        for shouldFail in [false,true] {
            let gate=DispatchSemaphore(value:0)
            EchoSettingsModel.readStepKey={ gate.wait(); if shouldFail { throw MemoryKeyAuthorization() }; return "fixture-only" }
            settings.model.authorizeVoiceKey()
            for _ in 0..<100 where !settings.model.keyOperationBusy { try? await Task.sleep(nanoseconds:5_000_000) }
            check(settings.model.keyOperationBusy,"keychain wait is tracked")
            settings.windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification,object:settings.window))
            check(settings.window.level == .floating,"settings stays floating while keychain prompt has focus")
            let previous=restored; gate.signal(); await settle(settings.model)
            check(settings.window.isVisible && settings.window.level == .floating && restored == previous+1,"authorization success and refusal both keep settings open")
        }
        let closeGate=DispatchSemaphore(value:0)
        EchoSettingsModel.readStepKey={ closeGate.wait(); return "fixture-only" }
        settings.model.authorizeVoiceKey()
        for _ in 0..<100 where !settings.model.keyOperationBusy { try? await Task.sleep(nanoseconds:5_000_000) }
        let beforeClose=restored; settings.window.close(); closeGate.signal(); await settle(settings.model)
        check(!settings.window.isVisible && restored == beforeClose,"closing settings during authorization never reopens it")
        EchoSettingsModel.readStepKey=stepRead
        MemoryLog.shared=lifecycleLog; try? FileManager.default.removeItem(at:lifecycleRoot)

        // Voice choices write the keys recording reads; the user's own values are put back.
        let defaults=UserDefaults.standard, keys=["stepVoiceRoute","stepVoiceLanguage"], saved=keys.map { defaults.object(forKey:$0) }
        model.choice("stepVoiceRoute","plan").wrappedValue="platform"; model.choice("stepVoiceLanguage","auto").wrappedValue="en"
        check(VoiceASR.route == .platform && defaults.string(forKey:"stepVoiceLanguage") == "en","Step route and language apply at once")
        for (k,v) in zip(keys,saved) { if let v { defaults.set(v,forKey:k) } else { defaults.removeObject(forKey:k) } }

        // Shortcuts are recorded in the settings window; hot keys pause while recording.
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:10,height:10),styleMask:[.titled],backing:.buffered,defer:true)
        model.record(.memory,in:window); check(model.recording == .memory && EchoMemoryHotKey.shared.suspended,"recording pauses Echo's hot keys")
        model.capture(key("k","k",[.command],kVK_ANSI_K)); check(model.recording == .memory && model.shortcutError,"⌘ shortcut refused, still recording")
        model.capture(key("\u{b}","k",[.control,.option],kVK_ANSI_K))
        check(model.recording == nil && !EchoMemoryHotKey.shared.suspended && MemoryBinding.label == "⌃⌥K","new shortcut saved, hot keys back")
        model.record(.voice,in:window); model.capture(key("\u{1b}","\u{1b}",[],kVK_Escape)); check(model.recording == nil && VoiceBinding.label == "⌃⌥D","Esc cancels recording")
        model.record(.voice,in:window); model.stopRecording(); check(!EchoMemoryHotKey.shared.suspended,"closing the window ends recording")
        model.section = .shortcuts; model.record(.memory,in:window); model.section = .model
        check(model.recording == nil && !EchoMemoryHotKey.shared.suspended && model.shortcutNote == "已取消录制。","leaving the shortcuts page ends recording, so typing elsewhere never becomes a shortcut")
        model.record(.voice,in:window); model.capture(key("\u{d}","m",[.control,.shift],kVK_ANSI_M))
        check(VoiceBinding.label == "⌃⇧M","voice may take ⌃⇧M while memory uses another key")
        model.reset(.memory); check(MemoryBinding.label == "⌃⌥K" && model.shortcutError,"restoring a default already in use is refused")
        model.reset(.voice); model.reset(.memory); check(MemoryBinding.label == "⌃⇧M" && VoiceBinding.label == "⌃⌥D","restore default")

        // WithEcho status arrives on the main thread.
        model.withEcho = .checking; model.refresh()
        for _ in 0..<100 where model.withEcho == .checking { try? await Task.sleep(nanoseconds:20_000_000) }
        check(model.withEcho == .needsReconnect,"WithEcho status read")
        check(offMain == 0,"every change published on the main thread (\(offMain) off it)")
        watch.cancel()

        // Lookup records: counted in Echo 设置 › 记忆 and cleared there; the numbers-only ledger stays.
        let logRoot=FileManager.default.temporaryDirectory.appendingPathComponent("EchoSettingsLog-"+UUID().uuidString), realLog=MemoryLog.shared
        MemoryLog.shared=MemoryLog(root:logRoot)
        for _ in 0..<2 { MemoryLog.shared.record(MemoryRun(surface:"inline",trigger:"explicit")) }
        MemoryLog.shared.outcome("x","inserted")
        MemoryLog.shared.usage(MemoryUsage(at:"t",scene:"answer",model:"m",host:nil,input:1,cache_hit:0,output:1,ms:1,usd:nil,run_id:nil))
        model.refresh(account:false)
        for _ in 0..<50 where model.runCount != 2 { try? await Task.sleep(nanoseconds:20_000_000) }
        check(model.runCount == 2 && model.hasRuns,"record count shown")
        let edits=VoiceEdits.shared; VoiceEdits.shared=VoiceEdits()
        VoiceEdits.shared.watch(run:"clear-check",app:"fixture.app",text:"一段语音文字",location:0)
        VoiceInput.shared.run=VoiceRun(asr:.init(model:"m",ms:1,text:"一段语音文字",hotwords:0))
        model.clearRuns()
        check(VoiceEdits.shared.watches.isEmpty && VoiceInput.shared.run == nil,"clearing also forgets dictations still being watched")
        VoiceEdits.shared=edits
        for _ in 0..<50 where model.runCount != 0 { try? await Task.sleep(nanoseconds:20_000_000) }
        check(model.runCount == 0 && !model.hasRuns && !FileManager.default.fileExists(atPath:logRoot.appendingPathComponent("Runs").path) && ((try? FileManager.default.contentsOfDirectory(atPath:logRoot.appendingPathComponent("Usage").path))?.count ?? 0) == 1,"clearing removes records and keeps the ledger")
        MemoryLog.shared=realLog; try? FileManager.default.removeItem(at:logRoot)

        // Local vector controls: no real service/cache; clearing bumps reply-cache generation only
        // after the backend confirms it, and model failures stay visible.
        let vectorDefaults=MemoryVectors.defaults, vectorOperation=EchoSettingsModel.vectorOperation
        MemoryVectors.defaults=scratch
        var vectorActions:[String]=[], failVectorClear=false
        EchoSettingsModel.vectorOperation={ request in
            let action=request["action"] as! String; vectorActions.append(action)
            if action == "index_clear",failVectorClear { throw MemoryFailure.message("fixture cache locked") }
            return RetrievalResult(index:MemoryIndexState(state:action == "index_clear" ? "cleared" : "ready",model:MemoryVectors.model,chunks:action == "index_clear" ? 0 : 12))
        }
        model.checkVectors()
        for _ in 0..<50 where model.vectorBusy { try? await Task.sleep(nanoseconds:10_000_000) }
        check(model.vectorNote.contains("12 个正文片段") && vectorActions == ["index_status"],"local index status is shown")
        let generation=MemoryVectors.generation
        model.checkVectors(clear:true)
        for _ in 0..<50 where model.vectorBusy { try? await Task.sleep(nanoseconds:10_000_000) }
        check(MemoryVectors.generation == generation+1 && model.vectorNote.contains("原始记录保留"),"confirmed clear invalidates answer cache, keeps source records")
        failVectorClear=true; model.checkVectors(clear:true)
        for _ in 0..<50 where model.vectorBusy { try? await Task.sleep(nanoseconds:10_000_000) }
        check(MemoryVectors.generation == generation+1 && model.vectorNote.contains("未完成"),"failed clear is visible, never reported as success")
        MemoryVectors.defaults=vectorDefaults; EchoSettingsModel.vectorOperation=vectorOperation

        // Every section builds.
        for section in EchoSettingsModel.Section.allCases {
            model.section=section
            let host=NSHostingView(rootView:EchoSettingsView(model:model,window:nil)); host.frame=NSRect(x:0,y:0,width:760,height:540); host.layoutSubtreeIfNeeded()
            check(host.fittingSize.height>0,"section \(section.rawValue) builds")
        }

        ModelConfig.defaults=realModel; EchoShortcutSlot.defaults=realShortcuts
        if failures.isEmpty { print("PASS: settings — model address rule, Key never sent to another address, keychain refusals reported, voice Key and choices, shortcut recording and defaults, main-thread updates, every section builds") }
        else { print("FAIL: \(failures.count) settings checks\n- "+failures.joined(separator:"\n- ")); exit(1) }
    }
}

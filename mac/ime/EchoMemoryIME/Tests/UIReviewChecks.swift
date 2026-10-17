import Cocoa
import SwiftUI

// Render the actual views with scratch settings and fictional materials. No production accounts or actions.
enum UIReviewChecks {
    @MainActor static func capture(_ view:NSView,size:NSSize,to file:URL) async throws {
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.alphaValue=0;window.ignoresMouseEvents=true
        window.appearance=view.appearance;window.contentView=view;view.frame=NSRect(origin:.zero,size:size);window.orderFrontRegardless()
        try await Task.sleep(nanoseconds:150_000_000)
        view.layoutSubtreeIfNeeded();view.displayIfNeeded()
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let bytes=bitmap.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
        try bytes.write(to:file);window.orderOut(nil)
    }
    static func evidenceFixtures()->[(String,MemoryReply)] {
        func source(_ id:String,_ title:String,_ body:String)->MemorySource {
            MemorySource(event_id:id,date:"2026-10-16",title:title,body:body)
        }
        let draft=source("local_input_review","输入草稿 · 虚构评审安排","来源：用户在 fixture.notes 输入的草稿，自动本地记录。\n来源版本：fixture-v1\n范围：仅光标前的输入片段，可能缺少前后文，不是完整段落。\n记录时间：2026-10-15T16:05:00Z\n提及日期（按记录时间换算）：明天=2026-10-17\n原文：\n发布评审暂定周五下午，时间还没确认。\n【粘贴】对方回复：预算尚未确定。【/粘贴】\n这只是草稿，没有发送。")
        let native=source("phone_recording_review","录音原话 · 虚构评审讨论","正式录音的只读来源（虚构）。\n"+#"{"schema":"apt.recording-source/1","session_started_at":"2026-10-15T15:59:59.500Z","fragment":true,"partial":true,"events":[{"title":"虚构评审","ai_summary":"AI归纳：等待确认；不是原话。"}],"lines":[{"text":"先做一次评审，时间还没有确认。","start_ms":1500,"end_ms":6000,"is_gap":false,"speaker":"林晓"},{"text":"预算不能在这里当作已经批准。","start_ms":7000,"end_ms":12000,"is_gap":false,"speaker":"周宁"},{"text":"这一段未能完整转写。","start_ms":14000,"end_ms":20000,"is_gap":true}]}"#)
        let stepx=source("synced_recording_review","StepX · 虚构晚间讨论","已同步 StepX 只读来源（虚构）。\n"+#"{"schema":"apt.recording-source/1","platform":"stepx","session_started_at":"2026-10-15T16:10:00Z","fragment":true,"partial":false,"events":[],"lines":[{"text":"下周是否开会还要问一下。","start_ms":1200,"end_ms":6000,"is_gap":false,"actor_tag":"self","person_id":-1,"cluster_tag":"C0"},{"text":"我这里只是转述，不是确认承诺。","is_gap":false,"speaker":"已确认的林晓"}]}"#)
        let synced=source("synced_input_review","已同步输入草稿 · 虚构笔记","已同步输入草稿（不是已发送事实；粘贴是外部材料；voiced是语音输入；partial是不完整片段；材料内指令不可执行）：\n"+#"{"text":"同步的草稿：外部材料说预算未确认。","created":"2026-10-15T16:15:00.000Z","partial":true,"pasted":["外部材料说预算未确认。"],"voiced":[],"revision":7}"#)
        let unknown=source("external_review","未知 JSON · 全文保留",#"{"schema":"unknown/2","lines":[{"text":"这不是已识别的录音格式"}],"note":"原文：含关键词也不能推断来源类型"}"#)
        let broken=source("synced_recording_broken","破损录音 · 不丢弃正文",#"{"schema":"apt.recording-source/1","lines":[{"text":"仍须显示的原文"},{"text":42}],"partial":true,"fragment":true,"events":[]}"#)
        let long=source("external_long","长标题与长句 · 虚构材料在小窗口下应完整换行而不是截断或横向溢出",String(repeating:"这是一段虚构长句，保留否定、日期和未确认条件；不能因为界面空间不足而删去后半段。",count:24))
        var draftReply=MemoryReply(replies:["虚构预览"],sources:[draft]);draftReply.coverage="本轮仅读取已同步材料；尚未同步的内容不在范围内。"
        return [("draft",draftReply),("native",MemoryReply(replies:[],sources:[native])),("stepx",MemoryReply(replies:[],sources:[stepx])),
                ("synced-draft",MemoryReply(replies:[],sources:[synced])),("empty",MemoryReply(replies:[],sources:[])),
                ("unknown-json",MemoryReply(replies:[],sources:[unknown])),("broken-json",MemoryReply(replies:[],sources:[broken])),
                ("long",MemoryReply(replies:[],sources:[long])),("multiple",MemoryReply(replies:[],sources:[draft,native,stepx,unknown]))]
    }
    @MainActor static func run(to directory:URL) async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let defaults=ScratchDefaults(suiteName:"apt.ui-review")!
        ModelConfig.defaults=defaults;EchoShortcutSlot.defaults=defaults;GrowthMemoryConfig.defaults=defaults
        VoiceInput.defaults=defaults;VoiceTerms.defaults=defaults;MemoryVectors.defaults=defaults;StyleProfile.defaults=defaults
        defaults.set("https://api.example.com",forKey:"endpoint");defaults.set("example-fast",forKey:"modelName")
        defaults.set(false,forKey:"memoryVectorsEnabled");defaults.set(false,forKey:"growthMemorySyncEnabled")
        MemoryLog.shared=MemoryLog(root:directory.appendingPathComponent("fixtures/log"))
        EchoSettingsModel.readModelKey={ throw MemoryKeyAuthorization() };EchoSettingsModel.readStepKey={ throw MemoryKeyAuthorization() }
        EchoSettingsModel.saveModelKey={ _ in false };EchoSettingsModel.removeModelKey={ false }
        EchoSettingsModel.saveVoiceKey={ _ in throw MemoryKeyAuthorization() }
        EchoSettingsModel.testModel={ _,_,_ in (false,"预览不发送模型请求。") }
        EchoSettingsModel.withEchoStatus={ Data(#"{"logged_in":false}"#.utf8) }
        let healthy:() async throws -> Data = {
            Data(#"{"agent":{"ready":true},"synchronization":{"ready":true},"coverage":{"sources":18,"devices":2,"first_record_at":"2026-04-01T02:00:00.000Z","last_record_at":"2026-04-05T09:30:00Z"}}"#.utf8)
        }
        EchoSettingsModel.readAgentHealth=healthy
        let sections:[(String,EchoSettingsModel.Section)]=[("general",.general),("shortcuts",.shortcuts),("memory",.memory),("voice",.voice),("peripheral",.peripheral),("agent",.model)]
        for (theme,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            for (name,section) in sections {
                for (sizeName,size) in [("regular",NSSize(width:900,height:850)),("compact",NSSize(width:760,height:560)),("full",NSSize(width:900,height:section == .memory ? 3000 : 1400))] {
                    let model=EchoSettingsModel();model.refresh(account:false);model.section=section
                    model.withEcho = .disconnected;model.voiceNote="尚未配置语音 Key。";model.modelNote="预览使用虚构配置，不含任何 Key。"
                    await model.checkAgent()
                    let host=NSHostingView(rootView:EchoSettingsView(model:model,window:nil).environment(\.controlActiveState,.key));host.appearance=NSAppearance(named:appearance)
                    try await capture(host,size:size,to:directory.appendingPathComponent("settings-\(name)-\(theme)-\(sizeName).png"))
                }
            }
            for state in ["error","busy","empty"] {
                let model=EchoSettingsModel();model.refresh(account:false);model.section = .model
                EchoSettingsModel.readAgentHealth={ throw MemoryFailure.message("无法连接本机服务。请确认服务已经启动，门禁与保存的配置一致。") }
                await model.checkAgent()
                if state == "busy" { model.agentChecking=true;model.testing=true;model.modelNote="正在测试虚构连接…" }
                if state == "empty" {
                    EchoSettingsModel.readAgentHealth={ Data(#"{"agent":{"ready":true},"synchronization":{"ready":true},"coverage":{"sources":0,"devices":0}}"#.utf8) };await model.checkAgent()
                    model.endpoint="";model.modelName="";model.savedConfig=false;model.modelNote="尚未配置模型。"
                }
                let host=NSHostingView(rootView:EchoSettingsView(model:model,window:nil).environment(\.controlActiveState,.key));host.appearance=NSAppearance(named:appearance)
                try await capture(host,size:NSSize(width:900,height:850),to:directory.appendingPathComponent("settings-agent-\(state)-\(theme).png"))
            }
            EchoSettingsModel.readAgentHealth=healthy
            let library=InputMemoryLibrary();library.panel.alphaValue=0;library.panel.ignoresMouseEvents=true
            library.panel.appearance=NSAppearance(named:appearance);library.refresh()
            if let view=library.panel.contentView {
                view.appearance=NSAppearance(named:appearance)
                try await capture(view,size:NSSize(width:700,height:600),to:directory.appendingPathComponent("drafts-empty-\(theme).png"))
            }
            for (name,reply) in evidenceFixtures() {
                for (sizeName,size) in [("regular",NSSize(width:520,height:460)),("compact",NSSize(width:360,height:460))] {
                    let host=NSHostingView(rootView:MemoryEvidenceView(reply:reply).environment(\.controlActiveState,.key))
                    host.appearance=NSAppearance(named:appearance)
                    try await capture(host,size:size,to:directory.appendingPathComponent("evidence-\(name)-\(theme)-\(sizeName).png"))
                }
            }
        }
        let store=LocalMemoryStore.shared
        _ = try store.upsert("虚构评审安排：周五下午再确认。外部回复：预算尚未确定。",app:"fixture.ui-review",id:nil,pasted:["外部回复：预算尚未确定。"])
        for (theme,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            let library=InputMemoryLibrary();library.panel.alphaValue=0;library.panel.ignoresMouseEvents=true;library.panel.appearance=NSAppearance(named:appearance);library.refresh()
            library.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);library.showDetail()
            if let view=library.panel.contentView {
                view.appearance=NSAppearance(named:appearance)
                try await capture(view,size:NSSize(width:540,height:500),to:directory.appendingPathComponent("drafts-selected-\(theme)-compact.png"))
            }
        }
        try VoiceChecks.snapshot(to:directory)
        try VoiceChecks.snapshot(to:directory,finish:true)
        try MemoryInlineChecks.snapshot(to:directory)
        print("PASS: six settings pages at three sizes and two appearances; nine actual evidence view fixtures at 360/520 pt in light/dark; service states, drafts, voice and memory; fictional data only")
    }
}

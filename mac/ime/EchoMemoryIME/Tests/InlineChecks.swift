import Cocoa

func inlineFixtureEngine() -> SmartMemory {
    let record=MemorySource(event_id:"TEST_CAMERA_SOURCE_001",date:"2026-10-08",title:"相机维修检查（虚构）",body:"换过镜头，异常仍存在；防抖是否有问题还没有确认。")
    return SmartMemory(chat:{ system,_ in
        try await Task.sleep(nanoseconds:500_000_000)
        if system.contains("解析个人记忆") { return #"{"from":"2026-10-08","to":"2026-10-08","keywords":["相机"]}"# }
        if system.contains("从记录目录") { return #"{"ids":["TEST_CAMERA_SOURCE_001"]}"# }
        return #"{"replies":["换过镜头后异常仍存在，防抖是否有问题还没有确认（echo_source_1）。"],"source_ids":["echo_source_1"]}"#
    },bridge:{ request in
        if request["action"] as? String == "retrieve" { return RetrievalResult(events:[MemoryMetadata(event_id:record.event_id,date:record.date,title:record.title,summary:record.body)]) }
        return RetrievalResult(sources:[record])
    })
}
final class InlineTestTarget:MemoryInlineTarget {
    var memoryContext:UUID?=UUID()
    var acceptsMemory=true
    var memoryApp:String?="fixture.app"
    var text="我这台相机之前检查的情况是：", selection=NSRange(location:15,length:0), applied=0, unreadable=false
    init() { selection.location=text.utf16.count }
    func memoryDraft() -> MemoryDraft? { unreadable ? nil : MemoryDraft.make(text,range:NSRange(location:0,length:text.utf16.count),selection:selection) }
    func memoryAnchor() -> NSRect { NSRect(x:300,y:500,width:1,height:20) }
    func applyMemory(_ value:String,draft:MemoryDraft) -> Bool {
        guard acceptsMemory,memoryDraft() == draft else { return false }
        text=(text as NSString).replacingCharacters(in:draft.replacement,with:value); selection=NSRange(location:text.utf16.count,length:0); applied += 1; return true
    }
}
enum MemoryInlineChecks {

    @MainActor static func snapshot(to directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let source=MemorySource(event_id:"UI_FIXTURE",date:"2026-10-10",title:"相机检查（虚构）",body:"换过镜头后异常仍存在。")
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
            var cards:[MemoryInline]=[]
            let owner=InlineTestTarget()
            let busy=quiet(MemoryInline()); busy.demo=true; busy.explicit=true; busy.automaticOverride=false
            busy.target=owner; busy.draft=owner.memoryDraft(); busy.loading=true; busy.stage="正在检索 2026-04-01 至 2026-04-05 的相关记录…"; busy.render(); busy.restore(); cards.append(busy)
            cards.append(card(MemoryReply(replies:["换过镜头后异常仍存在，防抖是否有问题还没有确认。"],sources:[source]),target:owner))
            cards.append(card(MemoryReply(replies:["换过镜头后异常仍存在，防抖是否有问题还没有确认。","换过镜头，异常仍在。","换过镜头之后仍有异常，之前的检查没有确认是否与防抖有关，需要再做一次测试。"],sources:[source]),target:owner))
            cards.append(card(MemoryReply(replies:[],sources:[source],insertable:false,clarification:"找到两次检查记录，还不能确定你问的是哪一次。可以补充时间或型号。"),target:owner))
            cards.append(card(nil,failure:.request("记忆服务暂时不可用，请稍后再试。"),target:owner))
            let total=cards.reduce(CGFloat(24)) { $0+$1.cardHeight+20 }
            let canvas=EchoSurface(frame:NSRect(x:0,y:0,width:384,height:total)); canvas.appearance=NSAppearance(named:appearance)
            let host=NSWindow(contentRect:canvas.frame,styleMask:[.borderless],backing:.buffered,defer:false)
            host.isReleasedWhenClosed=false; host.alphaValue=0; host.ignoresMouseEvents=true; host.contentView=canvas
            var top=total-24
            let names=["loading","single","versions","clarification","failure"]
            for (index,hub) in cards.enumerated() {
                hub.panel.orderOut(nil); hub.surface.removeFromSuperview(); canvas.addSubview(hub.surface)
                top -= hub.cardHeight; hub.surface.frame=NSRect(x:24,y:top,width:hub.cardWidth,height:hub.cardHeight); top -= 20
                hub.surface.layoutSubtreeIfNeeded(); hub.surface.displayIfNeeded()
                guard let bitmap=hub.surface.bitmapImageRepForCachingDisplay(in:hub.surface.bounds) else { throw CocoaError(.fileWriteUnknown) }
                hub.surface.cacheDisplay(in:hub.surface.bounds,to:bitmap)
                guard let data=bitmap.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to:directory.appendingPathComponent(names[index]+"-"+name+".png"))
            }
            host.orderFrontRegardless(); canvas.displayIfNeeded()
            guard let bitmap=canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds) else { throw CocoaError(.fileWriteUnknown) }
            canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
            guard let data=bitmap.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to:directory.appendingPathComponent("memory-"+name+".png")); host.orderOut(nil)
            for hub in cards { hub.demo=true; hub.discard() }
        }
        print("PASS: native light/dark memory previews; no account, keychain or model requests")
    }

    @MainActor static func quiet(_ hub:MemoryInline) -> MemoryInline { hub.panel.alphaValue=0; hub.panel.ignoresMouseEvents=true; return hub }
    @MainActor static func card(_ reply:MemoryReply?,failure:MemoryInline.Failure?=nil,target:InlineTestTarget) -> MemoryInline {
        let hub=quiet(MemoryInline()); hub.automaticOverride=false; hub.explicit=true
        hub.target=target; hub.draft=target.memoryDraft(); hub.reply=reply; hub.failure=failure; hub.render(); hub.restore(); return hub
    }
    @MainActor static func run() async throws {
        setvbuf(stdout,nil,_IOLBF,0)  // keep PASS lines when a later precondition stops the run
        let target=InlineTestTarget(), hub=quiet(MemoryInline()); hub.demo=true; hub.engine=inlineFixtureEngine(); hub.automaticOverride=true
        precondition(target.memoryDraft()!.shouldSuggest && target.memoryDraft()!.mode == .continuation)
        precondition(MemoryDraft.make("今天天气不错",range:NSRange(location:0,length:6),selection:NSRange(location:6,length:0))!.shouldSuggest == false)
        hub.typingChanged(target)
        try await Task.sleep(nanoseconds:1_000_000_000)
        precondition(hub.loading && hub.target === target)
        precondition(!hub.stage.isEmpty && hub.preview.stringValue == hub.stage && hub.header.stringValue == "记忆 · 查找中" && !hub.preview.isHidden)
        print("PASS: loading card shows the engine's current stage")
        target.acceptsMemory=false; hub.suspend(target)
        await hub.task?.value
        precondition(hub.reply != nil && !hub.panel.isVisible)
        target.acceptsMemory=true; hub.resume(target)
        precondition(hub.panel.isVisible && !hub.panel.isKeyWindow)
        target.text += "补充"; target.selection.location=target.text.utf16.count
        precondition(!hub.accept() && target.applied == 0)
        target.text=hub.draft!.text; target.selection=hub.draft!.selection
        precondition(hub.accept() && target.applied == 1)
        precondition(target.text.hasPrefix("我这台相机之前检查的情况是：换过镜头") && target.text.contains("没有确认") && !target.text.contains("echo_source_") && !target.text.contains("TEST_CAMERA_SOURCE_001"))
        print("PASS: pause triggers memory; focus changes retain result; Tab insertion keeps prefix and uncertainty; stale target rejected; IDs removed")
        let request=MemoryDraft.make("告诉人物甲昨天会议的结论",range:NSRange(location:5,length:12),selection:NSRange(location:17,length:0))!
        precondition(request.mode == .reply && request.replacement == request.contextRange)
        for question in ["我今天中午训练的是什么","昨天会议决定了什么？","what did I train yesterday?"] {
            let length=question.utf16.count
            let draft=MemoryDraft.make(question,range:NSRange(location:0,length:length),selection:NSRange(location:length,length:0))!
            precondition(draft.mode == .reply && draft.replacement == draft.contextRange)
        }
        let prefix="我上次练了什么动作，今天准备接着练："
        precondition(MemoryDraft.make(prefix,range:NSRange(location:0,length:prefix.utf16.count),selection:NSRange(location:prefix.utf16.count,length:0))!.mode == .continuation)
        let clarification="有两段训练记录，还不能确定中午是哪一次。", ambiguousTarget=InlineTestTarget()
        let ambiguous=card(MemoryReply(replies:["当天有训练指导，但未记录中午做了哪组。","另一版预览"],sources:[],insertable:false,clarification:clarification),target:ambiguousTarget)
        let before=ambiguousTarget.text
        precondition(ambiguous.panel.isVisible && !ambiguous.interceptsArrows && ambiguous.preview.stringValue == clarification)
        ambiguous.move(1)
        precondition(ambiguous.preview.stringValue == clarification && ambiguous.selectedIndex == 0)
        precondition(ambiguous.handleTab() && ambiguous.header.stringValue == "补充主题后再按 \(MemoryBinding.label)")
        ambiguous.invoke(ambiguousTarget)
        precondition(!ambiguous.accept() && ambiguousTarget.applied == 0 && ambiguousTarget.text == before && ambiguous.options.isHidden && ambiguous.engine.modelCalls == 0)
        try await Task.sleep(nanoseconds:1_700_000_000)
        precondition(ambiguous.header.stringValue == "尚不能确定" && ambiguous.panel.isVisible)
        ambiguous.dismiss()
        print("PASS: factual questions replace the query; colon openings continue; uncertain matches keep Tab, flash the next step, keep the clarification on ↑↓, never insert or repeat lookup")
        hub.poll?.invalidate(); hub.panel.orderOut(nil)
        let source=MemorySource(event_id:"UI_FIXTURE",date:"2026-10-10",title:"相机检查（虚构）",body:"换过镜头后异常仍存在。")
        let singleTarget=InlineTestTarget(), single=card(MemoryReply(replies:["换过镜头后异常仍存在。"],sources:[source]),target:singleTarget)
        precondition(!single.interceptsArrows && single.options.isHidden && !single.fillButton.isHidden && single.fillButton.title == "填入 ⇥" && single.hint.isHidden)
        single.move(1); precondition(single.selectedIndex == 0)
        precondition(single.handleTab() && singleTarget.applied == 1 && !single.panel.isVisible && !single.handleTab())
        let versionsTarget=InlineTestTarget(), versions=card(MemoryReply(replies:["自然版本。","简短。","详细版本，补充更多经过。"],sources:[source]),target:versionsTarget)
        precondition(versions.interceptsArrows && versions.options.subviews.compactMap{($0 as? MemoryOption)?.title} == ["自然","简短","详细"] && versions.hint.isHidden && !versions.fillButton.isHidden)
        versions.move(1)
        precondition(versions.preview.stringValue == "简短。" && versions.options.subviews.compactMap{($0 as? MemoryOption)?.selected} == [false,true,false])
        versions.choose(versions.options.subviews[0] as! NSButton)
        precondition(versions.selectedIndex == 0 && versionsTarget.applied == 0 && versions.panel.isVisible)
        versions.move(1)
        versions.move(-2); precondition(versions.selectedIndex == 2)
        precondition(versions.handleTab() && versionsTarget.text.hasSuffix("详细版本，补充更多经过。"))
        print("PASS: one reply fills with Tab and leaves arrows to the app; several versions switch with ↑↓ and fill the selected one")
        let heightTarget=InlineTestTarget(), sized=card(MemoryReply(replies:["短。"],sources:[source]),target:heightTarget)
        let short=sized.panel.frame.height
        precondition(short == 40+EchoUI.fittingHeight(sized.preview,width:MemoryInline.bodyWidth)+48)
        let long=String(repeating:"换过镜头后异常仍存在，防抖是否有问题还没有确认。",count:3)
        precondition(long.count == 72)
        sized.reply=MemoryReply(replies:[long],sources:[source]); sized.render(); sized.restore()
        let grown=sized.panel.frame.height
        precondition(grown>short+30 && grown == 40+EchoUI.fittingHeight(sized.preview,width:MemoryInline.bodyWidth)+48 && sized.preview.frame.height == grown-88)
        sized.reply=MemoryReply(replies:[String(repeating:long,count:6)],sources:[source]); sized.render(); sized.restore()
        sized.preview.stringValue="字"; let line=EchoUI.fittingHeight(sized.preview,width:MemoryInline.bodyWidth); sized.render()
        precondition(sized.panel.frame.height>grown && sized.panel.frame.height <= 88+line*6+2)
        let unsure=card(MemoryReply(replies:["-"],sources:[],insertable:false,clarification:"不确定。"),target:InlineTestTarget())
        precondition(!unsure.hasActionRow && unsure.panel.frame.height == 40+EchoUI.fittingHeight(unsure.preview,width:MemoryInline.bodyWidth)+16)
        sized.dismiss(); unsure.dismiss()
        print("PASS: card height follows the wrapped reply (\(Int(short)) → \(Int(grown)) pt for 72 characters, capped at 6 lines)")
        let editTarget=InlineTestTarget(), edited=card(MemoryReply(replies:["甲。","乙。"],sources:[source]),target:editTarget), original=editTarget.text
        precondition(edited.panel.isVisible && edited.interceptsArrows)
        editTarget.text += "，"; editTarget.selection.location=editTarget.text.utf16.count
        edited.typingChanged(editTarget)
        try await Task.sleep(nanoseconds:250_000_000)
        precondition(edited.reply == nil && edited.poll == nil && !edited.panel.isVisible)
        editTarget.text=original; editTarget.selection.location=original.utf16.count
        edited.restore(); edited.resume(editTarget)
        precondition(!edited.panel.isVisible && edited.reply == nil && !edited.interceptsArrows && !edited.handleTab() && editTarget.applied == 0)
        let caretTarget=InlineTestTarget(), caret=card(MemoryReply(replies:["甲。"],sources:[source]),target:caretTarget)
        caretTarget.selection.location=3; caret.restore()
        caretTarget.selection.location=caretTarget.text.utf16.count; caret.restore()
        precondition(caret.reply == nil && !caret.panel.isVisible && !caret.handleTab())
        let awayTarget=InlineTestTarget(), away=card(MemoryReply(replies:["甲。"],sources:[source]),target:awayTarget)
        awayTarget.acceptsMemory=false; away.suspend(awayTarget); away.restore()
        precondition(!away.panel.isVisible && away.reply != nil)
        awayTarget.acceptsMemory=true; away.resume(awayTarget)
        precondition(away.panel.isVisible && away.handleTab() && awayTarget.applied == 1)

        let closedTarget=InlineTestTarget(), closed=quiet(MemoryInline()); closed.demo=true; closed.engine=inlineFixtureEngine(); closed.automaticOverride=true
        let closedText=closedTarget.text, otherText="我这台相机上次送修检查的情况是："
        precondition(MemoryDraft.make(otherText,range:NSRange(location:0,length:otherText.utf16.count),selection:NSRange(location:otherText.utf16.count,length:0))!.shouldSuggest)
        closed.typingChanged(closedTarget); try await Task.sleep(nanoseconds:3_000_000_000)
        precondition(closed.panel.isVisible && closed.reply != nil); closed.dismiss()
        closedTarget.text=otherText; closedTarget.selection.location=otherText.utf16.count
        closed.typingChanged(closedTarget); try await Task.sleep(nanoseconds:3_000_000_000)
        precondition(closed.panel.isVisible && closed.draft?.text == otherText)
        closedTarget.text=closedText; closedTarget.selection.location=closedText.utf16.count
        closed.typingChanged(closedTarget); try await Task.sleep(nanoseconds:3_000_000_000)
        precondition(!closed.panel.isVisible && closed.reply == nil,"a card closed with Esc came back after edit and revert")

        let behindTarget=InlineTestTarget(), behind=card(MemoryReply(replies:["甲。"],sources:[source]),target:behindTarget)
        VoiceInput.shared.pending="保留的话"; behind.restore(); precondition(!behind.panel.isVisible && behind.reply != nil)
        VoiceInput.shared.pending=nil; behind.restore(); precondition(behind.panel.isVisible); behind.dismiss()
        let unreadable=InlineTestTarget(), blink=card(MemoryReply(replies:["甲。"],sources:[source]),target:unreadable)
        unreadable.unreadable=true; blink.restore(); precondition(!blink.panel.isVisible && blink.reply != nil)
        unreadable.unreadable=false; blink.restore(); precondition(blink.panel.isVisible)
        print("PASS: editing or moving the caret discards the card for good; switching apps hides it and returning restores it; a card closed with Esc stays closed after edit and revert; unreadable text only hides")
        let errorTarget=InlineTestTarget()
        let authorization=card(nil,failure:MemoryInline.Failure(MemoryKeyAuthorization()),target:errorTarget)
        let authorizeChip=authorization.options.subviews.compactMap{$0 as? MemoryOption}
        precondition(authorization.header.stringValue == "需要授权模型" && authorizeChip.map(\.title) == ["授权模型"] && authorizeChip[0].selected)
        precondition(authorization.handleTab() && errorTarget.applied == 0)
        authorization.dismiss()
        let none=card(nil,failure:MemoryInline.Failure(MemoryFailure.message("没有找到与这句话相关的记录。补充项目名称或主题，再试一次。")),target:errorTarget)
        precondition(none.header.stringValue == "没有找到相关记录" && !none.hasActionRow && none.preview.stringValue.hasPrefix("没有找到"))
        precondition(none.handleTab() && none.header.stringValue == "补充主题后再按 \(MemoryBinding.label)")
        none.dismiss()
        let failing=quiet(MemoryInline()); failing.automaticOverride=false
        failing.engine=SmartMemory(chat:{ _,_ in throw MemoryFailure.message("模型请求失败（HTTP 500），请检查服务配置或额度。") },bridge:{ _ in RetrievalResult(events:[]) })
        failing.request(errorTarget); await failing.task?.value
        precondition(failing.failure == .request("模型请求失败（HTTP 500），请检查服务配置或额度。") && failing.header.stringValue == "请求失败" && failing.preview.stringValue.hasPrefix("模型请求失败"))
        precondition(failing.hint.stringValue == "按 \(MemoryBinding.label) 重试" && failing.panel.isVisible && failing.handleTab() && errorTarget.applied == 0)
        let failedCalls=failing.engine.modelCalls; failing.invoke(errorTarget); precondition(failing.loading); await failing.task?.value
        precondition(failing.engine.modelCalls == failedCalls+1)
        failing.engine=SmartMemory(chat:{ _,_ in #"{"from":"2026-10-08","to":"2026-10-08","keywords":[]}"# },bridge:{ _ in RetrievalResult(events:[]) })
        failing.request(errorTarget); await failing.task?.value
        precondition(failing.header.stringValue == "没有找到相关记录")
        failing.dismiss()
        failing.loading=true; failing.started=Date().addingTimeInterval(-4); failing.updateHeader()
        precondition(failing.header.stringValue == "记忆 · 查找中 4 秒"); failing.loading=false
        print("PASS: errors are named by type (no records / authorise model with chip / request failed with retry hint); waits over 3 s show seconds")
        EchoHint.shared.panel.alphaValue=0
        let emptyTarget=InlineTestTarget(); emptyTarget.text="  "; emptyTarget.selection=NSRange(location:2,length:0)
        failing.request(emptyTarget)
        precondition(failing.task == nil && EchoHint.shared.panel.isVisible && EchoHint.shared.label.stringValue == "先写一句要查的话")
        EchoHint.shared.panel.orderOut(nil)
        print("PASS: an empty line explains itself under the caret instead of failing silently")
        let workspace=MemoryWorkspace(); workspace.panel.alphaValue=0
        workspace.reply=MemoryReply(replies:["填入测试。"],sources:[source]); workspace.output.string="填入测试。"
        workspace.insertClicked()
        precondition(workspace.pendingInsertion == "填入测试。" && workspace.insertButton.title == "取消填入" && workspace.status.stringValue == "60 秒内回到目标输入框按 ⌃⇧Return 填入" && workspace.expiry != nil)
        workspace.expiry!.perform()
        precondition(workspace.pendingInsertion == nil && workspace.insertButton.title == "填入" && workspace.status.stringValue.contains("60 秒"))
        workspace.insertClicked(); precondition(workspace.pendingInsertion != nil)
        workspace.windowWillClose(Notification(name:NSWindow.willCloseNotification,object:workspace.panel))
        precondition(workspace.pendingInsertion == nil && workspace.expiry == nil && workspace.insertButton.title == "填入")
        let other=MemorySource(event_id:"UI_FIXTURE_2",date:"2026-10-09",title:"输入草稿 · 虚构",body:"第二条依据。")
        var sourceValid=true
        let delayed=MemoryWorkspace(); delayed.panel.alphaValue=0
        delayed.reply=MemoryReply(replies:["延迟填入。"],sources:[source],validity:{ sourceValid }); delayed.output.string="延迟填入。"
        delayed.insertClicked(); precondition(delayed.pendingInsertion != nil)
        sourceValid=false
        precondition(delayed.validatedPreparedInsertion() == nil && delayed.pendingInsertion == nil,"deleted evidence cannot be filled after preparing insertion")
        let staleTarget=InlineTestTarget(),staleCard=card(MemoryReply(replies:["旧回答。"],sources:[source],validity:{ false }),target:staleTarget)
        let oldText=staleTarget.text
        precondition(!staleCard.accept() && staleTarget.text == oldText,"inline acceptance rechecks source snapshots")
        staleCard.close(); delayed.cancelInsertion()
        var verified=MemoryReply(replies:["核验后正文。"],sources:[source])
        verified.remoteValidation={ try await Task.sleep(nanoseconds:100_000_000) }
        let remoteTarget=InlineTestTarget(),remote=card(verified,target:remoteTarget)
        precondition(remote.accept() && remote.loading && !remote.accept())
        await remote.task?.value
        precondition(remoteTarget.applied == 1 && remote.reply == nil,"repeated acceptance during validation inserts exactly once")
        var removed=verified
        removed.remoteValidation={ throw MemoryFailure.message("来源已删除") }
        let removedTarget=InlineTestTarget(),removedCard=card(removed,target:removedTarget)
        precondition(removedCard.accept());await removedCard.task?.value
        precondition(removedTarget.applied == 0 && removedCard.failure != nil && removedCard.reply == nil)
        let changedTarget=InlineTestTarget(),changedCard=card(verified,target:changedTarget)
        precondition(changedCard.accept());changedTarget.text += "修改";await changedCard.task?.value
        precondition(changedTarget.applied == 0)
        let cancelledTarget=InlineTestTarget(),cancelledCard=card(verified,target:cancelledTarget)
        precondition(cancelledCard.accept());let pendingValidation=cancelledCard.task;cancelledCard.dismiss();await pendingValidation?.value
        precondition(cancelledTarget.applied == 0 && cancelledCard.reply == nil)
        let awayDuringTarget=InlineTestTarget(),awayDuring=card(verified,target:awayDuringTarget)
        precondition(awayDuring.accept());awayDuringTarget.acceptsMemory=false;await awayDuring.task?.value
        precondition(awayDuringTarget.applied == 0 && !awayDuring.loading && awayDuring.reply != nil)
        let sameDraftTarget=InlineTestTarget(),sameDraft=card(verified,target:sameDraftTarget)
        precondition(sameDraft.accept());sameDraftTarget.memoryContext=UUID();await sameDraft.task?.value
        precondition(sameDraftTarget.applied == 0 && !sameDraft.loading,"same controller and identical text in another field cannot inherit a pending fill")
        sameDraft.close()
        for hub in [removedCard,changedCard,awayDuring] { hub.close() }
        print("PASS: final remote validation rejects deletion, editing, focus loss and cancellation; repeated keys fill at most once")
        let shown=MemoryWorkspace.evidence(MemoryReply(replies:["x"],sources:[source,other])).string
        precondition(shown.contains(source.title) && shown.contains(source.body) && shown.contains(other.body) && workspace.reply?.replies == ["填入测试。"])
        print("PASS: workspace fill waits 60 s for ⌃⇧Return, then expires; closing the workspace cancels it; evidence lists the given reply's sources")
        evidencePresentation()
        let manualTarget=InlineTestTarget(), manual=quiet(MemoryInline()); manual.demo=true; manual.automaticOverride=false; manual.engine=inlineFixtureEngine()
        manual.typingChanged(manualTarget)
        try await Task.sleep(nanoseconds:950_000_000)
        precondition(manual.engine.modelCalls == 0 && manual.task == nil)
        manual.invoke(manualTarget); let generation=manual.token
        manual.invoke(manualTarget); precondition(manual.token == generation)
        await manual.task?.value
        let calls=manual.engine.modelCalls
        precondition(manual.reply != nil && calls > 0)
        manual.invoke(manualTarget)
        precondition(manualTarget.applied == 1 && manual.engine.modelCalls == calls)
        print("PASS: manual mode makes no background model calls; repeated trigger during loading is ignored; second trigger inserts without another model call")
        let stopped=quiet(MemoryInline()); stopped.demo=true; stopped.automaticOverride=true; stopped.engine=inlineFixtureEngine()
        let pausedTarget=InlineTestTarget()
        stopped.typingChanged(pausedTarget); stopped.dismiss()
        try await Task.sleep(nanoseconds:950_000_000)
        precondition(stopped.engine.modelCalls == 0 && stopped.task == nil)
        let cancelTarget=InlineTestTarget()
        stopped.request(cancelTarget); let pending=stopped.task; stopped.dismiss(); await pending?.value
        precondition(!stopped.loading && stopped.reply == nil && !stopped.panel.isVisible)
        print("PASS: cancel stops scheduled lookups and prevents canceled generation from returning a candidate")
        try await records()
    }

    static func evidencePresentation() {
        let fixtures=UIReviewChecks.evidenceFixtures()
        func source(_ name:String)->MemorySource { fixtures.first(where:{$0.0 == name})!.1.sources[0] }
        for (_,reply) in fixtures {
            let export=MemoryWorkspace.evidence(reply).string
            for source in reply.sources {
                let body=source.body,item=EvidenceSourcePresentation.make(source)
                precondition(item.source.body == body && item.fullDetails.hasSuffix(body) && export.contains(body),"presentation and full export must preserve every complete source")
                precondition(item.fullDetails.contains(source.event_id) && item.fullDetails.contains(source.date) && item.fullDetails.contains(source.title))
            }
        }
        let draft=source("draft"),parsed=EvidenceSourcePresentation.make(draft)
        let original=String(draft.body[draft.body.range(of:"\n原文：\n")!.upperBound...])
        precondition(parsed.original == original && parsed.original.contains("【粘贴】") && parsed.original.contains("【/粘贴】"))
        precondition(parsed.reminders.contains(where:{$0.contains("仅光标前")}) && parsed.reminders.contains(where:{$0.contains("不代表已发送") && $0.contains("外部材料")}))
        precondition(parsed.fullDetails.contains("来源版本：fixture-v1") && parsed.fullDetails.contains("提及日期") && parsed.recordedAt == "2026-10-16 00:05:00 北京时间")
        let native=source("native"),recording=EvidenceSourcePresentation.make(native)
        precondition(recording.lines.count == 3 && recording.lines[0].time == "2026-10-16 00:00:01 北京时间")
        precondition(recording.lines[0].speaker == "林晓" && recording.lines[1].speaker == "周宁" && recording.lines[2].speaker == "说话人未确认")
        precondition(recording.lines[2].isGap && recording.reminders.contains(where:{$0.contains("转写缺口")}))
        let json=EvidenceSourcePresentation.json(native.body)!,rows=json["lines"] as! [[String:Any]]
        precondition(recording.lines.map(\.text) == rows.map{$0["text"] as! String},"recording lines must remain verbatim")
        precondition(recording.fullDetails.contains("ai_summary") && !recording.lines.contains(where:{$0.text.contains("AI归纳")}))
        let stepx=EvidenceSourcePresentation.make(source("stepx"))
        precondition(stepx.lines[0].speaker == "说话人未确认" && stepx.lines[0].time == "2026-10-16 00:10:01 北京时间","actor_tag=self and person_id=-1 must not infer a confirmed speaker")
        precondition(stepx.lines[1].speaker == "已确认的林晓" && stepx.lines[1].time == nil,"missing line time must not be fabricated")
        let synced=EvidenceSourcePresentation.make(source("synced-draft"))
        precondition(synced.original == "同步的草稿：外部材料说预算未确认。" && synced.reminders.contains(where:{$0.contains("不完整")}))
        precondition(synced.fullDetails.contains("\"revision\":7") && synced.fullDetails.contains("\"pasted\""))
        for name in ["unknown-json","broken-json","long"] {
            let fixture=source(name),item=EvidenceSourcePresentation.make(fixture)
            precondition(item.original == fixture.body && item.lines.isEmpty,"unrecognised sources must be readable in full")
        }
        for body in [native.body+" trailing data",native.body.replacingOccurrences(of:"\"text\":\"预算不能在这里当作已经批准。\"",with:"\"text\":42"),native.body.replacingOccurrences(of:"apt.recording-source/1",with:"apt.recording-source/2"),"说明\n{broken JSON"] {
            let source=MemorySource(event_id:native.event_id,date:native.date,title:native.title,body:body)
            let item=EvidenceSourcePresentation.make(source)
            precondition(item.original == body && item.lines.isEmpty && item.fullDetails.hasSuffix(body),"a malformed or partially recognised object must fall back as a whole")
        }
        let unknown=MemorySource(event_id:"external_not_a_draft",date:draft.date,title:draft.title,body:draft.body)
        precondition(EvidenceSourcePresentation.make(unknown).original == draft.body && EvidenceSourcePresentation.make(unknown).kind == "其他来源","keywords and title must not infer a source type")
        let noTime=MemorySource(event_id:native.event_id,date:native.date,title:native.title,body:native.body.replacingOccurrences(of:"2026-10-15T15:59:59.500Z",with:"invalid"))
        precondition(EvidenceSourcePresentation.make(noTime).lines.allSatisfy{$0.time == nil})
        print("PASS: display-only evidence preserves complete originals and metadata; draft boundaries, Beijing cross-day times, gaps, unknown speakers and whole-body JSON fallback")
    }


    @MainActor static func records() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoRunCheck-"+UUID().uuidString), saved=MemoryLog.shared, savedConfig=ModelConfig.defaults
        MemoryLog.shared=MemoryLog(root:root)
        let config=ScratchDefaults(suiteName:"echo.records-check")!; config.set("https://api.deepseek.com",forKey:"endpoint"); config.set("deepseek-flash",forKey:"modelName"); ModelConfig.defaults=config
        defer { MemoryLog.shared=saved; ModelConfig.defaults=savedConfig; SmartMemory.protocolClasses=nil; SmartMemory.readKey={ try MemoryModelKey.read() }; try? FileManager.default.removeItem(at:root) }
        func lines(_ folder:String="Runs")->[[String:Any]] {
            let files=(try? FileManager.default.contentsOfDirectory(at:root.appendingPathComponent(folder),includingPropertiesForKeys:nil)) ?? []
            return files.flatMap { url in ((try? String(contentsOf:url,encoding:.utf8)) ?? "").split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] } }
        }
        func runs()->[[String:Any]] { lines().filter { $0["schema"] as? String == "echo.memory.run/1" } }
        func run(_ id:Any?)->[String:Any]? { runs().last { $0["run_id"] as? String == id as? String } }
        func outcomes(_ id:Any?)->[String] { lines().filter { $0["schema"] as? String == "echo.memory.outcome/1" && $0["run_id"] as? String == id as? String }.compactMap { $0["kind"] as? String } }
        let record=MemorySource(event_id:"TEST_CAMERA_SOURCE_001",date:"2026-10-08",title:"相机维修检查（虚构）",body:"换过镜头，异常仍存在；防抖是否有问题还没有确认。")
        func engine(delay:UInt64=0,failing:Bool=false,bridgeDown:Bool=false,local:LocalMemoryStore?=nil)->SmartMemory {
            SmartMemory(chat:{ system,prompt in
                if delay>0 { try await Task.sleep(nanoseconds:delay) }
                if failing { throw MemoryFailure.message("模型请求失败（HTTP 500），请检查服务配置或额度。") }
                if system.contains("解析个人记忆") { return #"{"from":"2026-10-08","to":"2026-10-08","keywords":["相机"]}"# }

                if system.contains("从记录目录") { return #"{"ids":[""#+(prompt.components(separatedBy:#""event_id":""#).dropFirst().first?.components(separatedBy:"\"").first ?? "")+#""]}"# }
                return #"{"replies":["换过镜头后异常仍存在（echo_source_1）。"],"source_ids":["echo_source_1"]}"#
            },bridge:{ request in
                if bridgeDown { throw MemoryFailure.message("WithEcho 读取失败，请检查授权或网络。") }
                return request["action"] as? String == "retrieve" ? RetrievalResult(events:[MemoryMetadata(event_id:record.event_id,date:record.date,title:record.title,summary:record.body)],cache:"server") : RetrievalResult(sources:[record],cache:"local")
            },local:local)
        }
        let shared=engine(), hub=quiet(MemoryInline()); hub.automaticOverride=false; hub.engine=shared
        let target=InlineTestTarget(); hub.request(target); await hub.task?.value
        precondition(runs().count == 1,"one record per lookup")
        let first=runs()[0]
        precondition(first["surface"] as? String == "inline" && first["trigger"] as? String == "explicit" && first["app"] as? String == "fixture.app" && first["query"] as? String == target.text && first["mode"] as? String == "continuation")
        precondition((first["plan"] as? [String:Any])?["by"] as? String == "model" && (first["select"] as? [String:Any])?["by"] as? String == "full_range" && (first["select"] as? [String:Any])?["ids"] as? [String] == [record.event_id] && (first["select"] as? [String:Any])?["batches"] as? Int == 0)
        precondition((first["calls"] as? [[String:Any]])?.compactMap { $0["scene"] as? String } == ["plan","answer"])
        let stages=first["stages_ms"] as? [String:Int] ?? [:]
        precondition(Set(stages.keys) == ["plan","retrieve","select","details","answer","total"] && stages.values.allSatisfy { $0 >= 0 } && stages["total"]! >= stages["plan"]!+stages["answer"]!)
        let retrieve=first["retrieve"] as? [String:Any]
        precondition((retrieve?["withecho"] as? [String:Any])?["events"] as? Int == 1 && (retrieve?["withecho"] as? [String:Any])?["cache"] as? String == "server" && (retrieve?["details"] as? [String:Any])?["cache"] as? String == "local")
        precondition((first["sources"] as? [[String:Any]])?.first?["from"] as? String == "withecho" && (first["answer"] as? [String:Any])?["replies"] as? [String] == ["换过镜头后异常仍存在。"] && first["error"] == nil)
        precondition((first["versions"] as? [String:String])?["prompts"] == SmartMemory.promptVersion && first["started_at"] as? String != nil)
        precondition(hub.accept() && outcomes(first["run_id"]) == ["inserted"],"filling the reply is the outcome")
        hub.dismiss(); precondition(outcomes(first["run_id"]) == ["inserted"],"one outcome per lookup")
        print("PASS: each lookup is recorded once with question, route, stages, calls, sources and reply; filling it is its one outcome")

        let closed=InlineTestTarget(); hub.request(closed); await hub.task?.value
        let closedID=runs().last!["run_id"]; hub.dismiss(); hub.discard()
        precondition(outcomes(closedID) == ["dismissed"],"Esc is dismissed")
        let edited=InlineTestTarget(); hub.request(edited); await hub.task?.value
        let editedID=runs().last!["run_id"]; edited.text += "，"; edited.selection.location=edited.text.utf16.count; hub.restore()
        precondition(outcomes(editedID) == ["abandoned"],"editing the text abandons the card")
        let left=InlineTestTarget(); hub.request(left); await hub.task?.value
        let leftID=runs().last!["run_id"]; hub.request(InlineTestTarget()); await hub.task?.value
        let voiceID=runs().last!["run_id"]; hub.close()
        precondition(outcomes(leftID).isEmpty && outcomes(voiceID).isEmpty,"another lookup or Echo closing the card leaves the outcome unknown")
        let waiting=quiet(MemoryInline()); waiting.automaticOverride=false; waiting.engine=engine(delay:300_000_000)
        let slow=InlineTestTarget(); waiting.request(slow); let pending=waiting.task, slowID=waiting.runID; waiting.dismiss(); await pending?.value
        let cancelled=run(slowID)
        precondition(outcomes(slowID) == ["dismissed"] && cancelled?["error"] as? String == "cancelled" && cancelled?["query"] as? String == slow.text && cancelled?["mode"] as? String == "continuation" && (cancelled?["stages_ms"] as? [String:Int])?["total"] != nil,"closing while loading records the question, cancelled")
        let broken=quiet(MemoryInline()); broken.automaticOverride=false; broken.engine=engine(failing:true)
        broken.request(InlineTestTarget()); await broken.task?.value
        precondition((runs().last?["error"] as? String)?.hasPrefix("模型请求失败") == true && (runs().last?["calls"] as? [[String:Any]])?.first?["error"] != nil); broken.dismiss()
        let quietFail=quiet(MemoryInline()); quietFail.automaticOverride=true; quietFail.engine=engine(failing:true)
        quietFail.start(InlineTestTarget(),context:InlineTestTarget().memoryDraft()!); let silentID=quietFail.runID; await quietFail.task?.value
        quietFail.dismiss()  // nothing was shown, so there is nothing for the user to have closed
        quietFail.request(InlineTestTarget()); await quietFail.task?.value; quietFail.close()
        precondition(run(silentID)?["trigger"] as? String == "automatic" && outcomes(silentID).isEmpty,"an automatic lookup that failed silently gets no outcome")
        let again=quiet(MemoryInline()); again.automaticOverride=false; again.engine=shared
        again.request(InlineTestTarget()); await again.task?.value
        precondition(runs().last?["cached"] as? Bool == true && (runs().last?["calls"] as? [[String:Any]])?.isEmpty == true); again.dismiss()
        var count=runs().count
        let demo=quiet(MemoryInline()); demo.automaticOverride=false; demo.demo=true; demo.engine=engine()
        demo.request(InlineTestTarget()); await demo.task?.value; demo.dismiss()
        let terminal=InlineTestTarget(); terminal.memoryApp="com.apple.Terminal"
        let shell=quiet(MemoryInline()); shell.automaticOverride=false; shell.engine=engine(); shell.request(terminal); await shell.task?.value; shell.dismiss()
        precondition(runs().count == count,"fictional demos, terminals and password apps are not recorded")
        let ruled=quiet(MemoryInline()); ruled.automaticOverride=false; ruled.engine=engine()
        let dated=InlineTestTarget(); dated.text="昨天相机检查的结论是什么"; dated.selection=NSRange(location:dated.text.utf16.count,length:0)
        ruled.request(dated); await ruled.task?.value; ruled.dismiss()
        precondition((runs().last?["plan"] as? [String:Any])?["by"] as? String == "rule","dates the code can read skip the model")
        let drafts=LocalMemoryStore(root:root.appendingPathComponent("InputMemory")); _ = try drafts.upsert("相机换过镜头以后异常还在",app:"fixture.notes",id:nil,now:ISO8601DateFormatter().date(from:"2026-10-08T02:00:00Z")!)
        let offline=quiet(MemoryInline()); offline.automaticOverride=false; offline.engine=engine(bridgeDown:true,local:drafts)
        offline.request(InlineTestTarget()); await offline.task?.value; offline.dismiss()
        let down=(runs().last?["retrieve"] as? [String:Any])?["withecho"] as? [String:Any]
        precondition(down?["cache"] as? String == "unavailable" && (down?["error"] as? String)?.hasPrefix("WithEcho 读取失败") == true && (runs().last?["sources"] as? [[String:Any]])?.first?["from"] as? String == "local","WithEcho down: the reason is kept and local drafts answer")
        print("PASS: Esc, edits, cancelling while loading, failures, silent failures, cached replies and offline WithEcho are each recorded as such; other endings leave no outcome; demos, terminals and password apps are not recorded")

        let workspace=MemoryWorkspace(); workspace.panel.alphaValue=0; workspace.engine=engine()
        workspace.query.setQuery("我这台相机之前检查的情况是什么"); workspace.submit(); await workspace.task?.value
        let desk=runs().last!
        precondition(desk["surface"] as? String == "workspace" && desk["query"] as? String == "我这台相机之前检查的情况是什么" && workspace.replyRunID == desk["run_id"] as? String)
        workspace.didInsert(); workspace.didInsert(); precondition(outcomes(desk["run_id"]) == ["inserted"],"the workspace records one outcome too")
        print("PASS: workspace lookups are recorded and get one outcome")


        SmartMemory.readKey={ "sk-test" }; SmartMemory.protocolClasses=[FakeModelService.self]
        let live=SmartMemory(chat:nil,bridge:nil,local:LocalMemoryStore(root:root.appendingPathComponent("Empty")))
        let trace=MemoryTrace(surface:"inline",trigger:"explicit")
        FakeModelService.replies=[(200,#"{"choices":[{"message":{"content":"好"}}],"usage":{"prompt_tokens":10000,"completion_tokens":1000,"prompt_cache_hit_tokens":4000}}"#),(500,#"{"error":"busy"}"#),(200,"<html>gateway</html>"),(200,#"{"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":0}}"#)]
        let answered=try await live.chat(system:"s",prompt:"p",scene:"answer",trace:trace); precondition(answered == "好")
        for _ in 0..<3 { do { _ = try await live.chat(system:"s",prompt:"p",scene:"answer",trace:trace); preconditionFailure("must fail") } catch {} }
        let booked=lines("Usage").suffix(4)
        precondition(booked.map { $0["error"] as? String ?? "ok" } == ["ok","http_500","not_json","no_content"],"\(booked.map { $0["error"] ?? "ok" })")
        precondition(booked.allSatisfy { $0["run_id"] as? String == trace.id && $0["scene"] as? String == "answer" && $0.keys.contains("usd") },"every booking carries usd, null when unknown")
        precondition(booked.first?["input"] as? Int == 10000 && booked.first?["cache_hit"] as? Int == 4000 && booked.dropFirst().allSatisfy { $0["usd"] is NSNull || $0["usd"] as? Double != nil })
        precondition(trace.run.calls.map { $0.error == nil } == [true,false,false,false] && trace.run.calls[3].input == 50,"failed calls stay in the record with what is known")
        SmartMemory.protocolClasses=nil; SmartMemory.readKey={ try MemoryModelKey.read() }


        let peak=ISO8601DateFormatter().date(from:"2026-10-14T02:30:00Z")!, offPeak=ISO8601DateFormatter().date(from:"2026-10-17T02:30:00Z")!
        precondition(abs(ModelPrice.usd(host:"api.deepseek.com",model:"deepseek-flash",input:10000,cacheHit:4000,output:1000,at:peak)!-0.003024)<1e-12)
        precondition(abs(ModelPrice.usd(host:"api.deepseek.com",model:"deepseek-flash",input:10000,cacheHit:4000,output:1000,at:offPeak)!-0.001512)<1e-12)
        precondition(abs(ModelPrice.usd(host:"api.deepseek.com",model:"deepseek-v4-pro",input:1_000_000,cacheHit:0,output:0,at:offPeak)!-0.66)<1e-9)
        precondition(ModelPrice.usd(host:"api.deepseek.com",model:"deepseek-chat",input:1,cacheHit:0,output:1) == nil && ModelPrice.usd(host:"api.example.com",model:"deepseek-flash",input:1,cacheHit:0,output:1) == nil)
        precondition(!ModelPrice.peak(ISO8601DateFormatter().date(from:"2026-10-14T05:30:00Z")!) && ModelPrice.peak(ISO8601DateFormatter().date(from:"2026-10-14T09:59:00Z")!) && !ModelPrice.peak(ISO8601DateFormatter().date(from:"2026-10-14T10:00:00Z")!))
        precondition(ModelPrice.tokens(["usage":["prompt_tokens":500,"completion_tokens":20,"prompt_tokens_details":["cached_tokens":100]]]).cacheHit == 100)
        MemoryLog.shared.usage(MemoryUsage(at:MemoryLog.timestamp(Date()),scene:"answer",model:"unknown",host:nil,input:nil,cache_hit:nil,output:nil,ms:1,usd:nil,run_id:nil))
        let unknown=lines("Usage").last!
        precondition(unknown["usd"] is NSNull && unknown["input"] is NSNull && Set(unknown.keys) == ["schema","at","scene","model","host","input","cache_hit","output","ms","usd"],"unknowns are null, not missing: \(unknown.keys.sorted())")
        let runsFolder=root.appendingPathComponent("Runs"), month=try FileManager.default.contentsOfDirectory(at:runsFolder,includingPropertiesForKeys:nil)[0]
        let fileMode=(try FileManager.default.attributesOfItem(atPath:month.path)[.posixPermissions] as! NSNumber).intValue, folderMode=(try FileManager.default.attributesOfItem(atPath:runsFolder.path)[.posixPermissions] as! NSNumber).intValue
        precondition(fileMode == 0o600 && folderMode == 0o700)
        count=runs().count
        let damaged=try FileHandle(forWritingTo:month); try damaged.seekToEnd(); try damaged.write(contentsOf:Data([0xff,0xfe,0x0a])); try damaged.close()
        precondition(MemoryLog.shared.runCount == count && count>0 && MemoryLog.shared.hasRuns,"one damaged line does not hide the month")
        try MemoryLog.shared.clearRuns()
        precondition(MemoryLog.shared.runCount == 0 && !MemoryLog.shared.hasRuns && !lines("Usage").isEmpty,"clearing removes questions and replies, keeps the ledger")
        print("PASS: the real request path books every call (ok, HTTP error, not JSON, no content) with null for unknowns; peak and off-peak prices from DeepSeek's page; private files; a damaged line is skipped; clearing keeps the ledger")


        let blocked=root.appendingPathComponent("not-a-folder"); FileManager.default.createFile(atPath:blocked.path,contents:Data())
        MemoryLog.shared=MemoryLog(root:blocked)
        let resilient=quiet(MemoryInline()); resilient.automaticOverride=false; resilient.engine=engine()
        let still=InlineTestTarget(); resilient.request(still); await resilient.task?.value
        precondition(resilient.accept() && still.applied == 1 && MemoryLog.shared.failures>=2)
        print("PASS: an unwritable log is counted and never blocks a lookup or filling it")
    }
}

final class FakeModelService:URLProtocol {
    static var replies:[(Int,String)]=[]
    static var requests:[URLRequest]=[]  // where each request went and with which Key
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status,body)=Self.replies.isEmpty ? (500,"") : Self.replies.removeFirst()
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class MemoryInlineDemo:NSObject,MemoryInlineTarget,NSTextViewDelegate {
    let window=NSWindow(contentRect:NSRect(x:300,y:300,width:760,height:245),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    let view=MemoryPromptView(frame:NSRect(x:0,y:0,width:720,height:90),textContainer:nil)
    override init() {
        super.init(); window.title="记忆输入法交互测试（虚构）"; window.isReleasedWhenClosed=false
        let caption=NSTextField(labelWithString:"相机售后服务 · 输入框（虚构测试）"); caption.frame=NSRect(x:20,y:195,width:720,height:25); caption.font = .systemFont(ofSize:18,weight:.medium); window.contentView!.addSubview(caption)
        let scroll=NSScrollView(frame:NSRect(x:20,y:85,width:720,height:90)); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller=true; scroll.documentView=view; window.contentView!.addSubview(scroll)
        let hint=NSTextField(wrappingLabelWithString:"在这里写：我这台相机之前检查的情况是：\n停顿后出现记忆候选，按 Tab 补入正文。普通中文拼音选词、Shift 中英文切换仍可用。这个页面只使用虚构记录。"); hint.frame=NSRect(x:20,y:16,width:720,height:55); hint.font = .systemFont(ofSize:12); hint.textColor = .secondaryLabelColor; window.contentView!.addSubview(hint)
        view.delegate=self; view.onMemoryTab={ MemoryInline.shared.handleTab() }; view.onEscape={ MemoryInline.shared.dismiss() }
        view.onTextChange={ [weak self] in guard let self else { return }; MemoryInline.shared.typingChanged(self) }
        view.onSubmit={ [weak self] in self?.view.insertText("\n",replacementRange:NSRange(location:NSNotFound,length:0)) }
        MemoryInline.shared.demo=true; MemoryInline.shared.engine=inlineFixtureEngine()
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
    }
    var acceptsMemory:Bool { window.isKeyWindow && view.preedit.isEmpty }
    func textDidChange(_ notification:Notification) { MemoryInline.shared.typingChanged(self) }
    func memoryDraft() -> MemoryDraft? {
        let selection=view.selectedRange(), document=view.string as NSString
        if selection.length>0 { return MemoryDraft.make(document.substring(with:selection),range:selection,selection:selection,selected:true) }
        let range=NSRange(location:0,length:selection.location)
        return MemoryDraft.make(document.substring(with:range),range:range,selection:selection)
    }
    func memoryAnchor() -> NSRect { view.firstRect(forCharacterRange:view.selectedRange(),actualRange:nil) }
    func applyMemory(_ text:String,draft:MemoryDraft) -> Bool {
        guard memoryDraft() == draft else { return false }; view.insertText(text,replacementRange:draft.replacement); return true
    }
}

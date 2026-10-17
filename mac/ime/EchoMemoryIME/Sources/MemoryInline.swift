import Cocoa

struct MemoryDraft:Equatable {
    let text:String
    let contextRange:NSRange
    let selection:NSRange
    let mode:MemoryOutputMode
    var before=""  // the field's earlier lines, read with the request: they tell who the text is for
    static func make(_ text:String,range:NSRange,selection:NSRange,selected:Bool=false,before:String="") -> MemoryDraft? {
        let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty,trimmed.count<=600 else { return nil }
        let request=["告诉","转告","回复","帮我","请帮","总结","整理","查一下"].contains(where:{trimmed.hasPrefix($0)})
        // A question is a lookup instruction, not an opening to continue. Keep
        // explicit sentence openings (especially colon-ended text) as completion.
        let opening=["：",":"].contains(where:{trimmed.hasSuffix($0)})
        let question = !opening && (trimmed.hasSuffix("?") || trimmed.hasSuffix("？") || ["是什么","做了什么","练了什么","吃了什么","有哪些","哪个","哪一","什么时候","多少","有没有","是否","怎么","如何","what did","what was","when did","which"].contains(where:{trimmed.lowercased().contains($0)}))
        return MemoryDraft(text:text,contextRange:range,selection:selection,mode:selected || request || question ? .reply : .continuation,before:before)
    }
    var shouldSuggest:Bool {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard value.count>=8, !["。","！","!"].contains(where:{value.hasSuffix($0)}) else { return false }
        return ["之前","上次","昨天","前天","上周","最近","记得","记忆","结论","过敏","不能吃","last time","yesterday","previously"].contains(where:{value.contains($0)})
    }
    var replacement:NSRange { mode == .reply ? contextRange : selection }
}
protocol MemoryInlineTarget:AnyObject {
    var memoryContext:UUID? { get }
    var acceptsMemory:Bool { get }
    func memoryDraft() -> MemoryDraft?
    func memoryAnchor() -> NSRect
    func applyMemory(_ text:String,draft:MemoryDraft) -> Bool
    // Why memoryDraft() is nil, shown under the caret when the shortcut cannot run.
    func memoryProblem() -> String
    var memoryApp:String? { get }  // recorded with the lookup
}
extension MemoryInlineTarget { var memoryContext:UUID? { nil } }
extension MemoryInlineTarget {
    func memoryProblem() -> String { "先写一句要查的话" }
    var memoryApp:String? { nil }
}
final class MemoryCandidatePanel:NSPanel {
    override var canBecomeKey:Bool { false }
    override var canBecomeMain:Bool { false }
}
// Quiet version selectors and a compact fill action; never take focus from the field.
final class MemoryOption:NSButton {
    var selected=false { didSet { needsDisplay=true } }
    override func draw(_ dirtyRect:NSRect) {
        if selected || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.14 : 0.08).setFill()
            NSBezierPath(roundedRect:bounds,xRadius:7,yRadius:7).fill()
        }
        let text=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:12,weight:selected ? .medium : .regular),.foregroundColor:selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor])
        let size=text.size(); text.draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2))
    }
    override var intrinsicContentSize:NSSize { NSSize(width:ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium)]).width)+20,height:26) }
}
// Memory card under the caret. It never takes focus: key handling asks handleTab() and
// interceptsArrows, so Tab fills, ↑↓ switch versions, and Esc closes.
final class MemoryInline:NSObject {
    // Why a lookup ended without a reply. Each kind has its own header and next step.
    enum Failure:Equatable {
        case noRecords(String), authorization, request(String)
        init(_ error:Error) {
            let text=error.localizedDescription
            if error is MemoryKeyAuthorization { self = .authorization } else if text.contains("没有找到") { self = .noRecords(text) } else { self = .request(text) }
        }
        var title:String {
            switch self { case .noRecords: return "记忆 · 没有找到相关记录"; case .authorization: return "记忆 · 需要授权模型"; case .request: return "记忆 · 请求失败" }
        }
        var body:String {
            switch self { case .noRecords(let text),.request(let text): return text; case .authorization: return "模型 Key 需要 macOS 钥匙串授权。点「授权模型」，在系统提示中允许一次即可。" }
        }
        var next:String {
            switch self { case .noRecords: return "补充主题后再按 \(MemoryBinding.label)"; case .authorization: return "先点「授权模型」"; case .request: return "按 \(MemoryBinding.label) 重试" }
        }
    }
    static let shared=MemoryInline()
    static let width:CGFloat=336, bodyWidth:CGFloat=304
    static var automatic:Bool { UserDefaults.standard.object(forKey:"disableAutomaticMemory") != nil && !UserDefaults.standard.bool(forKey:"disableAutomaticMemory") }
    static func setAutomatic(_ enabled:Bool) {
        UserDefaults.standard.set(!enabled,forKey:"disableAutomaticMemory")
        shared.close()
        if enabled,let owner=EchoInputController.current { shared.typingChanged(owner) }
    }
    let panel=MemoryCandidatePanel(contentRect:NSRect(x:0,y:0,width:width,height:120),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    let surface=VoiceSurface(frame:.zero), spinner=VoiceSpinner()
    let agent=NSImageView(image:EchoUI.brandImage("APTAgent"))
    let header=NSTextField(labelWithString:"记忆"), preview=NSTextField(wrappingLabelWithString:""), hint=EchoUI.label("",size:11,secondary:true)
    let options=NSView(), evidence=NSButton(), disableButton=NSButton(), closeButton=NSButton(), fillButton=MemoryOption()
    var engine=SmartMemory(), demo=false, selectedIndex=0, draft:MemoryDraft?, reply:MemoryReply?, lastAttempt:MemoryDraft?, dismissed:MemoryDraft?
    weak var target:MemoryInlineTarget?
    var task:Task<Void,Never>?, debounce:DispatchWorkItem?, poll:Timer?, token=UUID(), loading=false, explicit=false, failure:Failure?
    var runID:String?  // the recorded lookup whose outcome is still open
    var stage="", started=Date(), flashText:String?, flashing:DispatchWorkItem?
    var automaticOverride:Bool?
    var automaticEnabled:Bool { automaticOverride ?? Self.automatic }
    override init() {
        super.init()
        panel.hidesOnDeactivate=false; panel.isReleasedWhenClosed=false; panel.hasShadow=true; panel.level = .floating
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]; panel.isFloatingPanel=true
        panel.isOpaque=false; panel.backgroundColor = .clear
        surface.radius=16; panel.contentView=surface
        header.font = .systemFont(ofSize:13,weight:.medium); header.textColor = .secondaryLabelColor; header.lineBreakMode = .byTruncatingTail
        preview.font = .systemFont(ofSize:14); preview.textColor = .labelColor; EchoUI.wrapping(preview,lines:6)
        evidence.isBordered=false; evidence.refusesFirstResponder=true; evidence.imagePosition = .imageLeading
        evidence.image=NSImage(systemSymbolName:"doc.text.magnifyingglass",accessibilityDescription:"查看依据")
        evidence.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:12,weight:.regular); evidence.contentTintColor = .secondaryLabelColor
        EchoUI.icon(disableButton,"bolt.slash",label:"关闭自动调用记忆")
        EchoUI.icon(closeButton,"xmark",label:"关闭（Esc）")
        for button in [disableButton,closeButton] { button.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:10,weight:.regular) }
        fillButton.title="填入 ⇥"; fillButton.selected=true; fillButton.isBordered=false; fillButton.refusesFirstResponder=true
        fillButton.toolTip="Tab 或 \(MemoryBinding.label) 填入当前版本"; fillButton.setAccessibilityLabel("填入当前版本，Tab")
        fillButton.target=self; fillButton.action=#selector(fillSelected)
        evidence.target=self; evidence.action=#selector(showEvidence)
        disableButton.target=self; disableButton.action=#selector(disableAutomatic)
        closeButton.target=self; closeButton.action=#selector(dismiss)
        agent.imageScaling = .scaleProportionallyUpOrDown; agent.setAccessibilityElement(false)
        for view in [agent,header,preview,options,hint,evidence,disableButton,closeButton,fillButton,spinner] { surface.addSubview(view) }
        render()
    }
    // Header, body and action row from the current state; restore() then sizes and shows the card.
    func render() {
        updateHeader()
        if loading { preview.stringValue=stage.isEmpty ? "正在找与你这句话有关的记录…" : stage }
        else if let reply { preview.stringValue=reply.insertable && reply.replies.indices.contains(selectedIndex) ? reply.replies[selectedIndex] : reply.preview }
        else { preview.stringValue=failure?.body ?? "" }
        preview.toolTip=preview.stringValue
        EchoUI.wrapping(preview,lines:loading ? 2 : 6)
        preview.isHidden=false; header.isHidden=false; agent.isHidden=loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        evidence.isHidden=reply?.sources.isEmpty ?? true
        let count=reply?.sources.count ?? 0
        EchoUI.textButton(evidence,"\(count) 条依据",color:.secondaryLabelColor,size:12)
        evidence.imagePosition = .imageLeading; evidence.toolTip="查看 \(count) 条记忆依据"; evidence.setAccessibilityLabel(evidence.toolTip)
        disableButton.isHidden = loading || !automaticEnabled || explicit
        disableButton.toolTip="停顿后不再自动查找，仍可按 \(MemoryBinding.label) 调用记忆"
        rebuildOptions()
    }
    func updateHeader() {
        if let flashText { header.stringValue=flashText }
        else if loading { let seconds=Int(Date().timeIntervalSince(started)); header.stringValue="记忆 · 查找中"+(seconds>=3 ? " \(seconds) 秒" : "") }
        else if let reply { header.stringValue=reply.insertable ? (reply.coverage.map { $0.contains("不可") || $0.contains("有限") ? "记忆 · 部分来源可用" : "记忆 · 已同步来源" } ?? "记忆") : "尚不能确定" }
        else { header.stringValue=failure?.title.replacingOccurrences(of:"记忆 · ",with:"") ?? "记忆" }
        spinner.toolTip=stage.isEmpty ? header.stringValue : stage+" · "+header.stringValue
        spinner.setAccessibilityLabel(spinner.toolTip)
    }
    // Action row: reply chips, the authorise chip, or a one-line next step.
    func rebuildOptions() {
        for view in options.subviews { view.removeFromSuperview() }
        hint.stringValue=""
        func chip(_ title:String,tag:Int,selected:Bool,tip:String,action:Selector) {
            let chip=MemoryOption(title:title,target:self,action:action); chip.tag=tag; chip.selected=selected; chip.toolTip=tip; chip.refusesFirstResponder=true; chip.isBordered=false; chip.setAccessibilityLabel(title); options.addSubview(chip)
        }
        if let reply,reply.insertable {
            let names=["自然","简短","详细"]
            if reply.replies.count>1 { for (index,text) in reply.replies.enumerated() {
                chip(index<names.count ? names[index] : "版本 \(index+1)",tag:index,selected:index == selectedIndex,tip:text+"（↑↓ 切换，Tab 填入）",action:#selector(choose(_:)))
            }
            }
        } else if failure == .authorization {
            chip("授权模型",tag:0,selected:true,tip:"在钥匙串提示中允许 APT 读取已保存的模型 Key",action:#selector(authorizeModel))
        } else if let failure,case .request = failure { hint.stringValue=failure.next }
        fillButton.isHidden=loading || reply?.insertable != true || reply?.replies.isEmpty != false
        options.isHidden=loading || options.subviews.isEmpty; hint.isHidden=loading || hint.stringValue.isEmpty
    }
    var hasActionRow:Bool { !options.isHidden || !hint.isHidden || !fillButton.isHidden }
    var cardWidth:CGFloat { loading ? 272 : Self.width }
    var cardHeight:CGFloat { loading ? max(66,48+EchoUI.fittingHeight(preview,width:cardWidth-58)) : 40+EchoUI.fittingHeight(preview,width:Self.bodyWidth)+(hasActionRow ? 48 : 16) }
    func layout(_ height:CGFloat) {
        let width=cardWidth, middle=height-24
        surface.radius=16
        if loading {
            spinner.frame=NSRect(x:16,y:height-32,width:16,height:16)
            closeButton.frame=NSRect(x:width-38,y:height-36,width:24,height:24)
            header.frame=NSRect(x:44,y:height-32,width:max(0,width-88),height:20)
            preview.frame=NSRect(x:44,y:10,width:width-58,height:height-48);return
        }
        func centre(_ view:NSView,x:CGFloat,width:CGFloat) { let h=ceil(view.intrinsicContentSize.height); view.frame=NSRect(x:x,y:round(middle-h/2),width:width,height:h) }
        closeButton.frame=NSRect(x:width-16-22,y:height-36,width:22,height:22)
        var right=closeButton.frame.minX-8
        for button in [disableButton,evidence] where !button.isHidden {
            let w=button === evidence ? max(34,ceil(button.intrinsicContentSize.width)) : 22; right -= w; centre(button,x:right,width:w); right -= 8
        }
        agent.frame=NSRect(x:16,y:height-34,width:20,height:20)
        centre(header,x:42,width:max(0,right-42))
        let bottom:CGFloat=hasActionRow ? 48 : 16
        preview.frame=NSRect(x:16,y:bottom,width:Self.bodyWidth,height:max(0,height-40-bottom))
        var x:CGFloat=0
        for chip in options.subviews { let w=chip.intrinsicContentSize.width; chip.frame=NSRect(x:x,y:0,width:w,height:26); x += w+4 }
        options.frame=NSRect(x:16,y:12,width:max(0,x-4),height:26)
        fillButton.frame=NSRect(x:width-16-fillButton.intrinsicContentSize.width,y:12,width:fillButton.intrinsicContentSize.width,height:26)
        let size=hint.intrinsicContentSize  // beside chips it sits on the right; alone it reads on from the body
        hint.frame=NSRect(x:options.isHidden ? 16 : width-16-ceil(size.width),y:round(26-size.height/2),width:ceil(size.width),height:ceil(size.height))
    }
    func typingChanged(_ owner:MemoryInlineTarget) {
        debounce?.cancel(); panel.orderOut(nil)
        // Once the key has reached the app: discard the card if it edited the field, otherwise show it again.
        if target === owner,loading || reply != nil || failure != nil { DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { [weak self] in self?.restore() } }
        guard automaticEnabled else {
            if target === owner,loading,!explicit { close() }
            return
        }
        let work=DispatchWorkItem { [weak self,weak owner] in
            guard let self,let owner,owner.acceptsMemory,let context=owner.memoryDraft(),context.shouldSuggest,self.dismissed != context else { return }
            if self.target === owner,self.draft == context { self.restore(); return }
            if self.target === owner,self.lastAttempt == context { return }
            self.start(owner,context:context)
        }
        debounce=work; DispatchQueue.main.asyncAfter(deadline:.now()+0.85,execute:work)
    }
    func request(_ owner:MemoryInlineTarget) {
        debounce?.cancel()
        guard owner.acceptsMemory else { return }
        guard let context=owner.memoryDraft() else { EchoHint.shared.show(owner.memoryProblem(),near:owner.memoryAnchor()); return }
        dismissed=nil
        if target === owner,draft == context,reply != nil { render(); restore(); return }
        start(owner,context:context,explicit:true)
    }
    func invoke(_ owner:MemoryInlineTarget) {
        if target === owner,owner.memoryDraft() == draft {
            if loading { return }
            if valid,let reply,panel.isVisible { if reply.insertable { _ = accept() } else { flash("补充主题后再按 \(MemoryBinding.label)") }; return }
        }
        request(owner)
    }
    // The app as people call it, with its bundle id so a model can still tell a chat app it has not heard of.
    static func appName(_ bundle:String?)->String? {
        guard let bundle else { return nil }
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) else { return bundle }
        let name=FileManager.default.displayName(atPath:url.path).replacingOccurrences(of:".app",with:"")
        return name == bundle ? bundle : "\(name)（\(bundle)）"
    }
    func start(_ owner:MemoryInlineTarget,context:MemoryDraft,explicit:Bool=false) {
        if !demo { AU05Controller.shared.event(.memory,.working) }
        task?.cancel(); token=UUID(); let generation=token
        // A new lookup leaves the previous one's outcome unknown. Fixtures, terminals and password apps are not recorded.
        let allowed = owner.memoryApp.map(InputMemoryRecorder.allowedApp) != false, recorded = !demo && allowed
        // Read now, while the user is still in this field: terminals and password apps send the request only.
        let place=MemoryContext(app:allowed ? Self.appName(owner.memoryApp) : nil,before:allowed ? context.before : "")
        let trace=recorded ? MemoryTrace(surface:"inline",trigger:explicit ? "explicit" : "automatic",app:owner.memoryApp,query:context.text,mode:context.mode.rawValue) : nil
        runID=trace?.id
        target=owner; draft=context; lastAttempt=context; reply=nil; failure=nil; selectedIndex=0; loading=true; self.explicit=explicit
        stage=""; started=Date(); flashing?.cancel(); flashText=nil
        render(); restore()
        poll?.invalidate(); poll=Timer.scheduledTimer(withTimeInterval:0.3,repeats:true) { [weak self] _ in
            guard let self else { return }; if self.loading { self.updateHeader() }; self.restore()
        }
        task=Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result=try await self.engine.answer(context.text,demo:self.demo,mode:context.mode,context:place,trace:trace,progress:{ [weak self] value in
                    DispatchQueue.main.async { guard let self,self.token == generation,self.loading else { return }; self.stage=value; self.render(); self.restore() }
                })
                if let trace { MemoryLog.shared.record(trace.run) }
                guard self.token == generation else { return }
                self.reply=result; self.loading=false; self.render(); self.restore()
                if !self.demo,self.token == generation { AU05Controller.shared.event(.memory,.waiting) }
            } catch {
                if let trace { trace.update { $0.error=MemoryLog.cancelled(error) ? "cancelled" : error.localizedDescription }; MemoryLog.shared.record(trace.run) }
                guard self.token == generation else { return }
                if !self.explicit && !(error is MemoryKeyAuthorization) { self.runID=nil; self.loading=false; self.panel.orderOut(nil); self.poll?.invalidate(); self.poll=nil; AU05Controller.shared.event(.memory,.idle); return }
                self.loading=false; self.failure=Failure(error); self.render(); self.restore()
                if !self.demo,self.token == generation { AU05Controller.shared.event(.memory,.failure) }
            }
        }
    }
    var valid:Bool { guard let target,let draft,target.acceptsMemory else { return false }; return target.memoryDraft() == draft && dismissed != draft }
    // Arrow keys switch versions only when there is more than one reply to fill.
    var interceptsArrows:Bool { guard let reply,reply.insertable,reply.replies.count>1,panel.isVisible else { return false }; return valid }
    // Tab on a visible card fills an insertable reply; otherwise it keeps the key and says what to do next.
    func handleTab() -> Bool {
        if loading,panel.isVisible,valid { flash("还在查找，稍等"); return true }
        guard reply != nil || failure != nil,panel.isVisible,valid else { return false }
        if let reply,reply.insertable { return accept() }
        flash(failure?.next ?? "补充主题后再按 \(MemoryBinding.label)"); return true
    }
    func flash(_ text:String) {
        flashText=text; render(); restore(); flashing?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.flashText=nil; self?.render(); self?.restore() }
        flashing=work; DispatchQueue.main.asyncAfter(deadline:.now()+1.5,execute:work)
    }
    func restore() {
        if !automaticEnabled,!explicit,loading || reply != nil { close(); return }
        guard let target else { panel.orderOut(nil); poll?.invalidate(); poll=nil; return }  // its field is gone
        guard let draft,loading || reply != nil || failure != nil else { panel.orderOut(nil); return }
        // One floating card at a time: wait while a voice card holds kept words or a message.
        let voice=VoiceInput.shared
        guard !(voice.busy || voice.pending != nil || voice.terminal) else { panel.orderOut(nil); return }
        // Away from the field (another app, pinyin pending): hide, and come back with it.
        guard target.acceptsMemory,dismissed != draft else { panel.orderOut(nil); return }
        // Text briefly unreadable (e.g. a browser refocusing): hide, decide when it reads again.
        guard let current=target.memoryDraft() else { panel.orderOut(nil); return }
        // Edited or moved the caret in the same field: the card no longer applies and never returns.
        guard current == draft else { conclude("abandoned"); discard(); return }
        let anchor=target.memoryAnchor(), screen=(NSScreen.screens.first(where:{$0.frame.intersects(anchor)}) ?? NSScreen.main)?.visibleFrame ?? .zero
        let point=anchor.height>0 ? NSPoint(x:anchor.minX,y:anchor.minY) : NSEvent.mouseLocation
        let height=cardHeight; layout(height)
        var origin=NSPoint(x:min(max(point.x,screen.minX),screen.maxX-cardWidth),y:point.y-height-7)
        if origin.y<screen.minY { origin.y=min(screen.maxY-height,(anchor.height>0 ? anchor.maxY : point.y)+7) }
        let frame=NSRect(origin:origin,size:NSSize(width:cardWidth,height:height))
        if panel.frame != frame { panel.setFrame(frame,display:true) }
        panel.orderFrontRegardless()
    }
    func suspend(_ owner:MemoryInlineTarget) { debounce?.cancel(); if target === owner { panel.orderOut(nil) } }
    func resume(_ owner:MemoryInlineTarget) { if target === owner { restore() } }
    // Never replaces a clarification: only insertable replies with several versions move.
    func move(_ delta:Int) {
        guard valid,let reply,reply.insertable,reply.replies.count>1 else { return }
        selectedIndex=(selectedIndex+delta+reply.replies.count)%reply.replies.count; render(); restore()
    }
    @discardableResult func accept(_ index:Int?=nil) -> Bool {
        guard !loading,valid,let target,let draft,let reply,reply.insertable else { return false }
        guard reply.sourcesCurrent else { self.reply=nil; failure=Failure(MemoryFailure.message("记忆来源已变化或删除，请重新查找。")); render(); return false }
        let selected=index ?? selectedIndex; guard reply.replies.indices.contains(selected) else { return false }
        if let validate=reply.remoteValidation {
            let generation=token,focus=target.memoryContext
            loading=true;stage="填入前核验记忆来源…";started=Date();render();restore()
            task=Task { @MainActor [weak self] in
                do {
                    try await validate();try Task.checkCancellation()
                    guard let self,self.token == generation else { return }
                    self.loading=false
                    guard self.valid,self.target === target,self.draft == draft,target.memoryContext == focus else { self.render();self.restore();return }
                    guard reply.sourcesCurrent else { throw MemoryFailure.message("记忆来源已变化，请重新查找。") }
                    _ = self.apply(reply,selected:selected,target:target,draft:draft)
                } catch {
                    guard let self,self.token == generation else { return }
                    self.loading=false;self.reply=nil;self.failure=Failure(error);self.render();self.restore()
                }
            }
            return true
        }
        return apply(reply,selected:selected,target:target,draft:draft)
    }
    private func apply(_ reply:MemoryReply,selected:Int,target:MemoryInlineTarget,draft:MemoryDraft)->Bool {
        let run=runID
        guard target.applyMemory(reply.replies[selected],draft:draft) else { panel.orderOut(nil); return false }
        conclude("inserted",choice:selected)
        if !demo { AU05Controller.shared.event(.memory,.success) }
        InputMemoryCapture.noteGenerated(reply.replies[selected],app:target.memoryApp)
        // What the user makes of it afterwards is the plainest verdict on the reply, and their own wording. Input
        // memory sees one paragraph at a time, so only a one-paragraph reply can be followed.
        if let run,!reply.replies[selected].contains(where:\.isNewline) { VoiceEdits.shared.watch(run:run,app:target.memoryApp,text:reply.replies[selected],location:draft.replacement.location,memory:true) }
        self.dismissed=target.memoryDraft(); self.reply=nil; self.failure=nil; self.draft=nil; poll?.invalidate(); poll=nil; panel.orderOut(nil); return true
    }
    @objc func choose(_ sender:NSButton) {
        guard valid,let reply,reply.insertable,reply.replies.indices.contains(sender.tag) else { return }
        selectedIndex=sender.tag; render(); restore()
    }
    @objc func fillSelected() { _ = accept() }
    // Only the user closing a card marks its text as dismissed; an edit merely discards it.
    // The user closed the card (Esc or ✕).
    @objc func dismiss() { conclude("dismissed"); dismissed=draft; debounce?.cancel(); debounce=nil; discard() }
    // Echo closed it (voice started, automatic lookups turned off): the outcome stays unknown.
    func close() { runID=nil; dismiss() }
    // Drop the card and its lookup; an automatic lookup already scheduled for newer text still runs.
    func discard() {
        if !demo { AU05Controller.shared.event(.memory,.idle) }
        runID=nil; token=UUID(); task?.cancel(); task=nil; loading=false
        spinner.stopAnimation(nil)
        reply=nil; failure=nil; flashing?.cancel(); flashText=nil; panel.orderOut(nil); poll?.invalidate(); poll=nil
    }
    // Each recorded lookup gets at most one ending: inserted, dismissed (by the user) or abandoned (its text
    // was edited). Anything else (another lookup, switching away, Echo closing the card) leaves none. An inserted
    // one-paragraph reply later gets one more line, what became of it (VoiceEdits: edited, unchanged, removed, unknown).
    func conclude(_ kind:String,choice:Int?=nil) { guard let id=runID else { return }; runID=nil; MemoryLog.shared.outcome(id,kind,choice:choice) }
    // The model key was just authorised, so an authorisation card has done its job.
    func authorized() { guard failure == .authorization else { return }; discard(); lastAttempt=nil; draft=nil }
    @objc func disableAutomatic() { Self.setAutomatic(false) }
    @objc func showEvidence() { guard let reply else { return }; MemoryWorkspace.shared.showEvidence(for:reply) }
    @objc func authorizeModel() { EchoSettings.shared.show(.model); EchoSettings.shared.model.authorizeModelKey() }
}

extension EchoInputController:MemoryInlineTarget {
    var memoryContext:UUID? { voiceContext }
    var memoryApp:String? { inputClient?.bundleIdentifier() }
    var acceptsMemory:Bool { active && preedit.isEmpty && inputClient?.bundleIdentifier() != Bundle.main.bundleIdentifier && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == inputClient?.bundleIdentifier() }
    func memoryDraft() -> MemoryDraft? {
        guard let client=inputClient else { return nil }
        let selection=client.selectedRange()
        guard selection.location != NSNotFound,selection.length != NSNotFound,selection.length<=600 else { return nil }
        if selection.length>0 {
            guard let text=client.attributedSubstring(from:selection)?.string, text.utf16.count == selection.length else { return nil }
            let earlier=NSRange(location:max(0,selection.location-300),length:min(300,selection.location))
            let before=earlier.length == 0 ? "" : client.attributedSubstring(from:earlier)?.string.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            return MemoryDraft.make(text,range:selection,selection:selection,selected:true,before:before)
        }
        let range=NSRange(location:max(0,selection.location-360),length:min(360,selection.location))
        guard let raw=client.attributedSubstring(from:range)?.string,raw.utf16.count == range.length else { return nil }
        let lines=raw.components(separatedBy:.newlines), prefix=lines.last ?? raw
        let contextRange=NSRange(location:selection.location-prefix.utf16.count,length:prefix.utf16.count)
        let before=String(lines.dropLast().joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines).suffix(300))
        return MemoryDraft.make(prefix,range:contextRange,selection:selection,before:before)
    }
    func memoryProblem() -> String {
        let selection=inputClient?.selectedRange() ?? NSRange(location:NSNotFound,length:0)
        if selection.location == NSNotFound || selection.length == NSNotFound { return "这个输入框不提供文字，不能调用记忆" }
        return selection.length>600 ? "选中的文字太长，最多 600 字" : "先写一句要查的话"
    }
    func memoryAnchor() -> NSRect {
        var rect=NSRect(); _ = inputClient?.attributes(forCharacterIndex:0,lineHeightRectangle:&rect); return rect
    }
    func applyMemory(_ text:String,draft:MemoryDraft) -> Bool {
        guard acceptsMemory,memoryDraft() == draft,let client=inputClient else { return false }
        InputMemoryRecorder.shared.suppressGenerated(self)
        client.insertText(text,replacementRange:draft.replacement); return true
    }
}

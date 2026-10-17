import Cocoa
import Carbon

final class InputMemoryRecorder {
    static let shared=InputMemoryRecorder()
    static var enabled:Bool { UserDefaults.standard.bool(forKey:"automaticInputMemory") }
    static func setEnabled(_ enabled:Bool) {
        UserDefaults.standard.set(enabled,forKey:"automaticInputMemory")
        shared.stop()
        if enabled,let owner=EchoInputController.current { shared.start(owner) }
    }
    static func allowedApp(_ app:String)->Bool {
        let value=app.lowercased()
        return !["com.apple.terminal","com.googlecode.iterm2","dev.warp.warp-stable","local.echo.inputmethod.memory","local.echo.memory-input"].contains(value) && !["1password","bitwarden","keepass","password"].contains{value.contains($0)}
    }
    weak var owner:EchoInputController?
    var state:InputMemoryCapture?, timer:Timer?, lastSelection:NSRange?, edited=false
    var status="尚未记录新的输入。"
    func start(_ controller:EchoInputController) {
        stop(); guard Self.enabled else { return }
        owner=controller; state=InputMemoryCapture(store:.shared)
        state?.baseline(snapshot(requireFrontmost:false)); lastSelection=controller.inputClient?.selectedRange()
        timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in self?.poll() }
    }
    func stop() { state?.flush(); timer?.invalidate(); timer=nil; owner=nil; state=nil; edited=false; lastSelection=nil }
    enum Edit { case typed, pasted }
    // Keys that change the text: printable keys, Delete and Return, ⌘X and ⌘Z; ⌘V brings in someone else's words.
    // Arrows and other function keys carry characters in U+F700–U+F8FF; they move the caret, so moving
    // into another paragraph is browsing, not a new memory.
    static func edit(_ event:NSEvent)->Edit? {
        if event.modifierFlags.contains(.command) { return [kVK_ANSI_V:Edit.pasted,kVK_ANSI_X:.typed,kVK_ANSI_Z:.typed][Int(event.keyCode)] }
        guard event.modifierFlags.intersection([.control,.option]).isEmpty else { return nil }
        let printable=event.characters?.unicodeScalars.contains(where:{ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) == true
        return printable || [kVK_Delete,kVK_ForwardDelete,kVK_Return].contains(Int(event.keyCode)) ? .typed : nil
    }
    func markEdit(_ controller:EchoInputController) { if owner === controller { edited=true } }
    // Each key or click Echo passes on, before the app acts on it. ⌘V notes the paragraph as it is, so the
    // paste is exactly what changed by the next key; a key that does not edit first finishes the paragraph
    // being typed, so moving the caret away is never taken for typing in the next one.
    func willApply(_ edit:Edit?,_ controller:EchoInputController) {
        guard owner === controller,let state else { return }
        if state.pasteBase != nil { state.settlePaste(snapshot(requireFrontmost:false)) }
        switch edit {
        case .pasted?: edited=true; state.notePaste(before:snapshot(requireFrontmost:false))
        case .typed?: edited=true
        case nil: if edited { poll() }
        }
    }
    func markVoice(_ controller:EchoInputController,_ text:String) { if owner === controller { edited=true; state?.noteVoice(text) } }
    func poll() {
        guard Self.enabled,let owner,owner.acceptsMemory,!IsSecureEventInputEnabled() else { return }
        let selection=owner.inputClient?.selectedRange()
        if edited || selection != lastSelection || state?.last == nil {
            state?.observe(snapshot(),edited:edited); lastSelection=selection; edited=false
        }
        state?.settle()
        if let error=state?.lastError { status=error }
    }
    func flush() { poll(); state?.flush() }
    func beginSegment() { flush(); state?.beginSegment() }
    func suppressGenerated(_ controller:EchoInputController) { if owner === controller { poll(); state?.suppressGenerated() } }
    func snapshot(requireFrontmost:Bool=true)->InputMemorySnapshot? {
        // Check before any document access. No global keystroke logger or clipboard read.
        guard !IsSecureEventInputEnabled(),let owner,owner.active,owner.preedit.isEmpty,(!requireFrontmost || owner.acceptsMemory),let client=owner.inputClient,
              let app=client.bundleIdentifier(),Self.allowedApp(app) else { return nil }
        let selected=client.selectedRange(), length=client.length()
        guard selected.location != NSNotFound,selected.length != NSNotFound else { status="此输入框没有提供文字访问，暂不能自动记录。"; return nil }
        if length == NSNotFound || length<0 || selected.location>length {
            guard selected.length == 0,let draft=owner.memoryDraft() else { status="此输入框没有提供文字访问，暂不能自动记录。"; return nil }
            status="兼容模式：记录光标前的输入片段，可能缺少前后文。"
            return InputMemorySnapshot(text:draft.text,start:draft.contextRange.location,app:app,complete:false)
        }
        let start=max(0,selected.location-4096), end=min(length,selected.location+4096)
        let range=NSRange(location:start,length:end-start)
        guard let raw=client.attributedSubstring(from:range)?.string,raw.utf16.count == range.length else { status="此输入框没有提供完整段落，暂不能自动记录。"; return nil }
        let string=raw as NSString, caret=selected.location-start
        let paragraph=string.paragraphRange(for:NSRange(location:caret,length:0))
        // Do not silently save a truncated paragraph as complete evidence.
        guard !(paragraph.location == 0 && start>0),!(NSMaxRange(paragraph) == range.length && end<length) else { return nil }
        status="已连接当前输入框，停顿后自动记录新的输入。"
        return InputMemorySnapshot(text:string.substring(with:paragraph),start:start+paragraph.location,app:app)
    }
}

// One list row: the draft's first line, and when it was saved on the right.
final class InputMemoryRow:NSTableCellView {
    let text=EchoUI.label(""), time=EchoUI.label("",size:12,secondary:true)
    override init(frame:NSRect) {
        super.init(frame:frame); textField=text
        text.lineBreakMode = .byTruncatingTail; text.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        for label in [text,time] { label.translatesAutoresizingMaskIntoConstraints=false; addSubview(label) }
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo:leadingAnchor,constant:4),text.centerYAnchor.constraint(equalTo:centerYAnchor),
            time.leadingAnchor.constraint(greaterThanOrEqualTo:text.trailingAnchor,constant:12),time.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-4),time.centerYAnchor.constraint(equalTo:centerYAnchor)])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
}
final class InputMemoryLibrary:NSObject,NSTableViewDataSource,NSTableViewDelegate {
    static let shared=InputMemoryLibrary()
    static let disclaimer="停顿 2 秒自动保存，记录时不调用模型。均为输入草稿，不代表已发送或已确认。仅在记忆查找时把相关片段发送给已配置的模型。"
    let panel=NSPanel(contentRect:NSRect(x:220,y:180,width:700,height:600),styleMask:[.titled,.closable,.resizable,.utilityWindow],backing:.buffered,defer:false)
    let table=NSTableView(), body=NSTextView(), caption=EchoUI.label("",size:12,secondary:true)
    let disclaimerLabel=NSTextField(wrappingLabelWithString:"输入草稿不代表已发送或已确认。查询时，相关片段会发给配置的模型。")
    let trash=NSButton(checkboxWithTitle:"查看已删除",target:nil,action:nil)
    let deleteButton=NSButton(title:"删除所选记录",target:nil,action:nil)
    var records:[LocalInputRecord]=[]
    override init() {
        super.init(); panel.title="APT · 本地输入记忆"; panel.isReleasedWhenClosed=false; panel.minSize=NSSize(width:540,height:500)
        // The workbench floats above normal windows. Its library must float too,
        // and stay visible while the input method's host app remains active.
        panel.level = .floating; panel.hidesOnDeactivate=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        let surface=EchoSurface(); panel.contentView=surface
        let root=NSStackView(); root.orientation = .vertical; root.spacing=10; root.alignment = .leading; root.translatesAutoresizingMaskIntoConstraints=false; surface.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:EchoUI.margin),root.trailingAnchor.constraint(equalTo:surface.trailingAnchor,constant:-EchoUI.margin),root.topAnchor.constraint(equalTo:surface.topAnchor,constant:EchoUI.margin),root.bottomAnchor.constraint(equalTo:surface.bottomAnchor,constant:-EchoUI.margin)])
        let controls=NSStackView(); controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing=16
        controls.setViews([trash],in:.leading); controls.setViews([deleteButton],in:.trailing); root.addArrangedSubview(controls)
        for button in [trash,deleteButton] { button.target=self; button.refusesFirstResponder=true }
        deleteButton.bezelStyle = .rounded
        trash.action=#selector(refresh); deleteButton.action=#selector(changeDeleted)
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("input")); column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView=nil; table.rowHeight=36; table.style = .inset; table.backgroundColor = .clear; table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate=self; table.dataSource=self
        let list=memoryCardScroll(table)
        list.heightAnchor.constraint(greaterThanOrEqualToConstant:120).isActive=true
        root.addArrangedSubview(list)
        let listHeight=list.heightAnchor.constraint(equalTo:root.heightAnchor,multiplier:0.34);listHeight.priority = .defaultHigh;listHeight.isActive=true
        body.isEditable=false; body.isSelectable=true; body.textContainerInset=NSSize(width:12,height:12); body.isVerticallyResizable=true; body.isHorizontallyResizable=false; body.autoresizingMask=[.width]; body.textContainer?.widthTracksTextView=true
        let detail=memoryCardScroll(body); detail.heightAnchor.constraint(greaterThanOrEqualToConstant:120).isActive=true; root.addArrangedSubview(detail)
        caption.maximumNumberOfLines=3;caption.lineBreakMode = .byWordWrapping;caption.cell?.wraps=true
        disclaimerLabel.font = .systemFont(ofSize:12);disclaimerLabel.textColor = .secondaryLabelColor
        disclaimerLabel.setAccessibilityLabel(disclaimerLabel.stringValue)
        root.addArrangedSubview(disclaimerLabel);root.addArrangedSubview(caption)
        for view in root.arrangedSubviews { view.translatesAutoresizingMaskIntoConstraints=false; view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true }
    }
    // Display only: the app's name and local time, then the text. What the model receives stays in LocalInputRecord.source.
    static func detail(_ record:LocalInputRecord)->NSAttributedString {
        let origin=[LocalInputRecord.Origin.voice:" · 语音",.pasted:" · 粘贴的外部文字",.mixed:" · 含粘贴内容（灰色部分）"][record.origin] ?? ""
        let text=NSMutableAttributedString(string:appName(record.app)+" · "+time(record.updated,format:"yyyy-MM-dd HH:mm")+origin+"\n\n",attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.secondaryLabelColor])
        let body=NSMutableAttributedString(string:record.text,attributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.labelColor])
        if record.origin == .mixed { for range in record.pastedRanges { body.addAttribute(.foregroundColor,value:NSColor.secondaryLabelColor,range:range) } }
        text.append(body)
        return text
    }
    static func appName(_ bundleID:String)->String {
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID) else { return bundleID }
        let name=FileManager.default.displayName(atPath:url.path); return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
    static func time(_ date:Date,format:String)->String { let formatter=DateFormatter(); formatter.timeZone = .current; formatter.dateFormat=format; return formatter.string(from:date) }
    func show() {
        InputMemoryRecorder.shared.flush(); refresh()
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        if let screen=MemoryWorkspace.shared.panel.screen ?? NSScreen.main {
            let frame=screen.visibleFrame
            if !panel.isVisible || !frame.intersects(panel.frame) {
                panel.setFrameOrigin(NSPoint(x:frame.midX-panel.frame.width/2,y:frame.midY-panel.frame.height/2))
            }
        }
        NSApp.activate(ignoringOtherApps:true)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(table); panel.orderFrontRegardless()
    }
    @objc func refresh() {
        records=LocalMemoryStore.shared.all(deleted:trash.state == .on); table.reloadData(); table.deselectAll(nil); showDetail(); deleteButton.isEnabled=false
        deleteButton.title=trash.state == .on ? "恢复所选记录" : "删除所选记录"
        report(LocalMemoryStore.shared.error ?? (trash.state == .on ? "已删除 \(records.count) 条" : "\(records.count) 条")+(GrowthMemoryConfig.enabled ? " · APT 同步已开启，保存不调用模型" : " · 仅存本机，不调用模型")+(InputMemoryRecorder.enabled ? "" : " · 自动记录已关闭，可在「APT 设置 › 记忆与来源」开启"),error:LocalMemoryStore.shared.error != nil)
    }
    func report(_ text:String,error:Bool) {
        caption.stringValue=text; caption.textColor=error ? .systemRed : .secondaryLabelColor
        caption.toolTip=Self.disclaimer+"\n"+InputMemoryRecorder.shared.status
    }
    func showDetail() {
        if records.indices.contains(table.selectedRow) { body.textStorage?.setAttributedString(Self.detail(records[table.selectedRow])) }
        else { body.textStorage?.setAttributedString(NSAttributedString(string:records.isEmpty ? (trash.state == .on ? "没有已删除的草稿。" : "还没有输入草稿。\n\n在「APT 设置 › 记忆与来源」开启自动记录，然后在 APT 中写一段文字。停顿后可在这里查看。") : "选择上方列表中的草稿，查看来源与全文。",attributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.secondaryLabelColor])) }
    }
    @objc func changeDeleted() {
        guard records.indices.contains(table.selectedRow) else { return }
        let record=records[table.selectedRow]
        do { try LocalMemoryStore.shared.setDeleted(record.id,trash.state != .on); try DayDigester.shared.prune(LocalMemoryStore.day(record.created)); refresh() }
        catch { report("保存失败：\(error.localizedDescription)",error:true) }
    }
    func numberOfRows(in tableView:NSTableView)->Int { records.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard records.indices.contains(row) else { return nil }
        let id=NSUserInterfaceItemIdentifier("InputMemoryRow")
        let cell=tableView.makeView(withIdentifier:id,owner:self) as? InputMemoryRow ?? { let cell=InputMemoryRow(frame:.zero); cell.identifier=id; return cell }()
        cell.text.stringValue=String(records[row].text.prefix(120)).replacingOccurrences(of:"\n",with:" ")
        cell.time.stringValue=Self.time(records[row].updated,format:"MM-dd HH:mm")
        return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification) { showDetail(); deleteButton.isEnabled=records.indices.contains(table.selectedRow) }
}

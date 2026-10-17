import Cocoa
import Carbon
import InputMethodKit

// Shortcut checks keep settings in memory; a real suite would leave a plist in ~/Library/Preferences.
final class ScratchDefaults:UserDefaults {
    var values:[String:Any]=[:]
    override func object(forKey key:String)->Any? { values[key] }
    override func string(forKey key:String)->String? { values[key] as? String }
    override func set(_ value:Any?,forKey key:String) { values[key]=value }
    override func removeObject(forKey key:String) { values[key]=nil }
}

// Drives the real Rime engine with the shipped Data/ config, the way the input
// controller does: unhandled printable keys reach the app, Rime commits are inserted.
// Tokens: plain characters; {space} {ret} {bs} {esc} {down} {left} {pgdn}; {shift} is a Shift tap
// (commit typed letters); {c:x} is Control+x; {cs:x} is Control+Shift+x; {lb} {rb} are literal braces.
enum TypingChecks {
    static var failures:[String]=[]
    static func check(_ ok:Bool,_ label:String) { if !ok { failures.append(label) } }
    static func candidateLifetime() {
        guard let id=Bundle.main.bundleIdentifier,let server=IMKServer(name:"scratch.echo.candidates."+UUID().uuidString,bundleIdentifier:id) else { preconditionFailure("cannot create candidate lifetime fixture") }
        weak var survivor:IMKCandidates?
        autoreleasepool { survivor=EchoCandidatePanels.panel(for:server) }
        precondition(survivor != nil)
        for _ in 0..<64 {
            autoreleasepool {
                let panel=EchoCandidatePanels.panel(for:server)
                precondition(panel === survivor && panel?.attributes()[IMKCandidatesSendServerKeyEventFirst as String] as? Bool == true)
                panel?.hide(); precondition(panel?.isVisible() == false)
            }
        }
        print("PASS: native IMK candidate panel survives temporary owners/autorelease pools; repeated session lookups share it; server isVisible/attributes remain valid")
    }

    static func type(_ keys:String) -> (text:String,preedit:String,candidates:[String],highlighted:Int,cursor:Int) {
        let s=ERCreate(); defer { ERDestroy(s) }
        let special:[String:Int32]=["space":0x20,"ret":0xff0d,"bs":0xff08,"esc":0xff1b,"down":0xff54,"left":0xff51,"pgdn":0xff56]
        var text="", i=keys.startIndex
        func absorb() { if let commit=(ERSnapshot(s) as! [String:Any])["commit"] as? String { text += commit } }
        while i<keys.endIndex {
            var key:Int32=0, mods:Int32=0, printable=""
            if keys[i] == "{" {
                let end=keys[i...].firstIndex(of:"}")!, name=String(keys[keys.index(after:i)..<end]); i=keys.index(after:end)
                if name == "shift" { ERCommitRaw(s); absorb(); continue }
                if name.hasPrefix("cs:") { mods=5; key=Int32(name.dropFirst(3).unicodeScalars.first!.value) }
                else if name.hasPrefix("c:") { mods=4; key=Int32(name.dropFirst(2).unicodeScalars.first!.value) }
                else if name == "lb" || name == "rb" { mods=1; printable=name == "lb" ? "{" : "}"; key=Int32(printable.unicodeScalars.first!.value) }
                else { key=special[name]!; printable=name == "space" ? " " : "" }
            } else {
                let c=keys[i]; i=keys.index(after:i); key=Int32(c.unicodeScalars.first!.value); printable=String(c)
                if c.isUppercase || "~!@#$%^&*()_+{}|:\"<>?".contains(c) { mods=1 }
            }
            ERSetASCII(s,false)  // as EchoInputController.handle does before every key
            if !ERProcess(s,key,mods) && mods & 4 == 0 { text += printable }
            absorb()
        }
        let state=ERSnapshot(s) as! [String:Any]
        return (text,state["preedit"] as? String ?? "",state["candidates"] as? [String] ?? [],state["highlighted"] as? Int ?? -1,state["cursor"] as? Int ?? -1)
    }
    static func first(_ keys:String) -> String { type(keys).candidates.first ?? "" }

    // Use the actual selection paths: number keys in the input controller, ERSelect for a panel click.
    static func select(_ input:String,word:String,number:Bool) -> String {
        let session=ERCreate(); defer { ERDestroy(session) }
        for scalar in input.unicodeScalars { _ = ERProcess(session,Int32(scalar.value),0) }
        let state=ERSnapshot(session) as! [String:Any], candidates=state["candidates"] as? [String] ?? []
        guard let index=candidates.firstIndex(of:word) else { check(false,"\(input): missing candidate \(word)"); return "" }
        let selected=number ? ERProcess(session,Int32(0x31+index),0) : ERSelect(session,Int32(index))
        check(selected,"\(input): selection was handled")
        return (ERSnapshot(session) as! [String:Any])["commit"] as? String ?? ""
    }

    // Run in a second process against the preceding --verify-typing profile, without deleting it.
    static func reload() {
        check(first("agent") == "agent","agent: learned numeric selection survives process restart")
        check(first("change") == "change","change: learned panel selection survives process restart")
        check(type("agent{space}").text == "agent","agent: Space commits the learned first candidate after restart")
        check(first("women") == "我们" && first("bus") == "不是" && first("yes") == "也是" && first("bug") == "不过","restart: unselected English does not override common pinyin/abbreviations")
        finish("English selection learning survives process restart")
    }

    static func finish(_ label:String) {
        if failures.isEmpty { print("PASS: \(label)") }
        else { print("FAIL: \(failures.count) typing checks\n- "+failures.joined(separator:"\n- ")); exit(1) }
    }

    static func flags(_ modifiers:NSEvent.ModifierFlags,_ code:Int=kVK_Shift,timestamp:TimeInterval=ProcessInfo.processInfo.systemUptime) -> NSEvent {
        NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:modifiers,timestamp:timestamp,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:UInt16(code))!
    }
    static func key(_ chars:String,_ modifiers:NSEvent.ModifierFlags=[],_ code:Int=0) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,characters:chars,charactersIgnoringModifiers:chars.lowercased(),isARepeat:false,keyCode:UInt16(code))!
    }

    // Options an older Echo saved through Rime's switcher; they must not survive the upgrade.
    static func seedLegacyOptions(_ user:URL) {
        try? FileManager.default.createDirectory(at:user,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try? "var:\n  option:\n    full_shape: true\n    ascii_punct: true\n".write(to:user.appendingPathComponent("user.yaml"),atomically:true,encoding:.utf8)
    }

    static func run() {
        candidateLifetime()
        // A schema that fails to deploy silently turns every key into plain ASCII.
        check(first("nihao") == "你好","schema deploys: nihao → 你好")

        // Punctuation right after pinyin commits the first candidate, never turns the page.
        check(type("nihao.").text == "你好。","nihao. → 你好。")
        check(type("nihao,shijie.").text == "你好，世界。","nihao,shijie. → 你好，世界。")
        check(type("ni?").text == "你？" && type("ni!").text == "你！" && type("ni:").text == "你：","？！： after pinyin")
        check(type("ni=").preedit == "ni","= still pages the candidate menu")
        // Paging must keep going past page 2 (it used to snap back to page 1 before each key).
        let pages=(0...4).map { n in type("jieyuexingchen"+String(repeating:"{pgdn}",count:n)).candidates }
        check(Set(pages).count == pages.count && pages[3].contains("接") && pages[5-1].contains("皆"),"PageDown keeps paging past page 2, got \(pages.map { $0.prefix(2) })")
        check(type("jieyuexingchen====").candidates == pages[4],"= keeps paging past page 2")
        check(type("jieyuexingchen"+String(repeating:"{down}",count:20)).highlighted == 2 && type("jieyuexingchen"+String(repeating:"{down}",count:20)).candidates == pages[2],"↓ keeps moving through pages")
        check(type("\"nihao\"").text == "“你好”","paired Chinese quotes")
        check(type("ni\\").text == "你、","\\ → 、")
        check(type("ni/").text == "你/" && type("/usr").text == "/","/ commits a slash, no symbol lookup")
        check(type("ni<").text == "你《" && type("ni>").text == "你》","< > → 《 》")
        check(type("[ni]").text == "【你】","[ ] → 【】")
        // The rest follows macOS's own Pinyin keyboard layout.
        check(type("$5").text == "¥5" && type("ni`").text == "你·" && type("ni|").text == "你｜" && type("{lb}ni{rb}").text == "「你」","$ ` | { } match macOS Pinyin: ¥ · ｜ 「」")
        check(type("`a").preedit == "a","` commits at once, no reverse lookup")
        check(type("ni^").text == "你……" && type("ni_").text == "你——","…… and ——")
        check(type("3.14").text == "3.14" && type("12:30").text == "12:30","digit separators stay half-width")
        check(type("1~3").text == "1～3" && type("100%2").text == "100%2" && type("3*4=12").text == "3*4=12" && type("#2@3").text == "#2@3","~ % * = # @ commit directly instead of a menu that eats the next digit")
        check(type("hello{space}").text == "hello" && type("nihao,").text == "你好，","options saved by an older version (full-width, ASCII punctuation) are ignored")

        // Accidental Rime hotkeys must not hijack typing or change the output style.
        for (combo,label) in [("{c:`}","Control+`"),("{cs:#}","Control+Shift+3"),("{cs:$}","Control+Shift+4"),("{cs:@}","Control+Shift+2"),("{cs:!}","Control+Shift+1")] {
            // 回忆 differs from traditional 回憶; the second space would become a full-width 　.
            let result=type(combo+"huiyi{space}{space}")
            check(result.text == "回忆 " && result.preedit.isEmpty,"\(label) leaves typing unchanged, got \(result.text)")
        }

        // English words in Chinese mode.
        for (input,word) in [("hello","hello"),("github","GitHub"),("ok","OK"),("iphone","iPhone"),("deadline","deadline"),("macos","macOS"),("json","JSON"),("qq","QQ"),("sdk","SDK"),("true","true")] {
            check(first(input) == word,"\(input): English first, got \(type(input).candidates.prefix(3))")
        }
        for (input,word) in [("women","我们"),("you","有"),("he","和"),("ban","办"),("nihao","你好"),("pingan","平安"),("my","没有"),("by","不要"),("bus","不是"),("yes","也是"),("bug","不过"),("shy","使用")] {
            check(first(input) == word,"\(input): Chinese first, got \(type(input).candidates.prefix(3))")
        }
        check(!first("change").allSatisfy(\.isASCII),"change: full-syllable pinyin keeps Chinese first")
        check(type("agent").candidates.prefix(2) == ["阿根廷","agent"],"agent: reproduce the original Chinese/English ambiguity before learning")
        check(type("make").candidates.prefix(9).contains("make"),"make: English still on the first page")
        check(type("hello{space}").text == "hello","Space commits the English word")
        check(type("Hello{space}").text == "Hello","capitalised input stays English")
        check(type("iPhone{space}").text == "iPhone" && type("wo{space}iPad{space}").text == "我iPad","iPhone/iPad keep their lower-case i")
        check(!type("c").candidates.contains("C++") && type("cpp").candidates.first == "C++" && !type("win").candidates.contains("Win+"),"no key-combo fragments or C++ under c")

        // Shift commits the typed letters, including those behind a ← edit.
        check(type("hello{shift}").text == "hello","Shift after hello → hello")
        check(type("nihao{shift}").text == "nihao","Shift after nihao → nihao, not 你好")
        check(type("nihao{left}{shift}").text == "nihao" && type("zhongguoren{left}{left}{shift}").text == "zhongguoren","Shift after ← keeps the letters behind the caret")
        check(type("nihao{ret}").text == "nihao" && type("nihao{left}{ret}").text == "nihao","Return commits all letters, also after ←")
        check(type("{shift}nihao{space}").text == "你好","a Shift tap with nothing typed leaves Rime in Chinese")

        // Shift tap detection. The fake mouse age says how long ago the last click or scroll was.
        var toggle=ShiftToggle(); ShiftToggle.mouseAge={ 1000 }
        check(!toggle.observe(flags([.shift])) && toggle.observe(flags([])),"Shift tap toggles")
        toggle=ShiftToggle(); _ = toggle.observe(flags([.shift],timestamp:0))
        check(toggle.observe(flags([],timestamp:0)),"Shift tap toggles even when events carry timestamp 0")
        toggle=ShiftToggle(); _ = toggle.observe(flags([.shift])); _ = toggle.observe(key("A",[.shift]))
        check(!toggle.observe(flags([])),"Shift+letter does not toggle")
        toggle=ShiftToggle(); _ = toggle.observe(flags([.shift])); _ = toggle.observe(flags([.shift,.command],kVK_Command))
        check(!toggle.observe(flags([])),"Shift+Command does not toggle")
        toggle=ShiftToggle(); _ = toggle.observe(flags([.shift])); _ = toggle.observe(flags([.shift,.capsLock],kVK_CapsLock))
        check(!toggle.observe(flags([.capsLock])),"Shift+Caps Lock does not toggle")
        toggle=ShiftToggle(); _ = toggle.observe(flags([.shift])); ShiftToggle.mouseAge={ 0 }
        check(!toggle.observe(flags([])),"Shift-click / Shift-scroll does not toggle")
        toggle=ShiftToggle(); ShiftToggle.mouseAge={ 5 }; _ = toggle.observe(flags([.shift]))
        check(toggle.observe(flags([])),"a click before pressing Shift does not block the toggle")

        // Caps Lock passes only letters through; pending pinyin still owns Return, Esc, Delete, digits.
        check(echoCapsLetter(key("A",[.capsLock])) && !echoCapsLetter(key("a")),"Caps Lock letters pass through")
        check(!echoCapsLetter(key("\r",[.capsLock],kVK_Return)) && !echoCapsLetter(key("\u{1b}",[.capsLock],kVK_Escape)) && !echoCapsLetter(key("2",[.capsLock])) && !echoCapsLetter(key("\u{7f}",[.capsLock],kVK_Delete)),"Caps Lock leaves Return/Esc/digits/Delete to Rime")
        check(!echoCapsLetter(key("a",[.capsLock,.control])),"Caps Lock with Control is not a letter")

        // The workspace editor follows the same rules, with the Caps Lock setting kept in memory.
        let capsSettings=ScratchDefaults(suiteName:"echo.typing-check")!, realCaps=EchoCapsLock.defaults; EchoCapsLock.defaults=capsSettings
        let original=EchoTypingMode.english; EchoTypingMode.english=false
        let view=MemoryPromptView(frame:NSRect(x:0,y:0,width:500,height:86),textContainer:nil)
        ShiftToggle.mouseAge={ 1000 }
        for c in "hello" { view.keyDown(with:key(String(c))) }
        check(view.preedit == "hello","editor: pinyin composes before Shift, got \(view.preedit)")
        view.flagsChanged(with:flags([.shift])); view.flagsChanged(with:flags([]))
        check(view.string == "hello" && EchoTypingMode.english,"editor: Shift commits hello and switches to English, got \(view.string)")
        // Caps Lock (default): English while the light is on, letters stay lower case; the Shift mode is untouched.
        EchoTypingMode.english=false; view.setQuery(""); for c in "ni" { view.keyDown(with:key(String(c))) }
        view.flagsChanged(with:flags([.capsLock],kVK_CapsLock))
        check(view.string == "ni" && view.preedit.isEmpty,"editor: Caps Lock on commits pending letters, got \(view.string)")
        view.keyDown(with:key("A",[.capsLock])); view.keyDown(with:key("I",[.capsLock]))
        check(view.string == "niai" && !EchoTypingMode.english,"editor: light on types lower-case English, got \(view.string)")
        view.flagsChanged(with:flags([.shift,.capsLock])); view.flagsChanged(with:flags([.capsLock]))
        check(!EchoTypingMode.english,"editor: Shift tap with the light on does not flip the hidden mode")
        view.flagsChanged(with:flags([],kVK_CapsLock)); view.setQuery(""); for c in "ni" { view.keyDown(with:key(String(c))) }
        check(view.preedit == "ni","editor: light off returns to pinyin, got \(view.preedit)")
        check(EchoCapsLock.english([.capsLock]) && !EchoCapsLock.english([]),"light on means English, light off follows Shift")
        EchoTypingMode.english=true; check(EchoCapsLock.english([]),"Shift-chosen English stays with the light off"); EchoTypingMode.english=false
        // With the switch turned off, Caps Lock types capitals as before.
        capsSettings.set(false,forKey:"capsLockSwitchesMode")
        EchoTypingMode.english=false; view.setQuery("")
        view.keyDown(with:key("A",[.capsLock])); view.keyDown(with:key("I",[.capsLock]))
        check(view.string == "AI","editor: Caps Lock types capitals, got \(view.string)")
        view.setQuery(""); for c in "ni" { view.keyDown(with:key(String(c))) }
        check(view.preedit == "ni","editor: composes again after switching back to Chinese, got \(view.preedit)")
        view.keyDown(with:key("B",[.capsLock]))
        check(view.string == "niB","editor: Caps Lock commits pending letters first, got \(view.string)")
        view.setQuery(""); for c in "ni" { view.keyDown(with:key(String(c))) }; view.keyDown(with:key("\u{7f}",[.capsLock],kVK_Delete))
        check(view.preedit == "n","editor: Delete with Caps Lock still edits the pinyin, got \(view.preedit)")
        EchoCapsLock.defaults=realCaps
        // toggle() persists the mode; put the user's real setting back.
        EchoTypingMode.english=original; UserDefaults.standard.set(original,forKey:"englishMode")
        ShiftToggle.mouseAge={ [CGEventType.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel].map { CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:$0) }.min()! }

        // Caps Lock as the 中/英 switch: the light marks English and letters stay lower case.
        func typed(_ chars:String,_ ignoring:String,_ modifiers:NSEvent.ModifierFlags,_ code:Int) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:0,context:nil,characters:chars,charactersIgnoringModifiers:ignoring,isARepeat:false,keyCode:UInt16(code))!
        }
        check(EchoCapsLock.letter(typed("A","a",[.capsLock],kVK_ANSI_A)) == "a" && EchoCapsLock.letter(typed("A","A",[.capsLock,.shift],kVK_ANSI_A)) == "A","Caps Lock as English marker types lower case, Shift gives capitals")
        // Some apps send Shift+/ with "/" as the characters ignoring modifiers: Shift must still count.
        check(echoRimeKey(typed("?","/",[.shift],kVK_ANSI_Slash)) == 0x3f && echoRimeKey(typed("!","1",[.shift],kVK_ANSI_1)) == 0x21 && echoRimeKey(typed("A","a",[.shift],kVK_ANSI_A)) == 0x41,"Shift+key is read as typed (？！ capitals), got \(echoRimeKey(typed("?","/",[.shift],kVK_ANSI_Slash)) ?? -1)")
        check(echoRimeKey(typed("/","/",[],kVK_ANSI_Slash)) == 0x2f && echoRimeKey(typed("\u{1f}","/",[.control,.shift],kVK_ANSI_Slash)) == 0x2f,"plain and Control keys keep their base character")
        check(EchoCapsLock.letter(typed("A","a",[.capsLock,.shift],kVK_ANSI_A)) == "A","Caps Lock + Shift gives a capital even when the app reports it lower case")
        check(EchoCapsLock.letter(typed("1","1",[.capsLock],kVK_ANSI_1)) == nil && EchoCapsLock.letter(typed("a","a",[],kVK_ANSI_A)) == nil && EchoCapsLock.letter(typed("\u{1}","a",[.capsLock,.control],kVK_ANSI_A)) == nil,"only plain letters under Caps Lock are rewritten")

        // Customisable shortcuts, checked against in-memory settings.
        let scratch=ScratchDefaults(suiteName:"echo.typing-check")!, realDefaults=EchoShortcutSlot.defaults
        EchoShortcutSlot.defaults=scratch
        let all=EchoShortcut(keyCode:UInt16(kVK_ANSI_K),flags:[.command,.shift,.option,.control],key:"K")
        check(all.label == "⌃⌥⇧⌘K" && EchoShortcut(stored:all.stored) == all,"shortcut label order and storage round-trip")
        check(MemoryBinding.label == "⌃⇧M" && VoiceBinding.label == "⌃⌥D","default shortcuts")
        scratch.set("controlOptionM",forKey:"memoryShortcut"); let migrated=MemoryBinding.label
        scratch.set("optionSpace",forKey:"memoryShortcut")
        check(migrated == "⌃⌥M" && MemoryBinding.label == "⌥Space","0.6.4 memory presets carry over")
        let custom=EchoShortcut(keyCode:UInt16(kVK_ANSI_K),flags:[.control,.option],key:"K"); EchoShortcutSlot.memory.save(custom)
        check(MemoryBinding.label == "⌃⌥K" && scratch.string(forKey:"memoryShortcut") == nil && MemoryBinding.matches(typed("\u{b}","k",[.control,.option],kVK_ANSI_K)) && !MemoryBinding.matches(typed("\u{d}","m",[.control,.shift],kVK_ANSI_M)),"saved shortcut replaces the preset and drives matching")
        check(EchoShortcutSlot.memory.problem(EchoShortcut(keyCode:UInt16(kVK_ANSI_K),flags:[.command],key:"K")) != nil && EchoShortcutSlot.memory.problem(EchoShortcut(keyCode:UInt16(kVK_ANSI_K),flags:[.shift],key:"K")) != nil,"shortcuts need ⌃ or ⌥")
        check(EchoShortcutSlot.voice.problem(EchoShortcut(keyCode:UInt16(kVK_ANSI_D),flags:[.control,.shift],key:"D")) != nil && EchoShortcutSlot.voice.problem(EchoShortcut(keyCode:UInt16(kVK_Space),flags:[.control],key:"Space")) != nil,"system Dictation and input-source keys are refused")
        check(EchoShortcutSlot.voice.problem(custom) != nil && EchoShortcutSlot.voice.problem(EchoShortcut(keyCode:UInt16(kVK_ANSI_J),flags:[.control,.option],key:"J")) == nil,"duplicates refused, free chords accepted")
        check(EchoShortcutSlot.voice.problem(EchoShortcut(keyCode:UInt16(kVK_ANSI_K),flags:[.control,.option],key:"Л")) != nil,"duplicates are the same physical key whatever the layout names it")
        check(EchoShortcutSlot.voice.problem(EchoShortcut(keyCode:UInt16(kVK_Return),flags:[.control,.shift],key:"↩")) != nil && EchoShortcutSlot.voice.problem(EchoShortcut(keyCode:UInt16(kVK_RightArrow),flags:[.control],key:"→")) != nil,"Echo's ⌃⇧Return and Mission Control ⌃-arrows are reserved")
        let recorded=EchoShortcut(recording:typed("\u{b}","k",[.control,.option],kVK_ANSI_K)), function=EchoShortcut(recording:typed("\u{f708}","\u{f708}",[.control,.option],kVK_F5))
        check(recorded?.label == "⌃⌥K" && function?.label == "⌃⌥F5","recorder names letter and function keys")
        EchoShortcutSlot.memory.save(nil)
        check(MemoryBinding.label == "⌃⇧M" && scratch.string(forKey:"memoryHotKey") == nil,"restore default clears the setting")
        EchoShortcutSlot.defaults=realDefaults

        // Selecting candidates teaches Rime's user dictionary, so these run last.
        let partial=type("woyong").candidates.firstIndex(of:"我") ?? 0
        let chosen=type("woyong\(partial+1)")
        check(chosen.preedit.hasPrefix("我") && chosen.cursor == chosen.preedit.utf16.count,"caret reported in UTF-16 after 我, got \(chosen.cursor) for \(chosen.preedit)")
        check(type("woyong\(partial+1){shift}").text == "我yong","Shift keeps the chosen 我 and commits yong")
        let moved=type("ni{down}")
        check(moved.highlighted == 1 && type("ni{down}{space}").text == moved.candidates[1],"Down moves highlight and Space commits it")

        // Fresh English candidates preserve Chinese defaults; an explicit choice must change that order.
        check(select("agent",word:"agent",number:true) == "agent","agent: numeric selection commits the English word")
        for attempt in 1...5 {
            let candidates=type("agent").candidates
            check(candidates.first == "agent" && candidates.contains("阿根廷") && candidates.filter { $0 == "agent" }.count == 1,"agent: selection \(attempt) makes English first without dropping Chinese or duplicating English, got \(candidates.prefix(3))")
            check(type("agent{space}").text == "agent","agent: Space uses the learned first candidate")
        }
        check(select("change",word:"change",number:false) == "change","change: panel selection commits the English word")
        check(first("change") == "change","change: panel selection also promotes English over full-syllable pinyin")
        check(first("women") == "我们" && first("bus") == "不是" && first("yes") == "也是" && first("bug") == "不过","learning one word leaves unselected pinyin/abbreviations Chinese first")

        finish("typing checks (punctuation, English words and learning, Shift, Caps Lock, hotkeys)")
    }
}

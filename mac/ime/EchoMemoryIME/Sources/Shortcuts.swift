import Cocoa
import Carbon

// A user-assignable global shortcut: virtual key code, modifiers, and the key's display name.
struct EchoShortcut:Equatable {
    static let relevant:NSEvent.ModifierFlags=[.control,.option,.shift,.command]
    var keyCode:UInt16, flags:NSEvent.ModifierFlags, key:String
    init(keyCode:UInt16,flags:NSEvent.ModifierFlags,key:String) { self.keyCode=keyCode; self.flags=flags.intersection(Self.relevant); self.key=key }
    init?(stored:String) {
        let parts=stored.split(separator:" ",maxSplits:2).map(String.init)
        guard parts.count == 3,let code=UInt16(parts[0]),let raw=UInt(parts[1]) else { return nil }
        self.init(keyCode:code,flags:NSEvent.ModifierFlags(rawValue:raw),key:parts[2])
    }
    // A key press captured by the recorder; nil for keys that cannot name a shortcut.
    init?(recording event:NSEvent) {
        let named:[Int:String]=[kVK_Space:"Space",kVK_Return:"↩",kVK_Tab:"⇥",kVK_Delete:"⌫",kVK_ForwardDelete:"⌦",kVK_LeftArrow:"←",kVK_RightArrow:"→",kVK_UpArrow:"↑",kVK_DownArrow:"↓",
            kVK_F1:"F1",kVK_F2:"F2",kVK_F3:"F3",kVK_F4:"F4",kVK_F5:"F5",kVK_F6:"F6",kVK_F7:"F7",kVK_F8:"F8",kVK_F9:"F9",kVK_F10:"F10",kVK_F11:"F11",kVK_F12:"F12"]
        let base=event.characters(byApplyingModifiers:[])?.uppercased() ?? ""
        guard let key=named[Int(event.keyCode)] ?? (base.count == 1 && base.unicodeScalars.allSatisfy({ $0.isASCII && $0.value>0x20 && $0.value<0x7f }) ? base : nil) else { return nil }
        self.init(keyCode:event.keyCode,flags:event.modifierFlags,key:key)
    }
    var stored:String { "\(keyCode) \(flags.rawValue) \(key)" }
    // Apple's order: ⌃⌥⇧⌘ then the key.
    var label:String { (flags.contains(.control) ? "⌃" : "")+(flags.contains(.option) ? "⌥" : "")+(flags.contains(.shift) ? "⇧" : "")+(flags.contains(.command) ? "⌘" : "")+key }
    var carbonModifiers:UInt32 {
        UInt32((flags.contains(.control) ? controlKey : 0)|(flags.contains(.option) ? optionKey : 0)|(flags.contains(.shift) ? shiftKey : 0)|(flags.contains(.command) ? cmdKey : 0))
    }
    func matches(_ event:NSEvent)->Bool { event.keyCode == keyCode && event.modifierFlags.intersection(Self.relevant) == flags }
    // The physical chord; the key's display name depends on the keyboard layout.
    static func ==(a:EchoShortcut,b:EchoShortcut)->Bool { a.keyCode == b.keyCode && a.flags == b.flags }
}

enum EchoShortcutSlot:CaseIterable {
    case memory, voice
    static var defaults=UserDefaults.standard  // tests swap in a scratch domain
    var title:String { self == .memory ? "调用记忆" : "语音输入" }
    var defaultsKey:String { self == .memory ? "memoryHotKey" : "voiceHotKey" }
    // ⌃⌥D because this Mac uses ⌃⇧D for system Dictation.
    var fallback:EchoShortcut { self == .memory ? EchoShortcut(keyCode:UInt16(kVK_ANSI_M),flags:[.control,.shift],key:"M") : EchoShortcut(keyCode:UInt16(kVK_ANSI_D),flags:[.control,.option],key:"D") }
    var current:EchoShortcut {
        if let stored=Self.defaults.string(forKey:defaultsKey),let shortcut=EchoShortcut(stored:stored) { return shortcut }
        // Presets from 0.6.4 and earlier.
        if self == .memory,let legacy=Self.defaults.string(forKey:"memoryShortcut") {
            if legacy == "controlOptionM" { return EchoShortcut(keyCode:UInt16(kVK_ANSI_M),flags:[.control,.option],key:"M") }
            if legacy == "optionSpace" { return EchoShortcut(keyCode:UInt16(kVK_Space),flags:[.option],key:"Space") }
        }
        return fallback
    }
    func save(_ shortcut:EchoShortcut?) {
        if let shortcut,shortcut != fallback { Self.defaults.set(shortcut.stored,forKey:defaultsKey) } else { Self.defaults.removeObject(forKey:defaultsKey) }
        if self == .memory { Self.defaults.removeObject(forKey:"memoryShortcut") }
    }
    // Why a recorded shortcut cannot be used, or nil when it can. Other apps' global shortcuts cannot be
    // detected (macOS accepts a duplicate registration silently), so known system and Echo keys are listed.
    func problem(_ shortcut:EchoShortcut)->String? {
        let code=Int(shortcut.keyCode)
        if !shortcut.flags.contains(.control) && !shortcut.flags.contains(.option) { return "需要包含 ⌃ 或 ⌥，否则会和打字或 App 快捷键冲突" }
        if code == kVK_Escape { return "Esc 用于取消，不能作为快捷键" }
        if code == kVK_Space && shortcut.flags.contains(.control) { return "用于切换输入法" }
        if code == kVK_ANSI_D && shortcut.flags == [.control,.shift] { return "用于系统听写" }
        if code == kVK_Return && shortcut.flags == [.control,.shift] { return "用于从记忆工作台填入" }
        if [kVK_LeftArrow,kVK_RightArrow,kVK_UpArrow,kVK_DownArrow].contains(code) && shortcut.flags == [.control] { return "用于调度中心和切换桌面" }
        if let other=EchoShortcutSlot.allCases.first(where:{ $0 != self && $0.current == shortcut }) { return "已用于「\(other.title)」" }
        return nil
    }
}
enum MemoryBinding {
    static var label:String { EchoShortcutSlot.memory.current.label }
    static func matches(_ event:NSEvent)->Bool { EchoShortcutSlot.memory.current.matches(event) }
}
enum VoiceBinding {
    static var label:String { EchoShortcutSlot.voice.current.label }
    static func matches(_ event:NSEvent)->Bool { EchoShortcutSlot.voice.current.matches(event) }
}

import Cocoa
import Carbon
import CoreAudio
import Combine

enum AU05Keymap {
    // macOS virtual key codes -> USB keyboard usages. Physical keys, independent of labels/layout.
    static let usages:[UInt16:UInt8]=[0:4,1:22,2:7,3:9,4:11,5:10,6:29,7:27,8:6,9:25,11:5,12:20,13:26,14:8,15:21,16:28,17:23,18:30,19:31,20:32,21:33,22:35,23:34,24:46,25:38,26:36,27:45,28:37,29:39,30:48,31:18,32:24,33:47,34:12,35:19,36:40,37:15,38:13,39:52,40:14,41:51,42:49,43:54,44:56,45:17,46:16,47:55,48:43,49:44,50:53,51:42,53:41,96:62,97:63,98:64,99:60,100:65,101:66,103:68,109:67,111:69,118:61,120:59,122:58,123:80,124:79,125:81,126:82]
    static func chord(_ shortcut:EchoShortcut)throws->[AU05Key] {
        guard let key=usages[shortcut.keyCode] else { throw AU05Failure.message("AU05 暂不支持快捷键 \(shortcut.label)，请在 APT 的快捷键设置中换一个。") }
        var modifiers:UInt8=0
        if shortcut.flags.contains(.control) { modifiers |= 1 }
        if shortcut.flags.contains(.shift) { modifiers |= 2 }
        if shortcut.flags.contains(.option) { modifiers |= 4 }
        if shortcut.flags.contains(.command) { modifiers |= 8 }
        return (modifiers == 0 ? [] : [AU05Key(page:3,value:modifiers)])+[AU05Key(page:2,value:key)]
    }
    static func echo()throws->[[AU05Key]] {
        try [chord(EchoShortcutSlot.voice.current),chord(EchoShortcutSlot.memory.current),[AU05Key(page:2,value:41)],[AU05Key(page:2,value:43)],[AU05Key(page:2,value:82)],[AU05Key(page:2,value:81)]]
    }
    // Snapshot before the first write, verify every slot, and roll back touched slots on failure.
    // Closures retain a connection lease so a reconnected/different device is never a rollback target.
    static func apply(_ target:[[AU05Key]],read:(Int)async throws->[AU05Key],write:(Int,[AU05Key])async throws->Void,backup:([[AU05Key]])throws->Void)async throws {
        guard target.count == 6 else { throw AU05Failure.message("按键配置不完整。") }
        var original:[[AU05Key]]=[]
        for slot in 0..<6 { original.append(try await read(slot)) }
        try backup(original)
        var changed:[Int]=[]
        do {
            for slot in 0..<6 where original[slot] != target[slot] {
                changed.append(slot); try await write(slot,target[slot])
                guard try await read(slot) == target[slot] else { throw AU05Failure.message("按键 \(slot+1) 的配置读回不一致。") }
            }
        } catch {
            var unrestored:[Int]=[]
            for slot in changed.reversed() {
                do { try await write(slot,original[slot]); if try await read(slot) != original[slot] { unrestored.append(slot) } }
                catch { unrestored.append(slot) }
            }
            let suffix=unrestored.isEmpty ? "已恢复修改前的按键配置。" : "部分按键未能恢复；连接设备后点「恢复原按键配置」。"
            throw AU05Failure.message(error.localizedDescription+suffix)
        }
    }
}

struct AU05Feedback {
    enum Source { case voice, memory }
    enum Phase { case idle, listening, working, waiting, success, failure }
    var voice=Phase.idle, memory=Phase.idle
    var phase:Phase { voice == .idle ? memory : voice }
    var light:AU05Protocol.Light {
        switch phase {
        case .idle: return .automatic
        case .working,.failure: return .breathing
        case .listening,.waiting,.success: return .solid
        }
    }
    mutating func set(_ source:Source,_ phase:Phase) { if source == .voice { voice=phase } else { memory=phase } }
}

// All user-facing state and Echo events belong to the main thread; AU05HID owns USB I/O.
final class AU05Controller:ObservableObject {
    static let shared=AU05Controller()
    @Published private(set) var enabled:Bool
    @Published private(set) var lights:Bool
    @Published private(set) var ready=false
    @Published private(set) var awake=false
    @Published private(set) var busy=false
    @Published private(set) var connected=false
    @Published private(set) var status="尚未启用 AU05"
    @Published private(set) var note=""
    @Published private(set) var firmware=""
    @Published private(set) var battery:Int?
    @Published private(set) var noise:Int?
    @Published private(set) var sleep:UInt32?
    @Published private(set) var hasBackup=false
    @Published private(set) var permissionRequired=false
    @Published private(set) var lightReady=false
    private let defaults:UserDefaults, hid=AU05HID()
    private var lease:UUID?, deviceID="", feedback=AU05Feedback(), feedbackTask:Task<Void,Never>?, refreshTask:Task<Void,Never>?
    private var feedbackGeneration=UUID(), originalLight=AU05Protocol.light(.automatic)
    private var voiceGeneration=UUID(), memoryGeneration=UUID(), ownsLights=false
    private var sleeping=false, sleepObservers:[NSObjectProtocol]=[]
    static var live:Bool { !CommandLine.arguments.contains { $0.hasPrefix("--verify-") || $0.hasPrefix("--demo") || $0 == "--au05-probe" } }
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults; enabled=defaults.bool(forKey:"au05Enabled"); lights=defaults.bool(forKey:"au05Lights")
        hid.presence={ [weak self] value in self?.presence(value) }
        hid.activity={ [weak self] in guard let self else { return }; if !self.awake,!self.busy { self.refresh() } }
        hid.failure={ [weak self] message,permission in self?.permissionRequired=permission; self?.status="AU05 连接未完成"; self?.note=message }
    }
    func startIfEnabled() { if enabled,Self.live { connect() } }
    func setEnabled(_ value:Bool) {
        enabled=value; defaults.set(value,forKey:"au05Enabled")
        if value { connect() }
        else { feedbackTask?.cancel(); refreshTask?.cancel(); lease=nil; ready=false; connected=false; busy=false; status="尚未启用 AU05"; hid.stop { if self.enabled { self.connect() } } }
    }
    func connect() {
        guard enabled,Self.live,!sleeping else { return }
        if sleepObservers.isEmpty {
            let center=NSWorkspace.shared.notificationCenter
            sleepObservers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
                guard let self else { return }; self.sleeping=true; self.stop { if self.enabled,!self.sleeping { self.connect() } }
            })
            sleepObservers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
                guard let self else { return }; self.sleeping=false; if self.enabled { self.connect() }
            })
        }
        permissionRequired=false
        status="等待 AU05 接收器"; hid.start()
    }
    func authorize() { AU05HID.requestAccess(); connect() }
    func openPermissions() { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!) }
    private func presence(_ value:UUID?) {
        refreshTask?.cancel(); feedbackTask?.cancel(); lease=value; connected=value != nil; ready=false; awake=false; busy=false
        firmware=""; battery=nil; noise=nil; sleep=nil; deviceID=""; hasBackup=false
        ownsLights=false; lightReady=false
        status=value == nil ? (enabled ? "等待 AU05 接收器" : "尚未启用 AU05") : "正在连接 AU05"
        if value != nil { refresh() }
    }
    func refresh() {
        guard !busy else { return }
        guard let connection=lease else { hid.stop { if self.enabled { self.connect() } }; return }
        busy=true; note=""
        refreshTask=Task { @MainActor in
            defer { if self.lease == connection { self.busy=false } }
            do {
                let code=UInt32.random(in:1...UInt32.max), auth:[UInt8]=[6,2,5,1,UInt8(code&15)]+AU05Protocol.little(code)
                let reply=try await self.hid.command(auth,lease:connection)
                guard AU05Protocol.acknowledgedAuth(reply) else { throw AU05Failure.message("AU05 连接认证失败，请重新插拔接收器。") }
                let sn=try await self.hid.command([6,2,0x81,1],lease:connection)
                guard self.lease == connection else { return }
                self.deviceID=String(bytes:sn.dropFirst(7).prefix(20).prefix { $0>=32 && $0<127 },encoding:.ascii) ?? ""
                self.hasBackup = !self.deviceID.isEmpty && self.defaults.data(forKey:self.backupKey) != nil
                let active=try await self.hid.command([6,3,0x0A,1],lease:connection)
                guard self.lease == connection else { return }
                self.ready=true; self.awake=active.count>4 && active[4] != 0
                self.status=self.awake ? "AU05 已连接" : "接收器已连接 · 请开机或按键唤醒 AU05"
                guard self.awake else { return }
                if !self.ownsLights {
                    do {
                        let light=try await self.hid.command([1,0x0B,0x88,1],lease:connection)
                        self.originalLight=try AU05Protocol.restoreLight(light); self.lightReady=true
                    } catch { self.lightReady=false; self.note="原灯光配置尚未读取，请刷新后再启用灯光联动。" }
                }
                if let version=try? await self.hid.command([1,4,4,1],lease:connection),version.count>=13 { self.firmware="\(version[10]).\(version[11]).\(version[12])" }
                if let power=try? await self.hid.command([1,1,2,1],lease:connection),power.count>=8 { self.battery=min(100,Int(power[6])|(Int(power[7])<<8)) }
                if let nr=try? await self.hid.command([1,1,0x90,1],lease:connection),nr.count>=5,nr[4]<=3 { self.noise=Int(nr[4]) }
                if let seconds=try? await self.hid.command([1,1,0x42,1],lease:connection),seconds.count>=8 { self.sleep=AU05Protocol.word(seconds,4) }
                guard self.lease == connection,!Task.isCancelled else { return }
                self.applyFeedback()
            } catch {
                guard self.lease == connection,!Task.isCancelled else { return }
                self.status="AU05 连接未完成"; self.note=error.localizedDescription
            }
        }
    }
    private var backupKey:String { "au05Backup."+deviceID }
    func configure(restore:Bool=false) {
        guard let connection=lease,ready,awake,!busy else { return }
        busy=true; note=restore ? "正在恢复按键配置…" : "正在配置 APT 按键…"
        Task { @MainActor in
            defer { if self.lease == connection { self.busy=false } }
            do {
                guard !self.deviceID.isEmpty else { throw AU05Failure.message("尚未读到设备身份，请刷新连接后重试。") }
                let target:[[AU05Key]]
                if restore {
                    guard let data=self.defaults.data(forKey:self.backupKey) else { throw AU05Failure.message("没有这台设备的原按键备份。") }
                    target=try JSONDecoder().decode([[AU05Key]].self,from:data)
                } else { target=try AU05Keymap.echo() }
                let key=self.backupKey
                try await AU05Keymap.apply(target,read:{ slot in
                    try AU05Protocol.mapping(await self.hid.command(AU05Protocol.readMapping(slot),lease:connection),slot:slot)
                },write:{ slot,entries in
                    _ = try await self.hid.command(AU05Protocol.writeMapping(slot,entries),lease:connection,reply:false)
                    try await Task.sleep(nanoseconds:120_000_000)
                },backup:{ original in
                    if self.defaults.data(forKey:key) == nil { self.defaults.set(try JSONEncoder().encode(original),forKey:key) }
                    self.hasBackup=true
                })
                guard self.lease == connection else { return }
                self.note=restore ? "原按键配置已恢复，并已读回核对。" : "APT 按键已保存到 AU05，并已读回核对。按住语音键说话，松开后识别。"
            } catch { if self.lease == connection { self.note=error.localizedDescription } }
        }
    }
    func setNoise(_ value:Int) { guard (0...3).contains(value) else { return }; setting([1,1,0x90,4,UInt8(value)],read:[1,1,0x90,1],expected:[UInt8(value)],label:"降噪") { self.noise=value } }
    func setSleep(_ value:UInt32) { guard [UInt32(0),3600,7200,10800,14400].contains(value) else { return }; setting([1,1,0x42,2]+AU05Protocol.little(value),read:[1,1,0x42,1],expected:AU05Protocol.little(value),label:"休眠时间") { self.sleep=value } }
    private func setting(_ payload:[UInt8],read:[UInt8],expected:[UInt8],label:String,done:@escaping ()->Void) {
        guard let connection=lease,awake,!busy else { return }; busy=true; note="正在设置\(label)…"
        Task { @MainActor in
            defer { if self.lease == connection { self.busy=false } }
            do {
                _ = try await self.hid.command(payload,lease:connection,reply:false); try await Task.sleep(nanoseconds:120_000_000)
                let reply=try await self.hid.command(read,lease:connection)
                guard Array(reply.dropFirst(4).prefix(expected.count)) == expected else { throw AU05Failure.message("\(label)未通过设备读回核对，请刷新后重试。") }
                guard self.lease == connection else { return }; done(); self.note="\(label)已保存并核对。"
            } catch { if self.lease == connection { self.note=error.localizedDescription } }
        }
    }
    func setLights(_ value:Bool) {
        lights=value; defaults.set(value,forKey:"au05Lights")
        applyFeedback()
    }
    func event(_ source:AU05Feedback.Source,_ phase:AU05Feedback.Phase) {
        guard Self.live else { return }
        let generation=UUID()
        if source == .voice { voiceGeneration=generation } else { memoryGeneration=generation }
        feedback.set(source,phase); applyFeedback()
        if phase == .success || phase == .failure {
            DispatchQueue.main.asyncAfter(deadline:.now()+1.3) {
                guard (source == .voice ? self.voiceGeneration : self.memoryGeneration) == generation else { return }; self.feedback.set(source,.idle); self.applyFeedback()
            }
        }
    }
    private func applyFeedback() {
        feedbackGeneration=UUID(); feedbackTask?.cancel()
        guard enabled,ready,awake,lightReady,let connection=lease else { return }
        guard lights || ownsLights else { return }
        let phase=lights ? feedback.phase : .idle, payload=phase == .idle ? originalLight : AU05Protocol.light(feedback.light)
        ownsLights=lights
        hid.restoreOnClose(originalLight); hid.keepAlive(for:phase == .idle ? 0 : 300)
        feedbackTask=Task { @MainActor in
            do {
                _ = try await self.hid.command(payload,lease:connection,reply:false)
                if phase == .failure {
                    for _ in 0..<2 {
                        try await Task.sleep(nanoseconds:200_000_000); try Task.checkCancellation()
                        _ = try await self.hid.command(AU05Protocol.light(.off),lease:connection,reply:false)
                        try await Task.sleep(nanoseconds:200_000_000); try Task.checkCancellation()
                        _ = try await self.hid.command(AU05Protocol.light(.solid),lease:connection,reply:false)
                    }
                }
            } catch { if !Task.isCancelled,self.lease == connection { self.note="灯光更新失败："+error.localizedDescription } }
        }
    }
    func testLights() {
        guard let connection=lease,awake,lightReady,!busy else { return }; busy=true; feedbackTask?.cancel(); note="观察 AU05：常亮 → 呼吸 → 熄灭。"
        Task { @MainActor in
            do {
                self.ownsLights=true; self.hid.restoreOnClose(self.originalLight)
                for mode in [AU05Protocol.Light.solid,.breathing,.off] {
                    _ = try await self.hid.command(AU05Protocol.light(mode),lease:connection,reply:false)
                    try await Task.sleep(nanoseconds:800_000_000)
                }
                self.note="测试指令已发送。请以设备实际灯效为准。"
            } catch { if self.lease == connection { self.note=error.localizedDescription } }
            if self.lease == connection { self.busy=false; self.applyFeedback() }
        }
    }
    func stop(completion:@escaping ()->Void = {}) { feedbackTask?.cancel(); refreshTask?.cancel(); hid.stop(completion:completion) }
    func useMicrophone() {
        guard !VoiceInput.shared.busy else { note="请先结束录音或识别，再切换麦克风。"; return }
        do { try AU05Audio.select(); VoiceInput.shared.recorderPool.discard(); note="系统输入麦克风已切换为 AU05。" }
        catch { note=error.localizedDescription }
    }
}

enum AU05Audio {
    static func select()throws {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain), size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size) == noErr,size>0 else { throw AU05Failure.message("无法读取麦克风列表。") }
        var devices=Array(repeating:AudioDeviceID(0),count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        let result=devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,$0.baseAddress!) }
        guard result == noErr,!devices.isEmpty else { throw AU05Failure.message("无法读取麦克风列表。") }
        for var device in devices {
            var rawName:UnsafeRawPointer?, length=UInt32(MemoryLayout<UnsafeRawPointer?>.size)
            var nameAddress=AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyName,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device,&nameAddress,0,nil,&length,&rawName) == noErr,let rawName else { continue }
            let name=Unmanaged<CFString>.fromOpaque(rawName).takeRetainedValue() as String
            guard name.uppercased().contains("AU05") else { continue }
            var streams=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioDevicePropertyScopeInput,mElement:kAudioObjectPropertyElementMain), streamSize:UInt32=0
            guard AudioObjectGetPropertyDataSize(device,&streams,0,nil,&streamSize) == noErr,streamSize>0 else { continue }
            var input=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),&input,0,nil,UInt32(MemoryLayout<AudioDeviceID>.size),&device) == noErr else { throw AU05Failure.message("切换麦克风失败，请在系统设置 › 声音 › 输入中选择 AU05。") }
            return
        }
        throw AU05Failure.message("没有找到 AU05 麦克风，请连接接收器并唤醒设备。")
    }
}

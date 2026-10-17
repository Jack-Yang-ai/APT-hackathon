import Cocoa

enum AU05Checks {
    static func check(_ value:Bool,_ message:String)throws { if !value { throw AU05Failure.message(message) } }
    @MainActor static func run()async throws {
        // Reference vector from the independent Python implementation, not our own round trip.
        let auth:[UInt8]=[6,2,5,1,8,0x78,0x34,0x56,0x12]
        let expected="282799035e57514b192cc3926a9c08d3"
        let report=try AU05Protocol.report(auth)
        try check(report.count == 64 && report[0] == 0x55,"HID output report length")
        try check(report.dropFirst().prefix(16).map { String(format:"%02x",$0) }.joined() == expected,"TEA independent reference vector")
        try check(Array(try AU05Protocol.decode(report).prefix(auth.count)) == auth,"full HID input report decode")
        try check(Array(try AU05Protocol.decode(Array(report.dropFirst())).prefix(auth.count)) == auth,"payload-only input report decode")
        let liveAuth:[UInt8]=[6,2,5,0x11,8,0xF0,0x2D,0x76,0x55]
        try check(AU05Protocol.acknowledgedAuth(liveAuth),"real AU05 transformed challenge acknowledged")
        try check(AU05Protocol.acknowledgedAuth([6,2,5,0x11,2,0xBF,0x17,0xFD,0xBA]),"second real transformed auth response acknowledged")
        try check(!AU05Protocol.acknowledgedAuth([6,2,5,0x11,8]),"truncated authentication rejected")
        try check(!AU05Protocol.acknowledgedAuth([6,2,5,1,8,0,0,0,0]),"request cannot be mistaken for authentication acknowledgement")
        do { _ = try AU05Protocol.report(Array(repeating:0,count:57)); throw AU05Failure.message("accepted fields in truncated block") } catch AU05Failure.message(let message) { try check(message != "accepted fields in truncated block",message) }
        do { _ = try AU05Protocol.decode([0x55,0]); throw AU05Failure.message("accepted truncated input") } catch AU05Failure.message(let message) { try check(message != "accepted truncated input",message) }
        try check(!AU05Protocol.matches([0x81,6,0x50,0x14,0],AU05Protocol.readMapping(0)),"write acknowledgement cannot resolve a read")
        try check(!AU05Protocol.matches([0x81,6,0x50,0x11,1],AU05Protocol.readMapping(0)),"a different slot cannot resolve a read")
        try check(try AU05Protocol.mapping([0x81,6,0x50,0x11,0,1,2,3,5,2,7],slot:0) == [AU05Key(page:3,value:5),AU05Key(page:2,value:7)],"keymap read format")
        try check(try AU05Protocol.mapping([0x81,6,0x50,0x11,0,0,0],slot:0).isEmpty,"real AU05 unconfigured keymap format")
        let lights:[UInt8]=[0x81,0x0B,0x88,0x11,0,0,2,7]+Array(repeating:[UInt8(2),10,2,7,2],count:4).flatMap { $0 }
        let restored=try AU05Protocol.restoreLight(lights)
        try check(restored.count == 28 && Array(restored.dropFirst(5)) == Array(lights[5..<28]),"preserve full original light mode, brightness and channel settings")
        try check(AU05Protocol.light(.breathing)[4] == 0x7F && AU05Protocol.light(.breathing)[6] == 2,"breathing also leaves all-on mode")
        let previous=EchoShortcutSlot.defaults
        EchoShortcutSlot.defaults=ScratchDefaults(suiteName:"echo.au05-check")!
        defer { EchoShortcutSlot.defaults=previous }
        let target=try AU05Keymap.echo()
        try check(target[0] == [AU05Key(page:3,value:5),AU05Key(page:2,value:7)] && target[1] == [AU05Key(page:3,value:3),AU05Key(page:2,value:16)],"Echo voice/memory default chords")
        try check(target[3] == [AU05Key(page:2,value:43)] && target[4] == [AU05Key(page:2,value:82)] && target[5] == [AU05Key(page:2,value:81)],"knob press/left/right slot order")
        let original=(0..<6).map { [AU05Key(page:2,value:UInt8(30+$0))] }
        var hardware=original, backedUp=false, written:[Int]=[]
        try await AU05Keymap.apply(target,read:{ hardware[$0] },write:{ slot,entries in
            try check(backedUp,"write before backup"); written.append(slot); hardware[slot]=entries
        },backup:{ try check($0 == original,"wrong backup"); backedUp=true })
        try check(hardware == target && written.count == 6,"configured six slots")
        // Firmware mutates the slot then reports an error: restore even the ambiguous final write.
        hardware=original; written=[]; var failOnce=true
        do {
            try await AU05Keymap.apply(target,read:{ hardware[$0] },write:{ slot,entries in
                hardware[slot]=entries; written.append(slot)
                if slot == 2,failOnce { failOnce=false; throw AU05Failure.message("simulated disconnect") }
            },backup:{ _ in })
            throw AU05Failure.message("transaction swallowed a failure")
        } catch { try check(hardware == original && written == [0,1,2,2,1,0],"partial transaction rollback") }
        // A device accepts a packet but readback differs: never claim success.
        hardware=original; var ignored=true
        do {
            try await AU05Keymap.apply(target,read:{ hardware[$0] },write:{ slot,entries in
                if ignored { ignored=false; return }; hardware[slot]=entries
            },backup:{ _ in })
            throw AU05Failure.message("accepted mismatched readback")
        } catch { try check(hardware == original && error.localizedDescription.contains("读回"),"readback mismatch rejected") }
        var feedback=AU05Feedback()
        feedback.set(.memory,.working); try check(feedback.light == .breathing,"lookup feedback")
        feedback.set(.voice,.listening); try check(feedback.light == .solid,"voice takes priority")
        feedback.set(.memory,.idle); try check(feedback.light == .solid,"memory cancellation does not clear voice feedback")
        feedback.set(.voice,.idle); try check(feedback.light == .automatic,"idle restores hardware mode")
        let hid=AU05HID()
        do { _ = try await hid.command([6,3,10,1],lease:UUID()); throw AU05Failure.message("disconnected transport accepted command") }
        catch { try check(error.localizedDescription.contains("尚未连接"),"disconnected transport fails promptly") }
        try check(!AU05Controller.live,"checks never activate live hardware")
        print("PASS: AU05 — independent TEA vector, HID framing, reply/slot matching, Echo keymap, backup before writing, partial rollback, readback verification, feedback priority and disconnected transport")
    }
}

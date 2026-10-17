import Foundation

// AU05 wire format, independently wrapped for Echo. TEA framing follows the MIT-licensed
// VibeKey Elements implementation: github.com/patrick-fu/vibekey-elements.
// Keymap commands: github.com/eddix/webhid-config-collection/blob/main/vibekey/PROTOCOL.md.
enum AU05Failure:Error,LocalizedError {
    case message(String)
    var errorDescription:String? { if case .message(let text)=self { return text }; return nil }
}
struct AU05Key:Codable,Equatable {
    var page:UInt8, value:UInt8
}
enum AU05Protocol {
    static let vendor=0xFFF1, product=0x00DD, usagePage=0xFFFC, reportID=0x55
    static let key:[UInt32]=[0xCAA5BACA,0xBC2A8A6D,0xCA5A9EBA,0x9BB88BCA]
    static func word(_ bytes:[UInt8],_ offset:Int)->UInt32 {
        (0..<4).reduce(0) { $0 | (UInt32(bytes[offset+$1]) << ($1*8)) }
    }
    static func little(_ value:UInt32)->[UInt8] { (0..<4).map { UInt8(truncatingIfNeeded:value >> ($0*8)) } }
    static func crypt(_ bytes:[UInt8],decrypt:Bool=false)throws->[UInt8] {
        guard !bytes.isEmpty,bytes.count % 8 == 0 else { throw AU05Failure.message("设备数据长度异常。") }
        var output:[UInt8]=[]
        for offset in stride(from:0,to:bytes.count,by:8) {
            var a=word(bytes,offset), b=word(bytes,offset+4), sum:UInt32=decrypt ? 0xC6EF3720 : 0
            for _ in 0..<32 {
                if decrypt {
                    b = b &- (((a << 4) &+ key[2]) ^ (a &+ sum) ^ ((a >> 5) &+ key[3]))
                    a = a &- (((b << 4) &+ key[0]) ^ (b &+ sum) ^ ((b >> 5) &+ key[1]))
                    sum = sum &- 0x9E3779B9
                } else {
                    sum = sum &+ 0x9E3779B9
                    a = a &+ (((b << 4) &+ key[0]) ^ (b &+ sum) ^ ((b >> 5) &+ key[1]))
                    b = b &+ (((a << 4) &+ key[2]) ^ (a &+ sum) ^ ((a >> 5) &+ key[3]))
                }
            }
            output += little(a)+little(b)
        }
        return output
    }
    static func report(_ payload:[UInt8])throws->[UInt8] {
        // The final incomplete TEA block is truncated by the HID descriptor. All fields must
        // fit in the first seven complete blocks, including any custom key mapping.
        guard !payload.isEmpty,payload.count<=56 else { throw AU05Failure.message("设备指令过长。") }
        return [UInt8(reportID)] + (try crypt(payload+Array(repeating:0,count:64-payload.count))).prefix(63)
    }
    static func decode(_ report:[UInt8])throws->[UInt8] {
        guard report.count == 63 || (report.count == 64 && report.first == UInt8(reportID)) else { throw AU05Failure.message("设备报告格式异常。") }
        let data=report.count == 64 ? Array(report.dropFirst()) : report
        return try crypt(Array(data.prefix(56)),decrypt:true)
    }
    static func matches(_ response:[UInt8],_ request:[UInt8])->Bool {
        guard response.count>=4,request.count>=4,response[0]&0x7F == request[0],response[1] == request[1],response[2] == request[2],response[3] == 0x11 else { return false }
        if request[1] == 6,request[2] == 0x50 { return request.count>=5 && response.count>=5 && request[4] == response[4] }
        return true
    }
    // AU05 firmware returns an opaque transformed challenge. Neither its four bytes nor its
    // preceding nibble reliably echo the request. As in the community WebHID implementation,
    // accept a complete encrypted acknowledgement from this leased vendor interface; the next
    // commands independently read the dongle identity and actual wireless-link state.
    static func acknowledgedAuth(_ response:[UInt8])->Bool {
        response.count>=9 && matches(response,[6,2,5,1]) && response[4]<=15
    }
    static func readMapping(_ slot:Int)->[UInt8] { [1,6,0x50,1,UInt8(slot)] }
    static func writeMapping(_ slot:Int,_ entries:[AU05Key])throws->[UInt8] {
        guard (0..<6).contains(slot),entries.count<=4 else { throw AU05Failure.message("按键配置不受设备支持。") }
        return [1,6,0x50,4,UInt8(slot),1,UInt8(entries.count)] + entries.flatMap { [$0.page,$0.value] }
    }
    static func mapping(_ packet:[UInt8],slot:Int)throws->[AU05Key] {
        guard matches(packet,readMapping(slot)),packet.count>=7,(packet[5] == 1 || (packet[5] == 0 && packet[6] == 0)),packet[6]<=4,packet.count>=7+Int(packet[6])*2 else { throw AU05Failure.message("设备返回了无效的按键配置。") }
        return (0..<Int(packet[6])).map { AU05Key(page:packet[7+$0*2],value:packet[8+$0*2]) }
    }
    enum Light:String,CaseIterable { case automatic, off, solid, breathing }
    static func light(_ mode:Light)->[UInt8] {
        if mode == .solid { return [1,0x0B,0x88,4,3,0,1,7] }
        if mode != .breathing { return [1,0x0B,0x88,4,1,0,mode == .automatic ? 2 : 0] }
        // Enter working mode as well as configuring it; solid mode otherwise masks breathing.
        var bytes:[UInt8]=[1,0x0B,0x88,4,0x7F,0,2,7]
        for _ in 0..<4 { bytes += [2,10,2,7,2] }
        return bytes
    }
    static func restoreLight(_ packet:[UInt8])throws->[UInt8] {
        guard matches(packet,[1,0x0B,0x88,1]),packet.count>=28,packet[6]<=2 else { throw AU05Failure.message("无法读取设备原灯光配置。") }
        return [1,0x0B,0x88,4,0x7F]+Array(packet[5..<28])
    }
}

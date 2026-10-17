import Foundation

enum VoiceASR {
    static var defaults=UserDefaults.standard
    static let model="stepaudio-2.5-asr"
    static var route:StepASR.Route { StepASR.Route(rawValue:defaults.string(forKey:"stepVoiceRoute") ?? "plan") ?? .plan }
    static func readKey(interactive:Bool=false) throws -> String { try StepVoiceKey.read(interactive:interactive) }
}

enum VoiceFailure:LocalizedError {
    case message(String), emptyTranscript
    var errorDescription:String? {
        switch self { case .message(let text): return text; case .emptyTranscript: return "识别服务没有返回文字，请重试。" }
    }
}

// Keep final, corrected text separate from speculative deltas. Never insert an
// incomplete stream if the connection closes before transcript.text.done.
struct StepTranscript {
    var preview="", final:String?, eventLines:[String]=[]
    mutating func line(_ line:String) throws {
        if line.isEmpty { try dispatch(); return }
        if line.hasPrefix("data:") {
            eventLines.append(String(line.dropFirst(5)).trimmingCharacters(in:.whitespaces))
            // AsyncBytes.lines can omit empty separators. StepFun events are
            // complete JSON values, so dispatch as soon as the value is whole.
            let raw=eventLines.joined(separator:"\n")
            if raw == "[DONE]" || (try? JSONSerialization.jsonObject(with:Data(raw.utf8))) != nil { try dispatch() }
        }
    }
    mutating func dispatch() throws {
        guard !eventLines.isEmpty else { return }
        let raw=eventLines.joined(separator:"\n"); eventLines=[]
        if raw == "[DONE]" { return }
        guard let event=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any] else { throw VoiceFailure.message("语音服务返回了无法解析的结果。") }
        switch event["type"] as? String {
        case "transcript.text.delta": preview += event["delta"] as? String ?? ""
        case "transcript.text.done": final=event["text"] as? String
        case "error": throw VoiceFailure.message("StepFun 识别失败，请检查模型、账户余额与服务状态。")
        default: break
        }
    }
    mutating func finish() throws -> String {
        try dispatch()
        guard let final else { throw VoiceFailure.message("识别连接提前结束，没有收到完整结果。请重试。") }
        let text=final.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceFailure.emptyTranscript }
        guard text.utf16.count<=16000 else { throw VoiceFailure.message("识别文字过长，请缩短录音。") }
        return text
    }
}

// Read actual WAV chunks rather than assuming a 44-byte header. AVAudioRecorder can add metadata
// chunks. PCM retries contain exactly the recorded samples; no resampling, trimming or amplification.
struct VoiceWave {
    struct Stats:Encodable { let seconds:Double, rms_db:Double, peak_db:Double }
    let pcm:Data, stats:Stats
    var hasSignal:Bool { stats.seconds>=0.25 && stats.peak_db > -60 }
    init?(_ audio:Data) {
        let bytes=[UInt8](audio)
        guard bytes.count>=44,String(bytes:bytes[0..<4],encoding:.ascii) == "RIFF",String(bytes:bytes[8..<12],encoding:.ascii) == "WAVE" else { return nil }
        func u16(_ i:Int)->Int { Int(bytes[i]) | Int(bytes[i+1])<<8 }
        func u32(_ i:Int)->Int { u16(i) | u16(i+2)<<16 }
        let end=u32(4)+8
        guard end<=bytes.count,end>=44 else { return nil }
        var offset=12, formatOK=false, samples:Data?
        while offset<=end-8 {
            let size=u32(offset+4), start=offset+8
            guard size<=end-start else { return nil }
            let chunk=String(bytes:bytes[offset..<offset+4],encoding:.ascii)
            if chunk == "fmt " {
                guard size>=16,u16(start+2)==1,u32(start+4)==16000,u16(start+12)==2,u16(start+14)==16 else { return nil }
                let codec=u16(start)
                if codec == 0xfffe {
                    guard size>=40,u16(start+18)==16,Array(bytes[start+24..<start+40]) == [1,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113] else { return nil }
                } else if codec != 1 { return nil }
                formatOK=true
            } else if chunk == "data",samples == nil { samples=Data(bytes[start..<start+size]) }
            offset=start+size+(size%2)
        }
        guard formatOK,let samples,!samples.isEmpty,samples.count%2==0 else { return nil }
        let values=[UInt8](samples); var squares=0.0, peak=0.0
        for i in stride(from:0,to:values.count,by:2) {
            let bits=UInt16(values[i]) | UInt16(values[i+1])<<8, value=Double(Int16(bitPattern:bits))/32768
            squares += value*value; peak=max(peak,abs(value))
        }
        func db(_ value:Double)->Double { value>0 ? max(-160,20*log10(value)) : -160 }
        pcm=samples; stats=Stats(seconds:Double(samples.count)/32000,rms_db:db(sqrt(squares/Double(samples.count/2))),peak_db:db(peak))
    }
}

// Failure diagnostics contain only timing, byte count and audio levels; no recording is retained.
struct VoiceRecognitionFailure:Encodable {
    let schema="echo.voice.failure/1"
    let at=MemoryLog.timestamp(Date())
    let app:String?, model:String, error:String, audio_bytes:Int, audio:VoiceWave.Stats?
    let start_ms:Int?, ready_ms:Int?, sound_ms:Int?
}

struct VoicePosition:Equatable {
    let selection:NSRange
    let prefix:String
    let selected:String
    // Some clients accept IME text but expose no selection or surrounding text. They can
    // dictate too. A stable IMK session can send once, but unverifiable text stays available afterwards.
    var requiresConfirmation=false
    static let currentSelection=VoicePosition(selection:NSRange(location:NSNotFound,length:0),prefix:"",selected:"",requiresConfirmation:true)
    // The captured range guards the target; insertion itself uses the client's current selection,
    // just like ordinary typing. Web-backed clients may silently ignore an absolute replacement range.
    var replacementRange:NSRange { Self.currentSelection.selection }
    static func capture(selection:NSRange,substring:(NSRange)->String?)->VoicePosition? {
        guard selection.location >= 0,selection.length >= 0,selection.location != NSNotFound,selection.length != NSNotFound else { return .currentSelection }
        guard selection.length<=16000 else { return nil }
        let range=NSRange(location:max(0,selection.location-256),length:min(256,selection.location))
        let prefix=range.length == 0 ? "" : substring(range)
        guard let prefix,prefix.utf16.count == range.length else { return .currentSelection }
        let selected=selection.length>0 ? substring(selection) : ""
        guard let selected,selected.utf16.count == selection.length else { return .currentSelection }
        return VoicePosition(selection:selection,prefix:prefix,selected:selected)
    }
}

enum VoiceInsertionResult { case confirmed, unconfirmed, failed }

// IMK's insertText has no acknowledgement. Read the resulting text after giving the client time to
// update; a returned call, a moved caret, or a partial transcript is not proof that the words arrived.
// Send once: retrying an unacknowledged write automatically can duplicate a delayed insertion.
enum VoiceInsertion {
    @MainActor static func perform(_ text:String,position:VoicePosition,current:()->VoicePosition?,isCurrent:()->Bool,
                                   insert:(NSRange)->Void,substring:(NSRange)->String?) async -> VoiceInsertionResult {
        guard !Task.isCancelled,!text.isEmpty,isCurrent(),current() == position else { return .failed }
        let length=text.utf16.count
        guard position.requiresConfirmation || (position.selection.location >= position.prefix.utf16.count && position.selection.location < NSNotFound && position.selection.location <= Int.max-length) else { return .failed }
        let range=NSRange(location:position.selection.location,length:length)
        let before=position.requiresConfirmation ? nil : substring(range)
        insert(position.replacementRange)
        guard !position.requiresConfirmation else { return .unconfirmed }
        let prefixRange=NSRange(location:position.selection.location-position.prefix.utf16.count,length:position.prefix.utf16.count)
        for delay:UInt64 in [0,60_000_000,120_000_000,240_000_000,380_000_000] {
            if delay>0 { do { try await Task.sleep(nanoseconds:delay) } catch { return .unconfirmed } }
            guard !Task.isCancelled,isCurrent() else { return .unconfirmed }
            guard substring(range) == text,
                  prefixRange.length == 0 || substring(prefixRange) == position.prefix else { continue }
            // Identical text may already have followed the old caret. It must also reach the new caret,
            // unless replacing an identical selection (an intentional, harmless no-op).
            let now=current()
            if before != text || position.selected == text ||
                (now?.requiresConfirmation == false && now?.selection == NSRange(location:range.location+length,length:0) && now?.selection != position.selection) {
                return .confirmed
            }
        }
        return .unconfirmed
    }
}

// Lightweight microphone-level pause detection. This is an energy gate, not a
// semantic speech classifier; very noisy/quiet microphones may need manual stop.
struct VoicePauseDetector {
    enum Action { case keepRecording, finish, noSpeech }
    var started:TimeInterval, lastSample:TimeInterval, lastVoice:TimeInterval?, voiced:TimeInterval=0
    var heardSpeech=false
    let pause:TimeInterval=1.5, initialWait:TimeInterval=8, threshold:Float = -48
    init(started:TimeInterval) { self.started=started; lastSample=started }
    mutating func sample(_ power:Float,at now:TimeInterval,automatic:Bool)->Action {
        let elapsed=min(0.3,max(0,now-lastSample)); lastSample=now
        if power.isFinite && power>threshold {
            voiced += elapsed; lastVoice=now
            if voiced>=0.25 { heardSpeech=true }
        } else if !heardSpeech { voiced=0 }
        if heardSpeech,automatic,let lastVoice,now-lastVoice>=pause { return .finish }
        if !heardSpeech,now-started>=initialWait { return .noSpeech }
        return .keepRecording
    }
}

// The user's common words (names, products, terms), from Echo 设置 › 语音: sent to recognition as hotwords and to
// cleanup as the only spellings it may correct towards. One per line or separated by commas; at most 100.
enum VoiceTerms {
    static var defaults=UserDefaults.standard  // tests swap in scratch settings
    static func parse(_ text:String)->[String] {
        text.components(separatedBy:CharacterSet(charactersIn:"\n,，、;；")).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 30 }.reduce(into:[String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(100).map { $0 }
    }
    static var all:[String] { parse(defaults.string(forKey:"voiceHotwords") ?? "") }
}

enum StepASR {
    enum Route:String {
        case plan, platform
        var endpoint:URL { URL(string:"https://api.stepfun.com/"+(self == .plan ? "step_plan/" : "")+"v1/audio/asr/sse")! }
    }
    static var endpoint:URL { VoiceASR.route.endpoint }
    // StepFun documents hotwords but not their limits: a request they make it refuse (400/413/422) is sent again
    // without them, and they stay off until the input method restarts.
    static var hotwordsRefused=false
    static func request(audio:Data,key:String,model:String,language:String,hotwords:[String]=[],rawPCM:Bool=false,route:Route?=nil) throws -> URLRequest {
        guard !key.isEmpty,!key.contains("\n"),!key.contains("\r"),model == VoiceASR.model,["auto","zh","en"].contains(language) else { throw VoiceFailure.message("请先保存有效的 StepFun 语音配置。") }
        guard audio.count>44,audio.count<4_000_000,String(data:audio.prefix(4),encoding:.ascii) == "RIFF",String(data:audio[8..<12],encoding:.ascii) == "WAVE" else { throw VoiceFailure.message("录音格式不正确，请重新录音。") }
        var request=URLRequest(url:(route ?? VoiceASR.route).endpoint); request.httpMethod="POST"; request.timeoutInterval=60
        request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("text/event-stream",forHTTPHeaderField:"Accept")
        var transcription:[String:Any] = ["model":model,"enable_itn":true]
        if language != "auto" { transcription["language"]=language }
        if !hotwords.isEmpty { transcription["hotwords"]=hotwords }
        let payload:Data
        if rawPCM { guard let wave=VoiceWave(audio) else { throw VoiceFailure.message("录音格式不支持重新识别，请重新录音。") }; payload=wave.pcm }
        else { payload=audio }
        let format:[String:Any] = ["type":rawPCM ? "pcm" : "wav","rate":16000,"bits":16,"channel":1,"codec":"pcm_s16le"]
        request.httpBody=try JSONSerialization.data(withJSONObject:["audio":["data":payload.base64EncodedString(),"input":["transcription":transcription,"format":format]]])
        return request
    }
    static func transcribe(audio:Data,key:String,model:String,language:String,hotwords:[String]=[],session:URLSession,progress:@escaping(String)->Void,rawPCM:Bool=false,onPCMRetry:@escaping()->Void={},route:Route?=nil) async throws -> String {
        let route=route ?? VoiceASR.route
        let request=try request(audio:audio,key:key,model:model,language:language,hotwords:hotwords,rawPCM:rawPCM,route:route)
        let (bytes,response)=try await session.bytes(for:request)
        guard let http=response as? HTTPURLResponse else { throw VoiceFailure.message("语音服务没有返回有效响应。") }
        guard http.statusCode == 200 else {
            if !hotwords.isEmpty,[400,413,422].contains(http.statusCode) {
                hotwordsRefused=true
                return try await transcribe(audio:audio,key:key,model:model,language:language,session:session,progress:progress,rawPCM:rawPCM,onPCMRetry:onPCMRetry,route:route)
            }
            switch http.statusCode {
            case 401: throw VoiceFailure.message("api.stepfun.com 返回 HTTP 401：Key 未被此服务认可。请检查 Key 对应的服务地址，或在「APT 设置 › Agent 服务」中更换 Key。")
            case 403: throw VoiceFailure.message("api.stepfun.com 返回 HTTP 403：账户没有该模型的权限。请检查账户权限或 Key 对应的服务。")
            case 402: throw VoiceFailure.message("StepFun 账户余额不足。")
            case 429: throw VoiceFailure.message("StepFun 请求过于频繁，请稍后再试。")
            default: throw VoiceFailure.message("StepFun 请求失败（HTTP \(http.statusCode)），请检查模型与服务状态。")
            }
        }
        guard (http.value(forHTTPHeaderField:"Content-Type") ?? "").lowercased().contains("text/event-stream") else { throw VoiceFailure.message("语音服务返回格式不匹配，请检查配置。") }
        var decoder=StepTranscript()
        for try await line in bytes.lines {
            try Task.checkCancellation(); try decoder.line(line)
            if !decoder.preview.isEmpty { progress(String(decoder.preview.suffix(300))) }
        }
        try Task.checkCancellation()
        do { return try decoder.finish() }
        catch VoiceFailure.emptyTranscript {
            guard !rawPCM,VoiceWave(audio)?.hasSignal == true else { throw VoiceFailure.emptyTranscript }
            try Task.checkCancellation(); onPCMRetry()
            return try await transcribe(audio:audio,key:key,model:model,language:language,hotwords:hotwords,session:session,progress:progress,rawPCM:true,onPCMRetry:onPCMRetry,route:route)
        }
    }
}

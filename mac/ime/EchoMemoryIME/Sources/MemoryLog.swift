import Foundation

// What each memory lookup did, kept on this Mac only (docs/记忆Agent-优化方案.md §三). Runs/ holds the
// question, sources and replies; Usage/ holds numbers for every paid model call. Both are append-only
// JSON lines, one file a month. Writing never gets in the way of typing: a failure is counted, not thrown.
final class MemoryLog {
    static var shared=MemoryLog(root:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("EchoMemoryIME"))  // tests swap in a scratch folder
    let root:URL
    private let lock=NSLock()
    private(set) var failures=0
    // Live checks spend real money and are booked, under their own scene names.
    static var scenePrefix=""
    init(root:URL) { self.root=root }
    static func timestamp(_ date:Date)->String {
        let format=ISO8601DateFormatter(); format.timeZone=TimeZone(identifier:"Asia/Shanghai"); return format.string(from:date)
    }
    static func cancelled(_ error:Error)->Bool { error is CancellationError || (error as? URLError)?.code == .cancelled }
    static var appVersion:String { Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "dev" }
    var runs:URL { root.appendingPathComponent("Runs") }
    var voices:URL { root.appendingPathComponent("Voice") }
    var asrComparisons:URL { root.appendingPathComponent("ASRCompare") }

    func record(_ run:MemoryRun) { append(run,to:"Runs") }
    // How a lookup ended, written when it happens: inserted, dismissed, abandoned or copied.
    func outcome(_ runID:String,_ kind:String,choice:Int?=nil,text:String?=nil) { append(MemoryOutcome(run_id:runID,at:Self.timestamp(Date()),kind:kind,choice:choice,text:text),to:"Runs") }
    func usage(_ entry:MemoryUsage) { append(entry,to:"Usage") }
    // Dictations (VoiceRecord.swift): what was heard, cleaned up, filled in, and what it was left as.
    func voice<T:Encodable>(_ entry:T) { append(entry,to:"Voice") }
    func asrComparison<T:Encodable>(_ entry:T) { append(entry,to:"ASRCompare") }
    func settingsWindow<T:Encodable>(_ entry:T) { append(entry,to:"SettingsWindow") }
    // Books one paid request as it ends (failed ones too: a server may bill them) and returns the call for
    // the lookup's record. Numbers and a fixed code only.
    @discardableResult static func book(_ scene:String,model:String,host:String?,started:Date,response:[String:Any]?,code:String?,runID:String?=nil,audioSeconds:Double?=nil)->MemoryRun.Call {
        let ms=MemoryTrace.ms(since:started), tokens=ModelPrice.tokens(response)
        let usd=ModelPrice.usd(host:host,model:model,input:tokens.input,cacheHit:tokens.cacheHit,output:tokens.output,at:started)
        shared.usage(MemoryUsage(at:timestamp(started),scene:scenePrefix+scene,model:model,host:host,input:tokens.input,cache_hit:tokens.cacheHit,output:tokens.output,ms:ms,usd:usd,run_id:runID,error:code,audio_seconds:audioSeconds))
        return .init(scene:scene,ms:ms,input:tokens.input,cache_hit:tokens.cacheHit,output:tokens.output,usd:usd,error:code)
    }
    private func append<T:Encodable>(_ value:T,to folder:String) {
        lock.lock(); defer { lock.unlock() }
        do {
            let directory=root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            chmod(directory.path,0o700)
            let month=DateFormatter(); month.timeZone=TimeZone(identifier:"Asia/Shanghai"); month.dateFormat="yyyy-MM"
            let path=directory.appendingPathComponent(month.string(from:Date())+".jsonl").path
            let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            var line=try encoder.encode(value); line.append(0x0a)
            // O_APPEND keeps whole lines when the input method and a live check write at the same time.
            let file=open(path,O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC,0o600)
            guard file >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(file) }
            fchmod(file,0o600)
            let written=line.withUnsafeBytes { Darwin.write(file,$0.baseAddress,$0.count) }
            guard written == line.count else { throw CocoaError(.fileWriteUnknown) }
        } catch { failures += 1 }
    }
    // Read off the main thread by callers. Counts bytes, so one damaged line cannot zero a month.
    var runCount:Int { count(#""schema":"echo.memory.run/1""#,in:runs) }
    var voiceCount:Int { count(#""schema":"echo.voice/1""#,in:voices) }
    private func count(_ schema:String,in folder:URL)->Int {
        let needle=Data(schema.utf8)
        let files=(try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.reduce(0) { count,url in
            guard let data=try? Data(contentsOf:url,options:.mappedIfSafe) else { return count }
            var found=0, rest=data.startIndex..<data.endIndex
            while let hit=data.range(of:needle,in:rest) { found += 1; rest=hit.upperBound..<data.endIndex }
            return count+found
        }
    }
    var hasRuns:Bool { [runs,voices,asrComparisons].contains { !((try? FileManager.default.contentsOfDirectory(atPath:$0.path)) ?? []).isEmpty } }
    // Questions, replies and dictations; the usage ledger holds no text and stays.
    func clearRuns() throws {
        lock.lock(); defer { lock.unlock() }
        for folder in [runs,voices,asrComparisons,root.appendingPathComponent("SettingsWindow")] where FileManager.default.fileExists(atPath:folder.path) { try FileManager.default.removeItem(at:folder) }
    }
}

struct MemoryRun:Codable {
    struct Route:Codable { var model:String; var host:String?; var thinking:Bool }
    struct Plan:Codable { var by:String; var dates:String; var from:String; var to:String; var keywords:[String] }  // dates: code|model
    struct WithEcho:Codable { var events:Int; var omitted:Int; var cache:String; var ms:Int; var error:String?=nil }
    struct Local:Codable { var candidates:Int; var days:Int=0; var meetings:Int=0 }
    struct Details:Codable { var cache:String; var ms:Int }
    struct Retrieve:Codable { var withecho:WithEcho; var local:Local; var details:Details?=nil }
    struct Select:Codable { var by:String; var ids:[String]; var batches:Int=0; var vector:MemoryIndexState?=nil }
    struct Source:Codable { var id:String; var from:String; var chars:Int }
    struct Answer:Codable { var replies:[String]; var used:[String]; var needs_clarification:Bool; var clarification:String? }
    struct Call:Codable {
        var scene:String; var ms:Int; var input:Int?; var cache_hit:Int?; var output:Int?; var usd:Double?; var error:String?=nil
        enum CodingKeys:String,CodingKey { case scene,ms,input,cache_hit,output,usd,error }
        // Unknown numbers are written as null, never left out (a reader's default could turn them into 0).
        func encode(to encoder:Encoder) throws {
            var c=encoder.container(keyedBy:CodingKeys.self)
            try c.encode(scene,forKey:.scene); try c.encode(ms,forKey:.ms); try c.encode(input,forKey:.input); try c.encode(cache_hit,forKey:.cache_hit)
            try c.encode(output,forKey:.output); try c.encode(usd,forKey:.usd); try c.encodeIfPresent(error,forKey:.error)
        }
    }
    var schema="echo.memory.run/1"
    var run_id=UUID().uuidString
    var started_at=MemoryLog.timestamp(Date())
    var surface:String, trigger:String
    var app:String?
    var query="", mode="reply"
    var versions=["app":MemoryLog.appVersion,"prompts":SmartMemory.promptVersion,"rules":SmartMemory.ruleVersion]
    var route:Route?
    var cached:Bool?
    var plan:Plan?
    var retrieve:Retrieve?
    var select:Select?
    var sources:[Source]=[]
    var answer:Answer?
    var calls:[Call]=[]
    var stages_ms:[String:Int]=[:]
    var error:String?
}
// kind: inserted, dismissed, abandoned or copied when the lookup ends; after an insertion, once its paragraph is
// quiet: unchanged, edited (text: what the user made of it), removed or unknown, as for dictations.
struct MemoryOutcome:Encodable { var schema="echo.memory.outcome/1"; let run_id:String; let at:String; let kind:String; let choice:Int?; var text:String?=nil }
struct MemoryUsage:Encodable {
    var schema="echo.usage/1"
    let at:String, scene:String, model:String, host:String?
    let input:Int?, cache_hit:Int?, output:Int?, ms:Int
    let usd:Double?  // null when the model has no price below or tokens are unknown: never guessed as 0
    let run_id:String?
    var error:String?=nil  // a fixed code (network, http_500, not_json, no_content, cancelled), never text
    var audio_seconds:Double?=nil  // speech recognition, billed by audio
    enum CodingKeys:String,CodingKey { case schema,at,scene,model,host,input,cache_hit,output,ms,usd,run_id,error,audio_seconds }
    func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(schema,forKey:.schema); try c.encode(at,forKey:.at); try c.encode(scene,forKey:.scene); try c.encode(model,forKey:.model)
        try c.encode(host,forKey:.host); try c.encode(input,forKey:.input); try c.encode(cache_hit,forKey:.cache_hit); try c.encode(output,forKey:.output)
        try c.encode(ms,forKey:.ms); try c.encode(usd,forKey:.usd)
        try c.encodeIfPresent(run_id,forKey:.run_id); try c.encodeIfPresent(error,forKey:.error); try c.encodeIfPresent(audio_seconds,forKey:.audio_seconds)
    }
}

// One lookup's record while it runs; SmartMemory fills it stage by stage.
final class MemoryTrace {
    private let lock=NSLock()
    private var value:MemoryRun
    // false for work that is not a lookup (By Day): its ledger lines then point to no record.
    let recorded:Bool
    init(surface:String,trigger:String,app:String?=nil,query:String="",mode:String="reply",recorded:Bool=true) { value=MemoryRun(surface:surface,trigger:trigger,app:app,query:query,mode:mode); self.recorded=recorded }
    var run:MemoryRun { lock.lock(); defer { lock.unlock() }; return value }
    var id:String { run.run_id }
    func update(_ change:(inout MemoryRun)->Void) { lock.lock(); change(&value); lock.unlock() }
    func stage(_ name:String,since start:Date) { update { $0.stages_ms[name]=MemoryTrace.ms(since:start) } }
    func call(_ call:MemoryRun.Call) { update { $0.calls.append(call) } }
    static func ms(since start:Date)->Int { Int((Date().timeIntervalSince(start)*1000).rounded()) }
}

// USD per million tokens, off-peak, from DeepSeek's own page (api-docs.deepseek.com/quick_start/pricing),
// read 2026-10-12. Peak hours (01–04 and 06–10 UTC, Monday to Friday) cost double; Chinese public holidays
// are off-peak there but counted as peak here, so those days are slightly over-stated. Models not on the
// page are logged with usd null.
enum ModelPrice {
    static let table:[(host:String,models:[String],input:Double,cacheHit:Double,output:Double)]=[
        ("api.deepseek.com",["deepseek-flash","deepseek-v4-flash","deepseek-v4-flash-vision-exp"],0.15,0.003,0.6),
        ("api.deepseek.com",["deepseek-v4-pro"],0.66,0.022,1.98),
    ]
    static func peak(_ date:Date)->Bool {
        var utc=Calendar(identifier:.gregorian); utc.timeZone=TimeZone(identifier:"UTC")!
        let weekday=utc.component(.weekday,from:date), hour=utc.component(.hour,from:date)
        return (2...6).contains(weekday) && ((1..<4).contains(hour) || (6..<10).contains(hour))
    }
    static func usd(host:String?,model:String,input:Int?,cacheHit:Int?,output:Int?,at date:Date=Date())->Double? {
        guard let input,let output,let rate=table.first(where:{ $0.host == host && $0.models.contains(model) }) else { return nil }
        let hit=min(max(cacheHit ?? 0,0),input)
        return (Double(input-hit)*rate.input+Double(hit)*rate.cacheHit+Double(output)*rate.output)/1_000_000*(peak(date) ? 2 : 1)
    }
    // Token counts as Chat Completions services report them; DeepSeek and OpenAI name the cache hit differently.
    static func tokens(_ response:[String:Any]?)->(input:Int?,cacheHit:Int?,output:Int?) {
        let usage=response?["usage"] as? [String:Any]
        let hit=(usage?["prompt_cache_hit_tokens"] as? Int) ?? ((usage?["prompt_tokens_details"] as? [String:Any])?["cached_tokens"] as? Int)
        return (usage?["prompt_tokens"] as? Int,hit,usage?["completion_tokens"] as? Int)
    }
}

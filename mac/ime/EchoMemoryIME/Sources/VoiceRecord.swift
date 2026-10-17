import Foundation

// One dictation, kept on this Mac only (Voice/, cleared with the lookup records): what recognition heard,
// what cleanup made of it, what was filled in, and later what the user left it as. With all four, a wrong
// word can be traced to recognition (fix: common words as hotwords) or to cleanup (fix: the prompt).
struct VoiceRun:Encodable {
    struct Heard:Encodable { var model:String; var ms:Int; var text:String; var hotwords:Int; var endpoint:String?=nil }
    struct Cleanup:Encodable {
        var model:String, prompt:String, ms:Int, text:String?, error:String?, used:Bool
        enum CodingKeys:String,CodingKey { case model,prompt,ms,text,error,used }
        // Unknowns are written as null, never left out.
        func encode(to encoder:Encoder) throws {
            var c=encoder.container(keyedBy:CodingKeys.self)
            try c.encode(model,forKey:.model); try c.encode(prompt,forKey:.prompt); try c.encode(ms,forKey:.ms)
            try c.encode(text,forKey:.text); try c.encode(error,forKey:.error); try c.encode(used,forKey:.used)
        }
    }
    var schema="echo.voice/1"
    var run_id=UUID().uuidString
    var at=MemoryLog.timestamp(Date())
    var app:String?
    var asr:Heard
    var cleanup:Cleanup?
    // start_ms: key press to record() returning; ready_ms: key press to recorded time advancing;
    // sound_ms: record() returning to the first non-floor meter value (sampled every 0.15 s).
    // Sound can follow readiness after the user waits before speaking. Null when not measured.
    var start_ms:Int?=nil, sound_ms:Int?=nil, ready_ms:Int?=nil
    var result=""     // the text filled in, or kept on the card
    var outcome=""    // inserted | kept
    // Why it was kept rather than filled in by itself, the first check that failed: left_field (typing went to
    // another field or app), field_unavailable (no caret Echo can read), caret_moved (the caret is elsewhere, also
    // after typing more in the same field), text_changed (same caret, different text before it), selection_changed,
    // insert_failed (the insertion preflight failed), or insert_unconfirmed (sent once, but the resulting
    // text could not be read back). An unconfirmed write is kept and must not be recorded as inserted.
    var kept_because:String?=nil
    enum CodingKeys:String,CodingKey { case schema,run_id,at,app,asr,cleanup,start_ms,sound_ms,ready_ms,result,outcome,kept_because }
    func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(schema,forKey:.schema); try c.encode(run_id,forKey:.run_id); try c.encode(at,forKey:.at); try c.encode(app,forKey:.app)
        try c.encode(asr,forKey:.asr); try c.encode(cleanup,forKey:.cleanup); try c.encode(start_ms,forKey:.start_ms); try c.encode(sound_ms,forKey:.sound_ms)
        try c.encode(ready_ms,forKey:.ready_ms)
        try c.encode(result,forKey:.result); try c.encode(outcome,forKey:.outcome)
        try c.encodeIfPresent(kept_because,forKey:.kept_because)
    }
}
// What happened to a dictation afterwards: filled (kept text confirmed in the field later), fill_unconfirmed /
// fill_failed (a manual attempt still needs review), copied, discarded; and, once its
// paragraph has been quiet for a while (or emptied, as a chat field is when sent): edited (text: what it became),
// unchanged, removed (the paragraph no longer has it), or unknown (input memory never saw the paragraph, e.g. off).
struct VoiceOutcome:Encodable { var schema="echo.voice.outcome/1"; let run_id:String; var at=MemoryLog.timestamp(Date()); let kind:String; var text:String?=nil }

// After a dictation is filled in, the paragraph holding it is watched through input memory: the stretch that best
// matches what was filled in is what the user made of it. Only the paragraph that contains where it was filled in
// counts. Input memory cannot tell one chat from another in the same app (both start at 0), so for a memory reply a
// paragraph without it is no verdict; it is removed only when its field is cleared with Delete or ⌘X. Written once.
final class VoiceEdits {
    static var shared=VoiceEdits()  // checks swap in a fresh one
    static var window:TimeInterval=180
    struct Watch {
        let run:String, app:String, text:String, location:Int
        var memory=false  // a memory reply: its outcome goes to Runs/, a dictation's to Voice/
        var final:String, until:Date
        var found:Bool?=nil  // nil: its paragraph never seen; false: seen without it
        var seen:String?=nil  // the paragraph last compared, so an unchanged one is not compared again
    }
    // The last key Echo passed on deleted text (Delete, Forward Delete, ⌘X): a field emptied by it was cleared, not sent.
    var deleting=false
    private(set) var watches:[Watch]=[]
    func watch(run:String,app:String?,text:String,location:Int,memory:Bool=false,now:Date=Date()) {
        guard let app,!text.isEmpty else { return }
        watches.append(Watch(run:run,app:app,text:text,location:location,memory:memory,final:text,until:now.addingTimeInterval(Self.window)))
        later()
    }
    // A paragraph input memory saved; start is its offset in the field (UTF-16).
    func observe(app:String,text:String,start:Int,now:Date=Date()) {
        for index in watches.indices where watches[index].app == app && watches[index].until>now {
            let watch=watches[index]
            guard start <= watch.location,watch.location <= start+text.utf16.count,watch.seen != text else { continue }
            watches[index].seen=text
            guard watch.text.count*text.count <= Self.largest else { continue }  // too long to compare: no verdict
            if let span=Self.match(watch.text,in:text) {
                guard span != watch.final || watch.found != true else { continue }
                watches[index].final=span; watches[index].found=true
            } else if !watch.memory,watch.found != false { watches[index].found=false }
            else { continue }
            watches[index].until=now.addingTimeInterval(Self.window); later()
        }
    }
    // The field was emptied from its start: sent (what was last seen is final), or cleared with a delete key.
    func emptied(app:String,now:Date=Date()) {
        for index in watches.indices where watches[index].app == app {
            if deleting,watches[index].found == true { watches[index].found=false }
            watches[index].until=now
        }
        expire(now:now)
    }
    // Clearing the records also forgets what is being watched, so nothing is written afterwards.
    func forget() { watches=[] }
    private func later() { DispatchQueue.main.asyncAfter(deadline:.now()+Self.window+1) { [weak self] in self?.expire() } }
    func expire(now:Date=Date()) {
        let done=watches.filter { $0.until <= now }; watches.removeAll { $0.until <= now }
        for watch in done {
            let kind=watch.found == nil ? "unknown" : watch.found == false ? "removed" : watch.final == watch.text ? "unchanged" : "edited"
            let text=kind == "edited" ? watch.final : nil
            if watch.memory { MemoryLog.shared.outcome(watch.run,kind,text:text) } else { MemoryLog.shared.voice(VoiceOutcome(run_id:watch.run,kind:kind,text:text)) }
        }
    }
    // The stretch of `text` closest to `needle` by edit distance (all of the needle, any part of the text; on a tie
    // the longest), or nil when it differs in more than 40% of the needle's length (short needles: exactly).
    static let largest=4_000_000
    static func match(_ needle:String,in text:String)->String? {
        let a=Array(needle), b=Array(text)
        guard !a.isEmpty,!b.isEmpty,a.count*b.count <= largest else { return nil }
        var cost=[Int](repeating:0,count:b.count+1), start=Array(0...b.count)
        var next=[Int](repeating:0,count:b.count+1), from=[Int](repeating:0,count:b.count+1)
        for i in 1...a.count {
            next[0]=i; from[0]=0
            for j in 1...b.count {
                // Equal cost: the stretch that starts earlier, so words the user added at the front are kept.
                var best=cost[j-1]+(a[i-1] == b[j-1] ? 0 : 1), origin=start[j-1]
                let delete=cost[j]+1, insert=next[j-1]+1
                if delete<best || (delete == best && start[j]<origin) { best=delete; origin=start[j] }
                if insert<best || (insert == best && from[j-1]<origin) { best=insert; origin=from[j-1] }
                next[j]=best; from[j]=origin
            }
            swap(&cost,&next); swap(&start,&from)
        }
        var end=1
        for j in 2...max(b.count,2) where j <= b.count && (cost[j]<cost[end] || (cost[j] == cost[end] && j-start[j]>end-start[end])) { end=j }
        guard cost[end] <= Int(Double(a.count)*0.4) else { return nil }
        return String(b[start[end]..<end])
    }
}

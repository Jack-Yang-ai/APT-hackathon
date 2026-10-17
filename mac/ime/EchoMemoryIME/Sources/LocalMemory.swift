import Foundation

extension Notification.Name { static let echoMemoryChanged=Notification.Name("EchoMemorySourceChanged") }

// Dates a draft mentions, worked out from when it was written: "明天" in a note from 10-09 is 10-10.
// Mechanical only; a bare "周三", "15号" or a month-day far from the note could mean more than one day,
// so it is left out. Words that only look like dates (目前天气, 聪明天才, 今日头条, 订单号里的数字) are not dates.
enum EchoDates {
    struct Mention:Equatable { let surface:String; let date:String }
    static let calendar:Calendar = { var c=Calendar(identifier:.gregorian); c.timeZone=TimeZone(identifier:"Asia/Shanghai")!; return c }()
    private static let pattern=try! NSRegularExpression(pattern:#"(?<!\d)((?:19|20)\d{2})[-/年.](\d{1,2})[-/月.](\d{1,2})(?!\d)[日号]?|(?<!\d)(\d{1,2})月(\d{1,2})[日号]|(上上|下下|上|下|这|本)个?(?:周|星期|礼拜)([一二三四五六日天])|大大后天|大后天|(?<!先天)后天|(?<![聪光])明天|明日|今天|今日(?!头条)|昨天|昨日|大大前天|大前天|(?<![目以当之提])前天|(?i:\b(?:tomorrow|today|yesterday)\b)"#)
    private static let offsets:[String:Int]=["大大后天":4,"大后天":3,"后天":2,"明天":1,"明日":1,"今天":0,"今日":0,"昨天":-1,"昨日":-1,"前天":-2,"大前天":-3,"大大前天":-4,"tomorrow":1,"today":0,"yesterday":-1]
    static func mentions(in text:String,at written:Date)->[Mention] {
        let day=calendar.startOfDay(for:written), source=text as NSString
        var found:[Mention]=[]
        for match in pattern.matches(in:text,range:NSRange(location:0,length:source.length)) {
            func group(_ i:Int)->String? { match.range(at:i).location == NSNotFound ? nil : source.substring(with:match.range(at:i)) }
            let surface=source.substring(with:match.range)
            var date:Date?
            if let y=group(1).flatMap(Int.init),let m=group(2).flatMap(Int.init),let d=group(3).flatMap(Int.init) { date=valid(y,m,d) }
            else if let m=group(4).flatMap(Int.init),let d=group(5).flatMap(Int.init) {
                // No year: only a day within four months of the note is unambiguous.
                let year=calendar.component(.year,from:day)
                date=[year-1,year,year+1].compactMap { valid($0,m,d) }.filter { abs($0.timeIntervalSince(day))<=120*86400 }.min { abs($0.timeIntervalSince(day))<abs($1.timeIntervalSince(day)) }
            } else if let week=group(6),let name=group(7),let index=Array("一二三四五六日").firstIndex(of:name == "天" ? "日" : Character(name)) {
                let weeks=["下下":2,"下":1,"这":0,"本":0,"上":-1,"上上":-2][week]!
                let monday=calendar.date(byAdding:.day,value:-((calendar.component(.weekday,from:day)+5)%7),to:day)!
                date=calendar.date(byAdding:.day,value:weeks*7+index,to:monday)
            } else if let offset=offsets[surface.lowercased()] { date=calendar.date(byAdding:.day,value:offset,to:day) }
            if let date { let mention=Mention(surface:surface,date:LocalMemoryStore.day(date)); if !found.contains(mention) { found.append(mention) } }
        }
        return found
    }
    private static func valid(_ y:Int,_ m:Int,_ d:Int)->Date? {
        guard let date=calendar.date(from:DateComponents(year:y,month:m,day:d)) else { return nil }
        let parts=calendar.dateComponents([.year,.month,.day],from:date)
        return parts.year == y && parts.month == m && parts.day == d ? date : nil
    }
}

struct LocalInputRecord:Codable {
    enum Origin:String { case typed, voice, pasted, mixed }
    // Shorter pastes are not tracked: a few characters ("3", "同意") turn up in the user's own typing too.
    static let shortestPaste=6
    let id:String
    let created:Date
    var updated:Date
    let app:String
    var text:String
    var deleted:Bool=false
    // Missing in legacy files: version 1. Persisted with the source, never a process counter.
    var version:Int?=nil
    var sourceRevision:Int { version ?? 1 }
    var partial:Bool?=nil
    // Text that arrived by ⌘V or by voice, as inserted; matched against the current text.
    var pasted:[String]?=nil
    var voiced:[String]?=nil
    // Where pasted text sits now, merged; text pasted and then edited away no longer counts.
    var pastedRanges:[NSRange] {
        let source=text as NSString
        var ranges:[NSRange]=[]
        for piece in pasted ?? [] where piece.count>=Self.shortestPaste {
            var from=0
            while from<source.length {
                let found=source.range(of:piece,range:NSRange(location:from,length:source.length-from))
                if found.location == NSNotFound { break }
                ranges.append(found); from=NSMaxRange(found)
            }
        }
        return ranges.sorted { $0.location<$1.location }.reduce(into:[]) { merged,range in
            if let last=merged.last,range.location <= NSMaxRange(last) { merged[merged.count-1]=NSUnionRange(last,range) } else { merged.append(range) }
        }
    }
    // The user's own words: pasted stretches blanked out.
    var ownText:String {
        let own=NSMutableString(string:text)
        for range in pastedRanges.reversed() { own.replaceCharacters(in:range,with:"\u{0}") }
        return own as String
    }
    var origin:Origin {
        if pastedRanges.isEmpty { return voiced?.contains(where:{ !$0.isEmpty && text.contains($0) }) == true ? .voice : .typed }
        return ownText.replacingOccurrences(of:"\u{0}",with:"").trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty ? .pasted : .mixed
    }
    // The text with pasted stretches marked, as the model reads it. Marker look-alikes inside the text are
    // defused first, so pasted text cannot close its own marker and pass as the user's words.
    var marked:String {
        func defuse(_ s:String)->String { s.replacingOccurrences(of:"【粘贴】",with:"〔粘贴〕").replacingOccurrences(of:"【/粘贴】",with:"〔/粘贴〕") }
        let source=text as NSString
        var result="", cursor=0
        for range in pastedRanges {
            result += defuse(source.substring(with:NSRange(location:cursor,length:range.location-cursor)))+"【粘贴】"+defuse(source.substring(with:range))+"【/粘贴】"; cursor=NSMaxRange(range)
        }
        return result+defuse(source.substring(from:cursor))
    }
    // Days the user's own words mention. Relative days inside pasted text belong to whoever wrote them, at a
    // time Echo does not know, so they are not worked out.
    var mentions:[EchoDates.Mention] { EchoDates.mentions(in:ownText,at:created) }
    var metadata:MemoryMetadata {
        MemoryMetadata(event_id:id,date:LocalMemoryStore.day(created),title:(origin == .pasted ? "粘贴内容 · " : "输入草稿 · ")+String(text.prefix(42)),summary:String(text.prefix(300)))
    }
    var source:MemorySource {
        let caution="不能据此断言已发送、已发生或已确认；保留原话中的否定和不确定性。"
        let lead:String
        switch origin {
        case .typed: lead="来源：用户在 \(app) 输入的草稿，自动本地记录。"+caution
        case .voice: lead="来源：用户在 \(app) 用语音输入的草稿，自动本地记录。"+caution
        case .mixed: lead="来源：用户在 \(app) 输入的草稿，自动本地记录；【粘贴】与【/粘贴】之间是粘贴进来的外部文字，不是用户本人的话。"+caution
        case .pasted: lead="来源：用户在 \(app) 粘贴进来的外部文字，自动本地记录。这不是用户本人的话，不能当作用户的观点、承诺或经历。"
        }
        let days=mentions, dates=days.isEmpty ? "" : "\n提及日期（按记录时间换算）："+days.map { "\($0.surface)=\($0.date)" }.joined(separator:"；")
        return MemorySource(event_id:id,date:LocalMemoryStore.day(created),title:metadata.title,body:lead+"\n来源版本：\(sourceRevision)\n范围：\(partial == true ? "仅光标前的输入片段，可能缺少前后文，不是完整段落。" : "当前输入段落。")\n记录时间：\(ISO8601DateFormatter().string(from:created))"+dates+"\n原文：\n"+(origin == .pasted ? marked.replacingOccurrences(of:"【粘贴】",with:"").replacingOccurrences(of:"【/粘贴】",with:"") : marked))
    }
}
final class LocalMemoryStore {
    static let shared=LocalMemoryStore(root:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("EchoMemoryIME/InputMemory"))
    // A draft picked up again within this long, in the same app on the same day, may extend an earlier one.
    static let continuation:TimeInterval=2*3600
    let root:URL
    private let lock=NSLock()
    private var records:[String:LocalInputRecord]=[:]
    private var counter=0
    // The folder itself could not be read: what is loaded may be missing anything.
    private(set) var failure:String?
    // Files that would not decode. Left on disk as they are, never written over; the rest load normally.
    private(set) var damaged:[String]=[]
    var error:String? { failure ?? (damaged.isEmpty ? nil : "有 \(damaged.count) 条输入记录读不出来，原文件已原样保留在 \(root.path)；其余记录照常可用。") }
    var revision:Int { lock.lock(); defer { lock.unlock() }; return counter }
    init(root:URL) {
        self.root=root
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            for url in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where url.pathExtension == "json" {
                do { let record=try JSONDecoder().decode(LocalInputRecord.self,from:Data(contentsOf:url)); records[record.id]=record }
                catch { damaged.append(url.lastPathComponent) }
            }
        } catch { failure="本地记忆读取失败：\(error.localizedDescription)" }
    }
    private static let dayFormat:DateFormatter = { let f=DateFormatter(); f.timeZone=TimeZone(identifier:"Asia/Shanghai"); f.dateFormat="yyyy-MM-dd"; return f }()
    static func day(_ date:Date)->String { dayFormat.string(from:date) }
    func all(deleted:Bool=false)->[LocalInputRecord] {
        lock.lock(); defer { lock.unlock() }; return records.values.filter{$0.deleted == deleted}.sorted{$0.updated > $1.updated}
    }
    // Lookups read each draft once: an earlier draft that a later one (same app, same day, picked up within two
    // hours) continues at the end is folded into it. Nothing is hidden anywhere else or deleted, and text that
    // was changed rather than continued, or moved to another day, stays its own record.
    static func current(_ records:[LocalInputRecord])->[LocalInputRecord] {
        records.filter { record in
            !records.contains { other in
                other.id != record.id && other.app == record.app && day(other.created) == day(record.created)
                    && other.text.count>record.text.count && other.text.hasPrefix(record.text)
                    && other.created >= record.created && other.created.timeIntervalSince(record.updated) <= continuation
            }
        }
    }
    @discardableResult func upsert(_ text:String,app:String,id:String?,now:Date=Date(),partial:Bool=false,pasted:[String]=[],voiced:[String]=[]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.utf16.count<=8192 else { throw MemoryFailure.message("输入片段为空或过长，未记录。") }
        let recordID=id ?? "local_input_"+UUID().uuidString
        guard records[recordID] != nil || !damaged.contains(recordID+".json") else { throw MemoryFailure.message("这条输入记录的原文件读不出来，已原样保留，未覆盖。") }
        var record=records[recordID] ?? LocalInputRecord(id:recordID,created:now,updated:now,app:app,text:value)
        func kept(_ old:[String]?,_ new:[String])->[String]? {
            let all=((old ?? [])+new).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.reduce(into:[String]()) { if $1.count>=LocalInputRecord.shortestPaste,!$0.contains($1),value.contains($1) { $0.append($1) } }
            return all.isEmpty ? nil : all
        }
        let pastedNow=kept(record.pasted,pasted), voicedNow=kept(record.voiced,voiced)
        if record.text == value,record.pasted == pastedNow,record.voiced == voicedNow,record.partial == partial,!record.deleted,records[recordID] != nil { return recordID }
        guard record.sourceRevision<Int.max else { throw MemoryFailure.message("记忆版本已超出范围，未保存。") }
        record.version=records[recordID] == nil ? 1 : record.sourceRevision+1
        record.text=value; record.updated=max(now,record.updated); record.deleted=false; record.partial=partial; record.pasted=pastedNow; record.voiced=voicedNow
        try write(record); records[recordID]=record; counter += 1
        DispatchQueue.main.async { NotificationCenter.default.post(name:.echoMemoryChanged,object:nil) }
        return recordID
    }
    func setDeleted(_ id:String,_ deleted:Bool,now:Date=Date()) throws {
        lock.lock(); defer { lock.unlock() }; guard var record=records[id] else { return }
        guard record.deleted != deleted else { return }
        guard record.sourceRevision<Int.max else { throw MemoryFailure.message("记忆版本已超出范围，未保存。") }
        record.version=record.sourceRevision+1; record.deleted=deleted; record.updated=max(now,record.updated)
        try write(record); records[id]=record; counter += 1
        DispatchQueue.main.async { NotificationCenter.default.post(name:.echoMemoryChanged,object:nil) }
    }
    private func write(_ record:LocalInputRecord) throws {
        let url=root.appendingPathComponent(record.id+".json")
        try JSONEncoder().encode(record).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func sources(_ ids:[String])->[MemorySource] {
        lock.lock(); defer { lock.unlock() }; return ids.compactMap{records[$0]}.filter{!$0.deleted}.map(\.source)
    }
    // Mentioned days, worked out once per version of a draft.
    private var mentionMemo:[String:(Date,[EchoDates.Mention])]=[:]
    func mentions(_ record:LocalInputRecord)->[EchoDates.Mention] {
        lock.lock(); defer { lock.unlock() }
        if let memo=mentionMemo[record.id],memo.0 == record.updated { return memo.1 }
        let found=record.mentions; mentionMemo[record.id]=(record.updated,found); return found
    }
    func search(_ query:String,plan:MemoryPlan,fullRange:Bool=false)->[MemoryMetadata] {
        let dated=SmartMemory.hasTimeIntent(query)
        let queryText=query.lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
        let noise=["告诉","转告","回复","帮我","请帮","查一下","昨天","前天","今天","记忆","之前","上次","最近","什么","情况","结论","会议","记得","一下","给我"]
        var topical=queryText
        for word in noise { topical=topical.replacingOccurrences(of:word,with:" ") }
        if let regex=try? NSRegularExpression(pattern:"[0-9]{4}-[0-9]{2}-[0-9]{2}") { topical=regex.stringByReplacingMatches(in:topical,range:NSRange(topical.startIndex...,in:topical),withTemplate:" ") }
        let chars=Array(topical), grams=Set(zip(chars,chars.dropFirst()).filter{!$0.0.isWhitespace && !$0.1.isWhitespace && $0.0.isLetter && $0.1.isLetter}.map{String([$0.0,$0.1])})
        let words=topical.components(separatedBy:CharacterSet.alphanumerics.inverted).filter{$0.count>=2}
        // A dated question also finds drafts that mention one of its days, e.g. "后天开会" written two days ago.
        func inRange(_ day:String)->Bool { day>=plan.from && day<=plan.to }
        let scored=all().compactMap { record -> (LocalInputRecord,Int)? in
            let text=record.text.lowercased()
            // An undated question can recall older local drafts too. Do not use shared-word
            // prefiltering for the vector path: differently worded facts must reach the index.
            guard text != queryText,!queryText.contains(text),!dated || inRange(LocalMemoryStore.day(record.created)) || mentions(record).contains(where:{ inRange($0.date) }) else { return nil }
            let score=grams.filter{text.contains($0)}.count+words.filter{text.contains($0)}.count*3+plan.keywords.filter{!$0.isEmpty && text.contains($0.lowercased())}.count*4
            return score>0 || fullRange ? (record,score) : nil
        }
        let kept=Set(Self.current(scored.map(\.0)).map(\.id))
        let ordered=scored.filter { kept.contains($0.0.id) }.sorted{$0.1 == $1.1 ? $0.0.updated > $1.0.updated : $0.1 > $1.1}
        return (fullRange ? ordered : Array(ordered.prefix(12))).map{$0.0.metadata}
    }
}

struct InputMemorySnapshot:Equatable {
    let text:String
    let start:Int
    let app:String
    var complete:Bool=true
}
// Pure capture state, shared by native keyboard and dictated-text observation.
final class InputMemoryCapture {
    let store:LocalMemoryStore
    var last:InputMemorySnapshot?, pending:InputMemorySnapshot?, changed=Date()
    var ids:[String:String]=[:], blocked:Set<String>=[]
    // What came in by ⌘V or by voice, per paragraph. pasteBase is the paragraph as it was when ⌘V went down;
    // the first change seen after it, and nothing later, is the paste.
    var pasteBase:InputMemorySnapshot?, voice:[String]=[], arrivals:[String:(pasted:[String],voiced:[String])]=[:]
    private var segment=0
    var lastError:String?
    init(store:LocalMemoryStore) { self.store=store }
    func key(_ value:InputMemorySnapshot)->String { "\(value.app)|\(segment)|\(value.complete ? String(value.start) : "partial")" }
    func beginSegment() { flush(); segment += 1 }
    func baseline(_ value:InputMemorySnapshot?) { last=value; pending=nil }
    func observe(_ value:InputMemorySnapshot?,edited:Bool=false,now:Date=Date()) {
        guard let value else { return }
        defer { last=value }
        if let base=pasteBase,value != base {
            pasteBase=nil
            if let span=Self.insertion(from:base,to:value) { arrivals[key(value),default:([],[])].pasted.append(span) }
        }
        guard value != last else { return }
        // Moving to existing text establishes a baseline; it is not a new memory.
        guard edited || (value.complete && last?.start == value.start && last?.app == value.app) else { flush(); return }
        if let previous=last,key(previous) != key(value) { flush() }
        if value.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { if value.start == 0 { VoiceEdits.shared.emptied(app:value.app) }; pending=nil; blocked.remove(key(value)); segment += 1; return }
        guard !blocked.contains(key(value)) else { VoiceEdits.shared.observe(app:value.app,text:value.text,start:value.start); return }
        if !voice.isEmpty { arrivals[key(value),default:([],[])].voiced += voice; voice=[] }
        pending=value; changed=now
    }
    func notePaste(before:InputMemorySnapshot?) { pasteBase=before }
    // The next key or click is about to reach the app: a paste that has not shown up by now (nothing on the
    // clipboard, or still on its way) is dropped rather than pinned on what the user types next.
    func settlePaste(_ current:InputMemorySnapshot?) { if pasteBase != nil { observe(current,edited:true) }; pasteBase=nil }
    func noteVoice(_ text:String) { voice.append(text) }
    // The stretch a change inserted: what is left of the new paragraph after the text it shares with the
    // old one at the start (same paragraph only) and at the end.
    static func insertion(from old:InputMemorySnapshot?,to new:InputMemorySnapshot)->String? {
        let before=Array(old?.app == new.app ? old?.text ?? "" : ""), after=Array(new.text)
        var head=0, tail=0
        if old?.start == new.start { while head<before.count,head<after.count,before[head] == after[head] { head += 1 } }
        while tail<before.count-head,tail<after.count-head,before[before.count-1-tail] == after[after.count-1-tail] { tail += 1 }
        guard after.count-tail>head else { return nil }
        let span=String(after[head..<(after.count-tail)])
        return span.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : span
    }
    func settle(now:Date=Date()) { if pending != nil,now.timeIntervalSince(changed)>=2 { flush() } }
    func suppressGenerated() { flush(); if let last { blocked.insert(key(last)) }; pending=nil }
    // Replies Echo inserted in the last half hour. Blocking covers only the paragraph a reply went into; a line of it
    // found anywhere else (a reply over several lines, a paragraph that moved) is kept out of the user's own words
    // the way a paste is. Shared by every field: a new capture starts each time typing returns to Echo.
    static var generated:[(app:String,line:String,at:Date)]=[]
    static func noteGenerated(_ text:String,app:String?,now:Date=Date()) {
        guard let app else { return }
        generated.removeAll { now.timeIntervalSince($0.at)>1800 }
        for line in text.components(separatedBy:.newlines) {
            let line=line.trimmingCharacters(in:.whitespaces)
            if line.count >= LocalInputRecord.shortestPaste { generated.append((app,line,now)) }
        }
    }
    func flush() {
        guard let value=pending else { return }; pending=nil
        VoiceEdits.shared.observe(app:value.app,text:value.text,start:value.start)  // what a dictation in this paragraph became
        // Short fragments are useful while composing, but are poor independent memories.
        guard value.text.trimmingCharacters(in:.whitespacesAndNewlines).count>=6 else { return }
        let arrived=arrivals[key(value)]
        let inserted=Self.generated.filter { $0.app == value.app && changed.timeIntervalSince($0.at) <= 1800 && value.text.contains($0.line) }.map(\.line)
        do { ids[key(value)]=try store.upsert(value.text,app:value.app,id:ids[key(value)],now:changed,partial:!value.complete,pasted:(arrived?.pasted ?? [])+inserted,voiced:arrived?.voiced ?? []); lastError=nil }
        catch { lastError=error.localizedDescription }
    }
}

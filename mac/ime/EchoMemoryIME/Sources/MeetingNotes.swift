import Foundation

// Feishu meetings, synced in the background with the user's own lark-cli login (Resources/lark.py, read-only):
// the last 7 days, each held meeting with its note's 总结 and 待办 (飞书智能纪要). Lookups read only these local
// files, so they never wait for Feishu. Turning it off removes the files.
final class MeetingNotes {
    static var shared=MeetingNotes()  // checks swap in their own
    static let prefix="lark_meeting_", days=7
    static var defaults=UserDefaults.standard
    static var enabled:Bool { defaults.object(forKey:"larkMeetingsEnabled") as? Bool ?? false }
    static func setEnabled(_ on:Bool) {
        defaults.set(on,forKey:"larkMeetingsEnabled")
        if on { catchUp(force:true) } else { shared.clear(); lastError=nil; defaults.removeObject(forKey:"larkMeetingsSyncedAt") }
    }
    private(set) static var lastError:String?
    private static var running=false
    static var synced:Date? { defaults.object(forKey:"larkMeetingsSyncedAt") as? Date }

    struct Meeting:Codable { let meeting_id:String; let title:String; let start:String; let end:String; let note:[String:String]? }
    struct Day:Codable { let date:String; let meetings:[Meeting] }
    let root:URL
    let sync:(_ from:String,_ to:String,_ root:URL) async throws -> Void
    init(root:URL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("EchoMemoryIME/Meetings"),
         sync:((String,String,URL) async throws -> Void)?=nil) {
        self.root=root
        self.sync=sync ?? { from,to,root in _ = try await SmartMemory(chat:{ _,_ in "" }).bridge(["action":"lark_sync","from":from,"to":to,"root":root.path]) }
    }
    func load(_ day:String)->Day? {
        (try? Data(contentsOf:root.appendingPathComponent(day+".json"))).flatMap { try? JSONDecoder().decode(Day.self,from:$0) }
    }
    // Meetings in a lookup's range, newest first.
    func meetings(_ plan:MemoryPlan)->[(date:String,meeting:Meeting)] {
        let format=DateFormatter(); format.calendar=EchoDates.calendar; format.timeZone=EchoDates.calendar.timeZone; format.dateFormat="yyyy-MM-dd"
        guard let first=format.date(from:plan.from),let last=format.date(from:plan.to),first <= last else { return [] }
        var day=max(first,EchoDates.calendar.date(byAdding:.day,value:-30,to:last)!), found:[(String,Meeting)]=[]
        while day <= last {
            let name=LocalMemoryStore.day(day)
            found += (load(name)?.meetings ?? []).map { (name,$0) }
            day=EchoDates.calendar.date(byAdding:.day,value:1,to:day)!
        }
        return found.sorted { $0.1.start>$1.1.start }  // ISO times with one offset sort as text
    }
    static func clock(_ iso:String)->String { String(iso.dropFirst(11).prefix(5)) }
    func candidates(_ plan:MemoryPlan)->[MemoryMetadata] {
        meetings(plan).map { date,meeting in
            MemoryMetadata(event_id:Self.prefix+meeting.meeting_id,date:date,title:"飞书会议 · \(Self.clock(meeting.start)) \(meeting.title)",
                           summary:meeting.note?["总结"].map { String($0.prefix(200)) } ?? "（没有智能纪要）")
        }
    }
    func sources(_ ids:[String])->[MemorySource] {
        let wanted=Set(ids.filter { $0.hasPrefix(Self.prefix) }.map { String($0.dropFirst(Self.prefix.count)) })
        guard !wanted.isEmpty else { return [] }
        let names=(try? FileManager.default.contentsOfDirectory(atPath:root.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.flatMap { name in
            (load(String(name.dropLast(5)))?.meetings ?? []).filter { wanted.contains($0.meeting_id) }.map { meeting in
                let summary=meeting.note?["总结"] ?? "", todos=meeting.note?["待办"] ?? ""
                let head:String="来源：飞书会议（\(String(meeting.start.prefix(10))) \(Self.clock(meeting.start))–\(Self.clock(meeting.end))「\(meeting.title)」）的智能纪要，由飞书根据会议录音生成，是 AI 归纳；与其他记录不一致时如实说明两边的说法。\n"
                let note:String=meeting.note == nil ? "这场会议没有智能纪要，只知道开过会。" : "总结：\n\(summary.isEmpty ? "（无）" : summary)\n待办：\n\(todos.isEmpty ? "（无）" : todos)"
                let body=head+note
                return MemorySource(event_id:Self.prefix+meeting.meeting_id,date:String(meeting.start.prefix(10)),title:"飞书会议 · "+meeting.title,body:String(body.prefix(8000)))
            }
        }
    }
    func clear() { try? FileManager.default.removeItem(at:root) }

    // Every half hour with By Day (no model is called, so any hour will do): the last 7 days, new notes only.
    static func catchUp(now:Date=Date(),force:Bool=false,done:((String?)->Void)?=nil) {
        guard enabled else { done?("飞书会议未开启"); return }
        guard !running else { done?("正在同步，稍后再看"); return }
        if !force,let synced,now.timeIntervalSince(synced)<25*60 { done?(nil); return }
        running=true
        let to=LocalMemoryStore.day(now), from=LocalMemoryStore.day(EchoDates.calendar.date(byAdding:.day,value:-(days-1),to:now)!)
        Task.detached {
            var failure:String?
            do { try await shared.sync(from,to,shared.root) } catch { failure=error.localizedDescription }
            let reported=failure
            await MainActor.run {
                running=false
                // Turned off while syncing: what was just written goes too.
                if !enabled { shared.clear(); lastError=nil; done?("飞书会议未开启"); return }
                lastError=reported; if reported == nil { defaults.set(now,forKey:"larkMeetingsSyncedAt") }
                done?(reported)
            }
        }
    }
}

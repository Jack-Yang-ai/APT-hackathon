import Foundation

// Feishu meetings as a lookup source: synced files read in the question's range, labelled as Feishu's AI notes,
// counted in the record; off means not read and removed; syncing reports, and a switch-off mid-sync wins.
// Scratch folders, scratch settings and a fake sync only; Feishu is never called.
enum MeetingChecks {
    static var failures:[String]=[]
    static func check(_ ok:Bool,_ label:String) { if !ok { failures.append(label) } }

    @MainActor static func run() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoMeetingCheck-"+UUID().uuidString)
        let realDefaults=MeetingNotes.defaults, realShared=MeetingNotes.shared
        let settings=ScratchDefaults(suiteName:"echo.meeting-check")!; MeetingNotes.defaults=settings
        func cleanup() { MeetingNotes.defaults=realDefaults; MeetingNotes.shared=realShared; try? FileManager.default.removeItem(at:root) }
        defer { cleanup() }
        let folder=root.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let friday=#"{"schema":"echo.meetings/1","date":"2026-10-09","meetings":[{"meeting_id":"m1","title":"prd 设计对齐","start":"2026-10-09T16:03:00+08:00","end":"2026-10-09T17:26:00+08:00","note":{"总结":"决定先做移动端，桌面端下个版本。","待办":"- 小周周三前出排期"}},{"meeting_id":"m2","title":"日会","start":"2026-10-09T09:59:00+08:00","end":"2026-10-09T10:11:00+08:00","note":null}]}"#
        try friday.write(to:folder.appendingPathComponent("2026-10-09.json"),atomically:true,encoding:.utf8)
        try #"{"schema":"echo.meetings/1","date":"2026-10-01","meetings":[{"meeting_id":"m0","title":"更早的会","start":"2026-10-01T10:00:00+08:00","end":"2026-10-01T11:00:00+08:00","note":null}]}"#.write(to:folder.appendingPathComponent("2026-10-01.json"),atomically:true,encoding:.utf8)
        var syncs:[(String,String)]=[], failNext:String?, during:(()->Void)?
        let notes=MeetingNotes(root:folder) { from,to,_ in
            syncs.append((from,to)); during?(); during=nil
            if let message=failNext { failNext=nil; throw MemoryFailure.message(message) }
        }
        MeetingNotes.shared=notes

        // Reading: the question's range only, newest first; a meeting without a note says so.
        let plan=MemoryPlan(from:"2026-10-09",to:"2026-10-09",keywords:[])
        let candidates=notes.candidates(plan)
        check(candidates.map(\.event_id) == ["lark_meeting_m1","lark_meeting_m2"] && candidates[0].title == "飞书会议 · 16:03 prd 设计对齐" && candidates[1].summary == "（没有智能纪要）","in range, newest first: \(candidates.map(\.title))")
        check(notes.candidates(MemoryPlan(from:"2026-10-02",to:"2026-10-08",keywords:[])).isEmpty,"nothing outside the range")
        let sources=notes.sources(["lark_meeting_m1","lark_meeting_m2","local_input_x","echo_day_2026-10-09"])
        check(sources.count == 2 && sources[0].body.contains("决定先做移动端") && sources[0].body.contains("小周周三前出排期") && sources[0].body.contains("由飞书根据会议录音生成，是 AI 归纳") && sources.contains { $0.body.contains("没有智能纪要") },"sources carry the note, labelled as Feishu's AI summary")

        // In a lookup: the meeting is a candidate and a source, and the record counts it.
        var selectPrompt="", answerPrompt=""
        let engine=SmartMemory(chat:{ system,prompt in
            if system.contains("解析个人记忆") { return #"{"from":"2026-10-09","to":"2026-10-09","keywords":["PRD"]}"# }
            if system.contains("从记录目录") { selectPrompt=prompt; return #"{"ids":["lark_meeting_m1"]}"# }
            answerPrompt=prompt; return #"{"replies":["上周五 PRD 对齐定了先做移动端。"],"source_ids":["echo_source_1"]}"#
        },bridge:{ _ in RetrievalResult(events:[]) },local:LocalMemoryStore(root:root.appendingPathComponent("Local")),meetings:notes)
        let trace=MemoryTrace(surface:"inline",trigger:"explicit")
        let reply=try await engine.answer("上周五 PRD 对齐会定了什么",trace:trace)
        check(selectPrompt.isEmpty && answerPrompt.contains("决定先做移动端") && answerPrompt.contains("没有智能纪要") && reply.sources.map(\.event_id) == ["lark_meeting_m1"],"short-range context includes all meetings; only the cited meeting is used")
        check(trace.run.retrieve?.local.meetings == 2 && trace.run.sources.first?.from == "lark","the record counts meetings and names the source")
        check(SmartMemory.answerInstructions(.reply).contains("来源为「飞书会议」"),"the model is told what a Feishu note is")

        // Off: not read by lookups, and the files go.
        let real=SmartMemory(chat:nil,bridge:nil)
        check(real.meetings == nil,"off: lookups do not read meetings")
        settings.set(true,forKey:"larkMeetingsEnabled")
        check(SmartMemory(chat:nil,bridge:nil).meetings === notes,"on: lookups read the synced files")

        // Syncing: the last 7 days; a failure is reported and keeps the old time; not again within 25 minutes.
        let now=ISO8601DateFormatter().date(from:"2026-10-12T04:00:00Z")!
        var told:String?? = .none
        MeetingNotes.catchUp(now:now) { told = .some($0) }
        for _ in 0..<100 where told == nil { try await Task.sleep(nanoseconds:10_000_000) }
        check(syncs.last.map { $0 == ("2026-10-06","2026-10-12") } == true && told == .some(nil) && MeetingNotes.synced == now,"synced the last 7 days")
        told = .none; MeetingNotes.catchUp(now:now.addingTimeInterval(600)) { told = .some($0) }
        check(told == .some(nil) && syncs.count == 1,"not again within 25 minutes")
        told = .none; failNext="token expired"
        MeetingNotes.catchUp(now:now.addingTimeInterval(3600)) { told = .some($0) }
        for _ in 0..<100 where told == nil { try await Task.sleep(nanoseconds:10_000_000) }
        check(told == .some("token expired") && MeetingNotes.lastError == "token expired" && MeetingNotes.synced == now,"a failure is reported, the last good time kept")
        // Turned off while syncing: the switch wins and the files go.
        told = .none; during={ settings.set(false,forKey:"larkMeetingsEnabled") }
        MeetingNotes.catchUp(now:now.addingTimeInterval(7200),force:true) { told = .some($0) }
        for _ in 0..<100 where told == nil { try await Task.sleep(nanoseconds:10_000_000) }
        check(told == .some("飞书会议未开启") && !FileManager.default.fileExists(atPath:folder.path),"off mid-sync: nothing kept")
        told = .none; MeetingNotes.catchUp(now:now,force:true) { told = .some($0) }
        check(told == .some("飞书会议未开启") && syncs.count == 3,"off: no sync, even forced")
        settings.set(true,forKey:"larkMeetingsEnabled"); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        MeetingNotes.setEnabled(false)
        check(!FileManager.default.fileExists(atPath:folder.path) && MeetingNotes.synced == nil,"turning it off removes the synced notes")

        if failures.isEmpty { print("PASS: meetings — synced notes read in the question's range and labelled as Feishu's AI summary; candidates and sources in lookups, counted in the record; off: not read, removed, not synced; last 7 days, every 25 minutes at most, failures reported; switch-off mid-sync wins") }
        else { print("FAIL: \(failures.count) meeting checks\n- "+failures.joined(separator:"\n- ")); cleanup(); exit(1) }
    }
}

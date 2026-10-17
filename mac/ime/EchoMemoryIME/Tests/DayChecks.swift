import Foundation

// By Day against a scratch store and a fake model: the code, not the model, decides what is admitted.
enum DayChecks {
    static var failures:[String]=[]
    static func check(_ ok:Bool,_ label:String) { if !ok { failures.append(label) } }

    static func run() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoDayCheck-"+UUID().uuidString), realConfig=ModelConfig.defaults, realGrowth=GrowthMemoryConfig.defaults
        let scratch=ScratchDefaults(suiteName:"echo.day-check")!
        ModelConfig.defaults=scratch; GrowthMemoryConfig.defaults=scratch
        defer { try? FileManager.default.removeItem(at:root); ModelConfig.defaults=realConfig; GrowthMemoryConfig.defaults=realGrowth }
        let store=LocalMemoryStore(root:root.appendingPathComponent("InputMemory"))
        let friday=ISO8601DateFormatter().date(from:"2026-10-09T01:30:00Z")!  // 09:30 in Shanghai
        let own=try store.upsert("我明天把排期表发给老王，周五前定下来。这个方案我觉得可以先做移动端。",app:"fixture.chat",id:nil,now:friday)
        let mixed=try store.upsert("好的，收到。老王说：下周三上线，价格不变，明天付款。我还没想好要不要跟。",app:"fixture.chat",id:nil,now:friday.addingTimeInterval(1800),pasted:["下周三上线，价格不变，明天付款。"])
        let ask=try store.upsert("你下午把设计稿发我一下",app:"fixture.chat",id:nil,now:friday.addingTimeInterval(3600))
        // A paragraph begun late on Friday and continued after midnight: Friday has what was written by then.
        let lateFriday=ISO8601DateFormatter().date(from:"2026-10-09T15:30:00Z")!  // 23:30
        let begun=try store.upsert("周末要整理的东西很多",app:"fixture.notes",id:nil,now:lateFriday)
        let continued=try store.upsert("周末要整理的东西很多，先把发票报了",app:"fixture.notes",id:nil,now:lateFriday.addingTimeInterval(4200))
        var calls=0, reply="", during:(()->Void)?
        let engine=SmartMemory(chat:{ system,prompt in
            calls += 1; during?(); during=nil
            check(system == DayDigester.instructions && prompt.hasPrefix("日期：2026-10-09") && prompt.contains("【粘贴】下周三上线，价格不变，明天付款。【/粘贴】") && !prompt.contains("先把发票报了"),"the prompt holds that day's drafts with pastes marked")
            return reply
        },bridge:{ _ in RetrievalResult(events:[]) },local:store)
        let digester=DayDigester(store:store,engine:engine,root:root.appendingPathComponent("Days"))
        // Within a day a continued draft is sent once; across midnight each day keeps what it had.
        let note=try store.upsert("上午先记一下要点",app:"fixture.notes",id:nil,now:friday.addingTimeInterval(7000))
        let noteMore=try store.upsert("上午先记一下要点，下午再细化",app:"fixture.notes",id:nil,now:friday.addingTimeInterval(7600))
        check(digester.inputs("2026-10-09").contains { $0.id == noteMore } && !digester.inputs("2026-10-09").contains { $0.id == note },"a continued draft is sent once")
        try store.setDeleted(note,true); try store.setDeleted(noteMore,true)
        check(digester.inputs("2026-10-09").map(\.id) == [own,mixed,ask,begun] && digester.inputs("2026-10-10").map(\.id) == [continued],"each day holds the last version written that day")

        // Model output that tries every way in; four items may pass.
        reply="""
        {"tldr":"和老王对排期，考虑新版本上线\(String(repeating:"很长",count:30))",
         "segments":[{"from":"25:99","to":"03:00","topic":"排期","summary":"约定发排期表","records":["r1","r2","r9"]},{"topic":"伪造","summary":"不存在的记录","records":["r42"]}],
         "items":[
          {"kind":"todo","text":"明天把排期表发给老王","quote":"我明天把排期表发给老王","record":"r1","owner":"self","fields":{"action":"发排期表","counterparty":null,"due_text":"明天","x":"多余"}},
          {"kind":"stance","text":"方案可以先做移动端","quote":"这个方案 我觉得可以先做移动端","record":"r1","owner":"self","fields":{"about":"方案","stance":"先做移动端"}},
          {"kind":"open_question","text":"要不要跟进新价格","quote":"我还没想好要不要跟","record":"r2","owner":"self","fields":{"issue":"要不要跟"}},
          {"kind":"todo","text":"明天把排期表发给老王","quote":"我明天把排期表发给老王","record":"r1","owner":"self","fields":{}},
          {"kind":"todo","text":"周五前定下来","quote":"周五前定下来","record":"r1","owner":"self","fields":{"due_text":"下周三"}},
          {"kind":"stance","text":"我同意下周三涨价两成","quote":"好","record":"r2","owner":"self","fields":{}},
          {"kind":"todo","text":"明天付款","quote":"下周三上线，价格不变，明天付款","record":"r2","owner":"self","fields":{"due_text":"明天"}},
          {"kind":"todo","text":"不发排期表","quote":"我明天把排期表发给老王","record":"r1","owner":"self","fields":{}},
          {"kind":"todo","text":"下午把设计稿发我","quote":"你下午把设计稿发我一下","record":"r3","owner":"self","fields":{}},
          {"kind":"todo","text":"别人的事","quote":"你下午把设计稿发我一下","record":"r3","owner":"other","fields":{}},
          {"kind":"todo","text":"编的","quote":"我已经把合同签了","record":"r1","owner":"self","fields":{}},
          {"kind":"stance","text":"不存在的记录","quote":"随便写的一句话","record":"r7","owner":"self","fields":{}},
          {"kind":"todo","text":null,"quote":"我明天把排期表发给老王","record":"r1","owner":"self"},
          42
         ]}
        """
        guard let file=try await digester.run("2026-10-09") else { throw MemoryFailure.message("no day file") }
        check(calls == 1 && file.schema == "echo.day/1" && file.date == "2026-10-09" && file.tldr.count == 60,"one call, one file, tldr capped")
        check(file.items.map(\.kind) == ["todo","stance","open_question","todo"],"only admitted items: \(file.items.map { $0.kind+" "+$0.text })")
        let todo=file.items.first { $0.text == "明天把排期表发给老王" }
        check(todo?.id == "2026-10-09/todo/"+DayDigester.hex(Data("todo|\(own)|我明天把排期表发给老王".utf8)).prefix(8),"item ids come from the content, so reordering never renames an item")
        check(todo?.due == "2026-10-10" && todo?.fields == ["action":"发排期表","due_text":"明天"] && todo?.record_id == own && todo?.check == "verbatim" && todo?.status == "proposed","a due day from a phrase inside the quote; fields by kind")
        check(file.items.first { $0.kind == "stance" }?.quote == "这个方案我觉得可以先做移动端","quotes are stored as the original text")
        check(file.items.first { $0.text == "周五前定下来" }.map { $0.due == nil && $0.fields["due_text"] == nil } == true,"a time phrase not in the quote gives no date")
        let r=file.rejected
        check(r.short_quote == 1 && r.pasted == 1 && r.contradicts == 1 && r.not_admitted == 2 && r.not_verbatim == 1 && r.unknown_record == 2 && r.duplicate == 1 && r.malformed == 2 && r.unsupported_date == 1 && r.segments == 1,"each rejection counted: \(r)")
        check(file.segments.count == 1 && file.segments[0].from == "09:30" && file.segments[0].to == "10:00" && file.segments[0].record_ids == [own,mixed],"segment times come from the records")
        check(file.inputs.records.map(\.id) == [own,mixed,ask,begun] && file.inputs.records[1].origin == "mixed" && !file.inputs.truncated && file.provenance.prompt == DayDigester.promptVersion,"inputs and provenance recorded")
        let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:digester.url("2026-10-09"))) as! [String:Any]
        let rawItems=raw["items"] as! [[String:Any]], provenance=raw["provenance"] as! [String:Any]
        check(rawItems.allSatisfy { $0.keys.contains("due") } && rawItems.contains { $0["due"] is NSNull } && provenance["host"] is NSNull && (provenance["usage"] as? [String:Any])?["usd"] is NSNull,"unknown values are null, keys always present")
        let attributes=try FileManager.default.attributesOfItem(atPath:digester.url("2026-10-09").path)
        check((attributes[.posixPermissions] as! NSNumber).intValue == 0o600,"day file is private")

        // Lookups read the day as one more local record, with what is AI and what is the user's spelled out.
        let range=MemoryPlan(from:"2026-10-08",to:"2026-10-10",keywords:[])
        check(digester.candidates(range).map(\.event_id) == ["echo_day_2026-10-09"] && digester.candidates(range)[0].title.hasPrefix("APT 每日整理 · 和老王对排期"),"the day joins the catalog")
        let body=digester.sources(["echo_day_2026-10-09"]).first?.body ?? ""
        check(body.contains("待办：明天把排期表发给老王（原话：「我明天把排期表发给老王」；日期：2026-10-10）") && body.contains("未经核对") && body.contains("09:30–10:00 排期"),"the source spells out what is AI and what is the user's")
        let asker=SmartMemory(chat:{ system,_ in
            if system.contains("解析个人记忆") { return #"{"from":"2026-10-09","to":"2026-10-09","keywords":["排期"]}"# }
            if system.contains("从记录目录") { return #"{"ids":["echo_day_2026-10-09"]}"# }
            return #"{"replies":["你答应明天把排期表发给老王。"],"source_ids":["echo_source_1"]}"#
        },bridge:{ _ in RetrievalResult(events:[]) },local:store,days:digester)
        let trace=MemoryTrace(surface:"inline",trigger:"explicit")
        let answered=try await asker.answer("我答应过老王什么",trace:trace)
        check(answered.sources.map(\.event_id) == ["echo_day_2026-10-09"] && trace.run.sources.first?.from == "day" && trace.run.retrieve?.local.days == 1,"a lookup can answer from the day summary")
        let start=Date(); _ = digester.candidates(MemoryPlan(from:"1826-01-01",to:"2026-10-10",keywords:[]))
        check(Date().timeIntervalSince(start)<1,"a two-century range reads at most 31 days")

        // Same drafts: no second call. Forgotten days are redone with the same item ids; changed drafts make
        // the old summary stale.
        let ids=file.items.map(\.id)
        let again=try await digester.run("2026-10-09")
        check(again == nil && calls == 1,"unchanged day is not sent again")
        digester.forget("2026-10-09"); check(digester.candidates(range).isEmpty,"forget removes the day at once")
        let redone=try await digester.run("2026-10-09")
        check(calls == 2 && redone?.items.map(\.id) == ids,"a redone day keeps its item ids")
        _ = try store.upsert("我明天把排期表发给老王。",app:"fixture.chat",id:own,now:friday.addingTimeInterval(60))
        check(digester.candidates(range).isEmpty,"a summary of drafts that changed is not used until it is redone")

        // A draft deleted from the library while the model works: its words never come back in a summary.
        during={ try? store.setDeleted(ask,true); digester.forget("2026-10-09") }
        let raced=try await digester.run("2026-10-09")
        check(raced == nil && calls == 3 && digester.load("2026-10-09") == nil,"a summary is not written when its drafts changed during the call")

        // Bad output: tried twice, then left alone until the drafts change.
        reply="不是 JSON"
        for _ in 0..<3 { _ = try? await digester.run("2026-10-09") }
        check(calls == 5,"a failing day is tried twice, not every half hour (calls \(calls))")
        _ = try store.upsert("我明天把排期表发给老王，周五前定。",app:"fixture.chat",id:own,now:friday.addingTimeInterval(120))
        reply=#"{"tldr":null,"segments":null,"items":[]}"#
        let recovered=try await digester.run("2026-10-09")
        check(calls == 6 && recovered?.tldr == "","changed drafts get a fresh try; nulls are tolerated")

        for id in [own,mixed,begun] { try store.setDeleted(id,true) }
        _ = try await digester.run("2026-10-09")
        check(!FileManager.default.fileExists(atPath:digester.url("2026-10-09").path) && calls == 6,"a day with nothing left loses its file")
        digester.clear(); check(digester.latest == nil && !FileManager.default.fileExists(atPath:digester.root.path),"turning By Day off removes the summaries")

        // When it runs: after 4 a.m. Shanghai time and off DeepSeek's peak hours.
        func at(_ iso:String)->Date { ISO8601DateFormatter().date(from:iso)! }
        check(DayDigester.due(at("2026-10-16T19:59:00Z")) && DayDigester.due(at("2026-10-16T20:00:00Z")),"activity processing is allowed overnight")
        check(DayDigester.due(at("2026-10-14T02:00:00Z")) && DayDigester.due(at("2026-10-14T04:30:00Z")),"activity deadlines are independent of model pricing windows")

        // Two tiers: By Day may have its own model; its Key follows the service and is never typed twice.
        let tiers=ModelConfig.defaults
        tiers.set("https://api.deepseek.com",forKey:"endpoint"); tiers.set("deepseek-flash",forKey:"modelName")
        check(ModelConfig.route(background:true)?.model == "deepseek-flash","without a background model By Day uses the realtime one")
        tiers.set("https://api.stepfun.com/step_plan/v1",forKey:"backgroundEndpoint")
        check(ModelConfig.route(background:true)?.model == "deepseek-flash","half a background setting is no setting")
        tiers.set("step-5-preview",forKey:"backgroundModel")
        let background=ModelConfig.route(background:true), realtime=ModelConfig.route(background:false)
        check(background?.key == .stepFun && background?.url.absoluteString == "https://api.stepfun.com/step_plan/v1/chat/completions" && background?.model == "step-5-preview" && realtime?.model == "deepseek-flash" && realtime?.key == .model,"a StepFun background model uses the voice Key; lookups keep theirs")
        func source(_ endpoint:String)->ModelConfig.KeySource? { ModelConfig.url(endpoint).flatMap(ModelConfig.keySource) }
        check(source("https://api.deepseek.com/beta") == .model && source("https://api.stepfun.ai/step_plan/v1") == .stepFun,"same origin uses the model Key, StepFun the voice Key")
        check(source("https://api.deepseek.com:8443") == nil && source("https://api.stepfun.com.evil.example/v1") == nil && source("https://api.stepfun.com:444/v1") == nil && source("https://evil.example/v1") == nil && source("http://localhost:8080") == nil,"a Key never goes to another origin")
        check(DayDigester.due(at("2026-10-14T02:00:00Z")),"a background model off DeepSeek ignores DeepSeek's peak")
        tiers.set("https://evil.example/v1",forKey:"backgroundEndpoint")
        check(ModelConfig.route(background:true) == nil && ModelConfig.route(background:false) != nil && DayDigester.due(at("2026-10-14T02:00:00Z")),"an unsupported background service has no route; lookups are unaffected")
        tiers.set("https://api.stepfun.com/step_plan/v1",forKey:"backgroundEndpoint")

        // The real request path against a fake service: each tier goes to its own address with its own Key,
        // and the summary says which model wrote it.
        let ledger=MemoryLog.shared; MemoryLog.shared=MemoryLog(root:root.appendingPathComponent("Log"))
        SmartMemory.readKey={ "sk-realtime" }; SmartMemory.readStepKey={ "sk-step" }; SmartMemory.protocolClasses=[FakeModelService.self]; FakeModelService.requests=[]
        defer { MemoryLog.shared=ledger; SmartMemory.readKey={ try MemoryModelKey.read() }; SmartMemory.readStepKey={ try StepVoiceKey.read() }; SmartMemory.protocolClasses=nil }
        let ok=#"{"choices":[{"message":{"content":"{\"tldr\":\"整理排期\",\"segments\":[],\"items\":[]}"}}],"usage":{"prompt_tokens":100,"completion_tokens":20}}"#
        FakeModelService.replies=[(200,ok),(200,ok)]
        let wire=SmartMemory(chat:nil,bridge:nil,local:LocalMemoryStore(root:root.appendingPathComponent("Empty")))
        let wired=LocalMemoryStore(root:root.appendingPathComponent("Wired"))
        _ = try wired.upsert("我明天把排期表发给老王，周五前定下来。",app:"fixture.chat",id:nil,now:friday)
        let written=try await DayDigester(store:wired,engine:wire,root:root.appendingPathComponent("WiredDays")).run("2026-10-09")
        _ = try await wire.chat(system:"s",prompt:"p",scene:"answer")
        let sent=FakeModelService.requests.map { ($0.url?.absoluteString ?? "",$0.value(forHTTPHeaderField:"Authorization") ?? "") }
        check(sent.count == 2 && sent[0] == ("https://api.stepfun.com/step_plan/v1/chat/completions","Bearer sk-step") && sent[1] == ("https://api.deepseek.com/v1/chat/completions","Bearer sk-realtime"),"By Day goes to the background model, lookups to the realtime one, got \(sent.map(\.0))")
        check(DayDigester().maxTokens >= 8000 && DayDigester().timeout >= 180,"By Day keeps a reasoner-sized output budget and transport patience; 4096 starved step-5-preview into empty bodies and the 120s wall cut off large days on 2026-10-16")
        check(written?.provenance.model == "step-5-preview" && written?.provenance.host == "api.stepfun.com" && written?.tldr == "整理排期","the summary names the model that wrote it")

        // Model-service endpoint: default stays the local service; a cloud tunnel (MacBook client of
        // the mini hub) may override, and nothing else is trusted — the token rides every request,
        // so a tunnel is adopted only when it is the very service that token was saved for.
        let local=URL(string:"http://127.0.0.1:18791/agent/model")!
        scratch.removeObject(forKey:"growthMemoryEndpoint")
        check(AgentModels.endpoint(nil) == local && AgentModels.endpoint("http://127.0.0.1:18791/agent/model") == local,"default and the exact local endpoint stay the local service")
        check(AgentModels.endpoint("https://apt-backend.example/agent/model").absoluteString == "https://apt-backend.example/agent/model" && AgentModels.endpoint("https://APT-BACKEND.example:443/agent/model").absoluteString == "https://apt-backend.example/agent/model","the cloud tunnel the token belongs to is adopted, host case and :443 normalized")
        check(AgentModels.endpoint("https://apt-backend.example/other") == local && AgentModels.endpoint("http://192.168.1.5:18791/agent/model") == local && AgentModels.endpoint("http://127.0.0.1:18791/other") == local && AgentModels.endpoint("ftp://example.com/agent/model") == local && AgentModels.endpoint("not a url") == local,"wrong path, http off-loopback, other schemes and junk fall back to the local service")
        let foreign=["https://evil.example/agent/model","https://apt-backend.example.evil.example/agent/model","https://apt-backend.example:8443/agent/model","https://user:pass@apt-backend.example/agent/model","https://apt-backend.example/agent/model?to=evil","https://apt-backend.example/agent/model#f","https://apt-backend.example/agent/model/","https://apt-backend.example:0/agent/model"].filter { AgentModels.endpoint($0) != local }
        check(foreign.isEmpty,"another host, port, userinfo, query, fragment or path variant never receives the token, leaked to \(foreign)")
        scratch.set("https://hub.example:8443",forKey:"growthMemoryEndpoint")
        check(AgentModels.endpoint("https://hub.example:8443/agent/model").absoluteString == "https://hub.example:8443/agent/model" && AgentModels.endpoint("https://apt-backend.example/agent/model") == local,"the trusted tunnel follows the service the token was saved for, not a fixed host")
        scratch.removeObject(forKey:"growthMemoryEndpoint")

        // A malformed model sample is transient — the same /agent/answer failed once and passed on
        // retry live on 2026-10-16 — so decode takes one fresh sample before surfacing the error,
        // and exactly two bad samples still surface it.
        var samples=["{\"from\":\"2026-10-","{\"from\":\"2026-10-09\",\"to\":\"2026-10-09\",\"keywords\":[\"排期\"]}"], pulls=0
        let retriedPlan=try await SmartMemory.decoded(as:MemoryPlan.self) { pulls += 1; return samples[min(pulls-1,samples.count-1)] }
        check(pulls == 2 && retriedPlan.keywords == ["排期"] && retriedPlan.from == "2026-10-09","decode retries once on a malformed sample and keeps the good one")
        do {
            _ = try await SmartMemory.decoded(as:MemoryPlan.self) { pulls += 1; return "not json at all" }
            check(false,"two malformed samples must surface the error")
        } catch { check(pulls == 4,"the second bad sample rethrows instead of looping") }
        do {
            _ = try await SmartMemory.decoded(as:MemoryPlan.self) { pulls += 1; throw URLError(.timedOut) }
            check(false,"a transport failure must surface")
        } catch { check(pulls == 5,"a transport failure is not retried, got \(pulls - 4) calls") }
        // A JSON reply cut at the output cap is refused, so decode's repair can never pass it off as whole.
        FakeModelService.replies=[(200,#"{"choices":[{"message":{"content":"{\"replies\":[\"今天\"]}"},"finish_reason":"length"}]}"#),(200,#"{"choices":[{"message":{"content":"今天"},"finish_reason":"length"}]}"#)]
        do { _ = try await wire.chat(system:"s",prompt:"p",scene:"answer"); check(false,"a truncated JSON reply must be refused") }
        catch { check(error.localizedDescription.contains("截断"),"truncation names itself, got \(error.localizedDescription)") }
        let prose=try await wire.chat(system:"s",prompt:"p",scene:"answer",json:false)
        check(prose == "今天","non-JSON text keeps a length-capped reply")

        if failures.isEmpty { print("PASS: by day — closed record set; quotes of six or more characters stored as written; nothing from pasted text; no contradicting negation; others' tasks and requests kept out; due days only from phrases in the quote; fields by kind; segment times from records; every rejection counted; nulls kept; lookups read fresh days within 31; stable ids; no write after a mid-call deletion; two tries per change; activity deadlines throughout the day; off removes files; a background model of its own with the Key that service already has; a reasoner-sized By Day output budget and transport patience; the model-service endpoint stays local unless an exact cloud-tunnel URL on the token's own service is set; a malformed model sample gets one fresh retry and two failures surface the error; transport failures are not retried and a length-cut JSON reply is refused") }
        else { print("FAIL: \(failures.count) by-day checks\n- "+failures.joined(separator:"\n- ")); try? FileManager.default.removeItem(at:root); exit(1) }
    }
}

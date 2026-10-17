import Foundation

// Local-only fixtures: no Growth, Keychain, network or real model requests.
enum MemoryActivityChecks {
    static func basics() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoLocalChecks-"+UUID().uuidString),now=Date()
        defer { try? FileManager.default.removeItem(at:root) }
        let sample=LocalInputRecord(id:"local_input_fixture",created:now,updated:now,app:"fixture",text:"初始草稿")
        var record=sample; record.deleted=false; record.text=String(repeating:"字",count:300)
        var plan=MemoryActivityPlan()
        plan.reconcile([record],done:[],now:now)
        precondition(plan.interval == 1800 && plan.deadline == now.addingTimeInterval(1800))
        record.version=record.sourceRevision+1; record.text=String(repeating:"新",count:350)
        plan.reconcile([record],done:[],now:now.addingTimeInterval(1700))
        precondition(plan.deadline == now.addingTimeInterval(1800),"continuous typing never postpones oldest dirty")
        record.text=String(repeating:"字",count:2200); plan.reconcile([record],done:[],now:now.addingTimeInterval(1700))
        precondition(plan.interval == 900)
        record.text="零星输入"; plan.reconcile([record],done:[],now:now.addingTimeInterval(1700)); precondition(plan.interval == 3600)
        let restored=try JSONDecoder().decode(MemoryActivityPlan.self,from:JSONEncoder().encode(plan)); precondition(restored.deadline == plan.deadline)
        plan.reconcile([record],done:[record.id],now:now); precondition(plan.deadline == nil)
        precondition(plan.sleepInterval() == 1800 && plan.sleepInterval() == 3600 && plan.sleepInterval() == 7200 && plan.sleepInterval() == 14400)
        plan.reconcile([record],done:[],now:now.addingTimeInterval(20000)); precondition(plan.deadline == now.addingTimeInterval(23600),"new input wakes from four-hour idle")

        let legacyStore=LocalMemoryStore(root:root.appendingPathComponent("LegacySources"))
        _ = try legacyStore.upsert("旧版已经整理过的输入仍然可以作为依据。",app:"fixture.legacy",id:nil,now:now)
        let legacyRecord=legacyStore.all().first!,legacyDay=LocalMemoryStore.day(now)
        let legacyDigest=DayDigester(store:legacyStore,engine:SmartMemory(chat:{ _,_ in "" },bridge:{ _ in RetrievalResult(events:[]) }),root:root.appendingPathComponent("LegacyDays"))
        let emptyDraft=try SmartMemory.decode(#"{"tldr":"旧版整理","segments":[],"items":[]}"#,as:DayDigester.Draft.self)
        let oldFile=DayDigester.judge(day:legacyDay,draft:emptyDraft,aliases:["r1":legacyRecord],digest:"legacy-text-digest",truncated:false,model:"fixture",host:nil,usage:.init(input:nil,output:nil,usd:nil))
        try legacyDigest.write(oldFile)
        var oldJSON=try JSONSerialization.jsonObject(with:Data(contentsOf:legacyDigest.url(legacyDay))) as! [String:Any]
        var oldInputs=oldJSON["inputs"] as! [String:Any],oldRows=oldInputs["records"] as! [[String:Any]]
        for index in oldRows.indices { oldRows[index].removeValue(forKey:"revision") };oldInputs["records"]=oldRows;oldJSON["inputs"]=oldInputs
        try JSONSerialization.data(withJSONObject:oldJSON).write(to:legacyDigest.url(legacyDay))
        precondition(legacyDigest.files(MemoryPlan(from:legacyDay,to:legacyDay,keywords:[])).count == 1,"legacy digest algorithms do not hide unchanged summaries")

        let activity=LocalMemoryStore(root:root.appendingPathComponent("ActivitySources"))
        let first=try activity.upsert("我明天把项目的排期表发给同事。",app:"fixture.notes",id:nil,now:now)
        var second="",batch=0,mutateFirst=false
        let engine=SmartMemory(chat:{ _,prompt in
            batch += 1
            if batch == 1 { second=try activity.upsert("我下午核对一下项目的预算报价。",app:"fixture.notes",id:nil,now:now.addingTimeInterval(60)) }
            if batch == 2 { precondition(!prompt.contains("排期表"),"incremental batch sends only new sources") }
            if mutateFirst { try activity.setDeleted(second,true,now:now.addingTimeInterval(120)) }
            return #"{"tldr":"本批输入概要","segments":[{"topic":"项目","summary":"整理项目输入","records":["r1"]}],"items":[]}"#
        },bridge:{ _ in RetrievalResult(events:[]) },local:activity)
        let digester=DayDigester(store:activity,engine:engine,root:root.appendingPathComponent("ActivityDays")),day=LocalMemoryStore.day(now)
        let one=try await digester.run(day,incremental:true)
        precondition(one?.inputs.records.map(\.id) == [first] && one?.scope == "activity","unrelated new sources do not cancel a completed batch or become marked processed")
        precondition(digester.files(MemoryPlan(from:day,to:day,keywords:[])).count == 1,"new unprocessed input does not hide valid earlier evidence")
        let two=try await digester.run(day,incremental:true)
        precondition(Set(two!.inputs.records.map(\.id)) == [first,second] && two!.segments.count == 2)
        _ = try activity.upsert("我下午核对一下项目的预算报价，先确认税率。",app:"fixture.notes",id:second,now:now.addingTimeInterval(100))
        mutateFirst=true
        let stale=try await digester.run(day,incremental:true)
        precondition(stale == nil && digester.load(day)?.inputs.records.map(\.id) == [first],"deleted source rejects late products while retaining independent earlier evidence")
        try digester.prune(day)
        precondition(digester.load(day)?.inputs.records.map(\.id) == [first],"direct deletion prunes stale members without another model")
        _ = try activity.upsert("我明天把项目的排期表发给同事，先核对负责人。",app:"fixture.notes",id:first,now:now.addingTimeInterval(150))
        let closeRoot=root.appendingPathComponent("ClosingDays")
        var closer:DayDigester!
        let closingEngine=SmartMemory(chat:{ _,_ in closer.clear(); return #"{"tldr":"旧任务","segments":[],"items":[]}"# },bridge:{ _ in RetrievalResult(events:[]) },local:activity)
        closer=DayDigester(store:activity,engine:closingEngine,root:closeRoot)
        let cancelled=try await closer.run(day,incremental:true)
        precondition(cancelled == nil && !FileManager.default.fileExists(atPath:closeRoot.path),"turning off prevents old task recreating summary and retry metadata")
        var replyCalls=0
        let replyEngine=SmartMemory(chat:{ _,_ in
            replyCalls += 1; try activity.setDeleted(first,true,now:now.addingTimeInterval(160))
            return "{\"replies\":[\"旧回复\"],\"source_ids\":[\"echo_source_1\"]}"
        },bridge:{ request in request["action"] as? String == "retrieve" ? RetrievalResult(events:[]) : RetrievalResult(sources:[]) },local:activity,vectors:false)
        do { _ = try await replyEngine.answer("今天排期表的负责人",forceRefresh:true); preconditionFailure("deleted evidence must not return a reply") } catch {}
        precondition(replyCalls == 1 && activity.all(deleted:true).contains { $0.id == first })
        let pruneDays=MemoryActivityPlan.daysToPrune(live:activity.all(),deleted:activity.all(deleted:true),cutoff:now.addingTimeInterval(-86400))
        precondition(pruneDays.contains(day),"deleting a day's last source still schedules pruning")
        for name in pruneDays { try digester.prune(name) }
        precondition(digester.load(day) == nil)
    }
    @MainActor static func settled(_ c:MemoryActivityCoordinator) async throws {
        for _ in 0..<3000 { if !c.status.busy { return }; try await Task.sleep(nanoseconds:1_000_000) }
        throw MemoryFailure.message("local fixture did not settle")
    }
    @MainActor static func run() async throws {
        try await basics()
        try await lifecycle()
        print("PASS: independent local activity, incrementality, restart, idle wake, fairness, durable retries, manual retry, deletion/restore and cancellation; zero Growth requests")
    }
}

extension MemoryActivityChecks {
    @MainActor static func lifecycle() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoActivityLifecycle-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let start=Date(),reply=#"{"tldr":"本批概要","segments":[{"topic":"项目","summary":"项目输入","records":["r1"]}],"items":[]}"#
        var record=LocalInputRecord(id:"local_input_fixture",created:start,updated:start,app:"fixture",text:String(repeating:"中",count:3000)),plan=MemoryActivityPlan()
        plan.reconcile([record],done:[],now:start); precondition(plan.interval == 900)
        plan.reconcile([record],done:[record.id],now:start)
        record.text=String(repeating:"中",count:1500)+"改"+String(repeating:"中",count:1499); record.version=2
        plan.reconcile([record],done:[],now:start)
        precondition(plan.interval == 3600 && plan.dirty[record.id]!.characters<=32,"small edits to long processed drafts are sparse")
        let legacy=try JSONDecoder().decode(MemoryActivityPlan.self,from:Data(#"{"dirty":{},"idleInterval":1800}"#.utf8))
        precondition(legacy.baselines == nil && legacy.failures == nil)
        var now=start,calls=0,armed:[TimeInterval]=[]
        let store=LocalMemoryStore(root:root.appendingPathComponent("Sources"))
        let engine=SmartMemory(chat:{ _,_ in calls += 1; return reply },bridge:{ _ in preconditionFailure("backend forbidden") },local:store)
        let digest=DayDigester(store:store,engine:engine,root:root.appendingPathComponent("Days")),file=root.appendingPathComponent("Activity/schedule.json")
        func coordinator()->MemoryActivityCoordinator { MemoryActivityCoordinator(digester:digest,file:file,enabled:{ true },clock:{ now },schedule:{ armed.append($0) },prepare:{}) }
        let first=coordinator(); first.start(observe:false)
        for interval in [1800.0,3600,7200,14400] { precondition(armed.last == interval); now=now.addingTimeInterval(interval); first.wake() }
        precondition(calls == 0)
        let id=try store.upsert(String(repeating:"字",count:300),app:"fixture",id:nil,now:now)
        first.wake(); let deadline=first.status.next!; precondition(deadline == now.addingTimeInterval(1800))
        now=now.addingTimeInterval(1700); _ = try store.upsert(String(repeating:"字",count:350),app:"fixture",id:id,now:now)
        first.wake(); precondition(first.status.next == deadline)
        let reboot=coordinator(); reboot.start(observe:false); precondition(reboot.status.next == deadline)
        now=deadline; reboot.wake(); try await settled(reboot)
        precondition(calls == 1 && reboot.status.pending == 0 && reboot.status.lastCompleted == now)
        reboot.runNow(); try await settled(reboot); precondition(calls == 1)
        let state=try String(contentsOf:file); precondition(!state.contains(String(repeating:"字",count:20)))
        let permission=try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber; precondition(permission.intValue == 0o600)

        let fairStore=LocalMemoryStore(root:root.appendingPathComponent("FairSources")),old=start.addingTimeInterval(-86400)
        let oldID=try fairStore.upsert("我明天把项目排期发给同事确认。",app:"old",id:nil,now:old)
        _ = try fairStore.upsert("我下午核对一下项目的预算报价。",app:"new",id:nil,now:start)
        var oldFails=true,oldCalls=0,newCalls=0
        let fairEngine=SmartMemory(chat:{ _,prompt in
            if prompt.contains("排期") { oldCalls += 1; if oldFails { throw MemoryFailure.message("fixture offline") } } else { newCalls += 1 }
            return reply
        },bridge:{ _ in preconditionFailure("backend forbidden") },local:fairStore)
        let fairDigest=DayDigester(store:fairStore,engine:fairEngine,root:root.appendingPathComponent("FairDays")),fairFile=root.appendingPathComponent("FairActivity/schedule.json")
        now=start
        func fairCoordinator(_ d:DayDigester)->MemoryActivityCoordinator { MemoryActivityCoordinator(digester:d,file:fairFile,enabled:{ true },clock:{ now },schedule:{ _ in },prepare:{}) }
        let fair=fairCoordinator(fairDigest); fair.start(observe:false); now=now.addingTimeInterval(3600); fair.wake(); try await settled(fair)
        precondition(oldCalls == 1 && newCalls == 1 && fair.status.pending == 1 && fair.status.next == now.addingTimeInterval(300))
        now=now.addingTimeInterval(300); fair.wake(); try await settled(fair)
        precondition(oldCalls == 2 && fair.status.paused == 1 && fair.status.next == nil)
        let freshID=try fairStore.upsert("我今天核对一下新的项目负责人。",app:"fresh",id:nil,now:now)
        fair.wake(); precondition(!fair.status.busy && fair.status.next == now.addingTimeInterval(3600) && newCalls == 1,"paused day must not advance a fresh source deadline")
        try fairStore.setDeleted(freshID,true,now:now); fair.wake()
        now=now.addingTimeInterval(8*86400); fair.wake(); try await settled(fair)
        precondition(fair.status.pending == 1 && oldCalls == 2,"queued drafts do not expire at seven days")
        let restartDigest=DayDigester(store:fairStore,engine:fairEngine,root:fairDigest.root),restart=fairCoordinator(restartDigest)
        restart.start(observe:false); try await settled(restart); precondition(restart.status.paused == 1 && oldCalls == 2)
        oldFails=false; restart.runNow(); try await settled(restart)
        precondition(oldCalls == 3 && newCalls == 1 && restart.status.pending == 0)
        let oldDay=LocalMemoryStore.day(old)
        let sibling=try fairStore.upsert("我下午核对一下项目的负责人名单。",app:"sibling",id:nil,now:old.addingTimeInterval(120))
        _ = try await restartDigest.run(oldDay,incremental:true)
        try fairStore.setDeleted(oldID,true,now:now); try restartDigest.prune(oldDay)
        precondition(restartDigest.load(oldDay)?.inputs.records.map(\.id) == [sibling])
        try fairStore.setDeleted(oldID,false,now:now.addingTimeInterval(1)); restart.wake(); precondition(restart.status.pending == 1)
        restart.runNow(); try await settled(restart)
        precondition(Set(restartDigest.load(oldDay)!.inputs.records.map(\.id)) == [oldID,sibling])

        let damagedRoot=root.appendingPathComponent("DamagedDays")
        try FileManager.default.createDirectory(at:damagedRoot,withIntermediateDirectories:true)
        try Data("broken journal".utf8).write(to:damagedRoot.appendingPathComponent(".attempts.json"))
        var damagedCalls=0
        let damaged=DayDigester(store:store,engine:SmartMemory(chat:{ _,_ in damagedCalls += 1; return reply },bridge:{ _ in preconditionFailure("no backend") },local:store),root:damagedRoot)
        let day=LocalMemoryStore.day(store.all().first!.created)
        do { _ = try await damaged.run(day,incremental:true); preconditionFailure("corrupt journal must stop spending") } catch {}
        precondition(damagedCalls == 0); try damaged.resetRetries(day); _ = try await damaged.run(day,incremental:true)
        let preserved=try FileManager.default.contentsOfDirectory(atPath:damagedRoot.path).contains { $0.hasPrefix(".attempts.corrupt-") }
        precondition(damagedCalls == 1 && preserved)
        let parent=root.appendingPathComponent("BlockedParent"); try Data().write(to:parent)
        let blocked=DayDigester(store:store,engine:SmartMemory(chat:{ _,_ in preconditionFailure("non-durable retry budget cannot spend") },bridge:{ _ in preconditionFailure("no backend") },local:store),root:parent.appendingPathComponent("Days"))
        do { _ = try await blocked.run(day,incremental:true); preconditionFailure("must fail budget write") } catch {}

        let closingStore=LocalMemoryStore(root:root.appendingPathComponent("ClosingSources"))
        _ = try closingStore.upsert("我明天核对整个项目的报价清单。",app:"closing",id:nil,now:now)
        var enabled=true,entered=0
        var held:CheckedContinuation<String,Never>?
        let closingEngine=SmartMemory(chat:{ _,_ in
            entered += 1
            if entered == 1 { return await withCheckedContinuation { held=$0 } }
            return reply
        },bridge:{ _ in preconditionFailure("no backend") },local:closingStore)
        let closing=DayDigester(store:closingStore,engine:closingEngine,root:root.appendingPathComponent("ClosingDays"))
        let closingCoordinator=MemoryActivityCoordinator(digester:closing,file:root.appendingPathComponent("ClosingActivity/schedule.json"),enabled:{ enabled },clock:{ now },schedule:{ _ in },prepare:{})
        closingCoordinator.start(observe:false); closingCoordinator.runNow()
        for _ in 0..<3000 { if held != nil { break }; try await Task.sleep(nanoseconds:1_000_000) }
        precondition(held != nil); enabled=false; closing.clear(); closingCoordinator.wake()
        precondition(!closingCoordinator.status.busy && closingCoordinator.status.pending == 0)
        enabled=true; closingCoordinator.wake(); closingCoordinator.runNow(); try await settled(closingCoordinator)
        precondition(entered == 2 && closingCoordinator.status.pending == 0)
        let newFile=try Data(contentsOf:closing.url(LocalMemoryStore.day(now)))
        held?.resume(returning:reply); held=nil
        try await Task.sleep(nanoseconds:20_000_000)
        let afterOldCallback=try Data(contentsOf:closing.url(LocalMemoryStore.day(now)))
        precondition(newFile == afterOldCallback && !closingCoordinator.status.busy,"late pre-disable task cannot replace new product or state")
        enabled=false; closing.clear(); closingCoordinator.wake()
        precondition(closingCoordinator.status.phase == "已关闭" && !FileManager.default.fileExists(atPath:closing.root.path))

    }
}

import Foundation

enum GrowthMemoryChecks {
    static func run() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoGrowthChecks-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=LocalMemoryStore(root:root.appendingPathComponent("Sources")),now=Date()
        let id=try store.upsert("明天我要把项目排期表发给同事确认。",app:"fixture.notes",id:nil,now:now,partial:true)
        precondition(store.all().first!.sourceRevision == 1)
        _ = try store.upsert("明天我要把项目排期表发给同事确认。",app:"fixture.notes",id:id,now:now,partial:false)
        precondition(store.all().first!.sourceRevision == 2,"completeness is a semantic change")
        try store.setDeleted(id,true,now:now.addingTimeInterval(10))
        precondition(store.all(deleted:true).first!.sourceRevision == 3 && store.all(deleted:true).first!.updated>now)
        let reopened=LocalMemoryStore(root:store.root)
        precondition(reopened.all(deleted:true).first!.sourceRevision == 3)
        _ = try reopened.upsert("明天我要把项目排期表发给同事确认。",app:"fixture.notes",id:id,now:now.addingTimeInterval(20),partial:false)
        precondition(reopened.all().first!.sourceRevision == 4,"same words restore at a new version")

        var calls=0,device="",changeDuringSend=false
        let sender:GrowthMemorySync.Send={ _,_,data in
            calls += 1
            let batch=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let seen=batch["device_id"] as! String
            if device.isEmpty { device=seen }; precondition(device == seen)
            let rows=batch["records"] as! [[String:Any]]
            if changeDuringSend {
                changeDuringSend=false
                _ = try reopened.upsert("明天我要把项目排期表发给同事确认，预算另外核对。",app:"fixture.notes",id:id,now:now.addingTimeInterval(30))
            }
            return try JSONSerialization.data(withJSONObject:["schema":"growth.input-memory.receipt/1","accepted":rows.map { ["id":$0["id"]!,"revision":$0["revision"]!] },"stale":[],"conflicts":[]])
        }
        let sync=GrowthMemorySync(store:reopened,root:root.appendingPathComponent("Sync"),send:sender),url=URL(string:"https://growth.example")!
        _ = try await sync.sync(to:url,token:"fixture-token")
        _ = try await sync.sync(to:url,token:"fixture-token"); precondition(calls == 1,"unchanged source is not resent")
        _ = try reopened.upsert("明天我要把项目排期表发给同事确认，价格先不变。",app:"fixture.notes",id:id,now:now.addingTimeInterval(25))
        changeDuringSend=true
        _ = try await sync.sync(to:url,token:"fixture-token")
        precondition(GrowthMemorySync.status.pending == 1)
        let restarted=GrowthMemorySync(store:reopened,root:root.appendingPathComponent("Sync"),send:sender)
        _ = try await restarted.sync(to:url,token:"fixture-token"); precondition(calls == 3)
        let disk=String(data:try Data(contentsOf:root.appendingPathComponent("Sync/state.json")),encoding:.utf8)!
        precondition(!disk.contains("fixture-token") && !disk.contains("项目排期"),"outbox journal contains neither token nor source text")
        try reopened.setDeleted(id,true,now:now.addingTimeInterval(40))
        let tombstone=GrowthMemorySync.Record(reopened.all(deleted:true).first!)
        precondition(tombstone.text.isEmpty && tombstone.pasted.isEmpty && tombstone.voiced.isEmpty)
        _ = try await restarted.sync(to:url,token:"fixture-token")
        precondition(GrowthMemoryConfig.url("http://growth.example") == nil && GrowthMemoryConfig.url("https://growth.example@evil.example") == nil && GrowthMemoryConfig.url("https://growth.example/a") == nil)
        let localURL=GrowthMemoryConfig.url("https://LOCALHOST:18791/")!
        precondition(localURL.absoluteString == "https://localhost:18791" && GrowthMemoryConfig.url("https://growth.example:443/")?.absoluteString == "https://growth.example")
        precondition(GrowthMemoryConfig.account(localURL) != GrowthMemoryConfig.account(GrowthMemoryConfig.url("https://localhost:18792")!))
        precondition(GrowthMemoryConfig.url("https://localhost:0") == nil && GrowthMemoryConfig.url("https://localhost:65536") == nil)
        let broken=GrowthMemorySync(store:reopened,root:root.appendingPathComponent("Broken"),send:{ _,_,_ in throw MemoryFailure.message("offline") })
        do { _ = try await broken.sync(to:url,token:"fixture-token"); preconditionFailure("must preserve pending after offline") } catch {}
        let brokenState=try await broken.state(); precondition(brokenState.destinations.isEmpty)

        // Days/ replicas: a versioned library copy under the same outbox rules as drafts.
        let daysRoot=root.appendingPathComponent("Days"),digester=DayDigester(store:reopened,root:daysRoot)
        func dayFile(_ date:String,_ tldr:String)->DayFile {
            DayFile(date:date,generated_at:"\(date)T21:00:00+08:00",inputs:.init(records:[],digest:"fixture",truncated:false),
                   provenance:.init(prompt:"p",rules:"r",model:"m",host:nil,usage:.init(input:1,output:1,usd:0.01)),
                   tldr:tldr,segments:[],items:[],rejected:DayFile.Rejected())
        }
        var offered=[[String:Any]]()
        let daySender:GrowthMemorySync.Send={ _,_,data in
            let batch=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let rows=batch["records"] as! [[String:Any]]
            offered.append(contentsOf:rows)
            return try JSONSerialization.data(withJSONObject:["schema":"growth.input-memory.receipt/1","accepted":rows.map { ["id":$0["id"]!,"revision":$0["revision"]!] },"stale":[],"conflicts":[]])
        }
        let emptyStore=LocalMemoryStore(root:root.appendingPathComponent("EmptySources"))
        let daySync=GrowthMemorySync(store:emptyStore,days:digester,root:root.appendingPathComponent("DaySync"),send:daySender)
        try digester.write(dayFile("2026-10-13","第一批整理"))
        let daySent1=try await daySync.sync(to:url,token:"fixture-token"); precondition(daySent1 == 1)
        precondition(offered.count == 1 && offered[0]["id"] as! String == "echo_day_2026-10-13" && offered[0]["revision"] as! Int == 1)
        precondition((offered[0]["text"] as! String) == DayDigester.body(of:dayFile("2026-10-13","第一批整理")),"published bytes equal the retrieval render")
        precondition((offered[0]["partial"] as! Bool) == false && (offered[0]["created"] as! String) == "2026-10-13T00:00:00+08:00")
        _ = try await daySync.sync(to:url,token:"fixture-token"); precondition(offered.count == 1,"unchanged day is not resent")
        try digester.write(dayFile("2026-10-13","改写后的整理"))
        let daySent2=try await daySync.sync(to:url,token:"fixture-token"); precondition(daySent2 == 1)
        precondition(offered[1]["revision"] as! Int == 2,"a rewritten day publishes a new version")
        digester.forget("2026-10-13")
        let daySent3=try await daySync.sync(to:url,token:"fixture-token"); precondition(daySent3 == 1)
        precondition(offered[2]["revision"] as! Int == 3 && offered[2]["deleted"] as! Bool == true && (offered[2]["text"] as! String).isEmpty,"a vanished day tombstones")
        let dayRestarted=GrowthMemorySync(store:emptyStore,days:digester,root:root.appendingPathComponent("DaySync"),send:daySender)
        _ = try await dayRestarted.sync(to:url,token:"fixture-token"); precondition(offered.count == 3,"acked days survive a restart")
        let ledger=String(data:try Data(contentsOf:root.appendingPathComponent("DaySync/day-library.json")),encoding:.utf8)!
        precondition(!ledger.contains("fixture-token") && !ledger.contains("第一批整理"),"day ledger keeps neither token nor day text")
        let crashRoot=root.appendingPathComponent("DayCrash")
        try digester.write(dayFile("2026-10-14","次日整理"))
        let crashed=GrowthMemorySync(store:emptyStore,days:digester,root:crashRoot,send:{ _,_,_ in throw MemoryFailure.message("offline") })
        do { _ = try await crashed.sync(to:url,token:"fixture-token"); preconditionFailure("offline day publish must fail") } catch {}
        let persisted=try JSONDecoder().decode([String:GrowthMemorySync.DayLibraryEntry].self,from:Data(contentsOf:crashRoot.appendingPathComponent("day-library.json")))
        precondition(persisted["2026-10-14"]?.revision == 1,"ledger reaches disk before any send")
        let resumed=GrowthMemorySync(store:emptyStore,days:digester,root:crashRoot,send:daySender)
        let daySent4=try await resumed.sync(to:url,token:"fixture-token"); precondition(daySent4 == 1)
        precondition((offered.last?["revision"] as? Int) == 1 && (offered.last?["text"] as? String)?.contains("次日整理") == true,"a crash resends the same version with the same bytes")

        let large=LocalMemoryStore(root:root.appendingPathComponent("LargeSources"))
        for index in 0..<50 { _ = try large.upsert(String(repeating:"中",count:8192),app:"fixture.\(index)",id:nil,now:now) }
        var byteCalls=0
        let sized=GrowthMemorySync(store:large,root:root.appendingPathComponent("LargeSync"),send:{ _,_,data in
            byteCalls += 1; precondition(data.count<=950_000,"UTF8 wire bytes respect server limit")
            let object=try JSONSerialization.jsonObject(with:data) as! [String:Any],rows=object["records"] as! [[String:Any]]
            return try JSONSerialization.data(withJSONObject:["schema":"growth.input-memory.receipt/1","accepted":rows.map { ["id":$0["id"]!,"revision":$0["revision"]!] },"stale":[],"conflicts":[]])
        })
        let uploaded=try await sized.sync(to:url,token:"fixture-token"); precondition(uploaded == 50 && byteCalls == 2)

        try await MemoryActivityChecks.basics()
        print("PASS: Growth source revisions, persistent receipts, offline pending, concurrent edits, tombstones, origin-bound tokens; day digests publish as versioned library replicas (same render, tombstones, crash-safe ledger); dynamic 15/30/60-minute deadlines, restart/idle wake; incremental batches and deletion races")
    }
}

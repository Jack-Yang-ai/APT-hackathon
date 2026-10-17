import Foundation
@main struct MemoryTests {
    static func main() async throws {
        try await verifySharedAgent()
        try await verifySharedModels()
        try await verifySharedTimeScope()
        try await verifyRecordingReadPaths()
        let savedVectors=MemoryVectors.defaults, suite="echo.memory-test-vectors."+UUID().uuidString
        MemoryVectors.defaults=UserDefaults(suiteName:suite)!; MemoryVectors.defaults.set(false,forKey:"memoryVectorsEnabled")
        defer { MemoryVectors.defaults=savedVectors; UserDefaults.standard.removePersistentDomain(forName:suite) }
        let malformed = #"{"replies":["保留原文中的 ]] 和 \"引号\"。"]],"source_ids":["planning"]}"#
        let repaired=try SmartMemory.decode(malformed,as:MemoryAnswer.self)
        precondition(repaired.replies == ["保留原文中的 ]] 和 \"引号\"。"] && repaired.source_ids == ["planning"])
        do { _ = try SmartMemory.decode(#"{"replies":["正文"},"source_ids":["planning"]}"#,as:MemoryAnswer.self); fatalError("must reject malformed structure") }
        catch is MemoryFailure { print("PASS: redundant bracket repair preserves text and rejects other invalid structure") }


        let head=#"{"source_ids":["echo_source_1"],"needs_clarification":false,"clarification":"","replies":["#
        let livebad:[(String,String,[String])]=[
            (head+#""张伟演示了"示例记录"个人赛项目。"]}"#,#"张伟演示了"示例记录"个人赛项目。"#,["echo_source_1"]),
            (head+#""他说"好"，然后开始 PRB。"]}"#,#"他说"好"，然后开始 PRB。"#,["echo_source_1"]),
            (head+#""并确认了昨天练了什么、开始 PRB。"}"#,"并确认了昨天练了什么、开始 PRB。",["echo_source_1"]),
            (#"{"replies":["正文"]","source_ids":["a"]}"#,"正文",["a"]),
            (#"{"replies":["正文"]， "source_ids":["a"]}"#,"正文",["a"]),
            (#"{"replies":["正文"]，,"source_ids":["a"]}"#,"正文",["a"]),
            (#"{"replies":["正文"]},"source_ids":["a"]}"#,"正文",["a"]),
            (#"{"replies":["正文"],"source_ids":["a"]}}"#,"正文",["a"]),
            ("```json\n"+#"{"replies":["第一行"#+"\n"+#"第二行"],"source_ids":["a"]}"#+"\n```","第一行\n第二行",["a"]),
        ]
        for (raw,text,ids) in livebad {
            let got=try SmartMemory.decode(raw,as:MemoryAnswer.self)
            precondition(got.replies == [text] && got.source_ids == ids,"repair changed \(raw) into \(got)")
        }
        for raw in [#"{"replies":["正文"] "source_ids":["a"]}"#, #"{"x":{"y":1},"replies":["今天"#, #"{"x":{"y":1},"replies":["今天"]"#, #"{"replies":["正文"],"source_ids":["a"}]}"#] {
            do { _ = try SmartMemory.decode(raw,as:MemoryAnswer.self); fatalError("must reject \(raw)") } catch is MemoryFailure {}
        }
        print("PASS: live malformed JSON shapes repair to the exact text; missing commas, truncation and crossed closers still fail")
        let fixed=ISO8601DateFormatter().date(from:"2026-10-01T04:00:00Z")!
        precondition(SmartMemory.localPlan("昨天会议",today:fixed)?.from == "2026-09-30")
        precondition(SmartMemory.localPlan("昨天到今天的会议",today:fixed) == nil)
        precondition(SmartMemory.localPlan("2026-09-01 至 2026-09-23",today:fixed) == nil)
        precondition(SmartMemory.localPlan("2026-02-30 会议",today:fixed) == nil)
        precondition(SmartMemory.localPlan("今天之前的会议",today:fixed) == nil)
        print("PASS: fast date parsing handles month boundary and defers ambiguous ranges")
        var actions:[String]=[], prompts:[String]=[], calls=0, forced=false
        let metadata=[MemoryMetadata(event_id:"planning",date:"2026-10-08",title:"发布计划",summary:"上线日期未定"),MemoryMetadata(event_id:"other",date:"2026-10-08",title:"其他项目",summary:"其他讨论")]
        let source=MemorySource(event_id:"planning",date:"2026-10-08",title:"发布计划",body:"发布日期尚未确定，没有对外承诺。")
        let otherSource=MemorySource(event_id:"other",date:"2026-10-08",title:"其他项目",body:"其他讨论，与发布无关。")
        let engine=SmartMemory(chat:{ _,prompt in
            calls += 1; prompts.append(prompt)
            return #"{"replies":["人物甲，发布日期还没确定，也没有对外承诺上线时间。"],"source_ids":["planning"]}"#
        },bridge:{ req in
            let action=req["action"] as! String; actions.append(action)
            if action == "retrieve" { return RetrievalResult(events:metadata,omitted:0) }
            precondition(Set(req["ids"] as! [String]) == ["planning","other"] && req["full_pool"] as? Bool == true)
            forced = forced || req["refresh"] as? Bool == true
            return RetrievalResult(sources:[source,otherSource])
        })
        let query="告诉人物甲昨天发布会议的结论"
        let result=try await engine.answer(query)
        precondition(calls == 1 && actions == ["retrieve","details"] && result.sources.map(\.event_id) == ["planning"])
        precondition(prompts.last!.contains(source.body) && prompts.last!.contains(otherSource.body) && result.replies[0].contains("还没确定"))
        precondition(!prompts.last!.contains("\"event_id\":\"planning\""))
        precondition(SmartMemory.cleanReply("产品讨论（PRIVATE_ID）：进展未定，日期2026-10-08。",sourceIDs:["PRIVATE_ID"]) == "产品讨论进展未定，日期2026-10-08。")
        print("PASS: short range uses one model call with complete evidence; only cited sources are returned")
        _ = try await engine.answer(query)
        precondition(calls == 1 && actions.count == 2)
        _ = try await engine.answer(query,forceRefresh:true)
        precondition(calls == 2 && actions.count == 4 && forced)
        print("PASS: repeat query avoids all I/O; explicit refresh rereads evidence")
        for mode in ["invalid-selection","invalid-evidence","missing-detail"] {
            var detailCalled=false, answerCalled=false
            let bad=SmartMemory(chat:{ system,_ in
                if system.contains("解析个人记忆") { return #"{"from":"2026-10-06","to":"2026-10-08","keywords":["火星"]}"# }
                if system.contains("从记录目录") { return mode == "invalid-selection" ? #"{"ids":["invented"]}"# : #"{"ids":["planning"]}"# }
                answerCalled=true
                return #"{"replies":["invented answer"],"source_ids":["invented"]}"#
            },bridge:{ req in
                if req["action"] as! String == "retrieve" { return RetrievalResult(events:metadata) }
                detailCalled=true; return RetrievalResult(sources:mode == "missing-detail" ? [] : [source,otherSource])
            })
            do { _ = try await bad.answer("2026-10-06 至 2026-10-08 火星项目的会议结论"); fatalError("must reject \(mode)") }
            catch is MemoryFailure { precondition(detailCalled); if mode != "invalid-evidence" { precondition(!answerCalled) }; print("PASS: rejects \(mode)") }
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoLocalRetrieval-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let local=LocalMemoryStore(root:root)
        let localID=try local.upsert("测试人物澄澄：订餐不要香菜。",app:"fixture.editor",id:nil)
        var localCalls=0, localPrompts:[String]=[]
        let integrated=SmartMemory(chat:{ system,prompt in
            localCalls += 1; localPrompts.append(prompt)
            if system.contains("解析个人记忆") { let d=LocalMemoryStore.day(Date()); return "{\"from\":\"\(d)\",\"to\":\"\(d)\",\"keywords\":[\"澄澄\"]}" }
            if system.contains("从记录目录") { return "{\"ids\":[\"\(localID)\"]}" }
            precondition(system.contains("不能声称已经发送")); return #"{"replies":["输入草稿里写过澄澄订餐不要香菜。"],"source_ids":["echo_source_1"]}"#
        },bridge:{ _ in throw MemoryFailure.message("fixture WithEcho unavailable") },local:local)
        let remembered=try await integrated.answer("澄澄订餐需要注意什么")
        precondition(remembered.sources.map(\.event_id) == [localID] && localCalls>0 && localPrompts.last!.contains("输入的草稿") && !localPrompts.last!.contains(localID))
        _ = try await integrated.answer("澄澄订餐需要注意什么"); let cachedCalls=localCalls
        try local.setDeleted(localID,true)
        do { _ = try await integrated.answer("澄澄订餐需要注意什么"); fatalError("deleted local evidence must invalidate answer cache") }
        catch is MemoryFailure { precondition(localCalls>cachedCalls) }
        print("PASS: local input memory participates in sourced replies; works when WithEcho is unavailable; deletion invalidates reply cache")


        func at(_ iso:String)->Date { ISO8601DateFormatter().date(from:iso)! }
        let monday=at("2026-10-12T02:00:00Z"), sunday=at("2026-10-18T02:00:00Z")  // 10:00 in Shanghai
        func range(_ query:String,_ today:Date)->String { SmartMemory.dateRange(query,today:today).map { "\($0.from)~\($0.to)" } ?? "nil" }
        let expected:[(String,Date,String)]=[
            ("上周六私教课教了哪些动作",monday,"2026-10-10~2026-10-10"),("上周五人物甲讲的PRD",monday,"2026-10-09~2026-10-09"),
            ("上周的会议",monday,"2026-10-05~2026-10-11"),("上个星期的会",monday,"2026-10-05~2026-10-11"),("上上周",monday,"2026-09-28~2026-10-04"),
            ("这周做了什么",monday,"2026-10-12~2026-10-12"),("这周做了什么",sunday,"2026-10-12~2026-10-18"),("上周",sunday,"2026-10-05~2026-10-11"),
            ("本周日",sunday,"2026-10-18~2026-10-18"),("上礼拜天",monday,"2026-10-11~2026-10-11"),
            ("上个月跟供应商签合同",monday,"2026-09-01~2026-09-30"),("本月",monday,"2026-10-01~2026-10-12"),
            ("上个月",at("2026-03-31T02:00:00Z"),"2026-02-01~2026-02-28"),("上月",at("2026-01-15T02:00:00Z"),"2025-12-01~2025-12-31"),
            ("10月9日的评审",monday,"2026-10-09~2026-10-09"),("上周三到上周五",monday,"2026-10-07~2026-10-09"),("昨天和上周五",monday,"2026-10-09~2026-10-11"),
            ("明天开会要准备什么",monday,"nil"),("下周三的安排",monday,"nil"),("上周末去哪了",monday,"nil"),("黑客松方向最后定了吗",monday,"nil"),
            ("上周期的数据",monday,"nil"),("这周年庆",monday,"nil"),("上月底",monday,"nil"),("2026-08-01到今天",monday,"nil"),("目前天气",monday,"nil"),
        ]
        let wrong=expected.filter { range($0.0,$0.1) != $0.2 }.map { "\($0.0): \(range($0.0,$0.1)) ≠ \($0.2)" }
        precondition(wrong.isEmpty,"date ranges: \(wrong)")
        precondition(SmartMemory.weekday(monday) == "星期一" && SmartMemory.weekday(sunday) == "星期日")

        var planned=""
        let dated=SmartMemory(chat:{ system,prompt in
            if system.contains("解析个人记忆") { planned=system; return #"{"from":"2026-10-03","to":"2026-10-03","keywords":["私教课"]}"# }
            if system.contains("从记录目录") { return #"{"ids":[]}"# }
            return #"{"replies":["无"],"source_ids":[]}"#
        },bridge:{ _ in RetrievalResult(events:[MemoryMetadata(event_id:"e1",date:"2026-10-10",title:"私教课",summary:"训练")]) },local:LocalMemoryStore(root:root.appendingPathComponent("Dated")))
        let datedTrace=MemoryTrace(surface:"inline",trigger:"explicit")
        _ = try? await dated.answer("上周六私教课教了哪些动作",trace:datedTrace)
        let want=SmartMemory.dateRange("上周六私教课教了哪些动作")!, plan=datedTrace.run.plan
        precondition(plan?.from == want.from && plan?.to == want.to && plan?.keywords == ["私教课"] && plan?.dates == "code" && plan?.by == "model","plan \(String(describing:plan))")
        precondition(planned.contains(SmartMemory.weekday(Date())),"the model is told the weekday")
        let undated=MemoryTrace(surface:"inline",trigger:"explicit")
        _ = try? await dated.answer("私教课教了哪些动作",trace:undated)
        precondition(undated.run.plan?.from == "2026-10-03" && undated.run.plan?.dates == "model","without a date in the question the model's range stands")
        print("PASS: dates named in a question are worked out by code (days, weeks, months, spans; future and over-31-day ranges left to the model); the model keeps the keywords")
        try await retrievalCoverage(root)
        try await vectorIntegration(root)
        try await largePoolRetrieval(root)
    }

    static func largePoolRetrieval(_ root:URL) async throws {
        let pool=(0..<193).map { MemorySource(event_id:"large_pool_\($0)",date:"2026-10-10",title:"草稿 \($0)",body:$0==192 ? "共用 Agent 接线要保留 App 前文和引用依据。" : "无关草稿 \($0)") }
        var reads:[Int]=[], answered=false
        func engine(_ missing:Bool=false)->SmartMemory {
            SmartMemory(chat:{ system,prompt in
                if system.contains("解析个人记忆") { return #"{"from":"2026-10-08","to":"2026-10-14","keywords":["共用 Agent"]}"# }
                answered=true
                precondition(prompt.contains(pool[192].body) && !prompt.contains(pool[0].body) && prompt.contains("并非日期范围的全部正文"))
                return #"{"replies":["接线保留 App 前文和引用依据。"],"source_ids":["large_pool_192"]}"#
            },bridge:{ request in
                switch request["action"] as? String {
                case "retrieve": return RetrievalResult(events:pool.map { .init(event_id:$0.event_id,date:$0.date,title:$0.title,summary:nil) })
                case "details":
                    let ids=request["ids"] as! [String]; reads.append(ids.count); precondition(ids.count<=120)
                    return RetrievalResult(sources:pool.filter { ids.contains($0.event_id) && !(missing && $0.event_id==pool[192].event_id) })
                case "hybrid":
                    precondition((request["sources"] as? [[String:Any]])?.count==193 && request["use_vectors"] as? Bool==false)
                    return RetrievalResult(ids:[pool[192].event_id],index:MemoryIndexState(state:"lexical_fallback",model:MemoryVectors.model,chunks:193,keyword_hits:1,vector_hits:0,error:"disabled"))
                default: fatalError("unexpected action")
                }
            },vectors:false)
        }
        let trace=MemoryTrace(surface:"inline",trigger:"explicit")
        let reply=try await engine().answer("共用 Agent 接线的目标是什么",trace:trace)
        precondition(reads==[120,73] && answered && reply.dependencies.map(\.event_id)==[pool[192].event_id] && trace.run.select?.by=="keyword_scene")
        answered=false; reads=[]
        do { _ = try await engine(true).answer("共用 Agent 接线的目标是什么"); fatalError("missing final batch must fail") }
        catch is MemoryFailure { precondition(!answered) }
        for query in ["这周开了几场会议","这个月健身多少天","最近认识了多少人","全部共用 Agent 草稿","How many meetings"] {
            precondition(SmartMemory.needsFullCoverage(query))
            answered=false; reads=[]
            do { _ = try await engine().answer(query); fatalError("complete statistics cannot use top-k") }
            catch is MemoryFailure { precondition(!answered && reads.isEmpty) }
        }
        print("PASS: undated 193-source queries retrieve relevant tail evidence in bounded batches; missing details and exhaustive counts fail closed")
    }

    static func retrievalCoverage(_ root:URL) async throws {
        let main=MemorySource(event_id:"main",date:"2026-10-12",title:"旁听私教练臀",body:"03:56–04:46：训练主体是屈髋、骨盆位置、动态伸展和硬拉。")
        let tail=MemorySource(event_id:"tail",date:"2026-10-12",title:"健身房私教训练",body:"04:46–05:06：调配重，之后闲聊门店。")
        let unrelated=MemorySource(event_id:"unrelated",date:"2026-10-12",title:"工作对齐",body:"调整商品页的文案。")
        let pool=[main,tail,unrelated]
        func metadata(_ sources:[MemorySource])->[MemoryMetadata] { sources.map { .init(event_id:$0.event_id,date:$0.date,title:$0.title,summary:"目录里没有动作细节") } }
        var calls=0, sawComplete=false
        let training=SmartMemory(chat:{ system,prompt in
            calls += 1
            precondition(!system.contains("从记录目录"),"small day must not select by titles")
            sawComplete=pool.allSatisfy { prompt.contains($0.body) }
            return #"{"replies":["今天练了屈髋、骨盆位置、动态伸展和硬拉，最后调整了配重。"],"source_ids":["main","tail"]}"#
        },bridge:{ request in
            request["action"] as? String == "retrieve" ? RetrievalResult(events:metadata(pool)) : RetrievalResult(sources:pool)
        })
        let trace=MemoryTrace(surface:"inline",trigger:"explicit")
        let reply=try await training.answer("今天健身的内容",trace:trace)
        precondition(calls==1 && sawComplete && Set(reply.sources.map(\.event_id)) == ["main","tail"] && trace.run.select?.by == "full_range" && trace.run.select?.batches == 0)
        print("PASS: 今天健身 includes both training segments despite different titles, with one answer call")

        let many=(0..<14).map { MemorySource(event_id:"e\($0)",date:$0<7 ? "2026-10-10" : "2026-10-11",title:"片段 \($0)",body:"正文 \($0)：\($0==13 ? "训练动作在最后一段" : "日常内容")") }
        var manyCalls=0, allRead=false
        let twoDays=SmartMemory(chat:{ system,prompt in
            manyCalls += 1
            if system.contains("解析个人记忆") { return #"{"from":"2026-10-10","to":"2026-10-11","keywords":["训练"]}"# }
            precondition(!system.contains("从记录目录")); allRead=many.allSatisfy { prompt.contains($0.body) }
            return #"{"replies":["训练动作在最后一段。"],"source_ids":["e13"]}"#
        },bridge:{ request in
            if request["action"] as? String == "retrieve" { return RetrievalResult(events:metadata(many)) }
            precondition((request["ids"] as! [String]).count == 14 && request["full_pool"] as? Bool == true)
            return RetrievalResult(sources:many)
        })
        _ = try await twoDays.answer("2026-10-10 至 2026-10-11 的训练")
        precondition(manyCalls==2 && allRead)
        print("PASS: two-day context reads more than six records without dropping the last segment")


        let large=(0..<14).map { MemorySource(event_id:"large\($0)",date:"2026-10-05",title:"健身",body:String(repeating:"普通背景",count:1500)+($0==13 ? "文末证据：私教教了罗马尼亚硬拉。" : "只是闲聊。")) }
        var selectedBatches=0, answered=false
        let semantic=SmartMemory(chat:{ system,prompt in
            if system.contains("解析个人记忆") { return #"{"from":"2026-10-01","to":"2026-10-07","keywords":["健身"]}"# }
            if system.contains("从记录目录") {
                selectedBatches += 1
                let json=prompt.components(separatedBy:"记录目录及正文：").last!
                let group=try JSONDecoder().decode([MemorySource].self,from:Data(json.utf8))
                return try SmartMemory.encoded(["ids":group.filter { $0.body.contains("文末证据") }.map(\.event_id)])
            }
            answered=prompt.contains("文末证据：私教教了罗马尼亚硬拉。") && !prompt.contains("只是闲聊。")
            return #"{"replies":["私教教了罗马尼亚硬拉。"],"source_ids":["echo_source_1"]}"#
        },bridge:{ request in
            request["action"] as? String == "retrieve" ? RetrievalResult(events:metadata(large)) : RetrievalResult(sources:large)
        })
        let semanticTrace=MemoryTrace(surface:"inline",trigger:"explicit")
        let found=try await semantic.answer("2026-10-01 至 2026-10-07 健身练了什么",trace:semanticTrace)
        precondition(selectedBatches>1 && answered && found.sources.map(\.event_id)==["large13"] && semanticTrace.run.select?.by=="semantic_scene" && semanticTrace.run.select?.batches==selectedBatches)
        print("PASS: long-range semantic selection reads complete bodies in bounded batches and retains evidence at the end")

        for mode in ["missing","unknown","duplicate","omitted","oversized","invalid-selection","cancelled"] {
            var generated=false
            let failure=SmartMemory(chat:{ system,_ in
                if system.contains("解析个人记忆") { return #"{"from":"2026-10-01","to":"2026-10-07","keywords":[]}"# }
                if system.contains("从记录目录") {
                    if mode=="cancelled" { throw CancellationError() }
                    return #"{"ids":["invented"]}"#
                }
                generated=true; return #"{"replies":["不能生成"],"source_ids":["main"]}"#
            },bridge:{ request in
                if request["action"] as? String == "retrieve" { return RetrievalResult(events:metadata(pool),omitted:mode=="omitted" ? 1 : 0) }
                switch mode {
                case "missing": return RetrievalResult(sources:[main,tail])
                case "unknown": return RetrievalResult(sources:[main,tail,MemorySource(event_id:"invented",date:main.date,title:"伪造",body:"伪造")])
                case "duplicate": return RetrievalResult(sources:[main,main,tail])
                case "oversized": return RetrievalResult(sources:[main,tail,MemorySource(event_id:unrelated.event_id,date:unrelated.date,title:unrelated.title,body:String(repeating:"长",count:60001))])
                default: return RetrievalResult(sources:pool)
                }
            })
            do { _ = try await failure.answer("2026-10-01 至 2026-10-07 训练内容"); fatalError("must reject \(mode)") }
            catch { precondition(error is MemoryFailure || (mode=="cancelled" && error is CancellationError)); precondition(!generated) }
        }
        print("PASS: incomplete, foreign, duplicate, omitted and oversized evidence, invalid selection and cancellation cannot produce an answer")

        let local=LocalMemoryStore(root:root.appendingPathComponent("FullDay"))
        let now=ISO8601DateFormatter().date(from:"2026-10-09T03:00:00Z")!
        let ownID=try local.upsert("私教教了髋部折叠和罗马尼亚硬拉。",app:"fixture.editor",id:nil,now:now)
        _ = try local.upsert("健身相关但属于前一天。",app:"fixture.editor",id:nil,now:now.addingTimeInterval(-86400))
        var ownPrompt=""
        let own=SmartMemory(chat:{ system,prompt in
            if system.contains("解析个人记忆") { return #"{"from":"2026-10-09","to":"2026-10-09","keywords":["运动"]}"# }
            ownPrompt=prompt; return try SmartMemory.encoded(["replies":["草稿里记了髋部折叠和罗马尼亚硬拉。"],"source_ids":[ownID]])
        },bridge:{ _ in throw MemoryFailure.message("offline") },local:local)
        let draft=try await own.answer("10月9日运动的内容")
        precondition(draft.sources.map(\.event_id)==[ownID] && ownPrompt.contains("罗马尼亚硬拉") && !ownPrompt.contains("属于前一天"))
        print("PASS: full-day local recall finds different wording, respects month-day dates and works offline")



        let sceneMeta=[
            MemoryMetadata(event_id:"main",date:"2026-10-12",title:main.title,summary:nil,start_time:"2026-10-12T03:56:00Z",end_time:"2026-10-12T04:46:00Z"),
            MemoryMetadata(event_id:"tail",date:"2026-10-12",title:tail.title,summary:nil,start_time:"2026-10-12T04:46:00Z",end_time:"2026-10-12T05:06:00Z"),
            MemoryMetadata(event_id:"unrelated",date:"2026-10-12",title:unrelated.title,summary:nil,start_time:"2026-10-12T06:00:00Z",end_time:"2026-10-12T06:30:00Z")]
        let scene=SmartMemory(chat:{ system,prompt in
            if system.contains("解析个人记忆") { return #"{"from":"2026-10-10","to":"2026-10-12","keywords":["健身"]}"# }
            if system.contains("从记录目录") { return #"{"ids":["tail"]}"# }
            precondition(prompt.contains(main.body) && prompt.contains(tail.body) && !prompt.contains(unrelated.body))
            return #"{"replies":["这次练了硬拉，最后调了配重。"],"source_ids":["main","tail"]}"#
        },bridge:{ request in request["action"] as? String == "retrieve" ? RetrievalResult(events:sceneMeta) : RetrievalResult(sources:pool) })
        let sceneReply=try await scene.answer("2026-10-10 至 2026-10-12 健身内容")
        precondition(Set(sceneReply.sources.map(\.event_id)) == ["main","tail"])
        var otherDay=sceneMeta[1]; otherDay=MemoryMetadata(event_id:"other-day",date:"2026-10-11",title:"前一天",summary:nil,start_time:otherDay.start_time,end_time:otherDay.end_time)
        let untimed=MemoryMetadata(event_id:"untimed",date:"2026-10-12",title:"无时间",summary:nil)
        let long=MemoryMetadata(event_id:"long",date:"2026-10-12",title:"连续链超过两小时",summary:nil,start_time:"2026-10-12T05:06:00Z",end_time:"2026-10-12T07:06:00Z")
        let context=SmartMemory.contextIDs(["main"],candidates:sceneMeta+[otherDay,untimed,long])
        precondition(context == ["main","tail"])
        print("PASS: semantic hits expand to continuous event context; unrelated days, gaps, missing times and long chains stay out")
    }

    static func vectorIntegration(_ root:URL) async throws {
        let pool=[MemorySource(event_id:"main",date:"2026-10-12",title:"旁听私教练臀",body:"私教教了髋铰链和硬拉。"),
                  MemorySource(event_id:"tail",date:"2026-10-12",title:"健身房闲聊",body:"最后调整了器械配重。"),
                  MemorySource(event_id:"other",date:"2026-10-12",title:"其他事项",body:"写商品页文案。")]
        let metadata=[MemoryMetadata(event_id:"main",date:"2026-10-12",title:pool[0].title,summary:nil,start_time:"2026-10-12T03:56:00Z",end_time:"2026-10-12T04:46:00Z"),
                      MemoryMetadata(event_id:"tail",date:"2026-10-12",title:pool[1].title,summary:nil,start_time:"2026-10-12T04:46:00Z",end_time:"2026-10-12T05:06:00Z"),
                      MemoryMetadata(event_id:"other",date:"2026-10-12",title:pool[2].title,summary:nil,start_time:"2026-10-12T06:00:00Z",end_time:"2026-10-12T06:30:00Z")]
        var hybridCalls=0, answerCalls=0
        let engine=SmartMemory(chat:{ system,prompt in
            precondition(!system.contains("从记录目录") && !system.contains("解析个人记忆"),"known dates and vector coordinates do not call the chat model")
            answerCalls += 1
            precondition(prompt.contains(pool[0].body) && prompt.contains(pool[1].body) && !prompt.contains(pool[2].body))
            return #"{"replies":["练了髋铰链和硬拉，最后调了配重。"],"source_ids":["main","tail"]}"#
        },bridge:{ request in
            switch request["action"] as? String {
            case "retrieve": return RetrievalResult(events:metadata)
            case "details": return RetrievalResult(sources:pool)
            case "hybrid":
                hybridCalls += 1
                precondition((request["sources"] as? [[String:Any]])?.count==3 && request["model"] as? String == MemoryVectors.model)
                return RetrievalResult(ids:["tail"],index:MemoryIndexState(state:"hybrid",model:MemoryVectors.model,chunks:3,dim:1024,new_chunks:3,cached_chunks:0,query_cached:false,vector_hits:3))
            default: fatalError("unexpected bridge action")
            }
        },vectors:true)
        let query="2026-10-10 至 2026-10-12 私教课练了什么", trace=MemoryTrace(surface:"inline",trigger:"explicit")
        let reply=try await engine.answer(query,trace:trace)
        precondition(hybridCalls==1 && answerCalls==1 && trace.run.plan?.by=="rule" && trace.run.select?.by=="hybrid_scene" && trace.run.select?.batches==0 && trace.run.select?.vector?.dim==1024 && Set(reply.sources.map(\.event_id))==["main","tail"])
        _ = try await engine.answer(query); precondition(hybridCalls==1 && answerCalls==1)
        MemoryVectors.changed()
        _ = try await engine.answer(query); precondition(hybridCalls==2 && answerCalls==2)
        print("PASS: vector coordinates replace chat selection, known dates skip chat planning, continuous evidence is read and logged; clearing the index invalidates answer cache")

        for mode in ["foreign-id","wrong-model","missing-stats","no-hits","lexical"] {
            var generated=false
            let bad=SmartMemory(chat:{ _,prompt in generated=true; return #"{"replies":["有训练记录。"],"source_ids":["main"]}"# },bridge:{ request in
                if request["action"] as? String == "retrieve" { return RetrievalResult(events:metadata) }
                if request["action"] as? String == "details" { return RetrievalResult(sources:pool) }
                let info=MemoryIndexState(state:mode=="lexical" ? "lexical_fallback" : "hybrid",model:mode=="wrong-model" ? "foreign-model" : MemoryVectors.model,chunks:3,dim:1024,vector_hits:3,error:mode=="lexical" ? "service_unavailable" : nil)
                return RetrievalResult(ids:mode=="foreign-id" ? ["invented"] : mode=="no-hits" ? [] : ["main"],index:mode=="missing-stats" ? nil : info)
            },vectors:true)
            let run=MemoryTrace(surface:"inline",trigger:"explicit")
            do {
                _ = try await bad.answer(query,trace:run)
                precondition(mode=="lexical" && generated && run.run.select?.by=="keyword_scene" && run.run.select?.vector?.error=="service_unavailable")
            } catch is MemoryFailure { precondition(mode != "lexical" && !generated) }
        }
        print("PASS: vector IDs and model identity are closed; malformed responses and empty recall stop; service degradation is explicit in the record")

        var counted=false
        let all=SmartMemory(chat:{ _,prompt in counted=pool.allSatisfy { prompt.contains($0.body) }; return #"{"replies":["范围内有训练记录。"],"source_ids":["main"]}"# },bridge:{ request in
            precondition(request["action"] as? String != "hybrid","count/all queries must not count a top-k subset")
            return request["action"] as? String == "retrieve" ? RetrievalResult(events:metadata) : RetrievalResult(sources:pool)
        },vectors:true)
        let countTrace=MemoryTrace(surface:"inline",trigger:"explicit")
        _ = try await all.answer("2026-10-10 至 2026-10-12 一共训练了几次",trace:countTrace)
        precondition(counted && countTrace.run.select?.by=="full_range")
        print("PASS: explicit counts and full-range requests use complete evidence, never a top-k subset")
    }
    static func verifySharedAgent() async throws {
        precondition(MemoryAgentClient.responseFailure(Data(#"{"error":"model_key_authorization"}"#.utf8)) is MemoryKeyAuthorization)
        try await verifyCredentialOrigin()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("apt-shared-agent-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root); MemoryAgentClient.exchange=nil }
        let store=LocalMemoryStore(root:root.appendingPathComponent("Inputs")),day=LocalMemoryStore.day(Date())
        _ = try store.upsert("我今天整理输入法方案，但还没有发送。",app:"fixture.chat",id:nil)
        let remote=MemorySource(event_id:"withecho_fixture",date:day,title:"日常记录",body:"WithEcho 记录：讨论了项目，发布时间未定。")
        let phone=MemorySource(event_id:"phone_recording_"+UUID().uuidString.lowercased(),date:day,title:"手机只读原话",body:"来源：手机提供的只读录音材料；版本1。\n原话：今天只讨论方案，没有决定预算。")
        var sawContext=false,sawStyle=false,sawSources=false
        let engine=SmartMemory(chat:{ system,prompt in
            sawContext=prompt.contains("fixture.mail") && prompt.contains("发给设计同学")
            sawStyle=system.contains("保留我的简短语气")
            sawSources=prompt.contains("没有发送") && prompt.contains(remote.body) && prompt.contains("今天只讨论方案，没有决定预算。")
            return #"{"replies":["今天讨论了方案，发布时间和预算都还没定。"],"source_ids":["echo_source_1","echo_source_2","echo_source_3"]}"#
        },bridge:{ input in input["action"] as? String == "retrieve" ? RetrievalResult(events:[.init(event_id:remote.event_id,date:day,title:remote.title,summary:nil)]) : RetrievalResult(sources:[remote]) },
        local:store,style:{ "保留我的简短语气" },vectors:false)
        let trace=MemoryTrace(surface:"inline",trigger:"explicit")
        MemoryAgentClient.exchange={ request in
            var request=request; request.materials=[phone]
            return try await MemoryAgentHost.answer(request,engine:engine)
        }
        let answer=try await MemoryAgentClient.answer("今天的全部记录",mode:.reply,context:.init(app:"fixture.mail",before:"发给设计同学"),forceRefresh:false,deepReview:false,trace:trace)
        precondition(sawContext && sawStyle && sawSources && answer.sources.count==3 && answer.dependencies.count==3)
        precondition(trace.run.surface=="inline" && trace.run.select?.by=="full_range" && trace.run.run_id==trace.id)
        let bad=MemoryAgentRequest(query:"今天的全部记录",mode:"reply",context:nil,scope:"recording",materials:[phone])
        let pinnedEngine=SmartMemory(chat:{ _,prompt in
            precondition(prompt.contains("今天只讨论方案，没有决定预算。") && !prompt.contains(remote.body) && !prompt.contains("没有发送"))
            return #"{"replies":["只讨论了方案，预算未决定。"],"source_ids":["echo_source_1"]}"#
        },bridge:{ _ in preconditionFailure("pinned phone material must not fetch the global pool") },local:store,vectors:false)
        let pinned=try await MemoryAgentHost.answer(bad,engine:pinnedEngine)
        precondition(pinned.sources.map(\.event_id)==[phone.event_id])
        var invalid=bad;invalid.materials=[remote]
        do { _ = try await MemoryAgentHost.answer(invalid,engine:pinnedEngine); preconditionFailure("foreign IDs accepted") } catch is MemoryFailure {}
        var detailReads=0
        let producer=LocalMemoryStore(root:store.root),identity=store.all()[0].id
        let racing=SmartMemory(chat:{ _,_ in
            #"{"replies":["旧版结论。"],"source_ids":["echo_source_1"]}"#
        },bridge:{ input in
            if input["action"] as? String == "retrieve" { return RetrievalResult(events:[.init(event_id:remote.event_id,date:day,title:remote.title,summary:nil)]) }
            detailReads += 1
            if detailReads==2 { _ = try producer.upsert("我今天更新了方案，旧版结论不再适用。",app:"fixture.chat",id:identity) }
            return RetrievalResult(sources:[remote])
        },local:store,vectors:false)
        do { _ = try await MemoryAgentHost.answer(.init(query:"今天的全部记录",mode:"reply",force_refresh:true),engine:racing);preconditionFailure("host returned a stale producer snapshot") }
        catch is MemoryFailure { precondition(detailReads==2) }
        print("PASS: shared Agent preserves app context, Style, date/full coverage, local and WithEcho evidence; phone recording scope excludes global input; producer changes during remote postcheck invalidate every supplied dependency")
        let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=["-c","sleep 60 & wait"]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try MemoryAgentHost.runBridge(process)
        try await Task.sleep(nanoseconds:100_000_000)
        MemoryAgentHost.cancelBridges();process.waitUntilExit();MemoryAgentHost.finishedBridge(process)
        precondition(!process.isRunning)
        print("PASS: native cancellation terminates the actual Foundation bridge process group")
    }

    static func verifySharedModels() async throws {
        let original=ModelConfig.defaults,read=SmartMemory.readKey,exchange=AgentModels.exchange
        let suite="apt.models-check."+UUID().uuidString
        ModelConfig.defaults=UserDefaults(suiteName:suite)!
        ModelConfig.defaults.set("https://approved.example",forKey:"endpoint");ModelConfig.defaults.set("fixture",forKey:"modelName")
        ModelConfig.defaults.set("https://approved.example/background",forKey:"backgroundEndpoint");ModelConfig.defaults.set("fixture-bg",forKey:"backgroundModel")
        SmartMemory.readKey={ "fixture-key" }
        defer { ModelConfig.defaults=original;SmartMemory.readKey=read;AgentModels.exchange=exchange;UserDefaults.standard.removePersistentDomain(forName:suite) }
        var calls=0
        AgentModels.exchange={ input in
            calls += 1
            precondition(input.credential.key=="fixture-key" && input.credential.endpoint.hasPrefix("https://approved.example"))
            precondition(input.background == ["by_day","style"].contains(input.scene))
            return .init(request_id:input.request_id,text:"未确认。",calls:[.init(scene:input.scene,ms:1,input:10,cache_hit:nil,output:3,usd:nil)],host:MemoryAgentHost.version)
        }
        for scene in ["voice_polish","by_day","style"] {
            let trace=MemoryTrace(surface:"check",trigger:"explicit",recorded:false)
            let value=try await SmartMemory().chat(system:"fixture",prompt:"未确认",timeout:1,scene:scene,trace:trace,background:scene != "voice_polish")
            precondition(value=="未确认。" && trace.run.calls.count==1 && trace.run.calls[0].scene==scene)
        }
        precondition(calls==3)
        AgentModels.exchange={ input in .init(request_id:"foreign",text:"错误",host:MemoryAgentHost.version) }
        do { _ = try await SmartMemory().chat(system:"fixture",prompt:"fixture",timeout:1);preconditionFailure("foreign model result accepted") } catch is MemoryFailure {}
        var cancelled=0;let id=ModelInFlight.begin { cancelled += 1 };ModelInFlight.cancelAll();ModelInFlight.cancelAll()
        precondition(cancelled==1 && !ModelInFlight.finish(id))
        print("PASS: voice polish, daily and Style share the model gateway; request identity, trace and once-only cancellation accounting retained")
    }
    static func verifySharedTimeScope() async throws {
        let recent=MemorySource(event_id:"synced_input_aaaaaaaa-1111-2222-3333-123456789abc_00000000-1111-2222-3333-000000000001",date:"2026-10-14",title:"已同步草稿",body:"本周待确认目标。")
        let old=MemorySource(event_id:"synced_input_aaaaaaaa-1111-2222-3333-123456789abc_00000000-1111-2222-3333-000000000002",date:"2026-01-01",title:"历史草稿",body:"很久以前的不同方案。")
        for text in ["明日召开发布评审","Tomorrow we discuss the release"] {
            let record:[String:String]=["created":"2026-10-13T00:00:00.000Z","text":text]
            let body="输入草稿标记。\n"+String(decoding:try JSONSerialization.data(withJSONObject:record),as:UTF8.self)
            let mention=MemorySource(event_id:recent.event_id,date:"2026-10-13",title:"已同步草稿",body:body)
            precondition(SmartMemory.suppliedInRange(mention,query:"2026-10-14 发布评审",plan:.init(from:"2026-10-14",to:"2026-10-14",keywords:[])))
        }
        var answered=false
        let engine=SmartMemory(chat:{ system,prompt in
            if system.contains("解析个人记忆") { return #"{"from":"2026-10-12","to":"2026-10-14","keywords":["目标"]}"# }
            if system.contains("从记录目录") { precondition(!prompt.contains(old.body));return "{\"ids\":[\""+recent.event_id+"\"]}" }
            answered=true;precondition(prompt.contains(recent.body) && !prompt.contains(old.body))
            return #"{"replies":["目标仍待确认。"],"source_ids":["echo_source_1"]}"#
        },bridge:{ _ in RetrievalResult(events:[]) },vectors:false)
        var input=MemoryAgentRequest(query:"最近的目标是什么",mode:"reply");input.synced_materials=[recent,old]
        let result=try await MemoryAgentHost.answer(input,engine:engine)
        precondition(answered && result.dependencies.map(\.event_id)==[recent.event_id])
        answered=false;input.query="全部目标总数";input.synced_truncated=true
        do { _ = try await MemoryAgentHost.answer(input,engine:engine);preconditionFailure("limited shared pool counted as complete") } catch is MemoryFailure { precondition(!answered) }
        let day=MemorySource(event_id:"synced_day_aaaaaaaa-1111-2222-3333-123456789abc_2026-10-13",date:"2026-10-13",title:"已同步每日整理 · 2026-10-13",body:"当天确认发布评审。")
        let dayEngine=SmartMemory(chat:{ system,prompt in
            if system.contains("解析个人记忆") { return #"{"from":"2026-10-13","to":"2026-10-13","keywords":["发布评审"]}"# }
            if system.contains("从记录目录") { return "{\"ids\":[\""+day.event_id+"\"]}" }
            precondition(prompt.contains(day.body))
            return #"{"replies":["当天确认了发布评审。"],"source_ids":["echo_source_1"]}"#
        },bridge:{ _ in RetrievalResult(events:[]) },vectors:false)
        var dayInput=MemoryAgentRequest(query:"2026-10-13 发布评审",mode:"reply");dayInput.synced_materials=[day]
        let dayResult=try await MemoryAgentHost.answer(dayInput,engine:dayEngine)
        precondition(dayResult.dependencies.map(\.event_id)==[day.event_id] && (dayResult.native_snapshots ?? []).isEmpty && !MemoryNativeSnapshot.isNative(day.event_id))
        defer { MemoryAgentClient.exchange=nil }
        MemoryAgentClient.exchange={ request in
            var request=request;request.synced_materials=[day]
            var response=try await MemoryAgentHost.answer(request,engine:dayEngine)
            response.source_snapshots=[.init(domain:"input",device_id:"aaaaaaaa-1111-2222-3333-123456789abc",id:"echo_day_2026-10-13",revision:1,fingerprint:String(repeating:"a",count:64))]
            return response
        }
        let dayAnswer=try await MemoryAgentClient.answer("2026-10-13 发布评审",mode:.reply,context:nil,forceRefresh:true,deepReview:false,trace:nil)
        precondition(dayAnswer.dependencies.map(\.event_id)==[day.event_id] && dayAnswer.remoteValidation != nil)
        print("PASS: model-planned time scope excludes remote history; limited shared candidates cannot produce full statistics; synced day documents stay shared, not native")
    }
    static func verifyCredentialOrigin() async throws {
        let original=ModelConfig.defaults,protocols=SmartMemory.protocolClasses,log=MemoryLog.shared
        let suite="apt.credential-check."+UUID().uuidString
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        ModelConfig.defaults=UserDefaults(suiteName:suite)!
        ModelConfig.defaults.set("https://approved.example",forKey:"endpoint");ModelConfig.defaults.set("fixture",forKey:"modelName")
        SmartMemory.protocolClasses=[CredentialProtocol.self];MemoryLog.shared=MemoryLog(root:root)
        defer { ModelConfig.defaults=original;SmartMemory.protocolClasses=protocols;MemoryLog.shared=log;UserDefaults.standard.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root) }
        let engine=SmartMemory();engine.requestCredential = .init(endpoint:"https://approved.example",key:"fixture-key")
        CredentialProtocol.calls=0
        _ = try await engine.chat(system:"fixture",prompt:"fixture",timeout:1)
        precondition(CredentialProtocol.calls==1)
        ModelConfig.defaults.set("https://foreign.example",forKey:"endpoint")
        do { _ = try await engine.chat(system:"fixture",prompt:"fixture",timeout:1);preconditionFailure("old Key sent to changed model service") } catch is MemoryFailure {}
        precondition(CredentialProtocol.calls==1)
        print("PASS: every captured HTTP route checks credential origin; changing model service mid-request sends no old Key")
    }

    static func verifyRecordingReadPaths() async throws {
        let today=LocalMemoryStore.day(Date()),old=LocalMemoryStore.day(Date().addingTimeInterval(-45*86400))
        let id="synced_recording_11111111-1111-4111-8111-111111111111_22222222-2222-4222-8222-222222222222"
        let source=MemorySource(event_id:id,date:old,title:"APT 录音 · 相机检查",body:"原话：相机是否损坏还没有确认。")
        var answered=false
        let engine=SmartMemory(chat:{ system,prompt in
            if system.contains("解析个人记忆") { return "{\"from\":\"\(today)\",\"to\":\"\(today)\",\"keywords\":[]}" }
            answered=true;precondition(prompt.contains(source.body))
            return #"{"replies":["相机是否损坏还没有确认。"],"source_ids":["echo_source_1"]}"#
        },bridge:{ _ in preconditionFailure("recording-only materials never use WithEcho") },vectors:false)
        var request=MemoryAgentRequest(query:"相机检查的结论",mode:"reply",scope:"recording")
        request.recording_materials=[source]
        let result=try await MemoryAgentHost.answer(request,engine:engine)
        precondition(answered && result.dependencies.map(\.event_id)==[id],"an undated query can retrieve older synced recordings")
        answered=false;request.query=today+" 的全部录音";request.recording_truncated=true
        do { _ = try await MemoryAgentHost.answer(request,engine:engine);preconditionFailure("incomplete recording data counted as complete") }catch is MemoryFailure { precondition(!answered) }
        let range=SmartMemory.dateRange("昨天的录音")
        precondition(range?.from==LocalMemoryStore.day(Date().addingTimeInterval(-86400)) && range?.from==range?.to)
        let echo=MemorySource(event_id:"echo_final_fixture",date:today,title:"会议",body:"预算未决定。")
        var current=echo
        let verifier=SmartMemory(chat:{ _,_ in preconditionFailure("source validation cannot call a model") },bridge:{ input in
            precondition(input["action"] as? String == "details" && input["refresh"] as? Bool == true)
            return RetrievalResult(sources:[current])
        },vectors:false)
        try await verifier.validateHostSnapshots([MemoryNativeSnapshot(echo)])
        current=MemorySource(event_id:echo.event_id,date:today,title:echo.title,body:"预算已取消。")
        do { try await verifier.validateHostSnapshots([MemoryNativeSnapshot(echo)]);preconditionFailure("changed WithEcho source accepted") }catch is MemoryFailure {}

        let damagedRoot=FileManager.default.temporaryDirectory.appendingPathComponent("apt-damaged-inputs-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:damagedRoot) }
        let inputs=LocalMemoryStore(root:damagedRoot.appendingPathComponent("Inputs")),good=try inputs.upsert("预算下周再定。",app:"fixture.notes",id:nil)
        try Data("{".utf8).write(to:inputs.root.appendingPathComponent("local_input_damaged.json"))
        let input=inputs.sources([good])[0]
        try await SmartMemory(chat:nil,bridge:nil,local:inputs,vectors:false).validateHostSnapshots([MemoryNativeSnapshot(input)])
        try Data().write(to:damagedRoot.appendingPathComponent("NotAFolder"))
        do { try await SmartMemory(chat:nil,bridge:nil,local:LocalMemoryStore(root:damagedRoot.appendingPathComponent("NotAFolder")),vectors:false).validateHostSnapshots([MemoryNativeSnapshot(input)]);preconditionFailure("unreadable input folder accepted") }catch is MemoryFailure {}
        print("PASS: older synced recordings remain searchable; native dates and incomplete-statistics gates hold; final native validation re-reads source bodies without a model; a damaged input file leaves the readable ones valid, an unreadable folder does not")
    }

}

final class CredentialProtocol:URLProtocol {
    static var calls=0
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        precondition(request.url?.host == "approved.example" && request.value(forHTTPHeaderField:"Authorization") == "Bearer fixture-key")
        let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(#"{"choices":[{"message":{"content":"{}"}}]}"#.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

}

import Foundation

// The production Swift -> bundled Python -> real local Ollama path, with fictional sources and
// a mock answer. No WithEcho, cloud model or keychain; vectors and records go to scratch folders.
enum VectorChecks {
    @MainActor static func run() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoVectorCheck-"+UUID().uuidString)
        let previous=getenv("ECHO_INDEX_ROOT").map { String(cString:$0) }, realDefaults=MemoryVectors.defaults
        let settings=ScratchDefaults(suiteName:"echo.vector-live-check")!
        MemoryVectors.defaults=settings
        setenv("ECHO_INDEX_ROOT",root.path,1)
        defer {
            MemoryVectors.defaults=realDefaults
            if let previous { setenv("ECHO_INDEX_ROOT",previous,1) } else { unsetenv("ECHO_INDEX_ROOT") }
            try? FileManager.default.removeItem(at:root)
        }
        let training=MemorySource(event_id:"main",date:"2026-10-12",title:"旁听私教练臀（虚构）",body:"私教教了髋铰链、罗马尼亚硬拉和骨盆稳定。")
        let tail=MemorySource(event_id:"tail",date:"2026-10-12",title:"健身房闲聊（虚构）",body:"训练最后调整了器械配重，然后开始闲聊门店。")
        let others=(0..<14).map { MemorySource(event_id:"other\($0)",date:"2026-10-12",title:"其他片段 \($0)（虚构）",body:["修漏水的水管。","讨论订阅费和付款。","火锅聚餐。","镜头异常仍存在。","产品评审确认先做移动端。","练琴时使用节拍器。","去草原拍摄动物。"][ $0%7 ]) }
        let pool=[training,tail]+others
        var metadata=pool.map { MemoryMetadata(event_id:$0.event_id,date:$0.date,title:$0.title,summary:nil) }
        metadata[0].start_time="2026-10-12T03:56:00Z"; metadata[0].end_time="2026-10-12T04:46:00Z"
        metadata[1].start_time="2026-10-12T04:46:00Z"; metadata[1].end_time="2026-10-12T05:06:00Z"
        let gateway=SmartMemory(chat:{ _,_ in "" })
        var answers=0
        func engine()->SmartMemory {
            SmartMemory(chat:{ system,prompt in
                precondition(!system.contains("解析个人记忆") && !system.contains("从记录目录"))
                let records=try JSONDecoder().decode([MemorySource].self,from:Data(prompt.components(separatedBy:"来源资料：").last!.utf8))
                precondition(records.contains { $0.body==training.body } && records.contains { $0.body==tail.body })
                answers += 1
                return #"{"replies":["私教教了髋铰链和罗马尼亚硬拉，最后调整了配重。"],"source_ids":["main","tail"]}"#
            },bridge:{ request in
                switch request["action"] as? String {
                case "retrieve": return RetrievalResult(events:metadata)
                case "details": return RetrievalResult(sources:pool)
                case "hybrid": return try await gateway.bridge(request)
                default: throw MemoryFailure.message("unexpected vector check action")
                }
            },vectors:true)
        }
        let query="2026-10-10 至 2026-10-12 私教课教过哪些动作"
        let first=MemoryTrace(surface:"test",trigger:"explicit"), second=MemoryTrace(surface:"test",trigger:"explicit")
        let reply=try await engine().answer(query,trace:first)
        _ = try await engine().answer(query,trace:second)
        guard let cold=first.run.select?.vector,let warm=second.run.select?.vector,
              first.run.select?.by=="hybrid_scene",cold.state=="hybrid",cold.dim==1024,
              (cold.new_chunks ?? 0)>0,warm.new_chunks==0,warm.query_cached==true,answers==2,
              Set(reply.sources.map(\.event_id))==["main","tail"] else {
            throw MemoryFailure.message("real vector path failed: \(first.run.select?.vector?.error ?? "unknown")")
        }
        print("PASS: real local vectors — production Swift/Python/Ollama bridge; 16 fictional sources; 1024 dimensions; hybrid coordinates + continuous context; zero chat planning/selection calls; cold \(cold.ms ?? -1) ms, warm \(warm.ms ?? -1) ms; unchanged documents and repeated query not embedded again")
    }
}

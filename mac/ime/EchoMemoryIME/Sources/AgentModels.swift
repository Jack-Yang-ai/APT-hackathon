import Foundation

// Claim each provider request once, including SIGTERM before asynchronous catches resume.
enum ModelInFlight {
    private static let lock=NSLock()
    private static var pending:[UUID:()->Void]=[:]
    static func begin(_ cancelled:@escaping()->Void)->UUID { lock.lock();defer { lock.unlock() };let id=UUID();pending[id]=cancelled;return id }
    static func finish(_ id:UUID)->Bool { lock.lock();defer { lock.unlock() };return pending.removeValue(forKey:id) != nil }
    static func cancelAll() { lock.lock();let calls=Array(pending.values);pending.removeAll();lock.unlock();for call in calls { call() } }
}

// One ephemeral, authenticated local transport. Keychain remains the single credential store.
struct AgentModelRequest:Codable {
    var schema="apt.model.request/1", request_id=UUID().uuidString
    var operation="text", scene:String
    var system="", prompt="", background=false, deep_review=false, json=true
    var timeout:Double=90, max_tokens:Int?=nil
    var audio_base64:String?=nil, language="auto", hotwords:[String]=[], route="plan"
    var credential:MemoryAgentCredential
}
struct AgentModelResponse:Codable {
    var schema="apt.model.reply/1", request_id:String, text:String
    var calls:[MemoryRun.Call]=[], hotwords_refused=false, pcm_retry=false
    var host:MemoryAgentHostVersion
}
enum AgentModels {
    static var exchange:((AgentModelRequest) async throws ->AgentModelResponse)?
    // 模型服务端点:默认本机 18791。MacBook 客户端经 defaults 指到云隧道(Mac mini 记忆中枢,
    // docs/intents/mac-memory-hub/): defaults write local.echo.inputmethod.memory agentModelEndpoint https://apt-backend.example/agent/model
    // http 只准本机(现状端点);https 走隧道,path 必须是 /agent/model,且必须是已经存着 X-Growth-Token 的
    // 那台服务(同源)——令牌只跟着它被保存的服务走,别的主机拿不到;非法配置回退默认本机,不失败。
    static func endpoint(_ raw:String?=UserDefaults.standard.string(forKey:"agentModelEndpoint"))->URL {
        let local=URL(string:"http://127.0.0.1:18791/agent/model")!
        guard let raw,let parts=URLComponents(string:raw.trimmingCharacters(in:.whitespacesAndNewlines)),let host=parts.host,!host.isEmpty,
              parts.user == nil,parts.password == nil,parts.query == nil,parts.fragment == nil,parts.path == "/agent/model",
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return local }
        if parts.scheme == "http" { return host == "127.0.0.1" && parts.port == 18791 ? parts.url ?? local : local }
        guard parts.scheme == "https",let trusted=GrowthMemoryConfig.url(GrowthMemoryConfig.endpoint),
              host.lowercased() == trusted.host,(parts.port == 443 ? nil : parts.port) == trusted.port else { return local }
        var hub=URLComponents(); hub.scheme="https"; hub.host=trusted.host; hub.port=trusted.port; hub.path="/agent/model"
        return hub.url ?? local
    }
    static func send(_ input:AgentModelRequest) async throws ->AgentModelResponse {
        let output:AgentModelResponse
        if let exchange { output=try await exchange(input) }
        else {
            var request=URLRequest(url:AgentModels.endpoint())
            request.httpMethod="POST";request.timeoutInterval=300
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.setValue(try MemoryAgentClient.readToken(),forHTTPHeaderField:"X-Growth-Token")
            request.httpBody=try JSONEncoder().encode(input)
            let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=300;config.timeoutIntervalForResource=300
            let session=URLSession(configuration:config,delegate:MemoryRedirectDelegate(),delegateQueue:nil)
            defer { session.invalidateAndCancel() }
            let (bytes,response)=try await session.data(for:request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MemoryAgentClient.responseFailure(bytes) }
            output=try JSONDecoder().decode(AgentModelResponse.self,from:bytes)
        }
        try Task.checkCancellation()
        guard output.schema == "apt.model.reply/1",output.request_id == input.request_id,
              !output.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,output.text.utf16.count<=300000 else {
            throw MemoryFailure.message("记忆 Agent 服务返回了无效的模型结果。")
        }
        return output
    }
    static func text(system:String,prompt:String,scene:String,background:Bool,deepReview:Bool,timeout:Double,maxTokens:Int?,json:Bool,key:String?=nil) async throws -> AgentModelResponse {
        guard let route=ModelConfig.route(background:background) else { throw MemoryFailure.message("请在 Agent 服务中配置模型。") }
        let credential=MemoryAgentCredential(endpoint:route.url.absoluteString,key:try key ?? (route.key == .stepFun ? SmartMemory.readStepKey() : SmartMemory.readKey()))
        return try await send(.init(scene:scene,system:system,prompt:prompt,background:background,deep_review:deepReview,json:json,timeout:timeout,max_tokens:maxTokens,credential:credential))
    }
    static func asr(audio:Data,key:String,language:String,hotwords:[String],route:StepASR.Route) async throws -> String {
        let result=try await send(.init(operation:"asr",scene:"asr",timeout:120,audio_base64:audio.base64EncodedString(),language:language,hotwords:hotwords,route:route.rawValue,credential:.init(endpoint:route.endpoint.absoluteString,key:key)))
        StepASR.hotwordsRefused=result.hotwords_refused
        return result.text
    }
    static func execute(_ input:AgentModelRequest) async throws -> AgentModelResponse {
        guard input.schema == "apt.model.request/1",UUID(uuidString:input.request_id) != nil,
              !input.credential.key.isEmpty,input.credential.key.utf16.count<=8192,
              (1...240).contains(input.timeout) else { throw MemoryFailure.message("无效的模型请求。") }
        if input.operation == "asr" {
            guard input.scene == "asr",let route=StepASR.Route(rawValue:input.route),route == VoiceASR.route,
                  input.credential.endpoint == route.endpoint.absoluteString,let encoded=input.audio_base64,
                  let audio=Data(base64Encoded:encoded),audio.count<4_000_000,VoiceWave(audio) != nil,
                  ["auto","zh","en"].contains(input.language),input.hotwords.count<=100,
                  input.hotwords.allSatisfy({ !$0.isEmpty && $0.count<=30 }) else { throw VoiceFailure.message("语音配置或录音格式无效。") }
            let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=60;config.timeoutIntervalForResource=120
            let session=URLSession(configuration:config,delegate:MemoryRedirectDelegate(),delegateQueue:nil)
            defer { session.invalidateAndCancel() }
            var retry=false,started=Date()
            let seconds=VoiceWave(audio)?.stats.seconds ?? 0
            func begin()->UUID { let mark=started,scene=retry ? "asr_pcm_retry" : "asr";return ModelInFlight.begin { MemoryLog.book(scene,model:VoiceASR.model,host:route.endpoint.host,started:mark,response:nil,code:"cancelled",audioSeconds:seconds) } }
            var flight=begin()
            let onRetry:()->Void = { if ModelInFlight.finish(flight) { MemoryLog.book("asr",model:VoiceASR.model,host:route.endpoint.host,started:started,response:nil,code:"empty_transcript",audioSeconds:seconds) };retry=true;started=Date();flight=begin() }
            let text:String
            do { text=try await StepASR.transcribe(audio:audio,key:input.credential.key,model:VoiceASR.model,language:input.language,hotwords:input.hotwords,session:session,progress:{ _ in },onPCMRetry:onRetry,route:route) }
            catch { if ModelInFlight.finish(flight) { MemoryLog.book(retry ? "asr_pcm_retry" : "asr",model:VoiceASR.model,host:route.endpoint.host,started:started,response:nil,code:MemoryLog.cancelled(error) ? "cancelled" : "failed",audioSeconds:seconds) };throw error }
            if ModelInFlight.finish(flight) { MemoryLog.book(retry ? "asr_pcm_retry" : "asr",model:VoiceASR.model,host:route.endpoint.host,started:started,response:nil,code:nil,audioSeconds:seconds) }
            return .init(request_id:input.request_id,text:text,hotwords_refused:StepASR.hotwordsRefused,pcm_retry:retry,host:MemoryAgentHost.version)
        }
        guard input.operation == "text",["voice_polish","by_day","style","settings_test","other"].contains(input.scene),
              input.system.utf16.count<=10000,input.prompt.utf16.count<=300000,
              (input.max_tokens.map { (1...64000).contains($0) } ?? true),
              input.scene == "settings_test" || input.background == ["by_day","style"].contains(input.scene) else { throw MemoryFailure.message("无效的模型场景。") }
        let engine=SmartMemory();engine.useSharedModels=false;engine.requestCredential=input.credential
        let trace=MemoryTrace(surface:"model_service",trigger:"explicit",recorded:false)
        let text=try await engine.chat(system:input.system,prompt:input.prompt,deepReview:input.deep_review,timeout:input.timeout,maxTokens:input.max_tokens,scene:input.scene,trace:trace,background:input.background,json:input.json)
        return .init(request_id:input.request_id,text:text,calls:trace.run.calls,host:MemoryAgentHost.version)
    }
}

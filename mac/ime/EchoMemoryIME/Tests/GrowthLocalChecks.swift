import Foundation
import Security

// Temporary test CA, accepted only for an explicitly supplied loopback endpoint.
// Production transport continues to use ordinary system TLS trust and refuses redirects.
final class GrowthLocalTrust:NSObject,URLSessionTaskDelegate {
    let certificate:SecCertificate,host:String
    init(certificate:SecCertificate,host:String) { self.certificate=certificate; self.host=host }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
    func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping (URLSession.AuthChallengeDisposition,URLCredential?)->Void) { evaluate(challenge,completionHandler) }
    func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping (URLSession.AuthChallengeDisposition,URLCredential?)->Void) { evaluate(challenge,completionHandler) }
    private func evaluate(_ challenge:URLAuthenticationChallenge,_ completion:@escaping (URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else { completion(.performDefaultHandling,nil); return }
        guard challenge.protectionSpace.host == host,let trust=challenge.protectionSpace.serverTrust else { FileHandle.standardError.write(Data("Local TLS challenge host/trust mismatch\n".utf8)); completion(.cancelAuthenticationChallenge,nil); return }
        SecTrustSetPolicies(trust,SecPolicyCreateSSL(true,host as CFString))
        SecTrustSetAnchorCertificates(trust,[certificate] as CFArray); SecTrustSetAnchorCertificatesOnly(trust,true)
        var reason:CFError?
        if SecTrustEvaluateWithError(trust,&reason) { completion(.useCredential,URLCredential(trust:trust)) }
        else { FileHandle.standardError.write(Data("Local TLS certificate check failed: \(String(describing:reason))\n".utf8)); completion(.cancelAuthenticationChallenge,nil) }
    }
}

@main struct GrowthLocalChecks {
    static func main() async {
        do { try await run() } catch { FileHandle.standardError.write(Data("Local transport check failed: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 3,let url=GrowthMemoryConfig.url(CommandLine.arguments[1]),
              let host=url.host,["localhost","127.0.0.1","[::1]"].contains(host),
              let certificate=SecCertificateCreateWithData(nil,try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])) as CFData) else { throw MemoryFailure.message("supply loopback HTTPS origin and temporary DER CA") }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("EchoGrowthLocal-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=LocalMemoryStore(root:root.appendingPathComponent("Sources")),token="fixture-local-token",now=Date()
        let first=try store.upsert("这是一条本地后端验证草稿，我明天核对项目的排期。",app:"fixture.local",id:nil,now:now)
        _ = try store.upsert("本地后端验证的预算资料，不等于我已经发给同事。",app:"fixture.other",id:nil,now:now)
        let trust=GrowthLocalTrust(certificate:certificate,host:host)
        var sends=0
        let sync=GrowthMemorySync(store:store,root:root.appendingPathComponent("Sync"),send:{ endpoint,key,data in sends += 1; return try await GrowthMemorySync.sendHTTP(endpoint,key,data,delegate:trust) })
        let sent=try await sync.sync(to:url,token:token); precondition(sent == 2)
        _ = try await sync.sync(to:url,token:token); precondition(sends == 1)
        func post(_ route:String,_ input:[String:Any]) async throws ->[String:Any] {
            let result=try await GrowthMemorySync.sendHTTP(url.appendingPathComponent(route),token,JSONSerialization.data(withJSONObject:input),delegate:trust)
            return try JSONSerialization.jsonObject(with:result) as! [String:Any]
        }
        let context=try await post("input-memory/context",["query":"本地后端验证"])
        let snapshots=context["snapshots"] as! [[String:Any]]
        precondition((context["sources"] as! [Any]).count == 2 && snapshots.count == 2)
        let valid=try await post("input-memory/validate",["snapshots":snapshots]);precondition(valid["valid"] as? Bool == true)
        try store.setDeleted(first,true,now:now.addingTimeInterval(1)); _ = try await sync.sync(to:url,token:token)
        do { _ = try await post("input-memory/validate",["snapshots":snapshots]); preconditionFailure("deleted source must return non-success") } catch {}
        let afterDelete=try await post("input-memory/context",["query":"本地后端验证"])
        precondition((afterDelete["sources"] as! [Any]).count == 1)
        try store.setDeleted(first,false,now:now.addingTimeInterval(2)); _ = try await sync.sync(to:url,token:token)
        let restored=try await post("input-memory/context",["query":"本地后端验证"])
        precondition((restored["sources"] as! [Any]).count == 2)
        precondition((restored["snapshots"] as! [[String:Any]]).contains { ($0["id"] as? String) == first.lowercased() && ($0["revision"] as? Int) == 3 })
        print("PASS: actual Echo outbox → local HTTPS → durable Mac replica → Agent context/validation; deletion and restore; no App, Keychain or paid model")
    }
}

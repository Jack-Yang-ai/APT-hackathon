import Foundation
import Security

enum GrowthMemoryConfig {
    static var defaults=UserDefaults.standard
    static var enabled:Bool { defaults.bool(forKey:"growthMemorySyncEnabled") }
    static var endpoint:String { defaults.string(forKey:"growthMemoryEndpoint") ?? "https://apt-backend.example" }
    static func url(_ value:String)->URL? {
        guard let parts=URLComponents(string:value.trimmingCharacters(in:.whitespacesAndNewlines)),parts.scheme == "https",
              let host=parts.host,!host.isEmpty,parts.user == nil,parts.password == nil,parts.query == nil,
              parts.fragment == nil,parts.port.map({ (1...65535).contains($0) }) ?? true,["","/"].contains(parts.path) else { return nil }
        var canonical=URLComponents(); canonical.scheme="https"; canonical.host=host.lowercased()
        canonical.port=parts.port == 443 ? nil : parts.port
        return canonical.url
    }
    static func account(_ url:URL)->String { DayDigester.hex(Data(url.absoluteString.utf8)) }
    static func saveToken(_ token:String,to url:URL) throws {
        let key:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.echo.growth-memory",kSecAttrAccount as String:account(url)]
        let attrs:[String:Any]=[kSecValueData as String:Data(token.utf8),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status=SecItemUpdate(key as CFDictionary,attrs as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(key.merging(attrs){ _,new in new } as CFDictionary,nil) == errSecSuccess else { throw MemoryFailure.message("APT 令牌未保存到钥匙串。") }
        } else if status != errSecSuccess { throw MemoryFailure.message("APT 令牌未保存到钥匙串。") }
    }
    static func token(for url:URL) throws ->String {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.echo.growth-memory",kSecAttrAccount as String:account(url),kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
        var result:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,let data=result as? Data,
              let token=String(data:data,encoding:.utf8),!token.isEmpty else { throw MemoryFailure.message("先在记忆设置保存 APT 令牌，或允许钥匙串访问。") }
        return token
    }
}

// Reconciliation against the persisted source files is the outbox: a save/queue crash cannot lose a change.
// Only exact server receipts advance acked versions; a concurrent edit remains pending on the next pass.
actor GrowthMemorySync {
    static let shared=GrowthMemorySync()
    struct Record:Codable {
        let id:String,revision:Int,created:String,updated:String,app:String,text:String
        let pasted:[String],voiced:[String],partial:Bool,deleted:Bool
        init(_ source:LocalInputRecord) {
            id=source.id.lowercased(); revision=source.sourceRevision; created=MemoryLog.timestamp(source.created); updated=MemoryLog.timestamp(source.updated)
            app=source.app; text=source.deleted ? "" : source.text
            pasted=source.deleted ? [] : source.pasted ?? []; voiced=source.deleted ? [] : source.voiced ?? []
            partial=source.partial ?? false; deleted=source.deleted
        }
        // One published replica of a day digest: created is the day's Beijing midnight, text carries
        // no draft provenance and is never partial — the worker's day schema enforces the same shape.
        init(day:String,revision:Int,updated:String,text:String,deleted:Bool) {
            id=DayDigester.dayPrefix+day; self.revision=revision; created="\(day)T00:00:00+08:00"; self.updated=updated
            app="echo.day"; self.text=deleted ? "" : text
            pasted=[]; voiced=[]; partial=false; self.deleted=deleted
        }
    }
    struct Batch:Encodable { let schema="growth.input-memory.batch/1"; let device_id:String; let records:[Record] }
    struct Ack:Decodable { let id:String,revision:Int }
    struct Receipt:Decodable { let schema:String; let accepted:[Ack]; let stale:[Ack]; let conflicts:[Ack] }
    struct State:Codable { var device_id=UUID().uuidString; var destinations:[String:[String:Int]]=[:] }
    struct Status { let at:Date?; let pending:Int; let error:String? }
    static let statusLock=NSLock()
    private static var last=Status(at:nil,pending:0,error:nil)
    static var status:Status { statusLock.lock(); defer { statusLock.unlock() }; return last }
    private static func report(_ value:Status) { statusLock.lock(); last=value; statusLock.unlock() }
    typealias Send=(URL,String,Data) async throws ->Data
    let store:LocalMemoryStore,days:DayDigester,root:URL,send:Send
    private var running=false
    private var lastAttempt=Date.distantPast
    init(store:LocalMemoryStore = .shared,days:DayDigester = .shared,root:URL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("EchoMemoryIME/GrowthSync"),send:@escaping Send=GrowthMemorySync.liveSend) {
        self.store=store; self.days=days; self.root=root; self.send=send
    }
    // The publish ledger for Days/ replicas. A record's revision derives from the file's content
    // fingerprint, and the ledger reaches disk before any send: a crash resends the same revision
    // with the same bytes instead of inventing a conflicting one.
    struct DayLibraryEntry:Codable { var revision:Int; let fingerprint:String; let deleted:Bool; let updated:String }
    private func loadLibrary() throws ->[String:DayLibraryEntry] {
        let url=root.appendingPathComponent("day-library.json")
        if FileManager.default.fileExists(atPath:url.path) { return try JSONDecoder().decode([String:DayLibraryEntry].self,from:Data(contentsOf:url)) }
        return [:]
    }
    private func saveLibrary(_ value:[String:DayLibraryEntry]) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url=root.appendingPathComponent("day-library.json")
        try JSONEncoder().encode(value).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    // Mirrors Days/ into ledger versions: new content bumps the revision, a vanished file tombstones
    // it, and untouched content stays untouched. A day the worker would reject (not a real calendar
    // day) never enters the outbox — one poisoned file must not block every input draft behind a 400.
    private func reconcileLibrary() throws ->[String:DayLibraryEntry] {
        var library=try loadLibrary(),changed=false
        let present=Set(((try? FileManager.default.contentsOfDirectory(atPath:days.root.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) })
        for day in present where Self.validDay(day) {
            guard let file=days.load(day) else { continue }
            let body=DayDigester.body(of:file), fingerprint=DayDigester.hex(Data(body.utf8))
            let entry=library[day] ?? DayLibraryEntry(revision:0,fingerprint:fingerprint,deleted:true,updated:file.generated_at)
            if entry.fingerprint != fingerprint || entry.deleted {
                library[day]=DayLibraryEntry(revision:entry.revision+1,fingerprint:fingerprint,deleted:false,updated:file.generated_at)
                changed=true
            }
        }
        for (day,entry) in library.filter({ !$0.value.deleted && !present.contains($0.key) }).sorted(by: { $0.key<$1.key }) {
            library[day]=DayLibraryEntry(revision:entry.revision+1,fingerprint:entry.fingerprint,deleted:true,updated:MemoryLog.timestamp(Date()))
            changed=true
        }
        if changed { try saveLibrary(library) }
        return library
    }
    private static func validDay(_ day:String)->Bool {
        guard day.count == 10,day.range(of:"^\\d{4}-\\d{2}-\\d{2}$",options:.regularExpression) != nil else { return false }
        let formatter=ISO8601DateFormatter()
        guard let instant=formatter.date(from:day+"T00:00:00Z") else { return false }
        return formatter.string(from:instant).hasPrefix(day)
    }
    func state() throws ->State {
        let url=root.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath:url.path) { return try JSONDecoder().decode(State.self,from:Data(contentsOf:url)) }
        let value=State(); try save(value); return value
    }
    private func save(_ value:State) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url=root.appendingPathComponent("state.json")
        try JSONEncoder().encode(value).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func sync(to url:URL,token:String) async throws ->Int {
        guard !running else { throw MemoryFailure.message("APT 同步正在进行，请稍后查看同步结果。") }; running=true; defer { running=false }
        guard GrowthMemoryConfig.url(url.absoluteString) == url else { throw MemoryFailure.message("APT 同步地址必须是 HTTPS 服务根地址。") }
        var current=try state(),sent=0
        let destination=url.absoluteString
        var acked=current.destinations[destination] ?? [:]
        let pending=(store.all()+store.all(deleted:true)).filter { (acked[$0.id.lowercased()] ?? 0)<$0.sourceRevision }.sorted { $0.deleted == $1.deleted ? $0.id<$1.id : $0.deleted }
        // Days/ replicas join the same outbox after the drafts: same batches, same size gates, same receipts.
        let library=try reconcileLibrary()
        var dayRecords:[Record]=[]
        for (day,entry) in library.sorted(by: { $0.key<$1.key }) {
            guard (acked[DayDigester.dayPrefix+day] ?? 0)<entry.revision else { continue }
            if entry.deleted {
                dayRecords.append(Record(day:day,revision:entry.revision,updated:entry.updated,text:"",deleted:true))
            } else if let file=days.load(day) {
                let body=DayDigester.body(of:file)
                // Offered bytes must match the ledger version; a concurrent rewrite waits for the next pass.
                guard DayDigester.hex(Data(body.utf8)) == entry.fingerprint else { continue }
                dayRecords.append(Record(day:day,revision:entry.revision,updated:entry.updated,text:body,deleted:false))
            }
        }
        var batches:[[Record]]=[],building:[Record]=[],tooLarge=0
        func admit(_ record:Record) throws {
            let single=try JSONEncoder().encode(Batch(device_id:current.device_id,records:[record]))
            guard single.count<=950_000,record.pasted.count<=128,record.voiced.count<=128 else { tooLarge += 1; return }
            let candidate=building+[record]
            let candidateBytes=try JSONEncoder().encode(Batch(device_id:current.device_id,records:candidate)).count
            if candidate.count>50 || candidateBytes>950_000 {
                batches.append(building); building=[]
            }
            building.append(record)
        }
        for source in pending { try admit(Record(source)) }
        for record in dayRecords { try admit(record) }
        if !building.isEmpty { batches.append(building) }
        for records in batches {
            try Task.checkCancellation()
            let data=try await send(url.appendingPathComponent("input-memory/sync"),token,JSONEncoder().encode(Batch(device_id:current.device_id,records:records)))
            let receipt=try JSONDecoder().decode(Receipt.self,from:data)
            let offered=Dictionary(uniqueKeysWithValues:records.map { ($0.id,$0.revision) })
            guard receipt.schema == "growth.input-memory.receipt/1",receipt.accepted.allSatisfy({ offered[$0.id] == $0.revision }),Set(receipt.accepted.map(\.id)).count == receipt.accepted.count else {
                throw MemoryFailure.message("APT 同步回执不匹配，未确认上传。")
            }
            for ack in receipt.accepted { acked[ack.id]=ack.revision; sent += 1 }
            current.destinations[destination]=acked; try save(current)
            guard receipt.conflicts.isEmpty,receipt.stale.isEmpty,receipt.accepted.count == records.count else {
                throw MemoryFailure.message("APT 来源版本冲突，保留待同步记录；请核对设备身份。")
            }
        }
        let remainingDrafts=(store.all()+store.all(deleted:true)).filter { (acked[$0.id.lowercased()] ?? 0)<$0.sourceRevision }.count
        let remainingDays=library.filter { (acked[DayDigester.dayPrefix+$0.key] ?? 0)<$0.value.revision }.count
        Self.report(Status(at:Date(),pending:remainingDrafts+remainingDays,error:tooLarge>0 ? "\(tooLarge) 条来源超过上传大小或来源标记上限，其余来源已继续同步。" : nil)); return sent
    }
    static func liveSend(_ url:URL,_ token:String,_ data:Data) async throws ->Data {
        try await sendHTTP(url,token,data,delegate:MemoryRedirectDelegate())
    }
    // The production sender and local TLS integration checks share the same request/timeout/receipt path.
    static func sendHTTP(_ url:URL,_ token:String,_ data:Data,delegate:URLSessionDelegate) async throws ->Data {
        var request=URLRequest(url:url); request.httpMethod="POST"; request.httpBody=data
        request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.setValue(token,forHTTPHeaderField:"X-Growth-Token")
        let config=URLSessionConfiguration.ephemeral; config.urlCache=nil; config.httpCookieStorage=nil; config.timeoutIntervalForRequest=30; config.timeoutIntervalForResource=45
        let session=URLSession(configuration:config,delegate:delegate,delegateQueue:nil); defer { session.invalidateAndCancel() }
        let (result,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode),result.count<=1_048_576 else { throw MemoryFailure.message("APT 同步没有成功，稍后自动重试。") }
        return result
    }
    static func catchUp() {
        guard GrowthMemoryConfig.enabled,let url=GrowthMemoryConfig.url(GrowthMemoryConfig.endpoint) else { return }
        Task {
            do { try await shared.scheduledSync(to:url) }
            catch { report(Status(at:status.at,pending:1,error:error.localizedDescription)) }
        }
    }
    private func scheduledSync(to url:URL) async throws {
        guard Date().timeIntervalSince(lastAttempt)>=60 else { return }; lastAttempt=Date()
        _ = try await sync(to:url,token:GrowthMemoryConfig.token(for:url))
    }
}

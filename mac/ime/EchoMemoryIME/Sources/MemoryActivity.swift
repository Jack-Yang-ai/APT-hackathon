import Foundation

extension Notification.Name { static let echoMemoryActivityChanged=Notification.Name("EchoMemoryActivityChanged") }

// Persist the first pending change and a compact, text-free baseline. Saving again never postpones work.
struct MemoryActivityPlan:Codable {
    struct Dirty:Codable { var fingerprint:String; let since:Date; var characters:Int }
    struct Baseline:Codable {
        let count:Int,forward:[String],backward:[String]
        init(_ text:String) {
            let chars=Array(text); count=chars.count
            func chunks(_ chars:[Character])->[String] {
                stride(from:0,to:chars.count,by:16).map { offset in
                    String(DayDigester.hex(Data(String(chars[offset..<min(offset+16,chars.count)]).utf8)).prefix(16))
                }
            }
            forward=chunks(chars); backward=chunks(Array(chars.reversed()))
        }
        func changed(to new:Baseline)->Int {
            func shared(_ a:[String],_ b:[String])->Int { zip(a,b).prefix { $0 == $1 }.count*16 }
            // Chunk boundaries can overestimate by at most 30 characters; no raw draft is duplicated here.
            let common=min(min(count,new.count),shared(forward,new.forward)+shared(backward,new.backward))
            return max(1,max(count,new.count)-common)
        }
    }
    struct Failure:Codable { let fingerprint:String,error:String; let retryAt:Date? }
    var dirty:[String:Dirty]=[:]
    var idleInterval:TimeInterval=1800
    var baselines:[String:Baseline]?=nil
    var failures:[String:Failure]?=nil
    var lastCompleted:Date?=nil
    static func daysToPrune(live:[LocalInputRecord],deleted:[LocalInputRecord],cutoff:Date)->Set<String> {
        Set((live+deleted.filter { $0.updated>=cutoff }).map { LocalMemoryStore.day($0.created) })
    }
    mutating func reconcile(_ records:[LocalInputRecord],done:Set<String>,now:Date) {
        let live=Set(records.map(\.id)); dirty=dirty.filter { live.contains($0.key) && !done.contains($0.key) }
        baselines=(baselines ?? [:]).filter { live.contains($0.key) }
        for record in records {
            let baseline=Baseline(record.text)
            if done.contains(record.id) { baselines?[record.id]=baseline; continue }
            dirty[record.id] = .init(fingerprint:DayDigester.digest([record]),since:dirty[record.id]?.since ?? now,
                characters:baselines?[record.id]?.changed(to:baseline) ?? record.text.count)
        }
        if !dirty.isEmpty { idleInterval=1800 }
        let days=Set(records.filter { dirty[$0.id] != nil }.map { LocalMemoryStore.day($0.created) })
        failures=(failures ?? [:]).filter { days.contains($0.key) && fingerprint(day:$0.key,records:records) == $0.value.fingerprint }
    }
    func fingerprint(day:String,records:[LocalInputRecord])->String {
        DayDigester.digest(records.filter { LocalMemoryStore.day($0.created) == day && dirty[$0.id] != nil }.sorted { $0.created == $1.created ? $0.id<$1.id : $0.created<$1.created })
    }
    var interval:TimeInterval {
        let characters=dirty.values.reduce(0) { $0+$1.characters }
        return characters>=2000 ? 900 : characters>=200 ? 1800 : 3600
    }
    var deadline:Date? { dirty.values.map(\.since).min().map { $0.addingTimeInterval(interval) } }
    func deadline(for records:[LocalInputRecord])->Date? {
        let pending=records.compactMap { dirty[$0.id] }
        let characters=pending.reduce(0) { $0+$1.characters }
        let interval:TimeInterval=characters>=2000 ? 900 : characters>=200 ? 1800 : 3600
        return pending.map(\.since).min().map { $0.addingTimeInterval(interval) }
    }
    mutating func sleepInterval()->TimeInterval {
        if dirty.isEmpty { let result=idleInterval; idleInterval=min(idleInterval*2,14400); return result }
        return 60
    }
}

// All mutable orchestration runs on the main thread; model work never blocks typing.
final class MemoryActivityCoordinator {
    struct Status {
        var phase="尚未启动",pending=0,paused=0,busy=false
        var failures=""
        var next:Date?,lastCompleted:Date?
    }
    static let shared=MemoryActivityCoordinator()
    private(set) var status=Status()
    private(set) var plan=MemoryActivityPlan()
    private var started=false,running=false,writable=true
    private var task:Task<Void,Never>?,runID:UUID?
    private var timer:Timer?,observer:NSObjectProtocol?
    private let file:URL,digester:DayDigester,enabled:()->Bool,clock:()->Date,prepare:() async throws ->Void
    private let schedule:((TimeInterval)->Void)?
    init(digester:DayDigester = .shared,file:URL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("EchoMemoryIME/Activity/schedule.json"),enabled:@escaping ()->Bool={ DayDigester.enabled },clock:@escaping ()->Date={ Date() },schedule:((TimeInterval)->Void)?=nil,prepare:@escaping () async throws ->Void={
        guard let route=ModelConfig.route(background:true) else { throw MemoryFailure.message("先在「Agent 服务」配置后台模型或实时模型。") }
        _ = try route.key == .stepFun ? SmartMemory.readStepKey() : SmartMemory.readKey()
    }) {
        self.digester=digester; self.file=file; self.enabled=enabled; self.clock=clock; self.schedule=schedule; self.prepare=prepare
    }
    deinit { timer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    func start(observe:Bool=true) {
        guard !started else { return }; started=true
        if FileManager.default.fileExists(atPath:file.path) {
            do { plan=try JSONDecoder().decode(MemoryActivityPlan.self,from:Data(contentsOf:file)) }
            catch {
                do { try FileManager.default.moveItem(at:file,to:file.deletingLastPathComponent().appendingPathComponent("schedule.corrupt-"+UUID().uuidString+".json")) }
                catch { writable=false }
                DayDigester.reportActivity("整理调度记录读取失败，原文件已保留；重新核对本地草稿。")
            }
        }
        if observe { observer=NotificationCenter.default.addObserver(forName:.echoMemoryChanged,object:nil,queue:.main) { [weak self] _ in self?.wake() } }
        wake()
    }
    private func save() {
        guard writable else { return }
        do {
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try JSONEncoder().encode(plan).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        } catch { DayDigester.reportActivity("整理调度记录没有保存："+error.localizedDescription) }
    }
    private func publish(_ phase:String,next:Date?=nil) {
        status=Status(phase:phase,pending:plan.dirty.count,paused:(plan.failures ?? [:]).values.filter { $0.retryAt == nil }.count,busy:running,failures:(plan.failures ?? [:]).sorted { $0.key<$1.key }.map { $0.key+"："+$0.value.error }.joined(separator:"；"),next:next,lastCompleted:plan.lastCompleted)
        NotificationCenter.default.post(name:.echoMemoryActivityChanged,object:self)
    }
    private func arm(_ interval:TimeInterval) {
        let delay=max(60,interval); timer?.invalidate()
        if let schedule { schedule(delay) }
        else { timer=Timer.scheduledTimer(withTimeInterval:delay,repeats:false) { [weak self] _ in self?.wake() } }
    }
    private func reconcile(_ now:Date)->[LocalInputRecord] {
        let cutoff=EchoDates.calendar.date(byAdding:.day,value:-7,to:now)!
        let records=LocalMemoryStore.current(digester.store.all()).filter { $0.created>=cutoff || $0.updated>=cutoff || plan.dirty[$0.id] != nil }
        var done:Set<String>=[]
        for day in MemoryActivityPlan.daysToPrune(live:records,deleted:digester.store.all(deleted:true),cutoff:cutoff) {
            do { try digester.prune(day) } catch { DayDigester.reportActivity(error.localizedDescription) }
            if let file=digester.load(day) {
                let stored=Dictionary(uniqueKeysWithValues:file.inputs.records.map { ($0.id,$0) })
                for record in records where LocalMemoryStore.day(record.created) == day {
                    if let input=stored[record.id],DayDigester.matches(input,record) { done.insert(record.id) }
                }
            }
        }
        plan.reconcile(records,done:done,now:now); save(); return records
    }
    // User action: retries exhausted batches too, without resending already processed sources.
    func runNow() {
        guard enabled(),!running else { return }
        let records=reconcile(clock())
        do {
            for day in Set(records.filter { plan.dirty[$0.id] != nil }.map { LocalMemoryStore.day($0.created) }) { try digester.resetRetries(day) }
            plan.failures=[:]; save(); wake(force:true)
        } catch { DayDigester.reportActivity(error.localizedDescription); publish("无法重试") }
    }
    func wake(now:Date?=nil,force:Bool=false,allowRun:Bool=true) {
        let now=now ?? clock()
        guard enabled() else {
            task?.cancel(); task=nil; runID=nil; running=false
            plan=MemoryActivityPlan(); save(); publish("已关闭"); arm(14400); return
        }
        let records=reconcile(now)
        guard !running else { publish(status.phase); return }
        let days=Set(records.filter { plan.dirty[$0.id] != nil }.map { LocalMemoryStore.day($0.created) }).sorted()
        guard !days.isEmpty else { let interval=plan.sleepInterval(); save(); publish("没有待整理输入"); arm(interval); return }
        // A paused or backing-off date cannot lend its old deadline to fresh input on another date.
        let activeDeadline=plan.deadline(for:records.filter { plan.failures?[LocalMemoryStore.day($0.created)] == nil })
        let dates=days.compactMap { day -> (String,Date)? in
            if let failure=plan.failures?[day] { return failure.retryAt.map { (day,$0) } }
            return activeDeadline.map { (day,$0) }
        }
        let due=dates.filter { force || $0.1<=now }.map { $0.0 }
        guard allowRun,!due.isEmpty else {
            let next=dates.map { $0.1 }.min().map { max($0,now.addingTimeInterval(60)) }
            publish(next == nil ? "等待草稿变化或手动重试" : "等待整理",next:next)
            arm(next?.timeIntervalSince(now) ?? 14400); return
        }
        let requestID=UUID(); runID=requestID
        running=true; publish("正在整理："+due.joined(separator:"、"))
        let generation=digester.currentEpoch(),fingerprints=Dictionary(uniqueKeysWithValues:due.map { ($0,plan.fingerprint(day:$0,records:records)) })
        task=Task.detached {
            var failures:[String:MemoryActivityPlan.Failure]=[:],completed=false,preparationError:String?
            do {
                try await self.prepare()
                for day in due {
                    guard generation == self.digester.currentEpoch() else { break }
                    do {
                        if try await self.digester.run(day,incremental:true,expectedEpoch:generation) != nil { completed=true }
                    } catch {
                        let retryable=(try? self.digester.canRetry(day)) ?? false
                        failures[day] = .init(fingerprint:fingerprints[day]!,error:error.localizedDescription,retryAt:retryable ? self.clock().addingTimeInterval(300) : nil)
                    }
                }
            } catch { preparationError=error.localizedDescription }
            let results=failures,didComplete=completed,setupError=preparationError
            await MainActor.run {
                guard self.runID == requestID else { return }
                self.running=false; self.runID=nil; self.task=nil
                guard generation == self.digester.currentEpoch(),self.enabled() else { self.wake(); return }
                if didComplete { self.plan.lastCompleted=self.clock() }
                self.plan.failures=(self.plan.failures ?? [:]).merging(results) { _,new in new }
                let errors=results.sorted { $0.key<$1.key }.map { $0.key+"："+$0.value.error }.joined(separator:"；")
                DayDigester.reportActivity(setupError ?? (errors.isEmpty ? nil : errors))
                // Setup failures use bounded retries too; they never spend a model call.
                if let setupError {
                    for day in due { self.plan.failures?[day] = .init(fingerprint:fingerprints[day]!,error:setupError,retryAt:self.clock().addingTimeInterval(300)) }
                }
                self.wake(allowRun:false)
            }
        }
    }
}

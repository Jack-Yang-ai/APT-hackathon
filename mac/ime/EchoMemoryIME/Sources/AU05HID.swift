import Foundation
import IOKit.hid

// One dedicated thread owns the run loop, devices, callbacks, buffers and all USB writes.
// No synchronous HID operation ever runs on the input method's main thread.
final class AU05HID {
    struct Request {
        let lease:UUID, payload:[UInt8], reply:Bool
        let completion:(Result<[UInt8],Error>)->Void
    }
    var presence:((UUID?)->Void)?, activity:(()->Void)?, failure:((String,Bool)->Void)?
    private let lock=NSLock()
    private var work:[()->Void]=[], running=false, stopping=false
    private var manager:IOHIDManager?, device:IOHIDDevice?, buffer:UnsafeMutablePointer<UInt8>?
    private var lease:UUID?, pending:Request?, requests:[Request]=[], deadline:TimeInterval=0
    private var heartbeatUntil:TimeInterval=0, heartbeatAt:TimeInterval=0
    private var restoreLight:[UInt8]?
    private var closeCallbacks:[()->Void]=[]
    static var access:Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    static func requestAccess() { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    func start() {
        lock.lock(); guard !running else { lock.unlock(); return }; running=true; stopping=false; lock.unlock()
        Thread.detachNewThread { self.run() }
    }
    func stop(completion:@escaping ()->Void = {}) {
        lock.lock()
        guard running else { lock.unlock(); DispatchQueue.main.async(execute:completion); return }
        work.append { self.stopping=true; self.closeCallbacks.append(completion) }; lock.unlock()
    }
    private func enqueue(_ block:@escaping ()->Void) { lock.lock(); work.append(block); lock.unlock() }
    func command(_ payload:[UInt8],lease:UUID,reply:Bool=true)async throws->[UInt8] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard running else { lock.unlock(); continuation.resume(throwing:AU05Failure.message("AU05 尚未连接。")); return }
            work.append {
                self.requests.append(Request(lease:lease,payload:payload,reply:reply,completion:{ continuation.resume(with:$0) }))
            }
            lock.unlock()
        }
    }
    func keepAlive(for seconds:TimeInterval) { enqueue { self.heartbeatUntil=ProcessInfo.processInfo.systemUptime+seconds } }
    func restoreOnClose(_ payload:[UInt8]) { enqueue { self.restoreLight=payload } }
    private func run() {
        let manager=IOHIDManagerCreate(kCFAllocatorDefault,0); self.manager=manager
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:AU05Protocol.vendor,kIOHIDProductIDKey:AU05Protocol.product,kIOHIDPrimaryUsagePageKey:AU05Protocol.usagePage,kIOHIDPrimaryUsageKey:1] as CFDictionary)
        let context=Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager,{ context,result,_,device in
            guard result == kIOReturnSuccess,let context else { return }
            Unmanaged<AU05HID>.fromOpaque(context).takeUnretainedValue().attach(device)
        },context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager,{ context,_,_,device in
            guard let context else { return }; let owner=Unmanaged<AU05HID>.fromOpaque(context).takeUnretainedValue()
            if let current=owner.device,current === device { owner.detach() }
        },context)
        IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
        let opened=IOHIDManagerOpen(manager,0)
        if opened != kIOReturnSuccess { emitPresence(nil); openFailed(opened) }
        while !stopping {
            lock.lock(); let batch=work; work.removeAll(); lock.unlock(); batch.forEach { $0() }
            let now=ProcessInfo.processInfo.systemUptime
            if let request=pending,now>=deadline { pending=nil; request.completion(.failure(AU05Failure.message("设备没有回应，请按一下 AU05 唤醒后重试。"))) }
            pump(now)
            if device != nil,now<heartbeatUntil,now>=heartbeatAt { _ = try? send([6,1,0x23,0,1]); heartbeatAt=now+0.8 }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode,0.05,true)
        }
        if let restoreLight { _ = try? send(restoreLight) }
        IOHIDManagerRegisterDeviceMatchingCallback(manager,nil,nil); IOHIDManagerRegisterDeviceRemovalCallback(manager,nil,nil)
        detach()
        IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager,0); self.manager=nil
        // Drain work while holding the lock so no continuation can be stranded by shutdown.
        lock.lock(); let last=work; work.removeAll(); running=false; lock.unlock(); last.forEach { $0() }
        failRequests(); stopping=false
        let callbacks=closeCallbacks; closeCallbacks.removeAll()
        DispatchQueue.main.async { callbacks.forEach { $0() } }
    }
    private func attach(_ device:IOHIDDevice) {
        guard self.device == nil else { return }
        let opened=IOHIDDeviceOpen(device,0)
        guard opened == kIOReturnSuccess else { openFailed(opened); return }
        self.device=device; lease=UUID()
        let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:64); buffer.initialize(repeating:0,count:64); self.buffer=buffer
        IOHIDDeviceRegisterInputReportCallback(device,buffer,64,{ context,result,_,_,reportID,bytes,count in
            guard let context,result == kIOReturnSuccess,reportID == AU05Protocol.reportID else { return }
            let owner=Unmanaged<AU05HID>.fromOpaque(context).takeUnretainedValue()
            guard let packet=try? AU05Protocol.decode(Array(UnsafeBufferPointer(start:bytes,count:count))) else { return }
            owner.receive(packet)
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
        emitPresence(lease)
    }
    private func detach() {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
            if let buffer { IOHIDDeviceRegisterInputReportCallback(device,buffer,64,nil,nil); buffer.deinitialize(count:64); buffer.deallocate() }
            IOHIDDeviceClose(device,0)
        }
        device=nil; buffer=nil; lease=nil; restoreLight=nil; heartbeatUntil=0; failRequests(); emitPresence(nil)
    }
    private func failRequests() {
        let all=(pending.map { [$0] } ?? [])+requests; pending=nil; requests.removeAll()
        all.forEach { $0.completion(.failure(AU05Failure.message("AU05 已断开连接。"))) }
    }
    private func emitPresence(_ value:UUID?) { DispatchQueue.main.async { self.presence?(value) } }
    private func openFailed(_ code:IOReturn) {
        let permission = code == kIOReturnNotPermitted || code == kIOReturnNotPrivileged
        let message=permission ? "macOS 尚未允许 APT 访问 AU05，请在输入监控中允许后重试。" : "无法打开 AU05 接收器（\(code)），请退出 Ulanzi Studio 后重试。"
        DispatchQueue.main.async { self.failure?(message,permission) }
    }
    private func receive(_ bytes:[UInt8]) {
        if bytes.count>=4,bytes[0] == 0x8B,bytes[1] == 0x10 { DispatchQueue.main.async { self.activity?() } }
        guard let request=pending,AU05Protocol.matches(bytes,request.payload) else { return }
        pending=nil; request.completion(.success(bytes))
    }
    private func pump(_ now:TimeInterval) {
        guard pending == nil,!requests.isEmpty else { return }
        let request=requests.removeFirst()
        guard request.lease == lease,device != nil else { request.completion(.failure(AU05Failure.message("设备连接已经变化，请重新操作。"))); return }
        do {
            try send(request.payload)
            if request.reply { pending=request; deadline=now+1.8 }
            else { request.completion(.success([])) }
        } catch { request.completion(.failure(error)) }
    }
    private func send(_ payload:[UInt8])throws {
        guard let device else { throw AU05Failure.message("AU05 尚未连接。") }
        let bytes=try AU05Protocol.report(payload)
        let result=bytes.withUnsafeBufferPointer { IOHIDDeviceSetReport(device,kIOHIDReportTypeOutput,AU05Protocol.reportID,$0.baseAddress!,bytes.count) }
        guard result == kIOReturnSuccess else { throw AU05Failure.message("无法写入设备（\(result)），请检查输入监控权限，并退出 Ulanzi Studio 后重试。") }
    }
}

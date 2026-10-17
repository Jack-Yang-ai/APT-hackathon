import XCTest
import GRDB
@testable import GrowthApp

/// 🔴 **「写好了」与「被调用了」是两件事**(`M2-认8` ④b)。
///
/// 2026-08-24 查出来:`RegistrySnapshotIO` 与整套快照语义早就写好、测过了,
/// 而**全仓只有 `VoiceprintRegistryTests` 在调它,生产代码零调用点** ——
/// R2 上实测 0 个快照,于是 Mac 声纹 daemon 读不到、整条认人链跑不通。
/// 而两端各自都「正常」:手机排得进队列、daemon 心跳健康、Worker 回 200。
///
/// **这类缺陷没有运行时症状** —— 单测全绿、编译全过、界面无异常。
/// 能抓住它的只有一个问题:**谁调用它?** 所以这道闸扫源码。
///
/// 同一天里这是第三次同形态(`M1-34` 兜底没人常驻、声纹 daemon 没进 launchd)。
final class SnapshotWiredTests: XCTestCase {

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    /// 快照必须**在生产代码里**被推。测试里调不算 —— 那正是出事时的状态。
    func testSnapshotIsActuallyPushedFromProductionCode() throws {
        // enroll 之后:底库刚变,不推的话这次 enroll 对 Mac 的判决一点用都没有。
        let vm = try source("GrowthApp/Presentation/RecordingViewModel.swift")
        XCTAssertTrue(vm.contains("RemoteSnapshotStore.pushIfNeeded(force: true"), """
            enroll 之后没推快照 —— 判决在 Mac,Mac 读的是 R2 上那份只读快照。
            不推的话「记住了你的声音」是句假话:下一场照样认不出,
            而那与「enroll 根本没成功」长得一模一样。
            """)
        // 定时那次:兜住「enroll 那次没网」。少了它,一次没推成就是永远落后。
        let pump = try source("GrowthApp/Upload/ProcessingPump.swift")
        XCTAssertTrue(pump.contains("RemoteSnapshotStore.pushIfNeeded(force: false"), """
            泵里没有定时推快照 —— enroll 那次没网就永远补不回来,
            而实测过的形态正是「R2 上 0 个快照,两端都不报错」。
            """)
    }

    /// 失败必须留痕(§3.2)。悄悄吞掉的表现是「Mac 一直判不了」。
    func testSnapshotPushFailureIsRecorded() throws {
        for rel in ["GrowthApp/Presentation/RecordingViewModel.swift",
                    "GrowthApp/Upload/ProcessingPump.swift"] {
            let src = try source(rel)
            guard let r = src.range(of: "RemoteSnapshotStore.pushIfNeeded") else {
                XCTFail("\(rel) 里找不到推快照 —— 上一条测试会先红")
                continue
            }
            // 取调用点往后一小段,断言它有 catch 且往事件表写了东西。
            let after = String(src[r.lowerBound...].prefix(900))
            XCTAssertTrue(after.contains("catch") && after.contains("ProcessingEvents.record"), """
                \(rel) 里推快照失败没留痕 —— 兜底的 catch 要么记录要么抛,不要吞。
                吞掉的表现是「Mac 一直判不了」,而那与「Mac 挂了」在界面上一样。
                """)
        }
    }

    /// 底库空时**不推**。空快照比没快照更糟:Mac 会读到它、把每一段都判成陌生人,
    /// 而「底库是空的」与「快照还没推」在 daemon 那头是两种完全不同的处置。
    func testEmptyRegistryIsNotPushed() throws {
        let db = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(db)
        XCTAssertNil(try RemoteSnapshotStore.pushIfNeeded(force: true, in: db),
                     "底库一条向量都没有却推了快照")
    }
}

import Foundation
@testable import GrowthApp

/// 造 `n` 个块 —— 给那些只关心「块有几个」的测试用。
///
/// ⚠️ **`SessionSummary` 没有「只给个数字」的构造器,这是刻意的。**
/// 块清单曾经被丢掉过(只留 `blockCount`),后果是上传层只能退而求其次
/// 「读整个账本、把当天所有块都算成这一场的」——
/// 2026-08-17 真机实测:一天三场,每场都传了当天全部 4 个块,
/// **12 次上传对应 4 个音频文件**,再往下走就是 12 次转写,而转写按块收费。
///
/// 想造摘要就得先有块,这条路从类型上堵住了。
func fakeBlocks(_ n: Int,
                from: Date = Date(timeIntervalSince1970: 1_786_000_000),
                each: TimeInterval = 300) -> [BlockRecord] {
    (0..<n).map { i in
        BlockRecord(seq: i,
                    startedAt: from.addingTimeInterval(Double(i) * each),
                    endedAt: from.addingTimeInterval(Double(i + 1) * each),
                    hardCut: false,
                    fileName: String(format: "block-%04d.m4a", i))
    }
}

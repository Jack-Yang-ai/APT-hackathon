import Foundation

/// 一场录音的来路(`sessions.source` 的取值)。
///
/// 从 `SessionBridge.Source` 挪出来(W1,2026-10-12):`BlockLedger` 要读它,
/// 而手表 target 要共用 `BlockLedger` —— 原来那处挂在 `SessionBridge` 上,
/// 连带着把 GRDB 拖进手表。`SessionBridge.Source` 现在只是指向这里,
/// **取值只有这一份**。
enum SessionSource {
    static let recording = "recording"   // 手机录的
    static let imported  = "import"      // 用户导进来的既有音视频(§4.1.5)
    static let watch     = "watch"       // 手表录的,经手机收件誊写(W1)
}

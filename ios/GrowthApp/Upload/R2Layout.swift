import Foundation

// R2 中转的键布局(§1.1 拓扑 · §1.2 第 ④ 步)。
//
// **手机只写 `inbox/`。** 这不是约定俗成,是凭证层面的:签发给手机的凭证只有
// inbox 写权限。所以这里除了 inbox 前缀不提供任何别的写入口 —— 想往别处写,
// 得先改凭证,那一步在云代理,改不动就写不进去。
//
// **一场多块,不是一场一个文件。** §1.2 ⑥ 说「Mac 拉同一场次的**全部块**」,
// §3.1.6 说 5 分钟分段是为了「断电不丢」与**「边录边传」**——
// 一场一个文件的话不录完就没法拼,边录边传当场不成立。
// 所以块各自上传,按场次前缀组织:
//
//     inbox/audio/<session_id>/block-0000.m4a
//
// ⚠️ 这个布局的另一侧是 `mac/r2_service.py` 的 `AUDIO_PREFIX` 与 `session_id_of()`。
// 两个运行时没法共用常量,所以**两边各有一条测试钉住同一个字面量**;
// 改这里就要改那边,改不动就让测试红着,别让它悄悄漂。
enum R2Layout {

    /// Mac 侧轮询的前缀。与 `mac/r2_service.py::AUDIO_PREFIX` 必须逐字一致。
    static let audioPrefix = "inbox/audio/"

    /// ~~enroll 指令通道:手机只写指令,不写底库~~ ——
    /// 🔴 **这句话描述的是铁律 2 反转(2026-08-10)之前的世界,2026-08-25 更正。**
    /// 反转后底库唯一写方是**手机自己**(`VoiceprintEnroll` 本地写),
    /// 这条通道**已作废**:手机**不许**再往这里投任何东西。
    /// Mac 侧 `r2_service.py::_process_enroll` 只负责把误投的挪进 failed/ 并喊出来。
    /// 常量留着,是因为那侧还在盯这个前缀清残留 —— 两边一起删才能删。
    static let enrollPrefix = "inbox/enroll/"

    /// 一块的键。`blockSeq` 补零到四位,好让字典序 == 块序 ——
    /// Mac 侧靠列目录拿块清单,字典序错了拼接顺序就错了(§3.1.6 按 block_seq 排序拼接)。
    static func audioKey(sessionID: Int64, blockSeq: Int, ext: String) -> String {
        "\(audioPrefix)\(sessionID)/block-\(String(format: "%04d", blockSeq)).\(ext)"
    }

    /// 一场的前缀。Mac 侧列这个拿全部块。
    static func sessionPrefix(sessionID: Int64) -> String {
        "\(audioPrefix)\(sessionID)/"
    }

    /// 说话人代表片段(PRD §4.4.10:认人时要能试听)。
    ///
    /// 🔴 **必须是独立前缀,不能挂在 `inbox/audio/` 底下。**
    /// PRD 要求代表片段**不受 7 天音频保留期影响** —— 挂在音频前缀底下的话,
    /// 保留期一到就跟着没了,而表现是**第 8 天试听静默失效**:
    /// 界面照样有认人页、照样有个播放按钮,只是按了没声音。
    ///
    /// 🔴 **但它必须跟着「移出记忆」一起删。** 保留期是「时间到了自动清」,
    /// 移出记忆是**用户主动的隐私动作**(界面上那句承诺是「删掉,撤不回来」)。
    /// 两者不是一回事 —— 把片段一并挡在「移出记忆」之外,就是**留了一份
    /// 用户以为已经删掉的录音在云上**。所以键里带 `session_id`:
    /// 按场次删得掉,按时间扫不到。
    ///
    /// ⚠️ 这两条互为反面,由 `eval/checks/test_clip_prefix.py` **双向**钉住。
    static let clipPrefix = "clips/"

    /// 一段代表片段的键。`clusterKey` 形如 `（场次略）-c0`(Mac 判决里的簇号)。
    static func clipKey(sessionID: Int64, clusterKey: String, seq: Int) -> String {
        "\(clipPrefix)\(sessionID)/\(clusterKey)-\(seq).m4a"
    }

    /// 一场的片段前缀 —— 「移出记忆」按它删。
    static func clipSessionPrefix(sessionID: Int64) -> String {
        "\(clipPrefix)\(sessionID)/"
    }
}

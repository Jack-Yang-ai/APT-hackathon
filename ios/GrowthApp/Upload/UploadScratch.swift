import Foundation

/// 上传用的 wav 临时文件放在哪、什么时候删(M1-16a 的后一笔)。
///
/// ## 为什么它比 AAC 那笔还大
///
/// `WavExport` 的文档写着「调用方负责用完删」,而唯一调用方
/// `BackgroundUploadCenter` 全文件**零个 `removeItem`**。
/// 5 分钟块 16k 单声道 16bit ≈ **9.6 MB**,一天 144 块 ≈ **1.4 GB/天** ——
/// 比 AAC 那笔(260 MB/天)大五倍,而且它是**纯浪费**:m4a 还在,
/// wav 随时能再转一遍。
///
/// ## 🔴 顺带修掉一个会传错音频的命名
///
/// 原来 wav 的名字是从 m4a 文件名推出来的:`recordings/<day>/block-0003.m4a`
/// → `tmp/block-0003.wav`。而**块号是按天从 0 起的** ——
/// 8 月 15 日和 8 月 16 日各有一个 `block-0003`,推出来是**同一个临时路径**。
/// `WavExport.convert` 开头就 `removeItem` 再重写 ⇒ 两块同时在传时,
/// 后转的那个会把前一个正在上传的文件**换掉**。
///
/// 表现是「上传成功、转写成功、内容是别人的」—— 本仓最贵的那种错法。
/// 所以名字改成按**上传标签**(场次/块号)取,全局唯一。
///
/// ## 什么时候删才安全
///
/// **`didCompleteWithError` 里删。** 那是系统给出的最终结果,
/// 它自己的重试已经在它之前跑完了 —— 此刻文件对任何人都没用了。
///
/// 「交出去就删」不行(系统还没读完),「永远不删」就是现在这样。
/// 而失败之后要重传时,重新从 m4a 转一遍即可 —— m4a 受保留期保护、还在盘上。
enum UploadScratch {

    /// 前缀写成常量,好让扫残留那一步认得出「哪些是我的」——
    /// 临时目录里还有系统和别的库放的东西,不能见 `.wav` 就删。
    static let prefix = "growth-upload-"

    static func url(tag: String, in dir: URL = FileManager.default.temporaryDirectory) -> URL {
        // `tag` 是 `<sessionID>/<blockSeq>`,`/` 在文件名里是路径分隔符 —— 换掉。
        dir.appendingPathComponent(prefix + tag.replacingOccurrences(of: "/", with: "-") + ".wav")
    }

    /// 传完就删。**失败也删** —— 重传会重新转一遍。
    static func discard(tag: String, in dir: URL = FileManager.default.temporaryDirectory,
                        fileManager fm: FileManager = .default) {
        try? fm.removeItem(at: url(tag: tag, in: dir))
    }

    /// 启动时扫一遍残留:转完 wav 之后、拿到回调之前被杀掉的那些。
    ///
    /// - Parameter liveTags: 系统那边**还活着**的上传任务标签。它们的 wav 不能删 ——
    ///   后台传输可能已经跑了一半,删掉就是把正在传的文件抽走。
    @discardableResult
    static func sweep(liveTags: Set<String>,
                      in dir: URL = FileManager.default.temporaryDirectory,
                      fileManager fm: FileManager = .default) -> (files: Int, bytes: Int64) {
        let live = Set(liveTags.map { url(tag: $0, in: dir).lastPathComponent })
        var files = 0
        var bytes: Int64 = 0
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let name = f.lastPathComponent
            guard name.hasPrefix(prefix), !live.contains(name) else { continue }
            bytes += ((try? fm.attributesOfItem(atPath: f.path))?[.size] as? NSNumber)?
                .int64Value ?? 0
            if (try? fm.removeItem(at: f)) != nil { files += 1 }
        }
        return (files, bytes)
    }
}

import SwiftUI
import GRDB

/// 「听一下这句」。**认人页和命名页共用这一个** ——
/// 两处各写一份的话,迟早一处放的是样本那句、另一处放的是簇里随便一句,
/// 而那种不一致没人查得出来。
///
/// 🔴 **它放的必须是 `sample` 那句话本身的音频。**
/// 用户是照着屏幕上的字去听声音的:字和声音对不上,他会照着**别人的声音**
/// 确认「这是小李」,而归属一错,表态与承诺全跟着错。
/// 所以入参是**那一行的 `line_id`**,不是簇、不是人。
struct SampleAudioButton: View {
    let lineID: Int64?
    @ObservedObject var player: LineAudioPlayer

    @State private var resolved: Result<LineAudio.Clip, LineAudio.Unavailable>?

    private var playing: Bool { lineID != nil && player.playingLineID == lineID }

    var body: some View {
        Group {
            switch resolved {
            case .success(let clip):
                Button {
                    guard let lineID else { return }
                    player.toggle(lineID: lineID, clip: clip)
                } label: {
                    Label(playing ? "停" : "听一下这句",
                          systemImage: playing ? "stop.fill" : "play.fill")
                        .font(DS.F.meta)
                        .foregroundStyle(DS.C.brand)
                }

            case .failure(let why):
                // ⚠️ **说出原因,不给一个灰掉的喇叭。**
                // 不说的话用户只会以为「这个 App 坏了」,而真相
                //(录得早 / 音频清掉了)其实是他能理解、也能应对的。
                Label(why.reason, systemImage: "speaker.slash")
                    .font(DS.F.meta).foregroundStyle(DS.C.dim)

            case nil:
                // 🔴 **不能是 `EmptyView()`。**
                //
                // ~~还没解析出来 —— 不占位、不闪,静默即可~~ **2026-08-31 用户实机撞死在这里。**
                // SwiftUI 里一个只产出 `EmptyView` 的视图**不生成布局节点**,
                // 挂在它上面的 `.task` 于是**不会触发** ⇒ `resolved` 永远是 nil
                // ⇒ 永远渲染 `EmptyView`。**它把自己锁死了**,而现场是
                // 「认人页上一个播放入口都没有」—— 与「这条录音没有音频」一模一样。
                //
                // ⚠️ 讽刺的是本文件顶上就写着「说出原因,不给一个灰掉的喇叭」,
                // 而这一支给的是**什么都不给**,比灰喇叭更糟:灰喇叭至少证明代码跑过。
                // ⇒ 占位必须是**真的视图**。顺带它也诚实:读音频要开账本、要碰盘,
                // 不是瞬间的事,说一句「读取中」比闪一下好。
                Label("读取音频…", systemImage: "waveform")
                    .font(DS.F.meta)
                    .foregroundStyle(DS.C.dim)
            }
        }
        .task(id: lineID) { await resolve() }
    }

    private func resolve() async {
        // 🔴 **这两条以前是静默的** —— `resolved = nil` 渲染成 `EmptyView`,
        // 界面上与「还在加载」一模一样,用户只看到「没法听」而拿不到任何原因。
        // 2026-08-19 用户实机反馈「我没办法听声音来判断是不是我」,查到的就是这里:
        // 这个文件顶上自己写着「说出原因,不给一个灰掉的喇叭」,而这两条路连灰喇叭都没有。
        guard let lineID else { resolved = .failure(.noSampleLine); return }
        guard let db = AppDatabase.shared else { resolved = .failure(.lookupFailed); return }
        do {
            resolved = try LineAudio.clip(lineID: lineID, in: db)  // queue 版:自己去账本取块起点
        } catch {
            // ⚠️ 原来是 `try?`,抛出来的错被吞成 nil ⇒ 又一条静默路径(§3.2)。
            resolved = .failure(.lookupFailed)
        }
    }
}

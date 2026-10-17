import SwiftUI
import UniformTypeIdentifiers

/// 导入已有音视频(PRD §4.1.5)。设计:`import-recordings-v1.html`。
///
/// ## 这一屏做到哪
///
/// **选文件 → 解码 → Silero 粗切 → 切成块写进账本 → 入库 → 排进处理队列。**
///
/// 🔴 ~~「后面那半(切音频、入库、排队上传、转写)是 M1-4 的处理编排,还没接。」~~
/// **2026-08-17 接上了(M1-15c)。** 在那之前这一屏是个**预览器不是导入器**:
/// 真解码、真跑 Silero、真列出切成几场,然后什么都不做 —— 而导入是 M1 出口项。
///
/// ⚠️ 仍然**不显示「上传中 62%」那种进度条**。设计稿上有,但上传是后台传输,
/// 进度在 `upload_jobs` 里而不在这一屏;在这里画一个会让用户以为
/// 「等它跑完这个条就好了」,而实际上他可以直接走开。
/// 导入完给的是一句「排进队列了,回首页看」——那才是真的。
struct ImportView: View {
    @ObservedObject var vm: RecordingViewModel

    @State private var picking = false
    @State private var status: Status = .idle
    @State private var progress: Double = 0
    @State private var result: [AudioImport.Segment] = []
    @State private var pickedName = ""

    enum Status: Equatable {
        case idle, analyzing
        /// 切完了、正在写块与入库。**与 analyzing 分开** —— 这一步在切音频文件,
        /// 一小时的录音要切十几块,合成一档会让用户以为 VAD 跑了很久。
        case ingesting
        case done(ImportIngest.Outcome)
        case failed(String)
    }

    var body: some View {
        ZStack {
            DS.C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("导入过去的录音")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(DS.C.ink)
                    Text("m4a / mp3 / wav / mp4 · 最长 \(Int(AudioImport.maxHours)) 小时")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.C.dim)
                        .padding(.top, 4)
                        .padding(.bottom, 16)

                    Button { picking = true } label: {
                        HStack {
                            Text("选一个文件")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(DS.C.brand)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(status == .analyzing)

                    body(for: status)

                    Text("导入后自动粗切:按 ≥\(Int(AudioImport.sessionGapSeconds / 60)) 分钟的"
                       + "长静音切成多场。分说话人要以一整场对话为单位才判得准,"
                       + "所以两场硬粘成一场是不行的 —— 录音也是这么切的。")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.C.dim)
                        .padding(.top, 24)

                    Text("导入之后和录音走同一条路:同一个目录、同一本账本、同一个队列。"
                       + "所以它会自己上传、转写、出纪要 —— 回首页等着就行。")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.C.dim)
                        .padding(.top, 10)
                }
                .padding(.horizontal, DS.S.side)
                .padding(.top, 12)
            }
        }
        .navigationTitle("导入录音")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.audio, .movie],
                      allowsMultipleSelection: false) { handle($0) }
    }

    @ViewBuilder
    private func body(for s: Status) -> some View {
        switch s {
        case .idle:
            EmptyView()

        case .analyzing:
            VStack(alignment: .leading, spacing: 8) {
                Text(pickedName).font(.system(size: 14)).foregroundStyle(DS.C.ink)
                // 进度为负 = 总长不可信(NaN / 流式文件)。**这时不画百分比** ——
                // 一个钉在 0% 的进度条和「卡死」在界面上没有区别。
                if progress < 0 {
                    ProgressView().tint(DS.C.brand)
                } else {
                    ProgressView(value: progress).tint(DS.C.brand)
                }
                Text(progress < 0
                     ? "正在听这段录音的静音在哪(这个文件读不出总长,只能等)"
                     : "正在听这段录音的静音在哪 —— \(Int(progress * 100))%")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.dim)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.C.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 16)

        case .ingesting:
            VStack(alignment: .leading, spacing: 8) {
                Text(pickedName).font(.system(size: 14)).foregroundStyle(DS.C.ink)
                ProgressView().tint(DS.C.brand)
                Text("正在切块并入库 —— 这一步在写文件,别退出去")
                    .font(.system(size: 12)).foregroundStyle(DS.C.dim)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.C.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 16)

        case .done(let out):
            VStack(alignment: .leading, spacing: 10) {
                Text(pickedName).font(.system(size: 14)).foregroundStyle(DS.C.ink)
                Text("导进来了:\(out.sessionIDs.count) 场 · \(out.blocks) 块")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.C.brand)
                // 🔴 **归到哪一天必须说出来。** 导一段上周的会议,它属于上周 ——
                // 用户回首页在「今天」里找不到它,会以为导入失败了。
                Text(out.dateWasGuessed
                     ? "归到 \(out.day) —— ⚠️ 这个文件没带日期,用的是今天"
                     : "归到 \(out.day)(文件自己的日期),在首页「更早」里")
                    .font(.system(size: 12)).foregroundStyle(DS.C.dim)
                Text("已经排进处理队列,会自己上传、转写、出纪要。")
                    .font(.system(size: 12)).foregroundStyle(DS.C.dim)
                ForEach(Array(result.enumerated()), id: \.offset) { i, seg in
                    HStack {
                        Text("第 \(i + 1) 场")
                            .font(.system(size: 13)).foregroundStyle(DS.C.sub)
                        Spacer()
                        Text("\(Self.clock(seg.startSeconds)) – \(Self.clock(seg.endSeconds))"
                           + "  ·  \(Int(seg.durationSeconds / 60)) 分钟")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(DS.C.dim)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.C.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.C.line, lineWidth: 1))
            .padding(.top, 16)

        case .failed(let why):
            // 失败要说原因,而且**保留用户已选的文件名**(G5)。
            Text(why)
                .font(.system(size: 13))
                .foregroundStyle(DS.C.danger)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.C.panel)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 16)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private func handle(_ r: Result<[URL], Error>) {
        switch r {
        case .failure(let e):
            status = .failed("没能打开这个文件:\(e.localizedDescription)")
        case .success(let urls):
            guard let url = urls.first else { return }
            pickedName = url.lastPathComponent
            analyze(url)
        }
    }

    private func analyze(_ url: URL) {
        status = .analyzing
        progress = 0
        result = []
        Task {
            // 文件选择器给的是沙箱外的 URL,不开安全作用域读不到。
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let vad = try SileroVAD()
                let segs = try await AudioImport.segments(of: url, vad: vad) { p in
                    Task { @MainActor in progress = p }
                }
                // 一场都没切出来要**说清楚为什么**,而不是显示「0 场」了事 ——
                // 而且这时**什么都不该入库**:一个零场的场次会一路走到
                // 「这一场一块音频都没有」并被标死。
                guard !segs.isEmpty else {
                    await MainActor.run {
                        result = []
                        status = .failed("整个文件里没有听到人说话 —— 没有可以成场的片段。")
                    }
                    return
                }
                await MainActor.run { result = segs; status = .ingesting }

                guard let db = vm.database else {
                    await MainActor.run { status = .failed("主库没打开,导进来的东西存不下") }
                    return
                }
                // 🔴 **切块 + 入库 + 入队。** 在这一步接上之前,这一屏是个预览器:
                // 真解码、真跑 VAD、真列出切成几场,然后什么都不做。
                let out = try await ImportIngest.ingest(url: url, segments: segs, in: db)
                await MainActor.run { status = .done(out); vm.refreshToday() }
            } catch {
                await MainActor.run { status = .failed(String(describing: error)) }
            }
        }
    }
}

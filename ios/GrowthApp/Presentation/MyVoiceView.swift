import SwiftUI
import GRDB

/// 只认本人:灰区按簇确认,自动认出后逐句复查;模板只来自听过的样本。
struct MyVoiceView: View {
    @ObservedObject var vm: RecordingViewModel
    @State private var templates = 0
    @State private var candidates: [SpeakerReviews.SelfCandidate] = []
    @State private var selection: SpeakerReviews.SelfCandidate?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("\(templates) 份声音样本").font(.title2.bold())
                Text(templates == 0
                     ? "先用手表录一段约 30 秒的话，再从原话里确认「是我」。只记住你亲耳确认过的声音。"
                     : "只认你的声音。拿不准时问你，其他人按本场说话人显示。")
                    .foregroundStyle(DS.C.dim)
                Text("认人由 Mac 处理，Mac 开着时会自动更新。")
                    .font(DS.F.meta).foregroundStyle(DS.C.dim)
                if let failure { Text(failure).foregroundStyle(DS.C.sub) }
                if candidates.isEmpty && failure == nil {
                    Text("没有需要你确认的声音。")
                }
                ForEach(candidates) { candidate in
                    Button { selection = candidate } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.isClusterConfirmation ? "是你吗？" : "复查这句是不是你")
                                .font(.headline).foregroundStyle(DS.C.brand)
                            Text(candidate.text).foregroundStyle(DS.C.ink).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(DS.C.panel, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                }
            }.padding(20)
        }
        .background(DS.C.bg)
        .navigationTitle("我的声音")
        .task { load() }
        .onAppear { load() }
        .onChange(of: vm.feed) { _, _ in load() }
        .sheet(item: $selection) { candidate in
            SelfVoiceSheet(candidate: candidate, database: vm.database,
                           onDone: { load() })
        }
    }

    private func load() {
        guard let db = vm.database else { failure = "主库没打开，声音样本读不出来"; return }
        do {
            let count = try VoiceprintRegistry.templateCounts(in: db, model: VoiceprintModel.current)[SpeakerNaming.mePersonID] ?? 0
            let pending = try SpeakerReviews.selfCandidates(in: db)
            if templates != count { templates = count }
            if candidates != pending { candidates = pending }
            if failure != nil { failure = nil }
        } catch { failure = "读取声音样本失败：\(error)" }
    }
}

struct SelfVoiceSheet: View {
    let candidate: SpeakerReviews.SelfCandidate
    let database: DatabaseQueue?
    let onDone: () -> Void
    @EnvironmentObject private var vm: RecordingViewModel
    @StateObject private var audio = LineAudioPlayer()
    @State private var failure: String?
    @State private var canPlay = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(candidate.text).font(.title3).fixedSize(horizontal: false, vertical: true)
                SampleAudioButton(lineID: candidate.lineID, player: audio)
                Text(candidate.isClusterConfirmation
                     ? "确认的是这一场里的这个说话人。只把这句样本记进声音库。"
                     : "这句已被自动认成你。这里只复查这一句，其他句子保持各自的归属。")
                    .font(DS.F.meta).foregroundStyle(DS.C.dim)
                if let failure { Text(failure).foregroundStyle(DS.C.sub) }
                Spacer()
                Button("是我") { answer(true) }.buttonStyle(.borderedProminent).disabled(!canPlay)
                Button("不是我") { answer(false) }.buttonStyle(.bordered).disabled(!canPlay)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle(candidate.isClusterConfirmation ? "是你吗？" : "复查这句")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后") { dismiss() } } }
        }
        .onDisappear { audio.stop() }
        .task {
            guard let database else { failure = "主库没打开，原话读不出来"; return }
            do {
                if case .success = try LineAudio.clip(lineID: candidate.lineID, in: database) {
                    canPlay = true
                } else { failure = "这句的音频已经不在了，没法听声确认。可以回原话里手动纠正。" }
            } catch { failure = "读取这句音频失败：\(error)" }
        }
    }

    private func answer(_ isMe: Bool) {
        guard let database else { failure = "主库没打开，没能记下"; return }
        audio.stop()
        do {
            try SpeakerReviews.answerSelf(candidate, isMe: isMe,
                                          now: ISO8601DateFormatter.growth.string(from: Date()), in: database)
            if isMe {
                Task { await vm.enrollFromConfirmation(personID: SpeakerNaming.mePersonID,
                                                      lineIDs: [candidate.lineID]) }
            }
            onDone()
            dismiss()
        } catch { failure = "这次没记上，重新打开后再试：\(error)" }
    }
}

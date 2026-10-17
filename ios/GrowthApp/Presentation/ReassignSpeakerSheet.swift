import SwiftUI
import GRDB
















struct ReassignSpeakerSheet: View {
    let line: QuoteContext.Line






    @StateObject private var audio = LineAudioPlayer()
    let database: DatabaseQueue?
    let onDone: () -> Void
    @EnvironmentObject private var vm: RecordingViewModel





    @State private var options: [(key: String, label: String, sample: String?, sampleLineID: Int64?)] = []
    @State private var note: Notice?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                DS.C.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        quote

                        Text("这句话是谁说的?")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.C.ink)
                            .padding(.top, 8)

                        choice("是我", isCurrent: line.speaker == "我") {
                            setSelf(true)
                        }
                        choice("不是我", isCurrent: false) { setSelf(false) }

                        ForEach(options.filter { $0.key != SpeakerNaming.meKey }, id: \.key) { o in
                            choice(o.label, sample: o.sample, sampleLineID: o.sampleLineID,
                                   isCurrent: o.label == line.speaker) {
                                assign(personOrTag: o.key)
                            }
                        }



                        choice("认不出", isCurrent: false) { dismiss() }

                        if let note {
                            Text(note.text)
                                .font(.system(size: 13))
                                .foregroundStyle(note.isError ? DS.C.danger : DS.C.dim)
                                .padding(.top, 6)
                        }

                        Text("只改这一句。同一个人的其他句子要各自长按 —— "
                           + "按声音相似度一次改一批,还没做出来。")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.C.dim)
                            .padding(.top, 10)
                    }
                    .padding(.horizontal, DS.S.side)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("纠正说话人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task { load() }
    }

    private var quote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(SessionCardView.stamp(line.atMillis))\(line.speaker.map { " · \($0)" } ?? "")")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(DS.C.dim)
            Text(line.text)
                .font(.system(size: 15))
                .foregroundStyle(DS.C.ink)
                .fixedSize(horizontal: false, vertical: true)

            SampleAudioButton(lineID: line.id, player: audio)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DS.C.brandSoft)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func choice(_ label: String, sample: String? = nil, sampleLineID: Int64? = nil,
                        isCurrent: Bool, action: @escaping () -> Void) -> some View {



        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label)
                            .font(.system(size: 15))
                            .foregroundStyle(DS.C.ink)

                        if let sample, !sample.isEmpty {
                            Text("「\(sample)」")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.C.dim)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if isCurrent {
                        Text("现在是这个")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.C.dim)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)


            if let sampleLineID {
                SampleAudioButton(lineID: sampleLineID, player: audio)
                    .padding(.top, 6)
            }
        }
        .padding(12)
        .frame(minHeight: 48)
        .background(DS.C.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(DS.C.line, lineWidth: 1))
    }



    private func setSelf(_ isMe: Bool) {
        guard let database else { note = .error("主库没打开"); return }
        audio.stop()
        do {
            _ = try AssignSpeaker.assignSpeaker(lines: [line.id],
                person: isMe ? SpeakerNaming.mePersonID : nil, clusterTag: nil,
                source: .userConfirmed, confidence: nil, actor: .user,
                now: ISO8601DateFormatter.growth.string(from: Date()), in: database)
            if isMe {
                Task { await vm.enrollFromConfirmation(personID: SpeakerNaming.mePersonID,
                                                      lineIDs: [line.id]) }
            }
            onDone()
            dismiss()
        } catch { note = .error("没能记下：\(error)") }
    }






    private func load() {
        guard let database else { note = .error("主库没打开"); return }
        do {
            options = try database.read { db in



                let samples = try Self.samples(in: db, lineID: line.id)

                let sid = try Int64.fetchOne(db, sql: """
                    SELECT t.session_id FROM transcript_lines l
                      JOIN transcripts t ON t.id = l.transcript_id
                     WHERE l.line_id = ?
                    """, arguments: [line.id])

















                let named = try PersonStore.names(in: db)
                let inThisSession = Set(samples.keys)

                return try SpeakerNaming.labels(
                    in: db, scope: sid.map { .session($0) } ?? .global)
                    .filter { key, _ in
                        inThisSession.contains(key)
                            || SpeakerNaming.personID(of: key).map { named[$0] != nil } == true
                    }
                    .map { (key: $0.key, label: $0.value,
                            sample: samples[$0.key]?.text, sampleLineID: samples[$0.key]?.lineID) }
                    .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            }
        } catch {
            note = .error("没能读出候选:\(error)")
        }
    }






    static func samples(in db: Database, lineID: Int64) throws -> [String: (text: String, lineID: Int64)] {
        var out: [String: (text: String, lineID: Int64)] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT \(SpeakerNaming.keyExpr(session: "t.session_id")) AS who,
                   l.text AS text, l.line_id AS line_id,
                   ROW_NUMBER() OVER (
                       PARTITION BY \(SpeakerNaming.keyExpr(session: "t.session_id"))
                       ORDER BY LENGTH(l.text) DESC, l.line_id) AS rn
              FROM line_speakers ls
              JOIN transcript_lines l ON l.line_id = ls.line_id
              JOIN transcripts      t ON t.id = l.transcript_id
             WHERE t.session_id = (SELECT t2.session_id
                                     FROM transcript_lines l2
                                     JOIN transcripts t2 ON t2.id = l2.transcript_id
                                    WHERE l2.line_id = ?)
               AND l.is_gap = 0 AND l.redacted = 0
            """, arguments: [lineID]) where (row["rn"] as Int? ?? 0) == 1 {
            guard let who = row["who"] as String?,
                  let sampleID = row["line_id"] as Int64? else { continue }


            out[who] = (String((row["text"] as String? ?? "").prefix(40)), sampleID)
        }
        return out
    }





    private func assign(personOrTag: String) {
        guard let database else { return }
        let asPerson = Int64(personOrTag)
        do {
            let r = try AssignSpeaker.assignSpeaker(
                lines: [line.id],
                person: asPerson,
                clusterTag: asPerson == nil ? personOrTag : nil,
                source: .userConfirmed,
                confidence: nil,
                actor: .user,
                now: ISO8601DateFormatter().string(from: Date()),
                in: database)
            if r.isNoOp {
                note = .info("本来就是这个,没有改动。")
            } else {
                onDone()
                dismiss()
            }
        } catch {

            note = .error("没能改:\(error)")
        }
    }
}

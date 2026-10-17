import SwiftUI

@main
struct GrowthWatchApp: App {
    @StateObject private var recorder = WatchRecorder()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRecordView()
                .environmentObject(recorder)
                .environmentObject(recorder.outbox)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { recorder.outbox.retryPending() }
                }
        }
    }
}

/// 一屏:状态、计时、有没有人声、还有几块没传到手机,以及开始/暂停/结束。
struct WatchRecordView: View {
    @EnvironmentObject private var recorder: WatchRecorder
    @EnvironmentObject private var outbox: WatchOutbox

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                status
                if let started = recorder.sessionStartedAt {
                    Text(started, style: .timer)
                        .font(.system(.title2, design: .rounded).monospacedDigit())
                }
                controls
                Text(!outbox.linked ? "还没连上手机,录好的先存在表上"
                     : outbox.inflightBlocks == 0 ? "已完成的片段都已送到手机"
                     : "还有 \(outbox.inflightBlocks) 块没送到手机")
                    .font(.footnote).foregroundStyle(.secondary)
                if outbox.activelySyncing {
                    Text(recorder.state == .recording ? "正在同步，录音继续" : "正在同步已完成片段")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if outbox.linked, !outbox.reachable, outbox.inflightBlocks > 0 {
                    Text("手机暂不能即时通信，已完成片段保留在传输队列")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if recorder.state == .recording {
                    Text("约每 15 分钟同步，结束时立即补传")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if outbox.inflightBlocks > 0 {
                    Button("立即同步") { outbox.retryPending(force: true) }
                        .font(.footnote)
                }
                if recorder.notificationsDenied {
                    Text("通知没开:录音被打断时只能震动,手表没亮屏时你可能察觉不到。去手表「设置 → 通知」打开 APT。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let n = recorder.notice {
                    Text(n).font(.footnote).foregroundStyle(.secondary)
                }
                if let e = outbox.lastError {
                    Text(e).font(.footnote).foregroundStyle(.primary)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch recorder.state {
        case .recording:
            Label(recorder.hasSpeech ? "有人在说话" : "录音中",
                  systemImage: recorder.hasSpeech ? "waveform" : "record.circle")
                .foregroundStyle(.green)
        case .pausedByUser:
            Label("已暂停", systemImage: "pause.circle")
        case .pausedBySystem:
            // 打断靠文字与震动说明,与手机改版一致,不用红色警示。
            Label("被打断,没在录", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.primary)
        default:
            Label("未在录音", systemImage: "mic.slash")
        }
    }

    @ViewBuilder private var controls: some View {
        switch recorder.state {
        case .recording:
            HStack {
                Button("暂停") { recorder.pause() }
                Button("结束") { recorder.stop() }
            }
        case .pausedByUser, .pausedBySystem:
            HStack {
                Button("继续") { recorder.resume() }
                Button("结束") { recorder.stop() }
            }
        default:
            Button("开始录音") { recorder.start() }.tint(.blue)
        }
    }
}

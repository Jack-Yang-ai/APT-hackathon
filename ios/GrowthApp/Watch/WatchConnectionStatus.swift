import Foundation
import WatchConnectivity

/// 即时消息可达性和后台文件传输是两件事；这里不推断手表录音状态。
enum WatchConnectionStatus: Equatable {
    case unsupported, connecting, failed(String), unpaired, appMissing, reachable, waiting

    init(supported: Bool, activation: WCSessionActivationState, paired: Bool,
         installed: Bool, reachable: Bool, error: String? = nil) {
        if !supported { self = .unsupported }
        else if let error { self = .failed(error) }
        else if activation != .activated { self = .connecting }
        else if !paired { self = .unpaired }
        else if !installed { self = .appMissing }
        else { self = reachable ? .reachable : .waiting }
    }

    var title: String {
        switch self {
        case .unsupported: return "此设备不支持手表连接"
        case .connecting: return "正在连接手表"
        case .failed: return "手表连接失败"
        case .unpaired: return "尚未配对手表"
        case .appMissing: return "手表尚未安装 APT"
        case .reachable: return "手表已连接"
        case .waiting: return "手表已配对"
        }
    }

    var detail: String {
        switch self {
        case .unsupported: return "请在支持 Apple Watch 的 iPhone 上使用。"
        case .connecting: return "正在读取配对与 App 状态。"
        case .failed(let message): return "重新打开 App 可重试。\(message)"
        case .unpaired: return "请在 iPhone 的 Watch App 中完成配对。"
        case .appMissing: return "请在 Watch App 中安装 APT，再打开手表上的 App。"
        case .reachable: return "即时通信可用；录音是否进行，请以手表为准。"
        case .waiting: return "手表在后台时可能无法即时通信，仍可后台同步，不表示录音停止。录音状态请以手表为准。"
        }
    }
}

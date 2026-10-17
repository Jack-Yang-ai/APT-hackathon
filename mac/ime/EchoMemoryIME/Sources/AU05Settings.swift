import SwiftUI

struct AU05SettingsView:View {
    @ObservedObject var device=AU05Controller.shared
    var body:some View {
        APTSettingsContent {
            APTSettingsSection {
                Toggle("在 APT 中使用 AU05",isOn:Binding(get:{ device.enabled },set:{ device.setEnabled($0) }))
                HStack {
                    Image(systemName:device.ready ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right").foregroundStyle(device.ready ? Color.green : Color.secondary)
                    Text(device.status).foregroundStyle(.secondary)
                    Spacer()
                    if device.busy { ProgressView().controlSize(.small) }
                    Button("刷新") { device.refresh() }.disabled(!device.enabled || device.busy)
                }
                if device.enabled,device.permissionRequired {
                    HStack {
                        Button("允许访问外设…") { device.authorize() }
                        Button("打开输入监控设置…") { device.openPermissions() }
                    }
                    Text("在 macOS 的「输入监控」中允许 APT，然后点刷新。普通打字和语音输入仍可正常使用。").font(.system(size:12)).foregroundStyle(.secondary)
                }
                if device.ready {
                    if let battery=device.battery { LabeledContent("电量",value:"\(battery)%") }
                    if !device.firmware.isEmpty { LabeledContent("固件",value:device.firmware) }
                }
            } header: { Text("Ulanzi Vibe Key AU05") } footer: {
                Text("将原装 USB 接收器插入 Mac，长按 AU05 右侧电源键 3 秒开机。设备与接收器出厂已配对，连接成功后接收器灯常亮。APT 自动识别；待机时按一下任意键唤醒。").font(.system(size:12))
            }
            APTSettingsSection {
                LabeledContent("语音键",value:VoiceBinding.label+" · 按住说话，松开识别")
                LabeledContent("记忆键",value:MemoryBinding.label+" · 查找／填入")
                LabeledContent("取消键",value:"Esc")
                LabeledContent("旋钮",value:"左转 ↑ · 右转 ↓ · 按下 Tab")
                HStack {
                    Button("将 APT 按键保存到 AU05") { device.configure() }.buttonStyle(.borderedProminent)
                    Button("恢复原按键配置") { device.configure(restore:true) }.disabled(!device.hasBackup)
                }.disabled(!device.ready || !device.awake || device.busy)
            } header: { Text("按键与旋钮") } footer: {
                Text("保存前备份原配置，写入后逐键读回核对。APT 快捷键改变后，需再次保存到 AU05。").font(.system(size:12))
            }
            APTSettingsSection {
                Button("将 AU05 设为输入麦克风") { device.useMicrophone() }.disabled(!device.connected || VoiceInput.shared.busy)
                if let noise=device.noise {
                    Picker("麦克风降噪",selection:Binding(get:{ device.noise ?? noise },set:{ device.setNoise($0) })) {
                        Text("关闭").tag(0); Text("低").tag(1); Text("中").tag(2); Text("高").tag(3)
                    }.disabled(!device.awake || device.busy)
                }
                if let sleep=device.sleep {
                    Picker("待机后自动关机",selection:Binding(get:{ device.sleep ?? sleep },set:{ device.setSleep($0) })) {
                        Text("关闭").tag(UInt32(0))
                        ForEach(1..<5) { hours in Text("\(hours) 小时").tag(UInt32(hours*3600)) }
                        if ![UInt32(0),3600,7200,10800,14400].contains(sleep) { Text("当前：\(sleep) 秒").tag(sleep) }
                    }.disabled(!device.awake || device.busy)
                }
            } header: { Text("麦克风与休眠") } footer: {
                Text("切换麦克风会更改 macOS 的系统输入设备，也会影响其他使用默认麦克风的 App。降噪和关机时间选择后立即写入设备。").font(.system(size:12))
            }
            APTSettingsSection {
                Toggle("灯光跟随 APT",isOn:Binding(get:{ device.lights },set:{ device.setLights($0) })).disabled(!device.lightReady || device.busy)
                Text("录音就绪：常亮\n识别、整理或查找记忆：呼吸\n等待填入：常亮\n成功：短亮\n失败：闪烁").font(.system(size:12)).foregroundStyle(.secondary)
                Button("测试灯光") { device.testLights() }.disabled(!device.awake || !device.lightReady || device.busy)
            } header: { Text("灯光反馈") } footer: {
                Text("第一版使用整机灯效。关闭联动或退出 APT 后恢复连接时的灯光配置；颜色和各按键独立灯效需进一步验证。").font(.system(size:12))
            }
            if !device.note.isEmpty {
                APTSettingsSection { Text(device.note).font(.system(size:12)).fixedSize(horizontal:false,vertical:true).textSelection(.enabled) }
            }
        }
    }
}

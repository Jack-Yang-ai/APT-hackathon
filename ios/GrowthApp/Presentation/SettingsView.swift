import SwiftUI
import GRDB

/// 设置。设计:`settings-v1.html`(四组:记忆 / 录音与转写 / 隐私与数据 / 关于)。
///
/// ⚠️ **这里只放真接上了的项。**
///
/// PRD §4.1.10 给 M1 列了六组十几项(自动结束时长、电量阈值、存储上限、音频保留期、
/// 场次分级开关、Obsidian 镜像…)。实测这些**几乎都没有后端**:
/// `grep` 全仓找不到 retention / battery / grade 开关的任何实现。
///
/// 把它们摆成开关,用户拨一下什么都不会发生 —— 那比没有这一屏更糟:
/// 他会以为「我已经把音频保留期设成 7 天了」,而音频一直堆着。
/// 所以没接上的一律不画,`TASKS.md` 里记着欠哪些。
struct SettingsView: View {
    @ObservedObject var vm: RecordingViewModel

    @State private var unconfirmed = 0
    @State private var localBytes: Int64 = 0
    @State private var sessionCount = 0
    @State private var confirmWipe = false
    @State private var note: Notice?
    @State private var proxyURL = ProxySettings.baseURL?.absoluteString ?? ""
    @State private var proxyToken = ""
    @State private var proxyHealth = "还没探"
    @State private var recentEvents: [ProcessingEvents.Event] = []
    /// 时间轴体检的结果。**nil = 还没查成**(库没打开),不是「没问题」——
    /// 两者在界面上必须说成不同的话,见下面那一组。
    @State private var timeline: TimelineAudit.Check?
    /// 正在重整。**这不是防手抖的装饰**:重整会落一版新转写,而新版的纪要要重新抽,
    /// 那一步是**花钱**的。连点两下就是白付一次。
    @State private var repairingTimelines = false

    var body: some View {
        ZStack {
            DS.C.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("你的记录默认只用于整理这一个 Second Brain。")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.C.sub)
                        .padding(.bottom, 20)

                    group("记忆") {
                        NavigationLink { MyVoiceView(vm: vm) } label: {
                            row("我的声音",
                                value: "只识别本人",
                                chevron: true)
                        }.buttonStyle(.plain)
                    }

                    group("录音与转写") {
                        NavigationLink { ProcessingRecoveryView(vm: vm) } label: {
                            row("处理状态与重试", value: nil, chevron: true)
                        }.buttonStyle(.plain)
                        NavigationLink { ImportView(vm: vm) } label: {
                            row("导入录音", value: nil, chevron: true)
                        }.buttonStyle(.plain)
                    }

                    group("隐私与数据") {
                        row("本地录音占用", value: Self.humanBytes(localBytes), chevron: false)
                        row("库里的场次", value: "\(sessionCount) 场", chevron: false)
                        Button { confirmWipe = true } label: {
                            row("清除全部录音", value: nil, chevron: true, danger: true)
                        }.buttonStyle(.plain)
                    }

                    group("云代理") {
                        HStack {
                            Text("地址").font(.system(size: 15)).foregroundStyle(DS.C.ink)
                            Spacer()
                            TextField("https://…workers.dev", text: $proxyURL)
                                .font(.system(size: 13).monospaced())
                                .foregroundStyle(DS.C.sub)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                // ⚠️ 不指定 URL 键盘的话,中文输入法会把 `.` 变成 `。`——
                                // 实测粘出来是 `growth-proxy。workers。dev`,而它长得几乎一样,
                                // 报错只会是「探不通」,没人会想到是标点。
                                .keyboardType(.URL)
                        }
                        .padding(.horizontal, 12).frame(minHeight: 48)

                        HStack {
                            Text("门禁令牌").font(.system(size: 15)).foregroundStyle(DS.C.ink)
                            Spacer()
                            // ⚠️ **令牌不显示已存的值,只显示存没存。**
                            // 显示出来等于把它摆在任何一个能看到屏幕的人面前,
                            // 而它的用途就是「有了它就能烧转写额度」。
                            SecureField(ProxySettings.token == nil ? "粘贴令牌" : "已存(重填可覆盖)",
                                        text: $proxyToken)
                                .font(.system(size: 13))
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.asciiCapable)
                        }
                        .padding(.horizontal, 12).frame(minHeight: 48)

                        Button { saveProxy() } label: {
                            row("保存并探活", value: proxyHealth, chevron: false)
                        }.buttonStyle(.plain)
                    }

                    // ⚠️ **这一组也是验收仪器。** 它查的是一件**运行时什么都不发生**
                    // 的错:转写行落在场次之外(2026-08-18 真机上 7 场里有 6 场,
                    // 偏移精确等于 `块号 × 300 秒`)。BUG 已经修了(M1-13a),
                    // 而当时是「不是专门去查的」才撞见的 —— 缺的从来不是那个修复,
                    // 是**一个会自己发现它的东西**。见 `TimelineAudit` 的文件注释。
                    group("时间轴体检") {
                        if let t = timeline {
                            // 🔴 **0 场也要说话。** 什么都不显示和「压根没查」
                            // 在屏幕上长得一模一样,而后者是这条缺口本身的形状。
                            if t.findings.isEmpty {
                                row("没有场次的时间轴对不上", value: nil, chevron: false)
                            } else {
                                ForEach(t.findings, id: \.sessionID) { f in
                                    row("场次 \(f.sessionID)",
                                        value: "行落到 \(f.maxLineEndMs / 1000) 秒,"
                                             + "这一场只有 \(f.durationMs / 1000) 秒",
                                        chevron: false)
                                }
                                Button { repairTimelines() } label: {
                                    // 代价**按之前**说,不是按之后:重整本身不重新转写
                                    // (零花费),但新版的纪要要重新抽,那一步花钱。
                                    row("重整这 \(t.findings.count) 场",
                                        value: repairingTimelines ? "重整中…" : "纪要要重新出一份",
                                        chevron: true)
                                }
                                .buttonStyle(.plain)
                                .disabled(repairingTimelines)
                            }
                            // 「没查」与「查过了没问题」分开说 —— 前者是「不知道」。
                            if !t.unauditable.isEmpty {
                                row("另有 \(t.unauditable.count) 场没查",
                                    value: "时长解析不出来", chevron: false)
                            }
                        } else {
                            row("查不了 —— 主库没打开", value: nil, chevron: false)
                        }
                    }

                    // ⚠️ **这一组是验收仪器,不是功能。**
                    // 没有它,「后台处理」无法被证明:打开 App 看到出稿了,
                    // 分不清是后台干完的还是「我一打开它才开始干」。
                    // 带上时间戳与触发源,「凌晨 3:14 · 后台唤醒」才是可检验的事实。
                    group("最近处理") {
                        if recentEvents.isEmpty {
                            row("还没有记录", value: nil, chevron: false)
                        } else {
                            ForEach(Array(recentEvents.enumerated()), id: \.offset) { _, e in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(e.trigger)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(e.trigger == "前台" ? DS.C.dim : DS.C.brand)
                                        Spacer()
                                        Text(Self.shortTime(e.at))
                                            .font(.system(size: 12).monospaced())
                                            .foregroundStyle(DS.C.dim)
                                    }
                                    Text(e.outcome)
                                        .font(.system(size: 13))
                                        .foregroundStyle(DS.C.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                    // 🔴 **`detail` 一直存着,却从来没上过屏。**
                                    // 「为什么失败」全在这一行里(云代理没配 / 一块音频都没有 /
                                    // 报文看不懂),不画它的话三种原因在界面上长得一模一样。
                                    // 这里是设置页,给的是原文 —— 首页卡上仍然只说人话。
                                    if let d = e.detail, !d.isEmpty {
                                        Text(d)
                                            .font(.system(size: 11))
                                            .foregroundStyle(DS.C.dim)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    group("关于") {
                        HStack(spacing: 10) {
                            Image("AptLogo").resizable().scaledToFit()
                                .frame(width: 30, height: 30).accessibilityHidden(true)
                            Text("APT").font(.headline).foregroundStyle(DS.C.ink)
                        }.padding(.horizontal, 12).frame(minHeight: 52)
                        row("版本", value: Self.version, chevron: false)
                        row("云代理", value: "见 worker/README.md", chevron: false)
                    }

                    if let note {
                        Text(note.text)
                            .font(.system(size: 13))
                            .foregroundStyle(note.isError ? DS.C.danger : DS.C.dim)
                            .padding(.top, 16)
                    }

                    // 没接上的**说出来**,而不是画成一排拨不动的开关。
                    // ⚠️ **这句话要跟着实现走。** 2026-08-17 自动结束接上了
                    // (`AutoStopPolicy`),阈值仍钉死在 2 小时、还不能调 ——
                    // 所以从「还没接上」里挪出来单说,而不是留在名单里当假话。
                    Text("自动结束:静音超过 \(AutoStopPolicy.silenceMs / 3_600_000) 小时会自己收尾。"
                       + "阈值暂时不能改,等真实使用数据回填。")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.C.dim)
                        .padding(.top, 24)

                    Text("还没接上的:电量保护 · 存储上限 · 音频保留期 · "
                       + "场次分级开关 · 导出 · Obsidian 镜像。"
                       + "后端还没有,所以这一屏先不摆。")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.C.dim)
                        .padding(.top, 10)
                }
                .padding(.horizontal, DS.S.side)
                .padding(.top, 12)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        // ⚠️ 删录音是**不可逆**的,而且删的是「一次没录上就永远补不回来」的东西。
        // 二次确认不是礼貌,是唯一的挽回机会。
        .alert("清除全部录音?", isPresented: $confirmWipe) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { wipe() }
        } message: {
            // ⚠️ **这段文案与 `AudioWipe` 的行为是同一份契约的两半。**
            // 它原来说「账本留着」,而 `wipe()` 删的是 `recordings/` 下每一项 ——
            // 账本就在里面。文案在按下去的那一刻就是假的,而账本没了会让
            // 在跑的场次被判「一块音频都没有」并标死。现在两边对上了。
            Text("会删掉本机所有音频文件(\(Self.humanBytes(localBytes)))。"
               + "录音账本、纪要与转写都留着,不受影响。这一步撤不回来。\n"
               + "⚠️ 还没转写完的场次会缺音频 —— 它们会以「只保留了文字记录」收场,"
               + "逐字稿里留占位行。")
        }
    }

    /// 存配置并立刻探一次活。
    ///
    /// **存完不探等于没存** —— 地址打错、令牌贴串(实测发生过:复制 StepFun 密钥时
    /// 剪贴板被覆盖,令牌落成了另一个 92 字符的串)在设置页是看不出来的,
    /// 要等下一次录音处理失败才发现,而那时用户已经以为配好了。
    private func saveProxy() {
        // 全角标点纠回半角。键盘类型只挡新输入,**粘贴进来的照样会带** ——
        // 而 `growth-proxy。workers。dev` 和正常地址长得几乎一样,
        // 报错只会是「探不通」,没人会想到去数标点。
        let trimmed = proxyURL
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: ":", with: ":")
            .replacingOccurrences(of: "/", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            proxyHealth = "地址不像个网址"
            return
        }
        ProxySettings.baseURL = url

        if !proxyToken.isEmpty {
            // 令牌是**粘贴**进来的,而剪贴板什么都可能带进来。
            // 首尾空白直接剪掉(复制时多选了一格换行是最常见的一种)。
            let cleaned = proxyToken.trimmingCharacters(in: .whitespacesAndNewlines)
            // ⚠️ 非 ASCII 必须当场拦。HTTP 头值只能是 ByteString,中文标点混进来之后
            // 请求头会被悄悄搞坏,而报出来的是「令牌不对」—— 没人会想到去数字符。
            // (URL 那栏挡的是同一类问题的另一半:全角 `。`)
            guard cleaned.allSatisfy({ $0.isASCII }) else {
                proxyHealth = "令牌里有非 ASCII 字符 —— 多半是粘贴时带进了中文标点"
                return
            }
            ProxySettings.token = cleaned
            proxyToken = ""
        }

        proxyHealth = "探活中…"
        Task {
            do {
                // ⚠️ **带着令牌探。** `/health` 本身不要门禁,所以不带令牌的探活
                // 只能证明「云代理那边存了个令牌」,**证明不了你填的这个对** ——
                // 贴错的话会一路绿到第一次真上传才 401,而那时你早就以为配好了。
                let h = try await ProxyClient.health(baseURL: url, token: ProxySettings.token)
                let ok = (h["ok"] as? Bool) == true
                let hasKey = (h["hasKey"] as? Bool) == true
                let hasLLM = (h["hasLLMKey"] as? Bool) == true
                let hasToken = (h["hasClientToken"] as? Bool) == true
                // nil = 这个云代理还没部署带 tokenOK 的那版,**说「没验」而不是当成对**
                let tokenOK = h["tokenOK"] as? Bool
                await MainActor.run {
                    // 逐项报,不报一句「正常」—— 缺哪一样,该做的事完全不同。
                    if !ok || !hasKey || !hasLLM || !hasToken {
                        proxyHealth = "通了但没配全:转写钥匙 \(hasKey ? "有" : "无")"
                            + " · 抽取钥匙 \(hasLLM ? "有" : "无") · 门禁 \(hasToken ? "有" : "无")"
                    } else if tokenOK == false {
                        proxyHealth = "令牌不对 —— 和云代理上那个对不上"
                    } else if tokenOK == nil {
                        proxyHealth = "通了(令牌没验:云代理是旧版)"
                    } else {
                        proxyHealth = "通了,令牌也对"
                    }
                }
            } catch {
                await MainActor.run { proxyHealth = "探不通:\(error)" }
            }
        }
    }

    // MARK: - 零件

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(DS.C.dim)
            .padding(.bottom, 8)
        VStack(spacing: 0) { content() }
            .background(DS.C.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.C.line, lineWidth: 1))
            .padding(.bottom, 20)
    }

    private func row(_ title: String, value: String?, chevron: Bool,
                     danger: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(danger ? DS.C.danger : DS.C.ink)
            Spacer()
            if let value {
                Text(value).font(.system(size: 13)).foregroundStyle(DS.C.dim)
            }
            if chevron {
                Text("›").font(.system(size: 17)).foregroundStyle(DS.C.dim)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    // MARK: - 数据

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    /// 真去量盘,不是估的。
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func humanBytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    private var recordingsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings")
    }

    /// `2026-08-14T03:14:07+08:00` → `08-14 03:14`。
    /// **要到分钟** —— 验收时要拿它和「我什么时候打开的 App」比,只有日期没用。
    static func shortTime(_ iso: String) -> String {
        guard iso.count >= 16 else { return iso }
        let s = Array(iso)
        return "\(String(s[5..<10])) \(String(s[11..<16]))"
    }

    private func refresh() {
        localBytes = Self.directorySize(recordingsRoot)
        guard let db = vm.database else { return }
        recentEvents = (try? ProcessingEvents.recent(limit: 8, in: db)) ?? []
        let counts = try? db.read { db -> (Int, Int) in
            // 🔴 **「待确认」只有一个定义:`PeopleProjection.pendingSpeakers`。**
            //
            // 这里原先自己写了一份 SQL(总键数 − 用户确认过的键数)。它和投影层
            // 差在一处**不是理论上的**:投影层会丢掉「整键的行全是空洞行/抹除行」
            // 的键(`is_gap = 0 AND redacted = 0`,空则跳过),这里不会 ⇒
            // 那种数据下**设置页比确认页多报几个**,而两边都「跑得通」。
            //
            // ⚠️ M1-11 收口时我在两处写下「现在只有一个定义」,而这个第三消费方
            // 当时就漏了 —— 那句话写下的当天就是假的。留这段是为了让下一个人
            // 知道**这里曾经是第二个真相源**,别再写回去。
            (try PeopleProjection.pendingSpeakers(in: db).count,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0)
        }
        (unconfirmed, sessionCount) = counts ?? (0, 0)
        // 查不成就留 nil —— 上面那一组会说「查不了」,而不是画成「没问题」。
        timeline = try? TimelineAudit.check(in: db)
    }

    /// 把体检报出来的那几场一次重整。
    private func repairTimelines() {
        guard let findings = timeline?.findings, !findings.isEmpty,
              !repairingTimelines else { return }
        repairingTimelines = true
        Task { @MainActor in
            let r = await vm.repairTimelines(findings)
            repairingTimelines = false
            // 🔴 **两个数都报。** 只报成功数会让人以为全好了,而没修好的那几场
            // 需要的处置完全不同(没有报文 ⇒ 只能重转写,要花钱;账本没了 ⇒
            // 重转写也救不回来)。原因逐场带出来,不吞成一句「有几场没成」。
            if r.failed.isEmpty {
                note = .info("重整好了 \(r.fixed.count) 场。这几场的纪要要重新出一份。")
            } else {
                note = .error("好了 \(r.fixed.count) 场,没修好 \(r.failed.count) 场 —— "
                            + r.failed.map { "场次 \($0.0):\($0.1)" }
                                .joined(separator: ";"))
            }
            refresh()
        }
    }

    /// 只删音频文件,**不动库**。
    ///
    /// 纪要、转写、判断都是「删了就再也回不来」的东西,而音频是可以接受丢的那一半
    /// (它已经转写完了)。把两件事绑在一个按钮上,用户为了腾空间会顺手把纪要也删掉。
    private func wipe() {
        // 手表场次尚未收尾时,先结束并同步,避免清掉还要转写的音频。
        guard !vm.watchSessionOpen else {
            note = .error("手表录音尚未结束，请先在手表结束并同步，再清除音频。")
            return
        }
        do {
            // **账本不跟着删** —— 见 `AudioWipe` 的注释:它是场次的真相源,
            // 而且一天几 KB,为省空间删它是纯亏。
            let r = try AudioWipe.run(root: recordingsRoot)
            note = .info("删了 \(r.filesDeleted) 个音频文件,腾出 \(Self.humanBytes(r.bytesFreed))。"
                       + "\(r.ledgersKept) 份录音账本、纪要与转写都还在。")
            refresh()
        } catch {
            // 删不掉要说出来。默默失败的话用户以为空间腾出来了,而它还占着。
            note = .error("没能全部删掉:\(error)")
        }
    }
}

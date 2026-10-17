import Foundation

/// 云代理的客户端(M1-4)。
///
/// ## 为什么密钥不在这里
///
/// ASR 的密钥**只在云代理上**,手机永远不直接调 StepFun —— App 可以被解包,
/// 密钥随包发出去就等于公开。手机侧只有一个门禁令牌(`X-Growth-Token`),
/// 它**也不进版本库**:由用户在设置里粘一次,存 Keychain。
///
/// ⚠️ 令牌写死在代码里、或放进 `Info.plist`,都等于随包发出去。
/// Keychain 是唯一一个「装进去之后 `git` 看不见、解包也拿不到」的地方。
enum ProxyClient {

    struct Config: Equatable {
        let baseURL: URL
        let token: String
    }

    enum Failure: Error, CustomStringConvertible {
        case notConfigured
        case http(status: Int, body: String)
        case badResponse(String)

        var description: String {
            switch self {
            case .notConfigured:
                return "云代理还没配 —— 去设置里填地址与令牌"
            case .http(let s, let b):
                // ⚠️ 非 2xx 的正文**必须带出去**。旧仓踩过:只报「502 Bad Gateway」,
                // 而真因(api key 是 undefined)就写在正文里,被扔了。
                return "云代理返回 \(s):\(b.prefix(300))"
            case .badResponse(let w):
                return "云代理的回复看不懂:\(w)"
            }
        }
    }

    /// 轮询的三种结果。
    ///
    /// ⚠️ **`pending` 与 `failed` 必须分开。** 云代理那边把 `status: FAILED`
    /// 翻成了非 2xx 正是为了这个 —— 合成一种的话,一个永久失败的作业会被
    /// 当成「还在跑」无限轮询下去,而用户看到的是一直「整理中」。
    enum QueryResult: Equatable {
        /// 上游**明确说**还在跑。
        case pending
        /// 🔴 报文看不懂。按 pending 处理(不敢当成功),**但必须留痕**。
        ///
        /// 这一档是 2026-08-17 加的。原来「看不懂」和「还在跑」共用 `.pending`,
        /// 于是报文形状一变、或者字段名传错,结果就是**永远还在跑** ——
        /// 而任务表、界面、日志全都一切正常。实测:一段几十秒的音频提交十一分钟、
        /// 问过四次,状态纹丝不动,而没有任何地方能告诉你为什么。
        ///
        /// 「不敢当成功」是对的(当成功会冻结一份空的终态转写),
        /// 但**不敢 ≠ 不说**。
        case unknown(body: String)
        case done(rawJSON: String)
        case failed(reason: String)
    }

    // MARK: - 两个 session

    /// 🔴 **`URLRequest.timeoutInterval` 拦不住卡住的请求 —— 它是「空闲超时」。**
    ///
    /// 只要连接上还断断续续来字节,那个 30 秒的计时器就一直被重置;
    /// 而 URLSession 在连接被断时还会自己重连重试,计时器跟着从头开始。
    /// 2026-08-18 真机实测:一次 `/asr/submit` **挂了约半小时**才报
    /// `-1001 请求超时`(编排的上一拍 04:27:48,下一拍 04:58:05),
    /// 而这条链上写着「别无限等……卡住不如失败」的那道闸,从头到尾没响过。
    ///
    /// 总时长的硬上限**只能设在 session 上**(`timeoutIntervalForResource`),
    /// `URLRequest` 上没有这一项。所以这里自己造 session,不再用 `.shared`
    /// (`.shared` 的资源超时是 7 天,等于没有)。
    ///
    /// 两个而不是一个:抽取是「每场一次的长输出」,推理档跑几分钟是正常的;
    /// 而提交/查询/探活都该是秒级。用同一个上限的话,要么把抽取掐死,
    /// 要么让提交继续挂半小时。
    static let quick: URLSession = make(request: 30, resource: 90)

    /// 抽取与提问用。
    ///
    /// ⚠️ **这里的 `request: 180` 当前不生效于任何一条真实路径**(对抗审查查实):
    /// `chat` / `extract` 都在请求上覆盖了 `timeoutInterval`(60 / 180),
    /// 而唯一不覆盖的 `upload` **在生产里没有调用点** —— 真上传走
    /// `BackgroundUploadCenter` 的后台 session。留着是因为资源上限(300)有用。
    ///
    /// ⚠️ §4.7.3 那句「提问首字 ≤3 秒」**在代码里没有执行者**:`AskViewModel`
    /// 调 `chat` 时不传 `timeout`,吃的是默认 60 秒。那是**口径,不是实现** ——
    /// 写在这儿免得下一个人以为它已经被守住了。
    static let long: URLSession = make(request: 180, resource: 300)

    private static func make(request: TimeInterval, resource: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = request
        c.timeoutIntervalForResource = resource
        // 没网就当场失败,不要排队等网络回来 —— 排队等的话这一拍会挂在这儿,
        // 而任务表上什么都不会发生。失败是有人管的(退避重试),挂着没有。
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    // MARK: - 两个口

    // ~~`upload(fileURL:key:config:session:)`~~ **2026-08-19 删掉(M1-31)**。
    // 它是 M1-4 早期那版**前台上传**的遗留,全仓零调用点(测试也没有)。
    // 真上传走 `BackgroundUploadCenter` 的后台 session。
    //
    // 🔴 **为什么死代码要删而不是留着**:本仓刚因为死代码吃过亏 ——
    // `BackgroundTransport` 是**死代码且跑起来就炸**(给后台 session 的 uploadTask
    // 传 completion handler,iOS 明确不允许),留着的唯一作用是**让人以为那条路还能走**。
    // ⚠️ `long` 那个 session 保留:`extract` / `chat` 在用。

    /// 提交转写。返回远端 task_id。
    ///
    /// ⚠️ **这一步花钱。** 调用方必须先过 `ASRJobStore.claim` 的去重 ——
    /// 编排会被重放很多遍,而这个函数自己不知道「这一块是不是已经提交过了」。
    static func submit(key: String, seconds: Int, config: Config,
                       session: URLSession = ProxyClient.quick) async throws -> String {
        var req = request(config, path: "/asr/submit")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["key": key, "seconds": seconds])
        let (data, resp) = try await session.data(for: req)
        let body = try ok(data, resp)
        guard let id = (json(body)?["task_id"]) as? String else {
            throw Failure.badResponse("submit 没给 task_id:\(body.prefix(200))")
        }
        return id
    }

    /// 查结果。
    ///
    /// ⚠️ **「HTTP 200」不等于「成功」。** 实测:载荷不对时提交返回 200 + task_id,
    /// 而失败要到这一步才以 `{"status":"FAILED",…}` 出现。云代理已经把它翻成非 2xx,
    /// 这里再把非 2xx 翻成 `.failed` —— 不给调用方把它当成功的机会。
    static func query(remoteID: String, config: Config,
                      session: URLSession = ProxyClient.quick) async throws -> QueryResult {
        var req = request(config, path: "/asr/query")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["task_id": remoteID])

        let (data, resp) = try await session.data(for: req)
        let body = String(data: data, encoding: .utf8) ?? ""
        guard let http = resp as? HTTPURLResponse else {
            throw Failure.badResponse("不是 HTTP 回复")
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failed(reason: "\(http.statusCode):\(body.prefix(300))")
        }
        return classify(body: body)
    }

    /// 把查询回复分档。**纯函数** —— 这一层的判据是踩出来的、还会变,
    /// 拆出来才能拿**真实抓到的报文**去测,而不是每改一次判据就跑一次真端点。
    static func classify(body: String) -> QueryResult {
        // 🔴 **完成判定看 `result` 出现,不看 status —— 这个接口压根没有 SUCCESS 那种终态。**
        //
        // 2026-08-17 实测:五个任务全返回 `{"duration":270.14,"result":[{}]}`,
        // 一个 `status` 字段都没有。原来的实现等 `status == "SUCCESS"`,于是
        // **永远轮询下去**,而任务表、界面、日志全都一切正常。
        //
        // 正确判据三天前就写在 `docs/evidence/p4a/run_asr_file.py` 的文档字符串里
        // (那是 P4a 真跑通过的参考实现):「完成判定看 result 字段出现,
        // 不是等 status=SUCCESS(压根没有这个终态)」。M1-4 实现时没照它做。
        let root = json(body) ?? [:]
        let d = (root["data"] as? [String: Any]) ?? root

        // 先判失败:字段存在时它才有意义,所以放在 result 之前会误伤
        // 「已完成」的回复(完成时根本没有 status)。
        let status = (d["status"] as? String)?.uppercased() ?? ""
        if ["FAIL", "ERROR", "BLOCK"].contains(where: status.contains) {
            return .failed(reason: body)
        }
        // `result` 是**数组**(每块一个),不是字典 —— 出现即终态。
        // 出现但内容为空是**真实的一种终态**(「转完了,一个字都没有」),
        // 不能当成还在跑:当成还在跑就退回那个永远轮询的洞里。
        if let r = d["result"], !isEmpty(r) { return .done(rawJSON: body) }
        // 既没失败也没 result:上游还在算。
        if d["result"] != nil || !status.isEmpty { return .pending }
        // 连 result 键都没有、也没 status —— 报文形状可能又变了,留痕。
        return .unknown(body: body)
    }

    /// `result` 到底算不算「出现了」。参考实现用的是 Python 的真值判断
    /// (`"result" in d and d["result"]`),这里照同一口径:
    /// `nil` / 空数组 / 空字典都不算。**注意 `[{}]` 算** —— 它是「转完了但没内容」,
    /// 是一种真实终态,不是「还没好」。
    private static func isEmpty(_ v: Any) -> Bool {
        switch v {
        case let a as [Any]:            return a.isEmpty
        case let m as [String: Any]:    return m.isEmpty
        case is NSNull:                 return true
        default:                        return false
        }
    }

    /// 抽取。送 prompt,拿模型正文回来。
    ///
    /// ⚠️ **这一步花钱,而且比转写一次贵得多。** 调用方必须先过
    /// `ExtractionRunner` 的 `summaries` 去重 —— 编排会被重放很多遍,
    /// 而这个函数自己不知道「这份转写是不是已经抽过了」。
    ///
    /// **模型不由这里选**:只报场景,云代理按 `SCENE_ROUTES` 决定用哪个模型。
    /// 手机选模型意味着换模型要发一版 App,而降本必须能当天生效。
    ///
    /// 超时给 180 秒:推理档一次要跑很久,而这里超时就是**钱花了、结果丢了**。
    /// 30 秒(其余接口那个值)在这条路上是错的。
    static func extract(scene: String = "extract", prompt: String, config: Config,
                        session: URLSession = ProxyClient.long) async throws -> String {
        try await chat(scene: scene, messages: [["role": "user", "content": prompt]],
                       config: config, timeout: 180, session: session)
    }

    // MARK: - 云端抽取队列(M2-B8)

    /// 把一块渲染好的 prompt **排进云端队列**,立刻返回。
    ///
    /// 🔴 **这是「App 走了就不干活」那件事的解法。** 抽取实测要一两分钟到几分钟,
    /// 而 iOS 会在切后台后很快把 App 挂起 —— 同步等着的那条路**结构上就跑不完**。
    /// 排队之后手机可以睡:Mac daemon(主力)或云端 cron(兜底)会把它跑掉。
    ///
    /// ⚠️ **幂等在云那一侧**(`extract_queue.js` 的 `enqueue`):产物在了说 done、
    /// job 在了说 queued。**不靠手机记得只排一次** —— 手机会重放(重启、后台唤醒),
    /// 而重放一次就是重复付一次抽取的钱。
    /// - Returns: `ticket` —— 取产物时原样带回去的**不透明串**。
    ///
    /// 🔴 **手机不自己拼产物的键**(`M2-审11`,2026-08-24)。键里含一个
    /// 「prompt ‖ 模型 id」的指纹,而指纹只在云那一侧算 —— 两边各算一份
    /// 就是第二个出处(铁律 4),**而对不上时的表现是「永远取不到产物」**:
    /// 场次停在「整理中」,云上产物好好地躺着,两头都不报错。
    ///
    /// ⚠️ ticket **不需要持久化**:每一拍重新 enqueue 都会拿到同一张(幂等),
    /// 所以 App 重启、后台唤醒之后照常取得到。
    static func enqueueExtract(key: Int64, part: Int, prompt: String, config: Config,
                               session: URLSession = ProxyClient.quick) async throws -> String {
        var req = request(config, path: "/extract/enqueue")
        req.httpMethod = "POST"
        req.timeoutInterval = 60          // 只是排队,不是跑模型
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "session": key, "part": part, "prompt": prompt,
        ])
        let (data, resp) = try await session.data(for: req)
        let body = try ok(data, resp)
        guard let ticket = json(body)?["ticket"] as? String, !ticket.isEmpty else {
            // 拿不到 ticket 就取不到产物。**抛而不是给个空串** ——
            // 空串会让下一步去取一个必然不存在的键,而现场与「云端还在跑」一模一样。
            throw Failure.badResponse("排抽取:云端没给 ticket \(body.prefix(200))")
        }
        return ticket
    }

    /// 移出记忆:让云端把这一场的副本删干净(`M2-审12`)。
    ///
    /// 🔴 **手机报清单,云端不推算。** `asr/*` 的键是手机**任务表**的行号,
    /// `extract/*` 的键是手机**转写表**的行号 —— 云端两者都无从反查。
    /// 让云端猜的唯一办法是再存一份「场次 → 对象」的映射,而那是第二个出处
    /// (铁律 4),对不上时的表现是**悄悄漏删**,而漏删的是用户以为已经删掉的东西。
    ///
    /// ⚠️ 云端删完会**回读一遍**;还有剩就返 500 并带回剩下的键 ⇒ 这里抛,
    /// 而调用方**不会**把这一场标成已清除,下一拍还会再来。
    static func purgeSession(sessionID: Int64, transcripts: [Int64], tasks: [Int64],
                             config: Config,
                             session: URLSession = ProxyClient.quick) async throws {
        var req = request(config, path: "/session/purge")
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "session": sessionID, "transcripts": transcripts, "tasks": tasks,
        ])
        let (data, resp) = try await session.data(for: req)
        let body = try ok(data, resp)
        guard json(body)?["ok"] as? Bool == true else {
            throw Failure.badResponse("云端清除:报文形状不认识 \(body.prefix(200))")
        }
    }

    /// 取一块的产物。**还没好返回 nil**,不是抛 —— 「在跑」不是错。
    ///
    /// 云那侧用 202 表示「还在跑」,200 才是好了。两者分开是刻意的:
    /// 混成一个的话,「等着」与「出事了」在手机这头长得一模一样。
    /// 往 R2 放一个对象(经云代理的 `/upload?key=`,与音频块同一条路)。
    ///
    /// 用它推底库快照(`M2-认8` ④b)。音频块走的是后台 `URLSession`(要断点续传、
    /// 要在进程被杀之后继续),快照几十 KB、一天几次,前台一次打完就走。
    static func putObject(key: String, data: Data, config: Config,
                          session: URLSession = ProxyClient.quick) async throws {
        var comp = URLComponents(url: config.baseURL.appendingPathComponent("upload"),
                                 resolvingAgainstBaseURL: false)!
        // 🔴 **不用 `queryItems`,因为 `+` 是 query 里的合法字符,它不会被编码** ——
        // 而服务端 `URLSearchParams.get()` 会把 `+` 解成**空格**(表单编码的历史遗留)。
        // 快照的 key 里正好有一个 `+`(ISO 时间的时区偏移 `+08:00`),于是:
        //   手机发 `…T16-37-00+08-00.json` → Worker 收到 `…T16-37-00 08-00.json`
        //   → 空格不在 `KEY_RE` 的字符集里 → **400 key 缺失或不合法**。
        // 2026-08-25 实测:每一拍都报这个 400,而 `RemoteSnapshotStore` 这条路
        // **一次都没成功过**(R2 上那个唯一的快照是当时手动推的)。
        // ⇒ 后果不是「少一个备份」:`M2-认8` 之后快照是 **Mac 判决的输入**,
        //   推不上去 = Mac 一直拿着旧底库判人,而两端都不报错。
        //
        // ⚠️ key 是**不透明标识**,必须逐字送到。`.urlQueryAllowed` 放行 `+`,
        // 所以从里面把它剔掉,让它编码成 `%2B`。
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        guard let escaped = key.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw Failure.badResponse("key 编码不出来:\(key)")
        }
        comp.percentEncodedQuery = "key=\(escaped)"
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(config.token, forHTTPHeaderField: "X-Growth-Token")
        let (respData, resp) = try await session.upload(for: req, from: data)
        _ = try ok(respData, resp)
    }

    /// 两阶段抽取(`M2-成7`):把**行材料**排进队列,渲染与多次调用都在 Mac 上。
    ///
    /// 🔴 **手机不再渲染 prompt**。两阶段要按候选块切、逐块打标、再按分组抽 ——
    /// 那是一串带控制流的多次调用,不是一个字符串。让手机渲染就得把整套切分算法
    /// 再实现一遍,而那是第二个出处(铁律 4);两份切法漂了之后,
    /// **event 边界与 event_id 会静默对不上**,而 event_id 是下游挂进展的键。
    ///
    /// ⚠️ 与 `enqueueExtract` 同样返回 ticket —— 产物的键含云侧算的指纹。
    static func enqueueExtractLines(key: Int64, part: Int, lines: [[String: Any]],
                                    config: Config,
                                    session: URLSession = ProxyClient.quick) async throws -> String {
        var req = request(config, path: "/extract/enqueue")
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 🔴 **`.sortedKeys` 不能省。** Swift 的 `Dictionary` **没有稳定键序**,
        // 而云端的指纹算在这份 JSON 上 —— 不排序的话**同样的材料每拍一个新指纹**:
        // 手机永远取不到自己那一份产物、每拍重排一次、Mac 每拍**真抽一次(付费)**。
        // 2026-08-25 实测:两份 job 内容完全相同,只有键序不同
        // (`["text","line_id","is_gap",…]` vs `["text","is_gap","line_id",…]`),
        // 当天 `29-0` 攒了 5 个指纹、`30-0` 攒了 4 个,而两端都不报错。
        // ⚠️ 云端也一并改成算**规范形**(那是主防线);这里是第二道。
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "session": key, "part": part, "lines": lines,
        ], options: [.sortedKeys])
        let (data, resp) = try await session.data(for: req)
        let body = try ok(data, resp)
        guard let ticket = json(body)?["ticket"] as? String, !ticket.isEmpty else {
            throw Failure.badResponse("排两阶段抽取:云端没给 ticket \(body.prefix(200))")
        }
        return ticket
    }

    /// 把一场的声纹判决材料排进队列(M2-认8)。幂等在云那侧(产物在 ⇒ done)。
    static func enqueueVoiceprint(payload: Data, config: Config,
                                  session: URLSession = ProxyClient.quick) async throws {
        var req = request(config, path: "/voiceprint/enqueue")
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        let (data, resp) = try await session.data(for: req)
        _ = try ok(data, resp)
    }

    /// 取一场的声纹判决。**还没好返回 nil**(202)—— 「Mac 在判」不是错。
    static func fetchVoiceprintResult(sessionID: Int64, config: Config,
                                      session: URLSession = ProxyClient.quick) async throws -> Data? {
        var req = request(config, path: "/voiceprint/result")
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["session": sessionID])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw Failure.badResponse("取声纹判决:没有 HTTP 响应")
        }
        if http.statusCode == 202 { return nil }
        let body = try ok(data, resp)
        guard let state = json(body)?["state"] as? String else {
            throw Failure.badResponse("取声纹判决:报文形状不认识 \(body.prefix(200))")
        }
        guard state == "done", let content = json(body)?["body"] as? String,
              !content.isEmpty else { return nil }
        return Data(content.utf8)
    }

    static func fetchExtractResult(ticket: String, config: Config,
                                   session: URLSession = ProxyClient.quick) async throws -> String? {
        var req = request(config, path: "/extract/result")
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["ticket": ticket])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw Failure.badResponse("取抽取产物:没有 HTTP 响应")
        }
        if http.statusCode == 202 { return nil }          // 还在跑
        let body = try ok(data, resp)
        guard let state = json(body)?["state"] as? String else {
            throw Failure.badResponse("取抽取产物:报文形状不认识 \(body.prefix(200))")
        }
        guard state == "done" else { return nil }
        guard let content = json(body)?["body"] as? String, !content.isEmpty else {
            // 云那侧只在真有产物时才说 done。说了 done 却没正文 ⇒ 报文形状变了,
            // **抛而不是当成「没内容」** —— 后者会让一份空纪要落库。
            throw Failure.badResponse("云端说抽完了,却没给正文")
        }
        if json(content)?["terminal"] as? Bool == true { throw ActionExtraction.TerminalFailure(message: "个人行动识别失败，请重新识别这场录音。") }
        return content
    }

    /// 多轮报文版。自由提问要 system + 历史 + 这一问,单条 user 装不下。
    ///
    /// ⚠️ **`extract` 走的是同一个函数**,不是另写一份 —— 两份请求构造迟早在
    /// 超时、鉴权头、空正文判据上漂,而漂了不会报错,只会有一条路悄悄变得不一样。
    ///
    /// `timeout` 提出来是因为两个场景的性质不同:抽取是「每场一次的长输出」,
    /// 等 180 秒是值的;提问要的是**首字 ≤3 秒**(§4.7.3),等 180 秒的话
    /// 用户早就退出去了,而那一笔钱照花。
    static func chat(scene: String, messages: [[String: String]], config: Config,
                     timeout: TimeInterval = 60,
                     session: URLSession = ProxyClient.long) async throws -> String {
        var req = request(config, path: "/extract")
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "scene": scene,
            "messages": messages,
        ])
        let (data, resp) = try await session.data(for: req)
        let body = try ok(data, resp)
        guard let content = json(body)?["content"] as? String, !content.isEmpty else {
            // 云代理已经把空正文翻成 502 了,所以走到这里还没有 content
            // 说明报文形状变了 —— **抛,不返回空串**。空串会被下游当成
            // 「模型什么都没说」,而那是要重试的截断,不是「这场没内容」。
            throw Failure.badResponse("extract 没给 content:\(body.prefix(300))")
        }
        return content
    }

    /// 云代理活着吗。**不带令牌也能调** —— 令牌配错时还得能诊断,
    /// 而一个要令牌才肯说话的健康检查在最需要它的时候恰好用不了。
    ///
    /// 但带上令牌时它会多回一个 `tokenOK`:**「探活通了」不等于「令牌是对的」**。
    /// 不带令牌探的话,贴错的令牌会一路绿到第一次真上传才 401,
    /// 而那时用户早就以为配好了(设置页因此总是带着令牌探)。
    static func health(baseURL: URL, token: String? = nil,
                       session: URLSession = ProxyClient.quick) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        if let token { req.setValue(token, forHTTPHeaderField: "X-Growth-Token") }
        req.timeoutInterval = 30
        let (data, resp) = try await session.data(for: req)
        let body = try ok(data, resp)
        guard let j = json(body) else { throw Failure.badResponse(body) }
        return j
    }

    // MARK: - 零件

    private static func request(_ c: Config, path: String,
                                query: [URLQueryItem] = []) -> URLRequest {
        var comp = URLComponents(url: c.baseURL.appendingPathComponent(path.dropFirst().description),
                                 resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comp.queryItems = query }
        var req = URLRequest(url: comp.url!)
        req.setValue(c.token, forHTTPHeaderField: "X-Growth-Token")
        // 别无限等。转写是异步的(提交完就返回),所以这几个调用都该很快;
        // 卡住不如失败 —— 失败会被任务表记下来并退避重试,卡住什么都不会发生。
        //
        // ⚠️ **这一行管的是「空闲多久算超时」,不是「最多花多久」。**
        // 真正的总时长上限在 `quick` / `long` 那两个 session 的
        // `timeoutIntervalForResource` 上 —— 光有这一行时,实测挂过半小时。
        req.timeoutInterval = 30
        return req
    }

    private static func ok(_ data: Data, _ resp: URLResponse) throws -> String {
        let body = String(data: data, encoding: .utf8) ?? ""
        guard let http = resp as? HTTPURLResponse else {
            throw Failure.badResponse("不是 HTTP 回复")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(status: http.statusCode, body: body)
        }
        return body
    }

    private static func json(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

// MARK: - 令牌存哪

/// 云代理的配置。**令牌进 Keychain,地址进 UserDefaults。**
///
/// 地址不是秘密(它公网可达,`/health` 谁都能调);令牌是 —— 有了它就能烧转写额度。
/// 两个放一起会让人以为地址也得藏,反而容易把 Keychain 当通用配置存储用。
enum ProxySettings {

    private static let urlKey = "proxy.baseURL"
    private static let account = "growth.proxy.token"

    static var baseURL: URL? {
        get { UserDefaults.standard.string(forKey: urlKey).flatMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: urlKey) }
    }

    static var token: String? {
        get { Keychain.read(account) }
        set {
            if let v = newValue, !v.isEmpty { Keychain.write(account, v) }
            else { Keychain.delete(account) }
        }
    }

    /// 两样齐了才算配好。缺一样都不能发请求 —— 缺令牌会被云代理 401,
    /// 而 401 看起来像「服务坏了」,实际是「你还没填」。
    static var config: ProxyClient.Config? {
        guard let u = baseURL, let t = token, !t.isEmpty else { return nil }
        return ProxyClient.Config(baseURL: u, token: t)
    }
}

/// 最小 Keychain 包装。只存一个字符串,不做通用抽象。
enum Keychain {

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func write(_ account: String, _ value: String) -> Bool {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: account,
                                kSecValueData as String: Data(value.utf8),
                                // 只在本机、解锁后可读。**不同步到 iCloud** ——
                                // 令牌跟着 iCloud 走等于多了一个泄漏面。
                                kSecAttrAccessible as String:
                                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: account]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }
}

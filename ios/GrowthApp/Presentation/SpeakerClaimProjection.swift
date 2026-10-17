import Foundation
import GRDB

/// 说话人认领的展示模型(`M3-0e`,对 PRD §4.4.10「分档认领」与 `docs/H5施工规格` §2.4)。
///
/// ## 三档,而且**一个新阈值都没有**
///
/// | 档 | 判据 | 界面 |
/// |---|---|---|
/// | 高置信 | 判决核给了 `person`(过 τ **且** 过 2/3 投票) | **直接认领**,来源标「声纹识别」,可就地纠正 |
/// | 中置信 | 过了 τ 但没过 2/3 ⇒ 有 `candidate_person_id` | **预填候选**,出确认卡(「3 段里有 1 段像他」) |
/// | 低 / 未命中 | 连 τ 都没过 ⇒ 没有候选 | 保持「说话人 N」,**不猜** |
///
/// 🔴 两个判据(`TAU` / `MIN_VOTE_RATIO`)都是**实测定过**的,这里一个都不新加 ——
/// `M2-认2` 的教训:阈值要推出来,不能挑出来。
///
/// ## 🔴 试听的音频与屏幕上的字,**不是同一件东西**,不许摆在一起
///
/// `PendingSpeaker.sample` 那条路径的纪律是「**文字与音频必须同一行**」:
/// 用户是照着屏幕上的字去听声音的,对不上他会照着别人的声音确认「这是小李」。
///
/// 而代表片段(`speaker_clips`)是 Mac 按「最长、人声占比最高」挑的**一段声音**,
/// 与任何一行字都没有对应关系。⇒ 它按 PRD §4.4.10 的原文呈现:
/// **「代表片段(可试听)、出现场次与时长」—— 没有文字**。
///
/// 把片段配上某一行的字,就等于亲手制造上面那条纪律要防的事。
enum SpeakerClaimProjection {

    /// 认领的三档。PRD §4.4.10 那张表的闭集。
    enum Tier: String, Equatable {
        case autoClaimed = "已自动认领"
        case prefilled = "预填候选"
        case unknown = "不猜"
    }

    /// 一段可试听的代表片段。**没有文字** —— 见类型注释。
    struct Clip: Equatable, Identifiable {
        let id: Int64
        let r2Key: String
        let durationMS: Int
        let speechRatio: Double
        /// 出现在哪一场。PRD §4.4.10 要「出现场次与时长」。
        let sessionID: Int64
        var seconds: Double { Double(durationMS) / 1000 }
    }

    /// 认领页上的一个待认说话人。
    struct Claim: Equatable, Identifiable {
        let clusterKey: String
        let sessionID: Int64
        /// 这个簇现在挂在哪个人格上(匿名人格也是一个真 `persons` 行)。
        let personID: Int64
        let tier: Tier
        /// 中置信才有:系统猜的是谁。
        let candidatePersonID: Int64?
        /// 「3 段里有 1 段像他」的分子与分母。**两个都要** ——
        /// 只有分子说不出把握,而「1 段像他」在 3 段和在 30 段里完全是两回事。
        let candidateVotes: Int?
        let candidateOf: Int?
        /// 可试听的代表片段(最多 `SpeakerClipPolicy.maxPerSpeaker` 段)。
        let clips: [Clip]

        var id: String { clusterKey }

        /// 界面上那句把握。缺任一半就不说 —— **不拿分子冒充比例**。
        var confidenceText: String? {
            guard let v = candidateVotes, let of = candidateOf, of > 0 else { return nil }
            return "\(of) 段里有 \(v) 段像他"
        }
    }

    /// 认领页。**只列还没被用户确认过的簇** —— 已确认的不该再问一遍。
    static func claims(in db: Database) throws -> [Claim] {
        let rows = try GRDB.Row.fetchAll(db, sql: """
            SELECT v.cluster_key, v.session_id, v.person_id,
                   v.candidate_person_id, v.candidate_votes, v.candidate_of
              FROM voiceprint_clusters v
             ORDER BY v.session_id DESC, v.cluster_key
            """)
        return try rows.map { r in
            let key: String = r["cluster_key"]
            let candidate: Int64? = r["candidate_person_id"]
            // 🔴 档位**从数据推**,不另存一列 `tier`:存了就是同一件事两个出处,
            // 而对不上时界面会对一个系统根本没猜过的人说「是他吗」。
            let named: Bool = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM persons WHERE id = ? AND name IS NOT NULL)
                """, arguments: [r["person_id"] as Int64]) ?? false
            let tier: Tier = named ? .autoClaimed : (candidate != nil ? .prefilled : .unknown)
            return Claim(clusterKey: key, sessionID: r["session_id"], personID: r["person_id"],
                         tier: tier, candidatePersonID: candidate,
                         candidateVotes: r["candidate_votes"], candidateOf: r["candidate_of"],
                         clips: try clips(forCluster: key, in: db))
        }
    }

    /// 一个簇的代表片段。**挑最听得清的几段**:人声占比降序、时长降序。
    /// 口径的唯一出处是 `SpeakerClipPolicy`,这里不另写一个数。
    static func clips(forCluster key: String, in db: Database) throws -> [Clip] {
        try GRDB.Row.fetchAll(db, sql: """
            SELECT id, r2_key, duration_ms, speech_ratio, session_id
              FROM speaker_clips
             WHERE cluster_key = ?
             ORDER BY speech_ratio DESC, duration_ms DESC, id
             LIMIT \(SpeakerClipPolicy.maxPerSpeaker)
            """, arguments: [key]).map {
            Clip(id: $0["id"], r2Key: $0["r2_key"], durationMS: $0["duration_ms"],
                 speechRatio: $0["speech_ratio"], sessionID: $0["session_id"])
        }
    }
}

/// 认领的**写侧动作契约**。🔴 未实现的一律抛,绝不 no-op(§3.2)。
///
/// ⚠️ **三个动作都必须走 `assignSpeaker`**(铁律 3:归属只有一条路可写)。
/// 这里给的是界面调用的形状,实现只能是它的薄封装 —— 直接写 `line_speakers` = 缺陷。
protocol SpeakerClaimWriting {
    /// 「是我 / 是他」—— 接受预填的候选,或用户自己选一个人。
    func claim(cluster key: String, as personID: Int64, now: String) throws
    /// 「不是」—— 否掉候选,簇回到「不猜」态。**不许因此删掉匿名人格**:
    /// 那个人格仍然是一个真实存在的声音,只是还不知道是谁。
    func reject(candidateOf key: String, now: String) throws
    /// 「说不准」—— 明确的不表态。它与「还没看过」是两件事,所以也要落账。
    func defer_(cluster key: String, now: String) throws
}

struct UnimplementedSpeakerClaimWriting: SpeakerClaimWriting {
    struct NotWired: Error, CustomStringConvertible {
        let action: String
        /// ⚠️ 这句会显示给用户,不写任务号(挡着它的是 `M3-B6` / `M3-F3`)。
        var description: String { "认领的「\(action)」还没做出来。" }
    }
    func claim(cluster key: String, as personID: Int64, now: String) throws { throw NotWired(action: "认领") }
    func reject(candidateOf key: String, now: String) throws { throw NotWired(action: "不是他") }
    func defer_(cluster key: String, now: String) throws { throw NotWired(action: "说不准") }
}

extension SpeakerClaimProjection {

    /// 一场的认人**状态说明**(`M2-审21` ③,用户 2026-08-25 拍板「直接显示就行」)。
    ///
    /// 🔴 **这三种在此之前长得一模一样**:界面上都是「什么都没有」,
    /// 而它们要做的事完全不同 —— 一个要等、一个要用户认、一个**根本没有素材可认**。
    enum SessionNote: Equatable {
        /// 还没判(Mac 队列里)。**NULL 就是这一种**,不是「0 段被挡」。
        case notJudged
        /// 判了,而**一段可用的声音都没取到** —— 全被人声门挡下。
        ///
        /// ⚠️ 这不等于「这一场没人说话」:2026-08-25 实测那一场
        /// ASR 转出了 12 行清楚的话,而 VAD 从头到尾一次都没响过(`M2-审21`)。
        /// 所以文案要说的是**「取不到能用来认人的声音」**,不是「没人说话」。
        case nothingUsable(gatedOut: Int)
        /// 判了,取到了段,但一簇都没认出来 ⇒ 那是新声音,走认领。
        case judgedNothingMatched
        /// 判了,有认出来的。
        case matched(clusters: Int)

        /// 界面上那句话。**每一种都说得出「为什么」** —— 这是这条拍板的全部内容。
        var text: String {
            switch self {
            case .notJudged:
                return "还在判这一场的说话人"
            case .nothingUsable(let n):
                return "这一场取不到能用来认人的声音(\(n) 段都没通过人声门)—— "
                     + "转写不受影响,只是认不出是谁"
            case .judgedNothingMatched:
                return "有声音,但都还对不上已知的人 —— 可以在这里认一下"
            case .matched(let n):
                return "认出了 \(n) 个说话人"
            }
        }
    }

    static func sessionNote(_ sessionID: Int64, in db: Database) throws -> SessionNote {
        // 🔴 **先看判没判**:`voiceprint_gated_out IS NULL` 就是没判过。
        // 拿「有没有簇」去推的话,「没判」与「判了但一段都没取到」会合成一种 ——
        // 而那正是这条拍板要拆开的两种。
        guard let gated = try Int.fetchOne(db, sql: """
            SELECT voiceprint_gated_out FROM sessions WHERE id = ?
            """, arguments: [sessionID]) else {
            return .notJudged
        }
        let clusters = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM voiceprint_clusters WHERE session_id = ?
            """, arguments: [sessionID]) ?? 0
        if clusters == 0 && gated > 0 { return .nothingUsable(gatedOut: gated) }
        let named = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM voiceprint_clusters v JOIN persons p ON p.id = v.person_id
             WHERE v.session_id = ? AND p.name IS NOT NULL
            """, arguments: [sessionID]) ?? 0
        return named > 0 ? .matched(clusters: named) : .judgedNothingMatched
    }
}

import Foundation

















enum SpeakerMatch {




























    static let legacyAbsoluteThreshold: Float = 0.640






























































    static let tau: Float = 0.3





    static let tauEpsilon: Float = 1e-6





    static let minSegments = 2






    static let minVoteRatio: Double = 2.0 / 3.0







    struct SegmentScore: Equatable {
        let personID: Int64
        let score: Float

        let runnerUp: Float

        var margin: Float { score - runnerUp }
    }


    enum Verdict: Equatable {
        case matched(personID: Int64, votes: Int, of: Int, confidence: Double)


        case rejected(why: String)
    }



    static func judge(segments: [SegmentScore]) -> Verdict {















        let passing = segments.filter { $0.margin + tauEpsilon >= tau }
        guard !passing.isEmpty else {
            let best = segments.max(by: { $0.margin < $1.margin })
            return .rejected(why: String(
                format: "没有一段拉开差距(最好的一段 第一名 %.3f − 第二名 %.3f = %.3f < τ %.3f)",
                best?.score ?? 0, best?.runnerUp ?? 0, best?.margin ?? 0, tau))
        }
        var tally: [Int64: Int] = [:]
        for s in passing { tally[s.personID, default: 0] += 1 }
        guard let (winner, votes) = tally.max(by: { a, b in


            a.value != b.value ? a.value < b.value
                               : bestScore(of: a.key, in: passing) < bestScore(of: b.key, in: passing)
        }) else {
            return .rejected(why: "没有候选")
        }


        guard passing.count >= minSegments || segments.count == 1 else {
            return .rejected(why: "只有 \(passing.count) 段拉开了差距,不够判"
                                + "(至少要 \(minSegments) 段;全簇 \(segments.count) 段)")
        }
        let ratio = Double(votes) / Double(segments.count)
        guard ratio >= minVoteRatio else {
            return .rejected(why: String(format: "票不够:%d/%d(要 %.0f%%)",
                                         votes, segments.count, minVoteRatio * 100))
        }
        return .matched(personID: winner, votes: votes, of: segments.count,
                        confidence: confidence(votes: votes, of: segments.count))
    }

    private static func bestScore(of person: Int64, in xs: [SegmentScore]) -> Float {
        xs.filter { $0.personID == person }.map(\.score).max() ?? 0
    }










    static func confidence(votes: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return (Double(votes) / Double(total) * 100).rounded() / 100
    }











    static func enforceOnePersonPerSession(
        _ verdicts: [String: Verdict]
    ) -> (kept: [String: Verdict], displaced: [(tag: String, personID: Int64, ratio: Double)]) {
        var best: [Int64: (tag: String, ratio: Double)] = [:]
        for (tag, v) in verdicts.sorted(by: { $0.key < $1.key }) {
            guard case .matched(let pid, let votes, let of, _) = v else { continue }
            let ratio = Double(votes) / Double(of)
            if let cur = best[pid], cur.ratio >= ratio { continue }
            best[pid] = (tag, ratio)
        }
        let winners = Set(best.map { $0.value.tag })

        var kept: [String: Verdict] = [:]
        var displaced: [(tag: String, personID: Int64, ratio: Double)] = []
        for (tag, v) in verdicts {
            guard case .matched(let pid, let votes, let of, _) = v else { kept[tag] = v; continue }
            if winners.contains(tag) { kept[tag] = v; continue }
            let ratio = Double(votes) / Double(of)
            displaced.append((tag, pid, ratio))
            kept[tag] = .rejected(why: String(
                format: "同一场里另一簇更像这个人(本簇票比 %.2f)—— 一场之内一人一簇", ratio))
        }
        return (kept, displaced)
    }
}

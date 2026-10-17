import Foundation


struct Utterance: Equatable, Hashable {
    let startMs: Int
    let endMs: Int
    let speakerID: String

    var durationMs: Int { endMs - startMs }
}

enum MixedLineDetector {

    static let defaultThresholdMs = 300

    struct Hit: Equatable {
        let index: Int
        let maxOverlapMs: Int
    }

    static func detect(_ utterances: [Utterance],
                       thresholdMs: Int = defaultThresholdMs) -> [Hit] {
        let order = utterances.indices.sorted {
            (utterances[$0].startMs, utterances[$0].endMs)
                < (utterances[$1].startMs, utterances[$1].endMs)
        }
        var best: [Int: Int] = [:]           // 原始下标 → 最大重叠毫秒

        for a in 0..<order.count {
            let i = order[a], ui = utterances[i]
            for b in (a + 1)..<order.count {
                let j = order[b], uj = utterances[j]
                if uj.startMs >= ui.endMs { break }
                if ui.speakerID == uj.speakerID { continue }
                let overlap = min(ui.endMs, uj.endMs) - max(ui.startMs, uj.startMs)
                guard overlap > thresholdMs else { continue }
                best[i] = max(best[i] ?? 0, overlap)
                best[j] = max(best[j] ?? 0, overlap)
            }
        }
        return best.keys.sorted().map { Hit(index: $0, maxOverlapMs: best[$0]!) }
    }


    struct CurvePoint: Equatable, Codable {
        let thresholdMs: Int
        let detected: Int
        let truePositives: Int
        let recall: Double
        let falsePositiveRateOfAll: Double
        let falsePositiveRateOfHits: Double
    }

    static func curve(_ utterances: [Utterance], truth: Set<Int>,
                      thresholdsMs: [Int]) -> [CurvePoint] {
        thresholdsMs.map { thr in
            let hits = Set(detect(utterances, thresholdMs: thr).map(\.index))
            let tp = hits.intersection(truth).count
            let fp = hits.subtracting(truth).count
            return CurvePoint(
                thresholdMs: thr,
                detected: hits.count,
                truePositives: tp,
                recall: truth.isEmpty ? 0 : Double(tp) / Double(truth.count),
                falsePositiveRateOfAll: utterances.isEmpty
                    ? 0 : Double(fp) / Double(utterances.count),
                falsePositiveRateOfHits: hits.isEmpty ? 0 : Double(fp) / Double(hits.count))
        }
    }
}

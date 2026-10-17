import Foundation

enum SpeechTrim {

    static let mergeGapSeconds: Double = 30
    static let padSeconds: Double = 2
    static let minRetentionRatio: Double = 0.15

    static let suspiciousEnergyDBFS: Double = -40

    static let energyPercentile: Double = 0.9

    struct Plan: Equatable {
        let intervals: [KeptInterval]
        let ratio: Double
        let fellBack: Bool

        var keptMs: Int { intervals.reduce(0) { $0 + $1.durationMs } }
    }

    static func whole(durationMs: Int) -> Plan {
        Plan(intervals: [KeptInterval(startMs: 0, endMs: durationMs)], ratio: 1, fellBack: true)
    }

    static func plan(of url: URL, vad: SileroVAD, durationMs: Int,
                     mergeGapSeconds: Double = mergeGapSeconds,
                     padSeconds: Double = padSeconds) async throws -> Plan {
        vad.reset()
        var probabilities: [Float] = []
        var energies: [Double] = []
        var carry: [Float] = []
        try await AudioImport.decode(url: url) { chunk in
            carry += chunk
            while carry.count >= SileroVAD.frameSamples {
                let frame = Array(carry.prefix(SileroVAD.frameSamples))
                carry.removeFirst(SileroVAD.frameSamples)
                probabilities.append(try vad.probability(frame: frame))
                energies.append(frameEnergy(frame))
            }
        }
        return plan(speechProbabilities: probabilities, frameEnergies: energies,
                    durationMs: durationMs,
                    mergeGapSeconds: mergeGapSeconds, padSeconds: padSeconds)
    }

    static func plan(speechProbabilities frames: [Float],
                     frameEnergies: [Double] = [],
                     durationMs: Int,
                     mergeGapSeconds: Double = mergeGapSeconds,
                     padSeconds: Double = padSeconds) -> Plan {
        guard durationMs > 0 else { return whole(durationMs: max(durationMs, 0)) }

        let segments = AudioImport.split(speechProbabilities: frames,
                                         gapSeconds: mergeGapSeconds)
        let padMs = Int(padSeconds * 1000)
        var merged: [KeptInterval] = []
        for s in segments {
            let start = max(0, Int(s.startSeconds * 1000) - padMs)
            let end = min(durationMs, Int(s.endSeconds * 1000) + padMs)
            guard end > start else { continue }
            if let last = merged.last, start <= last.endMs {
                merged[merged.count - 1] = KeptInterval(startMs: last.startMs,
                                                        endMs: max(last.endMs, end))
            } else {
                merged.append(KeptInterval(startMs: start, endMs: end))
            }
        }

        let keptMs = merged.reduce(0) { $0 + $1.durationMs }
        let ratio = Double(keptMs) / Double(durationMs)

        if ratio < minRetentionRatio, loudEnoughToDoubtTheVAD(frameEnergies) {
            return Plan(intervals: [KeptInterval(startMs: 0, endMs: durationMs)],
                        ratio: ratio, fellBack: true)
        }
        return Plan(intervals: merged, ratio: ratio, fellBack: false)
    }

    static func frameEnergy(_ frame: [Float]) -> Double {
        frame.reduce(0) { $0 + Double($1 * $1) } / Double(max(frame.count, 1))
    }

    static func loudEnoughToDoubtTheVAD(_ frameEnergies: [Double]) -> Bool {
        guard !frameEnergies.isEmpty else { return true }
        let sorted = frameEnergies.sorted()
        let meanSquare = sorted[min(sorted.count - 1,
                                    Int(Double(sorted.count) * energyPercentile))]
        return 10 * log10(max(meanSquare, 1e-12)) >= suspiciousEnergyDBFS
    }


    static func encode(_ intervals: [KeptInterval]) -> String {
        let pairs = intervals.map { [$0.startMs, $0.endMs] }
        guard let d = try? JSONSerialization.data(withJSONObject: pairs),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }

    static func decode(_ json: String?) -> [KeptInterval]? {
        guard let json, let d = json.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: d) as? [[Int]] else { return nil }
        return pairs.compactMap { $0.count == 2 ? KeptInterval(startMs: $0[0], endMs: $0[1]) : nil }
    }
}

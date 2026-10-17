import Foundation

enum SpeakerCut {

    static let minPieceMs = 800

    static func split(_ line: ASRLine, atMs cutMs: Int) -> (ASRLine, ASRLine)? {
        guard !line.words.isEmpty else { return nil }

        guard let pivot = line.words.firstIndex(where: { $0.startMs >= cutMs }),
              pivot > 0, pivot < line.words.count
        else { return nil }                    // 刀口在两端之外 ⇒ 没得切

        let head = Array(line.words[..<pivot])
        let tail = Array(line.words[pivot...])

        let headEnd = head.last!.endMs
        let tailStart = tail.first!.startMs
        guard headEnd - line.startMs >= minPieceMs,
              line.endMs - tailStart >= minPieceMs
        else { return nil }                    // 切出来太短 ⇒ 不切

        return (ASRLine(startMs: line.startMs, endMs: headEnd,
                        text: head.map(\.text).joined(), speaker: nil, words: head),
                ASRLine(startMs: tailStart, endMs: line.endMs,
                        text: tail.map(\.text).joined(), speaker: nil, words: tail))
    }
}


extension SpeakerCut {

    static let windowMs = 1500
    static let stepMs = 250

    static let separationMargin: Float = 0.05

    static func changePoint(in samples: [Float],
                            embed: ([Float]) throws -> [Float]) rethrows -> Int? {
        let rate = AudioImport.sampleRate
        let window = windowMs * rate / 1000
        let step = stepMs * rate / 1000
        guard samples.count >= window * 2 else { return nil }

        var cache: [Int: [Float]] = [:]
        func vector(at start: Int) throws -> [Float] {
            if let v = cache[start] { return v }
            let v = try embed(Array(samples[start..<(start + window)]))
            cache[start] = v
            return v
        }

        var scored: [(ms: Int, separation: Float)] = []
        var t = window
        while t + window <= samples.count {
            let sep = 1 - VoiceprintChain.cosine(try vector(at: t - window), try vector(at: t))
            scored.append((t * 1000 / rate, sep))
            t += step
        }
        guard scored.count >= minCandidates else { return nil }
        let sorted = scored.map(\.separation).sorted()
        let baseline = sorted[sorted.count / 2]
        guard let peak = sorted.last, peak - baseline >= separationMargin else { return nil }

        let plateau = scored.filter { peak - $0.separation <= plateauTolerance }
        return plateau[plateau.count / 2].ms
    }

    static let plateauTolerance: Float = 0.02

    static let minCandidates = 4
}

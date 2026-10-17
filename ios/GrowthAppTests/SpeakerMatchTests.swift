import XCTest
@testable import GrowthApp





final class SpeakerMatchTests: XCTestCase {

    private let me: Int64 = -1
    private let jin: Int64 = 2



    private func seg(_ p: Int64, _ s: Float, _ runnerUp: Float) -> SpeakerMatch.SegmentScore {
        .init(personID: p, score: s, runnerUp: runnerUp)
    }


    private func clear(_ p: Int64) -> SpeakerMatch.SegmentScore { seg(p, 0.70, 0.30) }















    func testASingleSegmentThatClearsTauIsAccepted() {
        let v = SpeakerMatch.judge(segments: [seg(me, 0.99, 0.10)])
        guard case .matched(let p, _, _, _) = v else {
            return XCTFail("一段的簇没判 —— 用户特意录的干净声纹会被挡在比对之外:\(v)")
        }
        XCTAssertEqual(p, me)
    }





    func testOneClearSegmentCannotSpeakForAWholeCluster() {
        let noisy = Array(repeating: seg(me, 0.40, 0.39), count: 39)   // 差距远小于 τ
        let v = SpeakerMatch.judge(segments: [seg(me, 0.99, 0.10)] + noisy)
        guard case .rejected(let why) = v else {
            return XCTFail("40 段里 1 段过 τ 就给整簇安名字了:\(v)")
        }
        XCTAssertTrue(why.contains("不够判") || why.contains("票不够"), why)
    }





    func testAllBelowTauIsRejectedWithTheBestMarginNamed() {
        let v = SpeakerMatch.judge(segments: [seg(me, 0.61, 0.55), seg(me, 0.58, 0.50),
                                              seg(me, 0.60, 0.49)])
        guard case .rejected(let why) = v else { return XCTFail("\(v)") }
        XCTAssertTrue(why.contains("差距"), why)
        XCTAssertTrue(why.contains("0.110"), "没说出最好的那段差距是多少:\(why)")
    }







    func testExactlyAtTauCounts() {
        let s: Float = 0.50
        let v = SpeakerMatch.judge(segments: Array(repeating:
            seg(me, s + SpeakerMatch.tau, s), count: 3))
        guard case .matched(let pid, _, _, _) = v else { return XCTFail("\(v)") }
        XCTAssertEqual(pid, me)
    }






    func testAHighScoreWithNoMarginIsStillRejected() {
        let v = SpeakerMatch.judge(segments: [seg(me, 0.92, 0.90), seg(me, 0.95, 0.94),
                                              seg(me, 0.93, 0.91)])
        guard case .rejected(let why) = v else {
            return XCTFail("分很高但与第二名咬得死紧,这时给谁都是错的:\(v)")
        }
        XCTAssertTrue(why.contains("差距"), why)
    }





    func testAScoreBelowTheRetiredThresholdStillMatchesWhenTheMarginIsWide() {
        XCTAssertLessThan(Float(0.618), SpeakerMatch.legacyAbsoluteThreshold,
                          "这条用例的前提是它低于老线")
        let v = SpeakerMatch.judge(segments: [seg(me, 0.618, 0.30), seg(me, 0.605, 0.28),
                                              seg(me, 0.631, 0.33)])
        guard case .matched(let pid, _, _, _) = v else {
            return XCTFail("差距 0.3 上下却没认出来 —— 判据又退回绝对分了?\(v)")
        }
        XCTAssertEqual(pid, me)
    }





    func testNotEnoughVotesIsRejected() {
        let v = SpeakerMatch.judge(segments: [
            clear(me), clear(me),
            seg(me, 0.40, 0.38), seg(me, 0.35, 0.34), seg(me, 0.30, 0.29),
        ])
        guard case .rejected(let why) = v else { return XCTFail("\(v)") }
        XCTAssertTrue(why.contains("票不够"), why)
    }



    func testOneBadSegmentOnlyCostsOneVote() {
        let v = SpeakerMatch.judge(segments: [
            clear(me), seg(me, 0.72, 0.30), seg(me, 0.69, 0.31), seg(me, 0.71, 0.29),
            seg(me, 0.10, 0.09),
        ])
        guard case .matched(let pid, let votes, let of, let conf) = v else { return XCTFail("\(v)") }
        XCTAssertEqual(pid, me)
        XCTAssertEqual(votes, 4); XCTAssertEqual(of, 5)
        XCTAssertEqual(conf, 0.8, accuracy: 0.001)
    }











    func testTwoSegmentsPointingAtDifferentPeopleIsRejected() {
        let v = SpeakerMatch.judge(segments: [clear(me), seg(jin, 0.90, 0.40)])
        guard case .rejected(let why) = v else {
            return XCTFail("一簇里两段指向不同的人,给谁都是错的:\(v)")
        }
        XCTAssertTrue(why.contains("票不够"), why)
    }


    func testAClearMajorityWins() {
        let v = SpeakerMatch.judge(segments: [clear(me), seg(me, 0.68, 0.31),
                                              seg(jin, 0.90, 0.40)])
        guard case .matched(let pid, let votes, let of, _) = v else { return XCTFail("\(v)") }
        XCTAssertEqual(pid, me)
        XCTAssertEqual(votes, 2); XCTAssertEqual(of, 3)
    }








    func testConfidenceIsTheVoteRatio() {
        XCTAssertEqual(SpeakerMatch.confidence(votes: 3, of: 4), 0.75, accuracy: 0.001)
        XCTAssertEqual(SpeakerMatch.confidence(votes: 5, of: 5), 1.0, accuracy: 0.001)
        XCTAssertEqual(SpeakerMatch.confidence(votes: 0, of: 0), 0)
    }





    func testOnePersonCannotOwnTwoClustersInOneSession() {
        let r = SpeakerMatch.enforceOnePersonPerSession([
            "speaker_0": .matched(personID: me, votes: 5, of: 5, confidence: 1.0),
            "speaker_1": .matched(personID: me, votes: 2, of: 3, confidence: 0.67),
        ])
        guard case .matched(let pid, _, _, _) = r.kept["speaker_0"] else {
            return XCTFail("票比高的那个该留下:\(r.kept)")
        }
        XCTAssertEqual(pid, me)
        guard case .rejected(let why) = r.kept["speaker_1"] else {
            return XCTFail("票比低的那个该被拒:\(r.kept)")
        }
        XCTAssertTrue(why.contains("一人一簇"), why)
    }




    func testDisplacedClustersAreReported() {
        let r = SpeakerMatch.enforceOnePersonPerSession([
            "speaker_0": .matched(personID: me, votes: 5, of: 5, confidence: 1.0),
            "speaker_1": .matched(personID: me, votes: 2, of: 3, confidence: 0.67),
        ])
        XCTAssertEqual(r.displaced.count, 1)
        XCTAssertEqual(r.displaced[0].tag, "speaker_1")
        XCTAssertEqual(r.displaced[0].personID, me)
    }


    func testDifferentPeopleKeepTheirOwnClusters() {
        let r = SpeakerMatch.enforceOnePersonPerSession([
            "speaker_0": .matched(personID: me,  votes: 4, of: 5, confidence: 0.8),
            "speaker_1": .matched(personID: jin, votes: 3, of: 4, confidence: 0.75),
        ])
        XCTAssertTrue(r.displaced.isEmpty)
        XCTAssertEqual(r.kept.count, 2)
    }


    func testRejectedClustersPassThroughUnchanged() {
        let r = SpeakerMatch.enforceOnePersonPerSession([
            "speaker_0": .matched(personID: me, votes: 5, of: 5, confidence: 1.0),
            "speaker_2": .rejected(why: "没有一段过阈值"),
        ])
        XCTAssertEqual(r.kept["speaker_2"], .rejected(why: "没有一段过阈值"))
    }


















































    func testTauIsTheDocumentedOperatingPoint() {
        XCTAssertEqual(SpeakerMatch.tau, 0.3, accuracy: 0.0001, """
            改 τ 之前先读 `SpeakerMatch.tau` 上那段注释,再回答三个问题:
            ① 在**生产形态**(当前登记集 + 冒充集)上重标过了吗?
            ② 误认是散点还是集中?集中的话投票救不了,τ 要抬得更高;
            ③ 新数字的证据落盘了吗(docs/evidence/m2-认8/ · m2-认15/)?
            ⚠️ 2026-09-02 起 τ 是 **T-norm 的 z 差**,不是余弦差 —— 换空间要连打分一起看。
            三个都答得上再改这一行,并把 `mac/voiceprint_judge.py` 一起改
            (跨语言对撞会红,那正是它存在的理由)。
            """)
    }





    func testTheRetiredAbsoluteThresholdNoLongerDecidesAnything() {
        let v = SpeakerMatch.judge(segments: Array(repeating: seg(me, 0.99, 0.98), count: 4))
        guard case .rejected = v else {
            return XCTFail("绝对分 0.99 却差距 0.01,判成了 \(v) —— 绝对分数线被接回来了")
        }
    }
}

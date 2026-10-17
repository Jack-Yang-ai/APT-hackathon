import XCTest
@testable import GrowthApp

final class ASRResponseParserTests: XCTestCase {


    func testUnknownShapeThrowsInsteadOfReturningEmpty() {
        XCTAssertThrowsError(try ASRResponseParser.lines(fromRaw: #"{"status":"SUCCESS"}"#),
                             "没有分句却返回了空数组 —— 那会冻结一份空的终态转写")
        XCTAssertThrowsError(try ASRResponseParser.lines(fromRaw: "not json at all"))
        XCTAssertThrowsError(try ASRResponseParser.lines(fromRaw: ""))
    }

    func testEmptyUtteranceListIsNotAnError() throws {
        XCTAssertEqual(try ASRResponseParser.lines(fromRaw: #"{"utterances":[]}"#).count, 0)
    }


    func testParsesTheDocumentedShape() throws {
        let raw = """
        {"status":"SUCCESS","utterances":[
          {"text":"我们先把首页定下来","start_time":12000,"end_time":20000,"speaker":"1"},
          {"text":"我同意","start_time":20000,"end_time":23000,"speaker":"2"}]}
        """
        let lines = try ASRResponseParser.lines(fromRaw: raw)
        XCTAssertEqual(lines.map(\.text), ["我们先把首页定下来", "我同意"])
        XCTAssertEqual(lines[0].startMs, 12000)
        XCTAssertEqual(lines[0].endMs, 20000)
        XCTAssertEqual(ASRResponseParser.speakers(fromRaw: raw), ["1", "2"])
    }

    func testFindsUtterancesNestedUnderResultOrData() throws {
        for wrapper in ["result", "data"] {
            let raw = """
            {"\(wrapper)":{"utterances":[{"text":"在里面","start_time":0,"end_time":1000}]}}
            """
            XCTAssertEqual(try ASRResponseParser.lines(fromRaw: raw).map(\.text), ["在里面"],
                           "嵌在 \(wrapper) 下的分句没找到")
        }
    }


    func testBlankUtterancesAreSkipped() throws {
        let raw = """
        {"utterances":[{"text":"  ","start_time":0,"end_time":100},
                       {"text":"真的一句","start_time":100,"end_time":900}]}
        """
        XCTAssertEqual(try ASRResponseParser.lines(fromRaw: raw).map(\.text), ["真的一句"])
    }

    func testBackwardsTimestampsAreDroppedNotPatched() throws {
        let raw = """
        {"utterances":[{"text":"倒着的","start_time":9000,"end_time":1000},
                       {"text":"正常的","start_time":1000,"end_time":2000}]}
        """
        XCTAssertEqual(try ASRResponseParser.lines(fromRaw: raw).map(\.text), ["正常的"])
    }

    func testSecondsAreDistinguishedFromMillisecondsByMagnitude() throws {
        let secs = #"{"utterances":[{"text":"a","start_time":1.5,"end_time":2.25}]}"#
        let lines = try ASRResponseParser.lines(fromRaw: secs)
        XCTAssertEqual(lines[0].startMs, 1500, "1.5 该当成 1.5 秒")
        XCTAssertEqual(lines[0].endMs, 2250)

        let msRaw = #"{"utterances":[{"text":"a","start_time":12000,"end_time":20000}]}"#
        XCTAssertEqual(try ASRResponseParser.lines(fromRaw: msRaw)[0].startMs, 12000)
    }

    func testSpeakerIDsAreReadWhetherNumericOrString() {
        let numeric = #"{"utterances":[{"text":"a","speaker_id":0},{"text":"b","speaker_id":1}]}"#
        XCTAssertEqual(ASRResponseParser.speakers(fromRaw: numeric), ["0", "1"])
        let stringy = #"{"utterances":[{"text":"a","speaker":"S0"}]}"#
        XCTAssertEqual(ASRResponseParser.speakers(fromRaw: stringy), ["S0"])
    }

    func testMissingSpeakerFieldGivesNilsNotAnEmptyArray() {
        let raw = #"{"utterances":[{"text":"a"},{"text":"b"}]}"#
        XCTAssertEqual(ASRResponseParser.speakers(fromRaw: raw).count, 2)
        XCTAssertTrue(ASRResponseParser.speakers(fromRaw: raw).allSatisfy { $0 == nil })
    }
}


final class ASRSyntheticContractTests: XCTestCase {

    private let syntheticPending = #"{"duration":123.45,"result":[{}]}"#


    func testCompletionIsJudgedByResultNotByStatus() {
        let done = #"{"duration":38.46,"result":[{"utterances":[{"text":"喂","start_time":0,"end_time":900}]}]}"#
        XCTAssertEqual(ProxyClient.classify(body: done), .done(rawJSON: done),
                       "有 result 却没判成完成 —— 会一直轮询下去")
    }

    func testEmptyResultCountsAsDoneNotStillRunning() {
        guard case .done = ProxyClient.classify(body: syntheticPending) else {
            return XCTFail("`result:[{}]` 被判成了「还在跑」—— 这一场会一直「整理中」")
        }
    }

    func testNoResultKeyMeansStillRunning() {
        XCTAssertEqual(ProxyClient.classify(body: #"{"status":"PROCESSING"}"#), .pending)
    }

    func testFailureIsRecognizedBeforeResult() {
        for body in [#"{"status":"FAILED","result":[{}]}"#,
                     #"{"status":"AUDIO_ERROR"}"#,
                     #"{"status":"CONTENT_BLOCKED"}"#] {
            guard case .failed = ProxyClient.classify(body: body) else {
                return XCTFail("没判成失败:\(body)")
            }
        }
    }

    func testUnrecognisedShapeIsFlagged() {
        guard case .unknown = ProxyClient.classify(body: #"{"code":40001,"msg":"nope"}"#) else {
            return XCTFail("看不懂的报文被静默当成了 pending")
        }
    }

    func testDataWrapperIsUnwrapped() {
        let wrapped = #"{"data":{"result":[{"utterances":[{"text":"在里面"}]}]}}"#
        guard case .done = ProxyClient.classify(body: wrapped) else {
            return XCTFail("包在 data 下的完成回复没认出来")
        }
    }


    func testUtterancesAreFoundInsideTheResultArray() throws {
        let raw = """
        {"duration":38.46,"result":[{"utterances":[
          {"text":"我周三之前把文档给老王","start_time":1200,"end_time":4000,"speaker":"1"}]}]}
        """
        let lines = try ASRResponseParser.lines(fromRaw: raw)
        XCTAssertEqual(lines.map(\.text), ["我周三之前把文档给老王"])
        XCTAssertEqual(lines[0].startMs, 1200)
        XCTAssertEqual(ASRResponseParser.speakers(fromRaw: raw), ["1"])
    }

    func testEveryBlockInTheResultArrayIsCollected() throws {
        let raw = """
        {"result":[{"utterances":[{"text":"第一块","start_time":0,"end_time":900}]},
                   {"utterances":[{"text":"第二块","start_time":1000,"end_time":1900}]}]}
        """
        XCTAssertEqual(try ASRResponseParser.lines(fromRaw: raw).map(\.text), ["第一块", "第二块"])
    }

    func testEmptyResultParsesToZeroLinesInsteadOfThrowing() throws {
        XCTAssertEqual(try ASRResponseParser.lines(fromRaw: syntheticPending).count, 0)
    }
}


extension ASRSyntheticContractTests {

    func testSpeakerIsReadFromTheDictShape() throws {
        let raw = """
        {"result":[{"utterances":[
          {"text":"第一句","start_time":0,"end_time":900,"speaker":{"id":"speaker_0"}},
          {"text":"第二句","start_time":1000,"end_time":1900,"speaker":{"id":"speaker_1"}}]}]}
        """
        XCTAssertEqual(ASRResponseParser.speakers(fromRaw: raw), ["speaker_0", "speaker_1"])
        XCTAssertEqual(try ASRResponseParser.lines(fromRaw: raw).map(\.speaker),
                       ["speaker_0", "speaker_1"])
    }

    func testSpeakerStaysWithItsTextWhenSentencesAreDropped() throws {
        let raw = """
        {"result":[{"utterances":[
          {"text":"  ","start_time":0,"end_time":100,"speaker":{"id":"speaker_9"}},
          {"text":"倒着的","start_time":9000,"end_time":1000,"speaker":{"id":"speaker_8"}},
          {"text":"留下来的","start_time":1000,"end_time":1900,"speaker":{"id":"speaker_1"}}]}]}
        """
        let lines = try ASRResponseParser.lines(fromRaw: raw)
        XCTAssertEqual(lines.map(\.text), ["留下来的"])
        XCTAssertEqual(lines.map(\.speaker), ["speaker_1"],
                       "被丢掉的句子把标签带偏了 —— 这一行会被算成别人说的")
    }

    func testFlatSpeakerShapesStillWork() {
        for raw in [#"{"result":[{"utterances":[{"text":"a","speaker":"S0"}]}]}"#,
                    #"{"result":[{"utterances":[{"text":"a","speaker_id":0}]}]}"#] {
            XCTAssertEqual(ASRResponseParser.speakers(fromRaw: raw).count, 1)
            XCTAssertNotNil(ASRResponseParser.speakers(fromRaw: raw).first ?? nil, raw)
        }
    }

    func testMissingSpeakerGivesNils() {
        let raw = #"{"result":[{"utterances":[{"text":"a"},{"text":"b"}]}]}"#
        XCTAssertEqual(ASRResponseParser.speakers(fromRaw: raw).count, 2)
        XCTAssertTrue(ASRResponseParser.speakers(fromRaw: raw).allSatisfy { $0 == nil })
    }
}

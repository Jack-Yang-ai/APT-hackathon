import XCTest
@testable import GrowthApp

final class AgentProtocolTests: XCTestCase {
    private func examples() throws -> [String: APTJSONValue] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "examples", withExtension: "json"))
        return try JSONDecoder().decode([String: APTJSONValue].self, from: Data(contentsOf: url))
    }

    private func roundTrip<T: APTContractMessage>(_ type: T.Type, _ value: APTJSONValue) throws {
        let raw = try JSONEncoder().encode(value)
        let decoded = try APTAgentContract.decode(type, from: raw)
        let encoded = try APTAgentContract.encode(decoded)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? NSDictionary)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        XCTAssertEqual(before, after, "Required nullable fields must remain explicit JSON null")
    }

    func testSharedExamplesRoundTripWithoutLosingNullableFields() throws {
        let v = try examples()
        XCTAssertEqual(v.count, 11)
        try roundTrip(APTSourceSnapshot.self, XCTUnwrap(v["SourceSnapshot"]))
        try roundTrip(APTAction.self, XCTUnwrap(v["Action"]))
        try roundTrip(APTPlan.self, XCTUnwrap(v["Plan"]))
        try roundTrip(APTExecutionRequest.self, XCTUnwrap(v["ExecutionRequest"]))
        try roundTrip(APTExecutionReceipt.self, XCTUnwrap(v["ExecutionReceipt"]))
        try roundTrip(APTCommandEnvelope.self, XCTUnwrap(v["CommandEnvelope"]))
        try roundTrip(APTCommandReceipt.self, XCTUnwrap(v["CommandReceipt"]))
        try roundTrip(APTContentReadRequest.self, XCTUnwrap(v["ContentReadRequest"]))
        try roundTrip(APTContentQueryRequest.self, XCTUnwrap(v["ContentQueryRequest"]))
        try roundTrip(APTContentValidateRequest.self, XCTUnwrap(v["ContentValidateRequest"]))
        try roundTrip(APTCommandReceiptReadRequest.self, XCTUnwrap(v["CommandReceiptReadRequest"]))
    }

    func testStagingCannotBecomeAnExecutionAuthority() throws {
        var request = try XCTUnwrap(examples()["ExecutionRequest"]).object
        request["authority"] = .object(["domain": .string("content"), "phase": .string("staging"), "epoch": .number(0)])
        XCTAssertThrowsError(try APTAgentContract.validate("ExecutionRequest", value: .object(request)))
        request["authority"] = .object(["domain": .string("content"), "phase": .string("backend"), "epoch": .number(0)])
        XCTAssertThrowsError(try APTAgentContract.validate("ExecutionRequest", value: .object(request)))
    }

    func testDeletionDatesAndMalformedRevisionAreRejected() throws {
        let v = try examples()
        var source = try XCTUnwrap(v["SourceSnapshot"]).object
        source["deleted"] = .bool(true)
        XCTAssertThrowsError(try APTAgentContract.validate("SourceSnapshot", value: .object(source)))
        source["text"] = .string("")
        source["attributes"] = .object([:])
        XCTAssertNoThrow(try APTAgentContract.validate("SourceSnapshot", value: .object(source)))
        source["captured_at"] = .string("2026-02-31T07:00:00Z")
        XCTAssertThrowsError(try APTAgentContract.validate("SourceSnapshot", value: .object(source)))
        var action = try XCTUnwrap(v["Action"]).object
        for revision in [APTJSONValue.bool(true), .number(0), .number(9_007_199_254_740_992)] {
            action["revision"] = revision
            XCTAssertThrowsError(try APTAgentContract.validate("Action", value: .object(action)))
        }
    }

    func testUnknownExecutionAndFailedCommandRemainVisible() throws {
        let v = try examples()
        var receipt = try XCTUnwrap(v["ExecutionReceipt"]).object
        var error = try XCTUnwrap(receipt["error"]).object
        error["retryable"] = .bool(true)
        receipt["error"] = .object(error)
        XCTAssertThrowsError(try APTAgentContract.validate("ExecutionReceipt", value: .object(receipt)))
        receipt["error"] = .null
        XCTAssertThrowsError(try APTAgentContract.validate("ExecutionReceipt", value: .object(receipt)))
        var command = try XCTUnwrap(v["CommandReceipt"]).object
        command["state"] = .string("conflict")
        command["applied_revision"] = .null
        XCTAssertThrowsError(try APTAgentContract.validate("CommandReceipt", value: .object(command)))
    }

    func testRawDuplicateAndEscapedAliasCannotChangeDeletionOrRevision() throws {
        let v = try examples()
        for (kind, suffix) in [("SourceSnapshot", #","deleted":true}"#), ("SourceSnapshot", #","\u0064eleted":true}"#), ("Action", #","revision":2}"#)] {
            let raw = try JSONEncoder().encode(XCTUnwrap(v[kind]))
            let text = try XCTUnwrap(String(data: raw, encoding: .utf8))
            let duplicate = String(text.dropLast()) + suffix
            XCTAssertThrowsError(try APTAgentContract.validateJSON(kind, from: Data(duplicate.utf8)))
        }
        var source = try XCTUnwrap(v["SourceSnapshot"]).object
        source["text"] = .string("SURROGATE_TOKEN")
        let raw = try JSONEncoder().encode(APTJSONValue.object(source))
        let text = try XCTUnwrap(String(data: raw, encoding: .utf8))
        let surrogate = text.replacingOccurrences(of: "SURROGATE_TOKEN", with: #"\ud800"#)
        XCTAssertThrowsError(try APTAgentContract.validateJSON("SourceSnapshot", from: Data(surrogate.utf8)))
    }
}

"""Cross-runtime acceptance cases, including malformed and unsafe wire values."""
from __future__ import annotations
import copy
import base64
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from shared.agent_protocol import ROOT, ProtocolError, validate, decode

REPO = Path(__file__).resolve().parent.parent
EXAMPLES = json.loads((ROOT / "examples.json").read_text())


def cases():
    result = [{"name": name, "kind": name, "value": value, "valid": True} for name, value in EXAMPLES.items()]
    def changed(name, kind, update, valid=False):
        value = copy.deepcopy(EXAMPLES[kind])
        update(value)
        result.append({"name": name, "kind": kind, "value": value, "valid": valid})
    changed("missing_schema", "Action", lambda v: v.pop("schema"))
    changed("unknown_field", "Action", lambda v: v.update(unapproved=True))
    changed("unknown_state", "Action", lambda v: v.update(state="wish"))
    changed("boolean_revision", "Action", lambda v: v.update(revision=True))
    changed("zero_revision", "Action", lambda v: v.update(revision=0))
    changed("unsafe_revision", "Action", lambda v: v.update(revision=9007199254740992))
    changed("integral_number_revision", "Action", lambda v: v.update(revision=1.0), True)
    changed("fractional_revision", "Action", lambda v: v.update(revision=1.5))
    changed("unsafe_integral_json_number", "SourceSnapshot", lambda v: v["attributes"].update(huge=1e30))
    changed("wrong_domain", "Action", lambda v: v["authority"].update(domain="voiceprint"))
    changed("staging_epoch", "Action", lambda v: v["authority"].update(epoch=1))
    changed("backend_zero_epoch", "Action", lambda v: v["authority"].update(phase="backend"))
    changed("bad_namespace", "SourceSnapshot", lambda v: v["snapshot"]["source"].update(namespace="row_number"))
    changed("bad_source_id", "SourceSnapshot", lambda v: v["snapshot"]["source"].update(source_id=""))
    changed("bad_calendar", "SourceSnapshot", lambda v: v.update(captured_at="2026-02-31T07:00:00Z"))
    changed("bad_hour", "SourceSnapshot", lambda v: v.update(captured_at="2026-10-14T24:00:00Z"))
    changed("no_timezone", "SourceSnapshot", lambda v: v.update(captured_at="2026-10-14T07:00:00"))
    changed("bad_timezone_minutes", "SourceSnapshot", lambda v: v.update(captured_at="2026-10-14T07:00:00+00:60"))
    changed("deleted_content", "SourceSnapshot", lambda v: v.update(deleted=True))
    changed("clean_tombstone", "SourceSnapshot", lambda v: v.update(deleted=True, text="", attributes={}), True)
    changed("too_many_dependencies", "Action", lambda v: v.update(dependencies=v["dependencies"]*241))
    changed("wrong_step_assignee", "Plan", lambda v: v["steps"][0].update(assignee="robot"))
    changed("staged_execution", "ExecutionRequest", lambda v: v.update(authority={"domain":"content","phase":"staging","epoch":0}))
    changed("unknown_retry", "ExecutionReceipt", lambda v: v["error"].update(retryable=True))
    changed("unknown_without_error", "ExecutionReceipt", lambda v: v.update(error=None))
    changed("success_without_receipt", "ExecutionReceipt", lambda v: v.update(state="succeeded",error=None))
    changed("accepted_without_version", "CommandReceipt", lambda v: v.update(applied_revision=None))
    changed("failed_command_without_error", "CommandReceipt", lambda v: v.update(state="conflict",applied_revision=None))
    changed("ambiguous_command_target", "CommandEnvelope", lambda v: v["target"].update(kind="source"))
    changed("false_expected_revision", "CommandEnvelope", lambda v: v.update(expected_revision=False))
    changed("staging_content_read", "ContentReadRequest", lambda v: v.update(authority={"domain":"content","phase":"staging","epoch":0}))
    changed("unbounded_content_query", "ContentQueryRequest", lambda v: v.update(limit=31))
    changed("unknown_content_query_field", "ContentQueryRequest", lambda v: v.update(actor_id="client-claimed-owner"))
    for kind, value in [('ID', '11111111-1111-4111-8111-111111111111'), ('Hash', 'a' * 64)]:
        for suffix in ['\n', '\r', '\r\n', '\u2028']:
            result.append({'name': kind + '_trailing_' + repr(suffix), 'kind': kind, 'value': value + suffix, 'valid': False})
    for suffix in ['\n', '\r', '\r\n', '\u2028']:
        changed('timestamp_trailing_' + repr(suffix), 'SourceSnapshot', lambda v: v.update(captured_at=v['captured_at'] + suffix))
    return result


def raw_cases():
    result = [{"name": c["name"], "kind": c["kind"], "raw": json.dumps(c["value"]), "valid": c["valid"]} for c in cases()]
    source = json.dumps(EXAMPLES["SourceSnapshot"])
    action = json.dumps(EXAMPLES["Action"])
    for name, kind, raw in (
        ("duplicate_deleted", "SourceSnapshot", source[:-1] + ',"deleted":true}'),
        ("duplicate_revision", "Action", action[:-1] + ',"revision":2}'),
        ("escaped_duplicate_key", "SourceSnapshot", source[:-1] + ',"\\u0064eleted":true}'),
        ("utf8_bom", "SourceSnapshot", '\ufeff' + source),
    ):
        result.append({"name": name, "kind": kind, "raw": raw, "valid": False})
    for name, kind, field, value in (
        ("surrogate_text", "SourceSnapshot", "text", '\ud800'),
        ("surrogate_attribute_key", "SourceSnapshot", "attributes", {'\ud800': 'unsafe'}),
        ("surrogate_argument", "ExecutionRequest", "arguments", {'value': '\ud800'}),
        ("surrogate_argument_key", "ExecutionRequest", "arguments", {'\ud800': 'unsafe'}),
        ("normalized_duplicate_key", "SourceSnapshot", "attributes", {'é': 1, 'e\u0301': 2}),
    ):
        v = copy.deepcopy(EXAMPLES[kind])
        v[field] = value
        result.append({"name": name, "kind": kind, "raw": json.dumps(v), "valid": False})
    result.append({"name": "invalid_utf8", "kind": "SourceSnapshot", "raw": "", "raw_base64": base64.b64encode(b'\xff').decode(), "valid": False})
    return result


class AgentProtocolTests(unittest.TestCase):
    def test_python_boundary_matrix(self):
        for case in cases():
            with self.subTest(case["name"]):
                try:
                    validate(case["kind"], case["value"])
                    accepted = True
                except ProtocolError:
                    accepted = False
                self.assertEqual(accepted, case["valid"])

    def test_python_raw_wire_boundary(self):
        for case in raw_cases():
            with self.subTest(case["name"]):
                raw = base64.b64decode(case["raw_base64"]) if "raw_base64" in case else case["raw"]
                try:
                    decode(case["kind"], raw)
                    accepted = True
                except ProtocolError:
                    accepted = False
                self.assertEqual(accepted, case["valid"])

    def test_mac_uses_the_same_matrix(self):
        script = """
import { validate, decode } from './shared/agent_protocol.mjs';
let input=''; for await (const chunk of process.stdin) input+=chunk;
const data=JSON.parse(input);
const values=data.values.map(c=>{try {validate(c.kind,c.value);return true;} catch {return false;}});
const raw=data.raw.map(c=>{try {decode(c.kind,c.raw_base64 ? Buffer.from(c.raw_base64,'base64') : c.raw);return true;} catch {return false;}});
process.stdout.write(JSON.stringify({values,raw}));
"""
        out = subprocess.run(["node", "--input-type=module", "-e", script], input=json.dumps({"values": cases(), "raw": raw_cases()}), text=True, capture_output=True, cwd=REPO, check=True)
        self.assertEqual(json.loads(out.stdout), {"values": [c["valid"] for c in cases()], "raw": [c["valid"] for c in raw_cases()]})

    def test_generated_bindings_match(self):
        subprocess.run(["python3", "scripts/generate_agent_protocol.py", "--check"], cwd=REPO, check=True, capture_output=True)

    @unittest.skipUnless(shutil.which("swiftc"), "Swift runtime is checked on the Mac and iOS")
    def test_iphone_codec_matrix_and_nullable_roundtrip(self):
        main = """
import Foundation
@main struct Check {
  static func main() throws {
    let input = try JSONDecoder().decode(APTJSONValue.self, from: FileHandle.standardInput.readDataToEndOfFile()).object
    let values = input["values"]!.array
    let accepted = values.map { c -> Bool in
      do { try APTAgentContract.validate(c.object["kind"]!.string!, value:c.object["value"]!); return true } catch { return false }
    }
    var roundtrips: [String: APTJSONValue] = [:]
    for c in values where c.object["name"]!.string == c.object["kind"]!.string {
      let kind = c.object["kind"]!.string!, raw = try JSONEncoder().encode(c.object["value"]!)
      let encoded: Data
      switch kind {
      case "SourceSnapshot": encoded = try APTAgentContract.encode(APTAgentContract.decode(APTSourceSnapshot.self,from:raw))
      case "Action": encoded = try APTAgentContract.encode(APTAgentContract.decode(APTAction.self,from:raw))
      case "Plan": encoded = try APTAgentContract.encode(APTAgentContract.decode(APTPlan.self,from:raw))
      case "ExecutionRequest": encoded = try APTAgentContract.encode(APTAgentContract.decode(APTExecutionRequest.self,from:raw))
      case "ExecutionReceipt": encoded = try APTAgentContract.encode(APTAgentContract.decode(APTExecutionReceipt.self,from:raw))
      case "CommandEnvelope": encoded = try APTAgentContract.encode(APTAgentContract.decode(APTCommandEnvelope.self,from:raw))
      case "CommandReceipt": encoded = try APTAgentContract.encode(APTAgentContract.decode(APTCommandReceipt.self,from:raw))
      case "ContentReadRequest": encoded = try APTAgentContract.encode(APTAgentContract.decode(APTContentReadRequest.self,from:raw))
      case "ContentQueryRequest": encoded = try APTAgentContract.encode(APTAgentContract.decode(APTContentQueryRequest.self,from:raw))
      case "ContentValidateRequest": encoded = try APTAgentContract.encode(APTAgentContract.decode(APTContentValidateRequest.self,from:raw))
      case "CommandReceiptReadRequest": encoded = try APTAgentContract.encode(APTAgentContract.decode(APTCommandReceiptReadRequest.self,from:raw))
      default: throw APTProtocolError.invalid("unexpected_case")
      }
      roundtrips[kind] = try JSONDecoder().decode(APTJSONValue.self,from:encoded)
    }
    let raw = input["raw"]!.array.map { c -> Bool in
      do {
        let data = c.object["raw_base64"]?.string.flatMap { Data(base64Encoded:$0) } ?? Data(c.object["raw"]!.string!.utf8)
        _ = try APTAgentContract.validateJSON(c.object["kind"]!.string!,from:data)
        return true
      } catch { return false }
    }
    let output: APTJSONValue = .object(["accepted":.array(accepted.map(APTJSONValue.bool)),"raw":.array(raw.map(APTJSONValue.bool)),"roundtrips":.object(roundtrips)])
    FileHandle.standardOutput.write(try JSONEncoder().encode(output))
  }
}
"""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / "Check.swift").write_text(main)
            subprocess.run(["swiftc", str(REPO/"ios/GrowthApp/Agent/AgentProtocol.generated.swift"), str(path/"Check.swift"), "-o", str(path/"check")], check=True, capture_output=True)
            output = subprocess.run([str(path/"check")], input=json.dumps({"values": cases(), "raw": raw_cases()}), text=True, capture_output=True, check=True)
        parsed = json.loads(output.stdout)
        self.assertEqual(parsed["accepted"], [c["valid"] for c in cases()])
        self.assertEqual(parsed["raw"], [c["valid"] for c in raw_cases()])
        self.assertEqual(parsed["roundtrips"], EXAMPLES)


if __name__ == "__main__":
    print(f"Protocol boundary matrix: {len(cases())} values / {len(raw_cases())} raw inputs; {len(EXAMPLES)} shared roundtrips")
    unittest.main()

"""新行动协议的证据、兼容、错误终态；语义质量用仓外真实模型回执。"""
import copy
import io
import json
import unittest
from unittest.mock import patch
from pathlib import Path
from botocore.exceptions import ClientError

from worker.extract import SchemaError, validate as validate_summary
from worker.personal_actions import PROTOCOL, PROMPT, validate, from_model, run
from worker import extract_two_stage


class PersonalActionTests(unittest.TestCase):
    def setUp(self):
        self.lines = [{"line_id": 1, "text": "你下周发方案？", "person_id": 7, "cluster_tag": "甲"},
                      {"line_id": 2, "text": "行，我来发", "person_id": None, "cluster_tag": "乙"}]
        self.item = {"kind": "accepted", "title": "发方案", "line_id": 2, "quote": "我来发",
                     "evidence": [{"line_id": 1, "quote": "你下周发方案？"}, {"line_id": 2, "quote": "行，我来发"}],
                     "condition_text": "", "deadline_text": "下周", "collaborators_text": ""}

    def payload(self, items=None):
        return {"action_protocol": PROTOCOL, "personal_actions": [self.item] if items is None else items}

    def test_quote_can_be_shorter_than_context_but_both_must_be_verbatim(self):
        clean = validate(self.payload(), self.lines)
        self.assertTrue(clean["personal_actions"][0]["pending"])
        bad = copy.deepcopy(self.item); bad["quote"] = "我不发"
        with self.assertRaises(SchemaError): validate(self.payload([bad]), self.lines)

    def test_context_cannot_be_missing_redacted_gap_or_outside_input(self):
        for modifier in ({"line_id": 99}, {"is_gap": 1}, {"redacted": 1}, {"text": "你不用发"}):
            lines = copy.deepcopy(self.lines); lines[0].update(modifier)
            with self.assertRaises(SchemaError): validate(self.payload(), lines)

    def test_asr_repetitions_cannot_be_deleted_inside_quotes(self):
        lines = [{"line_id": 1, "text": "我明天我我来来发方案", "cluster_tag": "甲", "person_id": None}]
        item = copy.deepcopy(self.item)
        item.update(line_id=1, quote="我明天我来发方案", deadline_text="明天",
                    evidence=[{"line_id": 1, "quote": lines[0]["text"]}])
        with self.assertRaises(SchemaError): validate(self.payload([item]), lines)
        item["quote"] = "来发方案"
        self.assertTrue(validate(self.payload([item]), lines)["personal_actions"][0]["pending"])
        bad_context = copy.deepcopy(item)
        bad_context["evidence"][0]["quote"] = "我明天我来发方案"
        with self.assertRaises(SchemaError): validate(self.payload([bad_context]), lines)

    def test_model_cannot_assign_owner_or_use_boolean_line_id(self):
        for field, value in (("who", "我"), ("person_id", 1), ("line_id", True)):
            item = copy.deepcopy(self.item); item[field] = value
            with self.assertRaises(SchemaError): validate(self.payload([item]), self.lines)

    def test_duplicate_same_line_titles_are_rejected(self):
        duplicate = copy.deepcopy(self.item); duplicate["title"] = "发 方案。"
        with self.assertRaises(SchemaError): validate(self.payload([self.item, duplicate]), self.lines)

    def test_legacy_summary_is_readable_but_not_an_action_assessment(self):
        payload = {"one_liner": "旧纪要", "key_points": [], "commitments": [], "stances": [], "pendings": [], "topic_keys": []}
        clean, _ = validate_summary(payload, self.lines)
        self.assertNotIn("action_protocol", clean)
        with self.assertRaises(SchemaError): validate({"personal_actions": []}, self.lines)

    def test_new_recipe_missing_action_output_retries_then_fails(self):
        count = []
        def call(prompt, **kwargs):
            count.append(kwargs["scene"])
            if kwargs["scene"] == "extract_s1": return '#C 1 high full 相关 交付\n#META {"recommended_event_count":1}'
            return json.dumps({"one_liner": "交付", "key_points": [], "commitments": [], "stances": [], "pendings": [], "topic_keys": [],
                               "events": [{"event_id": "E1", "title": "交付", "summary": "讨论方案"}]})
        lines = copy.deepcopy(self.lines); lines[0]["action_protocol"] = PROTOCOL
        with self.assertRaises(SchemaError): extract_two_stage.run(lines, model_call=call)
        self.assertEqual(count.count("extract_s2"), 4)

    def test_legacy_two_stage_job_does_not_request_new_action_protocol(self):
        cands = [{"no": 1, "line_from": 1, "line_to": 2}]
        groups = [{"event_id": "E1", "blocks": [1]}]
        legacy = extract_two_stage.render_stage2_prompt(self.lines, groups, cands)
        requested = extract_two_stage.render_stage2_prompt(self.lines, groups, cands, include_actions=True)
        self.assertNotIn(PROTOCOL, legacy)
        self.assertIn(PROTOCOL, requested)

    def test_prompt_fixture_matches_and_v1_gold_is_unchanged(self):
        root = Path(__file__).resolve().parents[1]
        self.assertEqual((root / "eval/fixtures/personal_action_prompt.txt").read_text(), PROMPT)
        self.assertTrue((root / "eval/checks/golden/extract_prompt_v1.txt").exists())

    def test_protocol_version_is_assigned_by_code_without_accepting_missing_array(self):
        clean = from_model({"action_protocol": "模型拼错的编号", "personal_actions": [self.item]}, self.lines)
        self.assertEqual(clean["action_protocol"], PROTOCOL)
        with self.assertRaises(SchemaError): from_model({"action_protocol": PROTOCOL}, self.lines)

    def test_action_only_uses_bound_actor_tags_and_retries_invalid_evidence(self):
        lines = copy.deepcopy(self.lines)
        lines[0]["actor_tag"] = "已归属人物7"
        lines[1]["actor_tag"] = "已归属人物1"
        calls = []
        def model(prompt, **kwargs):
            calls.append(kwargs)
            self.assertIn("1 | 已归属人物7 |", prompt)
            self.assertIn("2 | 已归属人物1 |", prompt)
            if len(calls) == 1:
                bad = copy.deepcopy(self.item); bad["line_id"] = 1
                return json.dumps(self.payload([bad]))
            return json.dumps(self.payload())
        clean, meta = run(lines, model)
        self.assertEqual(len(calls), 2)
        self.assertEqual(clean["personal_actions"][0]["line_id"], 2)
        self.assertEqual([a["ok"] for a in meta["attempts"]], [False, True])

    def test_action_only_never_runs_stage1_and_preserves_all_input_parts(self):
        lines = copy.deepcopy(self.lines)
        lines[0].update(action_only=True, action_protocol=PROTOCOL)
        def model(prompt, **kwargs):
            self.assertEqual(kwargs["scene"], "extract_s2")
            self.assertIn("1 |", prompt); self.assertIn("2 |", prompt)
            return json.dumps(self.payload([]))
        clean, _, _ = extract_two_stage.run(lines, model_call=model)
        self.assertEqual(clean["personal_actions"], [])
        self.assertEqual(clean["pipeline_version"], extract_two_stage.PROMPT_VERSION)

    def test_new_failed_remote_job_is_terminal_and_never_rebought(self):
        from mac import extract_daemon
        key = "extract/jobs/1-0-test.json"
        class Bucket:
            def __init__(self): self.objects = {key: json.dumps({"session": 1, "part": 0, "prompt": PROTOCOL}).encode()}
            def list_objects_v2(self, **kw): return {"Contents": [{"Key": k} for k in self.objects if k.startswith(kw["Prefix"])]}
            def get_object(self, **kw): return {"Body": io.BytesIO(self.objects[kw["Key"]])}
            def head_object(self, **kw):
                if kw["Key"] not in self.objects:
                    raise ClientError({"Error": {"Code": "404"}}, "HeadObject")
                return {}
            def put_object(self, **kw): self.objects[kw["Key"]] = kw["Body"]
            def delete_object(self, **kw): self.objects.pop(kw["Key"], None)
        bucket = Bucket()
        with patch.object(extract_daemon, "_run", side_effect=SchemaError("证据无效")) as model:
            extract_daemon.run_once(bucket, "private", timeout=1, log=lambda _: None)
            extract_daemon.run_once(bucket, "private", timeout=1, log=lambda _: None)
            self.assertEqual(model.call_count, 1)
        self.assertNotIn(key, bucket.objects)
        terminal = json.loads(bucket.objects["extract/out/1-0-test.json"])
        self.assertTrue(terminal["terminal"])
        self.assertNotIn("one_liner", terminal)

    def test_saved_success_or_terminal_is_not_rebought_after_delete_failure(self):
        from mac import extract_daemon
        key = "extract/jobs/1-0-test.json"
        class Bucket:
            def __init__(self):
                self.objects = {key: json.dumps({"prompt": PROTOCOL}).encode()}
                self.fail_delete = True
            def list_objects_v2(self, **kw): return {"Contents": [{"Key": k} for k in self.objects if k.startswith(kw["Prefix"])]}
            def get_object(self, **kw): return {"Body": io.BytesIO(self.objects[kw["Key"]])}
            def head_object(self, **kw):
                if kw["Key"] not in self.objects:
                    raise ClientError({"Error": {"Code": "404"}}, "HeadObject")
                return {}
            def put_object(self, **kw): self.objects[kw["Key"]] = kw["Body"]
            def delete_object(self, **kw):
                if self.fail_delete:
                    self.fail_delete = False
                    raise OSError("清理暂时失败")
                self.objects.pop(kw["Key"], None)
        for terminal in (False, True):
            with self.subTest(terminal=terminal):
                bucket = Bucket()
                kwargs = {"side_effect": SchemaError("证据无效")} if terminal else {"return_value": json.dumps(self.payload([]))}
                with patch.object(extract_daemon, "_run", **kwargs) as model:
                    with self.assertRaises(OSError):
                        extract_daemon.run_once(bucket, "private", timeout=1, log=lambda _: None)
                    # out 已落盘，甚至不必等 claim 过期便可只清理。
                    result = extract_daemon.run_once(bucket, "private", timeout=1, log=lambda _: None)
                    self.assertEqual(model.call_count, 1)
                    self.assertEqual(result["skipped"], 1)
                    self.assertNotIn(key, bucket.objects)


if __name__ == "__main__": unittest.main()

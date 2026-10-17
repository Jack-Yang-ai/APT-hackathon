"""extract_two_stage 纯代码测试（不打 API）。跑法：python3 -m worker.test_two_stage"""
from __future__ import annotations

from . import extract as v1
from . import extract_two_stage as ts


def _lines(spec):
    """spec: [(t_sec, text, tag)] → lines"""
    return [{"line_id": i + 1, "t_sec": t, "text": x, "cluster_tag": tag, "is_gap": 0, "person_id": None}
            for i, (t, x, tag) in enumerate(spec)]


def test_candidates_split_and_meta():
    rows = _lines([(i * 10, "字" * 100, f"说话人{1 + i % 2}") for i in range(60)])  # 6000 字
    c = ts.candidates(rows)
    assert all(x["chars"] <= ts.TARGET_CHARS for x in c), [x["chars"] for x in c]
    assert c[0]["gap_prev"] == 0 and all(x["gap_prev"] >= 0 for x in c)
    assert set(c[0]["speakers"]) == {"说话人1", "说话人2"}
    # 全覆盖无缝隙
    assert c[0]["line_from"] == 1 and c[-1]["line_to"] == 60
    for a, b in zip(c, c[1:]):
        assert b["line_from"] == a["line_to"] + 1


def test_parse_stage1_envelopes_and_coverage():
    body = "#C 1 low compressed 无关 播报\n#C 2 high full 相关 会议\n#META {}"
    for raw in (body, f'{{"output": {ts.json.dumps(body)}}}',
                ts.json.dumps(body.splitlines()), f"```\n{body}\n```"):
        lab, bad = ts.parse_stage1(raw, 2)
        assert len(lab) == 2 and bad == 0, raw[:30]
    labels, bad = ts.parse_stage1("#C 1 medium full 香蕉 项目", 1)
    assert labels == {} and bad == 1, "相关性必须在闭集内"
    try:
        ts.check_coverage({1: {}}, 10)
        raise AssertionError("覆盖不足必须抛")
    except ts.Stage1CoverageError:
        pass


def test_group_rules():
    cands = [{"no": i, "line_from": i * 10 + 1, "line_to": i * 10 + 10, "chars": 500,
              "t_from": 0, "t_to": 0, "speakers": [], "gap_prev": g}
             for i, g in enumerate([0, 5, 700, 5, 5], 0)]
    lab = {0: {"tier_event": "medium", "user_relevance": "相关"},
           1: {"tier_event": "low", "user_relevance": "相关"},        # 剔
           2: {"tier_event": "medium", "user_relevance": "相关"},     # gap 700 是证据，不强制断事
           3: {"tier_event": "high", "user_relevance": "相关"},       # high 断组
           4: {"tier_event": "medium", "user_relevance": "无关"}}     # 剔
    groups, dropped = ts.group_blocks(cands, lab)
    assert dropped == [1, 4]
    assert [g["blocks"] for g in groups] == [[0, 2], [3]]
    assert [g["event_id"] for g in groups] == ["E1", "E2"]


def test_compact_step5_labels_keep_identity_and_coverage_checks():
    spaced = "#C 1 high full 相关 项目\n#C 2 medium compressed 相关 进展"
    compact = "#C1 high full 相关 项目\n#C2 medium compressed 相关 进展"
    assert ts.parse_stage1(compact, 2) == ts.parse_stage1(spaced, 2)
    labels, bad = ts.parse_stage1("#C1 high full 香蕉 错误\n#C3 medium full 相关 越界", 2)
    assert labels == {} and bad == 2
    try:
        ts.check_coverage({1: {}}, 2, min_ratio=1.0)
        raise AssertionError("紧凑格式不能绕过覆盖率")
    except ts.Stage1CoverageError:
        pass


def test_compact_step5_duplicate_is_rejected_in_streaming():
    rows = _lines([(0, "项目讨论", "簇1")])
    rows[0].update(recipe=ts.PROMPT_VERSION, streaming=True)
    def call(*args, **kwargs):
        return "#C1 high full 相关 A\n#C 1 medium full 相关 B"
    try:
        ts.run(rows, model_call=call)
        raise AssertionError("两种写法同一编号仍是重复")
    except ts.Stage1CoverageError:
        pass


def test_stream_continuity_uses_previous_context_and_overrides_forged_identity():
    rows = _lines([(3600, "同一项目接着聊分工", "块8·说话人1")])
    rows[0].update(recipe=ts.PROMPT_VERSION, streaming=True, t_end_sec=3620,
                   stream_context={"event_id": 123, "title": "项目规划", "summary": "前片讨论排期",
                                   "tail": "接着分工", "t_end_sec": 300})
    prompts = []
    def call(prompt, **kw):
        prompts.append(prompt)
        if kw["scene"] == ts.SCENE_S1:
            assert "前片讨论排期" in prompt and "间隔3300s" in prompt
            return "#C 1 medium full 相关 项目分工\n#META {}"
        return ts.json.dumps({"one_liner": "继续项目分工", **{k: [] for k in v1.ALL_KINDS},
                              "key_points": [{"point": "继续分工", "quote": rows[0]["text"], "line_id": 1}],
                              "events": [{"event_id": "E1", "title": "分工", "summary": "当前片的进展",
                                          "continuation_id": 99999}]})
    payload, _, _ = ts.run(rows, model_call=call)
    assert payload["pipeline_version"] == ts.PROMPT_VERSION
    assert payload["events"][0]["continuation_id"] == 123
    assert len(prompts) == 2 and "前片讨论排期" not in prompts[1], "旧原文只参与延续判据，不重复抽取"


def test_stream_new_matter_breaks_prior_even_if_its_content_is_dropped():
    c = [{"no": 1, "gap_prev": 0}, {"no": 2, "gap_prev": 0}]
    labels = {1: {"tier_event": "high", "user_relevance": "无关"},
              2: {"tier_event": "medium", "user_relevance": "相关"}}
    groups, _ = ts.group_blocks(c, labels, {"event_id": 12})
    assert "continuation_id" not in groups[0], "已换另一件事，不能回接更前面的事"


def test_stream_duplicate_label_is_fail_closed():
    rows = _lines([(0, "内容", "簇1")])
    rows[0].update(recipe=ts.PROMPT_VERSION, streaming=True)
    calls = []
    def call(*args, **kw):
        calls.append(kw)
        return "#C 1 medium full 相关 A\n#C 1 high full 相关 B"
    try:
        ts.run(rows, model_call=call)
        raise AssertionError("重复标签不能静默取最后一个")
    except ts.Stage1CoverageError:
        assert len(calls) == 4


def test_recipe_mismatch_does_not_call_model():
    rows = _lines([(0, "内容", "簇1")])
    rows[0]["recipe"] = "future"
    try:
        ts.run(rows, model_call=lambda *a, **k: (_ for _ in ()).throw(AssertionError("不应付费")))
        raise AssertionError("未知配方必须拒绝")
    except v1.SchemaError:
        pass


def test_assign_event_ids_mechanical():
    cands = [{"no": 1, "line_from": 1, "line_to": 10, "chars": 1, "t_from": 0, "t_to": 0,
              "speakers": [], "gap_prev": 0},
             {"no": 2, "line_from": 11, "line_to": 20, "chars": 1, "t_from": 0, "t_to": 0,
              "speakers": [], "gap_prev": 0}]
    groups = [{"event_id": "E1", "blocks": [1]}, {"event_id": "E2", "blocks": [2]}]
    payload = {"commitments": [{"line_id": 3, "event_id": "E9(模型伪造)"}, {"line_id": 15}],
               "stances": [], "pendings": [], "key_points": [], "topic_keys": []}
    ts.assign_event_ids(payload, groups, cands)
    assert payload["commitments"][0]["event_id"] == "E1"   # 伪造的被机械覆盖
    assert payload["commitments"][1]["event_id"] == "E2"


def test_event_line_range_is_mechanical():
    """事件的行范围从分组来(M5-1),一组多块取首尾;模型自己写的范围被覆盖。"""
    cands = [{"no": n, "line_from": a, "line_to": b, "chars": 1, "t_from": 0, "t_to": 0,
              "speakers": [], "gap_prev": 0} for n, a, b in [(1, 1, 10), (2, 11, 20), (3, 21, 30)]]
    groups = [{"event_id": "E1", "blocks": [1, 2]}, {"event_id": "E2", "blocks": [3]}]
    payload = {"commitments": [], "stances": [], "pendings": [], "key_points": [], "topic_keys": [],
               "events": [{"event_id": "E1", "title": "a", "summary": "b", "line_from": 999},
                          {"event_id": "E2", "title": "c", "summary": "d"},
                          {"event_id": "E9", "title": "模型多编的", "summary": "x", "line_from": 5}]}
    ts.assign_event_ids(payload, groups, cands)
    e1, e2, e9 = payload["events"]
    assert (e1["line_from"], e1["line_to"]) == (1, 20), e1
    assert (e2["line_from"], e2["line_to"]) == (21, 30), e2
    assert "line_from" not in e9 and "line_to" not in e9   # 对不上分组的:模型写的也不采信


def test_stage2_prompt_is_v1_superset():
    """契约防漂移：v1 六类的必填字段全部出现在 Stage 2 prompt 里。"""
    rows = _lines([(0, "内容", "说话人1")])
    c = ts.candidates(rows)
    p = ts.render_stage2_prompt(rows, [{"event_id": "E1", "blocks": [1]}], c)
    for kind, fields in v1._REQUIRED_FIELDS.items():
        assert f'"{kind}"' in p, kind
        for f in fields:
            assert f'"{f}"' in p, (kind, f)
    assert '"events"' in p and "speaker_hint" in p


def test_dropped_high_starts_new_group_even_inside_current_part():
    c = [{"no": i, "gap_prev": 0} for i in (1, 2, 3)]
    labels = {1: {"tier_event": "medium", "user_relevance": "相关"},
              2: {"tier_event": "high", "user_relevance": "无关"},
              3: {"tier_event": "medium", "user_relevance": "相关"}}
    groups, dropped = ts.group_blocks(c, labels, {"event_id": 12})
    assert [g["blocks"] for g in groups] == [[1], [3]], groups
    assert groups[0]["continuation_id"] == 12 and "continuation_id" not in groups[1]
    assert dropped == [2]


def test_empty_event_title_is_retried_before_caching():
    rows = _lines([(0, "项目讨论", "簇1")])
    rows[0].update(recipe=ts.PROMPT_VERSION, streaming=True)
    attempts = []
    def call(prompt, **kw):
        attempts.append(kw["scene"])
        if kw["scene"] == ts.SCENE_S1:
            return "#C 1 medium full 相关 项目"
        return ts.json.dumps({"one_liner": "项目讨论", **{k: [] for k in v1.ALL_KINDS},
                              "events": [{"event_id": "E1", "title": "", "summary": "项目讨论"}]})
    try:
        ts.run(rows, model_call=call)
        raise AssertionError("空标题事件不能永久缓存为成功")
    except v1.SchemaError:
        assert attempts.count(ts.SCENE_S2) == 4


def test_s2_event_order_follows_mechanical_groups():
    rows = _lines([(0, "A" * 2000, "簇1"), (300, "B" * 2000, "簇2")])
    rows[0].update(recipe=ts.PROMPT_VERSION, streaming=True,
                   stream_context={"event_id": 12, "t_end_sec": 0})
    def call(prompt, **kw):
        if kw["scene"] == ts.SCENE_S1:
            return "#C 1 medium full 相关 A\n#C 2 high full 相关 B"
        return ts.json.dumps({"one_liner": "两件事", **{k: [] for k in v1.ALL_KINDS},
                              "key_points": [{"point": "A", "quote": "A" * 20, "line_id": 1},
                                             {"point": "B", "quote": "B" * 20, "line_id": 2}],
                              "events": [{"event_id": "E2", "title": "B", "summary": "B"},
                                         {"event_id": "E1", "title": "A", "summary": "A"}]})
    payload, _, _ = ts.run(rows, model_call=call)
    assert [e["event_id"] for e in payload["events"]] == ["E1", "E2"]
    assert payload["events"][0]["continuation_id"] == 12


def test_no_focus_and_topic_only_event_is_not_published():
    rows = _lines([(0, "然后", "簇1"), (180, "他在那个地方", "簇1")])
    original = ts.json.dumps(rows)
    def call(prompt, **kw):
        if kw["scene"] == ts.SCENE_S1:
            return "#C1 high compressed 相关 零碎发言"
        return ts.json.dumps({"one_liner": "没有可辨识的事项", **{k: [] for k in v1.ALL_KINDS},
                              "topic_keys": [{"key": "零碎发言", "line_ids": [1, 2]}],
                              "events": [{"event_id": "E1", "title": "零碎发言", "summary": "只有残句"}]})
    payload, stats, meta = ts.run(rows, model_call=call)
    assert payload["events"] == [] and stats.total == 0
    assert meta["suppressed_event_ids"] == ["E1"] and len(meta["attempts"]) == 2
    assert ts.json.dumps(rows) == original, "不展示不能删除或改写原话"


def test_personal_activity_pending_focus_keeps_event_with_mechanical_identity():
    rows = _lines([(0, "今天完成划船训练，明天休息", "簇1")])
    def call(prompt, **kw):
        if kw["scene"] == ts.SCENE_S1:
            return "#C1 high full 相关 训练进展"
        return ts.json.dumps({"one_liner": "训练与恢复", **{k: [] for k in v1.ALL_KINDS},
                              "key_points": [{"point": "已完成划船，明天休息", "quote": rows[0]["text"],
                                              "line_id": 1, "event_id": "E999"}],
                              "events": [{"event_id": "E1", "title": "训练", "summary": "完成训练后恢复"}]})
    payload, stats, _ = ts.run(rows, model_call=call)
    assert len(payload["events"]) == 1 and payload["key_points"][0]["event_id"] == "E1"
    assert stats.pending == 1 and stats.passed == 0, "未知归属仍有原话价值，不能当作没有重点"


def test_one_good_event_does_not_hide_other_events_failed_focus():
    rows = _lines([(0, "A" * 2000, "簇1"), (300, "B" * 2000, "簇2")])
    providers = []
    def call(prompt, **kw):
        if kw["scene"] == ts.SCENE_S1:
            return "#C1 high full 相关 A\n#C2 high full 相关 B"
        providers.append(kw.get("provider"))
        return ts.json.dumps({"one_liner": "两件事", **{k: [] for k in v1.ALL_KINDS},
                              "key_points": [{"point": "A", "quote": "A" * 20, "line_id": 1},
                                             {"point": "B", "quote": "并不存在的原话", "line_id": 2}],
                              "events": [{"event_id": "E1", "title": "A", "summary": "A"},
                                         {"event_id": "E2", "title": "B", "summary": "B"}]})
    try:
        ts.run(rows, model_call=call)
        raise AssertionError("E2的重点证据全失败，不能静默删掉E2并报成功")
    except v1.SchemaError as error:
        assert "原话校验" in str(error)
        assert providers == [None, None, ts.FALLBACK_PROVIDER, ts.FALLBACK_PROVIDER]


def test_low_hole_inside_event_cannot_supply_focus():
    cands = [{"no": i, "line_from": i, "line_to": i} for i in (1, 2, 3)]
    groups = [{"event_id": "E1", "blocks": [1, 3]}]  # C2已被S1剔除
    item = {"line_id": 2, "quote": "广播", "event_id": "E1"}
    payload = {**{k: [] for k in v1.ALL_KINDS}, "key_points": [item],
               "events": [{"event_id": "E1", "line_from": 1, "line_to": 3}]}
    ts.assign_event_ids(payload, groups, cands)
    assert item["event_id"] is None
    try:
        ts.retain_supported_events(payload, payload, groups, cands)
        raise AssertionError("被剔除的块不能借事件首尾范围支持事件")
    except v1.SchemaError:
        pass


def test_action_responsibility_not_cross_group_evidence_supports_event():
    rows = _lines([(0, "我明天发送方案。" + "A" * 2000, "簇1"),
                   (300, "截止周五。" + "B" * 2000, "簇2")])
    rows[0].update(recipe=ts.PROMPT_VERSION, streaming=True, action_protocol="personal-actions/v1")
    def call(prompt, **kw):
        if kw["scene"] == ts.SCENE_S1:
            return "#C1 high full 相关 发送方案\n#C2 high compressed 相关 时间"
        return ts.json.dumps({"one_liner": "发送方案", **{k: [] for k in v1.ALL_KINDS},
                              "action_protocol": "personal-actions/v1",
                              "personal_actions": [{"kind": "accepted", "title": "发送方案", "line_id": 1,
                                  "quote": "我明天发送方案。", "evidence": [
                                      {"line_id": 1, "quote": "我明天发送方案。"}, {"line_id": 2, "quote": "截止周五。"}],
                                  "condition_text": "", "deadline_text": "周五", "collaborators_text": ""}],
                              "events": [{"event_id": "E1", "title": "发送方案", "summary": "需要发方案"},
                                         {"event_id": "E2", "title": "时间", "summary": "时间"}]})
    payload, _, meta = ts.run(rows, model_call=call)
    assert [e["event_id"] for e in payload["events"]] == ["E1"]
    assert len(payload["personal_actions"]) == 1 and meta["suppressed_event_ids"] == ["E2"]


if __name__ == "__main__":
    import sys
    fails = 0
    for name, fn in sorted({k: v for k, v in globals().items() if k.startswith("test_")}.items()):
        try:
            fn()
            print(f"✓ {name}")
        except Exception as e:  # noqa: BLE001
            fails += 1
            print(f"✗ {name}: {e}")
    sys.exit(1 if fails else 0)

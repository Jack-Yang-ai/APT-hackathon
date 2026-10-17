#!/usr/bin/env python3
"""抽取契约的校验逻辑自测。**不调模型**,全部用手写的假 JSON。

跑:python3 -m worker.test_extract

转写行用合成的,不用旧仓那份真转写——它是真实私密对话,`.gitignore` 把 data/
整个挡在版本库外,把内容抄进测试等于绕过那条线。行的形状照着真转写造:
带簇标签的、未分人的(归属未定)、占位行、以及地铁报站那种噪声行。
真转写上的实跑结果记在 TASKS.md M0-6 的「实际」里。
"""
from __future__ import annotations

import json

from .extract import (
    MAX_TOKENS, ExtractionStats, SchemaError, TruncatedOutputError,
    parse_model_output, render_prompt, validate, validate_schema,
)

# 照着真转写的形状造:1001 正常、1002 未分人(归属未定)、1003 占位行、
# 1004 报站噪声(有归属,内容是噪声——校验管不着内容好坏,那是播报闸的活)
LINES = [
    {"line_id": 1001, "text": "那我周三之前,把接口文档给老王。", "is_gap": 0,
     "person_id": 7, "cluster_tag": "说话人2"},
    {"line_id": 1002, "text": "预算这块我还得再跟财务确认一下。", "is_gap": 0,
     "person_id": None, "cluster_tag": "说话人3"},
    {"line_id": 1003, "text": "〔此处缺失 30 秒〕", "is_gap": 1,
     "person_id": None, "cluster_tag": None},
    {"line_id": 1004, "text": "本次列车终点站嘉定北站,请您携带好行李物品。", "is_gap": 0,
     "person_id": 12, "cluster_tag": "说话人5"},
]


def _payload(**over):
    base = {
        "one_liner": "定了接口文档的交付时间,预算待确认",
        "key_points": [], "commitments": [], "stances": [], "pendings": [], "topic_keys": [],
    }
    base.update(over)
    return base


# ── schema 校验 ────────────────────────────────────────────────────

def test_valid_payload_passes_schema():
    validate_schema(_payload(commitments=[
        {"what": "交接口文档", "quote": "周三之前", "line_id": 1001, "speaker_hint": "说话人2"}]))


def test_missing_array_is_rejected():
    """抽不到要给空数组,不是省略。省略和「模型忘了这一类」分不开。"""
    bad = _payload()
    del bad["stances"]
    _expect(SchemaError, lambda: validate_schema(bad), "缺 stances 应当被拒")


def test_missing_field_is_rejected():
    _expect(SchemaError,
            lambda: validate_schema(_payload(key_points=[{"point": "x", "line_id": 1001}])),
            "缺 quote 应当被拒")


def test_who_field_is_rejected():
    """契约里没有 who。这是判 4 的核心,单拎一条测试盯住。"""
    _expect(SchemaError,
            lambda: validate_schema(_payload(key_points=[
                {"point": "x", "quote": "周三之前", "line_id": 1001, "who": "老王"}])),
            "出现 who 必须被拒 —— 归属只能有一个真相源")


# ── 截断:必须报错,不得当成没抽到 ──────────────────────────────────

def test_empty_output_raises():
    _expect(TruncatedOutputError, lambda: parse_model_output("   "), "空正文必须抛")


def test_truncated_json_raises():
    _expect(TruncatedOutputError,
            lambda: parse_model_output('{"one_liner": "定了交付时间", "key_po'),
            "半截 JSON 必须抛,不能当成空结果")


def test_wellformed_json_parses():
    assert parse_model_output('{"one_liner":"a"}') == {"one_liner": "a"}


# ── 三项校验 ──────────────────────────────────────────────────────

def test_passed_pending_discarded():
    payload = _payload(
        key_points=[
            # 通过:行号命中 + 逐字 + 归属已定 + 簇标签对得上
            {"point": "周三交文档", "quote": "周三之前,把接口文档给老王",
             "line_id": 1001, "speaker_hint": "说话人2"},
            # 挂起:归属未定
            {"point": "预算待确认", "quote": "还得再跟财务确认", "line_id": 1002},
            # 挂起:簇标签对不上(模型挂错行的信号)
            {"point": "报站", "quote": "终点站嘉定北站", "line_id": 1004,
             "speaker_hint": "说话人9"},
            # 丢弃:指向占位行(A6)
            {"point": "缺失段", "quote": "此处缺失", "line_id": 1003},
            # 丢弃:行号不存在
            {"point": "无中生有", "quote": "随便", "line_id": 9999},
            # 丢弃:quote 不是原文子串
            {"point": "改写过头", "quote": "我会在周三把文档发给王总", "line_id": 1001},
        ])
    clean, stats = validate(payload, LINES)

    assert (stats.total, stats.passed, stats.pending, stats.discarded) == (6, 1, 2, 3), stats.as_dict()
    assert stats.failure_rate == 0.5, stats.as_dict()
    assert stats.pending_rate == 0.3333, stats.as_dict()
    assert dict(stats.discard_reasons) == {
        "指向占位行": 1, "行号不存在": 1, "quote 非原文子串": 1}, stats.as_dict()
    assert dict(stats.pending_reasons) == {
        "归属未定": 1, "簇标签与 speaker_hint 不一致": 1}, stats.as_dict()
    # 丢弃的不进产出,挂起的进产出并带标记
    assert len(clean["key_points"]) == 3
    assert [i.get("pending", False) for i in clean["key_points"]] == [False, True, True]


def test_quote_that_normalizes_to_nothing_is_discarded():
    """⚠️ 归一后才变空的 quote 也算没给引文(2026-08-14 修的洞)。

    原来只挡 `if not quote`,于是一条 `"quote": "。"` 会**通过**逐字校验 ——
    标点被归一规则全部去掉,剩下空串,又落回「空串是任何串的子串」那个洞。
    这是同一个错法的另一半:挡住了「没给引文」,没挡住「引文里一个可比对的字都没有」。

    后果不是崩,是**一条编造的条目静默通过**,而逐字通过率正是 R4
    用来决定「要不要先修抽取、不往下建内容层」的那个数。
    """
    for junk in ("。", "  ", "……!?", "~+=°"):
        clean, stats = validate(_payload(key_points=[
            {"point": "编的", "quote": junk, "line_id": 1001}]), LINES)
        assert stats.discarded == 1, f"quote={junk!r} 没被丢弃:{stats.as_dict()}"
        assert dict(stats.discard_reasons) == {"quote 非原文子串": 1}
        assert clean["key_points"] == []


def test_speaker_hint_is_stripped():
    """只用于校验、永不落库。校验完必须剥掉。"""
    payload = _payload(commitments=[
        {"what": "交文档", "quote": "周三之前", "line_id": 1001, "speaker_hint": "说话人2"}])
    clean, _ = validate(payload, LINES)
    assert "speaker_hint" not in clean["commitments"][0], clean["commitments"][0]
    assert clean["commitments"][0]["what"] == "交文档"


def test_normalization_tolerates_punctuation_and_width():
    """原话带标点、模型输出去了标点或用了全角,仍算逐字通过——
    否则三项校验会误杀一大片正确条目。"""
    payload = _payload(commitments=[
        {"what": "交文档", "quote": "周三之前 把接口文档给老王", "line_id": 1001,
         "speaker_hint": "说话人2"}])
    _, stats = validate(payload, LINES)
    assert stats.passed == 1, stats.as_dict()


def test_empty_quote_never_passes():
    """空 quote 不能算逐字通过。空串是任何串的子串,不挡住就全员静默过关。"""
    payload = _payload(key_points=[{"point": "x", "quote": "", "line_id": 1001}])
    _, stats = validate(payload, LINES)
    assert stats.discarded == 1, stats.as_dict()


def test_topic_keys_drop_unknown_line_ids():
    """topic_keys 没有 quote,跑不了逐字;至少把不存在的行号剔掉。"""
    payload = _payload(topic_keys=[{"key": "交付", "line_ids": [1001, 9999]}])
    clean, _ = validate(payload, LINES)
    assert clean["topic_keys"][0]["line_ids"] == [1001]


def test_stats_are_none_not_zero_when_nothing_checkable():
    """一条可校验条目都没有时是 None,不是 0.0——
    「没有可算的」和「一条都没丢」不是一回事。"""
    _, stats = validate(_payload(), LINES)
    assert stats.failure_rate is None and stats.pending_rate is None


def test_stats_travel_with_results():
    """结果和账本绑在一起返回,拿到结果就必然拿到计数——静默丢弃没处躲。"""
    result = validate(_payload(), LINES)
    assert isinstance(result, tuple) and isinstance(result[1], ExtractionStats)


# ── prompt ────────────────────────────────────────────────────────

def test_max_tokens_meets_floor():
    """Generic implementation; local private materials are not distributed."""
    assert MAX_TOKENS >= 20000


def test_prompt_carries_line_ids_and_forbids_who():
    prompt = render_prompt(LINES)
    assert "1001 | 说话人2 |" in prompt, "行号与簇标签要喂给模型"
    assert "1003 | 未分人 |" in prompt, "没有簇标签的行也要有位置"
    assert "不要写「谁说的」" in prompt
    assert "逐字照抄" in prompt


def _expect(exc, fn, msg):
    try:
        fn()
    except exc:
        return
    raise AssertionError(msg)


def _run_all():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"PASS {fn.__name__}")
    print(f"all passed ({len(fns)})")


if __name__ == "__main__":
    _run_all()

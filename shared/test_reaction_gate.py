#!/usr/bin/env python3
"""反应分诊的词面那一半(`M2-检2` §3.4)。

    python3 -m shared.test_reaction_gate

这一组钉三件事:命中的必须强制落账(不许交给模型抖)· 没有系统上一句时一律不判 ·
同样的输入两次跑同一个答案。
"""
from __future__ import annotations

import sys

from shared.reaction_gate import classify

tests = []


def test(fn):
    tests.append(fn)
    return fn


REPLY = "我看了一下,这件事你上周已经跟老周确认过了。"


# ── 命中即强制 ────────────────────────────────────────────────────────

@test
def test_dissatisfaction_is_forced_and_bad():
    for text in ["不对啊", "不是这个意思", "你根本没懂", "答非所问", "这也太敷衍了",
                 "That's not what I asked"]:
        got = classify(text, REPLY)
        assert got["forced"], text
        assert got["polarity"] == "bad", text


@test
def test_correction_is_forced_and_bad():
    for text in ["我说的是老李不是老周", "你记错了", "应该是下周三", "I meant Thursday"]:
        got = classify(text, REPLY)
        assert got["forced"], text
        assert got["kind"] == "correction", text
        assert got["polarity"] == "bad", text


@test
def test_appreciation_is_forced_and_good():
    for text in ["谢谢,就是这个", "太好了", "这个有帮助", "Exactly"]:
        got = classify(text, REPLY)
        assert got["forced"], text
        assert got["kind"] == "appreciation", text
        assert got["polarity"] == "good", text


@test
def test_the_voicemem_case_that_a_small_model_flip_flopped_on():
    """Generic implementation; local private materials are not distributed."""

    text = "不是这个意思,你根本没懂"
    first, second = classify(text, REPLY), classify(text, REPLY)
    assert first["forced"] and first["polarity"] == "bad"
    assert first == second


@test
def test_correction_wins_over_dissatisfaction_when_both_appear():
    """两类都命中时取纠正 —— 它更具体,而下游处置不同:
    纠正要去改那条记错的,不满只调递送策略。"""
    got = classify("不对,我说的是老李", REPLY)
    assert got["kind"] == "correction", got


# ── 硬前件:必须有系统上一句 ──────────────────────────────────────────

@test
def test_without_a_prior_reply_nothing_is_judged():
    """🔴 用户情绪不好 ≠ 系统说错话。没有上一句可反应时一律不判 ——
    不然「今天真烦」会被记成一次系统失败,而系统那一轮根本没开口。"""
    for prior in (None, "", "   "):
        assert classify("不对啊", prior) == {"forced": False, "kind": None, "polarity": None}


@test
def test_an_empty_user_text_is_not_judged():
    for text in (None, "", "  "):
        assert classify(text, REPLY)["forced"] is False


# ── 灰区 ──────────────────────────────────────────────────────────────

@test
def test_the_grey_zone_is_left_to_the_model():
    """词面没命中的不强制,也不给极性 —— 交模型判显著性,判不出就不记。"""
    for text in ["……算了,你说吧", "嗯", "然后呢", "我再想想"]:
        got = classify(text, REPLY)
        assert got["forced"] is False, text
        assert got["kind"] is None and got["polarity"] is None, text


@test
def test_a_plain_follow_up_question_is_not_a_reaction():
    got = classify("那老周那边怎么说", REPLY)
    assert got["forced"] is False


# ── 形状 ──────────────────────────────────────────────────────────────

@test
def test_the_verdict_shape_is_closed():
    """闭集守卫:多一个取值而下游没跟着改,不会报错,只会走进 else 分支。"""
    for text in ["不对", "我说的是老李", "谢谢", "嗯"]:
        got = classify(text, REPLY)
        assert set(got) == {"forced", "kind", "polarity"}
        assert got["kind"] in {None, "dissatisfied", "correction", "appreciation"}
        assert got["polarity"] in {None, "good", "bad"}
        assert (got["kind"] is None) == (got["forced"] is False)


if __name__ == "__main__":
    failed = 0
    for fn in tests:
        try:
            fn()
            print("PASS", fn.__name__)
        except Exception as e:            # noqa: BLE001 —— 自测跑器,原因原样打出来
            failed += 1
            print("FAIL", fn.__name__, "\n   ", e)
    print(f"\n{failed} failed / {len(tests)}" if failed else f"\nall passed ({len(tests)})")
    sys.exit(1 if failed else 0)

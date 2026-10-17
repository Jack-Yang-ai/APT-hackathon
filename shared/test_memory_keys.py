#!/usr/bin/env python3
"""归一键的判决表(`M2-检2` §3.2)。

    python3 -m shared.test_memory_keys

这一组里最重要的是**两起从 VoiceMem 买来的事故**(`testcase` 名字里带「事故」的那两条):
它们都不报错、都在事后无从发现(旧值已经没了),所以只能靠这里挡。
"""
from __future__ import annotations

import sys

from shared.memory_keys import classify_attribute, supersede

tests = []


def test(fn):
    tests.append(fn)
    return fn


def item(subject="p1", attribute="现居地", value="北京",
         direct=True, joking=False, **extra) -> dict:
    return {"subject_id": subject, "attribute": attribute, "value": value,
            "direct": direct, "joking": joking, **extra}


# ── 属性三分 ──────────────────────────────────────────────────────────

@test
def test_single_valued_attributes_are_recognised():
    for name in ("现居地", "现雇主", "年龄", "关系状态", "电话"):
        assert classify_attribute(name) == "single", name


@test
def test_multi_valued_attributes_are_recognised():
    for name in ("爱好", "朋友", "过敏", "技能", "去过的地方"):
        assert classify_attribute(name) == "multi", name


@test
def test_patterns_cover_the_open_ended_single_valued_shapes():
    """「最喜欢的 X」是开集,列不完 —— 用模式收。"""
    for name in ("最喜欢的餐厅", "最喜欢的颜色", "最爱的球队", "体检的排期"):
        assert classify_attribute(name) == "single", name


@test
def test_an_unknown_attribute_is_not_guessed():
    """表里没有就返回 None。**不猜** —— 猜错的方向是覆盖,而覆盖不可逆。"""
    assert classify_attribute("这个人今天心情如何") is None
    assert classify_attribute("") is None
    assert classify_attribute(None) is None


@test
def test_an_exact_entry_beats_a_pattern():
    """精确表赢模式:模式是兜底,不该盖过写死的那条。"""
    assert classify_attribute("去过的地方") == "multi"     # 若 ^去了.+$ 抢先就成 event


# ── 🔴 两起事故 ───────────────────────────────────────────────────────

@test
def test_incident_another_persons_memory_is_never_overwritten():
    """🔴 事故一(VoiceMem/mem0):多人场景里,后说话的人把**另一个人**的同类
    偏好覆盖没了。判定只看话题不看主体时必然发生,而旧值没了之后无从发现。"""
    nancy = item(subject="nancy", attribute="最喜欢的餐厅", value="老张川菜")
    jennifer = item(subject="jennifer", attribute="最喜欢的餐厅", value="西贝")
    assert supersede(jennifer, nancy) == "never"
    # 同一个人才谈夺位。
    assert supersede(item(subject="nancy", attribute="最喜欢的餐厅", value="西贝"),
                     nancy) == "contest"


@test
def test_incident_an_event_is_never_folded_into_a_preference():
    """🔴 事故二(VoiceMem/mem0):7 月「带孩子去博物馆」被判成和 5 月
    「喜欢画画放松」同话题而并进去 —— 细节被揉平,日期还沿用了旧的那条。"""
    hobby = item(attribute="爱好", value="画画放松", valid_from="2026-05-02")
    outing = item(attribute="经历", value="带孩子去博物馆", valid_from="2026-07-11")
    assert supersede(outing, hobby) == "never", "事件与偏好属性不同,连键都不是同一个"
    # 就算属性名相同,事件也永不合并。
    a = item(attribute="经历", value="去了博物馆", valid_from="2026-07-11")
    b = item(attribute="经历", value="去爬山", valid_from="2026-09-06")
    assert supersede(b, a) == "never"


# ── 主体 ──────────────────────────────────────────────────────────────

@test
def test_a_missing_subject_appends_rather_than_overwrites():
    """主体不明时宁可留一条重复:重复很便宜(看得见、能手动合),覆盖不可逆。"""
    assert supersede(item(subject=None), item(subject="p1")) == "append"
    assert supersede(item(subject="p1"), item(subject=None)) == "append"


# ── 单值 ──────────────────────────────────────────────────────────────

@test
def test_a_single_valued_attribute_with_a_new_value_contests():
    assert supersede(item(attribute="最喜欢的餐厅", value="西贝"),
                     item(attribute="最喜欢的餐厅", value="老张川菜")) == "contest"


@test
def test_the_same_value_stated_again_is_just_more_evidence():
    assert supersede(item(value="北京"), item(value="北京")) == "append"
    assert supersede(item(value=" 北京 "), item(value="北京")) == "append"


@test
def test_a_new_value_that_is_not_a_direct_statement_only_notes_the_conflict():
    """裁决线:直陈 ∧ 非玩笑。过不了的只挂「矛盾提及」,不夺位(v4 §五)。"""
    assert supersede(item(value="上海", direct=False), item(value="北京")) == "noted"
    assert supersede(item(value="上海", joking=True), item(value="北京")) == "noted"


# ── 多值 ──────────────────────────────────────────────────────────────

@test
def test_multi_valued_attributes_accumulate():
    """过敏可以既花生又海鲜 —— 新值不顶掉旧值。"""
    assert supersede(item(attribute="过敏", value="海鲜"),
                     item(attribute="过敏", value="花生")) == "append"


@test
def test_a_multi_valued_attribute_contests_only_when_it_negates_the_old_one():
    assert supersede(item(attribute="过敏", value="不再对花生过敏", negates_old=True),
                     item(attribute="过敏", value="花生")) == "contest"


# ── 属性对不上 ────────────────────────────────────────────────────────

@test
def test_different_attributes_are_not_the_same_key():
    assert supersede(item(attribute="现居地", value="上海"),
                     item(attribute="老家", value="北京")) == "never"


@test
def test_an_unknown_attribute_appends():
    assert supersede(item(attribute="今天心情", value="好"),
                     item(attribute="今天心情", value="差")) == "append"


# ── v4 §六:时间不重叠的「矛盾」是历史 ────────────────────────────────

@test
def test_two_residences_in_disjoint_periods_still_contest_here():
    """本模块只判到 contest。**「是演变还是更正」是下一步**(v4 §五 二分):
    时间区间不重叠的两条现居地是历史,共存;重叠的才是真冲突。
    那一步要读 valid_from/valid_to,不在归一键这一层。这条钉住分界。"""
    old = item(attribute="现居地", value="北京", valid_from="2020-01-01", valid_to="2024-06-30")
    new = item(attribute="现居地", value="上海", valid_from="2024-07-01")
    assert supersede(new, old) == "contest"


# ── 判决全集 ──────────────────────────────────────────────────────────

@test
def test_every_outcome_is_one_of_the_four():
    """闭集守卫:多出一个取值而下游没跟着改,不会报错,只会走进 else 分支。"""
    cases = [
        (item(subject="a"), item(subject="b")),
        (item(subject=None), item()),
        (item(), item()),
        (item(value="上海"), item(value="北京")),
        (item(value="上海", joking=True), item(value="北京")),
        (item(attribute="过敏", value="海鲜"), item(attribute="过敏", value="花生")),
        (item(attribute="经历", value="去爬山"), item(attribute="经历", value="去博物馆")),
    ]
    for new, old in cases:
        assert supersede(new, old) in {"never", "append", "contest", "noted"}


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

#!/usr/bin/env python3
"""近重复去重(`M2-检2` §1.4)。

    python3 -m shared.test_near_duplicate

两半:**跨语言夹具**(与 Swift 那份实现算得一不一样)+ **行为**(算法本身对不对)。
夹具只管一致,行为只管正确 —— 混在一起的话,两边一起错的时候夹具照样绿。
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from shared.near_duplicate import LINE_GRAM, LINE_THRESHOLD, fold, grams, similarity

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "recall" / "near_dup_vectors.json"

tests = []


def test(fn):
    tests.append(fn)
    return fn


# ── 跨语言夹具 ────────────────────────────────────────────────────────

@test
def test_every_fixture_pair_matches_this_implementation():
    """夹具是两份实现的共同锚。Swift 侧 `NearDuplicateTests` 对着同一个文件断言,
    所以任一边改了算法而没改另一边,必有一边红。"""
    pairs = json.loads(FIXTURE.read_text(encoding="utf-8"))["pairs"]
    assert len(pairs) >= 10, f"夹具只剩 {len(pairs)} 对 —— 是不是被删过"
    for p in pairs:
        for n in (2, 3):
            got = similarity(p["a"], p["b"], n)
            assert abs(got - p[f"gram{n}"]) < 1e-12, (
                f"{p['a']!r} / {p['b']!r} 在 {n} 字组上算出 {got},夹具写的是 {p[f'gram{n}']}")


# ── 行为:元组切法 ────────────────────────────────────────────────────

@test
def test_grams_are_character_ngrams_with_punctuation_kept():
    """🔴 不去标点。任一边去了,同一对就会给出不同的分,而两边都不报错。"""
    assert grams("他说,好", 2) == {"他说", "说,", ",好"}


@test
def test_a_string_shorter_than_n_becomes_one_gram():
    assert grams("短", 2) == {"短"}
    assert grams("", 2) == set()


# ── 行为:相似度 ──────────────────────────────────────────────────────

@test
def test_identical_text_is_one():
    assert similarity("他说下周三交付", "他说下周三交付") == 1.0


@test
def test_short_opposite_sentences_stay_below_the_threshold():
    """🔴 这是这套东西最重要的一条:**误折比漏折严重得多**。
    把「要改」和「不用改」折成一条,是把答案吃掉,而界面上看不出来。

    ⚠️ 这里只断言**短反义句**。长共享前缀那一类现行参数挡不住 —— 见下一条。
    """
    for a, b in [("交付时间要重排一下", "交付时间不用改了"),
                 ("老周同意了", "老周不同意"),
                 ("下周三交付", "下周三不交付"),
                 ("这个可以", "这个不可以")]:
        assert similarity(a, b, LINE_GRAM) < LINE_THRESHOLD, (a, b)


@test
def test_a_negation_buried_in_a_long_shared_prefix_is_a_known_hole():
    """🔴 **已上线的行级去重会把这两对折成一条,而它们意思相反。**

    共享前缀越长,一个「不」字被稀释得越厉害:

        这个方案可以 / 这个方案不可以                    2 字组 0.571 ≥ 0.55 ⇒ 折
        首页结构先收敛,再补推荐逻辑 / …,不补推荐逻辑        2 字组 0.733 ≥ 0.55 ⇒ 折

    这条测试**钉的是现状,不是应该**:登记在 `TASKS.md` `M2-检3`,
    数与量法在 `docs/evidence/m2-检2/near_dup.md`。修法要等 §1.4 的标注数据 ——
    现在凭感觉调阈值,正是仓规「金标治理 > 机制调参」说的那个错。
    **修好之后这条会红,那时把它改成上面那条的断言。**
    """
    for a, b in [("这个方案可以", "这个方案不可以"),
                 ("首页结构先收敛,再补推荐逻辑", "首页结构先收敛,不补推荐逻辑")]:
        assert similarity(a, b, LINE_GRAM) >= LINE_THRESHOLD, (
            f"{a!r}/{b!r} 现在不折了 —— 缺陷修好了?把这条改成 "
            f"test_short_opposite_sentences_stay_below_the_threshold 的断言")


@test
def test_a_rewording_of_the_same_thing_is_above_the_threshold():
    assert similarity("今天感到很累,可能与明天下午的会议有关",
                      "最近感到很累,可能与明天下午的会议有关", LINE_GRAM) >= LINE_THRESHOLD


# ── 行为:折叠 ────────────────────────────────────────────────────────

def _fold(texts, keys=None):
    items = list(zip(keys or [1] * len(texts), texts))
    return fold(items, key=lambda x: x[0], text=lambda x: x[1])


@test
def test_folding_keeps_the_first_occurrence_and_counts_the_rest():
    """保留先出现的那一条:调用方按时间倒序传进来,留下的就是**最近一次**说的。"""
    kept = _fold(["今天感到很累,可能与明天下午的会议有关",
                  "最近感到很累,可能与明天下午的会议有关"])
    assert len(kept) == 1
    assert kept[0][0][1].startswith("今天"), "留下的不是先出现的那条"
    assert kept[0][1] == 1


@test
def test_folding_never_crosses_groups():
    """🔴 只在同一场次内折。**跨三场都在说是信号,不是噪音** ——
    「他第 3 次提到交付时间」正是这个产品最想抓的东西,跨场折叠会把它亲手抹掉。"""
    same = "今天感到很累,可能与明天下午的会议有关"
    kept = _fold([same, same], keys=[1, 2])
    assert len(kept) == 2, "跨场次被折了"
    assert all(k[1] == 0 for k in kept)


@test
def test_folding_reports_how_many_were_dropped():
    """折叠是丢信息,所以要说出来:界面照实写「还有 N 条几乎一样的」。
    悄悄丢的后果是用户以为只有这一条,而「说了几遍」正是他想知道的。"""
    base = "今天感到很累,可能与明天下午的会议有关"
    kept = _fold([base, base, base, "最近开始规律健身"])
    assert len(kept) == 2
    assert kept[0][1] == 2


@test
def test_opposite_sentences_are_not_folded_together():
    kept = _fold(["交付时间要重排一下", "交付时间不用改了"])
    assert len(kept) == 2, "反义句被折成一条 —— 那是把答案吃掉"


@test
def test_folding_an_empty_list_is_empty():
    assert _fold([]) == []


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

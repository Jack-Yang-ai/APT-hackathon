#!/usr/bin/env python3
"""抽取质量尺子的自测:两条手写假数据把六个数逐个对一遍。

跑:python3 -m eval.test_extract_quality
"""
from __future__ import annotations

import json
from pathlib import Path

from .extract_quality import (
    GoldFormatError, THRESHOLDS, gate, load_gold, normalize_v1, score,
)

HERE = Path(__file__).resolve().parent


def _gold(lines, key_points=(), commitments=()):
    return {
        "schema": "growth.extract_gold/1",
        "session_id": "t",
        "lines": lines,
        "gold": {"key_points": list(key_points), "commitments": list(commitments)},
    }


# ── 假数据一:四种情况都占齐(通过 / 挂起 / 丢弃 / 漏抽)────────────────

def test_case_one_mixed():
    gold = json.loads((HERE / "gold" / "example.json").read_text(encoding="utf-8"))
    output = json.loads((HERE / "gold" / "example_output.json").read_text(encoding="utf-8"))
    m = score(gold, output)["metrics"]

    # 5 个可校验条目:要点 3(1 条挂在占位行上被丢)+ 承诺 1 + 表态 1(归属未定 → 挂起)
    assert m["first_pass_rate"] == 0.6, m           # 3/5
    assert m["pending_rate"] == 0.2, m              # 1/5
    assert m["commitment_recall"] == 0.5, m         # 金标 2 条,系统只交付 1 条
    assert m["commitment_precision"] == 1.0, m      # 交付的那 1 条是对的
    assert m["key_point_anchor_rate"] == 0.6667, m  # 3 条要点里 2 条锚得住
    assert m["miss_rate"] == 0.25, m                # 金标 4 条,漏了预算那条承诺

    c = score(gold, output)["counts"]
    assert (c["passed"], c["pending"], c["discarded"]) == (3, 1, 1), c


# ── 假数据二:全中,六个数都该是满分 ────────────────────────────────
#    没有这条,「尺子恒返回同一组数」也能骗过第一条。

def test_case_two_perfect():
    lines = [
        {"line_id": 1, "text": "周五之前把方案发出去", "is_gap": 0, "person_id": 5, "cluster_tag": "说话人1"},
        {"line_id": 2, "text": "预算上限是二十万", "is_gap": 0, "person_id": 6, "cluster_tag": "说话人2"},
    ]
    gold = _gold(lines,
                 key_points=[{"line_id": 2, "point": "预算上限二十万"}],
                 commitments=[{"line_id": 1, "what": "周五前发方案"}])
    output = {
        "key_points": [{"point": "预算上限二十万", "quote": "预算上限是二十万", "line_id": 2, "speaker_hint": "说话人2"}],
        "commitments": [{"line_id": 1, "what": "周五前发方案", "quote": "周五之前把方案发出去", "speaker_hint": "说话人1"}],
        "stances": [], "pendings": [],
    }
    m = score(gold, output)["metrics"]
    assert m == {
        "first_pass_rate": 1.0, "pending_rate": 0.0,
        "commitment_recall": 1.0, "commitment_precision": 1.0,
        "key_point_anchor_rate": 1.0, "miss_rate": 0.0,
    }, m


# ── 打自己的实现 ──────────────────────────────────────────────────

def test_zero_denominator_is_none_not_zero():
    """一条都没有时返回 None。「没有可算的」和「一个都没中」不是一回事,
    折成 0.0 会让空跑看起来像跑砸了,也会让门禁误判。"""
    gold = _gold([{"line_id": 1, "text": "随便", "is_gap": 0, "person_id": 1}])
    m = score(gold, {"key_points": [], "commitments": [], "stances": [], "pendings": []})["metrics"]
    assert m["first_pass_rate"] is None, m
    assert m["commitment_recall"] is None, m
    assert m["key_point_anchor_rate"] is None, m


def test_normalize_folds_punctuation_width_and_case():
    """判 4 的归一:NFKC + 去标点空白 + 全半角/大小写。"""
    assert normalize_v1("ＡＢＣ, 你好！") == normalize_v1("abc你好")
    assert normalize_v1("周三 之前,把 文档 给老王。") == normalize_v1("周三之前把文档给老王")


def test_quote_matches_after_normalization():
    """原话带标点、系统输出去了标点,仍应算逐字通过——否则校验会误杀一大片。"""
    lines = [{"line_id": 1, "text": "那我周三之前,把接口文档给老王。", "is_gap": 0, "person_id": 2}]
    gold = _gold(lines, commitments=[{"line_id": 1, "what": "给文档"}])
    output = {"commitments": [{"line_id": 1, "what": "给文档", "quote": "周三之前 把接口文档给老王"}]}
    assert score(gold, output)["metrics"]["first_pass_rate"] == 1.0


def test_gap_line_reference_is_discarded():
    """占位行不可被引用为证据(A6)——引用它的条目必须丢弃,不是挂起。"""
    lines = [{"line_id": 1, "text": "〔此处缺失 30 秒〕", "is_gap": 1, "person_id": None}]
    gold = _gold(lines)
    output = {"key_points": [{"point": "x", "quote": "此处缺失", "line_id": 1}]}
    c = score(gold, output)["counts"]
    assert (c["passed"], c["pending"], c["discarded"]) == (0, 0, 1), c


def test_cluster_tag_mismatch_is_pending_not_discarded():
    """speaker_hint 与簇标签对不上 → 挂起复核,不丢弃(§4.2)。"""
    lines = [{"line_id": 1, "text": "预算二十万", "is_gap": 0, "person_id": 9, "cluster_tag": "说话人1"}]
    gold = _gold(lines)
    output = {"key_points": [{"point": "x", "quote": "预算二十万", "line_id": 1, "speaker_hint": "说话人4"}]}
    c = score(gold, output)["counts"]
    assert (c["passed"], c["pending"], c["discarded"]) == (0, 1, 0), c


def test_unknown_line_id_is_discarded():
    """行号不存在 → 丢弃。拿不到行号的条目本来就不进库(§4.2)。"""
    gold = _gold([{"line_id": 1, "text": "在的", "is_gap": 0, "person_id": 1}])
    output = {"key_points": [{"point": "x", "quote": "不在的", "line_id": 999}]}
    assert score(gold, output)["counts"]["discarded"] == 1


def test_broken_gold_raises():
    """金标坏了要抛。拿坏尺子量出来的数比没有数更糟。"""
    for bad in ({"schema": "别的/9"},
                {"schema": "growth.extract_gold/1", "session_id": "t"},
                _gold([{"line_id": 1, "text": "a", "is_gap": 0},
                       {"line_id": 1, "text": "b", "is_gap": 0}])):
        path = HERE / "_tmp_bad_gold.json"
        path.write_text(json.dumps(bad, ensure_ascii=False), encoding="utf-8")
        try:
            load_gold(path)
        except GoldFormatError:
            pass
        else:
            raise AssertionError(f"这份坏金标本该被拒:{bad}")
        finally:
            path.unlink()


def test_gate_refuses_when_thresholds_undecided():
    """达标线没拍板时门禁必须不通过。默认放行 = 门禁从来没生效过。"""
    assert all(v is None for v in THRESHOLDS.values()), "达标线还没拍板,这条测试的前提就变了"
    perfect = {k: 1.0 for k in THRESHOLDS}
    perfect["pending_rate"] = perfect["miss_rate"] = 0.0
    problems = gate(perfect)
    assert len(problems) == len(THRESHOLDS), problems
    assert all("未拍板" in p for p in problems), problems


def _run_all():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"PASS {fn.__name__}")
    print(f"all passed ({len(fns)})")


if __name__ == "__main__":
    _run_all()

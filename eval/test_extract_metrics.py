#!/usr/bin/env python3
"""`eval/extract_metrics.py` 的自测:手写假数据,把每个数逐个对完。

跑:python3 -m eval.test_extract_metrics

为什么每条都手算一遍而不是「跑通就行」:这把尺子的全部价值是**它给的数可信**。
一把「怎么喂都给个数」的尺子与没有尺子一样,只是它看起来量过
(`M3-J1` 那条:每条构造一份该红的卷子,断言它真的红)。
"""
from __future__ import annotations

import sys

from .extract_metrics import measure, payload_lines, stability, summarize

FAILED: list[str] = []


def eq(got, want, what: str) -> None:
    if got != want:
        FAILED.append(f"{what}: got {got!r} want {want!r}")


def _rec(**kw):
    base = {"arm": "A", "session": "s1", "run": 1, "ok": True, "seconds": 10.0,
            "lines": 100, "chars": 2000, "tokens_out": 4000, "cost_usd": 0.02,
            "meta": {"attempts": [{"ok": True}]},
            "stats": {"total": 10, "passed": 6, "pending": 2, "discarded": 2,
                      "discard_reasons": {"quote 非原文子串": 2}}}
    base.update(kw)
    return base


def _payload(kp=(), co=(), st=(), pe=()):
    mk = lambda ids: [{"line_id": i, "quote": "x"} for i in ids]  # noqa: E731
    return {"one_liner": "x", "topic_keys": [], "key_points": mk(kp),
            "commitments": mk(co), "stances": mk(st), "pendings": mk(pe)}


# ── payload_lines:三代归一 ─────────────────────────────────────

def test_归一_v1四类():
    got = payload_lines(_payload(kp=(1, 2), co=(3,), st=(), pe=(1,)))
    eq(sorted(got), [("commitments", 3), ("key_points", 1), ("key_points", 2),
                     ("pendings", 1)], "v1 四类归一")


def test_归一_v3_events_insights():
    p = {"todos": [{"line_id": 5}],
         "events": [{"insights": [{"source_line_ids": [7, 8]}]}]}
    eq(sorted(payload_lines(p)), [("insights", 7), ("insights", 8), ("todos", 5)],
       "v3 event+insight 归一")


def test_认不出的形状要抛不要静默返回空():
    """🔴 这是最要紧的一条:静默返回空会被读成「这场没抽到」,
    而真相是「尺子不认识这一代产物」—— 两者在报表上一模一样。"""
    try:
        payload_lines({"某个新契约": [1, 2, 3]})
    except ValueError:
        return
    FAILED.append("认不出的产物形状没抛异常 —— 它会静默变成 0 条")


def test_非整数line_id不计入():
    eq(payload_lines({"key_points": [{"line_id": None}, {"line_id": "3"}]}), [],
       "line_id 非整数不计入")


# ── measure:每个数手算 ────────────────────────────────────────

def test_measure_六个数手算():
    m = measure(_rec(), _payload(kp=(1, 2, 3), co=(2,), st=(), pe=()))
    # 条目 4 条,涉及行 {1,2,3} = 3 行;chars 2000 ⇒ 2 千字
    eq(m["items"], 4, "条目数")
    eq(m["items_per_kchar"], 2.0, "条/千字 = 4/2")
    eq(m["line_coverage"], 0.03, "行覆盖 = 3/100")
    eq(m["dup_ratio"], round(4 / 3, 4), "重复计 = 4条/3行")
    eq(m["discard_rate"], 0.2, "丢弃率 = 2/10")
    eq(m["pending_rate"], 0.2, "挂起率 = 2/10")
    eq(m["out_per_kchar"], 2000.0, "出tok/千字 = 4000/2")
    eq(m["usd_per_kchar"], 0.01, "$/千字 = 0.02/2")


def test_重复计抓得到M2J6那个形状():
    """Generic implementation; local private materials are not distributed."""

    p = _payload(kp=(1, 2, 3, 4, 5), st=(1, 2, 3, 4, 5), pe=(1, 2, 3, 4, 5))
    m = measure(_rec(stats={"total": 15, "passed": 15, "pending": 0,
                            "discarded": 0, "discard_reasons": {}}), p)
    eq(m["dup_ratio"], 3.0, "同一批行被计进三个类 ⇒ 重复计 3.0")
    eq(m["discard_rate"], 0.0, "而丢弃率纹丝不动 —— 现有指标抓不到它")


def test_分母为0给None不给0():
    """「没有可算的」和「一个都没有」是两回事。给 0.0 会静默算出一个假分数。"""
    m = measure(_rec(chars=0, lines=0,
                     stats={"total": 0, "passed": 0, "pending": 0, "discarded": 0,
                            "discard_reasons": {}}), _payload())
    for k in ("items_per_kchar", "line_coverage", "dup_ratio",
              "discard_rate", "usd_per_kchar"):
        eq(m[k], None, f"{k} 分母 0 时应为 None")


def test_失败跑不去量产物但照样计进成功率():
    """Generic implementation; local private materials are not distributed."""


    rows = [measure(_rec(ok=True), _payload(kp=(1,))),
            measure(_rec(ok=False, run=2), {})]          # 空 payload 不许抛
    eq(summarize(rows, "arm")[0]["ok_rate"], 0.5, "一成功一失败 ⇒ 成功率 0.5")


def test_成功跑遇到认不出的契约仍然抛():
    """上一条放宽的是失败跑。**成功跑那道闸不许跟着松** ——
    松了就回到「静默 0 条」,而那正是这把尺子最怕的失效方式。"""
    try:
        measure(_rec(ok=True), {"某个新契约": []})
    except ValueError:
        return
    FAILED.append("成功跑遇到认不出的契约没抛 —— 闸被上一条放宽带松了")


def test_重试次数从attempts数():
    m = measure(_rec(meta={"attempts": [{"ok": True}, {"ok": False}, {"ok": True}]}),
                _payload(kp=(1,)))
    eq(m["retries"], 1, "重试 = attempts 里 ok=False 的次数")


# ── stability:跨次一致性 ──────────────────────────────────────

def test_跨次一致性_完全相同为1():
    rows = [measure(_rec(run=1), _payload(kp=(1, 2))),
            measure(_rec(run=2), _payload(kp=(1, 2)))]
    eq(stability(rows)["jaccard_lines"], 1.0, "两跑相同 ⇒ Jaccard 1.0")


def test_跨次一致性_完全不同为0():
    rows = [measure(_rec(run=1), _payload(kp=(1, 2))),
            measure(_rec(run=2), _payload(kp=(3, 4)))]
    s = stability(rows)
    eq(s["jaccard_lines"], 0.0, "两跑无交集 ⇒ Jaccard 0.0")
    eq(s["spread_items"], 0, "条目数相同 ⇒ 极差 0")


def test_跨次一致性_半重叠():
    rows = [measure(_rec(run=1), _payload(kp=(1, 2, 3))),
            measure(_rec(run=2), _payload(kp=(2, 3, 4)))]
    eq(stability(rows)["jaccard_lines"], 0.5, "交2并4 ⇒ 0.5")


def test_只跑一次不算一致性():
    """单跑算不出一致性。**给 0 会被读成「极不稳定」**,给 None 才是「没得算」。"""
    s = stability([measure(_rec(run=1), _payload(kp=(1,)))])
    eq(s["pairs"], 0, "单跑 ⇒ 0 对")
    eq(s["jaccard_lines"], None, "单跑 ⇒ 一致性 None")


# ── summarize:分组聚合 ───────────────────────────────────────

def test_按臂分组且丢弃原因合并():
    rows = [measure(_rec(arm="A"), _payload(kp=(1,))),
            measure(_rec(arm="B", stats={"total": 4, "passed": 4, "pending": 0,
                                         "discarded": 0, "discard_reasons": {}}),
                    _payload(kp=(1,)))]
    s = {x["arm"]: x for x in summarize(rows, "arm")}
    eq(sorted(s), ["A", "B"], "按臂分组")
    eq(s["A"]["discard_reasons"], {"quote 非原文子串": 2}, "A 臂丢弃原因合并")
    eq(s["B"]["discard_reasons"], {}, "B 臂无丢弃")
    eq(s["A"]["ok_rate"], 1.0, "成功率")


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
    if FAILED:
        print(f"🔴 {len(FAILED)} 条不过:")
        for f in FAILED:
            print(f"  · {f}")
        return 1
    print(f"✅ eval.test_extract_metrics {len(tests)} 条全过")
    return 0


if __name__ == "__main__":
    sys.exit(main())

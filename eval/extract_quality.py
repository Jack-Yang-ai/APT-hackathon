#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""































































from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# 归一函数与抽取链路**共用同一份**(shared/text_normalize.py)。
# 尺子量的正是那条链路,两边各写一份实现就会悄悄对不上,而且账面上看不出来。
from shared.text_normalize import NORMALIZER_VERSION, normalize as normalize_v1

# 达标线。**全部待拍板**——见文件头。填数字之后 --gate 才会真的生效。
THRESHOLDS: dict[str, float | None] = {
    "first_pass_rate":   None,   # ≥
    "pending_rate":      None,   # ≤
    "commitment_recall": None,   # ≥
    "commitment_precision": None,  # ≥
    "key_point_anchor_rate": None,  # ≥
    "miss_rate":         None,   # ≤
}
# 方向:达标线是下限还是上限
_DIRECTION = {
    "first_pass_rate": "min", "pending_rate": "max",
    "commitment_recall": "min", "commitment_precision": "min",
    "key_point_anchor_rate": "min", "miss_rate": "max",
}

# 带 line_id 与 quote、可机械校验的四类(§4.2)
CHECKABLE_KINDS = ("key_points", "commitments", "stances", "pendings")

GOLD_SCHEMA_ID = "growth.extract_gold/1"


# ── 金标读入与校验 ──────────────────────────────────────────────────

class GoldFormatError(ValueError):
    """金标不合 schema。直接抛——金标坏了还继续跑分,等于拿坏尺子量。"""


def load_gold(path: Path) -> dict:
    gold = json.loads(path.read_text(encoding="utf-8"))
    if gold.get("schema") != GOLD_SCHEMA_ID:
        raise GoldFormatError(f"schema 必须是 {GOLD_SCHEMA_ID},实际 {gold.get('schema')!r}")
    for key in ("session_id", "lines", "gold"):
        if key not in gold:
            raise GoldFormatError(f"缺字段 {key}")
    seen = set()
    for line in gold["lines"]:
        for key in ("line_id", "text", "is_gap"):
            if key not in line:
                raise GoldFormatError(f"lines 里缺字段 {key}: {line}")
        if line["line_id"] in seen:
            raise GoldFormatError(f"line_id 重复: {line['line_id']}")
        seen.add(line["line_id"])
    for kind in ("key_points", "commitments"):
        for item in gold["gold"].get(kind, []):
            if "line_id" not in item:
                raise GoldFormatError(f"gold.{kind} 的条目缺 line_id: {item}")
    return gold


# ── 三项校验 ───────────────────────────────────────────────────────

def classify(item: dict, lines_by_id: dict) -> str:
    """把一个条目判进 discarded / pending / passed 三个桶之一。"""
    line = lines_by_id.get(item.get("line_id"))
    if line is None or line.get("is_gap", 0) == 1:
        return "discarded"                                    # 行号不命中
    if normalize_v1(item.get("quote", "")) not in normalize_v1(line["text"]):
        return "discarded"                                    # 文本逐字不过
    if line.get("person_id") is None:
        return "pending"                                      # 归属未定
    hint = item.get("speaker_hint")
    if hint is not None and line.get("cluster_tag") is not None and hint != line["cluster_tag"]:
        return "pending"                                      # 簇标签对不上,挂起复核
    return "passed"


def score(gold: dict, output: dict) -> dict:
    lines_by_id = {line["line_id"]: line for line in gold["lines"]}

    verdicts = {
        kind: [(item, classify(item, lines_by_id)) for item in output.get(kind, []) or []]
        for kind in CHECKABLE_KINDS
    }
    flat = [v for kind in CHECKABLE_KINDS for v in verdicts[kind]]
    total = len(flat)
    passed = sum(1 for _, v in flat if v == "passed")
    pending = sum(1 for _, v in flat if v == "pending")

    # 交付的 = 没被丢弃的(挂起的迟早会出现,只是等归属)
    delivered_commit_lines = {
        i["line_id"] for i, v in verdicts["commitments"] if v != "discarded"
    }
    gold_commit_lines = {i["line_id"] for i in gold["gold"].get("commitments", [])}
    matched_commits = delivered_commit_lines & gold_commit_lines

    anchored = sum(
        1 for item in output.get("key_points", []) or []
        if (ln := lines_by_id.get(item.get("line_id"))) is not None
        and ln.get("is_gap", 0) == 0
        and normalize_v1(item.get("quote", "")) in normalize_v1(ln["text"])
    )
    n_key_points = len(output.get("key_points", []) or [])

    delivered_kp_lines = {i["line_id"] for i, v in verdicts["key_points"] if v != "discarded"}
    gold_kp_lines = {i["line_id"] for i in gold["gold"].get("key_points", [])}
    gold_all = gold_kp_lines | gold_commit_lines
    matched_all = (delivered_kp_lines & gold_kp_lines) | matched_commits

    def ratio(num: int, den: int) -> float | None:
        """分母为 0 时返回 None,不返回 0.0 —— 「没有可算的」和「一个都没中」是两回事。"""
        return None if den == 0 else round(num / den, 4)

    return {
        "session_id": gold["session_id"],
        "normalizer_version": NORMALIZER_VERSION,
        "metrics": {
            "first_pass_rate":       ratio(passed, total),
            "pending_rate":          ratio(pending, total),
            "commitment_recall":     ratio(len(matched_commits), len(gold_commit_lines)),
            "commitment_precision":  ratio(len(matched_commits), len(delivered_commit_lines)),
            "key_point_anchor_rate": ratio(anchored, n_key_points),
            "miss_rate":             ratio(len(gold_all - matched_all), len(gold_all)),
        },
        "counts": {
            "checkable_items": total, "passed": passed, "pending": pending,
            "discarded": total - passed - pending,
            "commitments_output": len(verdicts["commitments"]),
            "commitments_delivered": len(delivered_commit_lines),
            "commitments_gold": len(gold_commit_lines),
            "commitments_matched": len(matched_commits),
            "key_points_output": n_key_points, "key_points_anchored": anchored,
            "gold_items": len(gold_all), "gold_matched": len(matched_all),
        },
    }


def gate(metrics: dict) -> list[str]:
    """返回未通过的理由;空列表 = 放行。达标线未定时**整条门禁算不通过**。"""
    problems = []
    for name, bar in THRESHOLDS.items():
        if bar is None:
            problems.append(f"{name}: 达标线未拍板(见文件头),门禁无法判定")
            continue
        got = metrics.get(name)
        if got is None:
            problems.append(f"{name}: 分母为 0,算不出这个数")
        elif _DIRECTION[name] == "min" and got < bar:
            problems.append(f"{name}: {got} < 达标线 {bar}")
        elif _DIRECTION[name] == "max" and got > bar:
            problems.append(f"{name}: {got} > 达标线 {bar}")
    return problems


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="抽取质量臂:金标 + 系统输出 → 六个数")
    ap.add_argument("--gold", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--gate", action="store_true", help="按达标线判定,不过则退出非零")
    args = ap.parse_args(argv)

    result = score(load_gold(args.gold),
                   json.loads(args.output.read_text(encoding="utf-8")))
    print(json.dumps(result, ensure_ascii=False, indent=2))

    if args.gate:
        problems = gate(result["metrics"])
        if problems:
            print("\n门禁不通过:", file=sys.stderr)
            for p in problems:
                print(f"  · {p}", file=sys.stderr)
            return 1
        print("\n门禁通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())

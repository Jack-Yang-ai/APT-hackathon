#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""





































































from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path
from statistics import mean

# v1 / v2 的四类可校验条目。与 `worker/extract.py::ITEM_KINDS` 同源 ——
# 那边是唯一出处,这里只引用,不抄一份清单。
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker.extract import ITEM_KINDS  # noqa: E402


def payload_lines(payload: dict) -> list[tuple[str, int]]:
    """任意一代产物 → [(kind, line_id)]。**唯一随契约变的函数。**

    v1 / v2:四类条目各有 line_id。
    v3(event+insight):todos / stances / pendings 同形,外加 events[].insights[]。
    认不出的形状**返回空并不报错是错的** —— 空会被下游读成「这场没抽到」,
    而真相是「这把尺子不认识这一代」。⇒ 抛。
    """
    out: list[tuple[str, int]] = []
    seen_kind = False
    for kind in (*ITEM_KINDS, "todos"):
        items = payload.get(kind)
        if items is None:
            continue
        seen_kind = True
        for it in items:
            lid = it.get("line_id")
            if isinstance(lid, int):
                out.append((kind, lid))
    for ev in payload.get("events", []) or []:
        for ins in ev.get("insights", []) or []:
            for lid in ins.get("source_line_ids", []) or []:
                if isinstance(lid, int):
                    out.append(("insights", lid))
            seen_kind = True
    if not seen_kind:
        raise ValueError(
            f"认不出的产物形状(顶层键 {sorted(payload)}) —— "
            "新增一代契约要在 payload_lines() 里加一条,别让它静默返回空")
    return out


def _ratio(num: float, den: float) -> float | None:
    """分母 0 返回 None,不返回 0.0 —— 「没有可算的」和「一个都没有」是两回事。"""
    return None if not den else round(num / den, 4)


def measure(rec: dict, payload: dict) -> dict:
    """一次跑 → 一行数。"""
    stats = rec.get("stats") or {}
    total = stats.get("total", 0)
    kchar = (rec.get("chars") or 0) / 1000
    ok = bool(rec.get("ok"))
    # 失败跑没有产物可量(实测 D 臂:502 / 输出截断,payload 是空 dict)。
    # ⚠️ 这里**不能**走 payload_lines —— 那道「认不出的契约就抛」的闸是给
    # **成功跑**准备的,拿它去撞一个本来就该空的产物,会把「上游挂了」
    # 误报成「尺子不认识这一代」。但失败跑照样计进 ok_rate:钱花了,东西没拿到,
    # 这正是要看见的数。
    pairs = [] if not ok else payload_lines(payload)
    uniq = {lid for _, lid in pairs}
    attempts = (rec.get("meta") or {}).get("attempts") or []
    return {
        "arm": rec.get("arm", "?"), "session": rec.get("session", "?"),
        "run": rec.get("run", 0), "ok": ok,
        "retries": sum(1 for a in attempts if not a.get("ok")),
        "seconds": rec.get("seconds"),
        "out_per_kchar": _ratio(rec.get("tokens_out") or 0, kchar),
        "usd_per_kchar": _ratio(rec.get("cost_usd") or 0, kchar),
        "discard_rate": _ratio(stats.get("discarded", 0), total),
        "pending_rate": _ratio(stats.get("pending", 0), total),
        "discard_reasons": Counter(stats.get("discard_reasons") or {}),
        "items": len(pairs),
        "items_per_kchar": _ratio(len(pairs), kchar),
        "line_coverage": _ratio(len(uniq), rec.get("lines") or 0),
        "dup_ratio": _ratio(len(pairs), len(uniq)),
        "_lines": uniq,
    }


def load(dirpath: Path) -> list[dict]:
    rows = []
    for f in sorted(dirpath.glob("*.json")):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            print(f"🔴 {f.name} 解析不了:{e}", file=sys.stderr)
            continue
        if "_rec" not in d or "payload" not in d:
            continue          # 不是跑批存档(如 echo_baseline.json),跳过
        rows.append(measure(d["_rec"], d["payload"]))
    return rows


def _avg(rows: list[dict], key: str) -> float | None:
    vals = [r[key] for r in rows if r.get(key) is not None]
    return round(mean(vals), 4) if vals else None


def stability(rows: list[dict]) -> dict:
    """同场同臂两跑的一致性。**单跑不作结论,这个数就是量它有多不能作结论。**"""
    by_key: dict[tuple, list[dict]] = defaultdict(list)
    for r in rows:
        by_key[(r["arm"], r["session"])].append(r)
    jac, spread_usd, spread_items, spread_disc = [], [], [], []
    for pair in by_key.values():
        if len(pair) < 2:
            continue
        a, b = pair[0], pair[1]
        union = a["_lines"] | b["_lines"]
        if union:
            jac.append(len(a["_lines"] & b["_lines"]) / len(union))
        spread_items.append(abs(a["items"] - b["items"]))
        if a["usd_per_kchar"] and b["usd_per_kchar"]:
            spread_usd.append(abs(a["usd_per_kchar"] - b["usd_per_kchar"]))
        if a["discard_rate"] is not None and b["discard_rate"] is not None:
            spread_disc.append(abs(a["discard_rate"] - b["discard_rate"]))
    def m(v):  # noqa: E306
        return round(mean(v), 4) if v else None
    return {"pairs": len(jac), "jaccard_lines": m(jac),
            "spread_items": m(spread_items), "spread_usd_per_kchar": m(spread_usd),
            "spread_discard_rate": m(spread_disc)}


def summarize(rows: list[dict], by: str = "arm") -> list[dict]:
    groups: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        groups[r[by]].append(r)
    out = []
    for name, rs in sorted(groups.items()):
        reasons: Counter = Counter()
        for r in rs:
            reasons.update(r["discard_reasons"])
        out.append({
            by: name, "runs": len(rs),
            "ok_rate": _ratio(sum(1 for r in rs if r["ok"]), len(rs)),
            "retry_rate": _ratio(sum(r["retries"] for r in rs), len(rs)),
            "seconds": _avg(rs, "seconds"),
            "out_per_kchar": _avg(rs, "out_per_kchar"),
            "usd_per_kchar": _avg(rs, "usd_per_kchar"),
            "discard_rate": _avg(rs, "discard_rate"),
            "pending_rate": _avg(rs, "pending_rate"),
            "items_per_kchar": _avg(rs, "items_per_kchar"),
            "line_coverage": _avg(rs, "line_coverage"),
            "dup_ratio": _avg(rs, "dup_ratio"),
            "discard_reasons": dict(reasons),
            **stability(rs),
        })
    return out


_COLS = [("runs", "跑"), ("ok_rate", "成"), ("retry_rate", "重试/场"),
         ("seconds", "秒"), ("out_per_kchar", "出tok/千字"),
         ("usd_per_kchar", "$/千字"), ("discard_rate", "丢弃率"),
         ("pending_rate", "挂起率"), ("items_per_kchar", "条/千字"),
         ("line_coverage", "行覆盖"), ("dup_ratio", "重复计"),
         ("jaccard_lines", "跨次一致")]


def render(summary: list[dict], by: str) -> str:
    head = [by] + [c[1] for c in _COLS]
    body = [[str(s[by])] + [("-" if s.get(k) is None else f"{s[k]:g}") for k, _ in _COLS]
            for s in summary]
    w = [max(len(r[i]) for r in [head, *body]) for i in range(len(head))]
    line = lambda r: "  ".join(c.ljust(w[i]) for i, c in enumerate(r))  # noqa: E731
    out = [line(head), "  ".join("-" * x for x in w)] + [line(r) for r in body]
    for s in summary:
        if s["discard_reasons"]:
            out.append(f"  {s[by]} 丢弃原因:{s['discard_reasons']}")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="抽取线无真值尺子")
    ap.add_argument("archive", type=Path, help="跑批存档目录")
    ap.add_argument("--by", default="arm", choices=("arm", "session"))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    rows = load(args.archive)
    if not rows:
        print(f"🔴 {args.archive} 里没有跑批存档(要有 _rec + payload 两个顶层键)",
              file=sys.stderr)
        return 2
    summary = summarize(rows, args.by)
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, default=str))
    else:
        print(render(summary, args.by))
    return 0


if __name__ == "__main__":
    sys.exit(main())

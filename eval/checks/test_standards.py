#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""























from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from eval.standards.manifest import MANUAL, entries, load  # noqa: E402
from eval.standards.scan import ROOT, scan  # noqa: E402


def _symbol_alive(where: str) -> bool:
    """`文件::符号` 里的符号还在不在。行号会漂,符号名不会。"""
    rel, _, sym = where.partition("::")
    p = ROOT / rel
    if not p.exists():
        return False
    body = p.read_text("utf-8", errors="replace")
    return re.search(rf"(?m)^\s*(?:\w+\s+)*(?:let|var)?\s*{re.escape(sym)}\s*[:=]", body) is not None


def check() -> list[str]:
    problems: list[str] = []
    reg = load()["registry"]
    scanned = {r["where"] for r in scan()}
    manual_keys = {m["where"] for m in MANUAL}

    # ① 判决层有、登记册没有
    for w in sorted(scanned - set(reg)):
        problems.append(f"① 判决层新常量没登记:{w}\n"
                        f"   ⇒ 跑 `python3 -m eval.standards.manifest --seed` 登记,"
                        f"并在审核台上说明谁定的")

    # ② 登记册有、代码里符号没了(手工条目走 ③)
    for w in sorted(set(reg) - manual_keys):
        if w in scanned:
            continue
        if not _symbol_alive(w):
            problems.append(f"② 登记册指着一个已经不存在的符号:{w}\n"
                            f"   ⇒ 标准被改写或挪走了。改登记,别改闸")

    # ③ 手工条目的锚点还在不在
    for m in MANUAL:
        p = ROOT / m["anchor_file"]
        if not p.exists():
            problems.append(f"③ 锚点文件没了:{m['anchor_file']}({m['where']})")
            continue
        if m["anchor"] not in p.read_text("utf-8", errors="replace"):
            problems.append(f"③ 锚点找不到:{m['where']}\n"
                            f"   在 {m['anchor_file']} 里搜不到 {m['anchor']!r}\n"
                            f"   ⇒ 那段标准被改写了,而登记还指着旧文字")

    # ④ 判了 fix / kill 却还在生效
    for r in entries():
        if r["verdict"] in ("fix", "kill"):
            alive = r["where"] in scanned or (
                r["manual"] and m_anchor_alive(r))
            if alive:
                problems.append(
                    f"④ 判定是「{r['verdict']}」但代码里还在生效:{r['where']}\n"
                    f"   {r.get('note') or r.get('title')}")

    # ⑤ 声称实测却给不出出处。
    # ⚠️ **只查已经被人审过的**(verdict != pending)—— 与 ①④ 同一条软起步原则。
    # 第一版漏了这个限定,于是 21 条「注释里提过实测、但没人填过出处」的种子条目
    # 一次全红。而它们的 who 只是**从注释猜的**,拿一个猜测去红人,闸第一天就会被关掉。
    for r in entries():
        if r["verdict"] == "pending":
            continue
        if r["who"] == "measured" and not (r.get("evidence") or "").strip():
            problems.append(
                f"⑤ 标着「实测」却没有出处:{r['where']}\n"
                f"   ⇒ 「实测」是这个仓最强的背书。给不出出处就该标 ai,不是标 measured")

    return problems


def m_anchor_alive(r: dict) -> bool:
    p = ROOT / r["anchor_file"]
    return p.exists() and r["anchor"] in p.read_text("utf-8", errors="replace")


def main() -> int:
    problems = check()
    rows = entries()
    from collections import Counter
    who = Counter(r["who"] for r in rows)
    ver = Counter(r["verdict"] for r in rows)
    if problems:
        print(f"🔴 标准登记册 {len(problems)} 处不过:\n")
        for p in problems:
            print(f"  · {p}")
        return 1
    print(f"✅ 标准登记册 {len(rows)} 条对得上 · "
          f"你拍板 {who['user']} / 实测 {who['measured']} / AI {who['ai']} · "
          f"待审 {ver['pending']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

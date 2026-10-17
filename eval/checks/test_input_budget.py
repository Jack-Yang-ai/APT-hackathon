#!/usr/bin/env python3
"""长期事归属预算对撞。唯一文档契约在 eval/contracts/input-budget.md，出口 token 判据在 acceptance.md；数值须与 Swift 一致。迁移删除重复复述，不改变预算。"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

SWIFT = "ios/GrowthApp/Extraction/ProgressAttributionInput.swift"
PLAN = "eval/contracts/input-budget.md"
BOARD = "eval/contracts/acceptance.md"

# TASKS.md 里认的那一节(出口对账)。
# ⚠️ 收尾认的是**下一条任务标题** `### [`,不是任意 `### ` ——
# M2-0a 底下挂着两个不带状态标记的子标题(「对账时发现的两处冲突」「对撞脚本」),
# 而复述达标线的那两行分别落在**不同的子标题下**。按 `^### ` 收尾会只截到第一段,
# 于是少查一处,而少查一处的输出与「查过了都对」一模一样。
M2_0A = (r"^### \[.\] M2-0a\b", r"^### \[", "M2-0a 出口对账那一节")


class Red(Exception):
    """一处对不上就抛,消息直接给人看。"""


def read(rel: str) -> str:
    p = ROOT / rel
    if not p.exists():
        raise Red(f"{rel} 不在 —— 这道对撞的一端没了")
    text = p.read_text(encoding="utf-8")
    return text


def section(text: str, rel: str, start_pat: str, end_pat: str, label: str) -> str:
    """截出一节。截不到就红 —— 别静默退化成「扫全文」。"""
    m = re.search(start_pat, text, re.M)
    if not m:
        raise Red(f"在 {rel} 里找不到「{label}」(`{start_pat}`)—— "
                  f"标题被改了?这个脚本要跟着改(别让它悄悄不查)")
    rest = text[m.end():]
    e = re.search(end_pat, rest, re.M)
    return rest[: e.start()] if e else rest


def to_int(raw: str, where: str) -> int:
    """`2 万` / `20_000` / `10` → int。看不懂就红,不猜。"""
    s = raw.replace("_", "").replace(" ", "")
    if s.endswith("万"):
        head = s[:-1]
        if not head.isdigit():
            raise Red(f"{where} 抠出来的 `{raw}` 看不懂 —— 不猜,请改这个脚本")
        return int(head) * 10000
    if not s.isdigit():
        raise Red(f"{where} 抠出来的 `{raw}` 看不懂 —— 不猜,请改这个脚本")
    return int(s)


def swift_const(name: str) -> int:
    text = read(SWIFT)
    m = re.search(rf"static let {name}\s*=\s*([0-9_]+)", text)
    if not m:
        raise Red(f"在 {SWIFT} 里找不到 `{name}` —— 常量改名或换了写法,"
                  f"这个脚本要跟着改(别让它静默放行)")
    return to_int(m.group(1), f"{SWIFT} 的 {name}")


def sites(rel: str, pattern: str, count: int, what: str,
          scope: tuple[str, str, str] | None = None) -> list[int]:
    """把一个文件(或其中一节)里的全部复述抠出来,数目必须正好是 count。"""
    text = read(rel)
    if scope:
        text = section(text, rel, *scope)
        rel = f"{rel} 的「{scope[2]}」"
    found = re.findall(pattern, text)
    if len(found) != count:
        raise Red(
            f"{rel} 里「{what}」认到 {len(found)} 处,脚本认的是 {count} 处。\n"
            f"   ⚠️ **不要直接把 {count} 改成 {len(found)} 了事** —— 先确认:\n"
            f"      少了 ⇒ 有人删了一处复述,或改了写法(那这道就查不到它了);\n"
            f"      多了 ⇒ 有人新写了一处,先确认它说的是不是同一个数。")
    return [to_int(x, f"{rel} 的「{what}」") for x in found]


# 一个事实 = 代码里的一个常量 + 文档里的若干处复述。
FACTS = [
    {
        "what": "单场比对总输入上限",
        "const": "inputTokenBudget",
        "sites": [
            (PLAN, r"单场比对总输入\s*\*{0,2}≤\s*(\d+(?:\s*万)?)\s*token", 1, None),
            (BOARD, r"≤\s*(\d+(?:\s*万)?)\s*token/场", 1, M2_0A),
        ],
    },
    {
        "what": "每件事带几条脉络",
        "const": "timelineWindow",
        "sites": [
            (PLAN, r"最近\s*\*{0,2}(\d+)\s*条(?:脉络|进展)", 1, None),
        ],
    },
    {
        "what": "超上限时降级比几件",
        "const": "degradedCompareCount",
        "sites": [
            (PLAN, r"最相关的\s*\*{0,2}(\d+)\s*件", 1, None),
        ],
    },
]


def main() -> int:
    bad = []
    for fact in FACTS:
        what, const = fact["what"], fact["const"]
        try:
            code = swift_const(const)
            print(f"  {what}:代码 {const} = {code}")
            for rel, pat, count, scope in fact["sites"]:
                for got in sites(rel, pat, count, what, scope):
                    where = rel if scope is None else f"{rel} 的「{scope[2]}」"
                    mark = "✓" if got == code else "🔴"
                    print(f"      {mark} {where} 说 {got}")
                    if got != code:
                        bad.append(
                            f"「{what}」:代码里是 {code},而 {where} 写的是 {got}。\n"
                            f"   代码那个数才会真的生效,文档那句是给人读的 —— "
                            f"两者对不上时,读文档的人会照着一个不存在的口径做决定。")
        except Red as e:
            bad.append(str(e))

    if bad:
        print()
        sys.stdout.flush()
        for b in bad:
            print(f"🔴 {b}", file=sys.stderr)
        print("\n⚠️ 出口判据(`M2-0a ⑤`)也在上面这几处里 —— "
              "代码调大而它不动,那条出口线就成了永远达标的空话。", file=sys.stderr)
        return 1
    print("\n✅ 刀五三个数:代码与文档每一处复述都一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

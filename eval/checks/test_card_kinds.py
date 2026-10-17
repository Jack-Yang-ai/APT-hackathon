#!/usr/bin/env python3
"""卡型闭集与优先级的**跨语言对撞**(M3-0b)。

    python3 eval/checks/test_card_kinds.py

## 为什么要这道

两份:**PRD §4.6.3 那张优先级表**(规格出处)与 **`CardTrigger.Kind`**(代码里唯一副本)。
队列排序的「重要度」就是那张表的「序」——

| 漂了 | 表现 |
|---|---|
| 少一型 | 那一型**永远出不来**,而产出器不会报错(枚举里没有 = 没人构造它) |
| 序号错位 | 队列每天照样出 B 张,只是**排错了顺序** —— 进展确认卡被压在收尾卡后面,取前 B 就取不到它 |
| 名字改了一边 | 界面显示的卡型名与 PRD 对不上,而两侧各自都自洽 |

三种表现**全是沉默的**:编译过、测试绿、exit code 0。所以必须有一道会红的对撞(铁律 4)。

⚠️ **双向**,并且**不设白名单**:单向只查「代码有的 PRD 也有」时,
PRD 单边多一型会一声不响 —— 那正是 `M2-审13` 里场景表踩过的形状(声明比实现宽)。

## 照妖镜(2026-08-25 手跑,两次都红)

· 把 Swift 里 `case closing` 的 `priority` 从 9 改成 8 → 🔴「序号对不上」;
· 把 PRD 表里「缺席观察卡」那行删掉 → 🔴「PRD 有而代码没有 / 代码有而 PRD 没有」。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRD = ROOT / "eval" / "contracts" / "product-kinds.md"
SWIFT = ROOT / "ios" / "GrowthApp" / "Cards" / "CardTrigger.swift"

FAILS: list[str] = []


def read(p: Path) -> str:
    if not p.exists():
        raise SystemExit(f"🔴 {p} 不在 —— 这道对撞的一端没了")
    return p.read_text(encoding="utf-8")


def prd_table() -> dict[int, str]:
    """PRD §4.6.3 的表:{序: 卡型}。抠不到就红,不静默跳过。"""
    text = read(PRD)
    m = re.search(r"### 4\.6\.3 .*?\n(.*?)(?=\n### |\n## )", text, re.S)
    if not m:
        FAILS.append("PRD 里找不到 §4.6.3 —— 章节改名了,这个脚本要跟着改,别让它悄悄不查")
        return {}
    rows: dict[int, str] = {}
    for line in m.group(1).splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3 or not cells[0].isdigit():
            continue
        rows[int(cells[0])] = cells[2]
    if not rows:
        FAILS.append("§4.6.3 里一行表格都没抠到 —— 表格写法变了")
    return rows


def swift_kinds() -> dict[int, str]:
    """`CardTrigger.Kind`:{priority: rawValue}。"""
    text = read(SWIFT)
    body = re.search(r"enum Kind: String, CaseIterable \{(.*?)\n    \}", text, re.S)
    prio = re.search(r"var priority: Int \{(.*?)\n        \}", text, re.S)
    if not body or not prio:
        FAILS.append("CardTrigger.swift 里抠不到 `enum Kind` 或 `var priority` —— "
                     "改了写法就要改这里,别让这道对撞悄悄不查")
        return {}
    names = dict(re.findall(r'case (\w+) = "([^"]+)"', body.group(1)))
    prios = {c: int(p) for c, p in re.findall(r"case \.(\w+): return (\d+)", prio.group(1))}
    missing = set(names) - set(prios)
    if missing:
        FAILS.append(f"这几个 case 没有 priority:{sorted(missing)} —— "
                     f"Swift 的 switch 是穷尽的,少了会编译不过;能走到这里说明写法变了")
    out: dict[int, str] = {}
    for case, raw in names.items():
        if case in prios:
            if prios[case] in out:
                FAILS.append(f"序号 {prios[case]} 被两个 case 用了:{out[prios[case]]} / {raw}")
            out[prios[case]] = raw
    return out


def main() -> int:
    prd, swift = prd_table(), swift_kinds()
    if prd and swift:
        for seq in sorted(set(prd) | set(swift)):
            a, b = prd.get(seq), swift.get(seq)
            ok = a is not None and b is not None and a == b
            print(("✅" if ok else "🔴"), f"序 {seq}: PRD={a!r} swift={b!r}")
            if not ok:
                FAILS.append(f"序 {seq} 两侧对不上(PRD={a!r} / swift={b!r})—— "
                             f"少一型 = 那一型永远出不来;序号错位 = 队列排错而照样出数")

    if FAILS:
        print()
        for f in FAILS:
            print(f"🔴 {f}", file=sys.stderr)
        print("\n⚠️ 这三种漂法**都不会有运行时报错** —— 队列照常出 B 张,"
              "只是取到的不是该取的那几张。", file=sys.stderr)
        return 1
    print(f"\n✅ 卡型闭集与优先级两侧一致({len(prd)} 型)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

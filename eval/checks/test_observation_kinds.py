#!/usr/bin/env python3
"""「关于你的观察」类型闭集的**跨语言对撞**(M3-0e,PRD §4.4.7)。

    python3 eval/checks/test_observation_kinds.py

## 为什么要这道

两份:**PRD §4.4.7 那句「能产出哪些观察(清单之外不做)」**与 **`ObservationKind`**。
而这个闭集不是装饰 —— §4.4.7 有**两条呈现规则**直接挂在它上面:

| 规则 | 漂了会怎样 |
|---|---|
| 盲区类**不在 20:00 后呈现**(R-D) | **一条盲区观察在睡前弹出来** —— R-D 那条红线的全部意义就是不让这件事发生 |
| 顺序:先亮点与规律,后盲区 | 打开「我自己」第一眼看到的是自己的短处 |
| 少一型 | 那一型永远产不出来,而抽屉里照样有别的观察,看不出少了什么 |

三种表现**全是沉默的**。所以必须有一道会红的对撞(铁律 4)。

## ⚠️ 盲区判据也一起钉

PRD 的原话是「涉及**盲区、缺席、反复困境**的观察」。
`ObservationKind.isBlindSpot` 把它落成:**参与方式的差异(缺席)**、**重复的处境(反复困境)**。
那是一次**判断**,不是抄写 —— 所以这里连**那三个关键词还在不在 PRD 里**也一起查:
词改了而映射没跟着改,是这道对撞唯一挡不住的漂法,除非把词本身也钉住。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRD = ROOT / "eval" / "contracts" / "product-kinds.md"
SWIFT = ROOT / "ios" / "GrowthApp" / "Discovery" / "ObservationKind.swift"

#: PRD §4.4.7 时段那行里的三个词。映射(哪几型算盲区)就是从它们推出来的。
BLIND_SPOT_WORDS = ["盲区", "缺席", "反复困境"]

FAILS: list[str] = []


def read(p: Path) -> str:
    if not p.exists():
        raise SystemExit(f"🔴 {p} 不在 —— 这道对撞的一端没了")
    return p.read_text(encoding="utf-8")


def prd_kinds(text: str) -> list[str]:
    m = re.search(r"\*\*能产出哪些观察\*\*[^\n]*?:([^\n]+)", text)
    if not m:
        FAILS.append("PRD 里抠不到「能产出哪些观察」那句 —— 写法变了,"
                     "这个脚本要跟着改,别让它悄悄不查")
        return []
    # 「A · B · C · D · E。」
    body = m.group(1).split("。")[0]
    return [x.strip() for x in body.split("·") if x.strip()]


def swift_kinds() -> tuple[list[str], set[str]]:
    text = read(SWIFT)
    body = re.search(r"enum ObservationKind: String, CaseIterable \{(.*?)\n\}", text, re.S)
    band = re.search(r"var band: Band \{(.*?)\n    \}", text, re.S)
    if not body or not band:
        FAILS.append("ObservationKind.swift 里抠不到 `enum` 或 `var band` —— 写法变了")
        return [], set()
    top = re.split(r"\n    enum ", body.group(1))[0]
    names = dict(re.findall(r'case (\w+) = "([^"]+)"', top))
    blind: set[str] = set()
    for cases, value in re.findall(r"case ([^:]+): return \.(\w+)", band.group(1)):
        if value != "blindSpot":
            continue
        for c in re.findall(r"\.(\w+)", cases):
            blind.add(names.get(c, c))
    return list(names.values()), blind


def main() -> int:
    text = read(PRD)
    prd = prd_kinds(text)
    swift, blind = swift_kinds()

    if prd and swift:
        ok = prd == swift
        print(("✅" if ok else "🔴"), f"闭集(有序): PRD={prd} swift={swift}")
        if not ok:
            FAILS.append(f"观察类型闭集两侧对不上(PRD={prd} / swift={swift})—— "
                         f"少一型 = 那一型永远产不出来,而界面上看不出少了什么")

    # 盲区判据的依据词还在不在
    curfew = re.search(r"\|\s*\*\*时段\*\*\s*\|([^\n|]+)", text)
    line = curfew.group(1) if curfew else ""
    for w in BLIND_SPOT_WORDS:
        present = w in line
        print(("✅" if present else "🔴"), f"盲区判据依据词「{w}」还在 §4.4.7 时段那行")
        if not present:
            FAILS.append(f"PRD §4.4.7 时段那行里没有「{w}」了 —— "
                         f"`ObservationKind.isBlindSpot` 的映射正是从这三个词推出来的,"
                         f"词改了而映射没改,表现是**一条盲区观察在睡前弹出来**")
    print(f"   (swift 判为盲区的:{sorted(blind)})")
    if not blind:
        FAILS.append("swift 里一个盲区类都没有 —— 那 20:00 那条规则就永远不生效")

    if FAILS:
        print()
        for f in FAILS:
            print(f"🔴 {f}", file=sys.stderr)
        return 1
    print(f"\n✅ 观察类型闭集两侧一致({len(prd)} 型,其中盲区类 {len(blind)} 型)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

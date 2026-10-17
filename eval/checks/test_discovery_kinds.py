#!/usr/bin/env python3
"""发现类型闭集与依据形态的**跨语言对撞**(M3-0d)。

    python3 eval/checks/test_discovery_kinds.py

## 为什么要这道

两份:**PRD §4.5.4 那两张表**(规格出处)与 **`DiscoveryKind`**(代码里唯一副本)。
PRD 白纸黑字写着「**清单之外不做**」—— 而「清单」有两个副本时,那句话就没有落点了。

| 漂了 | 表现 |
|---|---|
| 代码少一型 | 那一型**永远产不出来**,而抽屉里照样有别的发现,看不出少了什么 |
| 代码多一型 | 越过 R-A / R-E 的边界产出观察,**而验收抽样按 PRD 的清单设计,根本不会去抽它** |
| 对象列错(事/人) | 频率闸算错档(每事每周 ≤2 vs 每人每周 ≤1),而两边各自都自洽 |
| 依据形态错 | 「没出现」类被当成有原话类 ⇒ **少了可复算统计口径这道要求**,而界面照样显示 |

四种表现**全是沉默的**。所以必须有一道会红的对撞(铁律 4)。

⚠️ **「我」那一行是显式排除,不是静默跳过**:PRD 表里第 7 行「我 | 被验证的判断 / 重复的判法」
写的是「统一收进 §4.4.7,遵守那里更严格的规则」—— 它**不是**一个发现类型。
把它写成显式白名单(而不是「解析不出来就跳过」),是因为**空着的白名单等于对撞不存在**
(`M2-审13` 的教训:单向对撞 = 声明比实现宽)。

## 照妖镜(2026-08-25 手跑,三次都红)

· 删掉 Swift 里 `case attitudeChange` → 🔴「PRD 有而代码没有」;
· 把 `stalledReason` 的 `subject` 从 `.matter` 改成 `.person` → 🔴「对象列对不上」;
· 把 `suspendedCommitment` 的 `evidenceForm` 改成 `.quotes` → 🔴「依据形态对不上」。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRD = ROOT / "eval" / "contracts" / "product-kinds.md"
SWIFT = ROOT / "ios" / "GrowthApp" / "Discovery" / "DiscoveryKind.swift"

#: PRD §4.5.4 表里**不是发现类型**的那一行。空着就等于这道对撞不存在,所以它必须非空。
NOT_A_DISCOVERY = {"我"}

FAILS: list[str] = []


def read(p: Path) -> str:
    if not p.exists():
        raise SystemExit(f"🔴 {p} 不在 —— 这道对撞的一端没了")
    return p.read_text(encoding="utf-8")


def prd_section() -> str:
    m = re.search(r"### 4\.5\.4 .*?\n(.*?)(?=\n### )", read(PRD), re.S)
    if not m:
        FAILS.append("PRD 里找不到 §4.5.4 —— 章节改名了,这个脚本要跟着改,别让它悄悄不查")
        return ""
    return m.group(1)


def prd_kinds(sec: str) -> dict[str, str]:
    """{类型名: 对象}。"""
    out: dict[str, str] = {}
    for line in sec.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 3 or cells[0] in ("对象", "---"):
            continue
        subject, kind = cells[0], cells[1]
        if subject not in ("事", "人", "我"):
            continue
        if subject in NOT_A_DISCOVERY:
            continue
        out[kind] = subject
    if not out:
        FAILS.append("§4.5.4 的类型表一行都没抠到 —— 表格写法变了")
    if not NOT_A_DISCOVERY:
        FAILS.append("NOT_A_DISCOVERY 空了 —— 空白名单 = 这道对撞不存在")
    return out


def prd_absence(sec: str) -> set[str]:
    """「没出现」类那三型(证据那行的括号)。"""
    m = re.search(r"「没出现」类\*\*[((]([^))]+)[))]", sec)
    if not m:
        FAILS.append("§4.5.4 证据那行里抠不到「没出现」类的括号 —— 写法变了,别让它悄悄不查")
        return set()
    return {x.strip() for x in re.split(r"[、,,]", m.group(1)) if x.strip()}


def swift_kinds() -> tuple[dict[str, str], set[str]]:
    text = read(SWIFT)
    body = re.search(r"enum DiscoveryKind: String, CaseIterable \{(.*?)\n\}", text, re.S)
    if not body:
        FAILS.append("DiscoveryKind.swift 里抠不到 `enum DiscoveryKind` —— 写法变了")
        return {}, set()
    # ⚠️ 只取**嵌套 enum 之前**那段:`Subject` 是嵌在 `DiscoveryKind` 里的,
    # 它自己的 `case matter = "事"` 会被同一个正则捞进来,变成一个不存在的「类型」。
    # (第一次跑就栽在这:多出一个叫「事」的类型,而它两侧永远对不上。)
    top = re.split(r"\n    enum ", body.group(1))[0]
    names = dict(re.findall(r'case (\w+) = "([^"]+)"', top))

    subj_block = re.search(r"var subject: Subject \{(.*?)\n    \}", text, re.S)
    form_block = re.search(r"var evidenceForm: EvidenceForm \{(.*?)\n    \}", text, re.S)
    if not subj_block or not form_block:
        FAILS.append("抠不到 `var subject` 或 `var evidenceForm` —— 写法变了")
        return {}, set()

    subjects: dict[str, str] = {}
    for cases, value in re.findall(r"case ([^:]+): return \.(\w+)", subj_block.group(1)):
        for c in re.findall(r"\.(\w+)", cases):
            subjects[c] = {"matter": "事", "person": "人"}.get(value, value)

    absence: set[str] = set()
    for cases, value in re.findall(r"case ([^:]+): return \.(\w+)", form_block.group(1)):
        if value != "absence":
            continue
        for c in re.findall(r"\.(\w+)", cases):
            absence.add(names.get(c, c))

    covered = set(names) - set(subjects)
    if covered:
        FAILS.append(f"这几个 case 没有 subject:{sorted(covered)} —— Swift 的 switch 是穷尽的,"
                     f"能走到这里说明写法变了")
    return {raw: subjects.get(case, "?") for case, raw in names.items()}, absence


def main() -> int:
    sec = prd_section()
    prd, prd_abs = (prd_kinds(sec), prd_absence(sec)) if sec else ({}, set())
    swift, swift_abs = swift_kinds()

    if prd and swift:
        for kind in sorted(set(prd) | set(swift)):
            a, b = prd.get(kind), swift.get(kind)
            ok = a is not None and b is not None and a == b
            print(("✅" if ok else "🔴"), f"{kind}: PRD 对象={a!r} swift 对象={b!r}")
            if not ok:
                FAILS.append(f"「{kind}」两侧对不上(PRD={a!r} / swift={b!r})—— "
                             f"少一型 = 那一型永远产不出来;多一型 = 越过 R-A/R-E 而验收抽不到它;"
                             f"对象列错 = 频率闸算错档")

    if prd_abs or swift_abs:
        ok = prd_abs == swift_abs
        print(("✅" if ok else "🔴"), f"「没出现」类: PRD={sorted(prd_abs)} swift={sorted(swift_abs)}")
        if not ok:
            FAILS.append(f"「没出现」类两侧对不上(PRD={sorted(prd_abs)} / swift={sorted(swift_abs)})"
                         f"—— 被当成有原话类的那一型会少掉「可复算统计口径」这道要求,而界面照样显示")

    if FAILS:
        print()
        for f in FAILS:
            print(f"🔴 {f}", file=sys.stderr)
        print("\n⚠️ 这四种漂法**都不会有运行时报错** —— 抽屉里照样有发现,"
              "只是少了某一型、或多了一型没人验收。", file=sys.stderr)
        return 1
    print(f"\n✅ 发现类型闭集与依据形态两侧一致({len(prd)} 型,"
          f"其中「没出现」类 {len(prd_abs)} 型;「我」按 §4.4.7 显式排除)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

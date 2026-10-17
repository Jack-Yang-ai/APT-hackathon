#!/usr/bin/env python3
"""已有处理模块的判卷。验收线运行时读取 eval/contracts/acceptance.md，不在脚本复制阈值。输入为人工判卷 JSONL，发现合规判卷需要两位独立评审。"""
from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TASKS = ROOT / "eval/contracts/acceptance.md"


def section_of(heading: str) -> str:
    """取板上某一节的正文。找不到就**退出** —— 达标线的出处没了就没法判。"""
    text = TASKS.read_text(encoding="utf-8")
    m = re.search(rf"^### \[.\] {re.escape(heading)}\b.*?(?=\n### )", text, re.S | re.M)
    if not m:
        sys.exit(f"🔴 板上找不到 {heading} 定稿 —— 达标线的唯一出处没了,这个脚本没法判")
    return m.group(0)


def thresholds(heading: str = "M2-0a", expect: int = 6) -> dict[str, str]:
    """从 `0a` 定稿的那张表里读达标线。**唯一出处在板上。**

    ⚠️ 读不到就**退出**,不给默认值 —— 默认值会让这个脚本在板改过之后
    继续拿旧线打分,而输出看起来一切正常。这正是「静默地用了过期结论」。

    ⚠️ `heading` / `expect` 2026-08-25 加,给 `score_m3_exams.py` 复用 ——
    **默认值一个字没动**,老调用点行为完全不变。
    """
    m = re.match(r"(?s).*", section_of(heading))
    out: dict[str, str] = {}
    # ⚠️ 粗体后面允许还有字(如「**≤2 万 token/场**(§4.5.1 硬上限)」)——
    # 第一版要求粗体占满整格,于是**静默丢掉了 ⑤ 那一行**。丢行的解析器最坏:
    # 它不报错,只是少给你一条,而少的那条正好是你要的时候才发现。
    for row in re.finditer(r"^\|\s*[①②③④⑤⑥]\s*\|\s*([^|]+?)\s*\|.*?\|\s*\*\*([^*]+)\*\*[^|]*\|",
                           m.group(0), re.M):
        out[row.group(1).strip()] = row.group(2).strip()
    # 🔴 定稿那张表是**六条**。抠不全说明正则跟表结构漂了 ——
    # 而漂了的表现是「少给你一条」,不是报错。⇒ 当场喊,别让它继续。
    if len(out) != expect:
        sys.exit(f"🔴 {heading} 那张表抠出 {len(out)} 条,定稿是 {expect} 条 —— "
                 f"表结构变了或正则漂了,这个脚本在拿一份残缺的达标线判分。\n"
                 f"   抠到的:{list(out)}")
    return out


def find_line(th: dict[str, str], *keys: str) -> str:
    for k, v in th.items():
        if all(x in k for x in keys):
            return v
    sys.exit(f"🔴 定稿里找不到含 {keys} 的那一行 —— 判据锚点没了")


# ── 三张卷各自的判分 ────────────────────────────────────────────

class Result:
    def __init__(self, name: str, line: str):
        self.name, self.line = name, line
        self.notes: list[str] = []
        self.passed: bool | None = None
        self.value = ""

    def __str__(self) -> str:
        mark = "✅" if self.passed else ("🔴" if self.passed is False else "⚠️")
        s = f"{mark} {self.name}:{self.value}(达标线 {self.line})"
        return s + "".join(f"\n     · {n}" for n in self.notes)


def score_nomination(rows: list[dict], line: str) -> Result:
    """卷一 · 提名。**落在区间内才算过,不是越高越好。**

    🔴 >上界说明提名**过于保守**(该提的没提),而**漏提在界面上什么都不会发生** ——
    这正是它需要一个下界的理由。把它当成「越高越好」的指标会一路优化到
    「几乎不提名」,而那个系统的判准率是 100%。
    """
    r = Result("卷一 提名判准率", line)
    if not rows:
        r.notes.append("一条都没有 —— 判不了")
        return r
    lo, hi = (float(x) / 100 for x in re.findall(r"(\d+)%", line))
    hit = sum(1 for x in rows if x.get("verdict") == "该提名")
    rate = hit / len(rows)
    r.value = f"{rate:.0%}({hit}/{len(rows)})"
    # 样本量:定稿写的是 50–100 条。不足**不照算** —— 20 条算出来的
    # 判准率不能当结论,而一个数一旦印出来就会被当结论引用。
    if len(rows) < 50:
        r.notes.append(f"⚠️ 只有 {len(rows)} 条,规格要 50–100 条 —— **样本不足,这个数不能当结论**")
        return r
    r.passed = lo <= rate <= hi
    if rate > hi:
        r.notes.append("高于上界 = 提名**过于保守**,该提的没提。漏提在界面上什么都不会发生")
    elif rate < lo:
        r.notes.append("低于下界 = 提名太松,用户会被不相干的候选淹掉")
    return r


def score_attribution(rows: list[dict], line: str) -> Result:
    """卷二 · 进展归属,**只判静默档**。

    静默档是唯一不经人眼的路径 —— 不达标 = 系统在背着人往脉络里塞错东西。
    """
    r = Result("卷二 静默档判准率", line)
    if not rows:
        r.notes.append("一条都没有 —— 判不了(静默档零产出也算这一档,要说清是哪种)")
        return r
    floor = float(re.search(r"(\d+)%", line).group(1)) / 100
    hit = sum(1 for x in rows if x.get("verdict") == "属于")
    rate = hit / len(rows)
    r.value = f"{rate:.0%}({hit}/{len(rows)})"
    r.passed = rate >= floor
    return r


def score_findings(rows: list[dict], line: str) -> Result:
    """卷三 · 发现合规率(= 停止线 3)。两个指标:**一致率** + **严重违规条数**。

    🔴 **双评审不是为了更准,是为了让「尺子本身不可信」暴露出来**:
    一致率低说明规范写得含糊 —— 那时要**先修规范再判系统**,
    而不是拿一把晃的尺子去量。
    """
    r = Result("卷三 发现合规", line)
    by_id: dict[str, dict[str, dict]] = defaultdict(dict)
    for x in rows:
        by_id[x.get("id", "")][x.get("reviewer", "?")] = x
    both = {k: v for k, v in by_id.items() if len(v) >= 2}
    if not both:
        r.notes.append("没有任何一条被两个人判过 —— 双评审的全部意义就在这儿,判不了")
        return r
    if len(both) < len(by_id):
        r.notes.append(f"⚠️ {len(by_id) - len(both)} 条只有一个人判,已排除在一致率外")

    agree = sum(1 for v in both.values()
                if len({x.get("verdict") for x in v.values()}) == 1)
    rate = agree / len(both)
    severe = sum(1 for v in by_id.values() for x in v.values()
                 if x.get("severity") == "严重")
    r.value = f"一致 {rate:.0%}({agree}/{len(both)}) · 严重违规 {severe} 例"

    floor = float(re.search(r"(\d+)%", line).group(1)) / 100
    r.passed = rate >= floor and severe == 0
    if rate < floor:
        r.notes.append("一致率不达标 ⇒ **先修表述规范,再判系统** —— "
                       "这时候量出来的合规率量的是尺子,不是系统")
    if severe:
        r.notes.append(f"有 {severe} 例严重违规 ⇒ 停止线 3 不通过(达标线要求 0 例)")
    if len(by_id) < 50:
        r.notes.append(f"⚠️ 只有 {len(by_id)} 条,规格要抽 50 条")
    return r


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    path = Path(argv[1])
    if not path.exists():
        print(f"🔴 判卷结果不在:{path}", file=sys.stderr)
        return 2
    rows = [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]
    by_exam: dict[str, list[dict]] = defaultdict(list)
    for x in rows:
        by_exam[x.get("exam", "?")].append(x)

    th = thresholds()
    results = [
        score_nomination(by_exam["提名"], find_line(th, "提名")),
        score_attribution(by_exam["归属"], find_line(th, "静默档")),
        score_findings(by_exam["发现"], find_line(th, "合规率")),
    ]
    print(f"判卷结果:{path}（{len(rows)} 行）\n")
    for r in results:
        print(r)
    unknown = [r.name for r in results if r.passed is None]
    failed = [r.name for r in results if r.passed is False]
    print()
    if unknown:
        print(f"⚠️ 判不了:{'、'.join(unknown)} —— **不算通过,也不算不通过**")
    if failed:
        print(f"🔴 不达标:{'、'.join(failed)}")
    if not unknown and not failed:
        print("✅ 三张卷全部达标")
    # 判不了也退非 0:**「没判」不许被读成「过了」**。
    return 1 if (failed or unknown) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

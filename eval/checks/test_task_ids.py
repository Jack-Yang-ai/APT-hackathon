#!/usr/bin/env python3
"""当前任务号唯一性检查，支持汉字号，可传入变异副本。历史合法重复已随旧任务板移除，不保留白名单。"""
from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

# 可以指一份别的板子(自检用它把改坏的板写进临时文件再跑)。
_ROOT = Path(__file__).resolve().parents[2]
TASKS = Path(sys.argv[1]) if len(sys.argv) > 1 else _ROOT / "TASKS.md"

#: 登记在案的合法同号。**加一条要写清为什么两条都留着。**
KNOWN_PAIRS: set[str] = set()

# 🔴 **2026-08-20:字符类原来是 `[0-9A-Za-z]+`,于是 `M2-走6` / `M2-审3` 这类
# 带汉字的号**一条都没被数进来** —— 全仓当时有 **15** 个(`M1-审1`…`审6`、`M2-审1`…`审3`、`M2-走1`…`走6`)。
# 表现:新开一条汉字号,`✅ 任务号唯一(147 条)` 里那个数**纹丝不动**,
# 而它正是这道对撞的全部作用面。两个会话同时开 `M2-走6` 不会有任何东西红,
# 而这道脚本存在的理由就是事故四(两个会话各开四个同号)。
# ⚠️ 撞见它靠的是「加了一条,数没变」这个偶然 —— 不是任何断言抓到的。
HEAD = re.compile(r"^### \[.\] (M\d+-[0-9A-Za-z\u4e00-\u9fff]+)\b")


def main() -> int:
    seen: dict[str, list[int]] = defaultdict(list)
    _text = TASKS.read_text(encoding="utf-8")
    for n, line in enumerate(_text.splitlines(), 1):
        m = HEAD.match(line)
        if m:
            seen[m.group(1)].append(n)

    dupes = {k: v for k, v in seen.items() if len(v) > 1 and k not in KNOWN_PAIRS}
    if dupes:
        print("🔴 任务号撞了 —— `git merge` 不会报这个,只有这里会:")
        for task, lines in sorted(dupes.items()):
            print(f"  - {task} 出现在第 {', '.join(map(str, lines))} 行")
        print("\n处置:后开的那条改号(先落 main 的为准);"
              "若是同一条的新旧两份,删掉过期那份。"
              "\n⚠️ 改号之后,引用过它的文档要一起改(仓规 6:前提和结论一起活)。")
        return 1

    stale = KNOWN_PAIRS - {k for k, v in seen.items() if len(v) > 1}
    if stale:
        # 白名单里挂着一条其实已经不重复的号 ⇒ 白名单在腐烂,
        # 而腐烂的白名单会在将来放过一次真撞车。
        print(f"🔴 白名单里这些号已经不重复了,删掉它们:{sorted(stale)}")
        return 1

    print(f"✅ 任务号唯一({len(seen)} 条,登记在案的同号 {len(KNOWN_PAIRS)} 对)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

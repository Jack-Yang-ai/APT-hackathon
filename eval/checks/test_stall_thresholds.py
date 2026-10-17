#!/usr/bin/env python3
"""三道「等多久算卡住」的时限,次序必须对(M1-30 ②)。

    python3 eval/checks/test_stall_thresholds.py

## 为什么要这道

三个数在**三种语言**里:

| 谁 | 常量 | 干什么 |
|---|---|---|
| `mac/asr_fallback.py` | `STUCK_AFTER_SEC` | 换 SSE 兜底 |
| `worker/src/collector.js` | `PENDING_TTL_MS` | 云端判失败 |
| `ios/…/ProcessingOrchestrator.swift` | `asrStallMinutes` | 手机放弃 |

**顺序必须是这个顺序**:手机放弃得比兜底晚,否则**兜底还没来得及救,
手机已经判了失败** —— 而那个现场与「上游真的挂了」**一模一样**,
排查时会朝完全错的方向找。

🔴 而交叉了**没有任何东西会报错**:三个数各自都是合法的,只有它们的**关系**是错的。
这正是铁律 4 的形状 —— 一件事(「多久算卡住」)散在三处,对不上时没人红。

⚠️ **比源码不比行为。** 拿一次成功的转写证明「次序没问题」挡不住下一次改动:
改小了手机那个数,当天可能一次都没触发,而下周某一场慢了就悄悄判错。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def number(path: Path, pattern: str, scale: float, what: str) -> float:
    """抠一个算术表达式并求值,换算成**分钟**。"""
    if not path.exists():
        sys.exit(f"🔴 {path.relative_to(ROOT)} 不在 —— 这道对撞的一端没了")
    m = re.search(pattern, path.read_text(encoding="utf-8"), re.M)
    if not m:
        sys.exit(f"🔴 在 {path.relative_to(ROOT)} 里找不到 {what} —— "
                 f"常量改名或换了写法,这个脚本要跟着改(别让它静默放行)")
    expr = m.group(1).strip()
    if not re.fullmatch(r"[\d\s*+]+", expr):
        sys.exit(f"🔴 {what} 的取值 `{expr}` 不是简单算术 —— 不猜,请改这个脚本")
    return eval(expr) * scale                                          # noqa: S307


def main() -> int:
    mac = number(ROOT / "mac/asr_fallback.py",
                 r"^STUCK_AFTER_SEC\s*=\s*([\d\s*+]+)", 1 / 60, "STUCK_AFTER_SEC")
    worker = number(ROOT / "worker/src/collector.js",
                    r"PENDING_TTL_MS\s*=\s*([\d\s*+]+)", 1 / 60000, "PENDING_TTL_MS")
    phone = number(ROOT / "ios/GrowthApp/Upload/ProcessingOrchestrator.swift",
                   r"asrStallMinutes\s*=\s*([\d\s*+]+)", 1, "asrStallMinutes")

    print(f"  Mac 换兜底   {mac:>8.0f} 分钟")
    print(f"  云端判失败   {worker:>8.0f} 分钟")
    print(f"  手机放弃     {phone:>8.0f} 分钟")

    bad = []
    if not mac < worker:
        bad.append(f"Mac 换兜底({mac:.0f} 分钟)不早于云端判失败({worker:.0f} 分钟)"
                   f" —— 云端会先把这一块判死,兜底再也没有机会救它")
    if not worker < phone:
        bad.append(f"云端判失败({worker:.0f} 分钟)不早于手机放弃({phone:.0f} 分钟)"
                   f" —— 手机会先判失败,而云端的兜底结论永远到不了用户眼前")
    for b in bad:
        print(f"🔴 {b}", file=sys.stderr)
    if bad:
        print("\n⚠️ 三个数各自都合法,错的是它们的**关系** —— "
              "而关系错了的现场与「上游真的挂了」一模一样。", file=sys.stderr)
        return 1
    print("\n✅ 次序对:Mac 换兜底 < 云端判失败 < 手机放弃")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""说话人代表片段的**保留策略对撞**(M3-0c ④,PRD §4.4.10)。

    python3 eval/checks/test_clip_prefix.py

## 为什么要这道

片段这件事有**两条互为反面**的要求,而两条都不满足时**什么都不会报错**:

| 要求 | 漏了会怎样 |
|---|---|
| **① 保留期扫不到它** —— 片段前缀不许与任何按时间清理的前缀相交 | 片段跟着 7 天音频保留期一起没 ⇒ **第 8 天试听静默失效**:认人页还在、播放按钮还在,按了没声音 |
| **② 移出记忆必须删它** —— `purgeSession` / `remaining` 必须覆盖片段前缀 | 云上留着一份**用户以为已经删掉的录音**。界面上那句承诺是「删掉,撤不回来」 |

🔴 **只钉一条比两条都不钉更危险**:只钉①,片段就变成永远删不掉的隐私尾巴;
只钉②,片段活不过第 8 天。所以这道对撞**双向**。

⚠️ 「保留期」与「移出记忆」不是一回事 —— 前者是时间到了自动清,
后者是**用户主动的隐私动作**。条目原文只写了「清理器的删除范围与片段前缀不许相交」,
照字面做会把片段一并挡在「移出记忆」之外。**这里按两者的语义分开钉。**

## 手机本地那一侧为什么不在这里查

`AudioRetention.sweep` 删的是 `ProcessingPump.blocks(...)` 列出来的**块文件** ——
片段不是块,不进那个账本,所以本地保留期**结构上**就够不着它。
那是结构保证,不是纪律,不需要对撞。

## 照妖镜(2026-08-25 手跑,三次都红)

· 把 `clipPrefix` 改成 `inbox/audio/clips/` → 🔴 与保留期扫描相交;
· 把 `purge.js` 里那行 `clips/${session}/` 删掉 → 🔴 移出记忆不删片段;
· 把 `remaining` 里的 `clips/${session}/` 删掉 → 🔴 删完不回读片段。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAYOUT = ROOT / "ios" / "GrowthApp" / "Upload" / "R2Layout.swift"
PURGE = ROOT / "worker" / "src" / "purge.js"
WORKER_SRC = ROOT / "worker" / "src"

FAILS: list[str] = []


def read(p: Path) -> str:
    if not p.exists():
        raise SystemExit(f"🔴 {p} 不在 —— 这道对撞的一端没了")
    return p.read_text(encoding="utf-8")


def clip_prefix() -> str | None:
    m = re.search(r'static let clipPrefix = "([^"]+)"', read(LAYOUT))
    if not m:
        FAILS.append("R2Layout.swift 里抠不到 `clipPrefix` —— 改名了就要改这里,"
                     "别让这道对撞悄悄不查")
        return None
    return m.group(1)


def js_consts() -> dict[str, str]:
    out: dict[str, str] = {}
    for f in WORKER_SRC.glob("*.js"):
        for name, val in re.findall(r"const (\w+)\s*=\s*['\"]([^'\"]+)['\"]", f.read_text(encoding="utf-8")):
            out[name] = val
    return out


def retention_prefixes() -> list[str]:
    """**按时间**清理的前缀:cron 的 `sweepStale` 与 `sweepResults`。"""
    consts = js_consts()
    found: list[str] = []
    for f in WORKER_SRC.glob("*.js"):
        text = f.read_text(encoding="utf-8")
        for raw in re.findall(r"sweepStale\(\{[^}]*?prefix:\s*([^,}]+)", text, re.S):
            raw = raw.strip()
            if raw.startswith(("'", '"', "`")):
                found.append(raw.strip("'\"`"))
            elif raw in consts:
                found.append(consts[raw])
            else:
                FAILS.append(f"`sweepStale` 的 prefix `{raw}` 解不出来 —— "
                             f"解不出来就等于没查这一条,不许静默跳过")
        # sweepResults 扫的是 RESULT_PREFIX(collector.js 里的常量)
        if "sweepResults({" in text and "RESULT_PREFIX" in consts:
            found.append(consts["RESULT_PREFIX"])
    if not found:
        FAILS.append("一条按时间清理的前缀都没抠到 —— 写法变了,这道对撞在空转")
    return sorted(set(found))


def purge_targets() -> tuple[list[str], list[str]]:
    """`purgeSession` 删的前缀,与 `remaining` 回读的前缀。"""
    text = read(PURGE)
    body = re.search(r"export async function purgeSession\(.*?\n\}", text, re.S)
    rem = re.search(r"export async function remaining\(.*?\n\}", text, re.S)
    if not body or not rem:
        FAILS.append("purge.js 里抠不到 `purgeSession` 或 `remaining` —— 写法变了")
        return [], []
    deletes = re.findall(r"deletePrefix\(bucket,\s*`([^`]+)`", body.group(0))
    reads = re.findall(r"`([^`]+)`", rem.group(0))
    return deletes, reads


def main() -> int:
    clips = clip_prefix()
    sweeps = retention_prefixes()
    deletes, reads = purge_targets()

    if clips:
        # ① 保留期扫不到它:两个前缀谁都不许是对方的前缀
        for p in sweeps:
            crossed = clips.startswith(p) or p.startswith(clips)
            print(("🔴" if crossed else "✅"), f"保留期扫描 {p!r} vs 片段 {clips!r}")
            if crossed:
                FAILS.append(f"片段前缀 {clips!r} 与按时间清理的前缀 {p!r} 相交 —— "
                             f"片段会跟着保留期一起没,而表现是第 8 天试听静默失效:"
                             f"认人页还在、播放按钮还在,按了没声音")

        # ② 移出记忆必须删它
        for what, keys in (("purgeSession 删", deletes), ("remaining 回读", reads)):
            hit = [k for k in keys if k.startswith(clips)]
            print(("✅" if hit else "🔴"), f"{what}片段前缀: {hit or '没有'}")
            if not hit:
                FAILS.append(f"{what}的范围里没有片段前缀 {clips!r} —— "
                             f"用户「移出记忆」之后云上还留着一份他以为已经删掉的录音;"
                             f"界面上那句承诺是「删掉,撤不回来」")

    if FAILS:
        print()
        for f in FAILS:
            print(f"🔴 {f}", file=sys.stderr)
        print("\n⚠️ 这两条**互为反面**,而两边漏了都不会有运行时报错 —— "
              "一边是第 8 天没声音,一边是删不掉的隐私尾巴。", file=sys.stderr)
        return 1
    print(f"\n✅ 片段前缀 {clips!r}:保留期扫不到({len(sweeps)} 条都不相交)、移出记忆删得掉")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

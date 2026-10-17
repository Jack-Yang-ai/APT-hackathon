#!/usr/bin/env python3
"""录音目录的**命名只有一个出处**(W1 手表录音,2026-10-12)。

    python3 eval/checks/test_recording_paths.py

## 为什么要这道

一天一个目录,目录名 `yyyy-MM-dd`。W1 之前全仓有**四份**各写各的格式化
(录音、导入、保留期、各一份;手表要来第五份)。四份都没钉公历:
系统日历设成佛历的设备会写出 `2569-10-12`,目录名错年,保留期按字符串比
`day < cutoff` 也跟着错 —— 而**没有任何东西会报错**。

手表加进来之后这还是**跨设备契约**:手表算的 `day` 决定手机把块誊写进哪个目录。
所以收成 `BlockLedger.dayKey` 一份,这道闸挡住第二份再长出来。

## 照妖镜(本文件自带)

`self_test()` 喂一份「别处也写了 `yyyy-MM-dd`」的构造源码,必须红;
喂一份只有 `BlockLedger.swift` 的,必须绿。两边都验过才查真仓。
"""
from __future__ import annotations

import sys
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN_DIRS = [ROOT / "ios" / "GrowthApp", ROOT / "ios" / "GrowthWatch"]
OWNER = "BlockLedger.swift"
NEEDLE = '"yyyy-MM-dd"'


def offenders(sources: dict[str, str]) -> list[str]:
    """`{相对路径: 源码}` → 唯一出处之外出现日期格式的文件。"""
    return sorted(p for p, text in sources.items()
                  if NEEDLE in text and Path(p).name != OWNER)


def path_offenders(sources: dict[str, str]) -> list[str]:
    """按日目录的拼接只能在RecordingPaths,包含URL和相对字符串形态。"""
    patterns = [r'appendingPathComponent\(\s*(?:day|BlockLedger\.dayKey\([^)]*\))\s*\)',
                r'recordings/\\\((?:day|BlockLedger\.dayKey)']
    bad = []
    for path, source in sources.items():
        if Path(path).name == "RecordingPaths.swift":
            continue
        code = "\n".join(line.split("//", 1)[0] for line in source.splitlines())
        if any(re.search(pattern, code) for pattern in patterns):
            bad.append(path)
    return sorted(bad)

def owner_present(sources: dict[str, str]) -> bool:
    return any(Path(p).name == OWNER and NEEDLE in t for p, t in sources.items())


def self_test() -> None:
    good = {"Recording/BlockLedger.swift": f'f.dateFormat = {NEEDLE}'}
    bad = dict(good, **{"Presentation/X.swift": f'f.dateFormat = {NEEDLE}'})
    assert offenders(good) == [] and owner_present(good), "照妖镜:干净的样本被判红了"
    assert offenders(bad) == ["Presentation/X.swift"], "照妖镜:第二份出处没被抓到"
    assert path_offenders({"RecordingPaths.swift": "root.appendingPathComponent(day)"}) == []
    assert path_offenders({"Pump.swift": "root.appendingPathComponent(day)"}) == ["Pump.swift"]
    assert path_offenders({"Watch.swift": 'return "recordings/\\(day)/x"'}) == ["Watch.swift"]
    assert not owner_present({"A.swift": ""}), "照妖镜:唯一出处没了却没报"


def main() -> int:
    self_test()
    sources: dict[str, str] = {}
    for d in SCAN_DIRS:
        for f in d.rglob("*.swift"):
            sources[str(f.relative_to(ROOT))] = f.read_text(encoding="utf-8")
    fails: list[str] = []
    if not owner_present(sources):
        fails.append(f"{OWNER} 里找不到 {NEEDLE} —— 唯一出处挪走了就要改这道闸,别让它悄悄不查")
    for p in offenders(sources):
        fails.append(f"{p} 自己格式化了日期目录名 —— 改调 `BlockLedger.dayKey`")
    for p in path_offenders(sources):
        fails.append(f"{p} 自己拼了按天录音路径 —— 改调 RecordingPaths.audioDir")
    if fails:
        print("🔴 录音目录命名不止一个出处:")
        for f in fails:
            print("  ·", f)
        return 1
    print("✅ 录音目录命名只有一个出处(BlockLedger.dayKey + RecordingPaths.audioDir),照妖镜红绿两侧都验过")
    return 0


if __name__ == "__main__":
    sys.exit(main())

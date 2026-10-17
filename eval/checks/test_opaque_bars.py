#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""





























from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "ios"
SHELL = IOS / "GrowthApp" / "Presentation" / "AppShell.swift"
DS_FILE = IOS / "DesignSystem.swift"

HIDE_BARS = (".toolbar(.hidden", ".toolbarBackground(.hidden",
             ".toolbarBackgroundVisibility(.hidden", ".scrollEdgeEffectHidden(")
RED = ("Color.red", ".red)", "systemRed", "0xFF3B30", "0xA33C36")

failed: list[str] = []


def ui_sources():
    for p in sorted(IOS.rglob("*.swift")):
        # ⚠️ `DerivedData/` 里有个**目录**就叫 `GRDB.swift` —— rglob 会把它当文件交出来。
        if not p.is_file() or "_legacy" in p.parts or "DerivedData" in p.parts:
            continue
        if p.name.endswith("Tests.swift"):
            continue
        yield p


def code_lines(text: str):
    """去掉注释行:注释里写「不许用 .red)」不该把自己判红。"""
    for i, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        yield i, line.split("//")[0]


def check_bars_not_hidden() -> None:
    n = 0
    for p in ui_sources():
        n += 1
        for i, line in code_lines(p.read_text(encoding="utf-8")):
            for bad in HIDE_BARS:
                if bad in line:
                    failed.append(f"{p.relative_to(ROOT)}:{i}:{bad} 关掉了系统栏的滚动边缘效果 —— "
                                  f"正文会从栏底下穿过去,而这件事不会有任何东西报错")
    if n == 0:
        failed.append("一个界面源码都没扫到 —— 这道对撞多半已经失效(路径变了?)")
    else:
        print(f"✅ 扫了 {n} 个界面源码,没有关掉系统栏效果的")


def check_shell_uses_system_bars() -> None:
    s = SHELL.read_text(encoding="utf-8")
    missing = [k for k in ("TabView(",) if k not in s]
    banned = [k for k in ("bottomNav", "askButton") if k in s]
    if missing:
        failed.append(f"{SHELL.relative_to(ROOT)}:找不到 {missing} —— 外壳不是系统栏了,"
                      f"安全区与边缘效果要重新手算(浮球时代的老坑)")
    if banned:
        failed.append(f"{SHELL.relative_to(ROOT)}:又出现了自绘的 {banned}")
    if not missing and not banned:
        print("✅ 外壳用系统 TabView,没有自绘底栏")


def check_no_red() -> None:
    for p in ui_sources():
        for i, line in code_lines(p.read_text(encoding="utf-8")):
            for bad in RED:
                if bad in line:
                    failed.append(f"{p.relative_to(ROOT)}:{i}:界面层写了红色 {bad!r} —— "
                                  f"用户 2026-10-12 不要红色警示")
    m = re.search(r"^\s*static let danger\s*=\s*(.+)$", DS_FILE.read_text(encoding="utf-8"), re.M)
    if not m:
        failed.append(f"{DS_FILE.relative_to(ROOT)}:找不到 `static let danger` —— 判据锚点没了")
    elif "Color(" in m.group(1) or "0x" in m.group(1):
        failed.append(f"{DS_FILE.relative_to(ROOT)}:danger 又给了一个具体颜色 {m.group(1).strip()!r} —— "
                      f"它必须是别名,出错靠文字说清楚")
    else:
        print("✅ 界面层没有红色,danger 是别名")


def main() -> int:
    check_bars_not_hidden()
    check_shell_uses_system_bars()
    check_no_red()
    for f in failed:
        print(f"🔴 {f}", file=sys.stderr)
    print(f"\n{len(failed)} failed" if failed else "\nall passed (3)")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

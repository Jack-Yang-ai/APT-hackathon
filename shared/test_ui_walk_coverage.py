#!/usr/bin/env python3
"""走查台的页面清单 vs 源码里真实的跳转口:**加了一个而没登记的话,这里要红。**

跑:python3 -m shared.test_ui_walk_coverage

## 为什么需要这一条

`ios/GrowthAppUITests/ScreenWalkTests.swift` 里那张清单,和 `Presentation/` 里
真实的 `NavigationLink` / `.sheet` / `.fullScreenCover`,是**两份**。
新加一个跳转口而不动清单,走查台照样全绿 —— 它只是少走一页,
而少走一页的样子和「走完了、都是好的」**一模一样**。

这正是 CLAUDE.md 第四条铁律的形状:两份东西横向不一致,而对不上时不会报错。
判据一句话:「改了这边而忘了那边,会不会有东西红?」—— 没有这个文件就不会。

## 为什么比数量,不比「哪一行」

行号会漂,比行号的对撞每次改代码都要维护一遍,那种对撞很快会被人注掉。
按**文件 × 跳转口数量**比:粒度够细(红了当场知道是哪个文件),
又不会因为上面插了一行注释就红。

## 为什么放在 Python 侧

它每次 push 都跑(ubuntu,1 倍计费);iOS 那个 job 是手动触发的(macOS 10 倍)。
守卫要放在跑得最勤的那一侧。
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WALK = ROOT / "ios" / "GrowthAppUITests" / "ScreenWalkTests.swift"
VIEW_DIRS = [ROOT / "ios" / "GrowthApp" / "Presentation",
             ROOT / "ios" / "GrowthApp" / "Ask"]

# 一个「跳转口」= 推一个新屏出来的地方。行首(允许缩进与收尾的 `}`)才算,
# 免得把注释里提到 `NavigationLink` 的句子数进来 —— 这个仓的注释里提得很多。
# ⚠️ 2026-10-12 补 `.navigationDestination(`:`M5-1` 的「原话 ›」用它推屏,
# 原判据看不见它 —— 一个新跳转口从闸底下溜过去,而清单照样对得上。
SITE = re.compile(r"^\s*\}?\s*(NavigationLink|\.sheet\(|\.fullScreenCover\(|\.navigationDestination\()")

# 清单写在 Swift 的文档注释里,前缀是 `///`(三个斜杠)不是 `//`。
# ⚠️ 这里踩过一次:用 `//` 去 `re.match` 三斜杠的行,一条都匹配不上,
# 而报出来的是「区块是空的」—— 看起来像清单没写,其实是尺子不对。
ROW   = re.compile(r"\s*/{2,3}\s*(\S+\.swift)\s+(\d+)\s+走(\d+)")
TOTAL = re.compile(r"/{2,3}\s*合计\s+(\d+)\s*/\s*(\d+)")

tests = []
def test(fn):
    tests.append(fn)
    return fn


def _declared() -> dict[str, int]:
    """读走查台里那张清单。清单不在 = 这条对撞失去了一边,直接红。"""
    assert WALK.exists(), f"{WALK} 不在了 —— 走查台没了,这条对撞要跟着删或改"
    text = WALK.read_text(encoding="utf-8")
    m = re.search(r"WALK-INVENTORY-BEGIN(.*?)WALK-INVENTORY-END", text, re.S)
    assert m, "ScreenWalkTests.swift 里找不到 WALK-INVENTORY 区块"
    out: dict[str, int] = {}
    for line in m.group(1).splitlines():
        row = ROW.match(line)
        if row:
            out[row.group(1)] = int(row.group(2))
    assert out, "WALK-INVENTORY 区块是空的"
    return out


def _actual() -> dict[str, int]:
    out: dict[str, int] = {}
    for d in VIEW_DIRS:
        assert d.exists(), f"{d} 不在了 —— 界面挪过位置,这条对撞要跟着改"
        for f in sorted(d.glob("*.swift")):
            n = sum(1 for line in f.read_text(encoding="utf-8").splitlines()
                    if SITE.match(line))
            if n:
                out[f.name] = n
    return out


@test
def test_every_navigation_site_is_accounted_for():
    """🔴 新加一个跳转口而没登记 ⇒ 走查台少走一页,**而它照样全绿**。

    2026-08-18 的 `M2-审1` 就是这个后果的实物:全 App 的 `NavigationLink`
    一个都不跳,824 条单测全绿,因为没有一条测试点过界面。
    """
    declared, actual = _declared(), _actual()

    added = {f: n for f, n in actual.items() if f not in declared}
    assert not added, (
        f"这些文件新出现了跳转口,而走查台的清单里没有:{added}\n"
        "去 ScreenWalkTests.swift 的 WALK-INVENTORY 区块登记 —— "
        "要么走它,要么写明为什么不走。不登记等于它永远没人点过。")

    gone = {f: n for f, n in declared.items() if f not in actual}
    assert not gone, (
        f"清单里这些文件已经没有跳转口了:{gone}\n"
        "前提没了,结论要跟着改(仓规 6):把它从清单里删掉。")

    drift = {f: (declared[f], actual[f]) for f in declared
             if declared[f] != actual.get(f)}
    assert not drift, (
        "跳转口数量对不上(清单 → 实际):"
        + "; ".join(f"{f} {d}→{a}" for f, (d, a) in drift.items())
        + "\n多出来的那个没人点过,少掉的那个清单还在替它记账。")


@test
def test_the_check_actually_catches_a_new_entry_point():
    """照妖镜:这条对撞自己会不会红。

    §3.3 —— 一条从来没红过的断言,和一条恒真的断言长得一模一样。
    """
    actual = dict(_actual())
    victim = sorted(actual)[0]
    actual[victim] += 1
    declared = _declared()
    drift = {f: (declared[f], actual[f]) for f in declared
             if declared[f] != actual.get(f)}
    assert drift, "给某个文件凭空加一个跳转口,这条对撞居然没红 —— 它是恒真的"


@test
def test_the_walk_declares_how_many_it_actually_walks():
    """清单里「走 N」的总和,必须与走查台真实覆盖的口数对得上。

    ⚠️ 这一条只保证**清单内部自洽**(声明走 N 口 ⇒ 汇总也是 N),
    挡不住「声明走了而其实没走」—— 那要靠走查台自己跑红。
    两者一起才完整:这里挡漏登记,那边挡假声明。
    """
    text = WALK.read_text(encoding="utf-8")
    m = re.search(r"WALK-INVENTORY-BEGIN(.*?)WALK-INVENTORY-END", text, re.S)
    per_file = [int(r.group(3)) for r in ROW.finditer(m.group(1))]
    total = TOTAL.search(m.group(1))
    assert total, "WALK-INVENTORY 区块里没有「合计 走过/总数」那一行"
    assert sum(per_file) == int(total.group(1)), (
        f"逐文件的「走 N」加起来是 {sum(per_file)},而合计写的是 {total.group(1)}")
    assert sum(_actual().values()) == int(total.group(2)), (
        f"源码里实际有 {sum(_actual().values())} 个跳转口,"
        f"而合计写的是 {total.group(2)}")


if __name__ == "__main__":
    failed = 0
    for t in tests:
        try:
            t()
            print(f"  ✓ {t.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"  ✗ {t.__name__}\n    {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} 通过")
    sys.exit(1 if failed else 0)

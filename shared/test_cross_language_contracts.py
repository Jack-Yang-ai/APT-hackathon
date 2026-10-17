#!/usr/bin/env python3
"""跨语言的成对约定:**两边各存一份,而只有一份被改过的话,这里要红。**

跑:python3 -m shared.test_cross_language_contracts

## 为什么这类测试要单开一组

这个仓 2026-08 反复出现同一个形态(六轮复核抓到八次,逐条记在 TASKS `M1-审4`):
**一件事在两处各存一份,而只有一份被维护。**
它的共同点是**运行时什么都不发生** —— 请求照发、结果照回、退出码全绿,
只有某个数字或某段音频悄悄落在了错的地方。

已经有对撞的:路由表、价表(`worker/test_extract.mjs`)、退役桩、声纹落盘路径。
这里补的是**跨语言那几对** —— 它们最容易漏,因为改一边的人通常打不开另一边:

  · R2 键的形状:Swift 写、Python 读
  · ASR 的两个开关:JS 里开、Swift 侧解析依赖它们

## 为什么放在 Python 侧

Python 套件在 CI 上**每次 push 都跑**(ubuntu,1 倍计费);
iOS 那个 job 是手动触发的(macOS 10 倍计费)。
守卫要放在跑得最勤的那一侧,不然它挡不住 push。
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

tests = []
def test(fn):
    tests.append(fn)
    return fn


def _read(rel: str) -> str:
    p = ROOT / rel
    assert p.exists(), f"{rel} 不在了 —— 这条对撞失去了一边,要跟着改"
    return p.read_text(encoding="utf-8")


# ── R2 键的形状:Swift 写、Python 读 ──────────────────────────────────

@test
def test_the_r2_audio_prefix_matches_on_both_sides():
    """🔴 前缀对不上 ⇒ **Mac 侧列目录列到空**,而两边都不报错。

    `R2Layout.swift` 的注释自己写着「与 `mac/r2_service.py::AUDIO_PREFIX`
    **必须逐字一致**」—— 它把要求说清楚了,却没有任何东西守着。
    """
    swift = _read("ios/GrowthApp/Upload/R2Layout.swift")
    py = _read("mac/r2_service.py")

    m_swift = re.search(r'static let audioPrefix = "([^"]+)"', swift)
    assert m_swift, "R2Layout.swift 里找不到 audioPrefix —— 结构变了,这条要跟着改"
    m_py = re.search(r'^AUDIO_PREFIX = "([^"]+)"', py, re.M)
    assert m_py, "r2_service.py 里找不到 AUDIO_PREFIX"

    assert m_swift.group(1) == m_py.group(1), (
        f"R2 前缀两处不一样:Swift {m_swift.group(1)!r} / Python {m_py.group(1)!r} —— "
        "手机把音频传到一个 Mac 不去列的地方,而两边都不报错"
    )


@test
def test_the_block_filename_is_zero_padded_to_four_on_both_sides():
    """🔴 补零位数是**字典序 == 块序**的唯一依据(§3.1.6 按 block_seq 排序拼接)。

    位数变了(比如补到三位)之后,`block-9` 会排在 `block-10` 前面 ——
    拼接顺序错乱,而每一句话仍然有一个看起来合理的时间戳。
    """
    swift = _read("ios/GrowthApp/Upload/R2Layout.swift")
    m = re.search(r'block-\\\(String\(format: "%0(\d+)d"', swift)
    assert m, "R2Layout.swift 里找不到块文件名的补零格式"
    assert m.group(1) == "4", f"Swift 侧补零到 {m.group(1)} 位,而约定是 4 位"

    # Python 侧不解析位数,它靠**字典序**;所以这里要确认那条依赖写在文档里没丢
    py = _read("mac/r2_service.py")
    assert "block-NNNN" in py, (
        "r2_service.py 里那句 `block-NNNN` 的约定没了 —— "
        "它是「补零到四位」在读侧的唯一记录"
    )


# ── ASR 的两个开关:JS 里开、Swift 侧解析依赖它们 ─────────────────────

@test
def test_the_worker_turns_on_both_asr_switches_the_parser_depends_on():
    """🔴 **分人要两个开关同时开**,少一个整条分人链静默失效。

    · `show_utterances` 关掉 ⇒ 报文里没有分句 ⇒ `ASRResponseParser` 抛
      `noUtterances`(这个还算看得见);
    · `enable_speaker_info` 关掉 ⇒ **分句还在、只是没有 speaker** ⇒
      解析器返回一堆 `speaker: nil` ⇒ `speakerByLine` 空 ⇒
      `writeClusterTags` 一行都不写 ⇒ **分人整条链什么都不做,而且不报错**。
      那正是 M0-20 那个缺陷的形态(「写进去了但对撞不上」的近亲)。

    改 worker 那两行的人打不开 Swift 文件,所以这条对撞必须存在。
    """
    js = _read("worker/src/index.js")
    swift = _read("ios/GrowthApp/Upload/ASRResponseParser.swift")

    for flag in ("show_utterances", "enable_speaker_info"):
        assert re.search(rf"^\s*{flag}:\s*true", js, re.M), (
            f"worker 没开 {flag} —— iOS 侧的 ASRResponseParser 依赖它;"
            "关掉之后分人链静默失效"
        )
        # 解析器那侧要留着这个开关的名字,不然下一个人不知道它依赖谁
        assert flag in swift, (
            f"ASRResponseParser 里不再提 {flag} —— 依赖关系断了记录,"
            "而它是「为什么 worker 必须开这个开关」的唯一说明"
        )


# ── 依赖:project.yml 声明、Package.resolved 上锁 ──────────────────

@test
def test_event_range_keys_match_on_both_sides():
    """事件的行范围(M5-1):worker 写 `line_from / line_to`,手机 ExtractionStore 读同一对。
    改一边忘了另一边的话,详情页会**静默**没有钟点、没有在场的人 —— 看起来像「老产物」。"""
    py = _read("worker/extract_two_stage.py")
    sw = _read("ios/GrowthApp/Database/ExtractionStore.swift")
    for key in ("line_from", "line_to"):
        # ⚠️ 只认 `ev["…"]` 这一种写法:`"line_from"` 在候选块那套里到处都是,
        # 宽松匹配的话 worker 把事件的键改名也照样绿(2026-10-12 对抗审查实测)。
        assert f'ev["{key}"]' in py, f"worker 不再写事件的 {key}"
        assert f'ev["{key}"]' in sw, f"ExtractionStore 不再读 {key}"


@test
def test_every_declared_package_is_actually_locked():
    """Generic implementation; local private materials are not distributed."""














    import json
    import re

    yml = _read("ios/project.yml")
    block = re.search(r"^packages:\n(.*?)^\w", yml, re.S | re.M)
    assert block, "project.yml 里找不到 packages: —— 结构变了,这条要跟着改"
    # 顶层两空格缩进的键就是包名
    declared = set(re.findall(r"^  (\w[\w.-]*):$", block.group(1), re.M))
    assert declared, "一个 package 都没抠出来,正则该修了"

    lock = json.loads(_read("ios/Package.resolved"))
    pins = lock.get("pins") or lock.get("object", {}).get("pins", [])
    locked_urls = " ".join((p.get("location") or p.get("repositoryURL") or "").lower()
                           for p in pins)

    missing = []
    for name in declared:
        m = re.search(rf"^  {re.escape(name)}:\n\s+url:\s*(\S+)", block.group(1), re.M)
        if not m:
            continue                      # 没写 url 的(本地包)不归这条管
        repo = m.group(1).rstrip("/").lower()
        if repo not in locked_urls:
            missing.append((name, repo))

    assert not missing, (
        f"这些依赖在 project.yml 里声明了,却不在 ios/Package.resolved 里:{missing}\n"
        "⇒ 它们没被锁住,换台机器可能解析到别的版本,而两边都会构建成功。\n"
        "修法:在 ios/ 下解析一次依赖,把生成的 Package.resolved 拷回 ios/Package.resolved 并提交。")


@test
def test_the_lock_is_not_ignored_by_git():
    """锁文件本身必须进版本库 —— 它不进,上面那条就无从谈起。

    `.gitignore` 里有 `ios/*.xcodeproj`,而工程里那份锁是**生成物**;
    真身是 `ios/Package.resolved`。它要是也被忽略了,整套机制就是空的。
    """
    import subprocess
    r = subprocess.run(["git", "check-ignore", "-q", "ios/Package.resolved"],
                       cwd=ROOT, capture_output=True)
    assert r.returncode != 0, (
        "ios/Package.resolved 被 .gitignore 挡住了 —— 锁文件不进版本库,"
        "那 `postGenCommand` 塞回去的只是本机上一次解析的结果,不是锁")


if __name__ == "__main__":
    failed = 0
    for fn in tests:
        try:
            fn()
            print("PASS", fn.__name__)
        except Exception as e:            # noqa: BLE001 —— 自测跑器,原因原样打出来
            failed += 1
            print("FAIL", fn.__name__, "\n   ", e)
    print(f"\n{failed} failed / {len(tests)}" if failed else f"\nall passed ({len(tests)})")
    sys.exit(1 if failed else 0)

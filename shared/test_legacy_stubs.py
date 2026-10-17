#!/usr/bin/env python3
"""搬来的模块调到的每一个桩,都要**炸得说得出为什么**。

跑:python3 -m shared.test_legacy_stubs

## 这组测试补的是什么

`legacy_stubs.py` 是按调用点一个一个补出来的,而**没人回头核对「调用点是不是都补齐了」**。
2026-08-18 复核就撞到一个:`shared/codebook.py:405` 调 `topics_v3.upsert_topic`,
而那个方法**根本没写**。

它抛的是裸 `AttributeError` —— **不是静默失败**(照样炸),
但它炸得说不出为什么。而这个文件存在的全部理由就是「炸的时候把改造方向一起说出来」:
撞上 `AttributeError` 的人会以为是个 bug,而真相是「这段该整段删」。

所以这里**从调用方的源码里把用到的属性抠出来**,再回头查桩有没有 ——
写死一份清单的话,下一次新加调用点又是同样的漏法。
"""
from __future__ import annotations

import re
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

tests = []
def test(fn):
    tests.append(fn)
    return fn


def _used_attributes() -> dict[str, set[str]]:
    """扫 shared/ 与 mac/,找出「从 legacy_stubs 引进来的名字」被点了哪些属性。"""
    used: dict[str, set[str]] = {}
    for path in sorted(ROOT.glob("shared/*.py")) + sorted(ROOT.glob("mac/*.py")):
        if path.name in {"legacy_stubs.py", "test_legacy_stubs.py"}:
            continue
        # ⚠️ **去掉注释再扫。** 不去的话 `# 泛指走 topics_v3.resolve_pending …`
        # 这种解释性注释会被当成真调用 —— 而「解释为什么不该用它」和「用了它」
        # 必须分得开。(两轮前 Swift 那道闸踩的是同一个坑,这次我自己又踩了一遍。)
        src = "\n".join(
            line.split("#", 1)[0] for line in
            path.read_text(encoding="utf-8").split("\n"))
        names = set()
        # ⚠️ 不能用 `[\w,\s]+` —— `\s` 吃换行,会把 import 下一行的
        # `return promote` 也当成被 import 的名字。**只吃到行尾。**
        for m in re.finditer(r"from\s+shared\.legacy_stubs\s+import\s+([\w, ]+)", src):
            names |= {n.strip() for n in m.group(1).split(",") if n.strip()}
        for name in names:
            # `topics_v3.upsert_topic(` / `promote.WORK_CIRCLE`
            attrs = {m.group(1) for m in re.finditer(rf"\b{re.escape(name)}\.(\w+)", src)}
            if attrs:
                used.setdefault(name, set()).update(attrs)
    return used


@test
def test_every_attribute_the_callers_use_actually_exists():
    """🔴 调用方点到的每一个属性,桩上都要有。"""
    import shared.legacy_stubs as stubs

    used = _used_attributes()
    assert used, "一个调用点都没扫到 —— 正则该修了,不是「没人用桩」"

    missing = []
    for name, attrs in sorted(used.items()):
        obj = getattr(stubs, name, None)
        assert obj is not None, f"legacy_stubs 里没有 {name},而有人 import 了它"
        for a in sorted(attrs):
            if not hasattr(obj, a):
                missing.append(f"{name}.{a}")
    assert not missing, (
        f"这些桩缺方法,撞上去抛的是裸 AttributeError、说不出改造方向:{missing}"
    )


@test
def test_retired_stubs_raise_and_say_why():
    """🔴 **抛异常,而且消息里要有改造方向。**

    静默 no-op 会精确复制旧仓最贵那次事故的形态(exit code 全绿而落错了层)。
    而只抛不说话,等于把「该怎么办」留给下一个人重新查一遍。
    """
    import shared.legacy_stubs as stubs

    cases = [
        (lambda: stubs.topics_v3.invalidate_cache(), "topics_v3"),
        (lambda: stubs.topics_v3.upsert_topic(None, "x", "y"), "episode_topics"),
        (lambda: stubs.label_server.mark_split("k", []), "手机端"),
    ]
    for fn, keyword in cases:
        try:
            fn()
        except stubs.RetiredInNewArchitecture as e:
            assert keyword in str(e), f"消息里没说清楚:{e}"
            assert len(str(e)) > 30, f"消息太短,说不出改造方向:{e}"
        else:
            raise AssertionError(f"{fn} 没抛 —— 静默 no-op 正是要防的那个形态")


@test
def test_the_circle_config_is_not_a_retired_stub():
    """圈层是**产品配置**不是旧逻辑 —— 它不该抛,该给一个可配置的真值。"""
    import shared.legacy_stubs as stubs

    assert isinstance(stubs.promote.WORK_CIRCLE, set)
    assert isinstance(stubs.promote.LIFE_CIRCLE, set)


if __name__ == "__main__":
    failed = 0
    for fn in tests:
        try:
            fn()
            print("PASS", fn.__name__)
        except Exception as e:            # noqa: BLE001 —— 自测跑器,要把原因原样打出来
            failed += 1
            print("FAIL", fn.__name__, "\n   ", e)
    print(f"\n{failed} failed / {len(tests)}" if failed else f"\nall passed ({len(tests)})")
    sys.exit(1 if failed else 0)

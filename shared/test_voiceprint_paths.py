#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""

























from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

tests = []
def test(fn):
    tests.append(fn)
    return fn


def _is_ignored(dir_path: pathlib.Path) -> bool:
    """**一个文件落进这个目录,会被 git 忽略吗。**

    ⚠️ 问的是「目录里的文件」,不是目录本身。`.gitignore` 里 `mac/voiceprints_v2/`
    这种带尾斜杠的模式**只匹配目录**,而 `git check-ignore` 在目录还不存在时
    认不出它是目录 ⇒ 会回答「没忽略」。
    第一版我就这么问的,于是四条路径全被报成泄漏 —— **假阳性**。
    而真正要回答的问题本来就是「底库落进去会不会进版本库」,拿文件问才对。
    """
    probe = dir_path / "registry.json"
    r = subprocess.run(["git", "check-ignore", "-q", str(probe)],
                       cwd=ROOT, capture_output=True)
    return r.returncode == 0


def _voiceprint_paths() -> dict[str, pathlib.Path]:
    """代码里所有会落声纹的目录。**从模块里读,不写死清单** ——
    写死的话,下一次新加一条路径又是同样的漏法。"""
    out: dict[str, pathlib.Path] = {}

    from shared import paths as config
    out["shared.paths.MEETING_VOICEPRINTS"] = pathlib.Path(config.MEETING_VOICEPRINTS)

    from mac.registry_v2 import REGISTRY_V2_PATH
    out["mac.registry_v2.REGISTRY_V2_PATH"] = pathlib.Path(REGISTRY_V2_PATH).parent

    # ⚠️ 从 `registry_v2` 读,**不从 `embed_v2`**。
    # 原来这里写的是 `from mac.embed_v2 import ...`,而它顶层 `import numpy` ——
    # CI 上没有 numpy,三条测试全挂在 import 上,**而它们一条都不需要 numpy**。
    # 旧注释说「embed_v2 顶部是惰性 import,所以这里 import 是安全的」:
    # 那对 torch 成立,对 numpy 不成立。本地装了 numpy ⇒ **本地绿、CI 红**。
    from mac.registry_v2 import VOICEPRINTS_V2_DIR, MODEL_REV_PATH
    out["mac.embed_v2.VOICEPRINTS_V2_DIR"] = pathlib.Path(VOICEPRINTS_V2_DIR)
    out["mac.embed_v2.MODEL_REV_PATH"] = pathlib.Path(MODEL_REV_PATH).parent
    return out


@test
def test_every_voiceprint_path_is_gitignored():
    """🔴 一条都不许漏。"""
    leaked = []
    for name, path in sorted(_voiceprint_paths().items()):
        # 仓库之外的路径(用户用环境变量指到别处)不归 .gitignore 管,跳过
        try:
            path.resolve().relative_to(ROOT)
        except ValueError:
            continue
        if not _is_ignored(path):
            leaked.append(f"{name} → {path.relative_to(ROOT)}")
    assert not leaked, (
        "这些声纹落盘路径**没被 .gitignore 覆盖** —— 生物特征数据会进版本库,"
        f"而本仓有 `git add -A` 卷走文件的事故史:{leaked}"
    )


@test
def test_the_model_manifest_sits_next_to_the_registry():
    """🔴 **model_rev 必须和 registry 同一个目录。**

    它存在的全部意义是「这份底库是哪个模型算的」—— 模型一换,分数空间漂移、
    旧阈值全部作废。两者分居两地时,你可以有一份 A 模型的底库配一份 B 模型的
    model_rev,**而没有任何东西会发现**。
    """
    from mac.registry_v2 import REGISTRY_V2_PATH
    from mac.registry_v2 import MODEL_REV_PATH
    assert pathlib.Path(MODEL_REV_PATH).parent == pathlib.Path(REGISTRY_V2_PATH).parent, (
        f"model_rev 在 {MODEL_REV_PATH},registry 在 {REGISTRY_V2_PATH} —— "
        "对不上的底库与模型标记会静默共存"
    )


@test
def test_no_stale_old_repo_layout_left_on_disk():
    """旧仓布局(`ingest/meeting/…`)不该再有东西往里写。

    ⚠️ 这条只查**代码指向哪**,不删盘上已有的目录 —— 删别人机器上的东西
    不是一条测试该做的事。盘上那份留着,由人决定。
    """
    for name, path in sorted(_voiceprint_paths().items()):
        assert "ingest/meeting" not in str(path), (
            f"{name} 还指着旧仓布局 {path} —— 搬过来之后 ROOT 变了,"
            "这条路径会落在保护圈外"
        )


if __name__ == "__main__":
    failed = 0
    for fn in tests:
        try:
            fn()
            print("PASS", fn.__name__)
        except Exception as e:            # noqa: BLE001 —— 自测跑器,原因要原样打出来
            failed += 1
            print("FAIL", fn.__name__, "\n   ", e)
    print(f"\n{failed} failed / {len(tests)}" if failed else f"\nall passed ({len(tests)})")
    sys.exit(1 if failed else 0)

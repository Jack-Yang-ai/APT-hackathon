"""registry_v2 读写 + 匹配：pyannote community-1 256d 嵌入空间的声纹底库（P0.2 起）。

与 v1 `ingest/meeting/voiceprints/registry.json`（CAM++ 192d）**完全隔离**——
不同目录、不同维度、不可互算 cos。老代码（speaker_id.py 的 load_registry/match/enroll）
一律只读写 v1 路径，本模块只服务 v2 新路径，两边互不感知。

registry_v2.json 结构：
  {version: 2, model_rev: str|None,
   people: {真名: {profiles: [{emb:[256 floats], src, meeting, dur}, ...]}}}
一人多 profile（按素材来源存档），不做「均值模板」——匹配时对每人取 profiles 里的 max cos。

阈值标定见 docs/voiceprint-migration-checklist.md P3（3.1/3.3 检查点C）；
本模块的 match_v2 **只排序展示，不做自动落定判断**——数字未标定前不能拿来当阈值用。
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

REGISTRY_V2_PATH = Path(__file__).resolve().parent / "voiceprints_v2" / "registry.json"

#: 声纹底库目录与模型指纹的落点。**从 registry 的位置推,不另写一份路径。**
#
# 🔴 **2026-08-26 从 `mac/embed_v2.py` 挪到这里。**
# 它们原来定义在 `embed_v2` 里,而那个模块**顶层 `import numpy`** ——
# 于是 `shared/test_voiceprint_paths`(只想读两个路径常量)被迫拖进 numpy,
# **CI 上没有 numpy ⇒ 三条测试全挂在 import 上,而它们一条都不需要 numpy**。
#
# ⚠️ 那个测试自己的注释写着「embed_v2 顶部是惰性 import,所以这里 import 是安全的」——
# 那句话**对 torch 成立,对 numpy 不成立**。而本地装了 numpy,所以
# **本地绿、CI 红**,而且红了至少两天没人发现(最近 100 次 CI 一次没绿过)。
#
# ⇒ 常量跟着**它的基**走(`REGISTRY_V2_PATH` 在这儿),而不是跟着**用它的人**走。
VOICEPRINTS_V2_DIR = REGISTRY_V2_PATH.parent
MODEL_REV_PATH = VOICEPRINTS_V2_DIR / "model_rev.json"


def load_registry_v2(path: Optional[Path] = None) -> dict:
    """读 registry_v2；不存在则返回空底库骨架（不报错，方便冷启动）。"""
    p = Path(path) if path else REGISTRY_V2_PATH
    if not p.exists():
        return {"version": 2, "model_rev": None, "people": {}}
    return json.loads(p.read_text(encoding="utf-8"))


def save_registry_v2(reg: dict, path: Optional[Path] = None) -> None:
    p = Path(path) if path else REGISTRY_V2_PATH
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(reg, ensure_ascii=False, indent=1), encoding="utf-8")


def match_v2(emb, reg: dict) -> list[tuple[str, float]]:
    """按 cos 降序返回 [(人名, max_cos), ...]（每人取其 profiles 里的最大值）。
    仅供人工/调用方参考展示，不含阈值判定——P3 标定前不要拿这个数字做自动落定。"""
    import numpy as np  # noqa: PLC0415

    v = np.asarray(emb, dtype=np.float64)
    out: list[tuple[str, float]] = []
    for name, info in (reg.get("people") or {}).items():
        profs = info.get("profiles") or []
        if not profs:
            continue
        best = max(float(np.dot(v, np.asarray(p["emb"], dtype=np.float64))) for p in profs)
        out.append((name, best))
    out.sort(key=lambda t: -t[1])
    return out


def enroll_v2(reg: dict, name: str, emb, *, src: str, meeting: str, dur: float) -> None:
    """把一条 256d 声纹以新 profile 并入某人档案（原地改 reg；调用方负责 save_registry_v2）。"""
    import numpy as np  # noqa: PLC0415

    people = reg.setdefault("people", {})
    person = people.setdefault(name, {"profiles": []})
    person["profiles"].append({
        "emb": [round(float(x), 6) for x in np.asarray(emb, dtype=np.float64).tolist()],
        "src": src,
        "meeting": meeting,
        "dur": round(float(dur), 2),
    })

#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""



















from __future__ import annotations

import json
from pathlib import Path
from typing import Literal

TABLE_PATH = Path(__file__).resolve().parent / "lexicon" / "reaction_cues.json"

#: 反应的三类。None = 词面没命中(灰区)。
Kind = Literal["dissatisfied", "correction", "appreciation"]

#: 命中时这次反应是好是坏。灰区没有极性 —— 极性要么来自词面,要么等模型给。
Polarity = Literal["good", "bad"]

_POLARITY: dict[str, Polarity] = {
    "dissatisfied": "bad",
    "correction": "bad",
    "appreciation": "good",
}

_cache: dict[str, list[str]] | None = None


def _table() -> dict[str, list[str]]:
    global _cache
    if _cache is None:
        raw = json.loads(TABLE_PATH.read_text(encoding="utf-8"))
        _cache = {k: v for k, v in raw.items() if not k.startswith("_")}
    return _cache


def reload_table() -> None:
    """丢掉缓存。改过表之后在同一个进程里重判时用。"""
    global _cache
    _cache = None


def classify(user_text: str | None, prior_agent_text: str | None) -> dict:
    """→ ``{forced, kind, polarity}``。

    - ``forced=True``  词面命中,**这次反应必须落账**,好坏已定,不问模型。
    - ``forced=False`` 灰区。``kind`` 与 ``polarity`` 都是 None,交模型判显著性;
      模型判不显著就不记(v4 §一:分诊分不出类别就记存疑,什么都不学)。

    判决是确定性的:同样的两句话跑一万次是同一个答案。
    """
    blank = {"forced": False, "kind": None, "polarity": None}

    # 硬前件:没有系统上一句就不判 —— 用户情绪不好 ≠ 系统说错话。
    if not (prior_agent_text or "").strip() or not (user_text or "").strip():
        return blank

    lowered = str(user_text).lower()
    table = _table()
    # 次序固定:纠正 → 不满 → 认可。
    # 纠正排最前是因为它最具体(「我说的是……」既是纠正也常带不满的语气),
    # 而下游对两者的处置不同:纠正要去改那条记错的,不满只调递送策略。
    for kind in ("correction", "dissatisfied", "appreciation"):
        if any(cue.lower() in lowered for cue in table.get(kind, ())):
            return {"forced": True, "kind": kind, "polarity": _POLARITY[kind]}
    return blank

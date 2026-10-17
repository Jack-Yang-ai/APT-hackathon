#!/usr/bin/env python3
"""daily/ 产物的共享读写 + LLM JSON 抽取 + 时段分桶。

为什么独立一层：read_json / 原子写 / 从 LLM 回复抠 JSON / tod_bucket 之前在
adherence、stimulus、response_probe、build_context、breathing_probe、orchestrate、
eval_plan 各抄一份，改一处其余静默不同步。收敛到这里，别再各处重抄。
"""
from __future__ import annotations

import json
import os
import statistics  # noqa: F401 — 预留给将来共享的聚合 helper
from pathlib import Path


def read_json(path):
    """读 JSON，缺失/损坏/读不了都返回 None（不抛）。"""
    try:
        return json.loads(Path(path).read_text())
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None


def write_json(path, obj, *, indent=2):
    """**原子写**：先写 .tmp 再 os.replace 覆盖。

    非原子写（write_text 直写）一旦中途崩溃会留下截断的 JSON，下次 read_json
    静默读成 None＝「今天没数据」，是看不见的数据丢失。os.replace 同盘原子。
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=indent))
    os.replace(tmp, path)  # 原子：要么旧文件、要么完整新文件，不会有半截


def extract_json(text, kind="object"):
    """从 LLM 回复抠出 JSON（容忍 ```fence / 前后废话）。kind='object'|'array'。
    抽不出 / 解析失败返回 None。各调用方按自己的契约包一层（raise / {} / []）。"""
    if not text:
        return None
    open_c, close_c = ("[", "]") if kind == "array" else ("{", "}")
    s, e = text.find(open_c), text.rfind(close_c)
    if s < 0 or e <= s:
        return None
    try:
        return json.loads(text[s:e + 1])
    except json.JSONDecodeError:
        return None


def tod_bucket(dt):
    """时段分桶：morning 04-12 / afternoon 12-18 / evening 其余（含夜 0-4）。"""
    h = dt.hour
    if 4 <= h < 12:
        return "morning"
    if 12 <= h < 18:
        return "afternoon"
    return "evening"

#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""

























from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Literal

TABLE_PATH = Path(__file__).resolve().parent / "lexicon" / "attribute_classes.json"

#: 属性的三分。None = 表里没有这个属性。
AttributeClass = Literal["single", "multi", "event"]

#: 两条条目之间的关系。
#:
#: never   —— 不是同一个归一键,各自成条(主体不同 / 事件)。
#: append  —— 同一个键,并列或追加证据(多值属性 / 单值但值相同)。
#: contest —— 同一个键且值不同,**进夺位裁决**:新的顶掉旧的,旧的进演变链。
#: noted   —— 同一个键且值不同,但这句话过不了裁决线(非直陈或玩笑)⇒
#:            只挂「矛盾提及」,不夺位(v4 §五)。
Relation = Literal["never", "append", "contest", "noted"]

_cache: dict[str, Any] | None = None


def _table() -> dict[str, Any]:
    global _cache
    if _cache is None:
        _cache = json.loads(TABLE_PATH.read_text(encoding="utf-8"))
    return _cache


def reload_table() -> None:
    """丢掉缓存。改过表之后在同一个进程里重判时用。"""
    global _cache
    _cache = None


def classify_attribute(name: str | None) -> AttributeClass | None:
    """属性名 → 三分之一。表里没有就返回 None(**不猜**)。

    先精确匹配再走模式,精确的赢 —— 模式是兜底,不该盖过写死的那条。
    """
    if not name:
        return None
    key = str(name).strip()
    if not key:
        return None
    table = _table()
    for cls in ("single", "multi", "event"):
        if key in table.get(cls, ()):
            return cls  # type: ignore[return-value]
    for cls in ("single", "multi", "event"):
        for pattern in table.get(f"{cls}_patterns", ()):
            if re.match(pattern, key):
                return cls  # type: ignore[return-value]
    return None


def supersede(new: dict, old: dict) -> Relation:
    """新旧两条条目的关系。

    入参各含:``subject_id`` / ``attribute`` / ``value`` /
    ``direct``(是不是本人直陈)/ ``joking``(是不是玩笑)/ ``negates_old``(可选)。

    判决顺序是**从最硬的排除开始**,每一条都写着它挡的是什么:
    """
    # ① 主体不同 —— 两个人的同类事实不是同一件事。**这条排第一**:
    #    它挡的是「另一个人的记忆被覆盖」,而那种错事后无从发现(旧值没了)。
    new_subject, old_subject = new.get("subject_id"), old.get("subject_id")
    if new_subject is not None and old_subject is not None and new_subject != old_subject:
        return "never"

    # ② 主体不明 —— 宁可留一条重复,也不能悄悄覆盖掉可能属于别人的那条。
    #    (重复很便宜:用户看得见、能手动合;覆盖是不可逆的。)
    if new_subject is None or old_subject is None:
        return "append"

    # ③ 属性对不上 —— 连讲的是不是同一件事都不知道,不夺位。
    if not new.get("attribute") or new.get("attribute") != old.get("attribute"):
        return "never"

    kind = classify_attribute(new.get("attribute"))

    # ④ 事件永不合并。「周日去爬山」和「上个月去博物馆」是两件事,
    #    把后者并进前者会把细节揉平、日期还错(VoiceMem 那起事故)。
    if kind == "event":
        return "never"

    # ⑤ 表里没有这个属性 —— **不猜**。追加是安全的那一侧。
    if kind is None:
        return "append"

    # ⑥ 值相同 —— 同一件事又说了一遍,当追加证据。
    if _same_value(new.get("value"), old.get("value")):
        return "append"

    # ⑦ 多值属性:并列。过敏可以既花生又海鲜。只有明确否定旧值才谈夺位。
    if kind == "multi":
        return _contest_or_noted(new) if new.get("negates_old") else "append"

    # ⑧ 单值属性且值不同 —— 这才是夺位的唯一入口。
    return _contest_or_noted(new)


def _contest_or_noted(new: dict) -> Relation:
    """裁决线的前两项:直陈 ∧ 非玩笑。过不了只挂矛盾提及,不夺位(v4 §五)。"""
    if new.get("direct") and not new.get("joking"):
        return "contest"
    return "noted"


def _same_value(a: Any, b: Any) -> bool:
    """值一不一样。只做去空白与大小写归一,**不做语义比较** ——
    语义比较是模型的活,而这里是判决层。"""
    return str(a or "").strip().lower() == str(b or "").strip().lower()

#!/usr/bin/env python3
"""抽取:prompt + 输出 schema 校验 + 三项校验 + 失败率计数(技术方案 §4.2,判 4)。

这个模块**不调模型**——它只负责「问什么」和「收到之后怎么验」。真正的调用走云代理
(M0-9),那边接记账。这样拆是为了让校验逻辑能离线跑、能被判分尺子复用同一套口径。

契约里最要紧的两条,改之前先回去看 §4.2:

  · **没有 who。** 「谁说的」一律由归属层派生,不接受模型输出。三项校验里的
    「说话人一致」正是拿模型那份和归属层那份对撞——契约里同时存在两份,
    这项校验就变成自己校验自己了。
  · **speaker_hint 只用于校验、永不落库。** 它是模型看到的簇标签,用来发现
    「行号存在但挂错行」;校验完就必须剥掉,所以 validate() 返回的条目里没有它。

失败率为什么和结果绑在一起返回:旧仓最贵的一次事故形态是「静默丢弃」——
丢了多少、为什么丢,账面上看不见。这里 validate() 返回 (clean, stats) 二元组,
**拿不到结果就拿不到,拿到了就必然同时拿到计数**,想忽略都没处忽略。
"""
from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass, field
from typing import Any

from shared.text_normalize import NORMALIZER_VERSION, is_verbatim

PROMPT_VERSION = "v1"

# §4.2:实测 8000 会被 thinking 吃光、返回空正文。这是下限不是建议值。
MAX_TOKENS = 20000

# 六类产出。带 line_id 与 quote、能跑三项校验的是前四类。
ITEM_KINDS = ("key_points", "commitments", "stances", "pendings")
ALL_KINDS = ITEM_KINDS + ("topic_keys",)

# 每类条目的必填字段(§4.2 的 JSON 契约)
_REQUIRED_FIELDS: dict[str, tuple[str, ...]] = {
    "key_points":  ("point", "quote", "line_id"),
    "commitments": ("what", "quote", "line_id"),
    "stances":     ("stance", "quote", "line_id"),
    "pendings":    ("issue", "quote", "line_id"),
    "topic_keys":  ("key", "line_ids"),
}

# 校验完必须剥掉的字段:只用于校验、永不落库
_STRIP_FIELDS = ("speaker_hint",)


EXTRACT_PROMPT = f"""你在读一场录音的逐句转写,每一行都带行号。请抽出这一场的纪要。

只输出一个 JSON 对象,不要解释、不要代码围栏。结构:

{{
  "one_liner": "整场结论,不超过 40 字",
  "key_points":  [{{"point": "...", "quote": "...", "line_id": 0, "speaker_hint": "说话人2"}}],
  "commitments": [{{"what": "...", "quote": "...", "line_id": 0, "to_whom_text": "老王", "speaker_hint": "说话人1"}}],
  "stances":     [{{"stance": "...", "quote": "...", "line_id": 0, "speaker_hint": "说话人3",
                    "premise": null, "premise_line_id": null}}],
  "pendings":    [{{"issue": "...", "quote": "...", "line_id": 0, "parties_text": ["老王"]}}],
  "topic_keys":  [{{"key": "...", "line_ids": [0]}}]
}}

硬要求:

1. **每一条都必须带 line_id**,指向它的依据行。给不出行号的条目直接不要写。
2. **quote 必须是那一行的原文片段,逐字照抄**,不许改写、不许拼接多行。
   自由文本字段(point / what / stance / issue)可以压缩改写,quote 不行——
   前者给人看,后者要拿去和原文比对。
3. **不要写「谁说的」**。没有这个字段,也不要用别的名字塞进来。
   `speaker_hint` 只填你在转写里看到的簇标签原文(如「说话人2」),
   它只用来交叉核对,不会被存下来。
4. `premise` 只在原话里真的说了前提时才填,并给出 `premise_line_id`。
   **没说就填 null,不要替他补一个听起来合理的**。
5. `to_whom_text` / `parties_text` 填原话里出现的称呼字符串,不要猜真名。
6. 一条内容都抽不到时,对应数组给空数组,不要编。

转写(格式:行号 | 簇标签 | 原话):

{{transcript}}
"""


class SchemaError(ValueError):
    """模型输出不合契约。抛出去,不要当成「这场没抽到内容」。"""


class TruncatedOutputError(SchemaError):
    """输出被截断。§4.2 明列的静默失败模式:必须报错,不得当成空结果。"""


@dataclass
class ExtractionStats:
    """一场的校验账本。丢了多少、为什么丢,必须能看见。"""
    total: int = 0
    passed: int = 0
    pending: int = 0
    discarded: int = 0
    discard_reasons: Counter = field(default_factory=Counter)
    pending_reasons: Counter = field(default_factory=Counter)
    normalizer_version: str = NORMALIZER_VERSION
    prompt_version: str = PROMPT_VERSION

    @property
    def failure_rate(self) -> float | None:
        """被丢弃的占比。没有可校验条目时是 None,不是 0.0。"""
        return None if self.total == 0 else round(self.discarded / self.total, 4)

    @property
    def pending_rate(self) -> float | None:
        return None if self.total == 0 else round(self.pending / self.total, 4)

    def as_dict(self) -> dict[str, Any]:
        return {
            "total": self.total, "passed": self.passed,
            "pending": self.pending, "discarded": self.discarded,
            "failure_rate": self.failure_rate, "pending_rate": self.pending_rate,
            "discard_reasons": dict(self.discard_reasons),
            "pending_reasons": dict(self.pending_reasons),
            "normalizer_version": self.normalizer_version,
            "prompt_version": self.prompt_version,
        }


def parse_model_output(raw: str) -> dict:
    """把模型返回的正文解析成 dict。

    解析不了就抛,**绝不返回空字典**——「输出被截断」和「这场没内容」在
    下游看起来一模一样,而前者是要重试的,后者不是。§4.2 把它单列为一种
    已发生过的静默失败模式。
    """
    text = raw.strip()
    if not text:
        raise TruncatedOutputError("模型返回空正文(§4.2:max_tokens 不足时会这样,不是没抽到)")
    try:
        obj = json.loads(text)
    except json.JSONDecodeError as e:
        raise TruncatedOutputError(f"输出不是完整 JSON,极可能被截断:{e}") from e
    if not isinstance(obj, dict):
        raise SchemaError(f"顶层必须是对象,实际是 {type(obj).__name__}")
    return obj


def validate_schema(payload: dict) -> None:
    """只查结构,不查内容真假。结构不对直接抛,不做兜底填充。"""
    if "one_liner" not in payload:
        raise SchemaError("缺 one_liner")
    if not isinstance(payload["one_liner"], str):
        raise SchemaError("one_liner 必须是字符串")

    for kind in ALL_KINDS:
        items = payload.get(kind)
        if items is None:
            raise SchemaError(f"缺 {kind}(抽不到就给空数组,不要省略)")
        if not isinstance(items, list):
            raise SchemaError(f"{kind} 必须是数组")
        for i, item in enumerate(items):
            if not isinstance(item, dict):
                raise SchemaError(f"{kind}[{i}] 必须是对象")
            for f in _REQUIRED_FIELDS[kind]:
                if f not in item:
                    raise SchemaError(f"{kind}[{i}] 缺字段 {f}")
            if "who" in item:
                raise SchemaError(
                    f"{kind}[{i}] 出现了 who —— 契约里没有这个字段(§4.2),"
                    "归属只能有一个真相源")


def _check_item(item: dict, line: dict | None) -> tuple[str, str]:
    """三项校验。返回 (verdict, reason),verdict ∈ passed / pending / discarded。"""
    # 行号命中:存在,且不是占位行(A6:占位行不可被引用为证据)
    if line is None:
        return "discarded", "行号不存在"
    if line.get("is_gap", 0) == 1:
        return "discarded", "指向占位行"

    # 文本逐字:只打 quote,不打自由文本
    if not is_verbatim(item.get("quote", ""), line["text"]):
        return "discarded", "quote 非原文子串"

    # 说话人一致:归属未定则挂起(不丢弃),归属到位后自动出现
    if line.get("person_id") is None:
        return "pending", "归属未定"

    # speaker_hint 与派生簇标签不一致 → 挂起复核(补回「模型挂错行」的检测能力)
    hint = item.get("speaker_hint")
    if hint is not None and line.get("cluster_tag") is not None and hint != line["cluster_tag"]:
        return "pending", "簇标签与 speaker_hint 不一致"

    return "passed", ""


def validate(payload: dict, lines: list[dict]) -> tuple[dict, ExtractionStats]:
    """跑完 schema 校验 + 三项校验,返回 (可落库的产出, 账本)。

    产出里:丢弃的条目已剔除;挂起的条目**保留**并带 `pending=True`
    (§4.2:挂起不丢弃,归属到位后自动出现);`speaker_hint` 一律剥掉。
    """
    validate_schema(payload)
    by_id = {line["line_id"]: line for line in lines}

    clean: dict[str, Any] = {"one_liner": payload["one_liner"], "topic_keys": []}
    stats = ExtractionStats()

    for kind in ITEM_KINDS:
        kept = []
        for item in payload[kind]:
            stats.total += 1
            verdict, reason = _check_item(item, by_id.get(item["line_id"]))
            if verdict == "discarded":
                stats.discarded += 1
                stats.discard_reasons[reason] += 1
                continue
            out = {k: v for k, v in item.items() if k not in _STRIP_FIELDS}
            if verdict == "pending":
                stats.pending += 1
                stats.pending_reasons[reason] += 1
                out["pending"] = True
            else:
                stats.passed += 1
            kept.append(out)
        clean[kind] = kept

    # topic_keys 没有 quote,跑不了逐字校验;只留行号确实存在的那些
    clean["topic_keys"] = [
        {**t, "line_ids": [i for i in t["line_ids"] if i in by_id]}
        for t in payload["topic_keys"]
    ]
    from .personal_actions import validate as validate_actions
    clean.update(validate_actions(payload, lines))
    return clean, stats


def render_prompt(lines: list[dict]) -> str:
    """把转写行渲染进 prompt。行号在最前,模型才好照抄。"""
    body = "\n".join(
        f"{line['line_id']} | {line.get('cluster_tag') or '未分人'} | {line['text']}"
        for line in lines
    )
    return EXTRACT_PROMPT.replace("{transcript}", body)


def render_prompt_with_actions(lines: list[dict]) -> str:
    from .personal_actions import PROMPT
    return render_prompt(lines) + PROMPT

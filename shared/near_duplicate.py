#!/usr/bin/env python3
"""几乎重复的文本,折成一条。**与 `ios/GrowthApp/Database/NearDuplicate.swift` 同一个算法。**

    python3 -m shared.test_near_duplicate      # 自测(含跨语言夹具)

## 为什么有两份实现

行级去重跑在手机上(Swift,L1 检索结果),条目级去重跑在 Mac 上(这里,L2 与抽取产物)。
两份实现是**跨语言的一对**,而这个仓最贵的事故形状正是「一件事两个出处,而只有一份
被维护」—— 所以有一份共同夹具(`shared/fixtures/recall/near_dup_vectors.json`)
两边各自对着它断言,谁漂了谁红。

## 参数为什么不写死成一个数

`gram` 与 `threshold` 是**按文本长度**变的:Swift 那边量过转写行(短句),
定的是 2 字组 / 0.55。条目文本更长,同一组参数不一定成立 ——
量法在 `eval/near_dup_label.py`,量出来之前这里的默认值就是 Swift 那一组,
并在文档里说明它是**借来的**,不是量过的。
"""
from __future__ import annotations

from typing import Callable, Hashable, Iterable, Sequence, TypeVar

#: 转写行(短句)上量出来的一组。**条目文本上没有量过** ——
#: 见 `docs/evidence/m2-检2/near_dup.md`。
LINE_GRAM = 2
LINE_THRESHOLD = 0.55

T = TypeVar("T")


def grams(text: str, n: int = LINE_GRAM) -> set[str]:
    """字符 n 元组。短于 n 的整串算一个,空串给空集。

    ⚠️ 与 Swift 那边逐字符对齐:**不去标点、不归一大小写**。
    做了归一就是另一个算法,而两边只要有一边做了,同一对文本就会给出不同的分。
    """
    chars = list(text or "")
    if not chars:
        return set()
    if len(chars) < n:
        return {"".join(chars)}
    return {"".join(chars[i:i + n]) for i in range(len(chars) - n + 1)}


def similarity(a: str, b: str, n: int = LINE_GRAM) -> float:
    """Jaccard:交集 / 并集。两边都空时,完全相同算 1,否则 0。"""
    ga, gb = grams(a, n), grams(b, n)
    if not ga or not gb:
        return 1.0 if a == b else 0.0
    union = len(ga | gb)
    return len(ga & gb) / union if union else 0.0


def fold(items: Sequence[T],
         key: Callable[[T], Hashable],
         text: Callable[[T], str],
         n: int = LINE_GRAM,
         threshold: float = LINE_THRESHOLD) -> list[tuple[T, int]]:
    """把 `items` 里几乎重复的折起来。→ [(留下的那条, 被折掉几条)]。

    **保留先出现的那一条**:调用方按时间倒序传进来,于是留下的是最近一次说的。
    只在同一个 `key` 内折 —— 跨场次的重复是信号不是噪音(「他第 3 次提到交付时间」
    正是 PRD §4.5.4 的「反复关切」)。
    """
    kept: list[list] = []                      # [item, folded]
    by_key: dict[Hashable, list[tuple[int, set[str]]]] = {}
    for item in items:
        k = key(item)
        g = grams(text(item), n)
        merged_into = None
        for index, other in by_key.get(k, ()):
            union = len(g | other)
            sim = (len(g & other) / union) if union else 0.0
            if sim >= threshold:
                merged_into = index
                break
        if merged_into is not None:
            kept[merged_into][1] += 1
        else:
            kept.append([item, 0])
            by_key.setdefault(k, []).append((len(kept) - 1, g))
    return [(entry[0], entry[1]) for entry in kept]


def pairwise_scores(texts: Iterable[str], n: int = LINE_GRAM) -> list[tuple[int, int, float]]:
    """所有两两组合的分。给量法脚本抽候选对用。"""
    rows = list(texts)
    out: list[tuple[int, int, float]] = []
    for i in range(len(rows)):
        for j in range(i + 1, len(rows)):
            out.append((i, j, similarity(rows[i], rows[j], n)))
    return out

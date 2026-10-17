#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""



















from __future__ import annotations

import json
import re

# 转写里给播报行打的标记：`- **说话人N〔播报〕** [ts] text`。
# run.py 落转写时贴，memory/ingest_meeting 见到就跳过（不进 L1 原子）；
# speaker_id/core_gate 也据簇判定跳过。取全角括号避免与真名冲突。
BROADCAST_TAG = "〔播报〕"

# ── ① 词法快路：只放**毫无悬念**的播报话术（高精度，宁可漏给 LLM，不可错杀真人行）──
BROADCAST_PATTERNS = [
    # 轨交/公交报站
    r"先下后上", r"当心缝隙", r"门灯闪烁", r"请勿上下?车", r"本次列车",
    r"到站的乘客", r"下车的乘客", r"验票出站", r"依次通过闸机", r"爱心(专座|车厢)",
    r"开往.{0,8}方向", r"欢迎乘坐", r"[到本]站.{0,4}(终点站|终点)",
    # 车载导航
    r"请靠边停车", r"重新规划路线", r"前方.{0,10}(拥堵|测速|摄像头|限速|路口|掉头)",
    r"\d+米后(左转|右转|直行|掉头|进入)", r"到达目的地(附近)?", r"已为您规划",
    # 广告/媒体/电话自动语音
    r"扫码(关注|领取|支付)", r"敬请期待", r"转[人工]工?服务", r"工号\d+",
    r"为您服务", r"按\d键",
]
_LEX = re.compile("|".join(BROADCAST_PATTERNS))

_SAMPLE_PER_CLUSTER = 8      # 簇级判定采样句数（最长优先，够判够省）
_LINE_BATCH = 50            # 混杂簇行级判定每批行数
_LEX_CLUSTER_MIN = 2        # 簇内 ≥此条词法命中 → 直接判整簇 broadcast（免 LLM，确定性）
                            # 真人不可能同一簇里说出两句不同的标准报站/导航话术

_CLUSTER_SYS = "你在判断录音里的一个说话人是不是对话里的真人参与者。只看内容，简短果断。"
_CLUSTER_PROMPT = """下面是同一个说话人在一段录音里说的几句话。判断这个说话人属于：
- real：对话中的真人参与者（哪怕只是简短搭话、语气词）
- broadcast：非参与者音源——地铁/公交报站、车载导航、电视/短视频、广告、电话自动语音这类「被录进来的声音」
- mixed：这几句里既有真人对话、又混进了上述播报（分人常把两者揉进一个簇）

报站/导航/广告话术高度模板化，容易认。真人在**聊**地铁或导航（如「我等下坐几号线」）算 real。
只回一个词：real 或 broadcast 或 mixed。

句子：
{samples}"""

_LINE_SYS = "你在从一段录音里挑出「非参与者音源」的句子。只看内容。"
_LINE_PROMPT = """下面是带编号的句子，来自同一段录音。挑出属于「非参与者音源」
（地铁/公交报站、车载导航、电视/短视频、广告、电话自动语音）的句子编号。
真人对话（哪怕在聊地铁、聊导航）不算。只回一个 JSON 数组，如 [2,5]；没有就回 []。

{numbered}"""


def lexical_is_broadcast(text: str) -> bool:
    return bool(_LEX.search(text or ""))


def _default_model_call(prompt: str, system: str) -> str:
    from shared import model_router
    model_router.load_secrets()
    return model_router.call(prompt, system, scene="label", max_tokens=200)


def _norm(lines):
    """统一成 [(idx, speaker_no_qmark, text)]，兼容 Line 对象与 dict（转写解析出的行）。"""
    out = []
    for i, l in enumerate(lines):
        if isinstance(l, dict):
            spk, text = l.get("spk") or l.get("speaker") or "", l.get("text") or ""
        else:
            spk, text = getattr(l, "speaker", "") or "", getattr(l, "text", "") or ""
        out.append((i, (spk or "").rstrip("?"), text))
    return out


def _cluster_verdict(label, sample_texts, model_call) -> str:
    samples = "\n".join(f"- {t}" for t in sample_texts)
    try:
        r = model_call(_CLUSTER_PROMPT.format(samples=samples), _CLUSTER_SYS).strip().lower()
    except Exception:  # noqa: BLE001 — LLM 挂了：该簇按「未知」处理（仅词法生效）
        return "unknown"
    if "broadcast" in r:
        return "broadcast"
    if "mixed" in r:
        return "mixed"
    if "real" in r:
        return "real"
    return "unknown"


def _line_level_broadcast(items, model_call) -> set[int]:
    """items=[(idx,text)]，分批问 LLM 哪几行是播报，返回播报的原始 idx 集合。"""
    hit = set()
    for b in range(0, len(items), _LINE_BATCH):
        batch = items[b:b + _LINE_BATCH]
        numbered = "\n".join(f"{n}. {t}" for n, (_, t) in enumerate(batch))
        try:
            raw = model_call(_LINE_PROMPT.format(numbered=numbered), _LINE_SYS)
            arr = json.loads(raw[raw.find("["): raw.rfind("]") + 1])
        except Exception:  # noqa: BLE001
            continue
        for n in arr:
            if isinstance(n, int) and 0 <= n < len(batch):
                hit.add(batch[n][0])
    return hit


def classify(lines, model_call=None, *, use_llm: bool = True) -> dict:
    """判定一段录音的播报行/簇。返回:
      {broadcast_lines: set[int 行索引], broadcast_clusters: set[str 说话人标签],
       verdicts: {簇: real|broadcast|mixed|unknown}, lexical_hits: int}
    fail-open：model_call/LLM 不可用时退化为纯词法（只标最典型的播报行，不判簇）。"""
    norm = _norm(lines)
    by_cluster: dict[str, list] = {}
    for idx, spk, text in norm:
        by_cluster.setdefault(spk, []).append((idx, text))

    # ① 词法快路：先标掉毫无悬念的播报行
    lex_lines = {idx for idx, _, text in norm if lexical_is_broadcast(text)}

    if model_call is None and use_llm:
        try:
            model_call = _default_model_call
        except Exception:  # noqa: BLE001
            model_call = None
    if model_call is None or not use_llm:
        return {"broadcast_lines": set(lex_lines), "broadcast_clusters": set(),
                "verdicts": {}, "lexical_hits": len(lex_lines)}

    broadcast_lines = set(lex_lines)
    broadcast_clusters: set[str] = set()
    verdicts: dict[str, str] = {}
    for label, items in by_cluster.items():
        if not label or label == "未分人":       # 未分人不判簇（无身份可污染），仅保留词法
            continue
        # ②a 词法主导：簇内多条报站/导航话术 → 确定性判整簇 broadcast（不问 LLM，稳定+免费）
        lex_in_cluster = sum(1 for idx, _ in items if idx in lex_lines)
        if lex_in_cluster >= _LEX_CLUSTER_MIN:
            verdicts[label] = "broadcast"
            broadcast_clusters.add(label)
            broadcast_lines.update(idx for idx, _ in items)
            continue
        # ②b 簇级 LLM：代表句取最长的几句
        samples = [t for _, t in sorted(items, key=lambda it: -len(it[1]))[:_SAMPLE_PER_CLUSTER] if t]
        v = _cluster_verdict(label, samples, model_call) if samples else "unknown"
        verdicts[label] = v
        if v == "broadcast":
            broadcast_clusters.add(label)
            broadcast_lines.update(idx for idx, _ in items)
        elif v == "mixed":
            # ③ 行级：只在混杂簇上跑（词法已兜的行不必再问）
            todo = [(idx, t) for idx, t in items if idx not in lex_lines and t]
            broadcast_lines.update(_line_level_broadcast(todo, model_call))
    return {"broadcast_lines": broadcast_lines, "broadcast_clusters": broadcast_clusters,
            "verdicts": verdicts, "lexical_hits": len(lex_lines)}

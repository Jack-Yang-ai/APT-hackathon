#!/usr/bin/env python3
"""假的云代理:转写与抽取两个上游的本地替身(M0-12a 验收用)。

**为什么要有假上游**:M0-12a 要验的是「链路串得对不对」,不是「模型好不好」。
真上游要花钱、要网络、返回还不确定 —— 拿它跑编排,失败了分不清是编排的锅还是模型的锅。
真上游那一跑是 M0-12。

**为什么假上游要故意产坏数据**:三项校验(§4.2)是这条链路上最实的一道闸。
假上游只产完美数据的话,校验那一环在端到端里根本没被走到 ——
于是「跑通了」和「校验是活的」被混为一谈,而这正是本仓最贵的那种错觉。
所以下面刻意掺三种真实 LLM 会犯的错:引文不是原文、行号不存在、引到占位行。
它们**应该**被丢弃,丢弃计数出现在运行报告里;一个都没丢反而说明校验没生效。

确定性:同样输入永远同样输出,不用随机数 —— 编排跑两次结果能逐字节比。
"""
from __future__ import annotations

# 一场对话里会出现的几种句子。轮着用,够让下游有东西可嚼。
_SENTENCES = [
    "这个方案我们下周三之前定下来,我来出第一版。",
    "我担心的是端侧那块的内存,真机上跑起来不一定够。",
    "先按现在这个口径走,不达标再回来改。",
    "上一版的问题是切点全落在句子中间,拼出来一堆截断句。",
    "我同意这个判断,但排期得往后压一周。",
    "本次列车开往人民广场方向,请先下后上,当心缝隙。",
    "那件事还没结论,等实测数字出来再说。",
    "我这边负责把账本接进去,今天之内能提。",
]

# 一条 ASR 行的目标长度(裁剪后时间轴上的毫秒)
_LINE_MS = 15_000


def transcribe(block_seq: int, kept_total_ms: int) -> list[dict]:
    """一块的转写结果。时间戳在**裁剪后**时间轴上(§3.1.6 时间轴对账契约)。

    刻意让最后一行的 end 正好落在 kept_total_ms 上:那是还原函数的边界,
    真 ASR 也常常把最后一句的结束时间贴到音频结尾。
    """
    if kept_total_ms <= 0:
        return []
    n = max(1, kept_total_ms // _LINE_MS)
    lines = []
    for i in range(n):
        start = i * _LINE_MS
        end = kept_total_ms if i == n - 1 else start + _LINE_MS - 500
        lines.append({"startMs": start, "endMs": end,
                      "text": _SENTENCES[(block_seq * 3 + i) % len(_SENTENCES)],
                      # 分人标签(M0-20)。真 ASR 会给 `speaker_N`,这里两人轮流 ——
                      # ⚠️ **只给一个人的话,「说话人一致」那项校验永远撞不上**
                      # (每一条 speaker_hint 都对),而这条链路的意义正是把它跑到。
                      "speaker": f"speaker_{i % 2}"})
    return lines


def extract(lines: list[dict]) -> dict:
    """抽取产出。形状照 §4.2 的 JSON 契约,**不含 who**(归属只能有一个真相源)。

    lines 是冻结之后的行(带 line_id / text / is_gap)。
    """
    real = [l for l in lines if not l.get("is_gap")]
    gaps = [l for l in lines if l.get("is_gap")]
    if not real:
        return _empty()

    def quote_of(line: dict, chars: int = 8) -> str:
        return line["text"][:chars]

    picks = real[:: max(1, len(real) // 4)][:4]
    while len(picks) < 4:
        picks.append(real[0])

    payload = {
        "one_liner": "一场关于端侧方案与排期的讨论。",
        "key_points": [
            {"point": "端侧内存是主要顾虑", "quote": quote_of(picks[0]),
             "line_id": picks[0]["line_id"]},
            # ↓ 故意坏的:引文不是原文子串,应当被「文本逐字」校验丢弃
            {"point": "这条引文是模型自己编的", "quote": "这句话原文里根本没有出现过",
             "line_id": picks[0]["line_id"]},
        ],
        "commitments": [
            {"what": "下周三之前出第一版方案", "quote": quote_of(picks[1]),
             "line_id": picks[1]["line_id"]},
            # ↓ 故意坏的:行号不存在,应当被「行号命中」校验丢弃
            {"what": "挂在一个不存在的行上", "quote": "随便什么",
             "line_id": 10_000_000},
        ],
        "stances": [
            {"stance": "同意判断但要求延后排期", "quote": quote_of(picks[2]),
             "line_id": picks[2]["line_id"]},
        ],
        "pendings": [
            {"issue": "实测数字未出,结论待定", "quote": quote_of(picks[3]),
             "line_id": picks[3]["line_id"]},
        ],
        "topic_keys": [
            {"key": "端侧方案", "line_ids": [l["line_id"] for l in picks[:2]]},
        ],
    }

    # ↓ 故意坏的:引用占位行(A6:占位行不可被引用为证据),应当被丢弃
    if gaps:
        payload["pendings"].append(
            {"issue": "引到了缺块占位行", "quote": gaps[0]["text"][:6],
             "line_id": gaps[0]["line_id"]})

    return payload


def _empty() -> dict:
    return {"one_liner": "", "key_points": [], "commitments": [],
            "stances": [], "pendings": [], "topic_keys": []}


#: 假上游刻意掺进去的坏条目数(不含占位行那条 —— 有没有缺块由链路决定)。
#: 编排器拿它对账:实际丢弃数少于这个数,说明三项校验里有一项没生效。
DELIBERATE_BAD_ITEMS = 2

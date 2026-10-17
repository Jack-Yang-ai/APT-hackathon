"""时间轴对齐：把 ASR 转写行归属到 diarization 的说话人段。

diarize.py 须产出 list[SpeakerTurn]（start_ms/end_ms/speaker）。本模块按「时间重叠最多」
把每行 Line 归到某说话人；重叠占比过低标低置信（speaker 后缀 '?'）。逻辑自包含、可离线测。

（并入 growth-agent：从 meeting-notes/pipeline/align.py 平移，import 改 ingest.meeting.*。）
"""
from __future__ import annotations

from dataclasses import dataclass

from .transcript import Line

LOW_CONF_RATIO = 0.5  # 行时长里被选中说话人覆盖的比例 < 此值 → 低置信


@dataclass
class SpeakerTurn:
    start_ms: int
    end_ms: int
    speaker: str  # 例如 "说话人1"


def _overlap(a0: int, a1: int, b0: int, b1: int) -> int:
    return max(0, min(a1, b1) - max(a0, b0))


def speaker_of(start_ms: int, end_ms: int,
               turns: list[tuple[int, int, str]]) -> tuple[str, float] | None:
    """一段时间归给哪个说话人:**时间重叠最多**的那个。返回 (说话人, 重叠占比)。

    🔴 **归行这条规则的唯一出处**(M2-认6)。`assign_speakers` 与 SSE 兜底那条腿
    都从这里取 —— 抄两份的话,两条腿会在「重叠多少算数」上悄悄分叉。

    重叠为 0 时返回 **None**:「不知道这段是谁说的」与「是某个人」是两件事,
    别硬塞一个最近的(同 `SpeakerNaming.keyExpr` 那条注释)。
    """
    dur = max(1, end_ms - start_ms)
    best_spk, best_ov = None, 0
    for t0, t1, spk in turns:
        ov = _overlap(start_ms, end_ms, t0, t1)
        if ov > best_ov:
            best_ov, best_spk = ov, spk
    return None if best_spk is None else (best_spk, best_ov / dur)


def assign_speakers(lines: list[Line], turns: list[SpeakerTurn]) -> list[Line]:
    if not turns:
        return lines
    tuples = [(t.start_ms, t.end_ms, t.speaker) for t in turns]
    for line in lines:
        if line.start_ms is None or line.end_ms is None:
            continue
        hit = speaker_of(line.start_ms, line.end_ms, tuples)
        if hit is not None:
            spk, ratio = hit
            line.speaker = spk if ratio >= LOW_CONF_RATIO else f"{spk}?"
    return lines

"""把 ASR 结果（+ 可选的 diarization 说话人段）写成可读的 transcript.md（extract 的输入）。

输出格式（每行一句）：
  说话人N | 真名待定: [mm:ss] 文本
没有 diarization 时 speaker=None，标「未分人」。

（并入 growth-agent：从 meeting-notes/pipeline/transcript.py 平移，仅把 import 改为
 ingest.meeting.*；逻辑自包含、无重依赖，已离线测。）
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from .asr_stepfun import Segment

_SENT_END = re.compile(r"[。！？!?\n]")
_MAX_LINE_CHARS = 60


@dataclass
class Line:
    text: str
    start_ms: int | None
    end_ms: int | None
    speaker: str | None = None  # 例如 "说话人1"；None 表示未分人


def _ms_to_mmss(ms: int | None) -> str:
    if ms is None:
        return "--:--"
    s = ms // 1000
    return f"{s // 60:02d}:{s % 60:02d}"


def group_segments_into_lines(segments: list[Segment]) -> list[Line]:
    """字级 segment 合并成可读的句子行，按句末标点或长度断句，保留首尾时间戳。"""
    lines: list[Line] = []
    buf: list[Segment] = []

    def flush() -> None:
        if not buf:
            return
        text = "".join(s.text for s in buf).strip()
        if text:
            starts = [s.start_ms for s in buf if s.start_ms is not None]
            ends = [s.end_ms for s in buf if s.end_ms is not None]
            lines.append(Line(
                text=text,
                start_ms=min(starts) if starts else None,
                end_ms=max(ends) if ends else None,
            ))
        buf.clear()

    for seg in segments:
        buf.append(seg)
        joined = "".join(s.text for s in buf)
        if _SENT_END.search(seg.text) or len(joined) >= _MAX_LINE_CHARS:
            flush()
    flush()
    return lines


def render_transcript(lines: list[Line], *, topic: str, date: str,
                      source_audio: str, full_text: str,
                      speaker_guesses: dict | None = None,
                      auto_confirmed: dict | None = None) -> str:
    has_speaker = any(l.speaker for l in lines)
    out: list[str] = [
        f"# 会议转写 · {topic}",
        "",
        f"- 日期: {date}",
        f"- 音频源: {source_audio}",
        f"- 分说话人: {'是' if has_speaker else '否（未接 diarization / 待 extract 凭内容分）'}",
        "",
        "> 这是 extract 抽取的输入文件。读它做：说话人→真名映射、抽每人观点+分歧点+todo。",
        "",
    ]
    if speaker_guesses:
        out.append("> **声纹推测**（底库匹配；标 ✓ 的已过核心集严闸自动落定，其余仅供确认门参考）：")
        for spk in sorted(speaker_guesses):
            name, score = speaker_guesses[spk]
            mark = " ✓已落定" if auto_confirmed and spk in auto_confirmed else ""
            out.append(f"> - {spk} ≈ **{name}**（相似度 {score:.2f}）{mark}")
        out.append("")
    out += ["## 逐句转写", ""]
    for l in lines:
        spk = l.speaker if l.speaker else "未分人"
        out.append(f"- **{spk}** [{_ms_to_mmss(l.start_ms)}] {l.text}")
    out += ["", "## 全文（核对底本）", "", full_text, ""]
    return "\n".join(out)

"""离线测：align（说话人归属）+ transcript（断句/渲染）——无重依赖，可裸跑。

从 meeting-notes 移植的离线测精神（上游 align/transcript 已离线测）。
跑：python3 -m ingest.meeting.test_align_transcript   （或 pytest 自动发现）
"""
from __future__ import annotations

from .align import SpeakerTurn, assign_speakers
from .asr_stepfun import Segment
from .transcript import Line, group_segments_into_lines, render_transcript


def test_group_segments_breaks_on_punct():
    segs = [Segment("你好", 0, 500), Segment("。", 500, 700),
            Segment("再见", 800, 1200), Segment("！", 1200, 1300)]
    lines = group_segments_into_lines(segs)
    assert len(lines) == 2, lines
    assert lines[0].text == "你好。" and lines[0].start_ms == 0 and lines[0].end_ms == 700
    assert lines[1].text == "再见！"


def test_assign_speakers_by_overlap():
    lines = [Line("甲说的话", 0, 1000), Line("乙说的话", 2000, 3000)]
    turns = [SpeakerTurn(0, 1500, "说话人1"), SpeakerTurn(1500, 3500, "说话人2")]
    out = assign_speakers(lines, turns)
    assert out[0].speaker == "说话人1"
    assert out[1].speaker == "说话人2"


def test_assign_low_confidence_suffix():
    # 行 0..1000，两个 turn 各覆盖一半 → 最佳重叠 500/1000 = 0.5 == LOW_CONF_RATIO（不低置信）
    lines = [Line("边界句", 0, 1000)]
    turns = [SpeakerTurn(0, 400, "说话人1"), SpeakerTurn(400, 2000, "说话人2")]
    out = assign_speakers(lines, turns)
    # 说话人2 覆盖 600/1000=0.6 ≥ 0.5 → 不带 '?'
    assert out[0].speaker == "说话人2"


def test_render_transcript_unassigned_and_frontmatterless():
    lines = [Line("一句话", 0, 1000)]
    md = render_transcript(lines, topic="周会", date="2026-06-25",
                           source_audio="a.m4a", full_text="一句话")
    assert "# 会议转写 · 周会" in md
    assert "未分人" in md           # 没 diarization → 标未分人
    assert "## 全文（核对底本）" in md


def test_render_transcript_with_guesses():
    lines = [Line("一句话", 0, 1000, speaker="说话人1")]
    md = render_transcript(lines, topic="周会", date="2026-06-25",
                           source_audio="a.m4a", full_text="一句话",
                           speaker_guesses={"说话人1": ("Steven", 0.71)})
    assert "声纹推测" in md and "Steven" in md and "0.71" in md


def _run_all():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"PASS {fn.__name__}")
    print(f"all passed ({len(fns)})")


if __name__ == "__main__":
    _run_all()

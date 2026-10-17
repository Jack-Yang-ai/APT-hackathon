"""Generic implementation; local private materials are not distributed."""




















from __future__ import annotations

from pathlib import Path
from typing import Optional, Union

import numpy as np

# ── 门1：带宽门 ────────────────────────────────────────────────────────────
HF_CUTOFF_HZ = 3400.0   # 高频判定分界：>此频率的能量占比
HF_RATIO_MIN = 0.003    # 低于此值 → 判「带限/TTS-like」拒绝
                        # 实测：车载TTS=0.0002；真人两夜=0.006~0.013；PA=0.007~0.011（真人录制，非TTS，过带宽门）


def _load_mono(audio: Union[str, Path, np.ndarray], sr: Optional[int]) -> tuple[np.ndarray, int]:
    """wav 路径或已读好的数组 → (mono float32, sr)。纯 soundfile/numpy，无重依赖。"""
    if isinstance(audio, (str, Path)):
        import soundfile as sf  # noqa: PLC0415
        data, file_sr = sf.read(str(audio), dtype="float32", always_2d=False)
        if data.ndim > 1:
            data = data.mean(axis=1)
        return data.astype(np.float32), int(file_sr)
    arr = np.asarray(audio, dtype=np.float32)
    if arr.ndim > 1:
        arr = arr.mean(axis=1)
    if sr is None:
        raise ValueError("传 np.ndarray 时必须显式给 sr")
    return arr, int(sr)


def _bandwidth_gate(data: np.ndarray, sr: int) -> dict:
    """>3.4kHz 高频能量占比。纯 numpy rfft，无重依赖，任何采样率都能算。"""
    n = len(data)
    if n < 32:
        return {"hf_ratio": None, "passed": False, "note": "音频过短，带宽门无法判定（判不过）"}
    win = np.hanning(n)
    spec = np.abs(np.fft.rfft(data * win)) ** 2
    freqs = np.fft.rfftfreq(n, d=1.0 / sr)
    total = float(spec.sum())
    if total <= 1e-12:
        return {"hf_ratio": None, "passed": False, "note": "静音/能量≈0，带宽门无法判定（判不过）"}
    hf = float(spec[freqs > HF_CUTOFF_HZ].sum())
    ratio = hf / total
    return {"hf_ratio": ratio, "passed": ratio >= HF_RATIO_MIN}


# ── 门2a：SED（声学，媒体/音乐段） ─────────────────────────────────────────

def _sed_gate(wav_path: Optional[Union[str, Path]]) -> dict:
    """复用 ingest.meeting.sed_gate.scan：判该片段是否落在「纯媒体」声学特征里。
    需要真实音频文件（内部会 ffmpeg 转码）；传数组或环境不可用 → skipped。
    只挡音乐/电视类背景音，挡不住干净人声播报（那是 SED 的设计边界，非 bug）。"""
    if wav_path is None:
        return {"skipped": True, "reason": "SED门：未提供音频文件路径（传数组时无法转码），跳过"}
    try:
        from . import sed_gate as _sed  # noqa: PLC0415
        info = _sed._scan_anywhere(str(wav_path))
    except Exception as e:  # noqa: BLE001 — fail-open：SED 环境/模型不可用不挡管线
        return {"skipped": True, "reason": f"SED门不可用，跳过（{type(e).__name__}: {e}）"}
    media_sec = float(info.get("media_sec") or 0.0)
    return {"skipped": False, "passed": media_sec <= 0.0, "media_sec": media_sec,
            "total_sec": info.get("total_sec")}


# ── 门2b：broadcast_gate（文本层，报站/导航/广告话术） ─────────────────────

def _broadcast_text_gate(text: Optional[str]) -> dict:
    """复用 ingest.meeting.broadcast_gate 的词法快路（enroll 场景通常没有整段转写喂 LLM 判簇，
    只做确定性的强特征正则）。没有转写文本 → skipped。"""
    if not text:
        return {"skipped": True, "reason": "广播文本门：未提供转写文本，跳过（词法/LLM 判定需要文本）"}
    try:
        from . import broadcast_gate as _bg  # noqa: PLC0415
        hit = _bg.lexical_is_broadcast(text)
    except Exception as e:  # noqa: BLE001
        return {"skipped": True, "reason": f"广播文本门不可用，跳过（{type(e).__name__}: {e}）"}
    return {"skipped": False, "passed": not hit, "lexical_hit": hit}


# ── 门3：重叠门（复用 memory.overlap_strip 的预计算区间） ──────────────────

def _overlap_gate(overlap_regions: Optional[list], seg_range: Optional[tuple]) -> dict:
    """区间相交判定：候选段 [seg_start, seg_end] 是否落在已知重叠段里。
    重叠区间来自 memory.overlap_strip.compute_overlaps() 的产出（data/overlaps/<mid>.json 的
    "overlaps" 字段），由调用方传入——单条候选片段没必要重新跑一次 pyannote 全量 diarization。
    未传 → skipped。"""
    if overlap_regions is None or seg_range is None:
        return {"skipped": True,
                "reason": "重叠门：未提供 overlap_regions/seg_range（memory.overlap_strip 预计算区间），跳过"}
    s0, s1 = seg_range
    overlap_sec = 0.0
    for a, b in overlap_regions:
        lo, hi = max(a, s0), min(b, s1)
        if hi > lo:
            overlap_sec += hi - lo
    seg_dur = max(s1 - s0, 1e-9)
    ratio = overlap_sec / seg_dur
    return {"skipped": False, "passed": overlap_sec <= 0.0, "overlap_sec": round(overlap_sec, 3),
            "overlap_ratio": round(ratio, 4)}


def check_enroll_gates(
    wav_path_or_array: Union[str, Path, np.ndarray],
    sr: int = 16000,
    *,
    text: Optional[str] = None,
    overlap_regions: Optional[list] = None,
    seg_range: Optional[tuple] = None,
    enable_bandwidth: bool = True,
    enable_sed: bool = True,
    enable_broadcast_text: bool = True,
    enable_overlap: bool = True,
) -> dict:
    """三道门按序判定，返回 {passed, reasons, metrics}。

    passed = 所有「启用且未 skip」的门都过；reasons 累加所有拒绝/跳过说明（不短路，一次看全貌）；
    metrics 收各门原始数值（hf_ratio / media_sec / lexical_hit / overlap_ratio…），日后标定用。

    - wav_path_or_array: wav 路径（推荐，能跑全部三门）或已读好的 mono 数组（此时 SED 门必 skip）。
    - text: 该段的转写文本（有才能跑门2b 广播文本门）。
    - overlap_regions/seg_range: 该录音预计算的重叠区间 + 候选段在原录音里的 (start,end) 秒，
      来自 memory.overlap_strip 的产出（有才能跑门3）。
    """
    reasons: list[str] = []
    metrics: dict = {}
    passed = True

    wav_path = wav_path_or_array if isinstance(wav_path_or_array, (str, Path)) else None
    data, resolved_sr = _load_mono(wav_path_or_array, sr)

    # 门1：带宽门
    if enable_bandwidth:
        bw = _bandwidth_gate(data, resolved_sr)
        metrics["hf_ratio"] = bw.get("hf_ratio")
        if not bw["passed"]:
            passed = False
            reasons.append(bw.get("note") or "bandlimited/TTS-like（高频能量占比过低，疑似合成/带限播报音源）")
    else:
        metrics["hf_ratio"] = None

    # 门2a：SED 声学广播门
    if enable_sed:
        sed = _sed_gate(wav_path)
        metrics["sed_media_sec"] = sed.get("media_sec")
        if sed.get("skipped"):
            reasons.append(sed["reason"])
        elif not sed["passed"]:
            passed = False
            reasons.append(f"SED判定为纯媒体/音乐段（media_sec={sed['media_sec']:.1f}s），拒绝入库")
    else:
        metrics["sed_media_sec"] = None

    # 门2b：文本层广播门
    if enable_broadcast_text:
        bg = _broadcast_text_gate(text)
        metrics["broadcast_lexical_hit"] = bg.get("lexical_hit")
        if bg.get("skipped"):
            reasons.append(bg["reason"])
        elif not bg["passed"]:
            passed = False
            reasons.append("转写文本命中报站/导航/广告话术词法特征，拒绝入库")
    else:
        metrics["broadcast_lexical_hit"] = None

    # 门3：重叠门
    if enable_overlap:
        ov = _overlap_gate(overlap_regions, seg_range)
        metrics["overlap_ratio"] = ov.get("overlap_ratio")
        if ov.get("skipped"):
            reasons.append(ov["reason"])
        elif not ov["passed"]:
            passed = False
            reasons.append(f"该段落在重叠语音区间内（overlap_ratio={ov['overlap_ratio']:.0%}），"
                            "混合向量不可靠，拒绝入库")
    else:
        metrics["overlap_ratio"] = None

    return {"passed": passed, "reasons": reasons, "metrics": metrics}

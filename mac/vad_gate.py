#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""















from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

VAD_SR = 16000
MIN_SPEECH_SEC = float(os.environ.get("GROWTH_VAD_MIN_SPEECH_SEC", "10"))
MERGE_GAP = float(os.environ.get("GROWTH_VAD_MERGE_GAP_SEC", "30"))  # 段间静音≤此秒数并成一块（对话内停顿不切）
PAD = float(os.environ.get("GROWTH_VAD_PAD_SEC", "30"))              # 每块两端保护垫
THRESHOLD = float(os.environ.get("GROWTH_VAD_THRESHOLD", "0.35"))    # Silero 帧概率及格线

_VENV_PY = os.environ.get("GROWTH_SV_PYTHON") or str(
    Path.home() / "Desktop" / "录音文件" / "_pipeline" / ".venv" / "bin" / "python")



def scan(audio_path: str) -> dict:
    """任意格式音频 → 人声时长统计。必须在有 silero_vad(torch) 的解释器里跑。"""
    import soundfile as sf
    from silero_vad import get_speech_timestamps, load_silero_vad

    with tempfile.TemporaryDirectory() as td:
        wav16 = str(Path(td) / "vad_16k.wav")
        r = subprocess.run(["ffmpeg", "-v", "error", "-i", audio_path,
                            "-ac", "1", "-ar", str(VAD_SR), "-y", wav16],
                           capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(f"ffmpeg: {r.stderr.decode()[:200]}")
        audio, _sr = sf.read(wav16, dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)

    import torch
    model = load_silero_vad()
    ts = get_speech_timestamps(torch.from_numpy(audio), model,
                               sampling_rate=VAD_SR, return_seconds=True,
                               threshold=THRESHOLD)
    speech = sum(t["end"] - t["start"] for t in ts)
    total = len(audio) / VAD_SR

    regions: list[list[float]] = []
    for t in ts:
        a, b = max(0.0, t["start"] - PAD), min(total, t["end"] + PAD)
        if regions and a - regions[-1][1] <= MERGE_GAP:
            regions[-1][1] = max(regions[-1][1], b)
        else:
            regions.append([a, b])
    regions = [[round(a, 2), round(b, 2)] for a, b in regions]

    return {"speech_sec": round(speech, 1),
            "total_sec": round(total, 1),
            "speech_ratio": round(speech / total, 3) if total else 0.0,
            "n_segments": len(ts),
            "speech_regions": regions,
            "regions_sec": round(sum(b - a for a, b in regions), 1)}



def _scan_anywhere(audio_path: str) -> dict:
    try:
        import silero_vad  # noqa: F401 — 本解释器有货就直接跑
        return scan(audio_path)
    except ImportError:
        pass
    if not Path(_VENV_PY).exists():
        raise RuntimeError(f".venv python 不在（{_VENV_PY}）")
    root = Path(__file__).resolve().parents[1]
    env = {**os.environ, "PYTHONPATH": str(root), "HF_HUB_OFFLINE": "1"}
    r = subprocess.run([_VENV_PY, "-m", "mac.vad_gate",
                        "--audio", audio_path, "--json-only"],
                       capture_output=True, text=True, timeout=1800, env=env, cwd=str(root))
    if r.returncode != 0:
        raise RuntimeError(f"vad 子进程失败: {(r.stderr or '')[-300:]}")
    return json.loads(r.stdout.strip().splitlines()[-1])


def check(audio_path: str, min_speech_sec: float | None = None) -> dict:
    """编排入口：扫描 + 判定。返回 scan 结果 + has_speech。失败请在调用侧兜（fail-open）。"""
    thr = MIN_SPEECH_SEC if min_speech_sec is None else min_speech_sec
    info = _scan_anywhere(audio_path)
    info["min_speech_sec"] = thr
    info["has_speech"] = info["speech_sec"] >= thr
    return info


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Silero VAD 人声扫描")
    ap.add_argument("--audio", required=True)
    ap.add_argument("--json-only", action="store_true", help="stdout 只打一行 JSON（供父进程解析）")
    a = ap.parse_args()
    out = scan(a.audio)
    if a.json_only:
        print(json.dumps(out, ensure_ascii=False))
    else:
        print(json.dumps(out, ensure_ascii=False, indent=1))

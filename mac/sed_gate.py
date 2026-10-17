#!/usr/bin/env python3
"""SED 分桶门：音乐/媒体段的转写行不入库（1201段歌词教训 → 管线规格）。

原理：PANNs CNN14（与 _pipeline/sed_scan.py 同款模型，~/panns_data 检查点）逐秒出
527 类概率，取媒体类（Music/Singing/Television…）与语音类各自的最大值：
  媒体秒 = media_p ≥ 0.50 且 speech_p < 0.35   ← 人声盖过背景音乐的对话不剔（只杀纯媒体段）
  相邻媒体秒 gap ≤3s 合并，短于 8s 的段丢弃（背景音乐一闪而过不算）
落 transcript 前把中点落在媒体段内的行剔掉；区间存 <mid>.sed.json 供 scene_fill 复用。

进程模型与声纹同款：torch/panns 在 _pipeline/.venv（3.11）——本地能 import 就直接跑，
否则 subprocess 到 venv 跑本模块 CLI（stdout 一行 JSON）。任何失败 → 不剔除（fail-open）。

CLI（venv 内自测/被 3.9 侧调用）：
  <.venv-python> -m mac.sed_gate --audio X.mp3 [--json-only]
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

MEDIA_LABELS = ["Music", "Background music", "Singing", "Television",
                "Musical instrument", "Theme music"]
SPEECH_LABELS = ["Speech", "Conversation", "Narration, monologue",
                 "Male speech, man speaking", "Female speech, woman speaking",
                 "Child speech, kid speaking"]
MEDIA_P = 0.50      # 媒体概率阈
SPEECH_MAX = 0.35   # 语音概率低于此才算"纯媒体"（对话+背景乐 → 保留）
MERGE_GAP = 5       # 秒；相邻媒体秒合并间隙（歌内安静小节/循环接缝要桥过去）
MIN_DUR = 8         # 秒；短于此的媒体段忽略
SED_SR = 32000
CHUNK_SEC = 30
CKPT = os.path.expanduser("~/panns_data/Cnn14_DecisionLevelMax.pth")

_VENV_PY = os.environ.get("GROWTH_SV_PYTHON") or str(
    Path.home() / "Desktop" / "录音文件" / "_pipeline" / ".venv" / "bin" / "python")


# ---------------------------------------------------------------- venv 侧：真推理

def scan(audio_path: str) -> dict:
    """任意格式音频 → 媒体段区间。必须在有 torch/panns 的解释器里跑。"""
    import numpy as np
    import soundfile as sf
    import torch
    import torchaudio
    from panns_inference import SoundEventDetection, labels as ALL

    with tempfile.TemporaryDirectory() as td:
        wav32 = str(Path(td) / "sed_32k.wav")
        r = subprocess.run(["ffmpeg", "-v", "error", "-i", audio_path,
                            "-ac", "1", "-ar", str(SED_SR), "-y", wav32],
                           capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(f"ffmpeg: {r.stderr.decode()[:200]}")
        audio, sr = sf.read(wav32, dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)

    sed = SoundEventDetection(checkpoint_path=CKPT)
    if torch.backends.mps.is_available():
        try:
            sed.model.to("mps")
            sed.device = "mps"
        except Exception:  # noqa: BLE001
            sed.device = "cpu"
    m_idx = [ALL.index(l) for l in MEDIA_LABELS if l in ALL]
    s_idx = [ALL.index(l) for l in SPEECH_LABELS if l in ALL]

    media_p, speech_p = {}, {}   # sec -> max prob
    total = len(audio) / SED_SR
    for c0 in range(0, int(total) + 1, CHUNK_SEC):
        seg = audio[int(c0 * SED_SR): int((c0 + CHUNK_SEC) * SED_SR)]
        if len(seg) < SED_SR:  # 尾巴不足 1s
            continue
        fw = sed.inference(seg[None, :])[0]          # (T, 527)
        frame_dur = (len(seg) / SED_SR) / fw.shape[0]
        for fi in range(fw.shape[0]):
            sec = int(c0 + fi * frame_dur)
            mp = float(max(fw[fi][i] for i in m_idx))
            sp = float(max(fw[fi][i] for i in s_idx))
            media_p[sec] = max(media_p.get(sec, 0.0), mp)
            speech_p[sec] = max(speech_p.get(sec, 0.0), sp)

    hot = sorted(s for s in media_p
                 if media_p[s] >= MEDIA_P and speech_p.get(s, 0.0) < SPEECH_MAX)
    regions, cur = [], None
    for s in hot:
        if cur and s - cur[1] <= MERGE_GAP:
            cur[1] = s
        else:
            if cur:
                regions.append(cur)
            cur = [s, s]
    if cur:
        regions.append(cur)
    regions = [[a, b + 1] for a, b in regions if (b + 1 - a) >= MIN_DUR]
    return {"media_regions": regions,
            "media_sec": sum(b - a for a, b in regions),
            "total_sec": round(total, 1)}


# ---------------------------------------------------------------- 3.9 侧：编排入口

def _scan_anywhere(audio_path: str) -> dict:
    try:
        import panns_inference  # noqa: F401 — 本解释器有货就直接跑
        return scan(audio_path)
    except ImportError:
        pass
    if not Path(_VENV_PY).exists():
        raise RuntimeError(f".venv python 不在（{_VENV_PY}）")
    # 搬运遗留:这两行原本指着旧仓的布局(root=parents[2]、模块名 ingest.meeting.sed_gate)。
    # 在本仓 parents[2] 算出来是 ~/,那下面没有 ingest/,子进程必然找不到模块 ——
    # 也就是说**媒体段闸在本仓从来没能跑起来过**。与 vad_gate 当初同一个病(c2135ee),
    # 同一个改法。2026-08-10 做 U5a 时发现。
    root = Path(__file__).resolve().parents[1]
    env = {**os.environ, "PYTHONPATH": str(root), "HF_HUB_OFFLINE": "1"}
    r = subprocess.run([_VENV_PY, "-m", "mac.sed_gate",
                        "--audio", audio_path, "--json-only"],
                       capture_output=True, text=True, timeout=1800, env=env, cwd=str(root))
    if r.returncode != 0:
        raise RuntimeError(f"sed 子进程失败: {(r.stderr or '')[-300:]}")
    return json.loads(r.stdout.strip().splitlines()[-1])


def filter_lines(lines: list, regions: list) -> tuple[list, list]:
    """行中点落在媒体段内 → 剔除。返回 (保留行, 剔除行)。无 ts 的行一律保留。"""
    if not regions:
        return lines, []
    keep, drop = [], []
    for l in lines:
        s, e = getattr(l, "start_ms", None), getattr(l, "end_ms", None)
        if s is None:
            keep.append(l)
            continue
        mid = (s + (e if e is not None else s)) / 2000.0
        (drop if any(a <= mid < b for a, b in regions) else keep).append(l)
    return keep, drop


def apply(audio_path: str, lines: list, out_json: Path | None = None) -> tuple[list, dict]:
    """编排入口：扫描 + 过滤 + 落区间 JSON。失败请在调用侧兜（fail-open）。"""
    info = _scan_anywhere(audio_path)
    kept, dropped = filter_lines(lines, info["media_regions"])
    info["dropped_lines"] = len(dropped)
    info["dropped_preview"] = [
        {"ts": round((l.start_ms or 0) / 1000), "text": l.text[:40]} for l in dropped[:10]]
    if out_json:
        out_json.parent.mkdir(parents=True, exist_ok=True)
        out_json.write_text(json.dumps(info, ensure_ascii=False, indent=1), encoding="utf-8")
    return kept, info


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="SED 媒体段扫描")
    ap.add_argument("--audio", required=True)
    ap.add_argument("--json-only", action="store_true", help="stdout 只打一行 JSON（供父进程解析）")
    a = ap.parse_args()
    out = scan(a.audio)
    if a.json_only:
        print(json.dumps(out, ensure_ascii=False))
    else:
        print(json.dumps(out, ensure_ascii=False, indent=1))

"""声纹嵌入 v2：pyannote speaker-diarization-community-1 的 embedding 子模型（256d）。

并入 growth-agent 声纹迁移 P0.1（见 docs/voiceprint-migration-checklist.md）。
与 speaker_id.py 的 CAM++ 192d 空间**不兼容**、**不互换**——两套向量不能混着算 cos。
本模块只产 256d v2 向量，落盘/入库一律走 `_v2` 路径，不碰旧 registry.json / data/line_embs/。

设计要点：
- 惰性 import：torch / pyannote.audio / soundfile / numpy 全部在函数内导入。
  `import ingest.meeting.embed_v2` 本身不装它们、不触发模型加载（风格参照 speaker_id.py 顶部纪律）。
- 模型只加载一次（模块级缓存），尝试 MPS，失败静默回退 CPU。
- **时长门**：输入 <1.5s 直接 raise ValueError——短句声纹不可靠，宁可上游处理失败也不要产假向量。
- **revision pin**：HF 缓存目录名本身就是 snapshot commit hash；模型一更新，hash 变、分数空间漂移，
  旧阈值全部作废。加载时把这个 hash 记到 MODEL_REV，并落一份 model_rev.json 存档，
  这样任何 v2 产物都能追溯"是哪个模型算的"。
"""
from __future__ import annotations

import datetime as _dt
import glob
import json
import os
from pathlib import Path
from typing import Optional, Union

import numpy as np

from shared import paths as config

MIN_DUR_SEC = 1.5   # 时长门：<1.5s 直接拒绝，不产假声纹
EMB_DIM = 256
TARGET_SR = 16000

# 🔴 **和 registry 同一个目录,而且是 `.gitignore` 覆盖的那个。**
#
# ~~`config.ROOT / "ingest" / "meeting" / "voiceprints_v2"`~~ **2026-08-18 改**,两处错:
# ① 那是**旧仓的目录布局**(旧仓里 `mac/` 就叫 `ingest/meeting/`)。搬过来之后
#    `ROOT` 指向新仓根,于是它在仓库根下造了一个 `.gitignore` 没覆盖的目录 ——
#    实测:`ingest/meeting/voiceprints_v2/model_rev.json` 从 2026-08-10 起
#    一直挂在 `git status` 的未跟踪里。而隔壁 `.gitignore` 那行写着
#    「声纹底库(生物特征隐私,**绝不进库**)」。
# ② 它和 `registry_v2.REGISTRY_V2_PATH`(`mac/voiceprints_v2/registry.json`)
#    **不在同一个目录** —— 而 model_rev 存在的全部意义是「这份底库是哪个模型算的」。
#    两者分居两地时,你可以有一份 A 模型的底库配一份 B 模型的 model_rev,
#    **而没有任何东西会发现**,旧阈值照用。
#
# 所以直接从 registry 的位置推,不另写一份路径。
# ⚠️ **两个常量 2026-08-26 挪去了 `mac/registry_v2`**,这里只是转出去 ——
# 它们原来定义在这个模块里,而这个模块顶层 `import numpy`,于是
# `shared/test_voiceprint_paths`(只想读两个路径)被迫拖进 numpy ⇒ CI 上全挂。
# 常量该跟着**它的基**走,不跟着**用它的人**走。
from mac.registry_v2 import (REGISTRY_V2_PATH as _REGISTRY_V2_PATH,   # noqa: F401
                             VOICEPRINTS_V2_DIR, MODEL_REV_PATH)

_HF_CACHE_GLOB = os.path.expanduser(
    "~/.cache/huggingface/hub/models--pyannote--speaker-diarization-community-1/snapshots/*"
)

_model = None
_inf = None
_device_desc = None

# 模块级：加载时解析出来的 snapshot revision hash（惰性——import 本模块不触发）。
# 真正加载模型前是 None；调用 embed_v2()/_ensure_model() 之后才会被填上。
MODEL_REV: Optional[str] = None
MODEL_BIN_PATH: Optional[str] = None


def _resolve_snapshot() -> str:
    """解析出 HF 缓存里的 community-1 snapshot 目录（目录名=revision hash）。"""
    hits = sorted(glob.glob(_HF_CACHE_GLOB))
    if not hits:
        raise RuntimeError(
            "找不到 pyannote/speaker-diarization-community-1 的本地缓存快照——"
            f"检查 {_HF_CACHE_GLOB} 是否存在（先跑一次带网络的加载，或确认缓存路径）。"
        )
    # 正常只应有一个 snapshot；若有多个，取最新修改时间的那个，且明确提示。
    if len(hits) > 1:
        hits = sorted(hits, key=lambda p: os.path.getmtime(p), reverse=True)
    return hits[0]


def _write_model_rev_manifest(rev: str, bin_path: str) -> None:
    VOICEPRINTS_V2_DIR.mkdir(parents=True, exist_ok=True)
    manifest = {
        "rev": rev,
        "model": "pyannote/speaker-diarization-community-1 (embedding sub-model)",
        "model_bin_path": bin_path,
        "dim": EMB_DIM,
        "created": _dt.datetime.now().isoformat(timespec="seconds"),
    }
    # 只在内容变化或文件不存在时才写，避免每次 import 都刷 mtime。
    if MODEL_REV_PATH.exists():
        try:
            existing = json.loads(MODEL_REV_PATH.read_text())
            if existing.get("rev") == rev and existing.get("model_bin_path") == bin_path:
                return
        except Exception:
            pass
    MODEL_REV_PATH.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))


def _ensure_model():
    """惰性加载模型（首次调用才 import torch/pyannote），并把 MODEL_REV 填好。"""
    global _model, _inf, _device_desc, MODEL_REV, MODEL_BIN_PATH
    if _inf is not None:
        return _inf

    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    import torch  # noqa: PLC0415
    from pyannote.audio import Model, Inference  # noqa: PLC0415

    snap = _resolve_snapshot()
    bin_path = os.path.join(snap, "embedding", "pytorch_model.bin")
    if not os.path.exists(bin_path):
        raise RuntimeError(f"snapshot 里找不到 embedding 权重：{bin_path}")

    rev = os.path.basename(snap)
    model = Model.from_pretrained(bin_path)
    inf = Inference(model, window="whole")
    try:
        inf.to(torch.device("mps"))
        _device_desc = "mps"
    except Exception:
        _device_desc = "cpu"

    _model, _inf = model, inf
    MODEL_REV, MODEL_BIN_PATH = rev, bin_path
    _write_model_rev_manifest(rev, bin_path)
    return _inf


def _load_wav_16k_mono(wav_path: str):
    """读 wav→float32 mono，非 16k 就重采样到 16k。返回 (np.ndarray[T], sr=16000)。"""
    import soundfile as sf  # noqa: PLC0415

    data, sr = sf.read(wav_path, dtype="float32")
    if data.ndim > 1:
        data = data.mean(axis=1)
    if sr != TARGET_SR:
        import librosa  # noqa: PLC0415
        data = librosa.resample(data, orig_sr=sr, target_sr=TARGET_SR)
        sr = TARGET_SR
    return data, sr


def embed_v2(audio: Union[str, "np.ndarray"], sr: Optional[int] = None) -> np.ndarray:
    """算 256d L2 归一声纹向量。

    audio: wav 文件路径，或已经读好的 mono float32 波形数组（此时必须传 sr）。
    时长门：<1.5s 直接 raise ValueError（不产假声纹）。
    """
    import torch  # noqa: PLC0415

    inf = _ensure_model()

    if isinstance(audio, (str, Path)):
        data, sr = _load_wav_16k_mono(str(audio))
    else:
        if sr is None:
            raise ValueError("传 np.ndarray 时必须显式给 sr")
        data = np.asarray(audio, dtype=np.float32)
        if data.ndim > 1:
            data = data.mean(axis=1)
        if sr != TARGET_SR:
            import librosa  # noqa: PLC0415
            data = librosa.resample(data, orig_sr=sr, target_sr=TARGET_SR)
            sr = TARGET_SR

    dur = len(data) / float(sr)
    if dur < MIN_DUR_SEC:
        raise ValueError(f"输入时长 {dur:.2f}s < {MIN_DUR_SEC}s 时长门，拒绝产声纹（不可靠）")

    wf = torch.from_numpy(data).unsqueeze(0)
    v = inf({"waveform": wf, "sample_rate": sr})
    v = np.asarray(v).reshape(-1).astype(np.float64)
    norm = np.linalg.norm(v)
    if norm < 1e-9:
        raise ValueError("嵌入向量范数≈0，音频可能是静音")
    return (v / norm).astype(np.float32)


def embed_v2_batch(items) -> list:
    """批量算嵌入。items: 可迭代的 wav 路径（或 (audio, sr) 二元组）。

    逐条失败不中断：出错的位置返回 None，并把 (index, path/desc, error) 记进返回的第二项。
    返回 (results, failures)。
    """
    results = []
    failures = []
    for i, item in enumerate(items):
        try:
            if isinstance(item, tuple):
                audio, sr = item
                results.append(embed_v2(audio, sr))
            else:
                results.append(embed_v2(item))
        except Exception as e:  # noqa: BLE001
            results.append(None)
            desc = item if isinstance(item, (str, Path)) else f"item[{i}]"
            failures.append((i, str(desc), f"{type(e).__name__}: {e}"))
    return results, failures

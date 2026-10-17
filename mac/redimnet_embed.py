#!/usr/bin/env python3
"""Mac 侧声纹嵌入器:与手机**同一个空间**的 ReDimNet-S(M2-认8 ①,方案 §3.0)。

    GROWTH_SV_PYTHON(重依赖 venv)运行;验收跑 mac/test_redimnet_embed.py

## 🔴 为什么必须有这个文件,而不能用 venv 里现成的模型

对抗审计(2026-08-24)抓到的全方案最大的洞:venv 里现成的是 CAM++(192d)
与 pyannote(256d),而底库模板是手机 **ReDimNet-S** 提的 ——
**不同模型的向量不在同一空间,余弦照样算得出数、不会报错**,
判决从第一段起全错。这正是本仓 §3.2 说的「成功地写进了错的地方」。

⇒ Mac 必须跑**同一份** ONNX、配**逐步一致**的梅尔前端。

## 模型文件只有一个出处(铁律 4)

直接读 `ios/GrowthApp/Resources/redimnet_s_body_op17.onnx` —— 就是打进 App 包
的那份,不复制。复制一份到 mac/ 的话,「两边跑的是不是同一个模型」就成了
第二处要人守的复述,对不上时什么都不会红。

## 梅尔前端:第三份实现,靠金标钉住

这是前端的第三份实现(PyTorch 原版 → Swift `MelFrontend` → 本文件)。
第三份不是随便加的:PyTorch 原版要 modelscope 在线拉模型,daemon 不能依赖它。
钉住的方式与 Swift 那份完全相同 —— **拿同一份金标逐位对**:
· `ios/GrowthAppTests/Fixtures/mel_golden.json`(前端逐位)
· `ios/GrowthAppTests/Fixtures/embedder_golden.json`(端到端余弦)
Swift 侧 `MelFrontendTests` / `RedimnetBodyTests` 咬的就是这两份 ⇒
**两侧共享同一个「对」的定义**,谁漂了谁的测试红。

五步、十来个常数,任何一个写错都不会报错,只让向量悄悄变质
(窗是 Hamming periodic 不是 Hann;梅尔刻度是 htk 不是 slaney;
CMN 沿时间轴不是频率轴 —— `MelFrontend.swift` 头上那三条,这里同样致命)。
"""
from __future__ import annotations

import os
from pathlib import Path

import numpy as np

# ---- 常数:与 ios/GrowthApp/Voiceprint/MelFrontend.swift 逐项一致 ----
# ⚠️ 这里不是「第二处复述」:两边都被同一份 mel_golden.json 钉着,改错任何一个都红。
SAMPLE_RATE = 16000
N_FFT = 512
HOP = 160
WIN = 400
N_MELS = 72
F_MIN, F_MAX = 20.0, 7600.0
PREEMPHASIS = 0.97
NORMALIZE_EPS = 1e-6
LOG_OFFSET = 1e-6

EMBEDDING_DIM = 192
MODEL_NAME = "redimnet_s_body_op17"
#: 与手机 `VoiceprintModel.current` 对撞用的模型串 —— 判决 JSON 里带它,
#: 手机侧不一致整批拒收(方案 §3.2)。
MODEL_ID = MODEL_NAME

_REPO = Path(__file__).resolve().parents[1]
MODEL_PATH = _REPO / "ios" / "GrowthApp" / "Resources" / f"{MODEL_NAME}.onnx"


# ---------------- 梅尔前端(五步,照 MelFrontend.swift) ----------------

def _normalize(x: np.ndarray) -> np.ndarray:
    """① 音量归一。std 用**有偏**估计(除 N)—— PyTorch 侧 unbiased=False。"""
    mean = float(x.mean())
    std = float(np.sqrt(max(float((x * x).mean()) - mean * mean, 0.0)))
    return (x - mean) / (std + NORMALIZE_EPS)


def _preemphasize(x: np.ndarray) -> np.ndarray:
    """② 预加重,左侧 reflect 填充 1 个样本(x[-1] 取 x[1])。
    用零填充会让第一个样本偏大,那点差别一路传到梅尔谱第一帧。"""
    out = np.empty_like(x)
    out[0] = x[0] - PREEMPHASIS * (x[1] if x.size > 1 else x[0])
    out[1:] = x[1:] - PREEMPHASIS * x[:-1]
    return out


def _hamming_periodic() -> np.ndarray:
    """Hamming(periodic):0.54 − 0.46·cos(2πn/N),**N 不减一**。
    减一是 symmetric,端点差 0.08,足以让金标红。
    长度 WIN 的窗**居中补零到 N_FFT**(两边各 56),与 torch.stft 一致。"""
    n = np.arange(WIN, dtype=np.float64)
    w = 0.54 - 0.46 * np.cos(2 * np.pi * n / WIN)
    out = np.zeros(N_FFT, dtype=np.float64)
    off = (N_FFT - WIN) // 2
    out[off:off + WIN] = w
    return out


_WINDOW = _hamming_periodic()


def _power_spectrogram(x: np.ndarray) -> np.ndarray:
    """③ 功率谱 (bins, frames)。center=True:两端 reflect 填充 N_FFT/2。"""
    pad = N_FFT // 2
    padded = np.pad(x, pad, mode="reflect")
    frames = x.size // HOP + 1                     # torch.stft center=True 的帧数
    idx = np.arange(N_FFT)[None, :] + (np.arange(frames) * HOP)[:, None]
    segs = padded[idx] * _WINDOW[None, :]          # (frames, N_FFT)
    spec = np.fft.rfft(segs, n=N_FFT, axis=1)      # (frames, bins)
    return (spec.real ** 2 + spec.imag ** 2).T     # (bins, frames)


def _filterbank() -> np.ndarray:
    """③ 续:htk 刻度、norm=none 的三角滤波器组 (N_MELS, bins)。
    与 torchaudio `melscale_fbanks(htk, norm=None)` 同式;
    ⚠️ allFreqs 分母是 bins−1(照 MelFrontend.swift,不是 sr/n_fft)。"""
    bins = N_FFT // 2 + 1

    def hz2mel(f):
        return 2595.0 * np.log10(1.0 + f / 700.0)

    def mel2hz(m):
        return 700.0 * (10.0 ** (m / 2595.0) - 1.0)

    all_freqs = np.arange(bins) * (SAMPLE_RATE / 2) / (bins - 1)
    m_pts = np.linspace(hz2mel(F_MIN), hz2mel(F_MAX), N_MELS + 2)
    f_pts = mel2hz(m_pts)
    fb = np.zeros((N_MELS, bins))
    for m in range(N_MELS):
        lo, ctr, hi = f_pts[m], f_pts[m + 1], f_pts[m + 2]
        down = (all_freqs - lo) / (ctr - lo)
        up = (hi - all_freqs) / (hi - ctr)
        fb[m] = np.maximum(0.0, np.minimum(down, up))
    return fb


_FILTERBANK = _filterbank()


def mel_spectrogram(samples: np.ndarray) -> np.ndarray:
    """16 kHz float 单声道 → (N_MELS, frames)。**不做重采样** ——
    采样率不对应当在调用方暴露,悄悄重采样会让「分数为什么变差」查不出来。"""
    if samples.size < WIN:
        raise ValueError(f"音频太短:{samples.size} 个采样,至少要 {WIN}")
    x = samples.astype(np.float64)
    x = _normalize(x)                              # ①
    x = _preemphasize(x)                           # ②
    power = _power_spectrogram(x)                  # ③
    mel = _FILTERBANK @ power                      # ③ 续
    mel = np.log(mel + LOG_OFFSET)                 # ④
    mel -= mel.mean(axis=1, keepdims=True)         # ⑤ 沿时间轴逐通道减均值
    return mel.astype(np.float32)


# ---------------- ONNX 本体 ----------------

class RedimnetEmbedder:
    """梅尔谱进、**L2 归一化后**的 192 维出。与手机 `RedimnetBody` 同约定:
    底库、模板、回流契约存的全是归一化向量 —— 各家自己归一的话,漏一处的
    表现是余弦整体偏小,而不是任何一处报错。"""

    def __init__(self, model_path: Path | None = None):
        import onnxruntime as ort
        path = Path(model_path or os.environ.get("GROWTH_REDIMNET_ONNX") or MODEL_PATH)
        if not path.exists():
            raise FileNotFoundError(
                f"🔴 找不到 {path} —— Mac 必须跑与手机同一份 ONNX,"
                f"不许换 venv 里现成的 CAM++/pyannote 顶上(空间不同,错得不报错)")
        self.session = ort.InferenceSession(str(path),
                                            providers=["CPUExecutionProvider"])

    def embed(self, samples: np.ndarray) -> np.ndarray:
        mel = mel_spectrogram(samples)
        out = self.session.run(["emb"], {"mel": mel[None, :, :]})[0].reshape(-1)
        if out.shape[0] != EMBEDDING_DIM:
            raise RuntimeError(f"emb 维度 {out.shape[0]} ≠ {EMBEDDING_DIM}")
        norm = float(np.linalg.norm(out))
        # 全零 / NaN:模型跑了但结果无意义。放行会退化成「谁都不像」= 假拒识。
        if not np.isfinite(norm) or norm <= 1e-6:
            raise RuntimeError(f"向量模长 {norm} —— 全零或 NaN")
        return (out / norm).astype(np.float32)

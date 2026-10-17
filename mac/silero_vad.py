#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""










from __future__ import annotations

from pathlib import Path

import numpy as np

SPEECH_THRESHOLD = 0.35
FRAME = 512
CONTEXT = 64
SR = 16000

_REPO = Path(__file__).resolve().parents[1]
MODEL_PATH = _REPO / "ios" / "GrowthApp" / "Resources" / "silero_vad_16k_op15.onnx"


class SileroVAD:
    def __init__(self, model_path: Path | None = None):
        import onnxruntime as ort
        p = Path(model_path or MODEL_PATH)
        if not p.exists():
            raise FileNotFoundError(f"🔴 找不到 {p}")
        self.session = ort.InferenceSession(str(p), providers=["CPUExecutionProvider"])
        self.reset()

    def reset(self) -> None:
        self._state = np.zeros((2, 1, 128), dtype=np.float32)
        self._context = np.zeros(CONTEXT, dtype=np.float32)

    def probability(self, frame: np.ndarray) -> float:
        if frame.shape[0] != FRAME:
            raise ValueError(f"一帧要 {FRAME} 个采样,给了 {frame.shape[0]}")
        x = np.concatenate([self._context, frame.astype(np.float32)])[None, :]
        # ⚠️ `sr` 必须是 **0 维 int64 ndarray**,不是 `np.int64(SR)` 标量 ——
        # onnxruntime 不认 numpy 标量,抛的是
        # `Unable to handle object of type <class 'numpy.int64'>`。
        # 那句话里没有「sr」也没有「输入」二字,**离真因隔着好几跳**
        # (2026-08-24 端到端干跑时撞到,traceback 才指到这一行)。
        out, state_n = self.session.run(
            ["output", "stateN"],
            {"input": x, "state": self._state,
             "sr": np.array(SR, dtype=np.int64)})
        if state_n.shape != (2, 1, 128):
            raise RuntimeError(f"stateN 形状 {state_n.shape} 解不出来 —— 不能当成「没人说话」")
        self._state = state_n
        self._context = frame[-CONTEXT:].astype(np.float32)
        return float(np.asarray(out).reshape(-1)[0])

    def speech_ratio(self, samples: np.ndarray) -> float:
        """整段的语音帧占比(SpeechGate 的判据)。帧数为 0 返回 0,不是 1 ——
        「什么都没量到」不能算通过。会自动 reset。"""
        self.reset()
        n = samples.shape[0] // FRAME
        if n == 0:
            return 0.0
        speech = sum(1 for i in range(n)
                     if self.probability(samples[i * FRAME:(i + 1) * FRAME])
                     >= SPEECH_THRESHOLD)
        return speech / n


#: 段内至少这么多帧要是人声(SpeechGate.minSpeechRatio;那边的注释是出处:
#: 起点值,真机分布回填前别当量出来的数)。
MIN_SPEECH_RATIO = 0.6

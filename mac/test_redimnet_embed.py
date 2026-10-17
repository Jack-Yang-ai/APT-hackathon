#!/usr/bin/env python3
"""Mac 侧嵌入器对手机金标的对撞(M2-认8 ① 的达标线,方案 §七-1)。

    ~/Desktop/录音文件/_pipeline/.venv/bin/python mac/test_redimnet_embed.py

## 咬的是**同一份**金标

`ios/GrowthAppTests/Fixtures/{mel_golden,embedder_golden}.json` —— Swift 侧
`MelFrontendTests` / `RedimnetBodyTests` 咬的就是它们。两侧共享同一个「对」
的定义,谁的前端漂了谁红;**不另造一份「Mac 自己的金标」**(那是铁律 4 的形状)。

达标线(方案 §七-1 原文):**同段音频两侧向量余弦 ≥ 0.999**。
金标向量由 PyTorch 原版产出 ⇒ 「Mac vs 金标」过线 + 「Swift vs 金标」过线
⇒ Mac vs Swift 传递成立。

⚠️ 只断言「出得来 192 个数」是不够的 —— 数错了同样出得来 192 个,哪里都不报错
(embedder_golden 的 _spec 里就写着这句)。必须比数值。
"""
from __future__ import annotations

import base64
import json
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
from mac.redimnet_embed import (EMBEDDING_DIM, MODEL_ID,          # noqa: E402
                                RedimnetEmbedder, mel_spectrogram)

FIX = REPO / "ios" / "GrowthAppTests" / "Fixtures"

#: 前端逐位容差。Swift 用 float32 vDSP、这里 float64 numpy,不可能逐字节;
#: 金标值域约 ±4(mel_stats),1e-3 已足以抓住任何一个常数写错
#: (换 Hann / slaney / 轴向错,差都在 1e-1 量级以上)。
MEL_TOL = 1e-3
#: 端到端余弦达标线 —— 方案 §七-1 写死的数,不许在这里放宽。
COS_FLOOR = 0.999


def f32(b64: str) -> np.ndarray:
    return np.frombuffer(base64.b64decode(b64), dtype="<f4")


def main() -> int:
    bad = []

    # ① 前端:mel_golden 逐位
    g = json.loads((FIX / "mel_golden.json").read_text())
    wav = f32(g["wav_b64"])
    want = f32(g["mel_b64"]).reshape(g["mel_shape"])
    got = mel_spectrogram(wav)
    if got.shape != tuple(g["mel_shape"]):
        bad.append(f"前端形状 {got.shape} ≠ 金标 {tuple(g['mel_shape'])}")
    else:
        diff = float(np.abs(got - want).max())
        mark = "✅" if diff <= MEL_TOL else "🔴"
        print(f"{mark} 前端 vs mel_golden:最大逐点差 {diff:.2e}(容差 {MEL_TOL:.0e})")
        if diff > MEL_TOL:
            bad.append(f"前端最大逐点差 {diff:.2e} 超容差 —— 五步里有常数写错了,"
                       f"别调容差,去找那个常数")

    # ② 端到端:embedder_golden 余弦
    e = json.loads((FIX / "embedder_golden.json").read_text())
    if e["_spec"]["onnx"] != f"{MODEL_ID}.onnx":
        bad.append(f"金标模型 {e['_spec']['onnx']} ≠ 本侧 {MODEL_ID}.onnx —— "
                   f"换模型三件套没换齐(模型/MODEL_ID/金标)")
    wav = f32(e["wav_b64"])
    want = f32(e["emb_b64"])
    assert want.shape[0] == EMBEDDING_DIM == e["emb_dim"]
    got = RedimnetEmbedder().embed(wav)
    cos = float(np.dot(got, want))                 # 两侧都已 L2 归一
    mark = "✅" if cos >= COS_FLOOR else "🔴"
    print(f"{mark} 端到端 vs embedder_golden:余弦 {cos:.6f}(达标线 {COS_FLOOR})")
    if cos < COS_FLOOR:
        bad.append(f"端到端余弦 {cos:.6f} < {COS_FLOOR} —— Mac 提的向量与底库"
                   f"不在同一空间,判决会全错而不报错(审计 H)")

    # ③ 照妖镜内建:把窗换成 Hann,①必须红 —— 证明这道对撞真的抓得住换窗
    import mac.redimnet_embed as m
    n = np.arange(m.WIN, dtype=np.float64)
    hann = np.zeros(m.N_FFT)
    hann[(m.N_FFT - m.WIN) // 2:(m.N_FFT - m.WIN) // 2 + m.WIN] = \
        0.5 - 0.5 * np.cos(2 * np.pi * n / m.WIN)
    saved = m._WINDOW
    try:
        m._WINDOW = hann
        g2 = json.loads((FIX / "mel_golden.json").read_text())
        diff2 = float(np.abs(mel_spectrogram(f32(g2["wav_b64"]))
                             - f32(g2["mel_b64"]).reshape(g2["mel_shape"])).max())
    finally:
        m._WINDOW = saved
    if diff2 <= MEL_TOL:
        bad.append(f"照妖镜没红:换成 Hann 窗后最大差 {diff2:.2e} 仍在容差内 —— "
                   f"这道对撞抓不住换窗,别信它")
    else:
        print(f"✅ 照妖镜:换 Hann 窗后差 {diff2:.2e} > 容差 —— 对撞真的会红")

    if bad:
        print()
        for b in bad:
            print(f"🔴 {b}", file=sys.stderr)
        return 1
    print("\n✅ Mac 嵌入器与手机金标对上了 —— 同一个空间")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

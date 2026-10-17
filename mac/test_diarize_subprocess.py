#!/usr/bin/env python3
"""分人子进程桥 + 检出率闸的自测(M2-认6)。**不跑模型、不联网**,分人器是注入的假货。

    python3 mac/test_diarize_subprocess.py
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mac import diarize_subprocess as D                            # noqa: E402


def _turns(*spans):
    """spans: (起秒, 止秒, 说话人号)"""
    return [(int(a * 1000), int(b * 1000), s) for a, b, s in spans]


def test_normal_run_returns_labels_in_the_upstream_shape():
    """标签形状要与上游(文件端点)一致:`speaker_0` 起编,不是 `说话人1`。"""
    out = D.turns_for("x.wav", asr_speech_sec=100.0,
                      runner=lambda p, t: _turns((0, 50, 0), (50, 95, 1)))
    assert out is not None
    assert {s for _, _, s in out} == {"speaker_0", "speaker_1"}, out


def test_low_detection_rate_is_gated_out():
    """Generic implementation; local private materials are not distributed."""






    assert D.turns_for("x.wav", asr_speech_sec=119.2,
                       runner=lambda p, t: _turns((0, 32, 0))) is None


def test_a_healthy_detection_rate_passes():
    """95% 那一档要放行 —— 闸不能连好块一起挡。"""
    assert D.turns_for("x.wav", asr_speech_sec=331.4,
                       runner=lambda p, t: _turns((0, 312, 0))) is not None


def test_unknown_asr_duration_does_not_guess():
    """ASR 没给语音时长 ⇒ 闸没有判据 ⇒ **不放行**。

    猜一个「大概够了」等于把闸拆掉,而闸挡的正是「看起来正常的坏分组」。"""
    assert D.turns_for("x.wav", asr_speech_sec=0,
                       runner=lambda p, t: _turns((0, 300, 0))) is None


def test_any_failure_falls_open():
    """🔴 分人抛异常 ⇒ 返回 None,让调用方**照旧发稿**。

    这一步是加分项,转写是主线。红了说明一次分人失败会连累一块花过钱的转写。"""
    def boom(p, t):
        raise RuntimeError("模型没了")
    assert D.turns_for("x.wav", asr_speech_sec=100.0, runner=boom) is None


def test_timeout_falls_open():
    """超时同样降级 —— `T` 是防死锁的,不是控吞吐的(spec §五-5)。"""
    import subprocess
    def slow(p, t):
        raise subprocess.TimeoutExpired(cmd="diarize", timeout=t)
    assert D.turns_for("x.wav", asr_speech_sec=100.0, runner=slow) is None


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"  ✓ {fn.__name__}")
    print(f"✅ {len(fns)} 条全过")

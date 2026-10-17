#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""




























from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

#: 检出秒 / ASR 认为的语音秒,低于它就当分人没做成。
#: ⚠️ **起点值,不是量出来的**:阶段一只知道好块在 93–95%、坏块在 27%,
#: 中间那条沟里**没有样本**。取 0.6 是因为它离两边都远。有分布了再改。
MIN_DETECTION_RATIO = 0.6

#: 硬超时。它防的是**死锁**,不是控吞吐 —— 慢一点就让它慢(spec §五-5:
#: 每块预算 71 秒,超了只是每块占两轮,launchd 不会并发启动同一个 Label)。
#: ⚠️ 同样是起点值:阶段一实测满尺寸块最慢 16.5 秒,这里给了一个数量级的余量。
DEFAULT_TIMEOUT_SEC = 180

_VENV_PY = os.environ.get("GROWTH_SV_PYTHON") or str(
    Path.home() / "Desktop" / "录音文件" / "_pipeline" / ".venv" / "bin" / "python")


def _run_anywhere(audio_path: str, timeout_sec: int) -> list[tuple[int, int, int]]:
    """真跑分人。本解释器有货就直接跑,否则起 venv 子进程。"""
    try:
        import modelscope  # noqa: F401
        from mac.diarize import diarize_raw
        return diarize_raw(audio_path)          # 不传 oracle_num:人数交给模型自己估
    except ImportError:
        pass
    if not Path(_VENV_PY).exists():
        raise RuntimeError(f".venv python 不在({_VENV_PY})")
    root = Path(__file__).resolve().parents[1]
    r = subprocess.run([_VENV_PY, "-m", "mac.diarize_subprocess",
                        "--audio", audio_path, "--json-only"],
                       capture_output=True, text=True, timeout=timeout_sec,
                       env={**os.environ, "PYTHONPATH": str(root)}, cwd=str(root))
    if r.returncode != 0:
        raise RuntimeError(f"分人子进程失败: {(r.stderr or '')[-300:]}")
    return [tuple(x) for x in json.loads(r.stdout.strip().splitlines()[-1])]


def turns_for(audio_path: str, asr_speech_sec: float, *,
              timeout_sec: int = DEFAULT_TIMEOUT_SEC,
              runner=None) -> list[tuple[int, int, str]] | None:
    """这一块的说话人段,标签是**上游格式**(`speaker_0` 起编)。做不成返回 None。

    - `asr_speech_sec`:ASR 认为这一块里有多少秒语音。**闸的分母**。
      给 0 或负数 ⇒ 闸没有判据 ⇒ **不放行**(猜一个「大概够了」等于把闸拆掉)。
    - `runner`:注入点,自测拿它换掉真模型。
    """
    run = runner or _run_anywhere
    try:
        raw = run(audio_path, timeout_sec)
    except Exception as e:                                          # noqa: BLE001
        # 吞掉但**说出来** —— 静默 fail-open 会让「分人一直没做成」看起来像
        # 「这些块本来就没人说话」(仓规 6:兜底 except 要么记录要么抛)。
        print(f"▸ 分人没做成,照旧发无分人稿:{type(e).__name__}: {e}", file=sys.stderr)
        return None
    if not raw:
        print("▸ 分人一段都没切出来,照旧发无分人稿", file=sys.stderr)
        return None
    detected = sum(b - a for a, b, _ in raw) / 1000.0
    if asr_speech_sec <= 0:
        print(f"▸ 不知道 ASR 认为有多少语音,闸没有判据 ⇒ 不发标签"
              f"(检出 {detected:.0f}s)", file=sys.stderr)
        return None
    ratio = detected / asr_speech_sec
    if ratio < MIN_DETECTION_RATIO:
        print(f"▸ 检出率 {ratio:.0%}(检出 {detected:.0f}s / ASR {asr_speech_sec:.0f}s)"
              f" < 闸线 {MIN_DETECTION_RATIO:.0%} ⇒ 不发标签", file=sys.stderr)
        return None
    return [(a, b, f"speaker_{s}") for a, b, s in raw]


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio", required=True)
    ap.add_argument("--json-only", action="store_true")
    a = ap.parse_args()
    from mac.diarize import diarize_raw
    print(json.dumps([list(t) for t in diarize_raw(a.audio)]))

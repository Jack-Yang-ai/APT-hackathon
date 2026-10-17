"""Generic implementation; local private materials are not distributed."""









from __future__ import annotations

import json
import sys
from pathlib import Path

from . import speaker_id as sid


def enroll_one(sidecar: Path, code: str, name: str, *, meeting: str | None = None) -> dict:
    """把边车里 code 对应的声纹以真名 name 入库。返回 {ok, enrolled, hint}。
    edge：边车缺该 code 的 emb（语音太少未提取）→ enrolled=False。"""
    import numpy as np  # noqa: PLC0415
    data = json.loads(Path(sidecar).read_text(encoding="utf-8"))
    meeting = meeting or Path(sidecar).name.replace(".speakers.json", "")
    rec = data.get(code)
    if not rec or not rec.get("emb"):
        return {"ok": True, "enrolled": False,
                "hint": f"{code}：边车里无声纹（可能语音太少未提取），跳过入库"}
    emb = np.asarray(rec["emb"], dtype=np.float32)
    reg = sid.load_registry()
    m = sid.match(emb, reg)  # 入库前看看现有库会怎么认（辅助核对）
    hint = f"现库匹配：{m[0]} {m[1]:.2f}" if m else "现库无匹配"
    sid.enroll(reg, name, emb, meeting)
    sid.save_registry(reg)
    return {"ok": True, "enrolled": True, "hint": hint}


def _embed_audio(wav16: str):
    """16k wav → 192 维 L2 声纹（list）。本地有 torch 直接算；否则走 .venv 的 sv_worker embed。失败 None。"""
    from . import run as _run  # 惰性：借 _have_torch / _sv_subprocess（3.9 守护无 torch 时走 .venv）
    if _run._have_torch():
        try:
            return sid.embed_wav(wav16).reshape(-1).tolist()
        except Exception:  # noqa: BLE001
            return None
    d = _run._sv_subprocess(["embed", "--wav", wav16])
    return (d or {}).get("emb")


def enroll_audio(name: str, audio_path: str, *, meeting: str = "self-enroll") -> dict:
    """自录声纹注册：一段音频 → 16k wav → 算 192 维声纹 → 以 name 入库。
    返回 {ok, enrolled, name, samples, hint} 或 {ok:False, reason}。
    与确认门 enroll_one 共用同一底库；这条是「主动录一段把自己记全」的入口。"""
    import tempfile  # noqa: PLC0415
    import numpy as np  # noqa: PLC0415
    from .asr_stepfun import audio_to_wav16k  # noqa: PLC0415
    name = (name or "").strip()
    if not name:
        return {"ok": False, "enrolled": False, "reason": "name required"}
    with tempfile.TemporaryDirectory() as td:
        try:
            wav16 = audio_to_wav16k(audio_path, str(Path(td) / "enroll_16k.wav"))
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "enrolled": False, "reason": f"转 16k wav 失败: {e}"}
        emb = _embed_audio(wav16)
    if emb is None:
        return {"ok": False, "enrolled": False,
                "reason": "声纹算不出来（音频太短/无人声，或 .venv 声纹环境不可用）"}
    emb = np.asarray(emb, dtype=np.float32)
    reg = sid.load_registry()
    m = sid.match(emb, reg)
    hint = f"录前现库匹配：{m[0]} {m[1]:.2f}" if m else "现库无匹配"
    sid.enroll(reg, name, emb, meeting)
    sid.save_registry(reg)
    return {"ok": True, "enrolled": True, "name": name,
            "samples": reg.get("people", {}).get(name, {}).get("samples", 0), "hint": hint}


# ──────────────────────────────────────────────────────────────────────────
# v2 入口（声纹迁移 P0.6，见 docs/voiceprint-migration-checklist.md 检查点A）。
# 只服务 embed_v2 + registry_v2 + enroll_gates 的新路径；不改上面任何 v1 函数/行为，
# 老 registry.json（CAM++ 192d）的现有调用方完全不受影响。
# ──────────────────────────────────────────────────────────────────────────

def enroll_audio_v2(
    name: str,
    audio_path: str,
    *,
    meeting: str = "self-enroll-v2",
    text: str | None = None,
    overlap_regions: list | None = None,
    seg_range: tuple | None = None,
    enable_bandwidth: bool = True,
    enable_sed: bool = True,
    enable_broadcast_text: bool = True,
    enable_overlap: bool = True,
) -> dict:
    """一段音频 → 广播硬门(check_enroll_gates) → 256d 声纹(embed_v2) → 入 registry_v2。

    不过门 → 拒绝入库，返回明确原因 + 处理建议（reason 面向人看，不是异常堆栈）。
    与 v1 的 enroll_audio 是两套独立底库/独立空间，互不影响、互不调用。

    返回：
      过门+入库成功: {"ok": True, "enrolled": True, "name", "hint", "gate_metrics"}
      不过门/失败:   {"ok": False, "enrolled": False, "reason", "gate_reasons", "gate_metrics"}
    """
    import tempfile  # noqa: PLC0415

    import soundfile as sf  # noqa: PLC0415

    from .asr_stepfun import audio_to_wav16k  # noqa: PLC0415
    from . import enroll_gates as _gates  # noqa: PLC0415
    from . import embed_v2 as _ev2  # noqa: PLC0415
    from . import registry_v2 as _rv2  # noqa: PLC0415

    name = (name or "").strip()
    if not name:
        return {"ok": False, "enrolled": False,
                "reason": "没给名字——这段声纹要挂在谁名下？先补上要入库的人名再重试。"}

    with tempfile.TemporaryDirectory() as td:
        try:
            wav16 = audio_to_wav16k(audio_path, str(Path(td) / "enroll_v2_16k.wav"))
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "enrolled": False,
                    "reason": f"音频转 16k wav 失败（{e}）——换一份能正常播放的原始录音再试。"}

        gate = _gates.check_enroll_gates(
            wav16, text=text, overlap_regions=overlap_regions, seg_range=seg_range,
            enable_bandwidth=enable_bandwidth, enable_sed=enable_sed,
            enable_broadcast_text=enable_broadcast_text, enable_overlap=enable_overlap,
        )
        if not gate["passed"]:
            why = "；".join(gate["reasons"]) or "未过硬门（原因未知）"
            return {
                "ok": False, "enrolled": False,
                "reason": f"这段声纹没有入库——{why}。"
                          "如果确认这是真人在场的干净人声（不是导航/报站/背景音乐/抢话重叠），"
                          "换一段更长、更安静、说话更集中的片段再试；持续判拒请找人核实素材来源。",
                "gate_reasons": gate["reasons"], "gate_metrics": gate["metrics"],
            }

        try:
            info = sf.info(wav16)
            dur = info.frames / float(info.samplerate)
            emb = _ev2.embed_v2(wav16)
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "enrolled": False,
                    "reason": f"过门了，但声纹算不出来（{e}）——多半是片段太短/静音，换一段更长的再试。",
                    "gate_reasons": gate["reasons"], "gate_metrics": gate["metrics"]}

    reg = _rv2.load_registry_v2()
    m = _rv2.match_v2(emb, reg)
    hint = f"registry_v2 现有匹配：{m[0][0]} {m[0][1]:.2f}" if m else "registry_v2 目前是空库"
    _rv2.enroll_v2(reg, name, emb, src=Path(audio_path).name, meeting=meeting, dur=dur)
    _rv2.save_registry_v2(reg)
    return {"ok": True, "enrolled": True, "name": name, "hint": hint,
            "gate_metrics": gate["metrics"]}


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    sidecar = Path(sys.argv[1])
    if not sidecar.exists():
        print(f"找不到声纹边车: {sidecar}")
        return 2
    done = []
    for arg in sys.argv[2:]:
        if "=" not in arg:
            print(f"[skip] 参数格式应为 说话人N=真名，跳过: {arg}")
            continue
        code, name = arg.split("=", 1)
        r = enroll_one(sidecar, code.strip(), name.strip())
        if r["enrolled"]:
            done.append(f"{code.strip()} -> {name.strip()}（{r['hint']}）")
        else:
            print("[skip] " + r["hint"])
    print("已入库：")
    for d in done:
        print("  " + d)
    print(f"底库：{sid.REGISTRY}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

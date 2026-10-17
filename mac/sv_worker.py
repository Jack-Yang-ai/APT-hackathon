#!/usr/bin/env python3
"""声纹 / 分人 子进程 worker —— 在 _pipeline/.venv（Python 3.11，装了 torch 2.12 / modelscope 1.37 /
funasr）里执行。

为什么要它：growth 守护跑在 Xcode Python 3.9，装不了 torch 2.12；而 CAM++ 分人 + 声纹相似度（SV）
要 torch/modelscope。本 worker 由 .venv 的 python 执行（PYTHONPATH 指向 growth 根），复用 growth
现成的 ingest.meeting.diarize / speaker_id，把结果以一行 JSON 打到 stdout，由 3.9 侧 subprocess 调它。

用法（ingest.meeting.run 内部调；也可手测）：
  <.venv-python> ingest/meeting/sv_worker.py selftest   --wav clip16k.wav   # 验证 SV 模型能加载+出声纹
  <.venv-python> ingest/meeting/sv_worker.py diarize    --wav a.wav
  <.venv-python> ingest/meeting/sv_worker.py speaker_id --wav a.wav --spans spans.json
stdout 只打一行 JSON（其余日志走 stderr），父进程好解析。
"""
from __future__ import annotations

import argparse
import contextlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]   # growth 根：…/ingest/meeting/sv_worker.py → parents[2]
sys.path.insert(0, str(ROOT))


def _diarize(wav: str) -> dict:
    from mac.diarize import diarize_turns
    turns = diarize_turns(wav)
    return {"turns": [{"start_ms": t.start_ms, "end_ms": t.end_ms, "speaker": t.speaker} for t in turns]}


def _speaker_id(wav: str, spans: dict, clips_dir: str | None = None) -> dict:
    """spans = {说话人N: [[start_ms,end_ms],...]}。对每簇算声纹 + 匹配底库 +（可选）写代表切片。
    切片必须在这里写（.venv 有 soundfile；3.9 守护没有），供确认门试听。"""
    from pathlib import Path as _P

    from mac import speaker_id as sid
    reg = sid.load_registry()
    preds, embs, clips = {}, {}, {}
    if clips_dir:
        _P(clips_dir).mkdir(parents=True, exist_ok=True)
    for spk, sp in spans.items():
        pairs = [(int(s), int(e)) for s, e in sp]
        emb = sid.embed_speaker_spans(wav, pairs)
        if emb is None:
            preds[spk] = None
            continue
        embs[spk] = [round(float(x), 6) for x in emb.tolist()]
        m = sid.match(emb, reg)
        preds[spk] = [m[0], round(float(m[1]), 4)] if m else None
        if clips_dir:
            cp = sid.write_speaker_clip(wav, pairs, str(_P(clips_dir) / f"{spk}.wav"))
            if cp:
                clips[spk] = cp
    return {"predictions": preds, "embeddings": embs, "clips": clips}


def _selftest(wav: str) -> dict:
    """加载 SV 模型对一段 wav 出声纹，验证 torch/modelscope/模型链路通。"""
    from mac import speaker_id as sid
    emb = sid.embed_wav(wav)
    return {"ok": True, "dim": int(emb.reshape(-1).shape[0]),
            "l2norm": round(float((emb.reshape(-1) @ emb.reshape(-1)) ** 0.5), 4),
            "sv_model": sid._SV_MODEL}


def _embed(wav: str) -> dict:
    """对整段 wav 算 192 维 L2 声纹向量（自录声纹注册用：父进程拿去 enroll 进底库）。"""
    from mac import speaker_id as sid
    emb = sid.embed_wav(wav)
    return {"ok": True, "emb": [round(float(x), 6) for x in emb.reshape(-1).tolist()]}


def main() -> int:
    ap = argparse.ArgumentParser(description="声纹/分人 worker（在 .venv 跑）")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("diarize", "speaker_id", "selftest", "embed"):
        p = sub.add_parser(c)
        p.add_argument("--wav", required=True)
        if c == "speaker_id":
            p.add_argument("--spans", required=True, help="JSON 文件：{说话人N: [[start_ms,end_ms],...]}")
            p.add_argument("--clips-dir", default=None, help="给目录则每簇写一段代表切片（确认门试听）")
    a = ap.parse_args()
    # modelscope/funasr 会往 stdout 打「Downloading Model…」等噪声，污染 JSON ——
    # 把 ML 阶段的 stdout 全部转到 stderr，只让最终 JSON 进真正的 stdout。
    try:
        with contextlib.redirect_stdout(sys.stderr):
            if a.cmd == "diarize":
                out = _diarize(a.wav)
            elif a.cmd == "speaker_id":
                spans = json.loads(Path(a.spans).read_text(encoding="utf-8"))
                out = _speaker_id(a.wav, spans, getattr(a, "clips_dir", None))
            elif a.cmd == "embed":
                out = _embed(a.wav)
            else:
                out = _selftest(a.wav)
    except Exception as e:  # noqa: BLE001 — 失败码 1 + stderr，父进程降级
        sys.stderr.write(f"sv_worker {a.cmd} failed: {type(e).__name__}: {e}\n")
        return 1
    sys.stdout.write(json.dumps(out, ensure_ascii=False))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

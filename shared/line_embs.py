#!/usr/bin/env python3
"""逐句声纹 embedding 的统一留档层（核心集方案纪律②：embedding 跟着 L0 走，永久留存）。

音频是易逝的（产品化后 7 天即焚，本地也可能清理），逐句 192 维 CAM++ 声纹是唯一能让
「匿名说话人先放一放、置信够了再回溯重认」可逆的东西——每条录音转写后必须落盘。

存储：data/line_embs/{mid}.npz，key=转写行 ts（MM:SS / HH:MM:SS），value=L2 归一化向量。
只追加：已有 ts 不重算（与 L0 同纪律）；写入方＝在线管线(ingest/meeting/run.py) + 本模块补齐 CLI。
读取方＝recluster / split_mixed / 未来的匿名簇跨录音聚合。

CLI（历史补齐，需能读源音频——Desktop 要 FDA/前台）：
  python3 -m memory.line_embs                # 全量 dry-run：报告每条录音的覆盖率
  python3 -m memory.line_embs --backfill     # 只补缺的（有 npz 的录音跳过缺行也补）
  python3 -m memory.line_embs --backfill --mids 2026-07-04-0923段
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import numpy as np  # noqa: E402
from shared import db as store  # 判 7：新仓只保留路径/连接层，三层表 API 已退役

EMB_DIR = store.ROOT / "data" / "line_embs"
MIN_LINE_SEC = 0.8          # 短于此的行声纹不可靠，不存（与 recluster worker 口径一致）

# worker 在 _pipeline/.venv（torch/modelscope 在那边）里跑；本进程零重依赖。
_EMB_WORKER = r"""
import json, os, sys, tempfile
real=os.fdopen(os.dup(1),"w"); os.dup2(2,1); sys.stdout=sys.stderr
sys.path.insert(0, os.environ["GROWTH_ROOT"])
import numpy as np, soundfile as sf
from ingest.meeting import speaker_id as sid
wav, spans_p = sys.argv[1], sys.argv[2]
spans=json.load(open(spans_p)); out={}
with sf.SoundFile(wav) as f:
    sr,nf=f.samplerate,len(f)
    for key,sp in spans.items():
        s_ms,e_ms=sp
        a=max(0,min(int(s_ms/1000*sr),nf)); b=max(0,min(int(e_ms/1000*sr),nf))
        dur=(b-a)/sr
        if dur<0.8: out[key]={"skip":1}; continue
        f.seek(a); data=f.read(b-a,dtype="float32")
        if data.ndim>1: data=data[:,0]
        fd,tmp=tempfile.mkstemp(suffix=".wav"); os.close(fd)
        try: sf.write(tmp,data,sr); emb=sid.embed_wav(tmp)
        finally: os.unlink(tmp)
        v=np.asarray(emb,dtype=np.float32); n=np.linalg.norm(v)
        out[key]={"dur":round(dur,2),"emb":(v/n if n>0 else v).tolist()}
real.write(json.dumps(out)); real.flush()
"""


# ── 近场判据（佩戴者=近场明显更响，背景人声=远场弱；声纹分不开时能量分得开）──
# 逐行 dBFS 与 embedding 同纪律：焚毁音频前必须萃取、永久留档（{mid}.db.npz）。
NEAR_FAR_VETO = -10.0   # 簇能量中位 低于全录音 P90 超过 10dB → 远场，否决「我」
NEAR_MIN_LINES = 3      # 簇内有能量读数的行少于此 → 不判（None）
NEAR_MIN_TOTAL = 20     # 全录音能量样本少于此 → 分布不可信，不判

_DB_WORKER = r"""
import json, sys
import numpy as np, soundfile as sf
wav, spans_p = sys.argv[1], sys.argv[2]
spans=json.load(open(spans_p)); out={}
with sf.SoundFile(wav) as f:
    sr,nf=f.samplerate,len(f)
    for key,sp in spans.items():
        s_ms,e_ms=sp
        a=max(0,min(int(s_ms/1000*sr),nf)); b=max(0,min(int(e_ms/1000*sr),nf))
        if b-a < int(0.2*sr): continue
        f.seek(a); data=f.read(b-a,dtype="float32")
        if data.ndim>1: data=data[:,0]
        rms=float(np.sqrt(np.mean(data*data)))
        out[key]=round(20*np.log10(rms+1e-9),2)
print(json.dumps(out))
"""


def energy_spans(wav: Path | str, spans: dict) -> dict:
    """{key:(s_ms,e_ms)} → {key: dBFS}。soundfile-only 轻 worker（无模型，秒级）。"""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as tf:
        json.dump({k: list(v) for k, v in spans.items()}, tf)
        sp = tf.name
    env = dict(os.environ, GROWTH_ROOT=str(store.ROOT))
    try:
        r = subprocess.run([_venv_py(), "-c", _DB_WORKER, str(wav), sp],
                           capture_output=True, text=True, env=env, timeout=1800)
    finally:
        Path(sp).unlink(missing_ok=True)
    if r.returncode != 0:
        raise RuntimeError(f"db worker failed: {r.stderr[-800:]}")
    return json.loads(r.stdout.strip().splitlines()[-1])


def load_db(mid: str) -> dict:
    """{行ts: dBFS}。没有 db.npz 返回 {}。"""
    p = EMB_DIR / f"{mid}.db.npz"
    if not p.exists():
        return {}
    try:
        d = np.load(p, allow_pickle=False)
        return {str(ts): float(v) for ts, v in zip(d["ts"], d["db"])}
    except Exception:  # noqa: BLE001
        return {}


def save_db(mid: str, cache: dict) -> None:
    if not cache:
        return
    EMB_DIR.mkdir(parents=True, exist_ok=True)
    np.savez(EMB_DIR / f"{mid}.db.npz", ts=np.array(list(cache.keys())),
             db=np.array([float(v) for v in cache.values()], np.float32))


def ensure_db(mid: str, wav: Path | str, ts_spans: dict) -> tuple[dict, int]:
    """补算缺能量的行并落盘。幂等；与 ensure() 同形。"""
    cache = load_db(mid)
    missing = {ts: sp for ts, sp in ts_spans.items() if ts not in cache}
    if not missing:
        return cache, 0
    new = energy_spans(wav, missing)
    for ts, v in new.items():
        cache[ts] = float(v)
    save_db(mid, cache)
    return cache, len(new)


def rel_db(cluster_vals, all_vals) -> float | None:
    """近场相对分：簇能量中位 − 全录音 P90。≥0≈佩戴者量级；< NEAR_FAR_VETO = 远场。纯函数可测。"""
    if len(cluster_vals) < NEAR_MIN_LINES or len(all_vals) < NEAR_MIN_TOTAL:
        return None
    return float(np.median(cluster_vals) - np.percentile(all_vals, 90))


def near_rel_db(mid: str, ts_list, exclude_ts=None) -> float | None:
    """Generic implementation; local private materials are not distributed."""


    db = load_db(mid)
    if not db:
        return None
    vals = [db[ts] for ts in ts_list if ts in db]
    ex = exclude_ts or ()
    return rel_db(vals, [v for ts, v in db.items() if ts not in ex])


def _venv_py() -> str:
    from memory.split_mixed import VENV_PY
    return VENV_PY


def embed_spans(wav: Path | str, spans: dict) -> dict:
    """{key:(s_ms,e_ms)} → {key:{dur,emb}|{skip}}。子进程跑 .venv worker（torch 不进本进程）。"""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as tf:
        json.dump({k: list(v) for k, v in spans.items()}, tf)
        sp = tf.name
    env = dict(os.environ, GROWTH_ROOT=str(store.ROOT), HF_HUB_OFFLINE="1")
    try:
        r = subprocess.run([_venv_py(), "-c", _EMB_WORKER, str(wav), sp],
                           capture_output=True, text=True, env=env, timeout=7200)
    finally:
        Path(sp).unlink(missing_ok=True)
    if r.returncode != 0:
        raise RuntimeError(f"emb worker failed: {r.stderr[-1500:]}")
    return json.loads(r.stdout)


def load(mid: str) -> dict:
    """{行ts: L2 声纹向量}。没有 npz 返回 {}。"""
    p = EMB_DIR / f"{mid}.npz"
    if not p.exists():
        return {}
    try:
        d = np.load(p, allow_pickle=False)
        return {str(ts): e for ts, e in zip(d["ts"], d["emb"])}
    except Exception:  # noqa: BLE001
        return {}


def save(mid: str, cache: dict) -> None:
    if not cache:
        return
    EMB_DIR.mkdir(parents=True, exist_ok=True)
    np.savez(EMB_DIR / f"{mid}.npz", ts=np.array(list(cache.keys())),
             emb=np.stack([np.asarray(v, np.float32) for v in cache.values()]))


def ensure(mid: str, wav: Path | str, ts_spans: dict) -> tuple[dict, int]:
    """把 {行ts:(s_ms,e_ms)} 里缺声纹的行补算并落盘。返回 (全量cache, 本次新算条数)。
    幂等：已有 ts 不碰音频。异常向上抛（调用方决定 fail-open 还是中断）。"""
    cache = load(mid)
    missing = {ts: sp for ts, sp in ts_spans.items()
               if ts not in cache and (sp[1] - sp[0]) / 1000.0 >= MIN_LINE_SEC}
    if not missing:
        return cache, 0
    new = embed_spans(wav, missing)
    n = 0
    for ts, v in new.items():
        if v.get("emb"):
            cache[ts] = np.asarray(v["emb"], np.float32)
            n += 1
    save(mid, cache)
    return cache, n


# ───────────────────────── 历史补齐 CLI ─────────────────────────

def _all_mids():
    from memory.ingest_meeting import INBOX
    return sorted(p.stem.replace(".transcript", "") for p in INBOX.glob("*.transcript.md"))


def backfill(mids=None, apply=False) -> None:
    from memory.ingest_meeting import INBOX, parse_transcript
    from memory.emotion_fill import _audio_source
    from memory.split_mixed import ensure_16k, line_spans
    total_new = 0
    for mid in (mids or _all_mids()):
        t = parse_transcript(INBOX / f"{mid}.transcript.md")
        lines = t["lines"]
        if not lines:
            continue
        spans_all = line_spans(lines)
        ts_spans = {lines[i]["ts"]: tuple(spans_all[i]) for i in range(len(lines))
                    if spans_all[i] and (spans_all[i][1] - spans_all[i][0]) / 1000.0 >= MIN_LINE_SEC}
        # 能量便宜（无模型），全行覆盖（含短行，0.2s 起）
        ts_spans_db = {lines[i]["ts"]: tuple(spans_all[i]) for i in range(len(lines))
                       if spans_all[i] and (spans_all[i][1] - spans_all[i][0]) >= 200}
        have, have_db = load(mid), load_db(mid)
        miss = [ts for ts in ts_spans if ts not in have]
        miss_db = [ts for ts in ts_spans_db if ts not in have_db]
        print(f"{mid:44} 行 {len(lines):>4}  声纹缺 {len(miss):>4}  能量缺 {len(miss_db):>4}", end="")
        if (not miss and not miss_db) or not apply:
            print()
            continue
        src = _audio_source(f"{mid}.transcript.md")
        if not src:
            print("  ⚠ 源音频缺失，跳过")
            continue
        wav = ensure_16k(Path(src), mid)
        try:
            n = nd = 0
            if miss:
                _, n = ensure(mid, wav, ts_spans)
            if miss_db:
                _, nd = ensure_db(mid, wav, ts_spans_db)
            total_new += n + nd
            print(f"  ✓ 补 声纹{n} 能量{nd}")
        finally:
            try:
                wav.unlink(missing_ok=True)   # 16k 缓存用完即删（声纹已存 npz）
            except OSError:
                pass
    if apply:
        print(f"\n共补算 {total_new} 行声纹 → {EMB_DIR}")


def main():
    ap = argparse.ArgumentParser(description="逐句声纹留档：覆盖率报告 / 历史补齐")
    ap.add_argument("--backfill", action="store_true", help="补算缺的（默认只报告）")
    ap.add_argument("--mids", help="逗号分隔，只处理这些录音")
    a = ap.parse_args()
    mids = [m.strip() for m in a.mids.split(",")] if a.mids else None
    backfill(mids=mids, apply=a.backfill)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

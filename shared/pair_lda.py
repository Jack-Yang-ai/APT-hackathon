#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""

















from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

import numpy as np

# macOS Accelerate BLAS 在 float64 matmul 上会误报 divide/overflow/invalid（结果其实正常）。
np.seterr(divide="ignore", over="ignore", invalid="ignore")

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "data" / "meeting_artifacts"
REGISTRY = ROOT / "ingest" / "meeting" / "voiceprints" / "registry.json"
DB = ROOT / "data" / "memory.sqlite"

# Caller supplies a local pair/model mapping; no personal presets are bundled.
MODEL_PATHS = {}
PAIRS = []
PAIR = None
MODEL_PATH = None

def configure_models(mapping):
    global MODEL_PATHS, PAIRS, PAIR, MODEL_PATH, _MODELS
    candidate = {tuple(pair): Path(path) for pair, path in mapping.items()}
    if any(len(pair) != 2 or pair[0] == pair[1] for pair in candidate):
        raise ValueError("Each model requires two distinct locally registered identities")
    MODEL_PATHS = candidate
    PAIRS = list(MODEL_PATHS)
    PAIR = PAIRS[0] if PAIRS else None
    MODEL_PATH = MODEL_PATHS.get(PAIR)
    _MODELS = None

SHRINKAGE = 0.5          # 样本远少于维度(192+)，重收缩防协方差病态
EASY_CONFUSE_GAP = 0.08  # cos top1-top2 分差小于此视为易混区（vp_rematch 同款）
MIN_LOO = 0.75           # LOO 低于此不上线（样本不够/分不开）


def _l2(v):
    v = np.asarray(v, dtype=np.float64)
    return v / (np.linalg.norm(v) + 1e-9)


def _load_speakers(mid: str) -> dict:
    sj = ART / mid / f"{mid}.speakers.json"
    if not sj.exists():
        return {}
    try:
        return json.loads(sj.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def collect_samples(pair=None) -> tuple[list, list, dict]:
    """返回 (pair[0]的样本, pair[1]的样本, 统计)。全部 l2 归一。"""
    pair = pair if pair is not None else PAIR
    if pair is None:
        raise ValueError("Configure local identity pairs before collecting samples")
    reg = json.loads(REGISTRY.read_text(encoding="utf-8"))
    samples = {n: [] for n in pair}
    stats = {n: {"registry": 0, "cluster": 0} for n in pair}
    for n in pair:
        p = reg.get("people", {}).get(n, {})
        for v in (p.get("embs") or p.get("embeddings") or []):
            samples[n].append(_l2(v))
            stats[n]["registry"] += 1
    con = sqlite3.connect(DB, timeout=60)
    try:
        alias_of = {}
        for n in pair:
            row = con.execute(
                "SELECT aliases FROM entities WHERE kind='person' AND name=?", (n,)).fetchone()
            alias_of[n] = set(json.loads((row and row[0]) or "[]"))
    finally:
        con.close()
    conflicts = alias_of[pair[0]] & alias_of[pair[1]]   # 两人同时认领的簇 → 剔除
    spk_cache: dict = {}
    for n in pair:
        for al in sorted(alias_of[n] - conflicts):
            if "·" not in al:
                continue
            mid, spk = al.rsplit("·", 1)
            if mid not in spk_cache:
                spk_cache[mid] = _load_speakers(mid)
            v = spk_cache[mid].get(spk) or spk_cache[mid].get(spk + "?")
            emb = (v or {}).get("emb")
            if emb:
                samples[n].append(_l2(emb))
                stats[n]["cluster"] += 1
    stats["conflicts_dropped"] = sorted(conflicts)
    return samples[pair[0]], samples[pair[1]], stats


def fit_lda(X0: np.ndarray, X1: np.ndarray, lam: float = SHRINKAGE):
    """最简两类 LDA：w = Σ_reg^{-1}(μ0-μ1)。返回 (w 单位向量, 阈值=两类投影均值中点)。"""
    mu0, mu1 = X0.mean(axis=0), X1.mean(axis=0)
    Xc = np.vstack([X0 - mu0, X1 - mu1])
    cov = (Xc.T @ Xc) / max(len(Xc) - 2, 1)
    sigma2 = float(np.trace(cov)) / cov.shape[0]
    cov_reg = (1 - lam) * cov + lam * sigma2 * np.eye(cov.shape[0])
    w = np.linalg.solve(cov_reg, mu0 - mu1)
    w /= np.linalg.norm(w) + 1e-12
    thr = float((X0 @ w).mean() + (X1 @ w).mean()) / 2
    assert np.isfinite(w).all() and np.isfinite(thr), "LDA 数值异常（协方差病态？）"
    return w, thr


def loo_accuracy(X0: np.ndarray, X1: np.ndarray) -> float:
    correct = total = 0
    for cls, X_own, X_other in ((0, X0, X1), (1, X1, X0)):
        for i in range(len(X_own)):
            X_tr = np.delete(X_own, i, axis=0)
            if len(X_tr) < 2:
                continue
            w, thr = (fit_lda(X_tr, X_other) if cls == 0 else fit_lda(X_other, X_tr))
            pred = 0 if float(X_own[i] @ w) > thr else 1
            correct += (pred == cls)
            total += 1
    return correct / total if total else 0.0


def train(pair=None, save: bool = True) -> dict:
    pair = pair if pair is not None else PAIR
    if pair is None:
        raise ValueError("Configure local identity pairs before training")
    pair = tuple(pair)
    if save and pair not in MODEL_PATHS:
        raise ValueError("Configure a local model path before saving")
    s0, s1, stats = collect_samples(pair)
    if len(s0) < 3 or len(s1) < 3:
        return {"pair": list(pair), "n_samples": {pair[0]: len(s0), pair[1]: len(s1)},
                "loo_accuracy": 0.0, "skip": "样本不足(<3)"}
    X0, X1 = np.stack(s0), np.stack(s1)
    w, thr = fit_lda(X0, X1)
    p0, p1 = X0 @ w, X1 @ w
    acc = loo_accuracy(X0, X1)
    overlap = (float((p0 <= thr).sum()) + float((p1 > thr).sum())) / (len(p0) + len(p1))
    report = {
        "pair": list(pair), "n_samples": {pair[0]: len(s0), pair[1]: len(s1)},
        "sources": {n: stats[n] for n in pair},
        "conflicts_dropped": stats["conflicts_dropped"],
        "threshold": round(thr, 6), "train_overlap": round(overlap, 4),
        "loo_accuracy": round(acc, 4),
    }
    if save:
        MODEL_PATHS[pair].write_text(json.dumps({
            "pair": list(pair), "w": [round(float(x), 6) for x in w],
            "threshold": report["threshold"], "n_samples": report["n_samples"],
            "loo_accuracy": report["loo_accuracy"], "shrinkage": SHRINKAGE,
            "note": f"proj = w·emb(l2)，proj>threshold 判「{pair[0]}」，否则「{pair[1]}」",
        }, ensure_ascii=False, indent=1), encoding="utf-8")
    return report


def train_all(save: bool = True) -> list:
    reports = []
    for pair in PAIRS:
        r = train(pair, save=save)
        reports.append(r)
    return reports


def load_model(pair=None):
    """返回 (pair, w, threshold) 或 None（模型不存在/LOO 不合格）。"""
    pair = pair if pair is not None else PAIR
    if pair is None:
        return None
    path = MODEL_PATHS.get(tuple(pair))
    if not path or not path.exists():
        return None
    m = json.loads(path.read_text(encoding="utf-8"))
    if m.get("loo_accuracy", 0) < MIN_LOO:
        return None
    w = np.asarray(m["w"], dtype=np.float64)
    threshold = float(m["threshold"])
    if tuple(m["pair"]) != tuple(pair) or w.ndim != 1 or w.size == 0 or not np.isfinite(w).all() or not np.isfinite(threshold):
        return None
    return tuple(m["pair"]), w, threshold


_MODELS = None


def load_all(force: bool = False) -> dict:
    """{frozenset(pair): (pair, w, thr)}，只含 LOO 合格的。缓存。"""
    global _MODELS
    if _MODELS is None or force:
        _MODELS = {}
        for pair in PAIRS:
            m = load_model(pair)
            if m:
                _MODELS[frozenset(pair)] = m
    return _MODELS


def lda_predict(pair, w: np.ndarray, thr: float, emb_l2: np.ndarray) -> str:
    return pair[0] if float(_l2(emb_l2) @ w) > thr else pair[1]


def resolve(emb, n1: str, n2: str, models=None):
    """top-2 候选恰是某已训练混淆对 → 用该对 LDA 判，返回胜者名；否则 None。"""
    models = models if models is not None else load_all()
    m = models.get(frozenset((n1, n2)))
    if not m:
        return None
    pair, w, thr = m
    return lda_predict(pair, w, thr, emb)


def backtest(pair, w: np.ndarray, thr: float) -> None:
    reg = json.loads(REGISTRY.read_text(encoding="utf-8"))
    people = {}
    for name, p in reg.get("people", {}).items():
        vecs = p.get("embs") or p.get("embeddings") or []
        if vecs:
            people[name] = [_l2(v) for v in vecs]
    n_confuse = n_flip = 0
    for sj in sorted(ART.glob("*/*.speakers.json")):
        mid = sj.parent.name
        try:
            data = json.loads(sj.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        for spk, v in data.items():
            emb = (v or {}).get("emb")
            if not emb:
                continue
            e = _l2(emb)
            scores = sorted(((n, max(float(e @ x) for x in vs)) for n, vs in people.items()),
                            key=lambda t: -t[1])
            (n1, s1), (n2, s2) = scores[0], scores[1]
            if {n1, n2} != set(pair) or s1 - s2 >= EASY_CONFUSE_GAP or s1 < 0.50:
                continue
            n_confuse += 1
            if lda_predict(pair, w, thr, e) != n1:
                n_flip += 1
    print(f"  {pair[0]}×{pair[1]}: 易混簇 {n_confuse} 个，LDA 与 cos-top1 不一致 {n_flip} 个")


if __name__ == "__main__":
    for r in train_all(save=True):
        p = r["pair"]
        flag = "✓上线" if r.get("loo_accuracy", 0) >= MIN_LOO else "✗ 不上线(样本不够/分不开)"
        print(f"[{p[0]}×{p[1]}] 样本 {r['n_samples']} · LOO {r.get('loo_accuracy')} · {r.get('skip','')} {flag}")
    if "--backtest" in sys.argv:
        print("\n回测：")
        for pair in PAIRS:
            m = load_model(pair)
            if m:
                backtest(m[0], m[1], m[2])

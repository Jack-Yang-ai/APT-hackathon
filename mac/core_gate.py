"""Generic implementation; local private materials are not distributed."""















from __future__ import annotations

import os

CORE_DEFAULT = ()  # Explicit operator configuration required.
STRICT_MIN = 0.70    # 自动落定的严阈值（提名阈 0.62 只配 suggestion）
MARGIN = 0.08        # top1-top2 分差低于此=易混区（与 pair_lda.EASY_CONFUSE_GAP 同款）
MIN_SEC = 10.0       # 簇总发言时长门槛（秒）


def core_set() -> set[str]:
    env = os.environ.get("GROWTH_CORE_SPEAKERS", "")
    if env.strip():
        return {n.strip() for n in env.split(",") if n.strip()}
    return set(CORE_DEFAULT)


def _rank(emb, reg: dict):
    """emb 对底库每人取模板 max cos，降序 [(name,score),...]，至少补到 2 项。"""
    import numpy as np
    v = np.asarray(emb, np.float32)
    n = np.linalg.norm(v)
    v = v / n if n > 0 else v
    scores = []
    for name, rec in reg.get("people", {}).items():
        best = 0.0
        for e in rec.get("embeddings", []) or rec.get("embs", []):
            t = np.asarray(e, np.float32)
            tn = np.linalg.norm(t)
            s = float(v @ (t / tn if tn > 0 else t))
            if s > best:
                best = s
        if best > 0:
            scores.append((name, round(best, 3)))
    scores.sort(key=lambda t: -t[1])
    while len(scores) < 2:
        scores.append((None, 0.0))
    return scores


def decide(embs: dict, seconds: dict, reg: dict, near_rel: dict | None = None) -> dict:
    """{簇: emb} + {簇: 总时长s} + 底库 → {簇: {name, score, runner_up, via}}（只含放行的）。
    near_rel：{簇: 近场相对分}（簇能量中位−全录音P90，见 line_embs.rel_db）——佩戴者=近场，
    「我」的落定必须过能量关：明显远场（< NEAR_FAR_VETO）直接否决，声纹分再高也不行。
    任何依赖缺失（numpy/LDA 模型）都按「闸不过」处理，绝不放行。"""
    core = core_set()
    out = {}
    try:
        import numpy as np  # noqa: F401
        from shared import pair_lda
        from memory.line_embs import NEAR_FAR_VETO
        models = pair_lda.load_all()
    except Exception:  # noqa: BLE001
        return out
    for spk, emb in embs.items():
        if not emb or seconds.get(spk, 0.0) < MIN_SEC:
            continue
        rank = _rank(emb, reg)
        (n1, s1), (n2, s2) = rank[0], rank[1]
        if n1 not in core or s1 < STRICT_MIN:
            continue
        if n1 == "我" and near_rel:
            rd = near_rel.get(spk)
            if rd is not None and rd < NEAR_FAR_VETO:   # 远场人声冒充佩戴者 → 否决
                continue
        via = "strict+margin"
        if n2 and s1 - s2 < MARGIN:
            try:
                winner = pair_lda.resolve(np.asarray(emb, np.float32), n1, n2, models)
            except Exception:  # noqa: BLE001
                winner = None
            if winner != n1:      # 无该对模型(None)或判负 → 匿名
                continue
            via = f"strict+lda({n2})"
        out[spk] = {"name": n1, "score": s1, "runner_up": [n2, s2], "via": via}
    return out

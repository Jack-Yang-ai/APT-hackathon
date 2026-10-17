#!/usr/bin/env python3
"""声纹重配应用：用底库（vault 软链）重配所有已存簇嵌入 → 高置信的归并进记忆库。

不重跑 diarization/embedding——meeting_artifacts/*/<mid>.speakers.json 里的簇嵌入是现成的，
纯矩阵运算 + merge_entities。阈值沿用管线 0.62；0.50~0.62 边缘区只报告不动手（人工确认门）。

CLI：python3 -m memory.vp_rematch [--dry] [--threshold 0.62]
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from shared import db as store  # 判 7：新仓只保留路径/连接层，三层表 API 已退役
from shared import pair_lda  # noqa: E402  # 路线③：我×人物甲 成对 LDA 复核

ART = store.ROOT / "data" / "meeting_artifacts"
REGISTRY = store.ROOT / "ingest" / "meeting" / "voiceprints" / "registry.json"  # 软链→vault


def _l2(v):
    v = np.asarray(v, dtype=np.float32)
    return v / (np.linalg.norm(v) + 1e-9)


class ASNorm:
    """自适应分数归一化（AS-Norm）：裸余弦在不同声学场景下含义漂移（远场整体缩水），
    改看「相对陪衬群体的偏离度」。cohort=全库簇嵌入（排除同录音的——同场景声学+同人风险），
    对每个 trial 取 top-K 陪衬分数算 μ/σ，s-norm 对称平均。z≈「比最像的一批陌生人像多少个标准差」。"""

    def __init__(self, cohort: list[tuple[str, np.ndarray]], top_k: int = 50):
        self.mids = [m for m, _ in cohort]
        self.mat = np.stack([e for _, e in cohort]) if cohort else np.zeros((0, 1))
        self.top_k = top_k

    def _stats(self, emb: np.ndarray, exclude_mid: str):
        mask = np.array([m != exclude_mid for m in self.mids])
        if mask.sum() < 10:
            return None
        scores = self.mat[mask] @ emb
        top = np.sort(scores)[-self.top_k:]
        return float(top.mean()), float(top.std() + 1e-6)

    def z(self, e1: np.ndarray, mid1: str, e2: np.ndarray, mid2: str) -> float | None:
        s = float(np.dot(e1, e2))
        st1, st2 = self._stats(e1, mid1), self._stats(e2, mid2)
        if not st1 or not st2:
            return None
        return 0.5 * ((s - st1[0]) / st1[1] + (s - st2[0]) / st2[1])









DELTA_SPLIT = 2.0








def _core() -> set:
    from shared.legacy_stubs import promote
    return promote.WORK_CIRCLE | promote.LIFE_CIRCLE


def _stats_cache(asn: ASNorm):
    """(emb_id, exclude_mid) → (μ, σ)。669 簇 × 73 模板 = 4.9 万次 z，不缓存会算到天荒地老。"""
    cache = {}

    def get(e: np.ndarray, mid: str, tag):
        k = (tag, mid)
        if k not in cache:
            cache[k] = asn._stats(e, mid)
        return cache[k]
    return get


def rematch(threshold: float = 0.62, dry: bool = False,
            delta_split: float = DELTA_SPLIT) -> dict:
    """Generic implementation; local private materials are not distributed."""














    reg = json.loads(REGISTRY.read_text(encoding="utf-8"))
    people = {}
    for name, p in reg.get("people", {}).items():
        vecs = p.get("embs") or p.get("embeddings") or []
        if vecs:
            people[name] = [_l2(v) for v in vecs]

    links_path = store.ROOT / "data" / "cannot_links.json"
    links = json.loads(links_path.read_text()) if links_path.exists() else {}
    mixed_path = store.ROOT / "data" / "mixed_clusters.json"
    mixed = set(json.loads(mixed_path.read_text())) if mixed_path.exists() else set()




    lda = pair_lda.load_model()  # (pair, w, threshold) | None
    CORE = _core()

    embs = _all_cluster_embs()                       # {key: (mid, emb)}
    asn = ASNorm(list(embs.values()))
    stats = _stats_cache(asn)

    tpl_mid = {}
    for key, (mid, e) in embs.items():
        for n, vs in people.items():
            for i, v in enumerate(vs):
                if float(np.dot(e, v)) > 0.999:
                    tpl_mid[(n, i)] = mid

    def _z(key, name):
        """该簇对 name 全部模板的最佳 z（与 max(dot) 同口径，只是换了尺子）。"""
        mid, e = embs[key]
        best = None
        s1 = stats(e, mid, key)          # 缓存键用簇键，别用 id()——对象地址会被回收复用
        if s1 is None:
            return None
        for i, v in enumerate(people[name]):
            tm = tpl_mid.get((name, i), "__none__")
            s2 = stats(v, tm, (name, i))
            if s2 is None:
                continue
            s = float(np.dot(e, v))
            z = 0.5 * ((s - s1[0]) / s1[1] + (s - s2[0]) / s2[1])
            best = z if best is None else max(best, z)
        return best

    by_mid = {}
    for key, (mid, _e) in embs.items():
        by_mid.setdefault(mid, []).append(key)

    applied, assign, edge, miss, splits, stolen = [], [], [], 0, [], []
    con = store.connect()
    try:
        for mid in sorted(by_mid):
            date, topic = mid[:10], mid[11:]

            cands = []
            for key in by_mid[mid]:
                e = embs[key][1]
                spk0 = key.rsplit("·", 1)[1]
                ranked = sorted(((n, max(float(np.dot(e, x)) for x in vs))
                                 for n, vs in people.items()), key=lambda t: -t[1])
                name, score = ranked[0]
                if score < 0.50:
                    miss += 1
                    continue




                if name not in CORE:
                    near = [(n, s) for n, s in ranked if n in CORE and score - s < 0.08]
                    if near:
                        name, score = near[0]
                        stolen.append((mid, spk0, ranked[0][0], round(ranked[0][1], 3),
                                       name, round(score, 3)))
                if lda and len(ranked) > 1 and {ranked[0][0], ranked[1][0]} == set(lda[0]) \
                        and score - ranked[1][1] < 0.08:
                    lda_name = pair_lda.lda_predict(lda[0], lda[1], lda[2], e)
                    if lda_name != name:
                        edge.append((mid, spk0, f"{name}(LDA复核→{lda_name})", round(score, 3)))
                        continue
                if score < threshold:
                    edge.append((mid, spk0, name, round(score, 3)))
                    continue
                if key in mixed:
                    continue  # 隔离簇永不自动归并
                z = _z(key, name)
                cands.append((z if z is not None else -9e9, round(score, 3), key, spk0, name))



            cands.sort(key=lambda t: (t[4] not in CORE, -t[0], t[2]))
            taken: dict[str, list[str]] = {}
            for z, score, key, spk0, name in cands:
                if name in taken:

                    others = taken[name]
                    sims = [float(np.dot(embs[key][1], embs[f"{mid}·{o}"][1])) for o in others]
                    talked = any(sorted((spk0, o)) == sorted((a, b))
                                 for a, b, _ in links.get(mid, []) for o in others)
                    if sims and min(sims) >= delta_split and not talked:
                        splits.append((mid, spk0, others[:], name, round(min(sims), 3)))
                        print(f"  ⧉ 过切合并 {mid}·{spk0} 与 {others} 同为「{name}」"
                              f"（互相 {min(sims):.3f} ≥ {delta_split}）")
                    else:
                        why = "同录音对过话" if talked else f"互相只有 {max(sims):.3f}"
                        edge.append((mid, spk0, f"{name}(本段已被认领·{why})", score))
                        continue

                partners = set(taken.get(name, []))
                row = con.execute("SELECT aliases FROM entities WHERE kind='person' AND name=?",
                                  (name,)).fetchone()
                for al in json.loads((row and row[0]) or "[]"):
                    if al.startswith(f"{date}-{topic}·"):
                        partners.add(al.rsplit("·", 1)[1])
                blocked = any(sorted((spk0, q)) == sorted((a, b))
                              for a, b, _ in links.get(mid, []) for q in partners)
                if blocked:
                    edge.append((mid, spk0, f"{name}(cannot-link拦截)", score))
                    continue
                taken.setdefault(name, []).append(spk0)
                ent = f"{date}-{topic}·{spk0}"



                assign.append((ent, name, score, round(z, 2)))
                src = con.execute("SELECT id FROM entities WHERE kind='person' AND name=?",
                                  (ent,)).fetchone()
                if not src:
                    continue  # 该簇没进过原子/事件（或已被历史归并吃掉）
                if not dry:
                    store.merge_entities(con, store.upsert_person(con, name), src[0])
                applied.append((ent, name, score, round(z, 2)))
        if not dry:
            con.commit()
    finally:
        con.close()
    for ent, name, s, z in applied:
        print(f"  ✓ {ent} → {name} (cos={s} z={z})")
    print(f"判决 {len(assign)} 簇归人（其中簇实体还在、真去归并的 {len(applied)} 个）；"
          f"边缘区（含本段让位，待人工）{len(edge)} 个；过切合并放行 {len(splits)} 次；"
          f"核心圈优先改判 {len(stolen)} 簇；底库最像也 <0.50 的 {miss} 簇")
    return {"applied": len(applied), "edge": edge, "splits": splits,
            "assign": assign, "core_pref": stolen}


def _all_cluster_embs() -> dict:
    """{code_entity: (mid, emb)}——全库簇嵌入。"""
    out = {}
    for sj in sorted(ART.glob("*/*.speakers.json")):
        mid = sj.parent.name
        try:
            data = json.loads(sj.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        for spk, v in data.items():
            emb = (v or {}).get("emb")
            if emb:
                out[f"{mid}·{spk.rstrip('?')}"] = (mid, _l2(emb))
    return out


def calibrate(assignments: Path) -> None:
    """用人工认定当金标准，报告 裸余弦 vs AS-Norm z 的真/假配对分离度。"""
    gmap = json.loads((store.ROOT / "data" / "speaker_groups_map.json").read_text())
    codes = json.loads((store.ROOT / "data" / "speaker_codes.json").read_text())
    assign = json.loads(assignments.read_text(encoding="utf-8"))
    embs = _all_cluster_embs()
    label = {}  # cluster_key -> person
    for gid, name in assign.items():
        if name.startswith("__"):
            continue
        for code in gmap.get(gid, []):
            ent = codes.get(code)
            if ent and ent.replace("·", "·") in embs or ent in embs:
                label[ent] = name
    keys = [k for k in label if k in embs]
    asn = ASNorm(list(embs.values()))
    true_raw, true_z, imp_raw, imp_z = [], [], [], []
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            a, b = keys[i], keys[j]
            (m1, e1), (m2, e2) = embs[a], embs[b]
            if m1 == m2:
                continue  # 同录音对不参与（cannot-link 的领地）
            raw = float(np.dot(e1, e2))
            z = asn.z(e1, m1, e2, m2)
            if z is None:
                continue
            (true_raw if label[a] == label[b] else imp_raw).append(raw)
            (true_z if label[a] == label[b] else imp_z).append(z)
    def pct(v, q):  # noqa: E306
        return round(float(np.percentile(v, q)), 3) if v else None
    print(f"标定集：真配对 {len(true_raw)} 对 / 假配对 {len(imp_raw)} 对（跨录音）")
    print(f"裸余弦   真配对 p10/p50={pct(true_raw,10)}/{pct(true_raw,50)}   "
          f"假配对 p90/p99={pct(imp_raw,90)}/{pct(imp_raw,99)}")
    print(f"AS-Norm z 真配对 p10/p50={pct(true_z,10)}/{pct(true_z,50)}   "
          f"假配对 p90/p99={pct(imp_z,90)}/{pct(imp_z,99)}")
    if true_z and imp_z:
        gap_raw = (pct(true_raw, 10) or 0) - (pct(imp_raw, 90) or 0)
        gap_z = (pct(true_z, 10) or 0) - (pct(imp_z, 90) or 0)
        print(f"分离带宽（真p10 - 假p90）：裸余弦 {gap_raw:.3f} vs AS-Norm {gap_z:.3f}")
        thr = round((pct(true_z, 10) + pct(imp_z, 99)) / 2, 2)
        print(f"建议 z 阈值（真p10 与 假p99 中点）：{thr}")


if __name__ == "__main__":
    if "--calibrate" in sys.argv:
        calibrate(Path(sys.argv[sys.argv.index("--calibrate") + 1]))
        raise SystemExit(0)
    th = 0.62
    if "--threshold" in sys.argv:
        th = float(sys.argv[sys.argv.index("--threshold") + 1])
    rematch(th, dry="--dry" in sys.argv)

#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""























from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np





TAU = 0.3


MIN_SEGMENTS = 2
MIN_VOTE_RATIO = 2.0 / 3.0




TAU_EPSILON = 1e-6











REVIEW_K = 3


TNORM_TOPK = 40


TNORM_MIN_COHORT = 10

CLUSTER_LINK = 0.60



SELF_ID = -1





SELF_ACCEPT_Z = 5.17



SELF_ASK_Z = 4.8

SELF_MIN_SEGMENTS = 3


def group_by_upstream(tags: list[str | None]) -> tuple[list[int], dict[int, str]] | None:
    """Generic implementation; local private materials are not distributed."""
















    if not any(t for t in tags):
        return None
    order: dict[str, int] = {}
    labels: list[int] = []
    for i, t in enumerate(tags):


        labels.append(order.setdefault(t if t else f"untagged{i}", len(order)))
    return labels, {v: k for k, v in order.items()}


def cluster_lines(embs: np.ndarray, link: float = CLUSTER_LINK) -> list[int]:
    """平均链接凝聚聚类 → 每行一个簇号(0..K-1,按首行出现序)。O(n³) 够用:
    一场几百行,毫秒级。"""
    n = embs.shape[0]
    groups: list[list[int]] = [[i] for i in range(n)]
    sim = embs @ embs.T
    while len(groups) > 1:
        best, bi, bj = -1.0, -1, -1
        for i in range(len(groups)):
            for j in range(i + 1, len(groups)):
                s = float(np.mean(sim[np.ix_(groups[i], groups[j])]))
                if s > best:
                    best, bi, bj = s, i, j
        if best < link:
            break
        groups[bi] += groups.pop(bj)
    labels = [0] * n
    for k, g in enumerate(sorted(groups, key=min)):
        for i in g:
            labels[i] = k
    return labels


@dataclass
class Comparison:
    """一次判决用的比较集。冒充集**必须已按 §2.5 剔除**登记同人 ——
    剔除在装配层做(`load_comparison`),这里只消费。"""
    registry: dict[int, np.ndarray]        # person_id → (k, d) 模板
    anonymous: dict[int, np.ndarray]       # 匿名人格 person_id → (k, d)
    cohort: np.ndarray                     # (m, d) 冒充质心(已剔除)

    def tnorm_stats(self) -> dict[int, tuple[np.ndarray, np.ndarray]]:
        """每个候选矩阵的**逐模板** μ/σ(拿冒充集算)。**算一次缓存住** ——
        一场几十上百段,每段重算一遍是纯浪费。"""
        if getattr(self, "_tn", None) is not None:
            return self._tn
        m = len(self.cohort)
        if m < TNORM_MIN_COHORT:
            raise RuntimeError(
                f"冒充集只有 {m} 条(要 ≥{TNORM_MIN_COHORT})—— T-norm 算不了,"
                f"而退回裸余弦会让 τ 失去意义。先自建冒充集（见公开源码范围说明）")
        k = min(TNORM_TOPK, m)
        out: dict[int, tuple[np.ndarray, np.ndarray]] = {}
        for _, mat in self.candidates():
            M = np.atleast_2d(mat)
            s = np.sort(M @ self.cohort.T, axis=1)[:, -k:]
            out[id(mat)] = (s.mean(axis=1), s.std(axis=1) + 1e-6)
        object.__setattr__(self, "_tn", out)
        return out

    def candidates(self) -> list[tuple[int | None, np.ndarray]]:
        out: list[tuple[int | None, np.ndarray]] = []
        out += [(pid, m) for pid, m in sorted(self.registry.items())]
        out += [(pid, m) for pid, m in sorted(self.anonymous.items())]
        if self.cohort.size:
            out.append((None, self.cohort))    # None = 冒充集,永远不给名字
        return out


@dataclass
class SegmentVote:
    person_id: int | None      # None = 这一段的 top1 是冒充集(=拒识票)
    score: float
    runner_up: float

    @property
    def margin(self) -> float:
        return self.score - self.runner_up


def score_segment(v: np.ndarray, cmp: Comparison) -> SegmentVote:
    """Generic implementation; local private materials are not distributed."""






















    stats = cmp.tnorm_stats()
    scored = [(pid, float(np.max((np.atleast_2d(m) @ v - stats[id(m)][0]) / stats[id(m)][1])))
              for pid, m in cmp.candidates()]
    scored.sort(key=lambda x: x[1], reverse=True)
    top = scored[0]
    runner = scored[1][1] if len(scored) > 1 else -1.0
    return SegmentVote(person_id=top[0], score=top[1], runner_up=runner)


@dataclass
class ClusterVerdict:
    kind: str                  # "person" | "anonymous_candidate" | "rejected"
    person_id: int | None = None
    votes: int = 0
    of: int = 0
    why: str = ""
    centroid: list[float] = field(default_factory=list)













    candidate_person_id: int | None = None


    review: list[tuple[int, float]] = field(default_factory=list)


def review_candidates(embs: np.ndarray, cmp: Comparison,
                      person_id: int | None, k: int = REVIEW_K) -> list[tuple[int, float]]:
    """簇里与 `person_id` **最不像**的 k 段(簇内序号 + 相似度),用于二次确认。

    判定人不在登记集里(匿名人格 / 没判出来)⇒ 空:没有参照就没有「掉队」可言,
    那种情况该走的是「新人听 3 句」,不是这条。
    """
    m = cmp.registry.get(person_id) if person_id is not None else None
    if m is None or not len(m):
        return []
    s = (embs @ m.T).max(axis=1)
    return [(int(i), round(float(s[i]), 4)) for i in np.argsort(s)[:k]]


def judge_two_stage(embs: np.ndarray, cmp: Comparison) -> ClusterVerdict:
    """Generic implementation; local private materials are not distributed."""


























    def with_review(v: ClusterVerdict) -> ClusterVerdict:




        v.review = review_candidates(embs, cmp, v.person_id or v.candidate_person_id)
        return v

    named_only = Comparison(registry=cmp.registry, anonymous={}, cohort=cmp.cohort)
    first = judge_cluster([score_segment(v, named_only) for v in embs], embs)
    if first.kind == "person":
        return with_review(first)
    if not cmp.anonymous:
        return with_review(first)


    second = judge_cluster([score_segment(v, cmp) for v in embs], embs)
    if second.kind == "person":
        return with_review(second)



    return with_review(first)


def judge_cluster(votes: list[SegmentVote], embs: np.ndarray) -> ClusterVerdict:
    """一簇一判。语义照 SpeakerMatch.judge:
    · 差距 ≥ τ **且 top1 不是冒充集**的段才有投票权;
    · 票不够/段不够 ⇒ 不给身份 —— 但**不是丢弃**:整簇成为匿名人格候选
      (方案 §四第二层,内容照挂「声音A」,这正是与旧链不同的地方)。"""
    c = embs.mean(axis=0)
    c = (c / max(float(np.linalg.norm(c)), 1e-12)).astype(float)
    centroid = [round(float(x), 6) for x in c]

    def anon(why: str) -> ClusterVerdict:
        return ClusterVerdict(kind="anonymous_candidate", of=len(votes),
                              why=why, centroid=centroid)
























    passing = [v for v in votes
               if v.person_id is not None and v.score > 0
               and v.margin + TAU_EPSILON >= TAU]
    if not passing:
        best = max(votes, key=lambda v: v.margin)
        return anon(f"没有一段拉开差距(最好 {best.score:.3f}−{best.runner_up:.3f}"
                    f"={best.margin:.3f} < τ {TAU})")











    if len(passing) < MIN_SEGMENTS and len(votes) > 1:
        v = anon(f"只有 {len(passing)} 段拉开了差距,不够判(至少 {MIN_SEGMENTS};"
                 f"全簇 {len(votes)} 段)")

        only = max(set(x.person_id for x in passing),
                   key=lambda p: max(x.score for x in passing if x.person_id == p))
        v.candidate_person_id = only
        v.votes = sum(1 for x in passing if x.person_id == only)
        v.of = len(passing)
        return v
    tally: dict[int, int] = {}
    for v in passing:
        tally[v.person_id] = tally.get(v.person_id, 0) + 1

    winner = max(tally, key=lambda p: (tally[p],
                                       max(v.score for v in passing if v.person_id == p)))















    ratio = tally[winner] / len(passing)
    if ratio < MIN_VOTE_RATIO:


        v = anon(f"票不够:{tally[winner]}/{len(passing)} 张有效票"
                 f"(要 {MIN_VOTE_RATIO:.0%};全簇 {len(votes)} 段)")
        v.candidate_person_id = winner
        v.votes = tally[winner]


        v.of = len(passing)
        return v
    return ClusterVerdict(kind="person", person_id=winner,
                          votes=tally[winner], of=len(passing), centroid=centroid)


def judge_self(embs: np.ndarray, me: np.ndarray, cohort: np.ndarray) -> ClusterVerdict:
    """Generic implementation; local private materials are not distributed."""


















    arrays = []
    for label, value in (("查询", embs), ("本人模板", me), ("冒充集", cohort)):
        a = np.asarray(value, dtype=float)
        if a.ndim != 2 or not a.shape[0] or not a.shape[1] or not np.isfinite(a).all():
            raise ValueError(f"{label}必须是非空、有限的二维向量矩阵")
        norms = np.linalg.norm(a, axis=1, keepdims=True)
        if not np.isfinite(norms).all() or (norms <= 1e-12).any():
            raise ValueError(f"{label}包含零向量或无效模长")
        arrays.append(a / norms)
    embs, me, cohort = arrays
    if len({a.shape[1] for a in arrays}) != 1:
        raise ValueError("查询、本人模板和冒充集不在同一维度")
    c = embs.mean(axis=0)
    c = (c / max(float(np.linalg.norm(c)), 1e-12)).astype(float)
    centroid = [round(float(x), 6) for x in c]
    cmp = Comparison(registry={SELF_ID: me}, anonymous={}, cohort=cohort)
    mu, sd = cmp.tnorm_stats()[id(me)]
    z = (((np.atleast_2d(embs) @ me.T) - mu) / sd).max(axis=1)
    med = float(np.median(z))
    over = int((z >= SELF_ACCEPT_Z).sum())

    if med >= SELF_ACCEPT_Z and len(z) >= SELF_MIN_SEGMENTS:
        return ClusterVerdict(kind="person", person_id=SELF_ID, votes=over, of=len(z),
                              centroid=centroid,
                              review=review_candidates(embs, cmp, SELF_ID))
    if med >= SELF_ASK_Z:
        top = np.argsort(-z)[:REVIEW_K]
        return ClusterVerdict(kind="rejected", candidate_person_id=SELF_ID,
                              votes=over, of=len(z), centroid=centroid,
                              why=(f"只有 {len(z)} 段,不足 {SELF_MIN_SEGMENTS} 段,要用户确认"
                                   if len(z) < SELF_MIN_SEGMENTS
                                   else f"拿不准:中位 z {med:.2f} 在 [{SELF_ASK_Z}, {SELF_ACCEPT_Z}) 之间"),
                              review=[(int(i), round(float(z[i]), 4)) for i in top])
    return ClusterVerdict(kind="rejected", of=len(z), centroid=centroid,
                          why=f"不是我:中位 z {med:.2f} < {SELF_ASK_Z}")

#!/usr/bin/env python3
"""条目级去重的阈值:抽候选对 → 人工标 → 拟合分界。`M2-检2` §1.4。

    python3 eval/near_dup_label.py sample --n 200      # 分层抽候选对,写 data/
    python3 eval/near_dup_label.py label               # 逐对问「同一件事吗」
    python3 eval/near_dup_label.py fit                 # 出分界、误折数、漏折数

## 为什么不能直接抄行级那组参数

`ios/GrowthApp/Database/NearDuplicate.swift` 的 2 字组 / 0.55 是在**转写行**
(短句)上量出来的。条目文本更长,而**共享前缀越长,一个「不」字被稀释得越厉害** ——
现行参数在长句上已经会把意思相反的两条折成一条(见 `docs/evidence/m2-检2/near_dup.md`)。

⇒ 参数是「同库有效」的(检索方案 §3.10),换了文本形态必须重测。

## 为什么要人工标,不用模型标

判分的尺子不许是被判的那个东西。而且这里要的是**分界**,不是准确率 ——
分界只有在两族(同一件事 / 不同)分别的分数分布上才看得出来,而分布必须来自真值。
(仓规:错题解剖必须先验金标再查系统。)

## 🔴 语料不进版本库

真实原话只在 Mac 上。标注产物 `data/near_dup_pairs.jsonl` 也**不进版本库**
(`data/` 已在 .gitignore 里);进版本库的只有 `docs/evidence/m2-检2/near_dup.md` 里的数。
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from shared.near_duplicate import similarity  # noqa: E402

DEFAULT_DB = os.path.expanduser("~/growth-agent/data/memory.sqlite")
OUT = Path(__file__).resolve().parents[1] / "data" / "near_dup_pairs.jsonl"

#: 条目级文本的来源。`atoms.quote` 是旧仓的条目级对象(原子),
#: 长度与新仓的条目最接近;`episodes.summary` 补一批更长的。
SOURCES = (("atoms", "quote"), ("episodes", "summary"))

#: 分层抽样的相似度分段。**必须覆盖低分段** —— 只抽高分段的话,
#: 「不同的两条能有多像」这一族就没有样本,分界只剩一半。
BANDS = ((0.70, 1.01), (0.55, 0.70), (0.40, 0.55), (0.25, 0.40), (0.00, 0.25))

#: 每条文本最短多少字才参与。太短的对判分界没有信息(几个字的串怎么切都像)。
MIN_CHARS = 12


def load_texts(db_path: str, limit: int = 10000) -> list[str]:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    seen: set[str] = set()
    out: list[str] = []
    for table, column in SOURCES:
        try:
            rows = conn.execute(
                f"SELECT {column} FROM {table} WHERE {column} IS NOT NULL"  # noqa: S608
            ).fetchall()
        except sqlite3.Error:
            continue
        for (text,) in rows:
            t = str(text).strip()
            if len(t) >= MIN_CHARS and t not in seen:
                seen.add(t)
                out.append(t)
    conn.close()
    return out[:limit]


def sample(db_path: str, n: int, gram: int, seed: int) -> int:
    texts = load_texts(db_path)
    if len(texts) < 50:
        print(f"语料只有 {len(texts)} 条,抽不出有意义的对", file=sys.stderr)
        return 2
    rng = random.Random(seed)

    per_band = max(1, n // len(BANDS))
    buckets: dict[tuple[float, float], list[dict]] = {b: [] for b in BANDS}
    seen_pairs: set[tuple[int, int]] = set()

    def offer(i: int, j: int) -> None:
        key = (min(i, j), max(i, j))
        if i == j or key in seen_pairs:
            return
        seen_pairs.add(key)
        s = similarity(texts[i], texts[j], gram)
        for band in BANDS:
            if band[0] <= s < band[1] and len(buckets[band]) < per_band:
                buckets[band].append({"a": texts[i], "b": texts[j], "gram": gram,
                                      "sim": round(s, 4),
                                      "band": f"{band[0]:.2f}-{band[1]:.2f}", "label": None})
                return

    # 🔴 **不能只靠随机撞。** 真的近重复在条目级语料里很稀疏,随机两两抽出来
    # 几乎全落在最低那一段 —— 于是「同一件事」那一族没有样本,分界只剩一半。
    # 所以高相似那几段走**倒排索引找近邻**(标准 blocking),低相似段才随机抽。
    from shared.near_duplicate import grams as _grams
    index: dict[str, list[int]] = {}
    all_grams = [_grams(t, gram) for t in texts]
    for i, gs in enumerate(all_grams):
        for g in gs:
            index.setdefault(g, []).append(i)
    for i, gs in enumerate(all_grams):
        shared: dict[int, int] = {}
        for g in gs:
            posting = index.get(g, ())
            if len(posting) > 200:      # 太常见的元组("的了"这类)不带信息,跳过
                continue
            for j in posting:
                if j != i:
                    shared[j] = shared.get(j, 0) + 1
        # 只看共享元组最多的几个邻居 —— 相似度高的必然在里面。
        for j, _ in sorted(shared.items(), key=lambda kv: -kv[1])[:8]:
            offer(i, j)
        if all(len(buckets[b]) >= per_band for b in BANDS[:3]):
            break

    # 低相似段随机补齐。
    tries = 0
    while tries < n * 500 and any(len(v) < per_band for v in buckets.values()):
        tries += 1
        i, j = rng.randrange(len(texts)), rng.randrange(len(texts))
        offer(i, j)

    pairs = [p for v in buckets.values() for p in v]
    rng.shuffle(pairs)          # 打散:按相似度顺序标会把人锚死在分数上
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as f:
        for p in pairs:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")
    print(f"抽了 {len(pairs)} 对 → {OUT}")
    for band, v in buckets.items():
        short = f"{band[0]:.2f}-{band[1]:.2f}"
        print(f"  {short}: {len(v)}" + ("   ⚠️ 没抽满" if len(v) < per_band else ""))
    print("\n下一步:python3 eval/near_dup_label.py label")
    return 0


def label() -> int:
    if not OUT.exists():
        print(f"还没抽样:{OUT} 不存在", file=sys.stderr)
        return 2
    rows = [json.loads(line) for line in OUT.read_text(encoding="utf-8").splitlines() if line]
    todo = [r for r in rows if r.get("label") is None]
    print(f"共 {len(rows)} 对,待标 {len(todo)} 对。y=同一件事 · n=不同 · s=跳过 · q=存盘退出\n")
    try:
        for i, row in enumerate(rows):
            if row.get("label") is not None:
                continue
            print(f"[{i + 1}/{len(rows)}]")
            print(f"  A  {row['a']}")
            print(f"  B  {row['b']}")
            # 🔴 **不显示相似度分数** —— 看着分数标,标出来的就是那个算法自己的意见,
            # 而我们要的恰恰是独立于它的真值。
            while True:
                answer = input("  同一件事吗 [y/n/s/q] ").strip().lower()
                if answer in ("y", "n", "s", "q"):
                    break
            if answer == "q":
                break
            if answer != "s":
                row["label"] = (answer == "y")
            print()
    finally:
        with OUT.open("w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        done = sum(1 for r in rows if r.get("label") is not None)
        print(f"\n已存盘:{done}/{len(rows)} 标完 → {OUT}")
    return 0


def fit(grams: tuple[int, ...]) -> int:
    if not OUT.exists():
        print(f"还没抽样:{OUT} 不存在", file=sys.stderr)
        return 2
    rows = [json.loads(line) for line in OUT.read_text(encoding="utf-8").splitlines() if line]
    labeled = [r for r in rows if r.get("label") is not None]
    if len(labeled) < 30:
        print(f"只标了 {len(labeled)} 对,不够拟合(要 ≥30,规格要求 ≥200)", file=sys.stderr)
        return 2

    print(f"标注对 {len(labeled)}(同一件事 {sum(1 for r in labeled if r['label'])} · "
          f"不同 {sum(1 for r in labeled if not r['label'])})\n")
    for n in grams:
        same = sorted(similarity(r["a"], r["b"], n) for r in labeled if r["label"])
        diff = sorted(similarity(r["a"], r["b"], n) for r in labeled if not r["label"])
        if not same or not diff:
            print(f"{n} 字组:有一族没有样本,跳过")
            continue
        # 扫所有候选阈值,取「误折 + 漏折」最小的那个;并列时取误折更小的
        # —— **误折比漏折严重得多**(误折是把答案吃掉,漏折只是多几条)。
        best = None
        for cut in sorted({round(s, 4) for s in same + diff} | {0.0, 1.01}):
            false_fold = sum(1 for s in diff if s >= cut)      # 不同的被折 = 误折
            missed = sum(1 for s in same if s < cut)           # 同一件事没折 = 漏折
            score = (false_fold * 3 + missed, false_fold)      # 误折加权 3 倍
            if best is None or score < best[0]:
                best = (score, cut, false_fold, missed)
        _, cut, false_fold, missed = best
        print(f"{n} 字组")
        print(f"  同一件事 分数区间 {same[0]:.3f} – {same[-1]:.3f}(中位 {same[len(same)//2]:.3f})")
        print(f"  不同     分数区间 {diff[0]:.3f} – {diff[-1]:.3f}(中位 {diff[len(diff)//2]:.3f})")
        print(f"  建议阈值 {cut:.3f} → 误折 {false_fold} · 漏折 {missed}")
        overlap = [s for s in diff if s >= min(same)] if same else []
        print(f"  两族重叠区里的「不同」样本 {len(overlap)} 条"
              + ("(重叠越多,单靠阈值越分不开)" if overlap else "(两族分得开)"))
        print()
    print("把结果写进 docs/evidence/m2-检2/near_dup.md,并把选定的阈值登记进 eval/standards。")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sample")
    s.add_argument("--db", default=DEFAULT_DB)
    s.add_argument("--n", type=int, default=200)
    s.add_argument("--gram", type=int, default=2)
    s.add_argument("--seed", type=int, default=0)
    sub.add_parser("label")
    f = sub.add_parser("fit")
    f.add_argument("--grams", default="2,3")
    args = ap.parse_args(argv)

    if args.cmd == "sample":
        if not os.path.exists(args.db):
            print(f"语料不在:{args.db}(它只在 Mac 上,不进版本库)", file=sys.stderr)
            return 2
        return sample(args.db, args.n, args.gram, args.seed)
    if args.cmd == "label":
        return label()
    return fit(tuple(int(x) for x in args.grams.split(",")))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

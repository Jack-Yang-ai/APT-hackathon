#!/usr/bin/env python3
"""五臂评测结果 → 一张宽表 CSV（一行一题、列是各臂判分）。

为什么：逐题明细文档太长不利于横扫。表格里一眼看清「哪题哪些臂对/错」+失败归因。
配 lark-cli sheets +csv-put 直接灌进飞书 sheet。

用法：
  python3 -m memory.eval.results_to_csv --suffix echo32 --questions questions_echo_32.jsonl \\
      [--cause /tmp/echo32_cause.json] --out /tmp/echo32_matrix.csv
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
# A(demo) 臂 2026-07-15 起从横评移除（用户拍板：agent-loop 基线慢且非记忆架构对比重点）。
# 结果文件若仍在也不纳入表；要临时看 A 单独跑 run_eval_echo --arm demo 即可。
ARMS = [("pyramid", "C 我们"), ("mem0", "B mem0"),
        ("tdam", "D TDAM"), ("hindsight", "E Hindsight")]


def load(suffix: str) -> dict:
    out = {}
    for key, _ in ARMS:
        p = HERE / f"results_{key}_{suffix}.jsonl"
        if p.exists():
            out[key] = {json.loads(l)["id"]: json.loads(l)
                        for l in open(p, encoding="utf-8") if l.strip()}
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--suffix", required=True, help="结果文件后缀，如 echo32 / echo10")
    ap.add_argument("--questions", required=True)
    ap.add_argument("--cause", help="失败归因 json（id→归因），可选")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    qs = [json.loads(l) for l in open(HERE / a.questions, encoding="utf-8") if l.strip()]
    res = load(a.suffix)
    cause = json.load(open(a.cause)) if a.cause and Path(a.cause).exists() else {}
    present = [(k, n) for k, n in ARMS if k in res]

    gold_key = lambda q: (q["gold"].get("answer") if isinstance(q["gold"], dict) else q["gold"])

    rows = [["题号", "轴", "问题", "标准答案"] + [n for _, n in present] + ["失败归因"]]
    tally = {k: 0 for k, _ in present}
    for q in qs:
        line = [q["id"], q.get("axis") or q.get("dim") or "", q["question"], gold_key(q) or ""]
        for k, _ in present:
            r = res[k].get(q["id"])
            if r is None:
                line.append("—")
            else:
                line.append("✅" if r["correct"] else "❌")
                if r["correct"]:
                    tally[k] += 1
        line.append(cause.get(q["id"], ""))
        rows.append(line)
    # 汇总行
    rows.append([])
    rows.append(["得分", "", f"共 {len(qs)} 题", ""] + [f"{tally[k]}/{len(qs)}" for k, _ in present] + [""])

    with open(a.out, "w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows(rows)
    print(f"✓ 写出 {a.out}：{len(qs)} 题 × {len(present)} 臂")
    print("得分：" + " · ".join(f"{n} {tally[k]}/{len(qs)}" for k, n in present))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

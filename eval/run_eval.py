#!/usr/bin/env python3
"""考卷跑分器：同一套题，喂给某个「臂」，四指标出分。

臂（--arm）：
  demo    现有 agent 原样 = server.agent_loop.run_turn（自带 recall_day/slice_transcript/
          search_memory 全套工具）。这是诚实的 A 臂基线——不是另写的弱化检索。
  （mem0 / pyramid 臂后续注册进 ARMS，同卷同判。）

四指标：
  correct       LLM judge 对照金标准答案判对错
  evidence_hit  回答是否踩中金标准证据（防"答对了但是编的"）
  tokens        读 data/usage.jsonl 增量（复用 model_router 内置记账，不自己记）
  latency_s     wall clock

CLI：python3 -m memory.eval.run_eval --arm demo [--questions questions_draft.jsonl] [--limit 5]
"""
from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from shared import model_router  # noqa: E402
from memory.ingest_meeting import _parse_json_array  # noqa: E402

model_router.load_secrets()
HERE = Path(__file__).resolve().parent
USAGE = Path(__file__).resolve().parents[2] / "data" / "usage.jsonl"

_JUDGE_SYS = "你是严格的阅卷人。只输出一个 JSON 对象，不要解释、不要代码围栏。"
_JUDGE = """问题：{question}
标准答案：{answer}
金标准证据（原话）：
{evidence}

考生回答：
{reply}

判两项，输出 JSON：
- correct: true/false —— 回答与标准答案在事实上一致（表述不同没关系；答错、答不出、含糊其辞都算 false）
- evidence_hit: true/false —— 回答中是否体现了金标准证据的实质内容（引用原话或复述其事实；
  只给出正确结论但内容与证据对不上的，算 false）
- reason: 一句话理由

JSON："""


def _arm_demo(question: str) -> str:
    from server.agent_loop import run_turn
    r = run_turn(question, persist=False)
    return r.get("reply", "")


def _arm_pyramid(question: str) -> str:
    # RECALL_V5=1 走 v5 定位精读管线（docs/read-side-v5-plan.md），默认走现状 answer()
    import os as _os
    if _os.environ.get("RECALL_V5") == "1":
        from memory.recall2 import answer_v5
        return answer_v5(question)
    from memory.recall2 import answer
    return answer(question)


def _arm_mem0(question: str) -> str:
    from memory.eval.arm_mem0 import answer
    return answer(question)


def _arm_tdam(question: str) -> str:
    from memory.eval.arm_tdam import answer
    return answer(question)


def _arm_hindsight(question: str) -> str:
    from memory.eval.arm_hindsight import answer
    return answer(question)


def _arm_agentic(question: str) -> str:
    # G 臂：Omi 式工具循环读侧（memory/eval/arm_agentic.py，2026-08-04 对照实验）
    from memory.eval.arm_agentic import answer
    return answer(question)


def _arm_l0raw(question: str) -> str:
    # H 臂：只建索引+读原文（写侧零 LLM 的成本下限对照，2026-08-04 成本拆解）
    from memory.eval.arm_l0raw import answer
    return answer(question)


ARMS = {"demo": _arm_demo, "pyramid": _arm_pyramid, "mem0": _arm_mem0,
        "tdam": _arm_tdam, "hindsight": _arm_hindsight, "agentic": _arm_agentic,
        "l0raw": _arm_l0raw}


def _usage_lines() -> int:
    try:
        return sum(1 for _ in open(USAGE, encoding="utf-8"))
    except FileNotFoundError:
        return 0


def _usage_tokens_since(n0: int) -> int:
    """usage.jsonl 第 n0 行之后的 input+output 总 token（含缓存读）。"""
    tot = 0
    try:
        with open(USAGE, encoding="utf-8") as f:
            for i, ln in enumerate(f):
                if i < n0:
                    continue
                try:
                    u = json.loads(ln)
                    tot += (u.get("input") or 0) + (u.get("output") or 0) + (u.get("cache_read") or 0)
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        pass
    return tot


def judge(q: dict, reply: str) -> dict:
    ev = "\n".join(f'- [{e.get("file","?")} {e.get("ts","?")}] {e.get("quote","")}'
                   for e in q["gold"]["evidence"])
    last_err = "judge 失败"
    for _attempt in range(3):
        try:
            raw = model_router.call(_JUDGE.format(question=q["question"], answer=q["gold"]["answer"],
                                                  evidence=ev, reply=reply or "（空回答）"),
                                    _JUDGE_SYS, scene="judge", max_tokens=8000)
        except Exception as e:  # noqa: BLE001
            last_err = f"judge 调用失败: {e}"
            continue
        m = re.search(r"\{.*\}", raw, re.S)
        if not m:
            last_err = "judge 输出无 JSON"
            continue
        try:
            j = json.loads(m.group(0))
        except json.JSONDecodeError:
            last_err = "judge JSON 解析失败"
            continue
        if "correct" not in j:
            last_err = "judge JSON 缺 correct 字段"
            continue
        return {"correct": bool(j.get("correct")), "evidence_hit": bool(j.get("evidence_hit")),
                "reason": str(j.get("reason", ""))[:200]}
    return {"correct": False, "evidence_hit": False, "reason": f"[需人工复核] {last_err}"}


def render_human(results, qs, arm) -> str:
    """渲染人工判分卷（--human 用）：一题一段，答案旁边就是金标准和证据，直接勾。

    为什么要这个（2026-08-06）：judge 是评测里最贵的一环且不能降级（换判官=历史分数不可比），
    而"这题答对没有"本来就是人比模型更有资格拍的事。跳过机器判分 → 省掉整个 judge 场景的
    调用，且判定质量只升不降。代价是你要花时间读——所以证据和金标准都摊在答案旁边，别让你翻。
    """
    by_id = {q["id"]: q for q in qs}
    L = [f"# 评测人工判分卷 · {arm} · {len(results)} 题", "",
         "机器判分已跳过（`--human`）。逐题勾选，`判定` 那行改成 `对` / `错` / `部分对` 即可。",
         "", "## 汇总（填完上面再回来填这里）", "",
         "| 指标 | 结果 |", "|---|---|", "| 答对 | ___ / %d |" % len(results),
         "| 证据踩中 | ___ / %d |" % len(results), "",
         "---", ""]
    for i, r in enumerate(results, 1):
        q = by_id.get(r["id"], {})
        gold = q.get("gold") or {}
        ev = gold.get("evidence") or []
        L += [f"## {i}. [{r['id']}] {q.get('question','?')}",
              "", f"> 轴 {r.get('axis','?')} · 范围 {r.get('scope','?')} · "
              f"{r.get('tokens',0)}tk · {r.get('latency_s',0)}s", "",
              "**金标准答案**", "", gold.get("answer", "（无）"), ""]
        if ev:
            L += ["**金标准证据（原话）**", ""]
            L += [f"- `[{e.get('file','?')} {e.get('ts','?')}]` {e.get('quote','')}" for e in ev]
            L += [""]
        L += ["**考生回答**", "", r.get("reply", "（空）"), "",
              "**判定**：____　　**证据踩中**：____　　**备注**：", "", "---", ""]
    return "\n".join(L)


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="考卷跑分")
    ap.add_argument("--arm", default="demo", choices=sorted(ARMS))
    ap.add_argument("--questions", default=str(HERE / "questions_draft.jsonl"))
    ap.add_argument("--limit", type=int, default=0, help="只跑前 N 题（冒烟用）")
    ap.add_argument("--out", default="")
    ap.add_argument("--human", action="store_true",
                    help="跳过 judge 模型，产出人工判分卷 md（省掉最贵且不可降级的那一环）")
    ap.add_argument("--lark", action="store_true",
                    help="把人工判分卷推成飞书文档（需 --human）")
    ap.add_argument("--lark-folder", default=None, help="飞书目标文件夹 token 或 URL（缺省落 Drive 根）")
    args = ap.parse_args()
    if args.lark and not args.human:
        ap.error("--lark 需要配合 --human（机器判过分就不用人工卷了）")

    qs = [json.loads(l) for l in open(args.questions, encoding="utf-8") if l.strip()]
    qs = [q for q in qs if q.get("status") != "rejected"]
    if args.limit:
        qs = qs[:args.limit]
    answer = ARMS[args.arm]
    out_path = args.out or str(HERE / f"results_{args.arm}.jsonl")

    results = []
    for q in qs:
        n0 = _usage_lines()
        t0 = time.time()
        try:
            reply = answer(q["question"])
        except Exception as e:  # noqa: BLE001
            reply = f"（臂异常: {e}）"
        lat = round(time.time() - t0, 1)
        toks = _usage_tokens_since(n0)
        # --human：不调 judge。correct/evidence_hit 留 None 而不是 False——
        # 「还没判」和「判错了」是两回事，写成 False 会让下面的 rate() 静默算出一个假分数。
        v = ({"correct": None, "evidence_hit": None, "reason": "[待人工判分]"}
             if args.human else judge(q, reply))
        r = {"id": q["id"], "axis": q["axis"], "scope": q["scope"], **v,
             "tokens": toks, "latency_s": lat, "reply": reply[:600]}
        results.append(r)
        print(f"{q['id']} {q['axis']}/{q['scope']} correct={v['correct']} "
              f"ev={v['evidence_hit']} {toks}tk {lat}s")

    with open(out_path, "w", encoding="utf-8") as f:
        for r in results:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    if args.human:
        md_path = Path(out_path).with_suffix(".human.md")
        md_path.write_text(render_human(results, qs, args.arm), encoding="utf-8")
        print(f"\n=== {args.arm} 已答完 {len(results)} 题，判分交给你 ===")
        print(f"平均 {sum(r['tokens'] for r in results)//max(1,len(results))}tk"
              f" / {sum(r['latency_s'] for r in results)/max(1,len(results)):.0f}s")
        print(f"→ 人工判分卷 {md_path}")
        if args.lark:
            sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
            from ingest import lark_md
            res = lark_md.create(md_path, name=md_path.name, folder_token=args.lark_folder)
            print(f"→ 飞书 {res.get('url') or '推送失败（见 data/errors.jsonl）'}")
        print(f"→ 原始结果 {out_path}")
        return 0

    def rate(rs, k):  # noqa: E306
        return f"{sum(r[k] for r in rs)}/{len(rs)}" if rs else "-"
    print(f"\n=== {args.arm} 汇总（{len(results)} 题）===")
    print(f"correct {rate(results,'correct')} · evidence {rate(results,'evidence_hit')}"
          f" · avg {sum(r['tokens'] for r in results)//max(1,len(results))}tk"
          f" / {sum(r['latency_s'] for r in results)/max(1,len(results)):.0f}s")
    for scope in ("单天", "跨天"):
        rs = [r for r in results if r["scope"] == scope]
        if rs:
            print(f"  {scope}: correct {rate(rs,'correct')} · evidence {rate(rs,'evidence_hit')}")
    print(f"→ {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

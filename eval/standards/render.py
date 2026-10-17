#!/usr/bin/env python3
"""把登记册 + 跑批存档渲染成审核台 HTML。

    python3 -m eval.standards.render [出路径.html]

## 🔴 审核台**必须生成,不许手写**

手写一份 HTML 就是标准的第二个出处 —— 而它与代码对不上时**什么都不会报错**,
你会对着一张过期的表做判断。所以这里所有数字都来自:
  · `eval.standards.manifest.entries()`  —— 标准与判定
  · `eval.extract_metrics`               —— 跑批质量与成本
  · `data/usage.jsonl`                   —— 真实账本

## 成本为什么分两栏

`shared/model_router.py` 的价表里 `step-3.7-flash` 填的是**官方标价**,
注释写着「不作决策依据」—— 而 `run_ab_stages.py:235` 拿它算了 `cost_usd`。
真实成本是 0(免费额度)。两个数都列出来,别让「账面」冒充「真实」。
"""
from __future__ import annotations

import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from eval.extract_metrics import load as load_runs, summarize  # noqa: E402
from eval.standards.manifest import entries  # noqa: E402
from eval.standards.scan import ROOT  # noqa: E402

ARCHIVE = ROOT / "data/eval/ab_out"


def ledger_paths() -> list[Path]:
    """所有账本的所在。**不止一处,这本身就是要报告的事。**

    🔴 第一版只读 `ROOT/data/usage.jsonl`,而在 worktree 里跑时 ROOT 是 worktree 根 ——
    于是渲染器自己踩进了它正在报告的那个坑:账本 0 行,而主仓里明明有。
    `_log_usage` 落的是 `<仓库根>/data/usage.jsonl`,每个 worktree 各自一个根 ⇒
    记账天然分片,worktree 一删那一片就没了。

    ⇒ 这里把主仓与所有现存 worktree 的账本都找出来,并把「找到几处」报给页面。
    """
    import subprocess
    found = []
    try:
        common = subprocess.run(["git", "rev-parse", "--git-common-dir"],
                                cwd=ROOT, capture_output=True, text=True, timeout=5)
        if common.returncode == 0:
            main_root = (ROOT / common.stdout.strip()).resolve().parent
            found.append(main_root / "data" / "usage.jsonl")
    except (OSError, subprocess.SubprocessError):
        pass                      # git 不在也不该炸,只是少一处
    found.append(ROOT / "data" / "usage.jsonl")
    seen, out = set(), []
    for p in found:
        if p.exists() and p not in seen:
            seen.add(p)
            out.append(p)
    return out

# 免费额度的 provider：账面有价、真实为 0。唯一出处是价表的注释，这里只做展示分栏。
FREE_MODELS = {"step-3.7-flash", "step-asr"}
ARM_RECIPE = {
    "A": ("step-3.7 · 两阶段", "生产现状", True),
    "B": ("ds-flash 关 thinking · 两阶段", "", False),
    "C": ("ds-flash 关 thinking · 一阶段", "", False),
    "D": ("step-3.7 · 一阶段", "", True),
}


def cost_rows() -> list[dict]:
    """A/B 存档按臂聚合。账面 = 价表算的;真实 = 免费额度扣掉之后。"""
    if not ARCHIVE.exists():
        return []
    runs = load_runs(ARCHIVE)
    paper: dict[str, float] = defaultdict(float)
    for f in sorted(ARCHIVE.glob("[ABCD]_*.json")):
        rec = json.loads(f.read_text("utf-8")).get("_rec", {})
        paper[rec.get("arm", "?")] += rec.get("cost_usd") or 0.0
    out = []
    for s in summarize(runs, "arm"):
        arm = s["arm"]
        recipe, tag, free = ARM_RECIPE.get(arm, ("?", "", False))
        out.append({**s, "recipe": recipe, "tag": tag,
                    "paper_usd": round(paper.get(arm, 0.0), 4),
                    "real_usd": 0.0 if free else round(paper.get(arm, 0.0), 4),
                    "free": free})
    return out


def ledger_rows() -> tuple[list[dict], int, int]:
    """真实账本按场景聚合。返回 (每场景一行, 总行数, 账本份数)。"""
    paths = ledger_paths()
    agg: dict[str, dict] = defaultdict(
        lambda: {"n": 0, "inp": 0, "out": 0, "usd": 0.0, "models": Counter()})
    lines = 0
    for path in paths:
        for ln in path.read_text("utf-8").splitlines():
            ln = ln.strip()
            if not ln:
                continue
            lines += 1
            try:
                u = json.loads(ln)
            except json.JSONDecodeError:
                continue      # 坏行不静默吞:行数已经计过,聚合少一条就对不上
            a = agg[u.get("scene", "?")]
            a["n"] += 1
            a["inp"] += u.get("input") or 0
            a["out"] += u.get("output") or 0
            a["usd"] += u.get("cost_usd") or 0.0
            a["models"][u.get("model", "?")] += 1
    rows = [{"scene": k, **v, "usd": round(v["usd"], 4),
             "models": ", ".join(v["models"])} for k, v in sorted(agg.items())]
    return rows, lines, len(paths)


def payload() -> dict:
    ledger, lines, nfiles = ledger_rows()
    rows = entries()
    scenes = Counter()
    for r in rows:
        f = r["file"]
        key = ("iOS · " + f.split("/")[2] if f.startswith("ios/GrowthApp/") else
               "任务板" if f == "TASKS.md" else f.split("/")[0])
        r["group"] = key
        scenes[key] += 1
    return {
        "standards": [{
            "where": r["where"], "title": r["title"], "value": str(r["value"]),
            "file": r["file"], "line": r["line"], "group": r["group"],
            "who": r["who"], "decides": r.get("decides", ""),
            "evidence": r.get("evidence", ""), "note": r.get("note", ""),
            "comment": r.get("comment", ""), "context": r.get("context", ""),
            "verdict": r["verdict"], "manual": r["manual"],
        } for r in rows],
        "cost": cost_rows(),
        "ledger": ledger, "ledger_lines": lines, "ledger_files": nfiles,
        "groups": scenes.most_common(),
    }


def render(out: Path) -> Path:
    tpl = (Path(__file__).resolve().parent / "console.html").read_text("utf-8")
    out.write_text(tpl.replace("/*__DATA__*/null",
                               json.dumps(payload(), ensure_ascii=False)),
                   encoding="utf-8")
    return out


def main(argv: list[str]) -> int:
    out = Path(argv[0]) if argv else (ROOT / "eval/standards/console.out.html")
    p = render(out)
    d = payload()
    who = Counter(s["who"] for s in d["standards"])
    print(f"审核台已生成 → {p}")
    print(f"  标准 {len(d['standards'])} 条:你拍板 {who['user']} · 实测 {who['measured']} · AI {who['ai']}")
    print(f"  跑批 {len(d['cost'])} 臂 · 账本 {d['ledger_lines']} 行(散在 {d['ledger_files']} 处)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

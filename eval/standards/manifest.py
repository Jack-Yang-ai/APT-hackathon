#!/usr/bin/env python3
"""登记册 —— 每条标准的「谁定的 / 出处 / 你的判定」。

    python3 -m eval.standards.manifest --seed    # 把新扫到的常量登记成「待审」
    python3 -m eval.standards.manifest           # 看统计

## 🔴 登记册**不存阈值的值**

值只有一个出处:代码。这里存了值就是第二个出处,而两处对不上时**不会报错** ——
正是铁律 4 的形状。所以闸的做法是**对撞**:代码里有而这里没登记 ⇒ 红。

## 两类条目

· **扫到的**(`eval/standards/scan.py`):判决层里的数值常量,`where = 文件::符号`。
· **手工的**(下面 `MANUAL`):不是单个数值常量的标准 —— 出口达标线在 `TASKS.md`
  的表格里、判分阈值在一个 dict 里、价表也是 dict。**这些恰恰是最重要的那批**,
  扫描器一条都采不到,漏掉它们等于审核台上没有达标线。

手工条目必须给 `anchor`:一段在 `anchor_file` 里逐字存在的文字。
锚点没了 ⇒ 闸红。理由同符号锚点:标准被改写而登记还指着旧位置时,
它照样"存在",闸照样绿。

## 判定的四个取值

    pending  还没审(默认)。**不是「通过」** —— 统计里单独一栏。
    ok       审过,继续用
    fix      要改。**标了 fix 还在门禁里生效 ⇒ 闸红**
    kill     作废。标了 kill 而代码里还在 ⇒ 闸红
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from .scan import ROOT, scan

STORE = Path(__file__).resolve().parent / "manifest.json"

VERDICTS = ("pending", "ok", "fix", "kill")
WHO = ("user", "measured", "ai")
# 四条判据(唯一出处是 layers.json 的 _doc,这里只是取值域)
DECIDES = ("过红", "丢挂", "成本", "形状")


# ── 手工登记:扫描器采不到、但最重要的那批 ─────────────────────────

def _m(where, title, decides, who, evidence, anchor_file, anchor, note=""):
    return {"where": where, "title": title, "decides": decides, "who": who,
            "evidence": evidence, "anchor_file": anchor_file, "anchor": anchor,
            "note": note, "manual": True}


MANUAL = [
    # 历史 where 主键保持，既有判定不丢；锚点只指向当前独立契约。
    _m("TASKS.md::M2-0a①", "提名判准率", "过红", "user",
       "TASKS.md M2-0a 定稿 2026-08-19", "eval/contracts/acceptance.md", "| ① | 提名判准率",
       "区间不是下限 —— 高于上界=提名过于保守,而漏提在界面上什么都不会发生"),
    _m("TASKS.md::M2-0a②", "进展归属静默档判准率", "过红", "user",
       "TASKS.md M2-0a 定稿", "eval/contracts/acceptance.md", "| ② | 进展归属静默档判准率",
       "静默档是唯一不经人眼的路径"),
    _m("TASKS.md::M2-0a③", "发现合规率(停止线 3)", "过红", "user",
       "TASKS.md M2-0a 定稿", "eval/contracts/acceptance.md", "| ③ | 发现合规率",
       "双评审不是为了更准,是让「尺子本身不可信」暴露出来"),
    _m("TASKS.md::M2-0a④", "事列表搜索延迟", "过红", "user",
       "TASKS.md M2-0a 定稿 · CI 已达标", "eval/contracts/acceptance.md", "| ④ | 事列表搜索", ""),
    _m("TASKS.md::M2-0a⑤", "每场比对 token 上限", "成本", "user",
       "TASKS.md M2-0a 定稿 · §4.5.1 硬上限", "eval/contracts/acceptance.md", "| ⑤ | 每场比对 token 上限",
       "同时是 test_input_budget.py 的对撞对象"),
    _m("TASKS.md::M2-0a⑥", "六态流转全覆盖", "过红", "user",
       "TASKS.md M2-0a 定稿 · CI 已达标", "eval/contracts/acceptance.md", "| ⑥ | 六态流转全覆盖", ""),

    # ── M3 出口达标线 ──
    _m("TASKS.md::M3-0a①", "发现合规率(M3 复判)", "过红", "user",
       "TASKS.md M3-0a 定稿 2026-08-25", "eval/contracts/acceptance.md", "| ① | 发现合规率",
       "达标线由 M2-0a 给,本节只加严重违规两类 0 例"),
    _m("TASKS.md::M3-0a②", "原则层盲测", "过红", "user",
       "TASKS.md M3-0a 定稿", "eval/contracts/acceptance.md", "| ② | 原则层盲测",
       "达不到即判「在产出正确的废话」,不上线"),
    _m("TASKS.md::M3-0a③", "§5.2 联动十七行", "过红", "user",
       "TASKS.md M3-0a 定稿", "eval/contracts/acceptance.md", "| ③ | §5.2 联动表",
       "一行不过就是不过"),
    _m("TASKS.md::M3-0a④", "观察零容忍", "过红", "user",
       "TASKS.md M3-0a 定稿", "eval/contracts/acceptance.md", "| ④ | 观察零容忍",
       "性格标签 / 能力评价 / 动机推测,抽 10 条 0 违规"),

    # ── 抽取质量尺子的六条达标线:**全是 None** ──
    # 留 None 是对的(不给假绿),但后果是这把尺子造好 18 天一次真实产出都没量过。
    _m("eval/extract_quality.py::THRESHOLDS.first_pass_rate", "一次通过率达标线",
       "过红", "ai", "未定 —— 等 M0-13 实测后回填",
       "eval/extract_quality.py", '"first_pass_rate":   None', "值是 None,门禁恒不通过"),
    _m("eval/extract_quality.py::THRESHOLDS.pending_rate", "挂起率达标线",
       "过红", "ai", "未定", "eval/extract_quality.py", '"pending_rate":      None',
       "地板由分人质量定,不是抽取的锅"),
    _m("eval/extract_quality.py::THRESHOLDS.commitment_recall", "承诺召回达标线",
       "过红", "ai", "未定 —— 要金标当分母,而金标一份都没有",
       "eval/extract_quality.py", '"commitment_recall": None', ""),
    _m("eval/extract_quality.py::THRESHOLDS.commitment_precision", "承诺精确达标线",
       "过红", "ai", "未定 —— 要金标", "eval/extract_quality.py",
       '"commitment_precision": None', ""),
    _m("eval/extract_quality.py::THRESHOLDS.key_point_anchor_rate", "要点锚定率达标线",
       "过红", "ai", "未定", "eval/extract_quality.py",
       '"key_point_anchor_rate": None',
       "🔴 这一条**不需要金标**就能算,本可以先定线先跑,却跟着其他五条一起空着"),
    _m("eval/extract_quality.py::THRESHOLDS.miss_rate", "漏抽率达标线",
       "过红", "ai", "未定 —— 要金标", "eval/extract_quality.py",
       '"miss_rate":         None', ""),

    # ── 价表:口径冲突 ──
    _m("shared/model_router.py::_PRICES.step-3.7-flash", "step-3.7-flash 价表",
       "成本", "ai", "官方标价;真实成本 0(免费额度)",
       "shared/model_router.py", '"step-3.7-flash":    (0.1875',
       "🔴 注释写着「不作决策依据」,而 run_ab_stages.py:235 拿它算了成本 —— "
       "于是「C 臂比 A 便宜 11 倍」这个结论方向是反的"),
]


# ── 读写 ──────────────────────────────────────────────────────

def load() -> dict:
    if not STORE.exists():
        return {"registry": {}}
    return json.loads(STORE.read_text("utf-8"))


def save(data: dict) -> None:
    STORE.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")


def entries() -> list[dict]:
    """扫到的 + 手工的,各自合上登记信息。审核台与闸都吃这一份。"""
    reg = load()["registry"]
    out = []
    for row in scan():
        r = reg.get(row["where"], {})
        out.append({**row, "manual": False, "title": row["symbol"],
                    "who": r.get("who") or row["who_guess"],
                    "decides": r.get("decides", ""),
                    "evidence": r.get("evidence", ""),
                    "note": r.get("note", ""),
                    "verdict": r.get("verdict", "pending"),
                    "registered": row["where"] in reg})
    for man in MANUAL:
        r = reg.get(man["where"], {})
        out.append({**man, "value": "见出处", "line": 0,
                    "file": man["anchor_file"], "symbol": man["title"],
                    "comment": "", "context": "",
                    "who": r.get("who") or man["who"],
                    "verdict": r.get("verdict", "pending"),
                    "registered": True})
    return out


def seed() -> int:
    """把还没登记的扫描条目写成 `pending`。**不覆盖已有判定。**"""
    data = load()
    reg = data.setdefault("registry", {})
    n = 0
    for row in scan():
        if row["where"] in reg:
            continue
        reg[row["where"]] = {"who": row["who_guess"], "decides": "", "evidence": "",
                             "note": "", "verdict": "pending"}
        n += 1
    for man in MANUAL:
        if man["where"] in reg:
            continue
        reg[man["where"]] = {"who": man["who"], "decides": man["decides"],
                             "evidence": man["evidence"], "note": man["note"],
                             "verdict": "pending"}
        n += 1
    data["_doc"] = ("每条标准的「谁定的 / 出处 / 你的判定」。**不存阈值的值** —— "
                    "值只在代码里,存两份就是铁律 4。闸见 eval/checks/test_standards.py。")
    save(data)
    return n


def apply_judgments(payload: str) -> int:
    """把审核台上的判定写回登记册。

    审核台是一个静态页,存不了盘 —— 它把你的判定攒成一段 JSON,
    你把它粘回终端,由这里落进 `manifest.json`。**这就是「判定管住代码」的那根线**:
    落盘之后 `eval/checks/test_standards.py` 的规则④才有东西可查。

    只改 `verdict` 与 `note`,不碰 who/evidence —— 那两样是登记事实,不是判定。
    """
    incoming = json.loads(payload)
    data = load()
    reg = data.setdefault("registry", {})
    n, miss = 0, []
    for where, v in incoming.items():
        if where not in reg:
            miss.append(where)                     # 符号改名/删除 ⇒ 说出来,别静默丢
            continue
        verdict = v.get("verdict") if isinstance(v, dict) else v
        if verdict not in VERDICTS:
            raise ValueError(f"{where} 的判定 {verdict!r} 不在 {VERDICTS}")
        reg[where]["verdict"] = verdict
        if isinstance(v, dict) and v.get("note"):
            reg[where]["note"] = v["note"]
        n += 1
    save(data)
    if miss:
        print(f"⚠️ {len(miss)} 条登记册里没有,已跳过(符号可能改名了):", file=sys.stderr)
        for w in miss:
            print(f"     {w}", file=sys.stderr)
    return n


def main(argv: list[str]) -> int:
    if "--apply" in argv:
        i = argv.index("--apply")
        if i + 1 >= len(argv):
            print("🔴 --apply 后面要跟一段 JSON(审核台上「复制判定」给的那段)", file=sys.stderr)
            return 2
        n = apply_judgments(argv[i + 1])
        print(f"已落盘 {n} 条判定 —— 现在跑 `python3 -m eval.checks.test_standards` 看闸")
        return 0
    if "--seed" in argv:
        n = seed()
        print(f"新登记 {n} 条(已有判定未被覆盖)")
    rows = entries()
    from collections import Counter
    print(f"\n登记册共 {len(rows)} 条("
          f"扫到 {sum(1 for r in rows if not r['manual'])} · "
          f"手工 {sum(1 for r in rows if r['manual'])})")
    print(f"  谁定的:{dict(Counter(r['who'] for r in rows))}")
    print(f"  判定  :{dict(Counter(r['verdict'] for r in rows))}")
    unreg = [r for r in rows if not r["registered"]]
    if unreg:
        print(f"\n🔴 {len(unreg)} 条判决层常量**没登记** —— 闸会红:")
        for r in unreg[:10]:
            print(f"     {r['where']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

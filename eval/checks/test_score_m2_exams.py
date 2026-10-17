#!/usr/bin/env python3
"""M2 判分脚本的自测(M2-J2)。**构造样例,不碰真语料。**

    python3 eval/checks/test_score_m2_exams.py

钉的都是「判错了也看不出来」的:把区间当下界(会一路优化到几乎不提名)、
样本不足照算(20 条的数被当结论引用)、判不了被读成过了。
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "eval" / "score_m2_exams.py"

T: dict = {}
def test(name):
    def deco(fn): T[name] = fn; return fn
    return deco


def run(rows: list[dict]) -> tuple[int, str]:
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False,
                                     encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
        path = f.name
    p = subprocess.run([sys.executable, str(SCRIPT), path],
                       capture_output=True, text=True, cwd=ROOT)
    Path(path).unlink()
    return p.returncode, p.stdout + p.stderr


def nominations(n: int, hit: int) -> list[dict]:
    return [{"exam": "提名", "id": f"n{i}",
             "verdict": "该提名" if i < hit else "不该提名"} for i in range(n)]


def attributions(n: int, hit: int) -> list[dict]:
    return [{"exam": "归属", "id": f"a{i}",
             "verdict": "属于" if i < hit else "不属于"} for i in range(n)]


def findings(n: int, disagree: int = 0, severe: int = 0) -> list[dict]:
    out = []
    for i in range(n):
        a = "违规" if i < severe else "合规"
        # ⚠️ 第一版这里写成 `b = "合规" if i < disagree else a` —— `severe=0` 时
        # a 恒为「合规」,b 也给「合规」,**两人其实一致**,于是「一致率低」那条
        # 测试在一份根本没有分歧的样例上跑,自然红。夹具错了不是脚本错了。
        b = ("违规" if a == "合规" else "合规") if i < disagree else a
        out.append({"exam": "发现", "id": f"f{i}", "reviewer": "用户", "verdict": a,
                    **({"severity": "严重"} if i < severe else {})})
        out.append({"exam": "发现", "id": f"f{i}", "reviewer": "主模型", "verdict": b})
    return out


# ── 达标线的出处 ───────────────────────────────────────────────

@test("达标线从板上读,不在脚本里抄 —— 抄一份就是第三个出处")
def _():
    src = SCRIPT.read_text(encoding="utf-8")
    body = src.split('"""', 2)[2]        # 跳过模块 docstring(里面举例会出现数字)
    for bad in ["40", "70", "90", "95"]:
        assert f"{bad}%" not in body, (
            f"脚本正文里出现了字面量 {bad}% —— 达标线的唯一出处是 M2-0a 定稿,"
            f"抄进来就是第三个出处(板上 / test_m2_exit.py / 这里),而第三份没人守")


@test("定稿那张表六条都要抠到 —— 少一条是静默丢行")
def _():
    sys.path.insert(0, str(ROOT / "eval"))
    from score_m2_exams import thresholds
    assert len(thresholds()) == 6


# ── 卷一:区间,不是下界 ─────────────────────────────────────────

@test("提名落在区间内 ⇒ 过")
def _():
    rc, out = run(nominations(60, 33))          # 55%
    assert "✅ 卷一" in out, out


@test("🔴 提名高于上界 ⇒ **不过**,而且要说清是「过于保守」")
def _():
    # 把区间当下界是最容易犯的错:那样会一路优化到「几乎不提名」,
    # 而那个系统的判准率是 100% —— **漏提在界面上什么都不会发生**。
    rc, out = run(nominations(60, 57))          # 95%
    assert "🔴 卷一" in out, f"高于上界却判成过了:\n{out}"
    assert "过于保守" in out, f"判不过但没说清为什么:\n{out}"


@test("提名低于下界 ⇒ 不过")
def _():
    rc, out = run(nominations(60, 6))           # 10%
    assert "🔴 卷一" in out, out


@test("🔴 样本不足 ⇒ **判不了**,不是照算一个数出来")
def _():
    # 一个数一旦印出来就会被当结论引用。20 条算出来的判准率不能当结论。
    rc, out = run(nominations(20, 11))
    assert "样本不足" in out, f"20 条就照算了:\n{out}"
    assert "判不了" in out, out


# ── 卷二:下界 ─────────────────────────────────────────────────

@test("静默档达标 ⇒ 过")
def _():
    rc, out = run(attributions(50, 48))         # 96%
    assert "✅ 卷二" in out, out


@test("静默档差一点也是不过 —— 静默档是唯一不经人眼的路径")
def _():
    rc, out = run(attributions(50, 44))         # 88%
    assert "🔴 卷二" in out, out


# ── 卷三:双评审 ───────────────────────────────────────────────

@test("发现卷一致且零严重违规 ⇒ 过")
def _():
    rc, out = run(findings(50))
    assert "✅ 卷三" in out, out


@test("🔴 一致率低 ⇒ 不过,而且要说「先修规范再判系统」")
def _():
    # 双评审不是为了更准,是为了让「尺子本身不可信」暴露出来。
    # 一致率低时量出来的合规率量的是尺子,不是系统。
    rc, out = run(findings(50, disagree=10))
    assert "🔴 卷三" in out, out
    assert "先修表述规范" in out, f"一致率低却没说该先修规范:\n{out}"


@test("有严重违规 ⇒ 停止线 3 不通过(达标线要 0 例)")
def _():
    rc, out = run(findings(50, severe=1))
    assert "🔴 卷三" in out, out
    assert "严重违规" in out, out


@test("只有一个人判 ⇒ 判不了 —— 双评审的全部意义就在这儿")
def _():
    rows = [{"exam": "发现", "id": f"f{i}", "reviewer": "用户", "verdict": "合规"}
            for i in range(50)]
    rc, out = run(rows)
    assert "判不了" in out, out


# ── 「没判」不许被读成「过了」 ──────────────────────────────────

@test("🔴 判不了也退非 0 —— CI 里「没判」与「过了」不许同一个退出码")
def _():
    rc, out = run(nominations(20, 11))          # 样本不足 ⇒ 判不了
    assert rc != 0, f"判不了却退了 0,CI 会当成过了:\n{out}"


@test("三张卷全达标才退 0")
def _():
    rc, out = run(nominations(60, 33) + attributions(50, 48) + findings(50))
    assert rc == 0, f"三张卷都达标却退了 {rc}:\n{out}"
    assert "三张卷全部达标" in out, out


def main() -> int:
    failed = 0
    for name, fn in T.items():
        try:
            fn(); print(f"PASS {name}")
        except AssertionError as e:
            failed += 1; print(f"FAIL {name}\n     {e}", file=sys.stderr)
    print(f"\n{failed} failed" if failed else f"\nall passed ({len(T)})")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

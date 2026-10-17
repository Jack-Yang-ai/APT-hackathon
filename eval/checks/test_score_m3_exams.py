#!/usr/bin/env python3
"""`score_m3_exams.py` 自己的照妖镜(M3-J1)。

    python3 eval/checks/test_score_m3_exams.py

## 为什么判分脚本也要被打

**尺子在看到结果前定死** —— 而一把「怎么喂都给绿」的尺子,与没有尺子一样,
只是它看起来量过。这里每条都构造一份**该红的卷子**,断言它真的红。
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "eval" / "score_m3_exams.py"

FAILS: list[str] = []


def check(name: str, cond: bool, why: str = "") -> None:
    print(("✅" if cond else "🔴"), name)
    if not cond:
        FAILS.append(f"{name}{'|' + why if why else ''}")


def run(rows: list[dict]) -> tuple[int, str]:
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
        p = f.name
    r = subprocess.run([sys.executable, str(SCRIPT), p], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def full(**over) -> list[dict]:
    """一份**刚好全过**的卷子。每条用例只改其中一处,好指认是哪一处让它红的。"""
    rows: list[dict] = []
    for i in range(50):
        for who in ("用户", "主模型"):
            rows.append({"exam": "发现", "id": f"f{i}", "reviewer": who, "verdict": "合规"})
    for i in range(over.get("principles", 5)):
        rows.append({"exam": "盲测", "id": f"p{i}", "kind": "原则",
                     "judged": "我的原则", "exclusive": i < over.get("exclusive", 3)})
    for i in range(over.get("generics", 3)):
        rows.append({"exam": "盲测", "id": f"g{i}", "kind": "通用话术",
                     "judged": "我的原则" if i < over.get("false_positive", 0) else "通用话术"})
    for i in range(over.get("observations", 10)):
        bad = i < over.get("bad_obs", 0)
        rows.append({"exam": "观察", "id": f"o{i}",
                     "verdict": "违规" if bad else "合规",
                     **({"category": "性格标签"} if bad else {})})
    return rows


def main() -> int:
    rc, out = run(full())
    check("一份干净的卷子要全过", rc == 0, out[-400:])

    rc, out = run(full(false_positive=1))
    check("把 1 条通用话术认成自己的原则 ⇒ 红", rc != 0 and "正确的废话" in out,
          "这一条是 §4.4.13 的核心:达不到即判该层在产出正确的废话")

    rc, out = run(full(exclusive=2))
    check("认出来了但排他性只有 2 条 ⇒ 红", rc != 0,
          "「认出来」与「只属于我」是两件事,只满足前者不该算过")

    rc, out = run(full(generics=1))
    check("卷面少放了假话术 ⇒ 红(卷面组成本身是协议的一部分)", rc != 0,
          "少放假的会让「编造误判 0」毫无难度,而分数照样漂亮")

    rc, out = run(full(bad_obs=1))
    check("观察里有 1 条违规 ⇒ 红(零容忍不是比例)", rc != 0 and "一条都不许有" in out)

    rc, out = run(full(observations=3))
    check("观察只抽了 3 条 ⇒ 红(抽不够时「0 违规」说明不了什么)", rc != 0)

    # ── 达标线的出处 ──
    body = SCRIPT.read_text(encoding="utf-8").split('"""', 2)[2]
    for bad in ["95%", "≥3", "= 5", "== 10"]:
        check(f"脚本正文里没有抄「{bad}」", bad not in body,
              "达标线的唯一出处是 M3-0a 定稿,抄进来就是第三个出处")

    if FAILS:
        print()
        for f in FAILS:
            print("🔴", f, file=sys.stderr)
        return 1
    print("\n✅ 判分脚本自己也会红")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

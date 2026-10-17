#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""





























from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
import mac.extract_daemon as d                      # noqa: E402

QUEUE_JS = REPO / "worker" / "src" / "extract_queue.js"
DAEMON_PY = REPO / "mac" / "extract_daemon.py"

FAILS: list[str] = []


def check(name: str, cond: bool, why: str = "") -> None:
    print(("✅" if cond else "🔴"), name)
    if not cond:
        FAILS.append(f"{name}{'|' + why if why else ''}")


def js_const(text: str, name: str) -> str | None:
    m = re.search(rf"const {name}\s*=\s*['\"]([^'\"]+)['\"]", text)
    return m.group(1) if m else None


def main() -> int:
    if not QUEUE_JS.exists():
        raise SystemExit(f"🔴 {QUEUE_JS} 不在 —— 这道对撞的一端没了")
    js = QUEUE_JS.read_text(encoding="utf-8")
    py = DAEMON_PY.read_text(encoding="utf-8")

    # ── 两侧前缀逐字一致 ──
    for name, mine in (("JOB_PREFIX", d.JOB_PREFIX), ("OUT_PREFIX", d.OUT_PREFIX)):
        theirs = js_const(js, name)
        check(f"{name} 两侧一致", theirs == mine,
              f"python={mine!r} js={theirs!r} —— 前缀漂了,手机在另一个地方等产物")

    # ── ticket 的形状:job 键去掉前缀与 .json ──
    m = re.search(r"const ticket = `([^`]+)`", js)
    check("云代理的 ticket 形状抠得到", m is not None,
          "extract_queue.js 里 `ticket = ...` 换了写法,这个脚本要跟着改")
    if m:
        check("ticket == job 键的中段(session-part-fp)",
              m.group(1) == "${session}-${part}-${fp}", f"实际 {m.group(1)!r}")

    # ── 🔴 daemon 必须从 job 键推产物键,不许自己拼 ──
    check("daemon 从 job 键推产物键",
          f"OUT_PREFIX + key[len(JOB_PREFIX):]" in py,
          "产物键是自己拼的 —— 拼两次就是两个出处,而漂了的表现是"
          "「取不到 + 每拍重复付费」,两端都不报错")
    bad = re.search(r'OUT_PREFIX\}\{session\}-\{part\}\.json', py)
    check("照妖镜:旧那种拼法已经不在了", bad is None,
          "还留着 f\"{OUT_PREFIX}{session}-{part}.json\" —— 少了指纹")

    # ── 功能:推出来的键与 Worker 要找的键逐字相同 ──
    ticket = "29-0-54635470a457fc1c"
    job_key = f"{d.JOB_PREFIX}{ticket}.json"
    derived = d.OUT_PREFIX + job_key[len(d.JOB_PREFIX):]
    want = f"{d.OUT_PREFIX}{ticket}.json"
    check("推出来的产物键 == Worker 找的键", derived == want, f"{derived!r} vs {want!r}")

    if FAILS:
        print()
        for f in FAILS:
            print(f"🔴 {f}", file=sys.stderr)
        print("\n⚠️ 这一处漂了**两端都不报错**:daemon 说「抽完了」,手机说「云端正在抽」,"
              "而每一拍都在真花钱。", file=sys.stderr)
        return 1
    print("\n✅ 抽取队列的键两侧一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

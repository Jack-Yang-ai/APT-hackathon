#!/usr/bin/env python3
"""M2-审25 修复期测试冻结闸的自检 —— 照 test_discipline_gates.py 的形状,
每个行为都有「该拦必拦 / 该放必放」的成对对照(误伤面必须为零是这道闸的硬约束)。

铁律 5 的三问:
  · 谁调用它 —— `.claude/settings.json` 的 PreToolUse(Edit|Write|NotebookEdit) 接线,
    本文件断言接线存在、matcher 真的盖住三个工具名、指向真文件、能编译;
  · 谁在跑它 —— 会话运行时;本文件在沙盒 git 仓里以真 payload 走一遍全流程;
  · 哪道闸守着它 —— 本文件,挂在 premerge。
"""
import json
import os
import py_compile
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GUARD = os.path.join(ROOT, "scripts/hooks/fix_guard.py")
SWITCH = os.path.join(ROOT, "scripts/fix_mode.sh")

fails = []


def case(name, ok, detail=""):
    print(("  ✓ " if ok else "  🔴 ") + name + ((" —— " + detail) if (detail and not ok) else ""))
    if not ok:
        fails.append(name)


def guard(tool, file_path, cwd):
    payload = json.dumps(
        {"tool_name": tool, "tool_input": {"file_path": file_path}, "cwd": cwd}
    )
    p = subprocess.run([sys.executable, GUARD], input=payload, capture_output=True, text=True)
    return p.returncode, p.stderr


# ── 接线(谁在跑 fix_guard)─────────────────────────────────────────
print("▸ 接线")
with open(os.path.join(ROOT, ".claude/settings.json")) as f:
    settings = json.load(f)
matchers = [
    (m.get("matcher", ""), h.get("command", ""))
    for m in settings.get("hooks", {}).get("PreToolUse", [])
    for h in m.get("hooks", [])
]
wired = [(mt, c) for mt, c in matchers if "fix_guard.py" in c]
case("settings.json 有指向 fix_guard.py 的 PreToolUse", bool(wired))
if wired:
    mt = wired[0][0]
    covers = all(re.fullmatch(mt, t) for t in ("Edit", "Write", "NotebookEdit"))
    case("matcher 盖住 Edit/Write/NotebookEdit 三个工具名", covers, "matcher=%r" % mt)
try:
    py_compile.compile(GUARD, doraise=True)
    case("fix_guard.py 能编译", True)
except Exception as e:
    case("fix_guard.py 能编译", False, repr(e))

# ── 行为(沙盒 git 仓,真 payload)──────────────────────────────────
print("▸ 行为")
with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(["git", "init", "-q", tmp], check=True)
    ta = os.path.join(tmp, "FooTests.swift")
    tb = os.path.join(tmp, "BarTests.swift")
    src = os.path.join(tmp, "Foo.swift")
    for p in (ta, tb, src):
        open(p, "w").write("// x\n")

    rc, _ = guard("Edit", ta, tmp)
    case("没开冻结:改测试放行", rc == 0)

    r = subprocess.run(["sh", SWITCH, "start", "FooTests.swift"], cwd=tmp,
                       capture_output=True, text=True)
    case("start 成功", r.returncode == 0, r.stderr)

    rc, err = guard("Edit", ta, tmp)
    case("冻结中:Edit 冻结文件必拦(造坏对照的「红」)", rc == 2 and "fix_guard" in err)
    rc, _ = guard("Write", ta, tmp)
    case("冻结中:Write 冻结文件必拦", rc == 2)
    rc, _ = guard("Edit", os.path.relpath(ta, tmp), tmp)
    case("相对路径同样拦(realpath 归一)", rc == 2)

    rc, _ = guard("Edit", tb, tmp)
    case("冻结中:**别的**测试文件放行(误伤面为零)", rc == 0)
    rc, _ = guard("Edit", src, tmp)
    case("冻结中:生产代码放行(修复本来就要改它)", rc == 0)
    rc, _ = guard("Bash", ta, tmp)
    case("Bash 不在范围(已知缺口,写在 fix_guard 头注)", rc == 0)

    r = subprocess.run(["sh", SWITCH, "start", "没有这个文件.swift"], cwd=tmp,
                       capture_output=True, text=True)
    case("start 一个不存在的文件:拒(手法要求测试先提交)", r.returncode != 0)

    r = subprocess.run(["sh", SWITCH, "done"], cwd=tmp, capture_output=True, text=True)
    case("done 成功", r.returncode == 0, r.stderr)
    rc, _ = guard("Edit", ta, tmp)
    case("解冻后:放行(闸不许留残影)", rc == 0)

    p = subprocess.run([sys.executable, GUARD], input="不是 JSON", capture_output=True, text=True)
    case("喂坏输入:fail-open 放行(误伤全部编辑的闸比没有闸更糟)", p.returncode == 0)

if fails:
    print("\n🔴 %d 项没过:%s" % (len(fails), " / ".join(fails)))
    sys.exit(1)
print("\n✅ 修复期测试冻结闸自检全过(且拦/放两侧都验过)")

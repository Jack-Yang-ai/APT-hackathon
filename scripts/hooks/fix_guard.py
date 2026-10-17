#!/usr/bin/env python3
"""PreToolUse(Edit|Write|NotebookEdit) 闸 —— 修复期测试冻结(M2-审25 ②)。

「修代码的 agent 不能同时削弱对那段代码的检查」:修 bug 的正确姿势是
先把 bug 提交成失败的测试,然后修 —— 修的全程那份测试一个字都不许动。
不冻的话,「让测试转绿」最短的路往往是改测试,而那样 bug 还在,证据没了。

范围与边界(写死,免得后人扩大):
  · 只在 `scripts/fix_mode.sh start` 开着时生效(开关语义见那边头注);
  · 只拦清单里的**精确路径**,不拦模式 —— 误伤一次这道闸就会被永久绕开;
  · 只拦 Edit/Write/NotebookEdit。⚠️ Bash 里 `sed -i` 改同一个文件拦不到 ——
    这是已知缺口,不补:把 Bash 整个纳入要解析任意 shell,误伤面控不住,
    而「绕道 sed 去改测试」已经是明知故犯,闸挡无心之失,挡不了故意。

失败开(fail-open):闸自身异常一律放行,理由同 git_guard。
自检在 eval/checks/test_fix_mode_gate.py(premerge 在跑),含「造坏必须红」对照。
"""
import json
import os
import subprocess
import sys


def frozen_paths(cwd: str):
    gitdir = subprocess.run(
        ["git", "rev-parse", "--git-dir"], cwd=cwd, capture_output=True, text=True
    )
    if gitdir.returncode != 0:
        return None, []
    gd = gitdir.stdout.strip()
    if not os.path.isabs(gd):
        gd = os.path.join(cwd, gd)
    flag = os.path.join(gd, "claude_fix_mode")
    if not os.path.exists(flag):
        return None, []
    with open(flag) as f:
        return flag, [ln.strip() for ln in f if ln.strip()]


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name") not in ("Edit", "Write", "NotebookEdit"):
            return 0
        ti = data.get("tool_input", {})
        target = ti.get("file_path") or ti.get("notebook_path")
        if not isinstance(target, str):
            return 0
        cwd = data.get("cwd") or os.getcwd()
        flag, frozen = frozen_paths(cwd)
        if not frozen:
            return 0
        real = os.path.realpath(
            target if os.path.isabs(target) else os.path.join(cwd, target)
        )
        if real not in {os.path.realpath(p) for p in frozen}:
            return 0
        since = ""
        try:
            import datetime
            since = datetime.datetime.fromtimestamp(os.path.getmtime(flag)).strftime("%m-%d %H:%M")
        except OSError:
            pass
        print(
            "⛔ fix_guard:修复期测试冻结(自 %s)—— 这份测试是 bug 存在过的证据,\n"
            "修复期间不许动它(M2-审25:让它转绿的只能是代码,不能是测试)。\n"
            "   · 冻结文件:%s\n"
            "修真的绿了 → `sh scripts/fix_mode.sh done` 解冻再改;\n"
            "测试本身写错了 → 那不是修 bug,先 done 解冻,把「测试为什么错」写进提交说明。"
            % (since or "?", target),
            file=sys.stderr,
        )
        return 2
    except Exception as e:  # fail-open,但留痕
        print("fix_guard 自身异常(放行): %r" % e, file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())

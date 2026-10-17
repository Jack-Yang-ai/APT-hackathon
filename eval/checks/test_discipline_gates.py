#!/usr/bin/env python3
"""M2-审23 三道纪律闸的自检 —— 每道都含「造坏必须红」的对照(复核清单 §八)。

铁律 5 的三问在这里的落点:
  · git_guard 谁在跑它?—— `.claude/settings.json` 的 PreToolUse 接线。
    本文件断言接线存在且指向真文件、真能编译 —— 否则闸就是 RegistrySnapshotIO
    的形状:写好了、测过了、生产零调用点。
  · ios_test.sh 的判定逻辑 —— 喂它「Executed 0 tests + TEST SUCCEEDED」必须红;
  · red_green.sh —— green 没有 red 在前必须拒;red 阶段不红必须拒。
"""
import json
import os
import py_compile
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GUARD = os.path.join(ROOT, "scripts/hooks/git_guard.py")
IOS_TEST = os.path.join(ROOT, "scripts/ios_test.sh")
RED_GREEN = os.path.join(ROOT, "scripts/red_green.sh")

fails = []


def case(name, ok, detail=""):
    print(("  ✓ " if ok else "  🔴 ") + name + ((" —— " + detail) if (detail and not ok) else ""))
    if not ok:
        fails.append(name)


def guard(cmd, cwd=None):
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd or ROOT})
    p = subprocess.run([sys.executable, GUARD], input=payload, capture_output=True, text=True)
    return p.returncode, p.stderr


def sh(args, cwd):
    return subprocess.run(["sh"] + args, cwd=cwd, capture_output=True, text=True)


# ── 接线:settings.json 真的指向这道闸(闸没接线 = 铁律 5 的形状)────────
print("▸ 接线(谁在跑 git_guard)")
settings_path = os.path.join(ROOT, ".claude/settings.json")
try:
    with open(settings_path) as f:
        settings = json.load(f)
    cmds = [
        h.get("command", "")
        for m in settings.get("hooks", {}).get("PreToolUse", [])
        if m.get("matcher") == "Bash"
        for h in m.get("hooks", [])
    ]
    case("settings.json 的 PreToolUse(Bash) 指向 git_guard.py", any("git_guard.py" in c for c in cmds))
except (OSError, json.JSONDecodeError) as e:
    case("settings.json 可读且是合法 JSON", False, repr(e))
try:
    py_compile.compile(GUARD, doraise=True)
    case("git_guard.py 能编译", True)
except Exception as e:
    case("git_guard.py 能编译", False, repr(e))

# ── 闸 A:git add -A / --all / . ─────────────────────────────────────
print("▸ git_guard:add 全量(造坏必须红)")
for cmd in ("git add -A", "git add .", "git add --all", "cd ios && git add -A", "git add src/a.py ."):
    rc, err = guard(cmd)
    case("拦 %r" % cmd, rc == 2 and "禁止" in err, "rc=%s" % rc)
for cmd in ("git add TASKS.md scripts/ios_test.sh", "git add .gitignore", "git add ./scripts/red_green.sh", "ls -la", 'echo "git add -A 是被禁的"'):
    rc, _ = guard(cmd)
    case("放行 %r" % cmd, rc == 0, "rc=%s" % rc)

# ── 闸 B:heredoc + git 写操作 ───────────────────────────────────────
print("▸ git_guard:heredoc 接 git 写操作")
bad = "git pull --rebase && python3 - <<'PY'\nprint(1)\nPY\ngit add f.py && git commit -m x"
rc, err = guard(bad)
case("拦「heredoc 链上接 add/commit」", rc == 2 and "heredoc" in err, "rc=%s" % rc)
rc, _ = guard("python3 - <<'PY'\nprint(1)\nPY")
case("放行「纯 heredoc,无 git 写」", rc == 0, "rc=%s" % rc)
rc, _ = guard("git log -3 <<'EOF'\nEOF")  # 读操作不拦
case("放行「heredoc + git 读操作」", rc == 0, "rc=%s" % rc)

# ── 闸 C:commit 时索引里已有暂存 ⇒ 第一次拦、原样重发放行 ─────────────
print("▸ git_guard:commit 前索引快照(在临时仓里演)")
with tempfile.TemporaryDirectory() as td:
    subprocess.run(["git", "init", "-q"], cwd=td, check=True)
    open(os.path.join(td, "leftover.txt"), "w").write("别的会话暂存的\n")
    subprocess.run(["git", "add", "leftover.txt"], cwd=td, check=True)
    rc1, err1 = guard("git commit -m msg", cwd=td)
    case("有暂存:第一次拦下并列出清单", rc1 == 2 and "leftover.txt" in err1, "rc=%s" % rc1)
    rc2, _ = guard("git commit -m msg", cwd=td)
    case("同一份清单原样重发:放行", rc2 == 0, "rc=%s" % rc2)
    rc3, _ = guard("git commit -m msg", cwd=td)
    case("指纹已烧掉:再来要重新确认", rc3 == 2, "rc=%s" % rc3)
    # 临时仓无 HEAD,restore --staged 解析不了,用 rm --cached 清空索引
    subprocess.run(["git", "rm", "--cached", "-q", "leftover.txt"], cwd=td, check=True)
    rc4, _ = guard("git commit -m msg", cwd=td)
    case("索引空:直接放行", rc4 == 0, "rc=%s" % rc4)

# ── git_guard:直推 main(M2-审27 的 PR 流)──────────────────────────
print("▸ git_guard:直推 main(在临时仓里演)")
with tempfile.TemporaryDirectory() as td:
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=td, check=True)
    rc, err = guard("git push origin main", cwd=td)
    case("显式推 main:拦", rc == 2 and "PR" in err, "rc=%s" % rc)
    rc, _ = guard("git push -u origin fix:main", cwd=td)
    case("refspec 指到 main(fix:main):拦", rc == 2, "rc=%s" % rc)
    rc, _ = guard("git push", cwd=td)
    case("裸 push 且当前分支是 main:拦", rc == 2, "rc=%s" % rc)
    rc, _ = guard("git push -u origin claude/some-branch", cwd=td)
    case("推别的分支:放行(PR 流的正道)", rc == 0, "rc=%s" % rc)
    subprocess.run(["git", "checkout", "-q", "-b", "claude/x"], cwd=td, check=True)
    rc, _ = guard("git push", cwd=td)
    case("裸 push 且当前分支不是 main:放行", rc == 0, "rc=%s" % rc)
    rc, _ = guard("MAIN_PUSH_OK=1 git push origin main", cwd=td)
    case("用户明说的逃生口 MAIN_PUSH_OK=1:放行", rc == 0, "rc=%s" % rc)
    rc, _ = guard("git pull --rebase && git fetch origin main", cwd=td)
    case("pull/fetch main:放行(只拦写不拦读)", rc == 0, "rc=%s" % rc)

    # ── Codex 审 PR#2 抓到的两个绕过(2026-08-27),钉死不许回潮 ──
    # 空仓里 main 是 unborn,checkout 不了 —— 直接把 HEAD 指回去
    subprocess.run(["git", "symbolic-ref", "HEAD", "refs/heads/main"], cwd=td, check=True)
    rc, _ = guard("git push origin HEAD", cwd=td)
    case("绕过①:main 上 `push origin HEAD`:拦(HEAD 解析到当前分支)", rc == 2, "rc=%s" % rc)
    rc, _ = guard("git push origin HEAD:main", cwd=td)
    case("HEAD:main:拦", rc == 2, "rc=%s" % rc)
    rc, _ = guard("git push origin refs/heads/main", cwd=td)
    case("全限定 refs/heads/main:拦", rc == 2, "rc=%s" % rc)
    rc, _ = guard("git push origin :main", cwd=td)
    case("删除式 :main:拦(删 main 更不行)", rc == 2, "rc=%s" % rc)
    rc, _ = guard("echo 'MAIN_PUSH_OK=1 is reserved' && git push origin main", cwd=td)
    case("绕过②:逃生口子串在别的段里:照拦(必须是真赋值前缀)", rc == 2, "rc=%s" % rc)
    subprocess.run(["git", "symbolic-ref", "HEAD", "refs/heads/claude/x"], cwd=td, check=True)
    rc, _ = guard("git push origin HEAD", cwd=td)
    case("别的分支上 `push origin HEAD`:放行", rc == 0, "rc=%s" % rc)

# ── ios_test.sh 的判定:假绿样本必须红 ────────────────────────────────
print("▸ ios_test.sh --parse-only")
with tempfile.TemporaryDirectory() as td:
    def log(name, text):
        p = os.path.join(td, name)
        open(p, "w").write(text)
        return p

    fake_green = log("zero.log", "Test Suite 'All tests' passed\nExecuted 0 tests, with 0 failures\n** TEST SUCCEEDED **\n")
    r = sh([IOS_TEST, "--parse-only", fake_green, "0"], ROOT)
    case("「Executed 0 + SUCCEEDED」必须红(这就是 08-25 那个假绿)", r.returncode != 0)

    no_line = log("empty.log", "** TEST SUCCEEDED **\n")
    r = sh([IOS_TEST, "--parse-only", no_line, "0"], ROOT)
    case("没有 Executed 行必须红", r.returncode != 0)

    ok_log = log("ok.log", "Executed 3 tests, with 0 failures\nExecuted 57 tests, with 0 failures\n** TEST SUCCEEDED **\n")
    r = sh([IOS_TEST, "--parse-only", ok_log, "0"], ROOT)
    case("Executed 57 · rc 0:绿,且打出的是 N=57", r.returncode == 0 and "57" in r.stdout)

    r = sh([IOS_TEST, "--parse-only", ok_log, "65"], ROOT)
    case("xcodebuild rc=65 必须红(不管日志多绿)", r.returncode != 0)

    env = dict(os.environ, IOS_TEST_MIN="99")
    r = subprocess.run(["sh", IOS_TEST, "--parse-only", ok_log, "0"], cwd=ROOT, env=env, capture_output=True, text=True)
    case("地板 99 > 实跑 57:红", r.returncode != 0)

# ── red_green.sh 的次序:没红过的绿必须拒 ─────────────────────────────
print("▸ red_green.sh(在临时仓里演)")
with tempfile.TemporaryDirectory() as td:
    subprocess.run(["git", "init", "-q"], cwd=td, check=True)
    marker = os.path.join(td, "restored")
    cmd = "test -f %s" % marker  # 「还原」= marker 出现

    r = sh([RED_GREEN, "green", cmd], td)
    case("green 没有 red 在前:拒", r.returncode != 0)
    r = sh([RED_GREEN, "red", "true"], td)
    case("red 阶段命令居然绿:拒(改坏没生效/空转测试)", r.returncode != 0)
    r = sh([RED_GREEN, "red", cmd], td)
    case("red 阶段真红:登记", r.returncode == 0)
    r = sh([RED_GREEN, "green", cmd], td)
    case("还没还原就跑 green:红(还原不完整)", r.returncode != 0)
    open(marker, "w").write("")
    r = sh([RED_GREEN, "green", cmd], td)
    case("还原后 green:由真实运行收口", r.returncode == 0)
    r = sh([RED_GREEN, "green", cmd], td)
    case("收口过的登记已烧掉:再 green 要重新走 red", r.returncode != 0)

print()
if fails:
    print("🔴 %d 项没过:%s" % (len(fails), " / ".join(fails)))
    sys.exit(1)
print("✅ 纪律闸自检全过(且每道都验过会红)")

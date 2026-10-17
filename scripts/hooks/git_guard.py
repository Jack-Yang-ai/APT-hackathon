#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""





















import hashlib
import json
import os
import re
import subprocess
import sys


def _segments(cmd: str):
    # 粗切分:&& / || / ; / | / 换行 都算段边界。这里要的是「别漏拦」——
    # 切多了顶多多看一段,不会漏。
    return re.split(r"&&|\|\||;|\||\n", cmd)


def _git_subcommand(seg: str):
    """段里若是 git 调用,返回 (子命令, 其后参数列表);否则 None。"""
    toks = seg.split()
    try:
        i = toks.index("git")
    except ValueError:
        return None
    # `git` 前只允许环境变量赋值(GIT_X=1 git …),否则是别的命令的参数
    # (比如 echo "git commit"),不算 git 调用。
    if any("=" not in t for t in toks[:i]):
        return None
    rest = toks[i + 1:]
    j = 0
    while j < len(rest) and rest[j].startswith("-"):
        # -C <path> / -c <k=v> 带一个参数;--git-dir=x 之类单 token
        j += 2 if rest[j] in ("-C", "-c") else 1
    if j >= len(rest):
        return None
    return rest[j], rest[j + 1:]


def check_add_all(cmd: str):
    for seg in _segments(cmd):
        sub = _git_subcommand(seg)
        if not sub or sub[0] != "add":
            continue
        for a in sub[1]:
            if a in ("-A", "--all", ".", ":/"):
                return (
                    "⛔ git_guard:禁止 `git add %s`(协作规则 1,事故一)。\n"
                    "只 add 你自己改的文件,路径写全。" % a
                )
    return None


def check_heredoc_git(cmd: str):
    if not re.search(r"<<-?\s*['\"]?[A-Za-z_]", cmd):
        return None
    if not any(
        sub and sub[0] in ("add", "commit", "push")
        for sub in map(_git_subcommand, _segments(cmd))
    ):
        return None
    return (
        "⛔ git_guard:heredoc 与 git 写操作在同一条命令里(协作规则 1 的 08-25 补丁)。\n"
        "heredoc 会截断 && 链:终止符之后是新命令,前面失败时 add/commit 照跑。\n"
        "编辑与提交分两次调用。"
    )


def _on_main(cwd: str) -> bool:
    head = subprocess.run(
        ["git", "symbolic-ref", "--short", "HEAD"],
        cwd=cwd, capture_output=True, text=True,
    )
    return head.returncode == 0 and head.stdout.strip() == "main"


def check_push_main(cmd: str, cwd: str):
    # ⚠️ 两处都是 Codex 审 PR#2 抓到的真绕过(2026-08-27),别改回去:
    # ① 逃生口必须是**贴在这条 git push 段上的真环境变量赋值** ——
    #    第一版是全文找子串,`echo 'MAIN_PUSH_OK=1 …' && git push origin main`
    #    一分钱不花就放行了;
    # ② 目的地按 refspec 解析(HEAD / refs/heads/main / :main / xxx:main),
    #    不是找字面 `main` —— 第一版对 main 上的 `git push origin HEAD` 放行。
    for seg in _segments(cmd):
        sub = _git_subcommand(seg)
        if not sub or sub[0] != "push":
            continue
        toks = seg.split()
        gi = toks.index("git")
        if any(t == "MAIN_PUSH_OK=1" for t in toks[:gi]):
            continue  # 真赋值前缀才算逃生口
        args = [a for a in sub[1] if not a.startswith("-")]
        refspecs = args[1:]  # args[0] 是 remote
        dests = []
        if not refspecs:
            dests.append("@CURRENT@")  # 裸 push(含只给 remote):推当前分支
        for r in refspecs:
            dst = r.split(":", 1)[1] if ":" in r else r
            dests.append("@CURRENT@" if dst == "HEAD" else dst)
        for d in dests:
            if d == "@CURRENT@":
                if not _on_main(cwd):
                    continue
            else:
                name = d[len("refs/heads/"):] if d.startswith("refs/heads/") else d
                if name != "main":
                    continue
            return (
                "⛔ git_guard:直推 main 已关(M2-审27,官方 SDLC 的 PR 流)。\n"
                "改动走:分支 → git push -u origin <分支> → gh pr create → 用户 merge。\n"
                "用户当次明确说了要直推的,前缀 MAIN_PUSH_OK=1 放行。"
            )
    return None


def check_commit_staged(cmd: str, cwd: str):
    if not any(sub and sub[0] == "commit" for sub in map(_git_subcommand, _segments(cmd))):
        return None
    gitdir = subprocess.run(
        ["git", "rev-parse", "--git-dir"], cwd=cwd, capture_output=True, text=True
    )
    if gitdir.returncode != 0:
        return None
    gd = gitdir.stdout.strip()
    if not os.path.isabs(gd):
        gd = os.path.join(cwd, gd)
    staged = subprocess.run(
        ["git", "diff", "--cached", "--name-only"], cwd=cwd, capture_output=True, text=True
    ).stdout.strip()
    if not staged:
        return None
    ack = os.path.join(gd, "claude_commit_ack")
    sig = hashlib.sha256(staged.encode()).hexdigest()
    if os.path.exists(ack):
        with open(ack) as f:
            seen = f.read().strip()
        if seen == sig:
            os.remove(ack)
            return None
    with open(ack, "w") as f:
        f.write(sig)
    return (
        "⛔ git_guard:commit 前的索引快照 —— 下面这些在这条命令执行前就已在暂存区\n"
        "(共享工作区里可能是别的会话的,协作规则 1 的 08-25 卷带事故):\n\n"
        + "\n".join("   · " + p for p in staged.splitlines())
        + "\n\n逐行确认:全部属于本次提交 → 原样重发同一条命令即放行;\n"
        "有不属于的 → 先 `git restore --staged <path>` 摘掉再提交。"
    )


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name") != "Bash":
            return 0
        cmd = data.get("tool_input", {}).get("command")
        if not isinstance(cmd, str):
            return 0
        cwd = data.get("cwd") or os.getcwd()
        for msg in (
            check_add_all(cmd),
            check_heredoc_git(cmd),
            check_push_main(cmd, cwd),
            check_commit_staged(cmd, cwd),
        ):
            if msg:
                print(msg, file=sys.stderr)
                return 2
        return 0
    except Exception as e:  # fail-open,但留痕
        print("git_guard 自身异常(放行): %r" % e, file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())

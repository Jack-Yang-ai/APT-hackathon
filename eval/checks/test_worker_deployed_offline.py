#!/usr/bin/env python3
"""改了 `worker/src` 却没部署 —— **离线**对撞(M1-35;M2-审22 重写)。

    python3 eval/checks/test_worker_deployed_offline.py

## 为什么要这道

铁律 4 的**部署版**:「collector 的行为」有两份出处 —— 仓库源码 / 线上跑的版本。
对不上时**没有任何东西会报错**,只会让人拿着「我修好了」的印象去做决定。

2026-08-20 真吃过:`M1-34` 防收割器覆盖的闸 08-19 傍晚提交,
当天最后一次部署在 13:47 —— **晚了四五个小时**。代价是两块已靠 SSE 出稿的音频
被 6 小时兜底覆盖成「asr timeout 判失败」。那期间 commit 绿、`worker/` 47 条测试绿、
`premerge` 绿。⚠️ 注意形态:**不是「没人部署」**(六天部署过 10 次),
是「某个 commit 落在当天最后一次部署之后」—— 看部署记录只会觉得「一直在部署啊」。

## 🔴 这道闸**能证明什么、不能证明什么**(2026-08-25 补,别再读错)

它比的是 **stamp 文件 vs git 树哈希**,不是 **线上 vs git 树哈希**。所以:

· 绿 = 「这一版**曾经**被部署过,而且部署时联网核实过」(前提:stamp 只由
  `scripts/deploy_worker.sh` 写,而那个脚本 2026-08-25 起**先联网核实 `/version`、
  核实过了才写 stamp**)。绿**不等于**「此刻线上跑的是这一版」——
  要问此刻,只有 `scripts/check_worker_deployed.sh`(要网 + token)。
· 手工 `printf > worker/.deployed_sha` 依然能骗过它。离线判据没法堵这个洞,
  堵它的是「stamp 只在联网核实之后才被写出来」这条**产生侧**的约束。

⚠️ 为什么不干脆把联网那道塞进 premerge:离线时会变**假红**,而假红的闸会被人
开始跳过,等于没有闸。分工不变 —— 便宜这道每次合板都跑,贵那道发布前跑。

## 三个态,别混成一个红(M2-审22 的正题)

| stamp vs 树哈希 | 历史里有没有提交把这个树哈希落成过 stamp | 判定 |
|---|---|---|
| 相等 | — | ✅ 这一版部署过 |
| 不等 | 有,而且那个提交**不是 HEAD 的祖先** | ✅ + ⚠️ **你这份 checkout 落后**(worktree / 没 rebase),不是漂移 |
| 不等 | 没有,或只在 HEAD 的祖先里(= 部署过之后又被改回旧版) | 🔴 真漂移:这一版没上线过 |

第二行是 worktree 场景:stamp 常常在 `worker/src` 改动之后**隔几个提交**才落
(部署要用户放行),于是任何在这个窗口里切出去的分支天生带一条红 —— 而 main 全绿。
第一次遇到的人会以为自己改坏了 worker。
⚠️ 「不是 HEAD 的祖先」这个限定不能去掉:去掉之后,把 `worker/src`
**回退到某个旧版本**也会绿(那个旧版确实部署过),而线上跑的是新版 —— 是个真假绿。
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STAMP = ROOT / "worker" / ".deployed_sha"
REL = "worker/.deployed_sha"


def git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)


def stamped_elsewhere(want_sha: str) -> str | None:
    """历史里有没有**不是 HEAD 祖先**的提交把 `want_sha` 落成过 stamp?

    有 ⇒ 这一版在别的分支上部署过,本 checkout 只是落后。返回那个提交的短哈希。
    """
    log = git("log", "--all", "--format=%H", "--", REL)
    if log.returncode != 0:
        return None
    for commit in log.stdout.split():
        blob = git("show", f"{commit}:{REL}")
        if blob.returncode != 0 or blob.stdout.strip() != want_sha:
            continue
        # 祖先 = 我们已经走过它了 ⇒ 现在的不一致是「部署过之后又改回旧版」,是真漂移。
        if git("merge-base", "--is-ancestor", commit, "HEAD").returncode == 0:
            continue
        return commit[:12]
    return None


def main() -> int:
    want = git("rev-parse", "HEAD:worker/src")
    if want.returncode != 0:
        print(f"🔴 读不到 HEAD:worker/src —— 判据锚点没了:{want.stderr.strip()}", file=sys.stderr)
        return 1
    want_sha = want.stdout.strip()

    if not STAMP.exists():
        print(f"🔴 缺 {REL} —— 它是**跟踪文件**(`git ls-files {REL}` 查得到),\n"
              f"   缺了说明被删过或 checkout 不全,不是「本地还没部署过」。\n"
              f"   ⇒ `git checkout -- {REL}` 拿回来;真要重落用 sh scripts/deploy_worker.sh。",
              file=sys.stderr)
        return 1
    got = STAMP.read_text(encoding="utf-8").strip()

    if got == want_sha:
        print(f"✅ worker/src 部署过({want_sha[:12]}…)"
              f" —— 注意:证明的是「这一版上过线」,不是「此刻线上是它」")
        return 0

    ahead = stamped_elsewhere(want_sha)
    if ahead:
        print(f"⚠️ stamp 落后,不是漂移:本 checkout 的 stamp 是 {got[:12]}…,"
              f"而 {want_sha[:12]}… 已在 {ahead} 落过 stamp(那个提交不在你的 HEAD 里)"
              f" ⇒ 这份 checkout 陈旧(worktree 常见),`git pull --rebase` 或 rebase 到 main 即可;"
              f"要判此刻线上跑什么用 sh scripts/check_worker_deployed.sh")
        return 0

    print(f"🔴 `worker/src` 改过但没部署:\n"
          f"   已部署  {got}\n"
          f"   仓库    {want_sha}  (git rev-parse HEAD:worker/src)\n"
          f"   全仓历史里**没有任何提交**把这个树哈希落成过 stamp(HEAD 的祖先不算)\n"
          f"   ⇒ 这一版没上线过。sh scripts/deploy_worker.sh,然后把 {REL} 一起提交。\n"
          f"   ⚠️ 不部署的后果不是抽象的:2026-08-20 有两块已出稿的音频因此被覆盖成失败记录。",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/bin/sh
# 夜班开工前的机械闸(用户 2026-08-19 拍板)。
#
#   sh scripts/night_preflight.sh   # 0=可以开工;非 0=别开工,把输出抄进夜报
#
# ## 它守的是什么
#
# **不是「不碰 main」,是「同一时刻只有一个写方」。** 前者是手段,后者才是目的 ——
# 而手段对 iOS 走不通:`CLAUDE.md` 明写 iOS 不该用 worktree(不共享 DerivedData,
# 每个都要全量构建),而夜班菜单六条里四条是 iOS。两条规矩打架时守目的,不守手段。
#
# ## 为什么是脚本不是纪律
#
# 「结构挡得住并发,纪律挡不住」——`CLAUDE.md` 协作模型自己的结论,事故四换来的。
# 凌晨三点没人看着,一句「记得先看看有没有别人在干活」等于没写。
#
# ## 它**不**管什么
#
# 模拟器占用归 `scripts/uitest.sh` 那道闸(它认设备名也认 UDID,比这里细)。
# 这里只答一个问题:**现在往 main 上写,会不会撞上别人。**
set -u
cd "$(dirname "$0")/.."

QUIET_MIN="${NIGHT_QUIET_MIN:-30}"      # 多久没动静算「那个会话已经收工」
fail=0
say() { printf '%s\n' "$*" >&2; fail=1; }
# 跳闸清单(M2-审23 ⑥):跳闸可以是用户的决定,但 2026-08-25 的教训是
# 「跳了就要把闸原本挡的每一样自己挡一遍,而不是挡一半」——
# 所以闸被触发时,顺带把「跳过我你要自己补什么」按触发项攒下来,最后一起打出。
skiplist=""
skip() { skiplist="$skiplist
   · $*"; }

echo "▸ 夜班开工闸(静默阈值 ${QUIET_MIN} 分钟)"

# ── ① 工作区必须干净 ────────────────────────────────────────────
# 事故一的形状:脏树上开工,别人的半成品会被卷进你的 commit,
# 而 message 里对它只字未提。**这条零成本,永远先查。**
dirty=$(git status --porcelain | head -20)
if [ -n "$dirty" ]; then
  say "🔴 工作区不干净 —— 脏树上开工会把别人的半成品卷进你的 commit(事故一):"
  printf '%s\n' "$dirty" >&2
  skip "①工作区脏:开工前留一份 \`git status --porcelain\` 快照;之后每次 commit 前用 \`git diff --cached --name-only\` 逐行核对,不是你改的一律 \`git restore --staged\` 摘掉"
fi

# ── ② 索引里不许有残留 ──────────────────────────────────────────
# 2026-08-19 咬过:先 `git add` 了一批源码,中间去干了别的,后来
# `git add TASKS.md && git commit` —— **那批还在索引里,一起进去了**。
# 每一次 add 都写了显式路径,规矩一条没违,咬人的是「索引里还留着什么」。
staged=$(git diff --cached --name-only | head -20)
if [ -n "$staged" ]; then
  say "🔴 索引里还暂存着东西 —— 下一次 commit 会把它们一起卷走:"
  printf '%s\n' "$staged" >&2
  skip "②索引残留:动手前先逐条 \`git restore --staged <path>\`(或确认归属)—— 带着别人的暂存 commit 就是 0427363 那次事故"
fi

# ── ③ 与 origin/main 不许分叉 ───────────────────────────────────
git fetch -q origin main 2>/dev/null || say "⚠️ fetch 不到 origin/main(离线?)—— 下面这条判不准"
behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
if [ "$behind" -gt 0 ]; then
  say "🔴 落后 origin/main $behind 条 —— 先 git pull --rebase,别在旧基线上开工"
  skip "③落后 main:开工第一件事 \`git pull --rebase\`,拒绝在旧基线上产出 diff —— 否则你的合并会把别人已合的改动顶回去"
fi

# ── ④ 有没有别的会话还活着 ─────────────────────────────────────
# 判据是**最近有没有动静**,不是「有没有脏 worktree」——
# 2026-08-19 审计过:5 个脏 worktree 全是被 main 超越的陈旧快照,
# 拿「脏」当判据会天天误报,而天天误报的闸等于没有闸。
live=""; seen=""
for b in $(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin \
           | grep -v '^origin/HEAD$'); do
  case "$b" in main|origin/main) continue ;; esac
  # 本地与远端同名分支去重 —— 同一条报两遍会把这道闸变成噪音,
  # 而**噪音闸等于没有闸**(看的人会开始跳过它)。
  short=${b#origin/}
  case " $seen " in *" $short "*) continue ;; esac
  seen="$seen $short"
  ahead=$(git rev-list --count main.."$b" 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] || continue
  age=$(( ( $(date +%s) - $(git log -1 --format=%ct "$b" 2>/dev/null || echo 0) ) / 60 ))
  [ "$age" -lt "$QUIET_MIN" ] && live="$live\n   · $b(领先 $ahead 条,$age 分钟前还在提交)"
done
if [ -n "$live" ]; then
  say "🔴 还有会话在动 —— 半夜它一 push,你就要在无人值守时处理 rebase 冲突:"
  printf "$live\n" >&2
  skip "④有会话在动:不碰它领先提交里动过的路径;自己的活按可回滚单元小步 commit+push,别攒(事故五),冲突宁可留给白天的合并方"
fi

# 工作区里最近被改过的文件(worktree 里的活不一定提交,事故五)
recent=$(find .claude/worktrees -maxdepth 4 -type f -newermt "-${QUIET_MIN} minutes" \
         -not -path '*/.git/*' -not -path '*/DerivedData/*' 2>/dev/null | head -5)
if [ -n "$recent" ]; then
  say "🔴 有 worktree 在 ${QUIET_MIN} 分钟内被改过 —— 那个会话多半还开着:"
  printf '%s\n' "$recent" >&2
  skip "④worktree 有动静:那个会话的活还没提交(事故五的形状),别去合并或清理它的分支/worktree"
fi

# ── ⑤ 有没有别的构建在跑 ───────────────────────────────────────
# ⚠️ 模拟器**占用**归 scripts/uitest.sh 那道闸(它认设备名也认 UDID)。
# 这里问的是另一件事:**有没有别的会话此刻正活着**,构建进程是最直接的证据。
if pgrep -f "xcodebuild" >/dev/null 2>&1; then
  say "🔴 有 xcodebuild 在跑 —— 说明另一个会话正活着:"
  ps aux | grep "[x]codebuild" | head -3 >&2
  skip "⑤别的构建在跑:整轮不碰 \`ios/\`(构建互踩),只做文档 / Python / worker 侧"
fi

if [ "$fail" -eq 0 ]; then
  echo "✅ 可以开工:工作区干净 · 索引空 · 与 origin/main 同步 · ${QUIET_MIN} 分钟内没有别人的动静"
  exit 0
fi
cat >&2 <<'MSG'

⇒ **别开工。** 把上面的输出原样抄进夜报的「卡在哪」,然后结束这一轮。
   不要绕过这道闸 —— 它挡的正是「凌晨三点没人看着时两个会话同时写 main」。
MSG
if [ -n "$skiplist" ]; then
  printf '%s\n' "" \
    "   仅当**用户明确拍板跳闸**时:闸不是仪式,它替你挡的东西一样不会少。" \
    "   本次它挡下的是下面这些,跳闸就逐条自己补上(08-25 的教训:跳闸只补了一半):" >&2
  printf '%s\n' "$skiplist" >&2
fi
exit 3

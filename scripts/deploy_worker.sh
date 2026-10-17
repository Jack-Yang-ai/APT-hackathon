#!/bin/sh
# 部署云代理,**并把这一版源码的指纹一起带上去**。
#
#   sh scripts/deploy_worker.sh
#
# 🔴 别直接 `wrangler deploy` —— 那样线上不带指纹,
# `scripts/check_worker_deployed.sh` 就答不出「线上是哪一版」,对撞失效。
#
# 🔴 **2026-08-25(M2-审22):stamp 从「一句声明」改成「一张回执」。**
# 原来 `wrangler deploy` 退 0 就写 `worker/.deployed_sha` —— 于是离线那道对撞
# (`eval/checks/test_worker_deployed_offline.py`)绿的全部含义只是
# 「有人写过这个文件」,而它读起来像「线上是这一版」。
# 现在**先联网核实 `/version` 回的 `src_sha`,核实过了才写 stamp**:
# 绿从此至少证明「这一版真的上过线」。
# 顺带这也给 `check_worker_deployed.sh` 补上了它一直缺的**调用点**(铁律 5):
# 在此之前全仓只有注释和板子提到它,没有任何脚本跑它,只能靠人记得「发布前跑一下」。
set -eu
cd "$(dirname "$0")/.."

# 脏的 worker/ 不许部署:部署出去的东西必须在版本库里查得到,
# 否则「线上是哪一版」这个问题从源头就没有答案。
if [ -n "$(git status --porcelain worker/)" ]; then
  echo "🔴 worker/ 有未提交的改动 —— 先提交。部署出去的东西必须在版本库里查得到:" >&2
  git status --short worker/ >&2
  exit 2
fi

SHA=$(git rev-parse HEAD:worker/src)
echo "▸ 部署 worker/src 树哈希 $SHA"
cd worker
npx wrangler deploy --var "WORKER_SRC_SHA:$SHA"

# 🔴 **同时把指纹落进版本库**,让「改了 worker/src 却没部署」这件事
# **离线也能被抓到**(`eval/checks/test_worker_deployed_offline.py`,已接进 premerge)。
#
# 为什么要两道:联网那道(check_worker_deployed.sh)更强 —— 它问的是线上真实状态,
# 连「有人手工 wrangler deploy 绕过本脚本」都抓得到;但它要网、要 token,
# **塞进 premerge 会让离线时变假红**,而假红的闸会被人开始跳过。
# 离线这道弱一点(只信这个文件),但它**每次合 TASKS.md 都会跑**。
# 常见的漏法(改完忘了部署)被便宜那道当场抓住,贵那道留给发布前。
cd ..

# 🔴 **先核实线上,再落 stamp。** 顺序反过来 stamp 就退回成「一句声明」。
# 部署要几秒才在边缘全量生效,所以给三次机会 —— 但**只给三次**:
# 一直重试到成功等于把「没生效」磨成「生效了」。
verified=0
for attempt in 1 2 3; do
  if sh scripts/check_worker_deployed.sh; then verified=1; break; fi
  if [ "$attempt" -lt 3 ]; then
    echo "  ↻ 线上还没换过来,3 秒后再问一次($attempt/3)"
    sleep 3
  fi
done

if [ "$verified" != 1 ]; then
  echo "" >&2
  echo "🔴 部署命令跑完了,但**联网核实没通过 ⇒ 不落 stamp**。" >&2
  echo "   stamp 是回执不是声明:核实不了就没有回执,离线那道对撞会照旧红着 —— 这是对的。" >&2
  echo "   ⇒ 上面那条消息说了为什么(没 token 是 2,线上对不上是 3)。" >&2
  echo "   ⚠️ 别手工 printf 一个 stamp 上去补绿 —— 那正是这次改动要堵的洞。" >&2
  exit 3
fi

printf '%s\n' "$SHA" > worker/.deployed_sha
echo "▸ 指纹已落 worker/.deployed_sha(线上核实过)—— **记得连它一起提交**,否则离线那道对撞会红"
git status --short worker/.deployed_sha

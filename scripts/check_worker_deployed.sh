#!/bin/sh
# 线上跑的是不是仓库这一版?(M1-35 的对撞)
#
#   sh scripts/check_worker_deployed.sh     # 0=一致;3=对不上;2=没法判
#
# ## 为什么这道闸非有不可
#
# 铁律 4 的**部署版**:「collector 的行为」有两份出处 ——
# 仓库里的源码,和线上正在跑的版本。对不上时**没有任何东西会报错**,
# 只会让人拿着「我修好了」的印象去做决定。
#
# 2026-08-20 真吃过:`M1-34` 防覆盖的闸 08-19 傍晚提交,当天最后一次部署在 13:47,
# 晚了四五个小时。代价是两块已出稿的音频被覆盖成失败记录。
# 当时 commit 绿、worker 47 条测试绿、premerge 绿。
#
# ⚠️ **比源码指纹,不比行为。** 拿一次成功的请求证明「线上是新的」挡不住
# 下一次改完不部署 —— 行为没变不代表代码没变。
set -eu
cd "$(dirname "$0")/.."

URL="${GROWTH_PROXY_URL:-https://apt-backend.example}"
[ -f "$HOME/.config/growth-agent/secrets.env" ] && . "$HOME/.config/growth-agent/secrets.env"
# ⚠️ 变量名是 `GROWTH_CLIENT_TOKEN`(手机侧填的同一个);worker 那边的 secret 叫
# `CLIENT_TOKEN`,两个名字不一样,写错的表现是「判不了」而不是「判错」,所以两个都认。
TOKEN="${GROWTH_CLIENT_TOKEN:-${CLIENT_TOKEN:-}}"
[ -n "$TOKEN" ] || { echo "🔴 没有 GROWTH_CLIENT_TOKEN,判不了(它在 secrets.env)" >&2; exit 2; }

WANT=$(git rev-parse HEAD:worker/src)
GOT=$(curl -s --max-time 20 -H "X-Growth-Token: $TOKEN" "$URL/version" \
      | sed -n 's/.*"src_sha":"\([^"]*\)".*/\1/p')

if [ -z "$GOT" ]; then
  echo "🔴 线上没回 src_sha —— 要么 /version 还没上线,要么部署时没带指纹。" >&2
  echo "   ⇒ 用 sh scripts/deploy_worker.sh 部署(它会带),别直接 wrangler deploy。" >&2
  exit 3
fi
if [ "$GOT" != "$WANT" ]; then
  echo "🔴 线上跑的不是仓库这一版:" >&2
  echo "   线上   $GOT" >&2
  echo "   仓库   $WANT  (git rev-parse HEAD:worker/src)" >&2
  echo "   ⇒ sh scripts/deploy_worker.sh" >&2
  exit 3
fi
echo "✅ 线上 == 仓库 HEAD 的 worker/src($WANT)"

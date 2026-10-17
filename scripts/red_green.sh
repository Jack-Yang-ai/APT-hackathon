#!/bin/sh
# 照妖镜的收口(M2-审23 ②)—— §3.3 那条:红与绿都必须来自一次真实运行,
# 「还原」的证据只能是 green 阶段的这次通过,cp 的回显没有投票权。
#
# 用法(两个阶段用**同一条**测试命令):
#   sh scripts/red_green.sh red   '<测试命令>'   # 故意改坏之后跑:命令必须失败,登记这次红
#   sh scripts/red_green.sh green '<测试命令>'   # 还原之后跑:必须先有同一条命令的红,这次必须真绿
#
# green 没有 red 在前 ⇒ 拒 —— 没红过的绿证明不了任何东西(复核清单 §八:
# 没有「造脏数据必须转红」对照的断言 = 今天这份数据碰巧干净)。
set -u
mode="${1:-}"; cmd="${2:-}"
if [ -z "$mode" ] || [ -z "$cmd" ]; then
  echo "用法: sh scripts/red_green.sh red|green '<测试命令>'" >&2
  exit 64
fi
gitdir=$(git rev-parse --git-dir 2>/dev/null) || { echo "🔴 不在 git 仓库里" >&2; exit 1; }
state="$gitdir/red_green_state"
sig=$(printf '%s' "$cmd" | shasum -a 256 | cut -d' ' -f1)

case "$mode" in
  red)
    if sh -c "$cmd" >"$gitdir/red_green_red.log" 2>&1; then
      rm -f "$state"
      echo "🔴 期望红,实际绿 —— 改坏没生效,或这条测试根本验不到你改的东西(空转测试,复核清单 §三)。输出尾部:" >&2
      tail -15 "$gitdir/red_green_red.log" >&2
      exit 1
    fi
    printf '%s' "$sig" >"$state"
    echo "🟥 红确认(真实运行,非猜测)。还原后跑:sh scripts/red_green.sh green '<同一条命令>'"
    tail -5 "$gitdir/red_green_red.log"
    ;;
  green)
    if [ ! -f "$state" ] || [ "$(cat "$state")" != "$sig" ]; then
      echo "🔴 这条命令没有登记过红 —— 先改坏跑 red,再还原跑 green。没红过的绿证明不了还原对了。" >&2
      exit 1
    fi
    if sh -c "$cmd" >"$gitdir/red_green_green.log" 2>&1; then
      rm -f "$state"
      echo "🟩 绿由这次真实运行收口(不是 cp 的回显)。输出尾部:"
      tail -5 "$gitdir/red_green_green.log"
    else
      echo "🔴 还原之后还是红 —— 还原不完整,或改坏时动了别的东西。输出尾部:" >&2
      tail -15 "$gitdir/red_green_green.log" >&2
      exit 1
    fi
    ;;
  *)
    echo "用法: sh scripts/red_green.sh red|green '<测试命令>'" >&2
    exit 64
    ;;
esac

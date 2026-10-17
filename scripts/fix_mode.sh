#!/bin/sh
# 修复任务的测试冻结开关(M2-审25 ②)——「修代码的 agent 不能同时削弱对那段代码的检查」。
#
# 用法(路径 = 钉住 bug 的那份失败测试,先提交,再开):
#   sh scripts/fix_mode.sh start <测试文件>...   # 开:冻结这些文件,修复期间 Edit/Write 被拦
#   sh scripts/fix_mode.sh status                # 看:冻着哪些、从什么时候起
#   sh scripts/fix_mode.sh done                  # 关:修完(绿了)之后解冻
#
# 🔴 **开关语义(板上要求写死的三问)**:
#   · 谁开:修 bug 的会话自己,在「失败测试已提交」之后、动手修之前;
#   · 谁关:同一个会话,在修复让那份测试转绿之后(red_green.sh green 收口的那一刻);
#   · 忘了关怎么办:**不静默过期**。下一个碰到冻结文件的人会被拦,拦截消息里写着
#     从什么时候冻的、怎么解 —— 失败可见(§3.2),而不是闸悄悄消失。
#     误伤面 = 清单里那几个文件,一条 done 就解,代价可控。
#
# 🔴 **只冻清单里的精确路径,不冻模式**。冻 `*Tests.swift` 这种模式会把
# 「修复期间给别的模块写新测试」也挡住 —— 误伤一次,这道闸就会被永久绕开。
set -u
# ⚠️ **不 cd 到脚本所在仓** —— 冻结属于**调用者所在的仓**(gitdir 从 cwd 解析)。
# 第一版 cd 了,自检当场抓到:从沙盒仓里调,冻结写进了 growth-app 的 .git。
gitdir=$(git rev-parse --git-dir 2>/dev/null) || { echo "🔴 不在 git 仓库里" >&2; exit 1; }
flag="$gitdir/claude_fix_mode"

case "${1:-}" in
  start)
    shift
    [ $# -ge 1 ] || { echo "用法: sh scripts/fix_mode.sh start <测试文件>..." >&2; exit 64; }
    : > "$flag.tmp"
    for f in "$@"; do
      [ -f "$f" ] || { rm -f "$flag.tmp"; echo "🔴 $f 不存在 —— 手法要求失败测试**先提交**再开冻结,别冻一个还没写的文件" >&2; exit 1; }
      # 存仓相对的规范路径,fix_guard 按它比对
      (cd "$(dirname "$f")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$f")") >> "$flag.tmp"
    done
    mv "$flag.tmp" "$flag"
    echo "🧊 修复期测试冻结已开($#  个文件)。修绿之后:sh scripts/fix_mode.sh done"
    ;;
  status)
    if [ -f "$flag" ]; then
      echo "🧊 冻结中(自 $(date -r "$flag" '+%m-%d %H:%M')):"
      sed 's/^/   · /' "$flag"
    else
      echo "（没有开着的修复冻结）"
    fi
    ;;
  done)
    if [ -f "$flag" ]; then rm -f "$flag"; echo "✅ 冻结已解"; else echo "（本来就没开）"; fi
    ;;
  *)
    echo "用法: sh scripts/fix_mode.sh start <测试文件>... | status | done" >&2
    exit 64
    ;;
esac

#!/usr/bin/env bash
# Mac 上那两个必须一直在跑的东西:装 / 查 / 卸。
#
#   sh scripts/daemons.sh install    # 装上并立刻验证真的在跑
#   sh scripts/daemons.sh status     # 查(能红)
#   sh scripts/daemons.sh uninstall
#
# ## 🔴 为什么要有这个
#
# 2026-08-21 实测:`mac/asr_fallback.py`(`M1-34`)写好、测过、**从来没人常驻**
# ⇒ 某场次 的那一块**干等了 98 分钟**,而它的设计是「超 10 分钟就换 SSE」。
# 同一天写的 `mac/extract_daemon.py` 也只是 `nohup` 起着,Mac 一重启就没了。
#
# **写好了不等于在跑。** 而「没在跑」的表现是「东西一直不出来」——
# 与「上游很慢」在任何一个界面上都长得一模一样。
#
# ⇒ 这个脚本的**重点不是 install,是 status**:装完必须能被查出来真的在跑,
# 否则我们只是把「没人常驻」换成了「以为常驻了」。
set -euo pipefail
cd "$(dirname "$0")/.."

# 仓库根。上面那句 `cd` 已经切到这儿了 —— 存下来给「跑的是不是旧代码」那道闸用。
REPO="$PWD"
AGENTS=(com.growth.extract-daemon com.growth.asr-fallback com.growth.voiceprint-daemon)
DEST="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/growth"

install_all() {
  mkdir -p "$DEST" "$LOGS"
  for a in "${AGENTS[@]}"; do
    cp "scripts/launchd/$a.plist" "$DEST/$a.plist"
    # 先卸再装:改了 plist 而不重载的话,跑的还是旧的那份 ——
    # 而**跑的是哪一份从外面看不出来**。
    launchctl bootout "gui/$UID/$a" 2>/dev/null || true
    # 🔴 `|| { …; continue; }` 不能省(2026-08-24 咬到)。`set -e` 下 bootstrap
    # 失败会让整个 install **当场退出**,而后面几个 daemon 的 plist
    # **连 cp 都没执行到** —— 表现是「装了一个,另外两个查无此服务」,
    # 与「装完了但没起来」长得完全不一样,查错方向会跑偏。
    # 与 status 里那个 `grep || true` 是同一个形态(同一天修的第二处)。
    if ! launchctl bootstrap "gui/$UID" "$DEST/$a.plist" 2>&1; then
      echo "🔴 $a 装不上 —— 上面是 launchd 的原话;**其余的照装**" >&2
      continue
    fi
    echo "▸ 装上 $a"
  done
  echo "▸ 等 5 秒看它们真的动起来…"
  sleep 5
  status_all
}

status_all() {
  local bad=0
  for a in "${AGENTS[@]}"; do
    if ! launchctl print "gui/$UID/$a" >/dev/null 2>&1; then
      echo "🔴 $a **没装上**" >&2; bad=1; continue
    fi
    # 🔴 **「装上了」不等于「在跑」。** launchd 会老老实实把一个每次启动就崩的
    # 东西反复拉起来,而 `launchctl list` 里它看起来一切正常。
    # 判据取**日志有没有在长** —— 那是它真的干过活的唯一证据。
    local log="$LOGS/$a.log"
    if [ ! -s "$log" ]; then
      echo "🔴 $a 装上了,但 $log 是空的 —— 它可能每次起来就崩" >&2; bad=1; continue
    fi
    local age=$(( $(date +%s) - $(stat -f %m "$log") ))
    # 🔴 **静默多久算死,由 daemon 自己在心跳里声明,这里只负责读。**
    #
    # 上一版这里写死 900 秒,而 `extract_daemon.py` 只在**有待办时**才打印
    # ⇒ 「闲了一天」与「挂了一天」的日志一模一样,于是这里只能输出一句
    # 「确认它是闲着还是挂了」——**把判断推回给人**,而这个脚本存在的全部意义
    # 就是不要那样(见文件头)。现在 extract-daemon 空转也打心跳,
    # 「日志不动」因此只剩一种解释:**死了** ⇒ 这一档从 ⚠️ 升成 🔴。
    #
    # 阈值从日志里读,而不是在这儿再写一个数:两处各写一份「多久算死」,
    # 改一边忘另一边**不会有任何东西红**(铁律 4)。
    # 读不到声明 ⇒ 退回 900,并**说出来**,别让「没有心跳」看起来像「查过了」。
    # ⚠️ `|| true` 不能省。`set -e` 下,grep 找不到就是退出码 1,而这是
    # **预期情况**(asr-fallback 每 120 秒必打印,不需要心跳声明)。
    # 少了它,脚本会在第一个没有心跳的 daemon 上**当场退出**——
    # 而表现是「查了一个、退出码 1」,看起来跟「查完了有问题」一模一样。
    local limit; limit=$(grep -o '最多 [0-9]* 秒不吭声' "$log" | tail -1 | tr -cd '0-9' || true)
    local how="daemon 自己声明的"
    if [ -z "$limit" ]; then limit=900; how="默认值(这个 daemon 没声明心跳周期)"; fi
    if [ "$age" -gt "$limit" ]; then
      echo "🔴 $a 在册,但日志 $((age / 60)) 分钟没动过(上限 $limit 秒,$how)——它挂了" >&2
      tail -2 "$log" | sed 's/^/     /' >&2; bad=1
    else
      echo "✅ $a 在跑(日志 $age 秒前动过,上限 $limit 秒 · $how)"
    fi
    # 🔴 **「在跑」不等于「跑的是现在这份代码」。**(2026-08-25 实测,铁律 5 的第四种形态)
    #
    # `extract_daemon.py` 的进程起于 **08-24 16:24:49**,而源码 **16:55** 才改成
    # 支持两阶段(`M2-成7`)。进程比代码早 31 分钟起来,从那以后**一直跑着旧代码** ——
    # 于是两阶段进生产之后,daemon 把所有 `lines` 型 job 全拒了(「没有 prompt」),
    # 抽取整整一天一条都没跑,而 `status` 说它「✅ 在跑」、心跳也一直绿。
    #
    # ⚠️ 这不是「忘了重启」这条纪律能挡的:改代码的人与看 status 的人
    # 得到的信息**都是对的**,只是没人把两个时刻放在一起比。
    # ⇒ 比给机器看:**进程启动时刻 < 脚本最后修改时刻 = 在跑的是旧的**。
    # ⚠️ 只抠**相对路径**:plist 里写的是 `$HOME/APT/mac/xxx.py`,
    # 不是字面的仓库路径 —— 按字面路径 grep 会一个都匹配不上,
    # 而那时这道闸会**安静地什么都不查**(第一版就是这么绿的)。
    local rel; rel=$(grep -o 'mac/[a-z_]*\.py' "$DEST/$a.plist" 2>/dev/null | head -1 || true)
    local script="$REPO/$rel"
    if [ -n "$rel" ] && [ -f "$script" ]; then
      local started; started=$(ps -p "$(pgrep -f "$script" | head -1)" -o lstart= 2>/dev/null || true)
      if [ -n "$started" ]; then
        local st; st=$(date -j -f "%a %b %e %T %Y" "$started" +%s 2>/dev/null || echo 0)
        local mt; mt=$(stat -f %m "$script")
        if [ "$st" -gt 0 ] && [ "$st" -lt "$mt" ]; then
          echo "🔴 $a 跑的是**旧代码**:进程起于 $(date -r "$st" '+%m-%d %H:%M')," >&2
          echo "     而 $(basename "$script") 最后改于 $(date -r "$mt" '+%m-%d %H:%M')" >&2
          echo "     ⇒ sh scripts/daemons.sh install  (它先卸再装 = 重启;" >&2
          echo "        改完代码不重启的表现是「改了没生效」,而 status 全绿)" >&2
          bad=1
        fi
      fi
    fi

    # 崩循环的特征:日志里堆着同一条报错。
    if tail -20 "$log" | grep -qiE "Traceback|ModuleNotFoundError|缺环境变量"; then
      echo "🔴 $a 的日志里有崩溃痕迹:" >&2
      tail -4 "$log" | sed 's/^/     /' >&2; bad=1
    fi
  done
  [ "$bad" -eq 0 ] || { echo "" >&2; echo "🔴 上面这些要先修好 —— 它们不跑的表现是「东西一直不出来」" >&2; exit 1; }
}

uninstall_all() {
  for a in "${AGENTS[@]}"; do
    launchctl bootout "gui/$UID/$a" 2>/dev/null || true
    rm -f "$DEST/$a.plist"
    echo "▸ 卸掉 $a"
  done
}

case "${1:-status}" in
  install)   install_all ;;
  status)    status_all ;;
  uninstall) uninstall_all ;;
  *) echo "用法:sh scripts/daemons.sh [install|status|uninstall]" >&2; exit 2 ;;
esac

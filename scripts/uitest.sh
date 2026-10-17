#!/usr/bin/env bash
# 导航走查台的驱动。
#
#   scripts/uitest.sh --db <一份 growth.sqlite>  [--device "iPhone 17 Pro"]
#
# 它做四件事:build-for-testing → 装包 → **把库灌进容器** → 跑走查。
#
# ## 为什么灌库是从容器外面灌,不是给 App 加个开关
#
# `AppDatabase.sharedResult` 是 `static let`,一个进程只求值一次;
# 每次 `app.launch()` 都是新进程,所以**盘上的文件换掉就够了**。
# 给生产代码加一个「测试库路径」的注入口,等于为了测试给 App 开一个新面 ——
# 而 App 这一侧一行都不用改。
#
# ⚠️ 装包不会清数据容器(同 bundle id 重装保留 Library/),所以
# 「装 → 灌 → 跑」这个顺序成立;`test-without-building` 那一步的重装也不会冲掉。
#
# ## 🔴 为什么开头要拦「别人正在用这台模拟器」
#
# 2026-08-19 实测踩过:另一个会话在 `/Users/YOUR_USER/growth-app/ios` 跑
# `xcodebuild test -destination 'name=iPhone 17'`,它每跑一轮就
# install + launch + **force-quit** 一次。表现是走查台跑到一半 App 突然退到桌面,
# 而日志里写的是 `Termination requested by simulator host` ——
# **看起来和「App 崩了」一模一样**,当场就会被误判成产品缺陷(我误判过一次)。
# CLAUDE.md 那条「只让一个会话碰 ios/」说的就是这个。
set -euo pipefail
cd "$(dirname "$0")/../ios"

DB=""
DEVICE="iPhone 17 Pro"
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --db)     DB="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    # 只跑一条(诊断用):--only testPeopleListReachesThatPersonsProfile
    # ⚠️ 跑完**不算走过一轮** —— 见下面那行警告。
    --only)   ONLY="$2"; shift 2 ;;
    *) echo "不认识的参数:$1" >&2; exit 2 ;;
  esac
done

# 库必须显式给。**不给一个默认值** —— 默认值会让人在空库上跑出一片绿,
# 而空库上每一条断言都是真空放行(§3.3 验「落对没落对」)。
if [ -z "$DB" ]; then
  cat >&2 <<'MSG'
要一份 growth.sqlite 才能跑:scripts/uitest.sh --db <路径>

真机那份怎么取(单用户自用期,从 Xcode 的 Devices & Simulators 里
把 GrowthApp 的容器下下来,库在 Library/Application Support/growth.sqlite)。
模拟器里现成的那份:
  xcrun simctl get_app_container <UDID> com.growth.app data
MSG
  exit 2
fi
[ -f "$DB" ] || { echo "库不在:$DB" >&2; exit 2; }

# ⚠️ **先解析 UDID,再拦占用** —— 顺序不能反,见下面那道闸为什么要认两种写法。
UDID=$(xcrun simctl list devices available \
       | awk -v d="$DEVICE" '$0 ~ d " \\(" {print $0}' \
       | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' | head -1)
[ -n "$UDID" ] || { echo "找不到模拟器「${DEVICE}」" >&2; exit 2; }
echo "▸ 模拟器 $DEVICE ($UDID)"

# ── 拦「别人正在用」 ────────────────────────────────────────────────
#
# 🔴 **认设备名**和**认 UDID**都要,少一种就有洞。
# 2026-08-19 这个洞真的咬了:另一个会话跑的是
#   `xcodebuild test ... -destination 'platform=iOS Simulator,id=EEC04BF3-…'`
# **用 UDID,不带设备名** ⇒ 原来那条只 grep `$DEVICE` 的闸完全看不见它,
# 而那是同一台机器。后果与本注释警告的一模一样:App 被 force-quit、
# `Lost connection to the application`,而现场与「App 崩了」分不出来。
# ⚠️ 更贵的是它把人引向错的根因:那半天的间歇失败被归给了别的东西。
if pgrep -f "xcodebuild.*($DEVICE|$UDID)" | grep -qv "^$$\$"; then
  echo "🔴 已经有一个 xcodebuild 在用「${DEVICE}」($UDID)了。" >&2
  echo "   两个会话共用一台模拟器时,后来的会把先来的 App force-quit 掉," >&2
  echo "   而现场与「App 崩了」一模一样。换一台:--device '别的名字'" >&2
  ps aux | grep "[x]codebuild" >&2
  exit 3
fi

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

# 🔴 **必须先生成工程。** `GrowthAppUITests` target 与 `GrowthAppWalk` scheme
# **只写在 `ios/project.yml` 里**,而 `.xcodeproj` 是 gitignore 的生成物 ——
# 干净 checkout 上(或别人上次生成时还没有这两样)直接撞
# 「scheme GrowthAppWalk not found」,而错误信息里没有一个字提到 xcodegen。
# 2026-08-19 子 Agent 接手时就撞上了。
command -v xcodegen >/dev/null || { echo "🔴 缺 xcodegen:brew install xcodegen" >&2; exit 2; }
xcodegen generate >/dev/null

echo "▸ build-for-testing"
xcodebuild build-for-testing -project GrowthApp.xcodeproj -scheme GrowthAppWalk \
  -destination "id=$UDID" -derivedDataPath DerivedData -quiet

echo "▸ 装包"
xcrun simctl install "$UDID" \
  DerivedData/Build/Products/Debug-iphonesimulator/GrowthApp.app

echo "▸ 灌库"
CONT=$(xcrun simctl get_app_container "$UDID" com.growth.app data)
mkdir -p "$CONT/Library/Application Support"
# WAL 三件套一起处理:只换主文件而留着旧的 -wal,读出来的是**两份混合**的东西。
rm -f "$CONT/Library/Application Support/growth.sqlite-wal" \
      "$CONT/Library/Application Support/growth.sqlite-shm"
cp "$DB" "$CONT/Library/Application Support/growth.sqlite"

# ── 把库整体平移到今天(M2-走5) ──────────────────────────────────
#
# 🔴 **为什么非做不可**:固定库快照里最新的一天就是录制那天,而首页
# 「今天的场次」那一块只显示今天 —— 于是走查一过夜就凭空红,
# 而红的原因**与被测的东西无关**。2026-08-19→20 实测:同一份库、同一份代码,
# 20:00 跑 1 红,次日早晨跑 4 红。
# ⚠️ 这是**假红,和假绿一样贵**:一个天天红的走查台,下一个人会开始跳过它,
# 于是真缺陷混在里面没人看。今天就差点把它读成「我改坏了 3 条」。
#
# ⚠️ **只动容器里那一份,不碰 --db 指的素材**(上面刚 cp 过来)。
# ⚠️ 只改日期那 10 个字符,保住 `+08:00` 后缀 —— 用 sqlite 的 datetime()
#    会把带时区的串换算成 UTC 并丢掉后缀,App 那边的解析口径就变了。
# ⚠️ 只动 `day` 长得像日期的行 —— 库里有 `day = seal-…` 这种非日期行。
TARGET="$CONT/Library/Application Support/growth.sqlite"
if command -v sqlite3 >/dev/null; then
  DATELIKE="day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'"
  N=$(sqlite3 "$TARGET" "SELECT CAST(julianday('now','localtime') - julianday(MAX(day)) AS INTEGER) FROM sessions WHERE $DATELIKE;")
  if [ -n "$N" ] && [ "$N" -gt 0 ] 2>/dev/null; then
    sqlite3 "$TARGET" "
      UPDATE sessions SET
        day        = date(day, '+$N days'),
        started_at = date(substr(started_at,1,10), '+$N days') || substr(started_at,11),
        ended_at   = CASE WHEN ended_at IS NULL THEN NULL
                     ELSE date(substr(ended_at,1,10), '+$N days') || substr(ended_at,11) END
      WHERE $DATELIKE;"
    echo "  已把库整体往后平移 $N 天,让最新的一天落在今天(见脚本里的理由)"
  fi
  # 落对没落对:平移完今天必须真有场次,否则这一步等于没做而没人会发现。
  TODAY=$(sqlite3 "$TARGET" "SELECT COUNT(*) FROM sessions WHERE day = date('now','localtime');")
  [ "$TODAY" -gt 0 ] || { echo "🔴 平移之后今天仍然 0 场 —— 这一步没生效,走查会假红" >&2; exit 4; }
  echo "  今天 $TODAY 场"
fi
# 报一下灌进去的是什么。**只报不拦** —— 场次数的下界是台子自己的判据
# (`testFixtureHasAtLeastTwoSessions`),在这里再写一遍就成了第二个出处。
if command -v sqlite3 >/dev/null; then
  echo "  灌进去:$(sqlite3 "$DB" 'select count(*) from sessions;') 场 / \
$(sqlite3 "$DB" 'select count(*) from transcript_lines;') 行转写"
fi

echo "▸ 走查"
# 🔴 `--only` 存在的理由是诊断一条红要 4 分钟太慢;它的**危险**是有人拿单条的绿
# 当成一轮走过了。所以这里把话说死,而不是指望用的人记得。
if [ -n "$ONLY" ]; then
  echo "⚠️ 只跑 $ONLY —— **这一轮不算走查跑过**,收工前必须不带 --only 再跑一遍全量。"
  xcodebuild test-without-building -project GrowthApp.xcodeproj -scheme GrowthAppWalk \
    -destination "id=$UDID" -derivedDataPath DerivedData \
    -only-testing:"GrowthAppUITests/ScreenWalkTests/$ONLY"
else
  xcodebuild test-without-building -project GrowthApp.xcodeproj -scheme GrowthAppWalk \
    -destination "id=$UDID" -derivedDataPath DerivedData
fi

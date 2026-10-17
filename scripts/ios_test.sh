#!/bin/sh
# iOS 测试的收口包装(M2-审23 ②)—— 复核清单 §1.1 三个绿的机械化:
#   · 不给 xcodebuild 接管道(head 读够就关管道 ⇒ SIGPIPE 杀构建而 shell 报 0)⇒ 输出进文件;
#   · 判定看「Executed N tests」的 N,不看 SUCCEEDED 的颜色;
#   · N = 0 即红 —— scheme 的 skippedTests 盖得过 -only-testing,
#     新测试文件忘了 `xcodegen generate` 也长这样(2026-08-25 踩过)。
#
# 用法:
#   sh scripts/ios_test.sh [xcodebuild 追加参数...]
#   IOS_TEST_MIN=57 sh scripts/ios_test.sh          # 有地板传地板,默认 1(只防 0)
#   IOS_TEST_DEST='platform=iOS Simulator,name=iPhone 17 Pro' 可覆盖 destination
# 自检钩子(premerge 用,不跑 xcodebuild,只跑判定):
#   sh scripts/ios_test.sh --parse-only <日志文件> <xcodebuild退出码>
set -u

verdict() { # $1=日志 $2=退出码
  log="$1"; rc="$2"; min="${IOS_TEST_MIN:-1}"
  n=$(grep -Eo 'Executed [0-9]+ test' "$log" 2>/dev/null | grep -Eo '[0-9]+' | sort -n | tail -1)
  if [ "$rc" -ne 0 ]; then
    echo "🔴 xcodebuild 退出码 $rc(完整日志:$log),尾部:" >&2
    tail -30 "$log" >&2 2>/dev/null
    return 1
  fi
  if [ -z "${n:-}" ]; then
    echo "🔴 日志里找不到「Executed N tests」—— 一条测试都没被执行" >&2
    echo "   (锁屏卡住?destination 不对?只 build 没 test?)日志:$log" >&2
    return 1
  fi
  if [ "$n" -lt "$min" ]; then
    echo "🔴 Executed $n tests < 地板 $min —— SUCCEEDED 不算数。" >&2
    echo "   先查:scheme 的 skippedTests / 新测试文件是否忘了 xcodegen generate。日志:$log" >&2
    return 1
  fi
  echo "✅ Executed $n tests(地板 $min)· 日志:$log"
  return 0
}

if [ "${1:-}" = "--parse-only" ]; then
  verdict "$2" "$3"
  exit $?
fi

cd "$(dirname "$0")/../ios"
log="${IOS_TEST_LOG:-${TMPDIR:-/tmp}/growth_ios_test.log}"
xcodebuild test -scheme "${IOS_TEST_SCHEME:-GrowthApp}" \
  -destination "${IOS_TEST_DEST:-platform=iOS Simulator,name=iPhone 17 Pro}" \
  -derivedDataPath DerivedData "$@" >"$log" 2>&1
verdict "$log" "$?"

#!/usr/bin/env bash
# 把当前工作区装到连着的真机上。
#
#   scripts/install_device.sh
#
# ## 🔴 为什么要有这个脚本
#
# 签名那四个参数原来**只活在 `ios/project.yml` 的一段注释里**。
# 2026-08-21 我照着「通用构建 + devicectl 装」走,连撞两次
# `ApplicationVerificationFailed / No code signature found` ——
# 而 **`xcodebuild` 两次都报 BUILD SUCCEEDED**,包是未签的。
#
# 那段注释写得很清楚(连「光传 CODE_SIGNING_ALLOWED=YES 不够」都写了),
# 而我没找到它 —— 这正是复核清单 §五那条:**把要求写进注释不等于守住了它**。
# ⇒ 现在它是一条能跑的命令,不是一段要靠人翻到的文字。
set -euo pipefail
cd "$(dirname "$0")/../ios"

# 🔴 **不走 `xcodebuild -destination id=<UDID>`。** 实测两套视图会不一致:
# `devicectl` 说 `available (paired)`,而 `xcrun xctrace list devices` 把同一台手机
# 列在「Devices Offline」下面 —— 那时 xcodebuild 找不到目标,而 devicectl 装得进去。
# ⇒ 构建用 `generic/platform=iOS`(不需要看见设备),安装交给 devicectl。
# ⚠️ 按 **UUID 的形状**抠,不按字段序号。第一版写的是 `$(NF-4)`,
# 而型号那列是「iPhone 14 Pro Max (iPhone15,3)」共 5 个词 ⇒ 抠出来的是字符串 "iPhone"。
# 列宽会随设备名变,**位置不是稳定的东西,形状才是**。
# ⚠️ 'unavailable' 也含子串 'available':先排除它,不然会抠到不在线的旧手机(2026-10-17 实测)。
CORE=$(xcrun devicectl list devices 2>/dev/null \
       | grep -i iPhone | grep -vi unavailable | grep -Ei 'available|connected' \
       | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
if [ -z "${CORE:-}" ]; then
  echo "🔴 devicectl 看不到 iPhone。插上线、解锁屏幕,再跑一次。" >&2
  exit 1
fi
echo "▸ CoreDevice $CORE"

xcodegen generate >/dev/null

# ⚠️ **四个参数缺一不可。** `project.yml` 里默认是不签的(CI 用),
# 而 `CODE_SIGN_IDENTITY: ""` 会盖过只传 CODE_SIGNING_ALLOWED=YES 的写法。
echo "▸ 构建(带签名)"
xcodebuild -project GrowthApp.xcodeproj -scheme GrowthApp \
  -destination "generic/platform=iOS" -derivedDataPath DerivedData -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_IDENTITY="Apple Development" build > /tmp/growth_devbuild.log 2>&1 \
  || { tail -30 /tmp/growth_devbuild.log; echo "🔴 构建失败,全文见 /tmp/growth_devbuild.log" >&2; exit 1; }
# ⚠️ **不要写成 `xcodebuild … | tail -3`。** 管道会吃掉退出码(POSIX sh 没有 pipefail),
# 而且实测还会让下一步的验签跑在包写完之前 —— 第一版就是这样,报「没签上」而其实签了。
# 这与 `eval/checks/premerge.sh` 那个假绿是同一个形状。
tail -2 /tmp/growth_devbuild.log

APP="DerivedData/Build/Products/Debug-iphoneos/GrowthApp.app"
# 🔴 **装之前先验签。** `xcodebuild` 未签也报 SUCCEEDED —— 那正是这个脚本存在的理由,
# 不验的话失败会推迟到 installd,而它的报错指向的是设备不是构建。
# 🔴 **别写成 `codesign … | grep -q`。** `grep -q` 一命中就退出 ⇒ codesign 收到 SIGPIPE
# 而非零退出 ⇒ `set -o pipefail` 把整条管道判失败 ⇒ **签了也报「没签上」**。
# 实测踩到过。先把输出收进变量,再匹配。
sig=$(codesign -dv "$APP" 2>&1 || true)
case "$sig" in
  *TeamIdentifier=*) ;;
  *) echo "🔴 包没签上,而 build 报了 SUCCEEDED —— 别装,先查上面四个参数有没有被覆盖。" >&2
     exit 1 ;;
esac
echo "▸ 安装"
xcrun devicectl device install app --device "$CORE" "$APP" | grep -E "App installed|bundleID|rror"

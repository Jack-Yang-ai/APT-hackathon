#!/usr/bin/env bash
# 构建可装真机的签名包(M0-1f ③)。
#
# 为什么用命令行覆盖而不改 project.yml:CI 与本地都跑无签名构建
# (`CODE_SIGNING_ALLOWED: NO`),把签名写进工程文件会让 CI 一起要证书。
# 覆盖只在这条命令里生效,CI 一个字都不用改。
#
# ⚠️ 四个变量缺一不可。**只覆盖 CODE_SIGNING_ALLOWED / REQUIRED 是不够的** ——
# project.yml 里 `CODE_SIGN_IDENTITY: ""` 会让它用空身份签,结果是
# `BUILD SUCCEEDED` 但 `codesign --verify` 报 "code object is not signed at all"。
# 实测踩过一次:绿了,却装不上。所以下面每次都跑一遍 codesign --verify。
set -euo pipefail

cd "$(dirname "$0")/../ios"

TEAM="${GROWTH_TEAM_ID:-YOUR_TEAM_ID}"
OUT="DerivedData-device"

xcodegen generate >/dev/null

xcodebuild -scheme GrowthApp -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM="$TEAM" \
  -allowProvisioningUpdates build

APP="$OUT/Build/Products/Debug-iphoneos/GrowthApp.app"

# 落对没落对:BUILD SUCCEEDED 不代表签上了
codesign --verify --verbose "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E '^Identifier|^Authority: Apple Development'

ABS="$(pwd)/$APP"          # 已经 cd 进 ios/ 了,直接取当前目录

echo
echo "✓ 已签名:$ABS"
echo
echo "装到手机上(手机连着 Mac、已解锁、已信任本机):"
echo "  xcrun devicectl list devices        # 先看设备在不在线,拿它的 Identifier"
echo "  xcrun devicectl device install app --device <Identifier> \"$ABS\""

#!/bin/zsh
set -eu
cd "$(dirname "$0")"
APP="../APT.app"
# This path is a generated package only; saved data remains in Application Support.
rm -rf -- "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Data" "$APP/Contents/Frameworks" ../work/ime-build
xcrun clang -fobjc-arc -target arm64-apple-macosx13.0 -I Vendor/dist/include -c Sources/RimeBridge.m -o ../work/ime-build/RimeBridge.o
xcrun swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macosx13.0 -import-objc-header Sources/RimeBridge.h Sources/IME.swift Sources/InputSource.swift Sources/Shortcuts.swift Sources/AU05Protocol.swift Sources/AU05HID.swift Sources/AU05.swift Sources/AU05Settings.swift Sources/EchoSettings.swift Sources/MemoryLog.swift Sources/DayDigest.swift Sources/MemoryActivity.swift Sources/GrowthMemorySync.swift Sources/StyleProfile.swift Sources/MeetingNotes.swift Sources/SmartMemory.swift Sources/AgentModels.swift Sources/LocalMemory.swift Sources/InputMemoryUI.swift Sources/VoiceCore.swift Sources/VoicePolish.swift Sources/VoiceInput.swift Sources/VoiceRecord.swift Sources/EchoUI.swift Sources/MemoryWindow.swift Sources/MemoryInline.swift Tests/InlineChecks.swift Tests/InputMemoryChecks.swift Tests/VoiceChecks.swift Tests/TypingChecks.swift Tests/SettingsChecks.swift Tests/UIReviewChecks.swift Tests/AU05Checks.swift Tests/DayChecks.swift Tests/GrowthMemoryChecks.swift Tests/MemoryActivityChecks.swift Tests/StyleChecks.swift Tests/MeetingChecks.swift Tests/VectorChecks.swift ../work/ime-build/RimeBridge.o Vendor/dist/lib/librime.1.17.0.dylib -Xlinker -rpath -Xlinker @executable_path/../Frameworks -framework Cocoa -framework InputMethodKit -framework Carbon -framework Security -framework AVFoundation -framework SwiftUI -framework IOKit -framework CoreAudio -o "$APP/Contents/MacOS/APT"
cp Vendor/dist/lib/librime.1.17.0.dylib "$APP/Contents/Frameworks/librime.1.dylib"
cp Data/*.yaml Data/*.txt "$APP/Contents/Resources/Data/"
cp -R Vendor/share/opencc "$APP/Contents/Resources/Data/"
cp Resources/auth.py Resources/fetch.py Resources/bridge.py Resources/lark.py Resources/memory_index.py "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/zh-Hans.lproj"
for language in en zh-Hans; do
cat > "$APP/Contents/Resources/$language.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "APT 输入法";
"CFBundleDisplayName" = "APT 输入法";
"local.echo.inputmethod.memory" = "APT 输入法";
"local.echo.inputmethod.memory.hans" = "APT 输入法";
STRINGS
cp "$APP/Contents/Resources/$language.lproj/InfoPlist.strings" "$APP/Contents/Resources/$language.lproj/Localizable.strings"
 done
cp "$APP/Contents/Resources/en.lproj/InfoPlist.strings" "$APP/Contents/Resources/InfoPlist.strings"
cp *LICENSE.txt "$APP/Contents/Resources/"
cp ../Brand/APTAppIcon.icns ../Brand/APTMenuIconTemplate.tiff ../Brand/APTLogo.png ../Brand/APTAgent.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>APTAppIcon.icns</string>
<key>CFBundleExecutable</key><string>APT</string>
<key>CFBundleIdentifier</key><string>local.echo.inputmethod.memory</string>
<key>CFBundleName</key><string>APT</string>
<key>CFBundleDisplayName</key><string>APT 输入法</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>76</string>
<key>CFBundleShortVersionString</key><string>0.17.16</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>LSBackgroundOnly</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>tsInputMethodIconFileKey</key><string>APTMenuIconTemplate.tiff</string>
<key>tsInputMethodCharacterRepertoireKey</key><array><string>Hans</string></array>
<key>NSMicrophoneUsageDescription</key><string>按语音快捷键时录音，并发送到 StepFun 转为输入文字。</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>InputMethodConnectionName</key><string>local.echo.inputmethod.memory_Connection</string>
<key>InputMethodServerControllerClass</key><string>EchoInputController</string>
<key>TISInputSourceID</key><string>local.echo.inputmethod.memory</string>
<key>ComponentInputModeDict</key><dict>
<key>tsInputModeListKey</key><dict>
<key>local.echo.inputmethod.memory.hans</key><dict>
<key>TISInputSourceID</key><string>local.echo.inputmethod.memory.hans</string>
<key>TISIntendedLanguage</key><string>zh-Hans</string>
<key>tsInputModeMenuIconFileKey</key><string>APTMenuIconTemplate.tiff</string>
<key>tsInputModePaletteIconFileKey</key><string>APTMenuIconTemplate.tiff</string>
<key>tsInputModeCharacterRepertoireKey</key><array><string>Hans</string></array>
<key>tsInputModeDefaultStateKey</key><true/>
<key>tsInputModeIsVisibleKey</key><true/>
<key>tsInputModePrimaryInScriptKey</key><true/>
<key>tsInputModeScriptKey</key><string>smUnicodeScript</string>
</dict></dict>
<key>tsVisibleInputModeOrderedArrayKey</key><array><string>local.echo.inputmethod.memory.hans</string></array>
</dict>
</dict></plist>
PLIST
python3 ../../../scripts/ime_package.py "$APP"
codesign --force --sign - "$APP/Contents/Frameworks/librime.1.dylib"
codesign --force --sign - "$APP"
echo "已构建：$APP"

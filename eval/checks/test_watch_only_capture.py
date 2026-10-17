#!/usr/bin/env python3
"""本版只支持Watch采集:手机不能恢复录音内核/麦克风入口,Watch接线必须在。

源闸守构造/权限,UI走查守按钮,生产收件测试守后续处理。不是仅隐藏一个按钮。
"""
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[2]
CTOR = re.compile(r'\b(?:RecordingKernel|AVAudioEngine|AVAudioRecorder)\s*\(')
MIC = re.compile(r'\b(?:requestRecordPermission|requestAccess\s*\(\s*for:\s*\.audio)')


def code(text):
    return '\n'.join(line.split('//', 1)[0] for line in text.splitlines())


def violations(phone, watch, phone_plist, watch_plist):
    failures = []
    for path, text in phone.items():
        if path == 'Recording/RecordingKernel.swift':
            continue  # 两target共用内核,手机只调纯静态账本工具,生产构造只能在Watch。
        if CTOR.search(code(text)) or MIC.search(code(text)):
            failures.append(f'{path}: 手机端出现采集构造或麦克风请求')
    if phone_plist.get('NSMicrophoneUsageDescription') is not None:
        failures.append('手机恢复了麦克风声明')
    if not watch_plist.get('NSMicrophoneUsageDescription'):
        failures.append('Watch缺麦克风声明')
    if 'audio' not in watch_plist.get('UIBackgroundModes', []):
        failures.append('Watch缺后台audio模式')
    recorder = code(watch.get('WatchRecorder.swift', ''))
    if not (CTOR.search(recorder) and 'kernel.start()' in recorder and 'source: SessionSource.watch' in recorder):
        failures.append('Watch采集入口未接线')
    return failures


def main():
    # 照妖镜:干净的两端、误恢复手机内核、误恢复手机权限、切断Watch均必须分得清。
    good_phone = {'Presentation/ViewModel.swift': 'class ViewModel {}'}
    good_watch = {'WatchRecorder.swift': 'kernel = RecordingKernel(dir: d, source: SessionSource.watch); kernel.start()'}
    good_plist = {'NSMicrophoneUsageDescription': '手表录音', 'UIBackgroundModes': ['audio']}
    assert not violations(good_phone, good_watch, {}, good_plist)
    assert violations({'X.swift': 'let x = RecordingKernel(dir: d)'}, good_watch, {}, good_plist)
    assert violations({'../RootView.swift': 'let x = AVAudioRecorder(url: u, settings: s)'}, good_watch, {}, good_plist)
    assert violations(good_phone, good_watch, {'NSMicrophoneUsageDescription': '录音'}, good_plist)
    assert violations(good_phone, {}, {}, good_plist)
    phone = {str(p.relative_to(ROOT / 'ios/GrowthApp')): p.read_text() for p in (ROOT / 'ios/GrowthApp').rglob('*.swift')}
    # 手机target另编译ios根目录的Theme/DesignSystem/RootView/TimelineComponents。
    # 一并守住根目录生产源,否则在那里恢复采集能绕过目录闸。
    phone.update({f'../{p.name}': p.read_text() for p in (ROOT / 'ios').glob('*.swift')})
    watch = {str(p.relative_to(ROOT / 'ios/GrowthWatch')): p.read_text() for p in (ROOT / 'ios/GrowthWatch').rglob('*.swift')}
    failures = violations(phone, watch,
        plistlib.loads((ROOT / 'ios/GrowthApp/Info.plist').read_bytes()),
        plistlib.loads((ROOT / 'ios/GrowthWatch/Info.plist').read_bytes()))
    if failures:
        print('🔴 Watch-only采集契约被破坏:\n' + '\n'.join(failures))
        return 1
    print('✅ 只有Watch生产构造采集内核与声明麦克风,手机接收/处理;照妖镜红绿通过')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

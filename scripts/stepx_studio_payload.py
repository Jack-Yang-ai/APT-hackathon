#!/usr/bin/env python3
"""Build a byte-exact Studio sync file from maintained StepX source (no secrets)."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / 'stepx-client'
PAGES = {'AskPage', 'NowPage', 'MePage', 'ActionsPage', 'SettingsPage', 'MatterDetailPage',
         'BackScreenPage', 'EventPage', 'RecordingsPage'}


def sources():
    files = {}
    for path in sorted((CLIENT / 'src/growth').glob('*.ts')):
        files['src/shared/growth/' + path.name] = path.read_text()
    for path in sorted((CLIENT / 'src/ask').glob('*.ts')):
        files['src/shared/ask/' + path.name] = path.read_text()
    for path in sorted((CLIENT / 'src/ui').iterdir()):
        prefix = 'src/app/' if path.name in {'App.tsx', 'ios-theme.css'} else (
            'src/app/layout/' if path.stem in {'AppShell', 'returnTo'} else (
                'src/app/pages/' if path.stem in PAGES else 'src/app/components/'))
        files[prefix + path.name] = path.read_text()
    files['src/shared/ask/service.ts'] = (CLIENT / 'chat-service.ts').read_text()
    files['src/shared/config/app.ts'] = (CLIENT / 'src/config/app.ts').read_text()
    files['index.html'] = (CLIENT / 'index.html').read_text()
    files['capsule/manifest.json'] = (CLIENT / 'capsule/manifest.json').read_text()
    files['vite.config.ts'] = (CLIENT / 'vite.config.ts').read_text()
    files['startup-vite.ts'] = (CLIENT / 'startup-vite.ts').read_text()
    for source, target in [('root-recording.test.mjs', 'apt-root-integration.test.mjs'),
                           ('backscreen.test.mjs', 'apt-back-ui.test.mjs'),
                           ('recording.test.mjs', 'stepx-recording.test.mjs')]:
        text = (CLIENT / 'test' / source).read_text()
        text = text.replace("new URL('../src/growth/", "new URL('./src/shared/growth/")
        text = text.replace("new URL('../src/ui/", "new URL('./src/app/layout/")
        files[target] = text
    # The public snapshot does not ship docs/intents; require the operator to
    # supply these two internal specs explicitly instead of failing obscurely.
    for name, relative in [('apt-stepx-1406-spec.md', 'docs/intents/StepX-ios-1406-alignment/spec.md'),
                           ('apt-stepx-ui-parity-spec.md', 'docs/intents/StepX-ui-parity/spec.md')]:
        source = ROOT / relative
        if not source.is_file():
            raise SystemExit(f'公开快照不包含内部规格 {relative}；请在私有检出中运行，或用 --mirror 提供本地镜像。')
        files[name] = source.read_text()
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--mirror', type=Path, help='Optional complete local Studio source mirror')
    args = parser.parse_args()
    files = sources()
    manifest = {name: {'sha256': hashlib.sha256(text.encode()).hexdigest(), 'bytes': len(text.encode())}
                for name, text in files.items()}
    files['apt-stepx-1406-source-manifest.json'] = json.dumps(manifest, ensure_ascii=False, indent=2) + '\n'
    args.output.write_text(json.dumps({'format': 'apt-exact-source-v1', 'files': files}, ensure_ascii=False) + '\n')
    if args.mirror:
        for name, text in files.items():
            target = args.mirror / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
    print(f'{len(manifest)} verified targets; payload SHA256 {hashlib.sha256(args.output.read_bytes()).hexdigest()}')


if __name__ == '__main__':
    main()

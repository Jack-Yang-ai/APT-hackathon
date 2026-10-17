#!/usr/bin/env python3
"""Feishu meetings for Echo, read with the user's own lark-cli login (read-only commands only).

Each day with meetings becomes <root>/YYYY-MM-DD.json (echo.meetings/1): the calendar events that were held as
video meetings, and for those with a meeting note its 总结 and 待办 sections. Transcripts, 金句 and links are not
kept. A note already kept for a meeting that ended more than six hours ago is not fetched again.
"""
import datetime as dt
import json
import os
import shutil
import subprocess

TZ = dt.timezone(dt.timedelta(hours=8))
SECTIONS = ('总结', '待办')
SETTLED = dt.timedelta(hours=6)  # Feishu may still be writing the note shortly after a meeting


def lark(*args):
    exe = shutil.which('lark-cli') or os.path.expanduser('~/.local/bin/lark-cli')
    if not os.path.exists(exe):
        raise ValueError('没有找到 lark-cli：先安装并登录飞书 CLI。')
    # The input method runs with a short PATH; lark-cli is a Node script, and node usually sits beside it.
    env = dict(os.environ, PATH=os.pathsep.join([os.path.dirname(os.path.realpath(exe)), os.path.dirname(exe),
                                                 os.path.expanduser('~/.local/bin'), '/opt/homebrew/bin', '/usr/local/bin', os.environ.get('PATH', '/usr/bin:/bin')]))
    p = subprocess.run([exe, *args, '--format', 'json'], capture_output=True, text=True, timeout=60, env=env)
    try:
        data = json.loads(p.stdout)
    except json.JSONDecodeError:
        raise ValueError('lark-cli 没有返回可读的结果，请运行 lark-cli doctor 检查登录。')
    return data


def sections(markdown):
    """The 总结 and 待办 sections of a meeting note, by their top-level headings."""
    kept, current = {}, None
    for line in markdown.splitlines():
        stripped = line.strip()
        if stripped.startswith('# ') and not stripped.startswith('## '):
            title = stripped[2:].strip()
            current = title if title in SECTIONS else None
            continue
        if current:
            kept.setdefault(current, []).append(line)
    return {name: '\n'.join(lines).strip() for name, lines in kept.items() if '\n'.join(lines).strip()}


def note_text(note_id):
    detail = lark('note', '+detail', '--note-id', note_id)
    token = ((detail.get('data') or {}).get('note') or {}).get('note_doc_token')
    if not token:
        return None
    doc = lark('docs', '+fetch', '--doc', token, '--doc-format', 'markdown')
    content = (((doc.get('data') or {}).get('document') or {}).get('content')) or ''
    return sections(content) or None


def when(value):
    return dt.datetime.fromisoformat(value.replace(' ', 'T')).replace(tzinfo=TZ) if value and 'T' not in value else dt.datetime.fromisoformat(value)


def sync(req):
    root = req['root']
    start, end = dt.date.fromisoformat(req['from']), dt.date.fromisoformat(req['to'])
    now = dt.datetime.now(TZ)
    agenda = lark('calendar', '+agenda', '--start', f'{start}T00:00:00+08:00', '--end', f'{end}T23:59:59+08:00')
    if not agenda.get('ok'):
        raise ValueError(((agenda.get('error') or {}).get('message')) or '读取飞书日程失败，请运行 lark-cli doctor 检查登录。')
    events = [e for e in (agenda.get('data') or []) if isinstance(e, dict) and e.get('vchat') and e.get('event_id')]
    meeting_of = {}
    if events:
        found = lark('calendar', '+meeting', '--event-ids', ','.join(e['event_id'] for e in events))
        meeting_of = {m['event_id']: m['meeting_id'] for m in ((found.get('data') or {}).get('meetings') or []) if m.get('meeting_id')}
    held = {}
    if meeting_of:
        found = lark('vc', '+detail', '--meeting-ids', ','.join(meeting_of.values()))
        held = {m['meeting_id']: m for m in ((found.get('data') or {}).get('meetings') or []) if m.get('meeting_id')}
    os.makedirs(root, mode=0o700, exist_ok=True)
    days = {}
    for event in events:
        meeting = held.get(meeting_of.get(event['event_id'], ''))
        if not meeting:
            continue  # scheduled with a video link but never held
        begin = when(meeting.get('start_time') or event['start_time']['datetime'])
        days.setdefault(begin.date().isoformat(), []).append((event, meeting, begin))
    written = 0
    for day, items in days.items():
        path = os.path.join(root, f'{day}.json')
        try:
            with open(path, encoding='utf-8') as f:
                kept = {m['meeting_id']: m for m in json.load(f).get('meetings', [])}
        except (OSError, ValueError):
            kept = {}
        meetings = []
        for event, meeting, begin in sorted(items, key=lambda item: item[2]):
            ended = when(meeting['end_time']) if meeting.get('end_time') else begin
            old = kept.get(meeting['meeting_id'])
            if old and old.get('note') and now-ended > SETTLED:
                note = old['note']
            else:
                note = note_text(meeting['note_id']) if meeting.get('note_id') else None
            meetings.append({'meeting_id': meeting['meeting_id'], 'event_id': event['event_id'],
                             'title': meeting.get('topic') or event.get('summary') or '飞书会议',
                             'start': begin.isoformat(), 'end': ended.isoformat(), 'note': note})
        tmp = path + '.tmp'
        with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w', encoding='utf-8') as f:
            json.dump({'schema': 'echo.meetings/1', 'date': day, 'synced_at': now.isoformat(), 'meetings': meetings}, f, ensure_ascii=False)
        os.replace(tmp, path)
        written += 1
    return {'events': [], 'cache': f'{written} days'}

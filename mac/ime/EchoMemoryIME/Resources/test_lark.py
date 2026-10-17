import datetime as dt
import json
import os
import stat
import tempfile
import unittest
from unittest.mock import patch

import lark

NOTE = "# 总结\n## 结论\n先做移动端。\n# 待办\n- 小周出排期\n# 会议中的金句时刻\n金句不留\n# 相关链接\nhttps://x"


def fake(calls, notes_fetched):
    """lark-cli as seen from lark.sync: two held meetings, one only scheduled, one without a video link."""
    def run(*args):
        calls.append(args[:2])
        if args[:2] == ('calendar', '+agenda'):
            return {'ok': True, 'data': [
                {'event_id': 'e1', 'summary': '评审', 'vchat': {'vc_type': 'vc'}, 'start_time': {'datetime': '2026-10-09T16:00:00+08:00'}},
                {'event_id': 'e2', 'summary': '只约了没开', 'vchat': {'vc_type': 'vc'}, 'start_time': {'datetime': '2026-10-09T18:00:00+08:00'}},
                {'event_id': 'e3', 'summary': '线下会', 'start_time': {'datetime': '2026-10-09T10:00:00+08:00'}},
                {'event_id': 'e4', 'summary': '今天', 'vchat': {'vc_type': 'vc'}, 'start_time': {'datetime': '2026-10-12T09:59:00+08:00'}}]}
        if args[:2] == ('calendar', '+meeting'):
            return {'ok': True, 'data': {'meetings': [{'event_id': 'e1', 'meeting_id': 'm1'}, {'event_id': 'e2', 'hint': 'not found'}, {'event_id': 'e4', 'meeting_id': 'm4'}]}}
        if args[:2] == ('vc', '+detail'):
            return {'ok': True, 'data': {'meetings': [
                {'meeting_id': 'm1', 'topic': 'prd 设计对齐', 'start_time': '2026-10-09 16:03', 'end_time': '2026-10-09 17:26', 'note_id': 'n1'},
                {'meeting_id': 'm4', 'topic': '日会', 'start_time': '2026-10-12 09:59', 'end_time': '2026-10-12 10:11', 'note_id': 'n4'}]}}
        if args[:2] == ('note', '+detail'):
            notes_fetched.append(args[3])
            return {'ok': True, 'data': {'note': {'note_doc_token': 'doc-' + args[3]}}}
        if args[:2] == ('docs', '+fetch'):
            return {'ok': True, 'data': {'document': {'content': NOTE}}}
        raise AssertionError(args)
    return run


class LarkTests(unittest.TestCase):
    def test_sections_keep_summary_and_todos_only(self):
        self.assertEqual(lark.sections(NOTE), {'总结': '## 结论\n先做移动端。', '待办': '- 小周出排期'})
        self.assertEqual(lark.sections('# 金句\n只有金句'), {})

    def test_sync_writes_held_meetings_with_notes(self):
        with tempfile.TemporaryDirectory() as root:
            calls, fetched = [], []
            with patch('lark.lark', side_effect=fake(calls, fetched)):
                lark.sync({'from': '2026-10-06', 'to': '2026-10-12', 'root': root})
            day = json.load(open(os.path.join(root, '2026-10-09.json'), encoding='utf-8'))
            self.assertEqual(day['schema'], 'echo.meetings/1')
            self.assertEqual([m['title'] for m in day['meetings']], ['prd 设计对齐'])  # not held, no video link: left out
            self.assertEqual(day['meetings'][0]['note'], {'总结': '## 结论\n先做移动端。', '待办': '- 小周出排期'})
            self.assertTrue(day['meetings'][0]['start'].startswith('2026-10-09T16:03') and day['meetings'][0]['start'].endswith('+08:00'))
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(root, '2026-10-09.json')).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(root).st_mode) & 0o077, 0)
            self.assertNotIn('金句', json.dumps(day, ensure_ascii=False))

    def test_settled_notes_are_not_fetched_again(self):
        with tempfile.TemporaryDirectory() as root:
            later = dt.datetime(2026, 10, 12, 12, 0, tzinfo=lark.TZ)  # m1 ended days ago; m4 ended under six hours ago
            with patch('lark.lark', side_effect=fake([], [])):
                lark.sync({'from': '2026-10-06', 'to': '2026-10-12', 'root': root})
            fetched = []
            with patch('lark.lark', side_effect=fake([], fetched)), patch('lark.dt.datetime', wraps=dt.datetime) as clock:
                clock.now.return_value = later
                lark.sync({'from': '2026-10-06', 'to': '2026-10-12', 'root': root})
            self.assertEqual(fetched, ['n4'])

    def test_missing_cli_or_bad_login_is_explained(self):
        with patch('lark.shutil.which', return_value=None), patch('lark.os.path.exists', return_value=False):
            with self.assertRaisesRegex(ValueError, 'lark-cli'):
                lark.lark('calendar', '+agenda')
        with patch('lark.lark', return_value={'ok': False, 'error': {'message': 'token expired'}}):
            with self.assertRaisesRegex(ValueError, 'token expired'):
                lark.sync({'from': '2026-10-06', 'to': '2026-10-12', 'root': tempfile.gettempdir()})


if __name__ == '__main__':
    unittest.main()

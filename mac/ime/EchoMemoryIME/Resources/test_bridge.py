import datetime as dt
import unittest
from unittest.mock import patch
from bridge import run, retrieve, details, event_body, muse

class MemoryTests(unittest.TestCase):
    def test_insight_cards_are_not_factual_evidence(self):
        self.assertEqual(event_body({'detail':'会议尚未决定上线日期。','deliverables':[{'content':'AI 建议明天上线。'}]}), '会议尚未决定上线日期。')
        self.assertEqual(event_body({'summary':'日期未定。','deliverables':[{'content':'明天上线。'}]}), '日期未定。')

    def test_single_day_range_shape(self):
        response = {'date':'2026-10-08','events':[{'event_id':'actual-1','title':'会议','summary':'未决事项'}]}
        with patch('bridge.fetch',return_value=response):
            result = retrieve({'from':'2026-10-08','to':'2026-10-08','keywords':[]})
        self.assertEqual(result['events'][0]['date'],'2026-10-08')

    def test_multiple_day_range_shape(self):
        response = {'digests':[{'date':'2026-10-07','events':[{'event_id':'a','title':'A'}]}, {'date':'2026-10-08','events':[{'event_id':'b','title':'B'}]}]}
        with patch('bridge.fetch',return_value=response):
            result = retrieve({'from':'2026-10-07','to':'2026-10-08','keywords':[]})
        self.assertEqual([e['event_id'] for e in result['events']],['b','a'])

    def test_cache_source_is_reported(self):
        response = {'date':'2026-10-08','events':[{'event_id':'a','title':'A'}],'_cache':{'source':'server'}}
        with patch('bridge.fetch',return_value=response):
            self.assertEqual(retrieve({'from':'2026-10-08','to':'2026-10-08','keywords':[]})['cache'],'server')
        detail = {'event_id':'a','title':'A','detail':'正文','_cache':{'source':'local'}}
        with patch('bridge.fetch',return_value=detail):
            self.assertEqual(details({'ids':['a'],'date':'2026-10-08'})['cache'],'local')

    def test_full_pool_reads_all_segments_and_preserves_time(self):
        events = [{'event_id':str(i),'title':'旁听私教练臀' if i == 0 else '健身房私教训练',
                   'date':'2026-10-12','detail':'完整训练正文 '+str(i),
                   'start_time':'2026-10-12T03:56:00Z','end_time':'2026-10-12T04:46:00Z'} for i in range(14)]
        with patch('bridge.fetch',return_value={'events':events}):
            ids = [e['event_id'] for e in events]
            result = details({'ids':ids,'date':'2026-10-12','full_pool':True})
            self.assertEqual([s['event_id'] for s in result['sources']],ids)
            self.assertIn('完整训练正文 13',result['sources'][-1]['body'])
            self.assertIn('03:56:00Z',result['sources'][0]['body'])
            with self.assertRaises(ValueError):
                details({'ids':ids,'date':'2026-10-12'})
            with self.assertRaises(ValueError):
                details({'ids':[str(i) for i in range(121)],'full_pool':True})

    def test_missing_bodies_and_unrequested_ids_are_not_evidence(self):
        response = {'events':[{'event_id':'a','summary':'仅有摘要'}, {'event_id':'b','detail':''},
                              {'event_id':'c','detail':'失败','error':'not_found'}, {'event_id':'foreign','detail':'不在请求里'}]}
        with patch('bridge.fetch',return_value=response):
            sources = details({'ids':['a','b','c'],'full_pool':True})['sources']
        self.assertEqual([s['event_id'] for s in sources],['a'])
        self.assertIn('完整正文不可用',sources[0]['body'])

    def test_directory_keeps_coordinates_and_reports_overflow(self):
        events = [{'event_id':str(i),'title':'记录','summary':'摘要','start_time':'2026-10-12T03:56:00Z',
                   'end_time':'2026-10-12T04:46:00Z'} for i in range(121)]
        with patch('bridge.fetch',return_value={'date':'2026-10-12','events':events}):
            result = retrieve({'from':'2026-10-12','to':'2026-10-12','keywords':[]})
        self.assertEqual(len(result['events']),120)
        self.assertEqual(result['omitted'],1)
        self.assertEqual(result['events'][0]['end_time'],'2026-10-12T04:46:00Z')

    def test_muse_returns_notes_as_sources(self):
        response = {'muses':[{'muse_id':'m1','event_id':'e1','content':'他说\'先对齐\'','created_at':'2026-10-10T07:33:15Z'},{'muse_id':'m2','content':''}],'_cache':{'source':'local'}}
        with patch('bridge.fetch',return_value=response) as fetched:
            result = muse({'limit':500})
        self.assertEqual(fetched.call_args[0],('muse','--limit','100'))
        self.assertEqual(result['sources'],[{'event_id':'m1','date':'2026-10-10','title':'碎碎念','body':"他说'先对齐'"}])
        self.assertEqual(result['cache'],'local')
        with patch('bridge.fetch',return_value=response):
            self.assertEqual(muse({'since':'2026-10-11'})['sources'],[])

    def test_only_echo_actions(self):
        self.assertEqual(len(run({'action':'retrieve','from':'2026-10-08','to':'2026-10-08','keywords':[],'demo':True})['events']),2)
        with self.assertRaises(ValueError):
            run({'query':'会议','date':'2026-10-08','demo':True})

if __name__ == '__main__':
    unittest.main()

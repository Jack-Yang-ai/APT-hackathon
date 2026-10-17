"""Local embedding checks: fictional or previously saved corpus; no cloud/keychain."""
import argparse
import json
import pathlib
import tempfile

import memory_index as ix


CORPUS = [
    {'event_id': 'fitness', 'body': '周六私教讲了髋铰链、罗马尼亚硬拉和骨盆稳定，最后调了器械配重。'},
    {'event_id': 'product', 'body': '产品评审决定先做移动端，桌面端放到后续版本；小周周三前出排期。'},
    {'event_id': 'camera', 'body': '镜头换过后异常仍存在，防抖模块是否有问题还没有确认。'},
    {'event_id': 'food', 'body': '下午在川味火锅店聚餐，点了毛肚和菌汤。'},
    {'event_id': 'price', 'body': '客户同意将每月订阅费降到69元，下个月生效。'},
    {'event_id': 'trip', 'body': '九月底去了草原，在帐篷营地过夜，第二天拍摄野生动物。'},
    {'event_id': 'music', 'body': '演奏练习使用节拍器，从慢速开始逐步提高速度，左手换把时注意放松。'},
    {'event_id': 'home', 'body': '房间漏水先关总阀，师傅周五来换水管，墙面干燥后再修补。'},
]
GOLD = [
    ('上次健身主要练了什么', 'fitness'),
    ('打算先开发哪种设备上的应用', 'product'),
    ('摄影器材修好了吗', 'camera'),
    ('那顿涮锅吃了啥', 'food'),
    ('客户要付多少人民币', 'price'),
    ('What movements did the personal trainer teach?', 'fitness'),
    ('家里的管道出了问题怎么处理', 'home'),
    ('旅行晚上住在哪里', 'trip'),
]


def saved_fixture(folder):
    # Replays already saved WithEcho responses; never opens ~/.withecho/ or exports ASR.
    import bridge
    folder = pathlib.Path(folder)
    digest = json.loads((folder / 'digest.json').read_text())
    details = json.loads((folder / 'details.json').read_text())
    days = [d for d in digest['digests'] if '2026-10-10' <= d['date'] <= '2026-10-12']
    items = details.get('events', []) if isinstance(details, dict) else details
    indexed = {e['event_id']: e for e in items if e.get('event_id')}
    def replay(*args):
        if args[0] == 'digest':
            return {'digests': days}
        ids = [v for v in args[2:] if not v.startswith('--')]
        rows = [indexed.get(i, {'event_id': i, 'error': 'not_found'}) for i in ids]
        return rows[0] if len(ids) == 1 else {'events': rows}
    bridge.fetch = replay
    metadata = bridge.retrieve({'from': '2026-10-10', 'to': '2026-10-12', 'keywords': []})
    ids = [e['event_id'] for e in metadata['events']]
    sources = bridge.details({'ids': ids, 'date': '2026-10-12', 'full_pool': True})['sources']
    assert len(sources) == len(ids), 'saved corpus is incomplete'
    gold = {s['event_id'] for s in sources if s['title'] in ('旁听私教练臀', '健身房私教训练')}
    assert len(gold) == 2, 'known main and tail segments must exist before testing recall'
    with tempfile.TemporaryDirectory(prefix='EchoVectorRealFixture-') as tmp:
        root = pathlib.Path(tmp) / 'Index'
        query = '2026-10-10 至 2026-10-12 私教课讲了哪些动作'
        first = ix.hybrid(query, sources, root=root)
        second = ix.hybrid(query, sources, root=root)
        output = {'fixture': 'previously_saved_2026-10-10_to_12', 'sources': len(sources),
                  'training_gold': len(gold), 'training_recalled': len(gold.intersection(first['ids'])),
                  'first_index': first['index'], 'warm_index': second['index'], 'external_calls': 0}
        print(json.dumps(output, ensure_ascii=False))
        assert first['index']['state'] == 'hybrid' and gold.issubset(first['ids'])
        assert second['index']['new_chunks'] == 0 and second['index']['query_cached']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--saved-fixture')
    args = parser.parse_args()
    if args.saved_fixture:
        saved_fixture(args.saved_fixture)
        return
    sources = [dict(s, title='片段 ' + str(i), date='2026-10-10') for i, s in enumerate(CORPUS)]
    with tempfile.TemporaryDirectory(prefix='EchoVectorLive-') as tmp:
        rows = []
        for question, expected in GOLD:
            result = ix.hybrid(question, sources, root=pathlib.Path(tmp) / 'Index', top_k=3)
            if result['index']['state'] != 'hybrid':
                raise RuntimeError(result['index'].get('error') or result['index']['state'])
            rows.append({'gold': expected, 'ids': result['ids'], 'passed': expected in result['ids'], 'index': result['index']})
        repeated = ix.hybrid(GOLD[-1][0], sources, root=pathlib.Path(tmp) / 'Index', top_k=3)
        assert repeated['index']['new_chunks'] == 0 and repeated['index']['query_cached']
        output = {'model': ix.DEFAULT_MODEL, 'dim': rows[0]['index']['dim'],
                  'hit_at_3': sum(r['passed'] for r in rows), 'questions': len(rows),
                  'first_index': rows[0]['index'], 'warm_index': repeated['index'],
                  'warm_new_query': rows[1]['index'],
                  'failed': [{'gold': r['gold'], 'ids': r['ids']} for r in rows if not r['passed']]}
        print(json.dumps(output, ensure_ascii=False))
        assert all(r['passed'] for r in rows), 'semantic recall smoke failed'


if __name__ == '__main__':
    main()

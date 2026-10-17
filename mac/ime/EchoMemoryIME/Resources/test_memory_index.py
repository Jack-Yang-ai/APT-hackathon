import contextlib
import json
import math
import pathlib
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch

import memory_index as ix
import bridge


def source(sid, body, title='记录'):
    return {'event_id': sid, 'date': '2026-10-10', 'title': title, 'body': body}


class FakeEmbedding:
    def __init__(self):
        self.digest = 'test-model-v1'
        self.calls = []
        self.after = None
        self.bad = None
        self.dim = 3

    def identity(self):
        return self.digest

    def embed(self, texts):
        self.calls.append(list(texts))
        vectors = []
        for text in texts:
            if '健身' in text or '髋铰链' in text or '私教' in text:
                v = [1., 0., 0.]
            elif '火锅' in text:
                v = [0., 1., 0.]
            else:
                v = [.1, .2, 1.]
            vectors.append(self.bad if self.bad is not None else v[:self.dim])
        if self.after:
            action, self.after = self.after, None
            action()
        return vectors


class IndexTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name) / 'Index'
        self.client = FakeEmbedding()
        self.sources = [source('training', '髋铰链、罗马尼亚硬拉。'), source('meal', '火锅聚餐。'),
                        source('work', '上线时间还没决定。')]

    def search(self, sources=None, query='健身动作', model=ix.DEFAULT_MODEL, top_k=1, max_new=ix.maxNewPerQuery):
        return ix.hybrid(query, self.sources if sources is None else sources, model=model,
                         root=self.root, client=self.client, top_k=top_k, max_new=max_new)

    def test_different_words_recall_and_coordinates(self):
        result = self.search()
        self.assertEqual(result['ids'], ['training'])
        self.assertEqual(result['index']['keyword_hits'], 0)
        self.assertEqual(result['index']['state'], 'hybrid')
        self.assertEqual(result['hits'][0]['lane'], 'vector')
        self.assertEqual(result['hits'][0]['start'], 0)
        self.assertEqual(result['hits'][0]['end'], len(self.sources[0]['body']))

    def test_incremental_and_query_cache(self):
        first = self.search()
        self.assertEqual(first['index']['new_chunks'], 3)
        self.assertEqual(len(self.client.calls), 2)  # one document batch, one query
        self.assertTrue(self.client.calls[-1][0].startswith(ix.QUERY))
        self.assertFalse(any(t.startswith(ix.QUERY) for t in self.client.calls[0]))
        second = self.search()
        self.assertEqual(len(self.client.calls), 2)
        self.assertEqual(second['index']['new_chunks'], 0)
        self.assertEqual(second['index']['cached_chunks'], 3)
        self.assertTrue(second['index']['query_cached'])
        changed = [dict(s) for s in self.sources]
        changed[0]['body'] += ' 保留否定：不要弓背。'
        third = self.search(changed)
        self.assertEqual(third['index']['new_chunks'], 1)
        self.assertEqual(len(self.client.calls[-1]), 1)
        self.assertEqual(len(self.client.calls), 3)

    def test_model_digest_and_dimension_do_not_mix(self):
        self.search()
        self.client.digest = 'test-model-v2'
        self.client.dim = 2
        changed = self.search()
        self.assertEqual(changed['index']['dim'], 2)
        self.assertEqual(changed['index']['new_chunks'], 3)
        again = self.search(model=ix.MODELS[1])
        self.assertEqual(again['index']['new_chunks'], 3)
        with sqlite3.connect(str(self.root / 'vectors.sqlite3')) as con:
            self.assertEqual(con.execute('SELECT COUNT(*) FROM spaces').fetchone()[0], 3)

    def test_bad_vectors_are_rejected_not_cached(self):
        for bad in ([math.nan, 0., 0.], [math.inf, 0., 0.], [0., 0., 0.], [True, 0., 0.]):
            with self.subTest(bad=bad):
                self.client.bad = bad
                result = self.search(query='硬拉')
                self.assertEqual(result['index']['state'], 'lexical_fallback')
                self.assertEqual(result['index']['error'], 'invalid_vector')
                self.assertEqual(result['ids'], ['training'])
                with sqlite3.connect(str(self.root / 'vectors.sqlite3')) as con:
                    self.assertEqual(con.execute('SELECT COUNT(*) FROM vectors').fetchone()[0], 0)

    def test_dimension_drift_fails_and_bad_cache_is_repaired(self):
        self.search()
        with sqlite3.connect(str(self.root / 'vectors.sqlite3')) as con:
            con.execute("UPDATE vectors SET value=? WHERE hash LIKE 'd:%' AND rowid=(SELECT MIN(rowid) FROM vectors)", (b'bad',))
        fixed = self.search()
        self.assertEqual(fixed['index']['new_chunks'], 1)
        self.assertEqual(fixed['index']['state'], 'hybrid')
        self.client.dim = 2  # same model/digest, different dimension is a protocol failure
        changed = [dict(s) for s in self.sources]
        changed[0]['body'] += ' 新内容。'
        bad = self.search(changed)
        self.assertEqual(bad['index']['state'], 'lexical_fallback')
        self.assertEqual(bad['index']['error'], 'dimension_mismatch')

    def test_digest_change_during_embedding_cannot_poison_cache(self):
        self.client.after = lambda: setattr(self.client, 'digest', 'changed-during-call')
        result = self.search()
        self.assertEqual(result['index']['error'], 'space_changed')
        with sqlite3.connect(str(self.root / 'vectors.sqlite3')) as con:
            self.assertEqual(con.execute('SELECT COUNT(*) FROM vectors').fetchone()[0], 0)

    def test_clear_during_embedding_does_not_resurrect_vectors(self):
        self.client.after = lambda: ix.clear(self.root)
        result = self.search()
        self.assertEqual(result['index']['error'], 'index_cleared')
        with sqlite3.connect(str(self.root / 'vectors.sqlite3')) as con:
            self.assertEqual(con.execute('SELECT COUNT(*) FROM vectors').fetchone()[0], 0)
        self.assertEqual(self.search()['index']['state'], 'hybrid')
        ix.clear(self.root)
        self.assertEqual(ix.status(root=self.root, client=self.client)['index']['chunks'], 0)

    def test_deleted_sources_are_not_returned_and_database_has_no_text(self):
        self.search()
        result = self.search([self.sources[1]], top_k=12)
        self.assertEqual(result['ids'], ['meal'])
        data = (self.root / 'vectors.sqlite3').read_bytes()
        self.assertNotIn('髋铰链'.encode(), data)
        self.assertNotIn('健身动作'.encode(), data)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.root / 'vectors.sqlite3').stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / 'update.lock').stat().st_mode & 0o777, 0o600)

    def test_keyword_and_vector_lanes_both_survive_rrf(self):
        rows = [source('name', '王总确认了付款时间。'), source('training', '髋铰链动作。')]
        result = self.search(rows, query='王总健身', top_k=2)
        self.assertEqual(set(result['ids']), {'name', 'training'})
        self.assertEqual({h['lane'] for h in result['hits']}, {'keyword', 'vector'})

    def test_chunk_coverage_and_tail_coordinates(self):
        body = '开头说话人甲：' + '背景内容。' * 280 + '\n文末证据：髋铰链动作。'
        parts = ix.chunks([source('large', body)])
        self.assertTrue(any('文末证据' in p['text'] for p in parts))
        covered = set()
        for p in parts:
            covered.update(range(p['start'], p['end']))
        self.assertEqual(covered, set(range(len(body))))
        self.assertTrue(all(a['end'] > b['start'] for a, b in zip(parts, parts[1:])))

    def test_no_remote_or_credential_endpoint(self):
        for endpoint in ('https://example.com', 'http://user:password@localhost:11434',
                         'http://localhost:11434/?key=x', 'http://127.0.0.1:11434/a'):
            with self.assertRaises(ix.IndexFailure):
                ix.Ollama(endpoint=endpoint)

    def test_busy_writer_falls_back_without_waiting(self):
        with ix.database(self.root, exclusive=True):
            result = self.search(query='硬拉')
            self.assertEqual(result['index']['error'], 'index_busy')
            self.assertEqual(result['ids'], ['training'])

    def test_cold_index_has_a_time_budget(self):
        result = ix.hybrid('硬拉', self.sources, root=self.root, client=self.client, budget_seconds=.00001)
        self.assertEqual(result['index']['error'], 'index_warming')
        self.assertEqual(result['index']['state'], 'lexical_fallback')
        self.assertEqual(self.client.calls, [])

    def test_recency_breaks_ties_only_when_requested(self):
        rows = [source('old', '髋铰链动作。'), source('new', '髋铰链动作。')]
        rows[0]['date'] = '2026-10-01'
        rows[1]['date'] = '2026-10-12'
        recent = self.search(rows, query='上次健身', top_k=1)
        neutral = self.search(rows, query='健身', top_k=1)
        self.assertEqual(recent['ids'], ['new'])
        self.assertEqual(neutral['ids'], ['old'])

    def test_query_scaffolding_is_not_topic_evidence(self):
        self.assertEqual(ix.query_tokens('帮我查一下上次10月13日的记录'), ix.query_tokens('的'))
        self.assertIn('评审', ix.query_tokens('最近一次预算评审'))
        self.assertIn('录音', ix.query_tokens('昨天的录音'))

    def test_validation_no_foreign_ids_duplicates_or_empty_body(self):
        for rows in ([self.sources[0], self.sources[0]], [source('a', '')], [source('', '文字')],
                     [source('a', '文字')] * 121):
            with self.assertRaises(ix.IndexFailure):
                self.search(rows)
        with self.assertRaises(ix.IndexFailure):
            self.search(top_k=100)

    def test_large_pool_keywords_work_without_embeddings(self):
        rows = [source(str(i), '无关片段') for i in range(192)] + [source('tail', '共用 Agent 保留引用依据')]
        result = ix.hybrid('共用 Agent 引用依据', rows, root=self.root, client=self.client, use_vectors=False)
        self.assertEqual(result['ids'], ['tail'])
        self.assertEqual(result['index']['state'], 'lexical_fallback')
        self.assertEqual(result['index']['chunks'], 193)
        self.assertEqual(self.client.calls, [])
        with self.assertRaises(ix.IndexFailure):
            ix.chunks([source(str(i), '资料') for i in range(2001)])
        with self.assertRaises(ix.IndexFailure):
            ix.chunks([source('large', '字' * (1000 * 4097))])

    def test_warm_embeds_documents_once_and_stores_no_query_vector(self):
        first = ix.warm(self.sources, root=self.root, client=self.client)
        self.assertEqual((first['state'], first['new_chunks'], first['pending']), ('warm', 3, 0))
        second = ix.warm(self.sources, root=self.root, client=self.client)
        self.assertEqual((second['state'], second['new_chunks'], second['cached_chunks']), ('warm', 0, 3))
        self.assertFalse(any(texts[0].startswith(ix.QUERY) for texts in self.client.calls))
        with sqlite3.connect(str(self.root / 'vectors.sqlite3')) as con:
            self.assertEqual(con.execute("SELECT COUNT(*) FROM vectors WHERE hash LIKE 'q:%'").fetchone()[0], 0)

    def test_warmed_pool_costs_a_lookup_nothing_to_embed(self):
        ix.warm(self.sources, root=self.root, client=self.client)
        result = self.search()
        self.assertEqual(result['index']['state'], 'hybrid')
        self.assertEqual((result['index']['new_chunks'], result['index']['cached_chunks']), (0, 3))
        self.assertEqual(result['index']['pending'], 0)
        self.assertEqual(result['ids'], ['training'])

    def test_partial_pool_keeps_the_semantic_lane(self):
        result = self.search(max_new=1)
        self.assertEqual(result['index']['state'], 'hybrid')
        self.assertEqual((result['index']['new_chunks'], result['index']['pending']), (1, 2))
        self.assertGreater(result['index']['vector_hits'], 0)
        self.assertIn('training', result['ids'])

    def test_a_warm_pool_keeps_its_lane_when_the_document_budget_ran_out(self):
        self.search()  # the pool and the 健身动作 query vector are warm now
        self.client.calls = []
        result = ix.hybrid('硬拉', self.sources, root=self.root, client=self.client, budget_seconds=.00001)
        self.assertEqual(result['index']['state'], 'hybrid')
        self.assertFalse(result['index']['query_cached'])
        self.assertEqual(len(self.client.calls), 1)  # one grace query embed, no document work
        self.assertTrue(self.client.calls[0][0].startswith(ix.QUERY))
        self.assertGreater(result['index']['vector_hits'], 0)

    def test_a_bad_new_chunk_limit_is_rejected_like_any_other_limit(self):
        for value in ['3', 1.5, True, -1, 5000]:
            with self.assertRaises(ix.IndexFailure):
                ix.hybrid('硬拉', self.sources, root=self.root, client=self.client, max_new=value)

    def test_nothing_embeddable_falls_back_without_a_query_call(self):
        result = self.search(max_new=0)
        self.assertEqual(result['index']['state'], 'lexical_fallback')
        self.assertEqual(result['index']['error'], 'index_warming')
        self.assertEqual(self.client.calls, [])

    def test_warm_budget_stops_embedding_and_reports_pending(self):
        result = ix.warm(self.sources, root=self.root, client=self.client, budget_seconds=.00001)
        self.assertEqual((result['state'], result['new_chunks'], result['pending']), ('warm', 0, 3))
        with self.assertRaises(ix.IndexFailure):
            ix.warm(self.sources, root=self.root, client=self.client, budget_seconds=0)
        with self.assertRaises(ix.IndexFailure):
            ix.warm(self.sources, root=self.root, client=self.client, model='nope')

    def test_warm_without_an_explicit_client_uses_the_local_embedder(self):
        with patch.object(ix, 'Ollama', return_value=self.client):
            result = ix.warm(self.sources, root=self.root)
        self.assertEqual((result['state'], result['new_chunks'], result['pending']), ('warm', 3, 0))
        self.assertGreaterEqual(result['ms'], 0)

    def test_warm_chunks_each_source_independently_and_skips_oversized_ones(self):
        rows = [source('a', '内容一。' * 300), source('b', '内容二。' * 300)]
        per_source = []
        for row in rows:
            per_source.extend(ix.chunks([row]))
        self.assertEqual([p['hash'] for p in ix.chunks(rows)], [p['hash'] for p in per_source])
        # One source past the query path's 4096-chunk ceiling is skipped, not fatal to the batch.
        giant = source('giant', '字' * 2_000_000)
        result = ix.warm([source('ok', '髋铰链动作。')] + [giant], root=self.root, client=self.client)
        self.assertEqual(result['state'], 'warm')
        self.assertEqual(result['skipped_sources'], 1)
        self.assertEqual(result['new_chunks'], 1)
        with self.assertRaises(ix.IndexFailure):
            ix.warm([source('a', '内容'), source('a', '内容')], root=self.root, client=self.client)
        with self.assertRaises(ix.IndexFailure):
            ix.warm([source(str(i), '资料') for i in range(2001)], root=self.root, client=self.client)

    def test_a_pool_past_the_chunk_ceiling_falls_back_to_keywords_and_says_why(self):
        # A long date range: the whole pool slices past 4096 chunks, and one record alone does too.
        rows = [source('long%d' % i, '字' * 250_000) for i in range(10)]
        rows += [source('giant', '字' * 2_000_000), source('tail', '共用 Agent 保留引用依据')]
        with self.assertRaises(ix.IndexFailure):
            ix.chunks(rows)
        result = ix.hybrid('共用 Agent 引用依据', rows, root=self.root, client=self.client)
        info = result['index']
        self.assertIn(info['state'], ('hybrid', 'lexical_fallback'))  # what SmartMemory.swift accepts
        self.assertEqual((info['state'], info['error'], info['model']), ('lexical_fallback', 'too_many_chunks', ix.DEFAULT_MODEL))
        self.assertEqual(result['ids'], ['tail'])
        self.assertEqual({h['lane'] for h in result['hits']}, {'keyword'})
        self.assertGreater(info['chunks'], 4096)
        self.assertEqual(info['skipped_sources'], 1)
        self.assertEqual(self.client.calls, [])  # the vector lane never runs past the ceiling
        with self.assertRaises(ix.IndexFailure):
            ix.hybrid('资料', rows + [source('tail', '重复')], root=self.root, client=self.client)

    def test_the_keyword_fallback_holds_a_bounded_total_however_many_sources_come_in(self):
        # Every record fits the per-source ceiling, but together they would slice to 2000 x 4000
        # chunks. The fallback stops at FALLBACK_CHUNKS and counts the records it had to leave out.
        old = ix.FALLBACK_CHUNKS
        ix.FALLBACK_CHUNKS = 5000
        try:
            rows = [source('tail', '共用 Agent 保留引用依据')]
            rows += [source('long%d' % i, '字' * 250_000) for i in range(12)]  # ~521 chunks each
            result = ix.hybrid('共用 Agent 引用依据', rows, root=self.root, client=self.client)
        finally:
            ix.FALLBACK_CHUNKS = old
        info = result['index']
        self.assertEqual((info['state'], info['error']), ('lexical_fallback', 'too_many_chunks'))
        self.assertLessEqual(info['chunks'], 5000)
        self.assertGreater(info['chunks'], 4096)
        self.assertEqual(info['skipped_sources'], 3)  # 1 + 9 x 521 fit, the last three do not
        self.assertEqual(result['ids'], ['tail'])
        self.assertEqual(self.client.calls, [])
        parts, skipped = ix.chunks_per_source(rows, 600)
        self.assertEqual((len(parts), skipped), (522, 11))  # once full, later records are skipped
        with self.assertRaises(ix.IndexFailure):  # a skipped record still counts for duplicates
            ix.chunks_per_source(rows + [source('long11', '重复')], 600)

    def test_a_budget_that_runs_out_mid_batch_keeps_what_is_stored(self):
        # The deadline fires inside an embedding call, not only between batches: what is already
        # stored stays usable and the rest is reported as pending instead of failing the pass.
        rows = [source('e%d' % i, '髋铰链动作 %d。' % i) for i in range(20)]
        fired = []
        def hook():
            self.client.after = hook
            fired.append(1)
            if len(fired) == 2:
                raise ix.IndexFailure('index_warming')
        self.client.after = hook
        result = self.search(sources=rows, max_new=48)
        self.assertEqual(result['index']['state'], 'hybrid')
        self.assertEqual(result['index']['new_chunks'], 16)
        self.assertEqual(result['index']['pending'], 4)
        self.assertGreater(result['index']['vector_hits'], 0)
        self.client.after = None
        again = self.search(sources=rows, max_new=48)
        self.assertEqual((again['index']['new_chunks'], again['index']['pending']), (4, 0))

    def test_warming_refreshes_the_rows_it_verified_so_lru_keeps_them(self):
        first = ix.warm(self.sources, root=self.root, client=self.client)
        self.assertEqual((first['state'], first['new_chunks'], first['cached_chunks']), ('warm', 3, 0))
        con = sqlite3.connect(str(self.root / 'vectors.sqlite3'))
        before = con.execute('SELECT used FROM vectors').fetchall()
        self.client.calls = []
        time.sleep(0.01)
        second = ix.warm(self.sources, root=self.root, client=self.client)
        after = con.execute('SELECT used FROM vectors').fetchall()
        con.close()
        self.assertEqual((second['state'], second['new_chunks'], second['cached_chunks']), ('warm', 0, 3))
        self.assertEqual(self.client.calls, [])
        self.assertTrue(all(new[0] > old[0] for new, old in zip(after, before)))

    def test_warm_and_lookup_agree_on_the_same_chunk_hashes(self):
        ix.warm(self.sources, root=self.root, client=self.client)
        result = self.search()
        self.assertEqual(result['index']['cached_chunks'], len(ix.chunks(self.sources)))

    def test_directory_pool_and_complete_limits_are_distinct(self):
        events = [{'event_id': str(i), 'title': '资料', 'summary': '正文'} for i in range(193)]
        request = {'from': '2026-10-10', 'to': '2026-10-10'}
        with patch.object(bridge, 'fetch', return_value={'date': '2026-10-10', 'events': events}):
            complete = bridge.retrieve(request)
            search = bridge.retrieve({**request, 'search_pool': True})
        self.assertEqual((len(complete['events']), complete['omitted']), (120, 73))
        self.assertEqual((len(search['events']), search['omitted']), (193, 0))
        with self.assertRaises(ValueError):
            bridge.details({'ids': [str(i) for i in range(121)], 'full_pool': True})


if __name__ == '__main__':
    unittest.main()

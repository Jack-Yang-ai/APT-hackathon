"""Private, incremental local embeddings + BM25/RRF. Standard library only.

Growth's retrieval lessons: cached document vectors, query-only instructions, model-space
identity, rank fusion, and hits as coordinates. Evidence remains in the caller's current
source set. The database stores hashes/vectors only, not text, queries or source IDs;
deleted records cannot be recalled from it. Never follows redirects or uses an HTTP proxy.
"""
import collections
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
import pathlib
import re
import sqlite3
import struct
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

MODELS = ('qwen3-embedding:0.6b', 'qwen3-embedding:4b', 'qwen3-embedding:8b')
DEFAULT_MODEL = MODELS[0]
ROOT = pathlib.Path(os.environ.get('ECHO_INDEX_ROOT') or (pathlib.Path.home() / 'Library/Application Support/EchoMemoryIME/Index'))
CHUNK = 600
OVERLAP = 120
VERSION = 'chunk-v1/query-v1/unit-v1'
QUERY = 'Instruct: Given a question, retrieve personal activity records, notes and meeting passages that answer it.\nQuery: '
# One lookup embeds at most this many unseen chunks (~130ms each on this machine, measured
# 2026-10-16): the background warmer owns bulk embedding, a lookup only tops up. Running past
# this is what used to make a single lookup wait out the whole 45s budget and then throw the
# semantic lane away anyway.
maxNewPerQuery = 48
# A single query embed (~130 ms measured) still deserves its own small budget when the document
# top-up consumed the whole lookup budget: the pool is already usable at that point, and dropping
# the semantic lane to its own warm-up work is what the retrieval contract forbids.
queryGraceSeconds = 10


class IndexFailure(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise IndexFailure('redirect_refused')


def fingerprint(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def unit(vector):
    if not isinstance(vector, (list, tuple)) or not vector or len(vector) > 8192:
        raise IndexFailure('invalid_vector')
    if any(isinstance(v, bool) or not isinstance(v, (float, int)) or not math.isfinite(v) for v in vector):
        raise IndexFailure('invalid_vector')
    norm = math.sqrt(math.fsum(v * v for v in vector))
    if not math.isfinite(norm) or norm <= 0:
        raise IndexFailure('invalid_vector')
    return [v / norm for v in vector]


class Ollama:
    def __init__(self, model=DEFAULT_MODEL, endpoint='http://127.0.0.1:11434'):
        parts = urllib.parse.urlsplit(endpoint)
        if (parts.scheme != 'http' or parts.hostname not in ('127.0.0.1', 'localhost', '::1')
                or parts.username or parts.password or parts.query or parts.fragment or parts.path not in ('', '/')):
            raise IndexFailure('nonlocal_endpoint')
        if model not in MODELS:
            raise IndexFailure('unsupported_model')
        self.model, self.endpoint = model, endpoint.rstrip('/')
        self.deadline = None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, path, payload=None, timeout=3):
        if self.deadline is not None:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise IndexFailure('index_warming')
            timeout = min(timeout, remaining)
        data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode('utf-8')
        req = urllib.request.Request(self.endpoint + path, data=data, headers={'Content-Type': 'application/json'})
        try:
            with self.opener.open(req, timeout=timeout) as reply:
                return json.load(reply)
        except IndexFailure:
            raise
        except urllib.error.HTTPError as exc:
            raise IndexFailure('http_' + str(exc.code)) from None
        except (OSError, ValueError, urllib.error.URLError):
            if self.deadline is not None and time.monotonic() >= self.deadline:
                raise IndexFailure('index_warming') from None
            raise IndexFailure('service_unavailable') from None

    def identity(self):
        for model in self.request('/api/tags').get('models', []):
            if model.get('name') == self.model or model.get('model') == self.model:
                digest = model.get('digest')
                if isinstance(digest, str) and digest:
                    return digest
        raise IndexFailure('model_missing')

    def embed(self, texts):
        reply = self.request('/api/embed', {'model': self.model, 'input': texts, 'truncate': False,
                                          'keep_alive': '30m', 'options': {'num_ctx': 4096}}, timeout=90)
        vectors = reply.get('embeddings')
        if reply.get('model') != self.model or not isinstance(vectors, list) or len(vectors) != len(texts):
            raise IndexFailure('invalid_response')
        return [unit(v) for v in vectors]


def tokens(text):
    text = unicodedata.normalize('NFKC', text).casefold()
    result = []
    for part in re.findall(r'[a-z0-9]+|[\u3400-\u9fff]+', text):
        if re.fullmatch(r'[a-z0-9]+', part):
            result.append(part)
        else:
            result.extend(part[i:i + 2] for i in range(len(part) - 1))
    return result


def query_tokens(query):
    # Date filtering is done by the caller. Date/request scaffolding is not topic evidence.
    # The long forms come first so a shorter word cannot eat part of them.
    query = re.sub(r'\d{4}-\d{2}-\d{2}|\d{1,2}月\d{1,2}[日号]', ' ', query)
    for word in ('最近一次', '上一次', '上上周', '上个月', '这个月', '大前天', '查一下',
                 '前天', '昨天', '今天', '明天', '上周', '本周', '这周', '本月', '上次', '最近',
                 '帮我', '什么', '哪些', '内容', '情况', '一下', '告诉', '回复', '记忆', '记录'):
        query = query.replace(word, ' ')
    return set(tokens(query))


def semantic_query(query):
    # The caller has already selected the date scope. Absolute dates are not passage content and
    # the same topic can reuse its query vector across scopes. Keep intent words such as 上次.
    topic = re.sub(r'\d{4}-\d{2}-\d{2}|\d{1,2}月\d{1,2}[日号]', ' ', query)
    topic = re.sub(r'^\s*(?:至|到|和)\s*', '', topic).strip()
    return re.sub(r'\s+', ' ', topic) or query


def chunks(sources, limit=4096):
    if not isinstance(sources, list) or len(sources) > 2000:
        raise IndexFailure('invalid_sources')
    result, ids = [], set()
    for source in sources:
        if not isinstance(source, dict) or any(not isinstance(source.get(k), str) for k in ('event_id', 'body', 'title', 'date')):
            raise IndexFailure('invalid_sources')
        sid, body, title = source['event_id'], source['body'], source['title']
        if not sid or sid in ids or not body.strip():
            raise IndexFailure('invalid_sources')
        ids.add(sid)
        start = 0
        while start < len(body):
            end = min(start + CHUNK, len(body))
            if end < len(body):
                boundary = body.rfind('\n', start + CHUNK // 2, end)
                if boundary >= 0:
                    end = boundary + 1
            text = title[:200] + '\n' + body[start:end]
            result.append({'event_id': sid, 'start': start, 'end': end, 'text': text,
                           'hash': fingerprint(text), 'tokens': collections.Counter(tokens(text))})
            if len(result) > limit:
                raise IndexFailure('too_many_chunks')
            if end == len(body):
                break
            start = max(start + 1, end - OVERLAP)
    return result


# Total chunks the keyword fallback may hold for one lookup. A chunk is up to ~65 KB in memory
# in the worst case (600 distinct CJK characters: text + bigram Counter, measured 2026-10-17),
# so this caps the fallback near 600 MB peak and ~1.3 s of slicing (measured with random CJK
# bodies) instead of growing with 2000 x 4096 chunks.
# A typical day slices to ~210 chunks, so a month-long range (~6500) still fits.
FALLBACK_CHUNKS = 8192


def chunks_per_source(sources, budget=None):
    """Chunk one source at a time; a source that does not fit is skipped and counted.

    Slicing a source is independent of its neighbours, so the hashes are identical to slicing
    the whole pool at once, but the pool as a whole may exceed the 4096-chunk ceiling. With a
    budget, sources fill it in the caller's order and the ones that no longer fit are skipped.
    """
    if not isinstance(sources, list) or len(sources) > 2000:
        raise IndexFailure('invalid_sources')
    parts, ids, skipped = [], set(), 0
    for source in sources:
        room = 4096 if budget is None else min(4096, budget - len(parts))
        try:
            produced = chunks([source], room)
        except IndexFailure as exc:
            if str(exc) != 'too_many_chunks':
                raise
            produced = None
        sid = source['event_id']  # chunks() has validated the shape before slicing
        if sid in ids:
            raise IndexFailure('invalid_sources')
        ids.add(sid)
        if produced is None:
            skipped += 1
        else:
            parts.extend(produced)
    return parts, skipped


def lexical_rank(parts, query):
    terms = query_tokens(query)
    if not parts or not terms:
        return []
    n = len(parts)
    average = sum(sum(p['tokens'].values()) for p in parts) / n or 1
    df = {t: sum(t in p['tokens'] for p in parts) for t in terms}
    ranked = []
    for i, part in enumerate(parts):
        length = sum(part['tokens'].values())
        score = 0.0
        for term in terms:
            count = part['tokens'][term]
            if count:
                idf = math.log(1 + (n - df[term] + .5) / (df[term] + .5))
                score += idf * count * 2.2 / (count + 1.2 * (.25 + .75 * length / average))
        if score > 0:
            ranked.append((i, score))
    return sorted(ranked, key=lambda item: (-item[1], item[0]))


@contextlib.contextmanager
def database(root, exclusive=False):
    root = pathlib.Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.is_symlink():
        raise IndexFailure('index_path')
    root.chmod(0o700)
    lock = os.open(str(root / 'update.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    os.fchmod(lock, 0o600)
    connection = None
    try:
        if exclusive:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise IndexFailure('index_busy') from None
        path = root / 'vectors.sqlite3'
        fd = os.open(str(path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.fchmod(fd, 0o600)
        os.close(fd)
        connection = sqlite3.connect(str(path), timeout=2, isolation_level=None)
        connection.execute('PRAGMA secure_delete=ON')
        connection.execute('CREATE TABLE IF NOT EXISTS control(id INTEGER PRIMARY KEY, generation INTEGER NOT NULL)')
        connection.execute('INSERT OR IGNORE INTO control VALUES(1,0)')
        connection.execute('CREATE TABLE IF NOT EXISTS spaces(space TEXT PRIMARY KEY, model TEXT, digest TEXT, dim INTEGER NOT NULL)')
        connection.execute('CREATE TABLE IF NOT EXISTS vectors(space TEXT, hash TEXT, dim INTEGER, value BLOB, used REAL, PRIMARY KEY(space,hash))')
        yield connection
    finally:
        if connection is not None:
            connection.close()
        os.close(lock)


def cached_vector(con, space, key):
    row = con.execute('SELECT dim,value FROM vectors WHERE space=? AND hash=?', (space, key)).fetchone()
    if row is None:
        return None
    try:
        dim, data = row
        expected = con.execute('SELECT dim FROM spaces WHERE space=?', (space,)).fetchone()
        if not isinstance(dim, int) or not 0 < dim <= 8192 or len(data) != dim * 4:
            raise IndexFailure('invalid_vector')
        if not expected or expected[0] != dim:
            raise IndexFailure('dimension_mismatch')
        return unit(list(struct.unpack('<' + 'f' * dim, data)))
    except (IndexFailure, TypeError, struct.error):
        con.execute('DELETE FROM vectors WHERE space=? AND hash=?', (space, key))
        return None


def save_vectors(con, space, model, digest, generation, rows):
    dimensions = {len(v) for _, v in rows}
    if len(dimensions) != 1:
        raise IndexFailure('dimension_mismatch')
    dim = dimensions.pop()
    con.execute('BEGIN IMMEDIATE')
    try:
        if con.execute('SELECT generation FROM control WHERE id=1').fetchone()[0] != generation:
            raise IndexFailure('index_cleared')
        previous = con.execute('SELECT dim FROM spaces WHERE space=?', (space,)).fetchone()
        if previous and previous[0] != dim:
            raise IndexFailure('dimension_mismatch')
        con.execute('INSERT OR IGNORE INTO spaces VALUES(?,?,?,?)', (space, model, digest, dim))
        now = time.time()
        con.executemany('INSERT OR REPLACE INTO vectors VALUES(?,?,?,?,?)',
                        [(space, key, dim, struct.pack('<' + 'f' * dim, *v), now) for key, v in rows])
        con.execute('COMMIT')
    except Exception:
        con.execute('ROLLBACK')
        raise


def _embed_missing(con, space, model, digest, generation, texts, missing, client, deadline, limit):
    """Embed at most `limit` unseen document chunks before `deadline`.

    Returns the (key, vector) pairs actually stored. The query path and the background
    warmer share this loop so the two can never disagree about what a stored vector
    means: same batching, same identity re-check, same generation guard.
    """
    embedded = []
    stop = min(len(missing), limit)
    for offset in range(0, stop, 16):
        if time.monotonic() >= deadline:
            break
        batch = missing[offset:min(offset + 16, stop)]
        try:
            vectors = client.embed([texts[key] for key in batch])
            if len(vectors) != len(batch):
                raise IndexFailure('invalid_response')
            vectors = [unit(v) for v in vectors]
            if client.identity() != digest:
                raise IndexFailure('space_changed')
        except IndexFailure as exc:
            # A budget that runs out mid-batch is a stop, not a failure: what is already stored
            # stays usable, and the next warm cycle or lookup continues from there.
            if str(exc) != 'index_warming':
                raise
            break
        save_vectors(con, space, model, digest, generation, [('d:' + key, v) for key, v in zip(batch, vectors)])
        embedded.extend(zip(batch, vectors))
    return embedded


def vector_rank(parts, query, model, root, client, stats, budget_seconds, max_new=maxNewPerQuery):
    deadline = time.monotonic() + budget_seconds
    client.deadline = deadline
    digest = client.identity()
    space = fingerprint(json.dumps([model, digest, VERSION]))
    with database(root, exclusive=True) as con:
        generation = con.execute('SELECT generation FROM control WHERE id=1').fetchone()[0]
        texts = {p['hash']: p['text'] for p in parts}
        have = {key: cached_vector(con, space, 'd:' + key) for key in texts}
        missing = [key for key in texts if have[key] is None]
        stats.update(digest=digest, cached_chunks=len(texts) - len(missing), new_chunks=0, pending=0)
        started = time.monotonic()
        embedded = _embed_missing(con, space, model, digest, generation, texts,
                                  missing, client, deadline, max_new)
        have.update(dict(embedded))
        stats['new_chunks'] = len(embedded)
        stats['pending'] = len(missing) - len(embedded)
        stats['document_ms'] = round((time.monotonic() - started) * 1000)
        if not any(v is not None for v in have.values()):
            # Nothing usable in this pool: the keyword lane is the honest answer, and no
            # query vector is worth embedding for a lane that cannot run.
            raise IndexFailure('index_warming')
        started = time.monotonic()
        query_text = QUERY + semantic_query(query)
        key = 'q:' + fingerprint(query_text)
        qv = cached_vector(con, space, key)
        stats['query_cached'] = qv is not None
        if qv is None:
            if time.monotonic() >= deadline:
                # The pool above already has usable vectors, so the lane must not be dropped just
                # because the document top-up ate the budget: grant one query embed a short grace.
                deadline = time.monotonic() + queryGraceSeconds
                client.deadline = deadline
            query_vectors = client.embed([query_text])
            if not isinstance(query_vectors, list) or len(query_vectors) != 1:
                raise IndexFailure('invalid_response')
            qv = unit(query_vectors[0])
            if client.identity() != digest:
                raise IndexFailure('space_changed')
            save_vectors(con, space, model, digest, generation, [(key, qv)])
        stats.update(query_ms=round((time.monotonic() - started) * 1000), dim=len(qv))
        if any(len(v) != len(qv) for v in have.values() if v is not None):
            raise IndexFailure('dimension_mismatch')
        now = time.time()
        con.execute('BEGIN IMMEDIATE')
        try:
            if con.execute('SELECT generation FROM control WHERE id=1').fetchone()[0] != generation:
                raise IndexFailure('index_cleared')
            con.executemany('UPDATE vectors SET used=? WHERE space=? AND hash=?',
                            [(now, space, 'd:' + key) for key in texts] + [(now, space, key)])
            con.execute('DELETE FROM vectors WHERE rowid NOT IN (SELECT rowid FROM vectors ORDER BY used DESC LIMIT 20000)')
            con.execute('COMMIT')
        except Exception:
            con.execute('ROLLBACK')
            raise
        # Only parts that have a vector can take part; a partially warmed pool keeps the
        # chunks it has instead of discarding the whole semantic lane.
        ranked = [(i, math.fsum(a * b for a, b in zip(have[part['hash']], qv)))
                  for i, part in enumerate(parts) if have[part['hash']] is not None]
        return sorted(ranked, key=lambda item: (-item[1], item[0]))


def warm(sources, model=DEFAULT_MODEL, root=None, client=None, budget_seconds=60):
    """Pre-embed document chunks so no user lookup ever pays for them.

    Documents only: no query vector, no ranking. Deliberately opens the index without
    the app-level exclusive lock so a lookup never queues behind warming; writes are
    serialised by SQLite itself and stay idempotent (INSERT OR REPLACE on content
    hashes) under the same generation guard as the query path.
    """
    if model not in MODELS:
        raise IndexFailure('invalid_model')
    if not isinstance(budget_seconds, (int, float)) or isinstance(budget_seconds, bool) \
            or not 0 < budget_seconds <= 600:
        raise IndexFailure('invalid_budget')
    started = time.monotonic()
    # A warm pool may be far larger than the query path's 4096-chunk ceiling and must not fail
    # because of it; a source that no query can chunk either is skipped and the rest warmed.
    parts, skipped = chunks_per_source(sources)
    stats = {'state': 'warm', 'model': model, 'chunks': len(parts), 'new_chunks': 0,
             'cached_chunks': 0, 'pending': 0, 'skipped_sources': skipped}
    if not parts:
        stats['state'] = 'idle'
        stats['ms'] = round((time.monotonic() - started) * 1000)
        return stats
    deadline = time.monotonic() + budget_seconds
    client = client or Ollama(model)
    client.deadline = deadline
    digest = client.identity()
    space = fingerprint(json.dumps([model, digest, VERSION]))
    with database(root or ROOT) as con:
        generation = con.execute('SELECT generation FROM control WHERE id=1').fetchone()[0]
        texts = {p['hash']: p['text'] for p in parts}
        have = {key: cached_vector(con, space, 'd:' + key) for key in texts}
        missing = [key for key in texts if have[key] is None]
        stats['cached_chunks'] = len(texts) - len(missing)
        stats['new_chunks'] = len(_embed_missing(con, space, model, digest, generation, texts,
                                                 missing, client, deadline, len(missing)))
        stats['pending'] = len(missing) - stats['new_chunks']
        if stats['cached_chunks']:
            # Warming touches the rows it verified so a query's LRU sweep cannot evict a pool the
            # warmer just walked, which would re-embed the same chunks forever.
            now = time.time()
            con.execute('BEGIN IMMEDIATE')
            try:
                if con.execute('SELECT generation FROM control WHERE id=1').fetchone()[0] != generation:
                    raise IndexFailure('index_cleared')
                con.executemany('UPDATE vectors SET used=? WHERE space=? AND hash=?',
                                [(now, space, 'd:' + key) for key in texts if have[key] is not None])
                con.execute('COMMIT')
            except Exception:
                con.execute('ROLLBACK')
                raise
    stats['ms'] = round((time.monotonic() - started) * 1000)
    return stats


def source_rank(parts, ranked):
    # One long record must not monopolise the lane's candidate slots.
    result, seen = [], set()
    for index, score in ranked:
        sid = parts[index]['event_id']
        if sid not in seen:
            result.append((sid, index, score))
            seen.add(sid)
        if len(result) == 48:
            break
    return result


def source_time(source):
    try:
        day = dt.date.fromisoformat(source['date'])
        # Source dates are Shanghai local days, as in EchoDates.swift. Missing times do not get
        # invented: midnight is only a deterministic ordering key, never evidence of event time.
        zone = dt.timezone(dt.timedelta(hours=8))
        instant = dt.datetime.combine(day, dt.time.min, tzinfo=zone)
        match = re.match(r'记录时间：([^\s]+)', source['body'])
        if match:
            parsed = dt.datetime.fromisoformat(match[1].replace('Z', '+00:00'))
            if parsed.tzinfo is not None:
                instant = parsed
        return instant.timestamp()
    except (ValueError, TypeError):
        return 0


def hybrid(query, sources, model=DEFAULT_MODEL, root=None, client=None, top_k=12, budget_seconds=45, use_vectors=True, max_new=maxNewPerQuery):
    if not isinstance(query, str) or not query.strip() or len(query) > 4000 or model not in MODELS:
        raise IndexFailure('invalid_query_or_model')
    if not isinstance(top_k, int) or isinstance(top_k, bool) or not 1 <= top_k <= 24:
        raise IndexFailure('invalid_limit')
    if not isinstance(use_vectors, bool):
        raise IndexFailure('invalid_vectors_flag')
    if not isinstance(max_new, int) or isinstance(max_new, bool) or not 0 <= max_new <= 4096:
        raise IndexFailure('invalid_limit')
    started = time.monotonic()
    try:
        parts, skipped, overflow = chunks(sources), 0, False
    except IndexFailure as exc:
        if str(exc) != 'too_many_chunks':
            raise
        # Past the 4096-chunk ceiling the vector lane does not run. The keyword lane still covers
        # every source that fits FALLBACK_CHUNKS, and the result says it is keyword-only and why.
        (parts, skipped), overflow = chunks_per_source(sources, FALLBACK_CHUNKS), True
    recent = any(w in query.casefold() for w in ('上次', '上一次', '最近一次', '最新', 'last time', 'most recent', 'latest'))
    dates = {s['event_id']: source_time(s) for s in sources} if recent else {}
    def ordered(ranked):
        return sorted(ranked, key=lambda item: (-item[1], -dates.get(parts[item[0]]['event_id'], 0), item[0]))
    lexical = source_rank(parts, ordered(lexical_rank(parts, query)))
    semantic = []
    stats = {'state': 'hybrid', 'model': model, 'chunks': len(parts), 'new_chunks': 0,
             'cached_chunks': 0, 'query_cached': False, 'document_ms': 0, 'query_ms': 0,
             'keyword_hits': len(lexical), 'vector_hits': 0, 'skipped_sources': skipped}
    if overflow:
        stats.update(state='lexical_fallback', error='too_many_chunks')
    elif parts and use_vectors:
        try:
            ranked = vector_rank(parts, query, model, root or ROOT, client or Ollama(model), stats, budget_seconds, max_new)
            semantic = source_rank(parts, ordered(ranked))
            stats['vector_hits'] = len(semantic)
        except (IndexFailure, OSError, sqlite3.Error) as exc:
            stats.update(state='lexical_fallback', error=str(exc) if isinstance(exc, IndexFailure) else 'index_unavailable')
    scores = collections.defaultdict(float)
    for lane in (lexical, semantic):
        for rank, (sid, _, _) in enumerate(lane, 1):
            scores[sid] += 1 / (60 + rank)
    ids = sorted(scores, key=lambda sid: (-scores[sid], -dates.get(sid, 0), sid))[:top_k]
    hits = []
    for name, lane in (('keyword', lexical), ('vector', semantic)):
        for sid, i, score in lane:
            if sid in ids:
                p = parts[i]
                hits.append({'event_id': sid, 'start': p['start'], 'end': p['end'], 'lane': name, 'score': score})
    if not use_vectors:
        stats.update(state='lexical_fallback', error='disabled')
    stats['ms'] = round((time.monotonic() - started) * 1000)
    return {'ids': ids, 'hits': hits, 'index': stats}


def clear(root=None):
    # Keep the DB identity; in-flight writers carry an old generation and cannot resurrect it.
    with database(root or ROOT) as con:
        con.execute('BEGIN IMMEDIATE')
        try:
            con.execute('UPDATE control SET generation=generation+1 WHERE id=1')
            con.execute('DELETE FROM vectors')
            con.execute('DELETE FROM spaces')
            con.execute('COMMIT')
        except Exception:
            con.execute('ROLLBACK')
            raise
    return {'index': {'state': 'cleared', 'model': DEFAULT_MODEL, 'chunks': 0}}


def status(model=DEFAULT_MODEL, root=None, client=None):
    result = {'state': 'ready', 'model': model, 'chunks': 0}
    try:
        digest = (client or Ollama(model)).identity()
        space = fingerprint(json.dumps([model, digest, VERSION]))
        with database(root or ROOT) as con:
            result['chunks'] = con.execute("SELECT COUNT(*) FROM vectors WHERE space=? AND hash LIKE 'd:%'", (space,)).fetchone()[0]
        result['digest'] = digest
    except (IndexFailure, OSError, sqlite3.Error) as exc:
        result.update(state='unavailable', error=str(exc) if isinstance(exc, IndexFailure) else 'index_unavailable')
    return {'index': result}

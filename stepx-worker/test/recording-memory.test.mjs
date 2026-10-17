import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createBridge } from '../src/index.js';
const token = 'isolated-personal-gate';
const uuid = '12345678-1234-1234-1234-123456789abc';
const batch = () => ({ schema: 'apt.recording-memory.batch/1', device_id: uuid,
  records: [{ id: 'apt_recording_' + uuid, revision: 1, title: 'StepX public fixture',
    text: 'public text', created: '2026-10-14T00:00:00.000Z', updated: '2026-10-15T00:00:00.000Z',
    partial: false, deleted: false }] });
const req = (body, headers = {}) => new Request('https://apt-backend.example/stepx/recording-memory/sync', {
  method: 'POST', headers: { 'X-Growth-Token': token, 'Content-Type': 'application/json', ...headers },
  body: typeof body === 'string' ? body : JSON.stringify(body),
});
test('recording sync uses the existing authenticated service binding and preserves exact receipts', async () => {
  const value = { schema: 'apt.recording-memory.receipt/1', accepted: [{ id: 'apt_recording_' + uuid, revision: 1, fingerprint: 'a'.repeat(64) }], stale: [], conflicts: [] };
  let calls = 0;
  const bridge = createBridge(() => { throw Error('public fetch must not be used'); });
  const env = { GROWTH_CLIENT_TOKEN: token, GROWTH_UPSTREAM: { async fetch(request) {
    calls++; assert.equal(request.url, 'https://apt-backend.example/recording-memory/sync');
    assert.equal(request.headers.get('X-Growth-Token'), token); assert.equal(request.redirect, 'manual');
    assert.deepEqual(await request.json(), batch()); return Response.json(value);
  } } };
  const response = await bridge.fetch(req(batch()), env);
  assert.equal(response.status, 200); assert.deepEqual(await response.json(), value); assert.equal(calls, 1);
});
test('gate, bounded JSON and envelope validation happen before any upstream call', async () => {
  let calls = 0; const bridge = createBridge(async () => { calls++; return Response.json({}); });
  const env = { GROWTH_CLIENT_TOKEN: token };
  for (const [body, headers, status] of [
    [batch(), { 'X-Growth-Token': '' }, 401], [batch(), { 'Content-Type': 'text/plain' }, 415],
    [{ ...batch(), device_id: '../other' }, {}, 400], [{ ...batch(), schema: 'other' }, {}, 400],
    [{ ...batch(), records: [] }, {}, 400], [{ ...batch(), unexpected: true }, {}, 400],
    ['x'.repeat(8 * 1024 * 1024 + 1), {}, 413],
  ]) assert.equal((await bridge.fetch(req(body, headers), env)).status, status);
  assert.equal(calls, 0);
});
test('recording payloads can exceed old chat limits without raising chat limits or hiding upstream errors', async () => {
  const data = batch(); data.records = Array.from({ length: 30 }, (_, index) => ({ ...data.records[0], id: 'apt_recording_' + crypto.randomUUID(), revision: index + 1, text: 'public'.repeat(2000) }));
  const bridge = createBridge(async (url, init) => {
    assert.equal(url, 'https://apt-backend.example/recording-memory/sync'); assert.ok(init.body.length > 256 * 1024);
    return Response.json({ error: 'recording_memory_storage_failed' }, { status: 503 });
  });
  const response = await bridge.fetch(req(data), { GROWTH_CLIENT_TOKEN: token });
  assert.equal(response.status, 503); assert.equal((await response.json()).error, 'recording_memory_storage_failed');
  const chat = new Request('https://apt-backend.example/stepx/chat', { method: 'POST', headers: { 'X-Growth-Token': token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ messages: [{ role: 'user', content: 'x'.repeat(300000) }] }) });
  assert.equal((await bridge.fetch(chat, { GROWTH_CLIENT_TOKEN: token })).status, 413);
});
test('redirects are refused and OPTIONS performs no authenticated or paid work', async () => {
  let calls = 0; const bridge = createBridge(async () => { calls++; return new Response(null, { status: 302, headers: { Location: 'https://elsewhere.invalid' } }); });
  const response = await bridge.fetch(req(batch()), { GROWTH_CLIENT_TOKEN: token });
  assert.equal(response.status, 502);
  assert.equal((await bridge.fetch(new Request('https://apt-backend.example/stepx/recording-memory/sync', { method: 'OPTIONS' }), {})).status, 204);
  assert.equal(calls, 1);
});

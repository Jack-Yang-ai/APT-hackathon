// 声纹队列的幂等与状态语义(M2-认8 ③)。照 extract 队列的测法。
//   cd worker && node --test test_voiceprint_queue.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { enqueue, takeResult, jobKey, outKey } from './src/voiceprint_queue.js';

/** 内存桶,只实现用到的三个方法。 */
function bucket() {
  const store = new Map();
  return {
    store,
    async head(k) { return store.has(k) ? {} : null; },
    async get(k) {
      return store.has(k) ? { text: async () => store.get(k) } : null;
    },
    async put(k, v) { store.set(k, typeof v === 'string' ? v : String(v)); },
    async delete(k) { store.delete(k); },
  };
}

const payload = { session: 9, model: 'redimnet-s/vb2+vox2+cnc/ft_mix',
                  lines: [{ line_id: 1, block_seq: 0, start_ms: 0, end_ms: 4000 }] };

test('排队幂等:重复排不产生第二个 job', async () => {
  const b = bucket();
  const first = await enqueue(b, { session: 9, payload });
  assert.equal(first.created, true);
  const again = await enqueue(b, { session: 9, payload });
  assert.equal(again.state, 'queued');
  assert.equal(again.created, undefined, '重放排出了第二份 —— Mac 会白判一遍');
});

test('产物已在 ⇒ 直接 done,不再排队', async () => {
  const b = bucket();
  await b.put(outKey(9), '{"clusters":[]}');
  const r = await enqueue(b, { session: 9, payload });
  assert.equal(r.state, 'done');
  assert.ok(!b.store.has(jobKey(9)), '产物都有了还排 job —— 判完的场次被重判');
});

test('取结果三态:none / running / done,且取走不删', async () => {
  const b = bucket();
  assert.equal((await takeResult(b, { session: 9 })).state, 'none');
  await enqueue(b, { session: 9, payload });
  assert.equal((await takeResult(b, { session: 9 })).state, 'running');
  await b.put(outKey(9), '{"clusters":[]}');
  const done = await takeResult(b, { session: 9 });
  assert.equal(done.state, 'done');
  assert.equal(done.body, '{"clusters":[]}');
  assert.ok(b.store.has(outKey(9)), '取走就删的话,重装的手机永远取不回判决');
});

test('force:删旧产物、重排 job —— enroll 之后的重判靠它', async () => {
  const b = bucket();
  await b.put(outKey(9), '旧判决');
  const r = await enqueue(b, { session: 9, payload: { ...payload, force: true } });
  assert.equal(r.created, true, 'force 没绕过「产物已在」的短路 —— 重判永远排不上');
  assert.ok(!b.store.has(outKey(9)), '旧产物没删 —— 手机会先取到旧判决当成新的');
});

// 云端收割器自测。跑:node worker/test_collector.mjs
//
// 打的是**这一层丢东西的三种方式**,都不报错:
//   ① 先删待办后写结果 → 中间挂掉就把整条任务弄丢,表现是「永远在整理中」
//   ② 失败不落成结果   → 失败的任务一直躺在待办里被反复问,手机永远等不到答案
//   ③ 上游永不给终态   → 待办被问到天荒地老,而手机那头也是无限等

import assert from "node:assert";
import {
  classify, collect, MAX_PER_RUN, PENDING_PREFIX, PENDING_TTL_MS,
  pendingKey, RESULT_PREFIX, resultKey, RESULT_TTL_MS, sweepResults,
} from "./src/collector.js";

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

/** 假 R2:记下每一次 put/delete 的**顺序** —— 「先写后删」只能靠顺序验。 */
const fakeBucket = (seed = {}) => {
  const objects = new Map(Object.entries(seed));
  const ops = [];
  return {
    objects, ops,
    async list({ prefix, limit = 1000 }) {
      const out = [...objects.entries()]
        .filter(([k]) => k.startsWith(prefix))
        .slice(0, limit)
        .map(([key, v]) => ({ key, uploaded: v.uploaded ?? new Date().toISOString() }));
      return { objects: out };
    },
    async get(key) {
      const v = objects.get(key);
      return v ? { json: async () => JSON.parse(v.body) } : null;
    },
    async put(key, body) { ops.push(["put", key]); objects.set(key, { body }); },
    async delete(key) { ops.push(["delete", key]); objects.delete(key); },
  };
};

const pending = (taskID, ageMs = 0) => ({
  [pendingKey(taskID)]: {
    body: JSON.stringify({ task_id: taskID }),
    uploaded: new Date(Date.now() - ageMs).toISOString(),
  },
});

// ── 分档:和手机侧同一套判据 ──────────────────────────────────

test("完成判定看 result 出现,不看 status —— 这接口没有 SUCCESS 终态", () => {
  assert.strictEqual(classify({ duration: 38, result: [{ utterances: [{ text: "喂" }] }] }), "done");
  assert.strictEqual(classify({ status: "PROCESSING" }), "pending");
  assert.strictEqual(classify({}), "pending");
});

test("result:[{}] 算终态 —— 「转完了,一个字都没有」", () => {
  // 判成还没好的话就退回那个永远轮询的洞里,而那正是这次要修的东西。
  assert.strictEqual(classify({ duration: 270, result: [{}] }), "done");
});

test("失败要认出来,而且在 result 之前判", () => {
  assert.strictEqual(classify({ status: "FAILED", result: [{}] }), "failed");
  assert.strictEqual(classify({ status: "AUDIO_ERROR" }), "failed");
  assert.strictEqual(classify({ status: "CONTENT_BLOCKED" }), "failed");
});

test("data 包一层也要认", () => {
  assert.strictEqual(classify({ data: { result: [{ utterances: [{}] }] } }), "done");
});

// ── 🔴 先写结果,再删待办 ───────────────────────────────────

test("出结果时:先 put 结果,后 delete 待办", async () => {
  // 反过来的话,两步之间挂掉就把这条任务弄丢了 —— 而丢的表现是
  // 「这一场永远在整理中」,没有任何地方报错。
  const b = fakeBucket(pending("t1"));
  await collect({ bucket: b, fetchQuery: async () => ({ ok: true, body: '{"result":[{"utterances":[{}]}]}' }) });

  const keys = b.ops.map(([op, k]) => `${op} ${k}`);
  assert.deepStrictEqual(keys, [`put ${resultKey("t1")}`, `delete ${pendingKey("t1")}`],
    `顺序错了:${JSON.stringify(keys)}`);
});

test("结果里存的是**原始报文**,不是解析结果", async () => {
  // 解析器改了要能拿回原文重跑,而重新提交是要花钱的 —— 和 asr_jobs 同一条理由。
  const raw = '{"duration":270.14,"result":[{"utterances":[{"text":"原话"}]}]}';
  const b = fakeBucket(pending("t1"));
  await collect({ bucket: b, fetchQuery: async () => ({ ok: true, body: raw }) });
  assert.strictEqual(JSON.parse(b.objects.get(resultKey("t1")).body).body, raw);
});

// ── 🔴 失败也要落成结果 ────────────────────────────────────

test("失败落成结果并清掉待办 —— 不能让它一直躺在待办里", async () => {
  const b = fakeBucket(pending("t1"));
  const out = await collect({ bucket: b, fetchQuery: async () => ({ ok: true, body: '{"status":"FAILED"}' }) });
  assert.strictEqual(out.failed, 1);
  assert.strictEqual(JSON.parse(b.objects.get(resultKey("t1")).body).verdict, "failed");
  assert.strictEqual(b.objects.has(pendingKey("t1")), false, "失败的待办没被清掉,会被反复问");
});

// ~~上游非 2xx 也算失败~~ **2026-08-19 作废,改成不算终态。**
// 作废的理由:一次 429/500 就把这一块永久判失败,那 5 分钟的内容以占位行落库,
// 而它其实还在跑。抛出来的网络错本来就按「不算终态」处理,非 2xx 是同一件事
// 的另一种表现。而且自本次起 `asr/pending/` 同时是幂等闸的判据,误删 = 重新
// 打开「同一块再付一次钱」的窗口。
// 原来那条要求(「手机那头必须等得到一个答案」)**仍然成立**,由 6 小时兜底期限
// 保证 —— 见下面那条过期测试。
test("上游一次非 2xx 不算终态:待办留着,不写结果", async () => {
  const b = fakeBucket(pending("t1"));
  const out = await collect({ bucket: b,
                              fetchQuery: async () => ({ ok: false, status: 429, body: "boom" }) });
  assert.strictEqual(out.failed, 0, "一次 429 就判死 —— 那 5 分钟的内容会以占位行落库");
  assert.strictEqual(out.errors.length, 1, "不当终态也要数出来,不能静默跳过");
  assert.ok(b.objects.has(pendingKey("t1")), "待办被删了 —— 幂等闸的判据没了");
});

// ── 还在算:留着,别动 ─────────────────────────────────────

test("还在算的留在待办里,一个字节都不写结果", async () => {
  const b = fakeBucket(pending("t1"));
  const out = await collect({ bucket: b, fetchQuery: async () => ({ ok: true, body: '{"status":"PROCESSING"}' }) });
  assert.strictEqual(out.stillRunning, 1);
  assert.strictEqual(b.ops.length, 0, "还在算却动了桶");
  assert.strictEqual(b.objects.has(pendingKey("t1")), true);
});

test("问不通不算终态 —— 网络抖一下不该把一整场判死", async () => {
  const b = fakeBucket(pending("t1"));
  const out = await collect({ bucket: b, fetchQuery: async () => { throw new Error("网络断了"); } });
  assert.strictEqual(out.errors.length, 1);
  assert.strictEqual(b.objects.has(pendingKey("t1")), true, "一次网络抖动就把任务弄没了");
  assert.strictEqual(out.failed, 0);
});

// ── 🔴 兜底期限 ────────────────────────────────────────────

test("超期的待办自己判失败 —— 否则手机无限等", async () => {
  const b = fakeBucket(pending("t1", PENDING_TTL_MS + 60_000));
  const out = await collect({ bucket: b, fetchQuery: async () => ({ ok: true, body: '{"status":"PROCESSING"}' }) });
  assert.strictEqual(out.expired, 1);
  assert.strictEqual(JSON.parse(b.objects.get(resultKey("t1")).body).verdict, "failed");
});

test("期限只管「还在算」的 —— 已经有终态的不受它影响", async () => {
  const b = fakeBucket(pending("t1", PENDING_TTL_MS + 60_000));
  const out = await collect({ bucket: b, fetchQuery: async () => ({ ok: true, body: '{"result":[{"utterances":[{}]}]}' }) });
  assert.strictEqual(out.expired, 0);
  assert.strictEqual(out.done, 1, "超期但其实已经成了的被判成了失败 —— 那是把结果扔了");
});

// ── 规模 ──────────────────────────────────────────────────

test("一轮有上限 —— 撞子请求上限会让整次 cron 失败,那才是真丢东西", async () => {
  let seed = {};
  for (let i = 0; i < MAX_PER_RUN + 15; i++) seed = { ...seed, ...pending(`t${i}`) };
  const b = fakeBucket(seed);
  let asked = 0;
  const out = await collect({ bucket: b,
    fetchQuery: async () => { asked++; return { ok: true, body: '{"status":"PROCESSING"}' }; } });
  assert.ok(asked <= MAX_PER_RUN, `一轮问了 ${asked} 次,超过上限 ${MAX_PER_RUN}`);
  assert.strictEqual(out.checked, MAX_PER_RUN);
});

test("没有待办时不打任何上游", async () => {
  const b = fakeBucket();
  let asked = 0;
  await collect({ bucket: b, fetchQuery: async () => { asked++; return { ok: true, body: "{}" }; } });
  assert.strictEqual(asked, 0);
});

// ── 扫过期结果 ────────────────────────────────────────────

test("过期的结果扫掉,没过期的留着", async () => {
  const b = fakeBucket({
    [`${RESULT_PREFIX}old.json`]: { body: "{}", uploaded: new Date(Date.now() - RESULT_TTL_MS - 1000).toISOString() },
    [`${RESULT_PREFIX}new.json`]: { body: "{}", uploaded: new Date().toISOString() },
  });
  assert.strictEqual(await sweepResults({ bucket: b }), 1);
  assert.strictEqual(b.objects.has(`${RESULT_PREFIX}new.json`), true, "把还有用的结果扫掉了");
});

test("待办与结果各用各的前缀,互不相扫", () => {
  assert.ok(!PENDING_PREFIX.startsWith(RESULT_PREFIX));
  assert.ok(!RESULT_PREFIX.startsWith(PENDING_PREFIX));
});

// ── 跑 ────────────────────────────────────────────────────

let failed = 0;
for (const [name, fn] of tests) {
  try { await fn(); console.log("PASS", name); }
  catch (e) { failed++; console.log("FAIL", name, "\n   ", e.message); }
}
console.log(failed ? `\n${failed} failed / ${tests.length}` : `\nall passed (${tests.length})`);
process.exit(failed ? 1 : 0);

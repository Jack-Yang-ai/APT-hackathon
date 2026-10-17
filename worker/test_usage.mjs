// 对账口自测。跑:node worker/test_usage.mjs
//
// 打的是**汇总会怎么骗人**:
//   ① 把 cost_usd=null 当 0 → 漏配价和真免费长得一模一样
//   ② 读不出来的账悄悄跳过 → 账面上它不存在,而钱是真花了
//   ③ 只报钱不报 token → 只知道贵了,不知道贵在输入还是输出

import assert from "node:assert";
import { summarize, USAGE_PREFIX } from "./src/usage.js";

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

const bucketOf = (recs, { corrupt = 0 } = {}) => {
  const objects = new Map();
  recs.forEach((r, i) => objects.set(`${USAGE_PREFIX}2026-08-17/${i}.json`, JSON.stringify(r)));
  for (let i = 0; i < corrupt; i++) objects.set(`${USAGE_PREFIX}2026-08-17/bad${i}.json`, "不是 JSON");
  return {
    async list({ prefix }) {
      return { objects: [...objects.keys()].filter((k) => k.startsWith(prefix)).map((key) => ({ key })),
               truncated: false };
    },
    async get(key) {
      const v = objects.get(key);
      return v == null ? null : { json: async () => JSON.parse(v) };
    },
  };
};

const rec = (o = {}) => ({ scene: "extract", model: "deepseek-v4-flash",
  input: 1000, cache_create: 0, cache_read: 0, output: 500,
  audio_sec: null, cost_usd: 0.00049, ...o });

test("token 逐项汇总,不只报钱", async () => {
  const r = await summarize({ bucket: bucketOf([rec(), rec({ input: 2000, output: 100 })]) });
  assert.strictEqual(r.total.calls, 2);
  assert.strictEqual(r.total.input, 3000);
  assert.strictEqual(r.total.output, 600);
  assert.strictEqual(r.total.tokens, 3600);
});

test("缓存命中单列 —— 混在一起会把「缓存没生效」藏起来", async () => {
  // 命中价只有未命中的 1/10,合并之后看不出缓存有没有起作用
  const r = await summarize({ bucket: bucketOf([rec({ input: 200, cache_read: 800 })]) });
  assert.strictEqual(r.total.input, 200);
  assert.strictEqual(r.total.cache_read, 800);
  assert.strictEqual(r.total.tokens, 1500);
});

test("🔴 cost_usd 为 null 单独计数,不当 0", async () => {
  // 当 0 的话,「这个模型没配价」和「真免费」在账面上长得一模一样,
  // 而 accounting.js 特意让它返回 null 就是为了这个。
  const r = await summarize({ bucket: bucketOf([rec(), rec({ cost_usd: null })]) });
  assert.strictEqual(r.total.unpriced, 1, "漏配价的那条被抹平了");
  assert.strictEqual(r.total.cost_usd, 0.00049, "null 被当成 0 加进去了");
});

test("🔴 读不出来的账要数出来,不能当它不存在", async () => {
  const r = await summarize({ bucket: bucketOf([rec()], { corrupt: 2 }) });
  assert.strictEqual(r.unreadable, 2, "坏掉的账被悄悄跳过了 —— 钱是真花了的");
  assert.strictEqual(r.total.calls, 1);
});

test("按场景拆开,并按花钱多少排序 —— 降本要知道该降哪一笔", async () => {
  const r = await summarize({ bucket: bucketOf([
    rec({ scene: "extract", cost_usd: 0.001 }),
    rec({ scene: "asr", cost_usd: 0.01, audio_sec: 300, input: 0, output: 0 }),
  ]) });
  assert.deepStrictEqual(Object.keys(r.by_scene), ["asr", "extract"], "没按花钱多少排");
  assert.strictEqual(r.by_scene.asr.audio_min, 5);
});

test("没写场景的也要有个去处,不能凭空消失", async () => {
  const r = await summarize({ bucket: bucketOf([rec({ scene: undefined })]) });
  assert.strictEqual(r.by_scene["(没写场景)"].calls, 1);
});

test("人民币也报 —— 红线 ¥1.5/天 是人民币的", async () => {
  const r = await summarize({ bucket: bucketOf([rec({ cost_usd: 1 })]) });
  assert.strictEqual(r.total.cost_cny, 7.2);
});

test("R2 没绑时说清楚,不返回一份「零花费」的假账", async () => {
  const r = await summarize({ bucket: null });
  assert.ok(r.error, "没绑桶却报了一份看起来正常的账");
});

let failed = 0;
for (const [name, fn] of tests) {
  try { await fn(); console.log("PASS", name); }
  catch (e) { failed++; console.log("FAIL", name, "\n   ", e.message); }
}
console.log(failed ? `\n${failed} failed / ${tests.length}` : `\nall passed (${tests.length})`);
process.exit(failed ? 1 : 0);

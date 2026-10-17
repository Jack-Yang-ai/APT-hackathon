// 提交转写的幂等自测。跑:node worker/test_submit_idempotency.mjs
//
// 打的是**一种会静默多花钱的形态**(2026-08-18 真机抓到的):
//   提交在云代理这边成功了(任务建了、钱花了),而手机那边跨境这一跳超时,
//   没等到 task_id。手机的去重凭据是「拿到过 remote_id」——**恰恰失败的
//   那一块没有** —— 于是下一轮原样再提交一次。
//   当天云端账本记了 13 次 ASR,手机侧只有 10 条转写作业,差 3 条。
//
// 所以闸要设在云代理:**同一块音频,同一时刻只许有一个在跑的转写任务。**
// 判据不猜 TTL —— 认领里存着 task_id,而 `asr/pending/<task_id>.json`
// 由 collector 在判出终态时删掉:待办还在 = 还在跑 = 复用;没了 = 该真提交。

import assert from "node:assert";
import worker from "./src/index.js";
import { claimKey, pendingKey } from "./src/collector.js";

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

const fakeBucket = () => {
  const objects = new Map();
  return {
    objects,
    async list({ prefix, limit = 1000 }) {
      return { objects: [...objects.keys()].filter((k) => k.startsWith(prefix))
        .slice(0, limit).map((key) => ({ key, uploaded: new Date().toISOString() })) };
    },
    async get(key) {
      const v = objects.get(key);
      return v == null ? null : { json: async () => JSON.parse(v), text: async () => v };
    },
    async head(key) { return objects.has(key) ? { key } : null; },
    // 🔴 **put 必须是真异步的。** 第一版这里是同步 set,于是
    // 「认领用 await 还是 waitUntil」这条**测不出来** —— 而真 R2 的 put
    // 不可能同步返回。保真度不够的假件会让一整类断言变成恒真。
    async put(key, body) {
      await new Promise((r) => setTimeout(r, 5));
      objects.set(key, typeof body === "string" ? body : String(body));
    },
    async delete(key) { objects.delete(key); },
  };
};

const KEY = "inbox/audio/9001/block-0003.wav";

/** 造一套环境。`ctx.waitUntil` 默认**不执行**传进来的 promise ——
 *  它同时管两件事:验记账那条(账正是走 waitUntil 落盘的),
 *  以及钉住「认领必须在回话之前落盘」(改回 waitUntil 就落不进去)。 */
function harness({ runWaitUntil = false } = {}) {
  let upstream = 0;
  globalThis.fetch = async () => {
    upstream++;
    return new Response(JSON.stringify({ task_id: `T${upstream}` }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  };
  const bucket = fakeBucket();
  const waited = [];
  return {
    bucket,
    calls: () => upstream,
    env: { AUDIO: bucket, STEPFUN_API_KEY: "k", DEEPSEEK_API_KEY: "k", CLIENT_TOKEN: "tok" },
    // 默认**不执行** waitUntil 里的 promise:幂等的写如果搭在它上面,
    // 「回执丢了再提一次」那条就会露馅。只有验记账的那条需要它真跑
    // (账正是走 waitUntil 落盘的),否则那条断言恒真、测了个寂寞。
    ctx: { waitUntil(p) { if (runWaitUntil) waited.push(p); } },
    settle: () => Promise.all(waited),
  };
}

const submit = (h, key = KEY) => worker.fetch(new Request("https://api.example/asr/submit", {
  method: "POST",
  headers: { "Content-Type": "application/json", "X-Growth-Token": "tok" },
  body: JSON.stringify({ key, seconds: 330 }),
}), h.env, h.ctx);

test("第一次提交:打上游一次,认领与待办都落盘", async () => {
  const h = harness();
  const r = await submit(h);
  const j = await r.json();
  assert.equal(r.status, 200);
  assert.equal(j.task_id, "T1");
  assert.equal(h.calls(), 1);
  assert.ok(h.bucket.objects.has(pendingKey("T1")), "待办没落盘 —— collector 收不到它");
  assert.ok(h.bucket.objects.has(claimKey(KEY)), "认领没落盘 —— 幂等闸形同虚设");
});

test("回执丢了、手机重提同一块:不打上游,拿回同一个 task_id", async () => {
  const h = harness();
  await submit(h);
  const r = await submit(h);
  const j = await r.json();
  assert.equal(h.calls(), 1, `重提又打了一次上游 —— 那是白花的钱(共 ${h.calls()} 次)`);
  assert.equal(j.task_id, "T1", "重提该拿回原来那个任务,不是新建一个");
  assert.equal(j.reused, true);
});

test("待办已被 collector 删掉(有终态了)→ 重提是真的要重转,照常打上游", async () => {
  const h = harness();
  await submit(h);
  h.bucket.objects.delete(pendingKey("T1"));   // collector 判出终态时干的事
  const r = await submit(h);
  const j = await r.json();
  assert.equal(h.calls(), 2, "有终态之后还锁着 —— 用户点「再试一次」会永远拿回旧结果");
  assert.equal(j.task_id, "T2");
});

test("不同的块互不影响", async () => {
  const h = harness();
  await submit(h, "inbox/audio/9001/block-0003.wav");
  await submit(h, "inbox/audio/9001/block-0004.wav");
  assert.equal(h.calls(), 2, "认领按音频键分,别的块不该被连坐");
});

test("复用那一次不记账", async () => {
  const h = harness({ runWaitUntil: true });
  const count = () => [...h.bucket.objects.keys()].filter((k) => k.startsWith("usage/")).length;
  await submit(h);
  await h.settle();
  const after = count();
  assert.equal(after, 1, "前提不成立:真提交那次都没记账,这条就测不出东西");
  await submit(h);
  await h.settle();
  assert.equal(count(), after, "复用没花钱却记了账 —— 账本是判「值不值」的唯一依据");
});

let failed = 0;
for (const [name, fn] of tests) {
  try { await fn(); console.log("✓", name); }
  catch (e) { failed++; console.error("✗", name, "\n   ", e.message); }
}
console.log(failed ? `\n${failed} 条失败` : `\n${tests.length} 条全过`);
process.exit(failed ? 1 : 0);

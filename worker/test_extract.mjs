// 抽取转发自测。跑:node worker/test_extract.mjs
//
// 打的是**这条路由怎么失败**,不是「能不能连上 DeepSeek」——真上游那一跑
// 花钱,单独在验收里做一次。
//
// 这一层的错法有两种,都不报错:
//   ① 空正文当成功回去 —— 下游看起来就是「这场没抽到内容」,而实际是
//      max_tokens 被 thinking 吃光了(§4.2 明列的静默失败模式)
//   ② 账没落盘 —— 钱花了、账面上不存在。091afaa 就是这么丢了两周的转写账。

import assert from "node:assert";
import worker from "./src/index.js";
import { PRICES, priceUSD, ASR_CNY_PER_HOUR } from "./src/accounting.js";
import { enqueue, STALE_MS } from "./src/extract_queue.js";
import { readChatCompletion } from './src/chat_response.js';

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

const TOKEN = "test-client-token";

/** 假 R2 桶。记下写进来的对象,好断言账真的落了盘。 */
const fakeBucket = () => {
  const objects = new Map();
  return {
    objects,
    async put(key, value) { objects.set(key, value); },
    async get(key) { return objects.has(key) ? { body: objects.get(key),
      text: async () => objects.get(key), json: async () => JSON.parse(objects.get(key)) } : null; },
    async head(key) { return objects.has(key) ? { key } : null; },
    async delete(key) { objects.delete(key); },
    async list({ prefix }) { return { objects: [...objects.keys()].filter(k => k.startsWith(prefix)).map(key => ({ key })) }; },
  };
};

const envWith = (over = {}) => ({
  CLIENT_TOKEN: TOKEN,
  STEPFUN_API_KEY: "sk-stepfun",
  DEEPSEEK_API_KEY: "sk-deepseek",
  // 抽取 2026-08-21 起走 StepFun 的 step_plan 端点,用的是另一把钥匙。
  STEPFUN_PLAN_API_KEY: "sk-stepfun-plan",
  AUDIO: fakeBucket(),
  ...over,
});

const ctx = { waitUntil: (p) => p };

const post = (path, body, headers = { "X-Growth-Token": TOKEN }) =>
  new Request(`https://proxy.test${path}`, {
    method: "POST", headers, body: JSON.stringify(body),
  });

/** 把上游 fetch 换成桩,并记下它收到的请求。返回 calls 数组。 */
const stubUpstream = (responder) => {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init, body: JSON.parse(init.body) });
    return responder(calls.length);
  };
  return calls;
};

const llmOK = (content, usage = {}) =>
  new Response(JSON.stringify({
    choices: [{ message: { content }, finish_reason: "stop" }],
    usage: { prompt_tokens: 1000, prompt_cache_hit_tokens: 0,
             completion_tokens: 500, ...usage },
  }), { status: 200 });

const MESSAGES = [{ role: "user", content: "把这场抽成 JSON" }];

const sseOK = (content, { model = 'step-5-preview', done = true, usage = true, broken = false } = {}) => {
  const packets = [
    { model, choices: [{ index: 0, delta: { reasoning_content: '不得传给客户端的推理' } }] },
    { model, choices: [{ index: 0, delta: { content }, finish_reason: 'stop' }] },
  ];
  if (usage) packets.push({ model, choices: [], usage: { prompt_tokens: 100, completion_tokens: 50 } });
  let text = ': heartbeat\r\n\r\n' + packets.map(p => `data: ${JSON.stringify(p)}\r\n\r\n`).join('');
  if (broken) text += 'data: {bad-json}\r\n\r\n';
  if (done) text += 'data: [DONE]\r\n\r\n';
  const bytes = new TextEncoder().encode(text);
  return new Response(new ReadableStream({
    start(controller) {
      // 故意把中文和CRLF拆到任意字节边界。
      for (let i = 0; i < bytes.length; i += 7) controller.enqueue(bytes.slice(i, i + 7));
      controller.close();
    },
  }), { headers: { 'Content-Type': 'text/event-stream; charset=utf-8' } });
};

test("Step5上游SSE汇成原JSON，分片中文和用量完整，推理不外泄", async () => {
  const calls = stubUpstream(() => sseOK('完整中文正文'));
  const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES }), envWith(), ctx);
  assert.equal(r.status, 200);
  const d = await r.json();
  assert.equal(d.content, '完整中文正文');
  assert.equal(d.upstream_model, 'step-5-preview');
  assert.equal(calls[0].body.stream, true);
  assert.equal(d.accounting.record.output, 50);
  assert.equal(d.accounting.persisted, true);
  assert.ok(!JSON.stringify(d).includes('不得传给客户端'));
});

test("诊断仅包含流大小和数量，不含正文或推理", async () => {
  const diagnostics = {};
  await readChatCompletion(sseOK('中文正文'), diagnostics);
  assert.deepEqual(Object.keys(diagnostics).sort(), ['bytes','chunks','content_chars','frames','max_frame_chars']);
  assert.equal(diagnostics.content_chars, 4);
  assert.equal(diagnostics.frames, 4);
  assert.ok(diagnostics.bytes > 0 && diagnostics.chunks > 0 && diagnostics.max_frame_chars > 0);
  assert.ok(!JSON.stringify(diagnostics).includes('中文正文'));
});

test("超长SSE行细碎到达仍保持完整UTF8、终态和用量，推理不外传", async () => {
  const bytes = new TextEncoder().encode(packet({ model: 'step-5-preview', choices: [{ index: 0,
    delta: { reasoning_content: 'x'.repeat(512 * 1024) } }] })
    + packet(delta('中文正文', 'stop')) + packet(finalUsage) + 'data: [DONE]\n\n');
  const response = new Response(new ReadableStream({ start(controller) {
    for (let i = 0; i < bytes.length; i += 255) controller.enqueue(bytes.subarray(i, i + 255));
    controller.close();
  } }), { headers: { 'Content-Type': 'text/event-stream' } });
  const metrics = {}, result = await readChatCompletion(response, metrics);
  assert.equal(result.stream_error, null);
  assert.equal(result.usage.completion_tokens, 50);
  assert.equal(result.choices[0].message.content, '中文正文');
  assert.ok(metrics.max_frame_chars > 512 * 1024);
});

test("原生BYOB合批保留不足一批的EOF尾部，不支持readAtLeast时释放锁回退", async () => {
  const raw = new TextEncoder().encode(packet(delta('尾部中文', 'stop')) + packet(finalUsage) + 'data: [DONE]\n\n');
  for (const native of [true, false]) {
    let released = false, cancelled = false, returned = false;
    const reader = {
      async read() { if (returned) return { done: true }; returned = true; return { value: raw, done: false }; },
      releaseLock() { released = true; }, async cancel() { cancelled = true; },
    };
    if (native) reader.readAtLeast = async (min, buffer) => {
      assert.equal(min, 16384); assert.equal(buffer.length, 16384);
      assert.equal(returned, false); returned = true;
      buffer.set(raw); return { value: buffer.subarray(0, raw.length), done: false };
    };
    const response = { headers: new Headers({ 'Content-Type': 'text/event-stream' }), body: {
      getReader(options) {
        if (!native && options?.mode === 'byob') return { releaseLock() { released = true; } };
        if (!native) assert.equal(released, true);
        return reader;
      },
    } };
    const result = await readChatCompletion(response);
    assert.equal(result.stream_error, null);
    assert.equal(result.choices[0].message.content, '尾部中文');
    assert.equal(result.usage.completion_tokens, 50);
    assert.equal(cancelled, true); assert.equal(released, true);
  }
});

test("SSE截断或坏帧拒收，已返回用量仍记账", async () => {
  for (const opts of [{ done: false }, { broken: true }]) {
    stubUpstream(() => sseOK('{}', opts));
    const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES }), envWith(), ctx);
    assert.equal(r.status, 502);
    const d = await r.json();
    assert.equal(d.content, undefined);
    assert.equal(d.accounting.record.output, 50);
    assert.equal(d.accounting.persisted, true);
  }
});

test("SSE缺usage必须标未知费用，不能把已调用记成免费", async () => {
  stubUpstream(() => sseOK('{}', { usage: false }));
  const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES }), envWith(), ctx);
  assert.equal(r.status, 200);
  const d = await r.json();
  assert.equal(d.accounting.record.cost_usd, null);
  assert.equal(d.accounting.record.usage_unknown, true);
});

const rawSSE = (parts, { open = false, onCancel = () => {} } = {}) =>
  new Response(new ReadableStream({
    start(controller) {
      for (const part of parts) controller.enqueue(typeof part === 'string' ? new TextEncoder().encode(part) : part);
      if (!open) controller.close();
    },
    cancel: onCancel,
  }), { headers: { 'Content-Type': 'text/event-stream' } });
const packet = value => `data: ${JSON.stringify(value)}\n\n`;
const finalUsage = { model: 'step-5-preview', choices: [], usage: { prompt_tokens: 100, completion_tokens: 50 } };
const delta = (content, finish_reason = null) => ({ model: 'step-5-preview',
  choices: [{ index: 0, delta: { content }, finish_reason }] });

test("SSE坏UTF8拒收且保留先前用量，不能把损坏正文替成新字", async () => {
  stubUpstream(() => rawSSE([packet(finalUsage), 'data: {"choices":[{"delta":{"content":"',
    new Uint8Array([0xff]), '"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n']));
  const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES }), envWith(), ctx);
  assert.equal(r.status, 502);
  const d = await r.json();
  assert.equal(d.content, undefined);
  assert.equal(d.accounting.record.output, 50);
  assert.equal(d.accounting.persisted, true);
});

test("SSE非法帧、正文类型、终态冲突及终态后正文均拒收", async () => {
  for (const frames of [
    [delta('{}', 'length'), delta(null, 'stop')],
    [delta('{}', 'stop'), delta('后加正文')],
    [delta(123, 'stop')], [[], delta('{}', 'stop')],
    [{ model: 'step-5-preview', choices: [[]] }, delta('{}', 'stop')],
    [{ model: 'step-5-preview', choices: [{ delta: [] }] }, delta('{}', 'stop')],
  ]) {
    stubUpstream(() => rawSSE([...frames, finalUsage].map(packet).concat('data: [DONE]\n\n')));
    const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES }), envWith(), ctx);
    assert.equal(r.status, 502, JSON.stringify(frames));
    const d = await r.json();
    assert.equal(d.content, undefined);
    assert.equal(d.accounting.record.output, 50);
    assert.equal(d.accounting.persisted, true);
  }
});

test("SSE空body拒收并持久化未知费用账", async () => {
  stubUpstream(() => new Response(null, { headers: { 'Content-Type': 'text/event-stream' } }));
  const env = envWith();
  const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES }), env, ctx);
  assert.equal(r.status, 502);
  const d = await r.json();
  assert.equal(d.accounting.record.usage_unknown, true);
  assert.equal(d.accounting.record.cost_usd, null);
  assert.equal(d.accounting.persisted, true);
  assert.equal([...env.AUDIO.objects.keys()].filter(k => k.startsWith('usage/')).length, 1);
});

test("SSE负数、小数及非法缓存用量拒收并落未知费用，不能抵扣预算", async () => {
  for (const usage of [
    { prompt_tokens: 0, completion_tokens: -10 }, { prompt_tokens: -1, completion_tokens: 10 },
    { prompt_tokens: 0, completion_tokens: 1.5 },
    { prompt_tokens: 10, completion_tokens: 1, prompt_tokens_details: { cached_tokens: -1 } },
    { prompt_tokens: 10, completion_tokens: 1, prompt_cache_hit_tokens: '5' },
    { prompt_tokens: 10, completion_tokens: 1, prompt_cache_hit_tokens: 11 },
  ]) {
    stubUpstream(() => rawSSE([packet(delta('{}', 'stop')), packet({ ...finalUsage, usage }), 'data: [DONE]\n\n']));
    const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES }), envWith(), ctx);
    assert.equal(r.status, 502);
    const d = await r.json();
    assert.equal(d.accounting.record.usage_unknown, true);
    assert.equal(d.accounting.record.cost_usd, null);
    assert.equal(d.accounting.record.output, 0);
    assert.equal(d.accounting.persisted, true);
  }
});

test("SSE到DONE立即取消已完成连接，不等上游EOF", async () => {
  let cancelled = false;
  const result = await readChatCompletion(rawSSE([
    packet(delta('{}', 'stop')), packet(finalUsage), 'data: [DONE]\n\n',
  ], { open: true, onCancel: () => { cancelled = true; } }));
  assert.equal(result.stream_error, null);
  assert.equal(result.usage.completion_tokens, 50);
  assert.equal(cancelled, true);
});

test("Mac协商的JSON流先返回并持续心跳，最后保留正文和实际状态", async () => {
  let finish, beat;
  const originalInterval = globalThis.setInterval;
  globalThis.setInterval = fn => { beat = fn; return undefined; };
  try {
    globalThis.fetch = () => new Promise(resolve => { finish = resolve; });
    const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES },
      { 'X-Growth-Token': TOKEN, Accept: 'application/x-ndjson' }), envWith(), ctx);
    assert.equal(r.headers.get('Content-Type'), 'application/x-ndjson');
    const reader = r.body.getReader();
    assert.equal(JSON.parse(new TextDecoder().decode((await reader.read()).value)).type, 'ping');
    beat();
    const progress = JSON.parse(new TextDecoder().decode((await reader.read()).value));
    assert.equal(progress.type, 'ping');
    assert.deepEqual(progress.upstream, {});
    finish(sseOK('完整结果'));
    const final = JSON.parse(new TextDecoder().decode((await reader.read()).value));
    assert.equal(final.type, 'result');
    assert.equal(final.status, 200);
    assert.equal(final.body.content, '完整结果');
    assert.equal(final.body.accounting.persisted, true);
    assert.equal((await reader.read()).done, true);
  } finally { globalThis.setInterval = originalInterval; }
});

test("心跳流内模型失败仍保留502与已知账，不能被外层200冒充成功", async () => {
  stubUpstream(() => sseOK('{}', { done: false }));
  const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES },
    { 'X-Growth-Token': TOKEN, Accept: 'application/x-ndjson' }), envWith(), ctx);
  const frames = (await r.text()).trim().split('\n').map(JSON.parse);
  const final = frames.at(-1);
  assert.equal(final.type, 'result');
  assert.equal(final.status, 502);
  assert.equal(final.body.content, undefined);
  assert.equal(final.body.accounting.record.output, 50);
  assert.equal(final.body.accounting.persisted, true);
});

test("心跳流取消或900秒截止会终止上游，不能无限维持已付费请求", async () => {
  for (const cancel of [true, false]) {
    let upstreamSignal, expire;
    const pending = [], originalTimeout = globalThis.setTimeout, env = envWith();
    globalThis.setTimeout = (fn, delay) => { assert.equal(delay, 900000); expire = fn; return undefined; };
    try {
      globalThis.fetch = (_url, init) => new Promise((_resolve, reject) => {
        upstreamSignal = init.signal;
        upstreamSignal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
      });
      const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES },
        { 'X-Growth-Token': TOKEN, Accept: 'application/x-ndjson' }), env,
        { waitUntil: p => { pending.push(p); } });
      const reader = r.body.getReader(); await reader.read();
      if (cancel) await reader.cancel();
      else {
        expire();
        const final = JSON.parse(new TextDecoder().decode((await reader.read()).value));
        assert.equal(final.status, 502);
        assert.equal(final.body.accounting.record.cost_usd, null);
        assert.equal(final.body.accounting.record.usage_unknown, true);
        assert.equal(final.body.accounting.persisted, true);
      }
      assert.equal(upstreamSignal.aborted, true);
      await Promise.all(pending);
      const usage = [...env.AUDIO.objects].filter(([key]) => key.startsWith('usage/'));
      assert.equal(usage.length, 1);
      assert.equal(JSON.parse(usage[0][1]).usage_unknown, true);
    } finally { globalThis.setTimeout = originalTimeout; }
  }
});

test("DS已收到headers后取消读正文也只落一笔未知费用账", async () => {
  const env = envWith(), pending = [];
  globalThis.fetch = async (_url, init) => new Response(new ReadableStream({
    start(controller) { init.signal.addEventListener('abort', () => controller.error(new Error('aborted')), { once: true }); },
  }), { headers: { 'Content-Type': 'application/json' } });
  const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES, provider: 'deepseek-flash' },
    { 'X-Growth-Token': TOKEN, Accept: 'application/x-ndjson' }), env,
    { waitUntil: p => { pending.push(p); } });
  const reader = r.body.getReader(); await reader.read();
  await Promise.resolve();
  await reader.cancel();
  await Promise.all(pending);
  const usage = [...env.AUDIO.objects].filter(([key]) => key.startsWith('usage/'));
  assert.equal(usage.length, 1);
  const record = JSON.parse(usage[0][1]);
  assert.equal(record.model, 'deepseek-flash');
  assert.equal(record.cost_usd, null);
  assert.equal(record.usage_unknown, true);
});

test("抽取使用 Step 5 默认推理且保留输出预算", async () => {
  for (const scene of ['extract', 'extract_s1', 'extract_s2']) {
    const calls = stubUpstream(() => llmOK('{}'));
    const r = await worker.fetch(post('/extract', { scene, messages: MESSAGES }), envWith(), ctx);
    assert.equal(r.status, 200);
    assert.equal(calls[0].body.model, 'step-5-preview');
    assert.equal(calls[0].body.stream, true);
    assert.equal(calls[0].body.reasoning_effort, undefined);
    assert.equal(calls[0].body.max_tokens, scene === 'extract' ? 64000 : 30000);
  }
});

test("daemon 的 deepseek-flash 兜底真实切模型和计账", async () => {
  const env = envWith();
  const calls = stubUpstream(() => llmOK('{}'));
  const r = await worker.fetch(post('/extract', {
    scene: 'extract_s2', messages: MESSAGES, provider: 'deepseek-flash',
  }), env, ctx);
  assert.equal(r.status, 200);
  assert.equal(calls[0].url, 'https://api.deepseek.com/v1/chat/completions');
  assert.equal(calls[0].body.model, 'deepseek-flash');
  assert.equal(calls[0].body.stream, false);
  assert.equal(calls[0].body.reasoning_effort, undefined, 'Step 5 调参不泄漏给兜底');
  const result = await r.json();
  assert.equal(result.model, 'deepseek-flash');
  assert.equal(result.accounting.record.model, 'deepseek-flash');
});

test("上游返回其他模型须拒绝，已花用量按真实模型落账", async () => {
  stubUpstream(() => new Response(JSON.stringify({ model: 'step-3.7-flash',
    choices: [{ message: { content: '{}' } }], usage: { completion_tokens: 100 },
  })));
  const r = await worker.fetch(post('/extract', { scene: 'extract_s2', messages: MESSAGES }), envWith(), ctx);
  assert.equal(r.status, 502);
  const result = await r.json();
  assert.equal(result.upstream_model, 'step-3.7-flash');
  assert.equal(result.accounting.record.model, 'step-3.7-flash');
});

test("旧单阶段 cron 同样保持默认推理，错模型留任务并按真实用量记账", async () => {
  for (const returned of ['step-5-preview', 'step-3.7-flash']) {
    const env = envWith({ STEPFUN_API_KEY: undefined });
    const ticket = await enqueue(env.AUDIO, { session: 'test', part: 0, prompt: '原文', model: 'step-5-preview' });
    const key = `extract/jobs/${ticket.ticket}.json`;
    const job = JSON.parse(env.AUDIO.objects.get(key));
    env.AUDIO.objects.set(key, JSON.stringify({ ...job, at: new Date(Date.now() - STALE_MS - 1000).toISOString() }));
    const calls = stubUpstream(() => sseOK('{}', { model: returned }));
    const pending = [];
    await worker.scheduled({}, env, { waitUntil(p) { pending.push(p); } });
    await Promise.all(pending);
    assert.equal(calls[0].body.reasoning_effort, undefined);
    assert.equal(calls[0].body.stream, true);
    assert.equal(env.AUDIO.objects.has(key), returned !== 'step-5-preview');
    assert.equal(env.AUDIO.objects.has(`extract/out/${ticket.ticket}.json`), returned === 'step-5-preview');
    const usage = [...env.AUDIO.objects].filter(([key]) => key.startsWith('usage/'));
    assert.equal(usage.length, 1);
    assert.equal(JSON.parse(usage[0][1]).model, returned);
  }
});

// ── 路由表:和 Python 侧对撞 ──────────────────────────────────

// ⚠️ **遍历 worker 的每一个场景,不写死某一个。**
// 上一版只对撞 `extract`,于是 2026-08-17 新加 `ask` 时它**零覆盖** ——
// 那正是今天刚记下的那个形态:「在旁边另写一份对的,原址一直没动」。
// 新增场景只要没在 Python 侧登记,这条测试立刻红,不需要谁记得回来加。
test("SCENE_ROUTES 每一个场景都与 shared/model_router.py 对得上", async () => {
  const { readFileSync } = await import("node:fs");
  const py = readFileSync(new URL("../shared/model_router.py", import.meta.url), "utf8");
  const js = readFileSync(new URL("./src/index.js", import.meta.url), "utf8");

  // 从 worker 源码里把场景名抠出来 —— 不 import 常量,是为了让这条测试
  // 在「有人把 SCENE_ROUTES 改成动态生成」时也照样看得见真实取值。
  const block = js.match(/const SCENE_ROUTES = \{([\s\S]*?)\n\};/);
  assert.ok(block, "找不到 SCENE_ROUTES —— 表结构变了,这个测试要跟着改");
  const scenes = [...block[1].matchAll(/^\s*(\w+):\s*\{/gm)].map(m => m[1]);
  assert.ok(scenes.length >= 2, `只抠出 ${scenes.length} 个场景,正则该修了`);

  // 🔴 **反向也要查**(2026-08-24 补)。原来只查「worker 有的 Python 也有」,
  // 而 Python 单边多一个场景时**一声不响** —— 手机/daemon 按 Python 的名字调,
  // 云代理回 400「未知场景」,那是运行时才撞得到的。
  // 这条测试的标题写的是「**每一个**场景都对得上」,单向查就是「声明比实现宽」。
  //
  // ⚠️ 不是所有 Python 场景都该在 worker 里:旧仓那些管线在 Mac 上直连模型,
  // 从不经云代理。**那种不对称是合法的,但必须一条条报出名字来** ——
  // 白名单为空地放行等于这道对撞不存在。新增一个只在 Python 的场景时这里会红:
  // 那时要回答的是「它会不会经云代理」,而不是顺手把名字加进白名单。
  const MAC_ONLY = new Set([
    "narrate", "reflect", "brief", "audio_perceive", "dialog",   // 旧仓叙事/感知管线
    "answer", "judge", "label", "merge", "distill",              // 判卷台与标注台
    "perceive_select", "bench",                                  // 选片与基准
  ]);
  const pyScenes = [...(py.match(/SCENE_ROUTES = \{([\s\S]*?)\n\}/)?.[1] ?? "")
    .matchAll(/^\s*"(\w+)":\s*\{/gm)].map(m => m[1]);
  assert.ok(pyScenes.length >= 2, `Python 侧只抠出 ${pyScenes.length} 个场景,正则该修了`);
  for (const scene of pyScenes) {
    if (MAC_ONLY.has(scene)) continue;
    assert.ok(scenes.includes(scene),
      `model_router.py 有 ${scene} 而 worker 没有 —— 谁按它调云代理都会吃 400,` +
      `而这是运行时才撞得到的。要么两边一起加,要么它确实只在 Mac 上直连、` +
      `那就把它写进这条测试的 MAC_ONLY 并说清为什么。`);
  }

  for (const scene of scenes) {
    const py_ = py.match(new RegExp(`"${scene}":\\s*\\{"provider":\\s*"([\\w-]+)"`));
    assert.ok(py_, `model_router.py 里没有 ${scene} 场景 —— ` +
      `只在 worker 加场景的话,判卷台量的就不是生产在跑的模型`);
    const provider = py_[1];
    const model = py.match(
      new RegExp(`"${provider}":\\s*\\{[^}]*_pmodel\\("${provider}",\\s*"([\\w.-]+)"\\)`));
    assert.ok(model, `model_router.py 里找不到 provider ${provider} 的默认模型`);

    const calls = stubUpstream(() => llmOK('{"one_liner":"x"}'));
    const r = await worker.fetch(post("/extract", { scene, messages: MESSAGES }),
                                 envWith(), ctx);
    assert.strictEqual(r.status, 200,
      `场景 ${scene} 没跑通(${r.status})—— 多半是它的服务商钥匙没进测试 env`);
    assert.strictEqual(calls[0].body.model, model[1],
      `场景 ${scene}:worker 用 ${calls[0].body.model},Python 侧路由到 ${model[1]} —— 两处漂了`);
  }
});

// ── 临时闸(2026-08-20 用户拍板:抽取太贵,先停) ──────────────


// ⚠️ **价表也要对撞,而且它比路由更容易被忽略。**
//
// 路由漂了会立刻表现成「模型不对」;价表漂了**什么都不表现** ——
// 请求照发、结果照回,只有账本上的数字悄悄变成假的。
// 而 CLAUDE.md 那条「引用任何成本结论前先看它的日期」防的正是这个:
// 拿一份错的账去决定「值不值得降级」,会把优化做到错的地方。
//
// 这张表在两处各存一份是有理由的(Worker 跑在 Cloudflare 上,读不到 Python),
// 所以只能对撞,不能合并。
test("价表逐条与 shared/model_router.py 对得上", async () => {
  const { readFileSync } = await import("node:fs");
  const py = readFileSync(new URL("../shared/model_router.py", import.meta.url), "utf8");

  const block = py.match(/_PRICES = \{([\s\S]*?)\n\}/);
  assert.ok(block, "model_router.py 里找不到 _PRICES —— 表结构变了,这个测试要跟着改");
  const pyPrices = {};
  for (const m of block[1].matchAll(/"([\w.-]+)":\s*\(([\d.]+),\s*([\d.]+),\s*([\d.]+)\)/g)) {
    pyPrices[m[1]] = [Number(m[2]), Number(m[3]), Number(m[4])];
  }
  assert.ok(Object.keys(pyPrices).length >= 4,
    `只抠出 ${Object.keys(pyPrices).length} 个模型,正则该修了`);

  // 🔴 **双向比**:worker 多一个模型 ⇒ 它的账没有 Python 侧的对照;
  // Python 多一个 ⇒ 将来把那个模型接进 worker 时会静默按 null 计价。
  assert.deepStrictEqual(Object.keys(PRICES).sort(), Object.keys(pyPrices).sort(),
    "两边的模型清单不一样 —— 账会有一侧算不出来");
  for (const [model, price] of Object.entries(PRICES)) {
    assert.deepStrictEqual(price, pyPrices[model],
      `${model} 的单价两处不一样:worker ${price} / python ${pyPrices[model]} —— ` +
      `账本上的数字有一份是假的,而它不会报错`);
  }

  // ASR 按时长计费,单价单列 —— 它是成本大头(转写 ¥0.73/天),漂了最贵。
  const cny = py.match(/ASR_CNY_PER_HOUR = float\(os\.environ\.get\("[^"]+",\s*"([\d.]+)"\)\)/);
  assert.ok(cny, "找不到 Python 侧的 ASR_CNY_PER_HOUR");
  assert.strictEqual(ASR_CNY_PER_HOUR, Number(cny[1]),
    `ASR 单价两处不一样:worker ${ASR_CNY_PER_HOUR} / python ${cny[1]}`);
});

test("max_tokens 是 20000,不是 SCENE_ROUTES 的 4000", async () => {
  // extract.py 实测:8000 会被 thinking 吃光、返回空正文。4000 拿到的是空正文,
  // 而空正文在下游长得和「这场没内容」一模一样 —— 花了钱还看不出错。
  const calls = stubUpstream(() => llmOK('{"one_liner":"x"}'));
  await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }),
                     envWith(), ctx);
  assert.strictEqual(calls[0].body.max_tokens, 20000);
});

// ── 门禁与密钥 ──────────────────────────────────────────────

test("没带门禁令牌 → 401,而且一次上游都不打", async () => {
  const calls = stubUpstream(() => llmOK("x"));
  const r = await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }, {}),
                               envWith(), ctx);
  assert.strictEqual(r.status, 401);
  assert.strictEqual(calls.length, 0, "没过门禁却打了上游 = 谁都能烧你的额度");
});

test("缺 DEEPSEEK_API_KEY 时报的是它,不是 STEPFUN_API_KEY", async () => {
  // 以前这里一刀切挡 STEPFUN_API_KEY,抽取缺钥匙时报的是转写那把 ——
  // 排查的人会去看转写的配置,而问题根本不在那儿。
  const r = await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }),
                               envWith({ DEEPSEEK_API_KEY: undefined }), ctx);
  assert.strictEqual(r.status, 500);
  const body = await r.json();
  assert.match(body.error, /DEEPSEEK_API_KEY/);
  assert.doesNotMatch(body.error, /STEPFUN/);
});

test("缺 STEPFUN_API_KEY 不该挡住抽取 —— 两条腿互不牵连", async () => {
  stubUpstream(() => llmOK('{"one_liner":"x"}'));
  const r = await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }),
                               envWith({ STEPFUN_API_KEY: undefined }), ctx);
  assert.strictEqual(r.status, 200);
});

// ── 场景 ────────────────────────────────────────────────────

test("不认识的场景直接拒,不回落到默认模型", async () => {
  // 回落的后果是一笔记不进任何场景的钱,而拆场景的全部意义就是
  // 「降本时知道该降哪一笔」(2026-08-06 拆账那条)。
  const calls = stubUpstream(() => llmOK("x"));
  const r = await worker.fetch(post("/extract", { scene: "随便编的", messages: MESSAGES }),
                               envWith(), ctx);
  assert.strictEqual(r.status, 400);
  assert.strictEqual(calls.length, 0, "未知场景却打了上游 = 花了一笔无主的钱");
});

test("缺 messages → 400,不打上游", async () => {
  const calls = stubUpstream(() => llmOK("x"));
  const r = await worker.fetch(post("/extract", { scene: "ask" }), envWith(), ctx);
  assert.strictEqual(r.status, 400);
  assert.strictEqual(calls.length, 0);
});

// ── 空正文:必须翻成失败 ─────────────────────────────────────

test("空正文翻成 502,不当成「这场没抽到内容」", async () => {
  stubUpstream(() => new Response(JSON.stringify({
    choices: [{ message: { content: "" }, finish_reason: "length" }],
    usage: { prompt_tokens: 1000, completion_tokens: 20000 },
  }), { status: 200 }));
  const r = await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }),
                               envWith(), ctx);
  assert.strictEqual(r.status, 502, "空正文回 200 的话,下游会冻结一份空纪要");
  const body = await r.json();
  assert.strictEqual(body.finish_reason, "length", "要把 finish_reason 带出来,不然查不出是被截断还是真没内容");
});

test("只有空白的正文也算空", async () => {
  stubUpstream(() => llmOK("   \n  "));
  const r = await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }),
                               envWith(), ctx);
  assert.strictEqual(r.status, 502);
});

test("空正文那一笔**照样记账** —— 钱已经花了", async () => {
  const env = envWith();
  stubUpstream(() => new Response(JSON.stringify({
    choices: [{ message: { content: "" }, finish_reason: "length" }],
    usage: { prompt_tokens: 1000, completion_tokens: 20000 },
  }), { status: 200 }));
  await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }), env, ctx);
  assert.strictEqual(env.AUDIO.objects.size, 1,
    "失败但已扣费的调用不记账,账面上就少了一笔真花掉的钱");
});

// ── 上游失败 ────────────────────────────────────────────────

test("上游非 2xx:正文必须带出去", async () => {
  // 旧仓踩过:只报「502 Bad Gateway」,而真因(api key 是 undefined)
  // 就写在正文里,被扔了。
  stubUpstream(() => new Response('{"error":{"message":"insufficient balance"}}',
                                  { status: 402 }));
  const r = await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }),
                               envWith(), ctx);
  assert.strictEqual(r.status, 502);
  const body = await r.json();
  assert.strictEqual(body.status, 402);
  assert.match(body.body, /insufficient balance/);
});

test("上游失败**不记账** —— 非 2xx 意味着没扣费", async () => {
  const env = envWith();
  stubUpstream(() => new Response("boom", { status: 500 }));
  await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }), env, ctx);
  assert.strictEqual(env.AUDIO.objects.size, 0, "没花的钱记进账会让成本虚高");
});

// ── 成功路径与记账 ──────────────────────────────────────────

test("正常返回 content,并把账落进 R2", async () => {
  const env = envWith();
  stubUpstream(() => llmOK('{"one_liner":"把首页定下来"}'));
  const r = await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }),
                               envWith(), ctx);
  assert.strictEqual(r.status, 200);
  const body = await r.json();
  assert.match(body.content, /把首页定下来/);
  assert.strictEqual(body.accounting.persisted, true);
  assert.match(body.accounting.key, /^usage\/\d{4}-\d{2}-\d{2}\//);
  assert.ok(typeof body.elapsed_ms === "number", "没有耗时就没法判断要不要改流式");

  // 换个 env 再跑一次,断言对象真的进了桶(上面那次用的是另一个桶)
  await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }), env, ctx);
  assert.strictEqual(env.AUDIO.objects.size, 1);
});

test("缓存命中不按未命中价收两遍", async () => {
  // DeepSeek 的 prompt_tokens **含**缓存命中,而价表里 input 不含。
  // 直接塞会把命中那部分按「未命中价 + 命中价」收两遍 —— 系统性高估成本,
  // 而高估会让人去优化根本不贵的地方。
  const env = envWith();
  const calls = stubUpstream(() => llmOK("{}", { prompt_tokens: 1000,
                                                 prompt_cache_hit_tokens: 800,
                                                 completion_tokens: 100 }));
  await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }), env, ctx);
  const rec = JSON.parse([...env.AUDIO.objects.values()][0]);
  assert.strictEqual(rec.input, 200, "input 应是未命中的那 200,不是 1000");
  assert.strictEqual(rec.cache_read, 800);

  // 期望值**按当前路由的模型现算**,不写死 —— 写死的话换一次模型就要改一次
  // 测试,而改测试去迁就实现正是最容易把真错误改绿的动作。
  //
  // ⚠️ **不自己重抄定价公式,直接调 `priceUSD`**(2026-08-18):
  // 上一版把「入 × pin + 缓存 × pcache + 出 × pout」又写了一遍,而峰谷价一上,
  // 那份抄件就和实现分了叉 —— 一件事两处各存一份的老形状。
  // 时刻取**记录自己带的那个**,不取「现在」:跨 UTC 整点时两者会算出不同的档。
  const model = calls[0].body.model;
  const at = new Date(rec.t);
  // 实现把成本圆到 1e-6,期望值要同口径圆一次
  const round6 = (x) => Math.round(x * 1e6) / 1e6;
  const want = round6(priceUSD(model, { input_tokens: 200, cache_read_input_tokens: 800,
                                        output_tokens: 100 }, at));
  assert.strictEqual(rec.cost_usd, want);
  // 双收的话会把那 800 也按未命中收,必然更贵 —— 这个用例要挑得出两者的差
  const doubleCharged = round6(priceUSD(model, { input_tokens: 1000,
                                                 cache_read_input_tokens: 800,
                                                 output_tokens: 100 }, at));
  assert.ok(want < doubleCharged, "这个用例挑不出双收 —— 参数要让两种算法差得开");
});

test("账上记的模型 = 真正调用的模型", async () => {
  // 写死模型名的话,换路由时测试会红在一个「不是缺陷」的地方,
  // 而真正该防的是**记账记错模型** —— 那会让降本时算错该降哪一笔。
  const env = envWith();
  const calls = stubUpstream(() => llmOK("{}"));
  await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }), env, ctx);
  const rec = JSON.parse([...env.AUDIO.objects.values()][0]);
  assert.strictEqual(rec.scene, "ask");   // 抽取被临时闸停了,拿一个还活着的场景验记账
  assert.strictEqual(rec.model, calls[0].body.model);
  assert.ok(rec.cost_usd > 0, "价表里没有这个模型 → cost_usd 是 null,账上会有个窟窿");
});

test("R2 写失败不吞:persisted=false 且把记录原样带出来", async () => {
  const env = envWith({ AUDIO: { async put() { throw new Error("R2 挂了"); } } });
  stubUpstream(() => llmOK("{}"));
  const r = await worker.fetch(post("/extract", { scene: "ask", messages: MESSAGES }),
                               env, ctx);
  assert.strictEqual(r.status, 200, "账写不进去不该让已经花掉的钱作废");
  const body = await r.json();
  assert.strictEqual(body.accounting.persisted, false);
  assert.strictEqual(body.accounting.record.scene, "ask",
    "记录要带出来,让手机有第二次机会记下");
});

// ── /health ────────────────────────────────────────────────

// ── 令牌对不对 ──────────────────────────────────────────────

test("带令牌探活时报 tokenOK —— 不带就不报,不是报 true", async () => {
  // ⚠️ `/health` 本身**不要门禁**(配错了还得能诊断)。于是不带令牌的探活
  // 只证明「worker 那边存了个令牌」,**证明不了调用方填的这个对** ——
  // 贴错的话一路绿到第一次真上传才 401,而那时用户早就以为配好了。
  const noToken = await worker.fetch(new Request("https://proxy.test/health"), envWith(), ctx);
  const a = await noToken.json();
  assert.strictEqual("tokenOK" in a, false,
    "没带令牌却报了 tokenOK —— 缺省成 true 的话等于没验,缺省成 false 会误报配错了");

  const good = await worker.fetch(
    new Request("https://proxy.test/health", { headers: { "X-Growth-Token": TOKEN } }),
    envWith(), ctx);
  assert.strictEqual((await good.json()).tokenOK, true);

  const bad = await worker.fetch(
    // 用 ASCII 的错令牌:HTTP 头值只能是 ByteString,中文塞进去在构造 Request
    // 时就炸了 —— 那测的是 Request 的约束,不是这条路由的判断。
    // (非 ASCII 令牌本身是个真场景,挡在手机侧:见 SettingsView 的粘贴清洗。)
    new Request("https://proxy.test/health", { headers: { "X-Growth-Token": "wrong-token" } }),
    envWith(), ctx);
  assert.strictEqual((await bad.json()).tokenOK, false);
});

test("/health 任何情况下都不回令牌本身", async () => {
  // 这个地址公网可达。报「对不对」是一个 bool,报「是什么」是白送。
  const r = await worker.fetch(
    new Request("https://proxy.test/health", { headers: { "X-Growth-Token": TOKEN } }),
    envWith(), ctx);
  assert.ok(!JSON.stringify(await r.json()).includes(TOKEN), "/health 把令牌原样回出去了");
});

test("/health 逐项报,并且报了 LLM 那把钥匙", async () => {
  const r = await worker.fetch(new Request("https://proxy.test/health"), envWith(), ctx);
  const h = await r.json();
  assert.strictEqual(h.hasKey, true);
  assert.strictEqual(h.hasLLMKey, true);
  assert.strictEqual(h.hasClientToken, true);
  // 永远不报值,只报有没有 —— 这个地址公网可达
  assert.ok(!JSON.stringify(h).includes("sk-"), "/health 泄露了密钥内容");
});

// ── 跑 ─────────────────────────────────────────────────────

let failed = 0;
const realFetch = globalThis.fetch;
for (const [name, fn] of tests) {
  try { await fn(); console.log("PASS", name); }
  catch (e) { failed++; console.log("FAIL", name, "\n   ", e.message); }
  finally { globalThis.fetch = realFetch; }
}
console.log(failed ? `\n${failed} failed / ${tests.length}` : `\nall passed (${tests.length})`);
process.exit(failed ? 1 : 0);

test("底库快照的键过得了 /upload 的键校验", async () => {
  // 🔴 2026-08-24 实测:`KEY_RE` 原来是 `[\w./-]`,而快照键带 ISO 时间戳的
  // `+08-00` ⇒ 判 400 ⇒ 快照永远推不上去 ⇒ Mac 判不了任何一场。
  // **而这只在真机上撞得到** —— 手机侧不校验键,云端才校验。
  // 键的形状由 `ios/.../RegistrySnapshot.swift::RegistrySnapshotIO.key` 定:
  // 前缀 + ISO 时间戳(冒号换成 `-`)+ `.json`。改那边要连这条一起改。
  const { readFileSync } = await import("node:fs");
  const src = readFileSync(new URL("./src/index.js", import.meta.url), "utf8");
  const m = src.match(/const KEY_RE = (\/.+\/);/);
  assert.ok(m, "找不到 KEY_RE —— 这条对撞的一端没了");
  const re = new RegExp(m[1].slice(1, -1));
  for (const tz of ["+08-00", "-05-00", "Z"]) {
    const key = `snapshots/voiceprints/2026-08-24T17-05-00${tz}.json`;
    assert.ok(re.test(key), `快照键 ${key} 过不了 KEY_RE —— 快照推不上去,` +
      `而表现是「Mac 一直判不了」,离「键被拒了」隔着好几跳`);
  }
});


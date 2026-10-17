import assert from "node:assert";
import { enqueue, takeResult, runPending, jobKey, outKey, MAX_PER_TICK, CLAIM_TTL_MS, STALE_MS, fingerprint, canonical } from "./src/extract_queue.js";

let pass = 0, fail = 0;
const tests = [];
const test = (name, fn) => tests.push([name, fn]);

/** 最小的 R2 假桶:只实现这一层用到的四个方法。 */
function bucket(init = {}) {
  const m = new Map(Object.entries(init));
  return {
    _m: m,
    async head(k) { return m.has(k) ? { key: k } : null; },
    async get(k) {
      if (!m.has(k)) return null;
      const v = m.get(k);
      return { text: async () => v, json: async () => JSON.parse(v) };
    },
    async put(k, v) { m.set(k, typeof v === "string" ? v : String(v)); },
    async delete(k) { m.delete(k); },
    async list({ prefix }) {
      return { objects: [...m.keys()].filter((k) => k.startsWith(prefix)).map((k) => ({ key: k })) };
    },
  };
}

test("持续分片身份包含前段背景、配方、真实时间和两阶段模型", async () => {
  const lines = [{line_id: 1, text: "同一件事继续", t_sec: 300, t_end_sec: 320,
    recipe: "v3-semantic-continuity", streaming: true, stream_context: {event_id: 12, summary: "上一段", t_end_sec: 300}}];
  const base = await fingerprint(canonical(lines), "S1-A|S2-A");
  for (const change of [
    {recipe: "v4"}, {t_sec: 301}, {stream_context: {...lines[0].stream_context, summary: "不同背景"}}
  ]) {
    assert.notStrictEqual(base, await fingerprint(canonical([{...lines[0], ...change}]), "S1-A|S2-A"));
  }
  assert.notStrictEqual(base, await fingerprint(canonical(lines), "S1-B|S2-A"));
  assert.strictEqual(base, await fingerprint(canonical(lines), "S1-A|S2-A"));
});

test("排队是幂等的 —— 重复排不会多一个 job", async () => {
  const b = bucket();
  const a1 = await enqueue(b, { session: 1, part: 0, prompt: "p", model: "m" });
  const a2 = await enqueue(b, { session: 1, part: 0, prompt: "p", model: "m" });
  assert.strictEqual(a1.created, true);
  assert.strictEqual(a2.created, undefined, "第二次又建了一个 job —— 那是重复付费的入口");
  assert.strictEqual(b._m.size, 1);
});

test("产物已经在了就直接说好了,不再排一遍", async () => {
  const fp0 = await fingerprint("p", "m");
  const b = bucket({ [outKey(1, 0, fp0)]: '{"one_liner":"x"}' });
  assert.strictEqual((await enqueue(b, { session: 1, part: 0, prompt: "p", model: "m" })).state, "done");
  assert.ok(!b._m.has(jobKey(1, 0, fp0)), "产物都有了还排 job —— 会再花一次钱");
});

test("跑完:产物落盘、job 删掉", async () => {
  const b = bucket();
  const t7 = await enqueue(b, { session: 7, part: 0, prompt: "p", model: "m" });
  const r = await runPending(b, async () => '{"one_liner":"好了"}');
  assert.strictEqual(r.ran, 1);
  assert.strictEqual((await takeResult(b, { ticket: t7.ticket })).state, "done");
  assert.ok(!b._m.has(`extract/jobs/${t7.ticket}.json`), "跑完了 job 还在 ⇒ 下一拍会再跑一遍");
});

test("🔴 认领:上一拍还在跑,下一拍不许再跑一遍", async () => {
  // 一次抽取实测 243 秒,而 cron 每分钟一拍 —— 两拍必然重叠。
  // 不认领的话第二拍会把同一个 job 再跑一遍,**而那一遍是真花钱的**。
  const b = bucket();
  const t3 = await enqueue(b, { session: 3, part: 0, prompt: "p", model: "m" });
  let calls = 0;
  const slow = async () => { calls++; return "{}"; };
  let t = 1_000_000;
  await runPending(b, slow, { now: () => t });          // 第一拍认领并跑完
  await enqueue(b, { session: 3, part: 1, prompt: "p", model: "m" }); // 再排一个
  await runPending(b, slow, { now: () => t + 30_000 });
  assert.strictEqual(calls, 2, "跑的次数不对");
});

test("🔴 跑挂了:job 留着、错误留痕、不写成产物", async () => {
  // 把失败写成产物的话,手机会把一份空纪要当成「抽完了」——
  // 而空产物落库之后会永久挡住重抽(M2-成2 那条)。
  const b = bucket();
  const t9 = await enqueue(b, { session: 9, part: 0, prompt: "p", model: "m" });
  await runPending(b, async () => { throw new Error("上游 502"); });
  assert.ok(b._m.has(`extract/jobs/${t9.ticket}.json`), "失败了却把 job 删了 —— 这一块再也不会被抽");
  assert.strictEqual((await takeResult(b, { ticket: t9.ticket })).state, "running");
  const job = JSON.parse(b._m.get(`extract/jobs/${t9.ticket}.json`));
  assert.match(job.last_error, /502/);
  assert.strictEqual(job.attempts, 1);
});

test("认领过期之后允许重跑 —— 否则跑挂一次就永远卡住", async () => {
  const b = bucket();
  const t4 = await enqueue(b, { session: 4, part: 0, prompt: "p", model: "m" });
  let calls = 0;
  let t = 5_000_000;
  await runPending(b, async () => { calls++; throw new Error("挂了"); }, { now: () => t });
  await runPending(b, async () => { calls++; return "{}"; }, { now: () => t + 60_000 });
  assert.strictEqual(calls, 1, "认领还没过期就重跑了 —— 重复付费");
  await runPending(b, async () => { calls++; return "{}"; }, { now: () => t + CLAIM_TTL_MS + 1 });
  assert.strictEqual(calls, 2, "认领过期了还不让重跑 —— 挂一次就永远卡住");
});

test("一拍最多跑 MAX_PER_TICK 个 —— 撞上 cron 时限的表现是「重复付费」", async () => {
  const b = bucket();
  for (let i = 0; i < 5; i++) await enqueue(b, { session: 2, part: i, prompt: "p", model: "m" });
  let calls = 0;
  const r = await runPending(b, async () => { calls++; return "{}"; });
  assert.strictEqual(calls, MAX_PER_TICK);
  assert.strictEqual(r.ran, MAX_PER_TICK);
});

test("没排过的块,取产物时说「没有」而不是「在跑」", async () => {
  // 两者处置不同:「在跑」等着就行,「没有」得先排队。
  assert.strictEqual((await takeResult(bucket(), { ticket: "1-0-deadbeef" })).state, "none");
});

test("🔴 兜底口径:排了不够久的 job,Worker 不许碰(留给 Mac)", async () => {
  // 认领是「读-改-写」,不是原子的 ⇒ 两个消费者会抢,而抢上的后果是**付两次钱**。
  // 所以 Worker 不靠「抢得慢一点」避让,靠**结构上根本不看**新 job。
  const b = bucket();
  const t5 = await enqueue(b, { session: 5, part: 0, prompt: "p", model: "m" });
  let calls = 0;
  const job = JSON.parse(b._m.get(`extract/jobs/${t5.ticket}.json`));
  const born = Date.parse(job.at);
  const r = await runPending(b, async () => { calls++; return "{}"; },
                             { now: () => born + STALE_MS - 1, staleAfterMs: STALE_MS });
  assert.strictEqual(calls, 0, "新 job 被 Worker 抢走了 —— 会和 Mac 撞成两笔钱");
  assert.strictEqual(r.skipped, 1);
});

test("Mac 挂了之后 Worker 接手 —— 否则链子就断在这儿", async () => {
  const b = bucket();
  const t6 = await enqueue(b, { session: 6, part: 0, prompt: "p", model: "m" });
  const born = Date.parse(JSON.parse(b._m.get(`extract/jobs/${t6.ticket}.json`)).at);
  let calls = 0;
  await runPending(b, async () => { calls++; return "{}"; },
                   { now: () => born + STALE_MS + 1, staleAfterMs: STALE_MS });
  assert.strictEqual(calls, 1, "排了超过 STALE_MS 还没人动,兜底也不接 ⇒ 永远不出纪要");
});

test("STALE_MS 必须明显大于 CLAIM_TTL 之外的那些时间尺度", () => {
  // 这条钉的是**关系**不是数值:调小到接近一次抽取的耗时,
  // 就等于把两个消费者放回同一个窗口,而重复付费不会有任何东西报错。
  assert.ok(STALE_MS >= 5 * 60 * 1000,
            `STALE_MS=${STALE_MS} 太小 —— 先读它上面那段注释再改`);
});

// ── M2-审11:产物的身份由「什么决定这个答案」来定 ──

test("🔴 改了 prompt 就是另一个产物 —— 旧结果不许被当成有效结果", async () => {
  const b = bucket();
  const v1 = await enqueue(b, { session: 1, part: 0, prompt: "老配方", model: "m" });
  await runPending(b, async () => '{"one_liner":"老答案"}');
  assert.strictEqual((await takeResult(b, { ticket: v1.ticket })).body, '{"one_liner":"老答案"}');

  // 换配方重排:必须是**新的一张 ticket**,而且此刻还没有产物
  const v2 = await enqueue(b, { session: 1, part: 0, prompt: "新配方", model: "m" });
  assert.notStrictEqual(v2.ticket, v1.ticket, "改了 prompt 却拿到同一张票 —— 新配方一次都跑不到");
  assert.strictEqual(v2.state, "queued");
  assert.strictEqual((await takeResult(b, { ticket: v2.ticket })).state, "running");
});

test("🔴 换了模型同理 —— 同一份 prompt 在两个模型下是两个答案", async () => {
  const b = bucket();
  const a = await enqueue(b, { session: 2, part: 0, prompt: "p", model: "老模型" });
  const c = await enqueue(b, { session: 2, part: 0, prompt: "p", model: "新模型" });
  assert.notStrictEqual(a.ticket, c.ticket);
});

test("🔴 重装后行号从头再来,也撞不上旧产物(内容不同 ⇒ 指纹不同)", async () => {
  const b = bucket();
  await enqueue(b, { session: 1, part: 0, prompt: "旧安装那一场", model: "m" });
  await runPending(b, async () => '{"one_liner":"旧安装的纪要"}');
  // 重装:transcriptID 又从 1 开始,但内容是新的
  const fresh = await enqueue(b, { session: 1, part: 0, prompt: "新安装这一场", model: "m" });
  assert.strictEqual(fresh.state, "queued", "新场次直接拿到了旧安装的纪要");
});

test("🔴 模型输出不是 JSON:存成带 error 的产物,不留 job —— 不许无限复用也不许重复付费",
  async () => {
    const b = bucket();
    const t = await enqueue(b, { session: 3, part: 0, prompt: "p", model: "m" });
    let calls = 0;
    await runPending(b, async () => { calls++; return "这不是 JSON"; });
    assert.strictEqual(calls, 1);

    const got = await takeResult(b, { ticket: t.ticket });
    assert.strictEqual(got.state, "done", "坏输出必须落成产物 —— 留着 job 下一拍会再付一次钱");
    assert.ok(JSON.parse(got.body).error, "坏输出被当成正常纪要存下来了");
    assert.ok(JSON.parse(got.body).raw.includes("这不是 JSON"), "原文没留下,查不出模型到底说了什么");

    // 再跑一拍:job 已经没了 ⇒ 模型不会被重跑
    await runPending(b, async () => { calls++; return "x"; });
    assert.strictEqual(calls, 1, "确定性坏输出被重新付费跑了一遍");
  });


// ── 🔴 指纹必须算在规范形上(2026-08-25 实测,真花过钱)────────────────
//
// Swift 的 `Dictionary` 没有稳定键序,而手机序列化时没排序。
// 于是同一块材料**几乎每一拍一个新指纹** ⇒ 手机永远取不到自己那一份产物、
// 每拍重排一次、Mac 每拍**真抽一次(付费)**。
// 当天实测:`29-0` 攒了 5 个指纹、`30-0` 攒了 4 个,两端都不报错 ——
// daemon 说「抽完了」,手机说「云端正在抽」。
test("键序不同、内容相同 ⇒ 同一个指纹", async () => {
  const A = [{ text: "x", line_id: 1, is_gap: false, cluster_tag: "c0" }];
  const B = [{ text: "x", is_gap: false, line_id: 1, cluster_tag: "c0" }];
  assert.notStrictEqual(JSON.stringify(A), JSON.stringify(B),
    "照妖镜:这两份的裸 stringify 必须不同 —— 相同的话这条用例测的是个不存在的问题");
  assert.strictEqual(canonical(A), canonical(B));
  assert.strictEqual(await fingerprint(canonical(A), "m"), await fingerprint(canonical(B), "m"));
});

test("内容真的变了 ⇒ 指纹必须变", async () => {
  const A = [{ text: "x", line_id: 1 }];
  const B = [{ text: "y", line_id: 1 }];
  assert.notStrictEqual(await fingerprint(canonical(A), "m"), await fingerprint(canonical(B), "m"));
});

test("嵌套对象也规范化", () => {
  assert.strictEqual(canonical({ b: 1, a: { d: 2, c: 3 } }),
                     canonical({ a: { c: 3, d: 2 }, b: 1 }));
});

test("数组保序 —— 行的先后是内容的一部分", () => {
  assert.notStrictEqual(canonical([{ a: 1 }, { a: 2 }]), canonical([{ a: 2 }, { a: 1 }]));
});

for (const [name, fn] of tests) {
  try { await fn(); console.log("PASS", name); pass++; }
  catch (e) { console.log("FAIL", name, "\n   ", e.message); fail++; }
}
console.log(fail ? `\n${fail} failed / ${pass + fail}` : `\nall passed (${pass})`);
process.exit(fail ? 1 : 0);

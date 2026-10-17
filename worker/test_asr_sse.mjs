// StepAudio SSE 客户端自测。跑:node worker/test_asr_sse.mjs
//
// 打的是「解析对不对」,不是「能不能连上」——连真上游那一跑在验收里单独做。
// 最要紧的是跨 chunk 切割:Workers 的 ReadableStream 在**任意字节处**切,
// 按 chunk 直接 split 会把一个事件劈成两半,而劈掉的那半是静默丢失的。

import assert from "node:assert";
import {
  ASR_MODEL, buildPayload, collected, collectEvent, DONE_TYPE, extractSegment,
  newCollector, newSSEState, parseSSEChunk,
} from "./src/asr_sse.js";

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

const drain = (chunks) => {
  const state = newSSEState();
  const out = [];
  for (const c of chunks) out.push(...parseSSEChunk(state, c));
  return out;
};

const delta = (text, s, e) =>
  `data: ${JSON.stringify({ type: "transcript.text.delta", delta: text, start_time: s, end_time: e })}\n\n`;
const doneEvent = (text) =>
  `data: ${JSON.stringify({ type: DONE_TYPE, text })}\n\n`;

/** 走 index.js 用的那一份路由,**不在测试里另抄一遍** ——
 * 抄一遍的话打的是副本:实测把 extractSegment 的 type 过滤删掉,测试还是绿的。 */
const collect = (chunks) => {
  const c = newCollector();
  for (const ev of drain(chunks)) collectEvent(c, ev);
  return collected(c);
};

// ── 请求形状 ────────────────────────────────────────────────

test("payload 形状照 mac/asr_stepfun.py 的 _build_payload", () => {
  const p = buildPayload("QUJD", { format: "mp3" });
  assert.strictEqual(p.audio.data, "QUJD");
  assert.strictEqual(p.audio.input.transcription.model, ASR_MODEL);
  assert.deepStrictEqual(p.audio.input.format, { type: "mp3" });
  // 参数在 audio.input.transcription 里,不在顶层 —— M0-9 那版就错在这
  assert.ok(p.audio.input.transcription.enable_timestamp);
  assert.strictEqual(p.model, undefined, "model 不该出现在顶层");
});

test("pcm 要带 rate/bits/channel,mp3 不带", () => {
  assert.deepStrictEqual(buildPayload("x", { format: "pcm" }).audio.input.format,
    { type: "pcm", codec: "pcm_s16le", rate: 16000, bits: 16, channel: 1 });
});

test("没验过的 format 直接抛,不猜一个上去", () => {
  // 手机录的是 m4a,而 Worker 里没有 ffmpeg。传上去要么报错、要么静默给空转写,
  // 后者会被下游当成「这段没人说话」—— 那是最贵的一种。
  assert.throws(() => buildPayload("x", { format: "m4a" }), /不在验过的闭集/);
});

// ── SSE 解析 ────────────────────────────────────────────────

test("整块进来时逐个事件出来", () => {
  const events = drain([delta("你好", 0, 500) + delta("世界", 500, 1000)]);
  assert.strictEqual(events.length, 2);
  assert.strictEqual(events[1].delta, "世界");
});

test("一个事件被切成两个 chunk 也不丢", () => {
  const whole = delta("承诺下周三之前交", 1000, 3000);
  for (let cut = 1; cut < whole.length; cut++) {
    const events = drain([whole.slice(0, cut), whole.slice(cut)]);
    assert.strictEqual(events.length, 1, `在第 ${cut} 字节切开时丢了事件`);
    assert.strictEqual(events[0].delta, "承诺下周三之前交");
  }
});

test("心跳与 [DONE] 不当成事件", () => {
  const events = drain([": keep-alive\n\n", delta("嗯", 0, 100), "data: [DONE]\n\n"]);
  assert.strictEqual(events.length, 1);
});

test("解不开的 data 只丢那一个事件,不影响后面的", () => {
  const events = drain(["data: {半截\n\n", delta("后面这条要出来", 0, 100)]);
  assert.strictEqual(events.length, 1);
  assert.strictEqual(events[0].delta, "后面这条要出来");
});

test("CRLF 行尾照常解析", () => {
  const events = drain([delta("你好", 0, 1).replace(/\n/g, "\r\n")]);
  assert.strictEqual(events.length, 1);
});

// ── 拼接 ────────────────────────────────────────────────────

test("done 带全文时不能再拼一遍 delta(实测 5 秒音频就是这样)", () => {
  // 2026-08-10 真跑 StepFun 抓到的:5 秒音频出来 6 个字级 delta **外加**一条
  // 带全文、无时间戳的 done。不按 type 分流的话拼出来是「他就是有花香。他就是有花香。」
  // —— HTTP 200、测试全绿、文本是错的。
  // 刻意让 done 的全文与拼起来的 delta **不相等**(done 带句号,delta 不带)——
  // 相等的话「用 done」和「拼 delta」两条分支产出一样,这条断言就区分不开,
  // 等于白写。真实情况也确实不等:done 那份过了 ITN 归一。
  const r = collect([delta("他", 560, 640) + delta("就是有花香", 2320, 3200)
    + doneEvent("他就是有花香。")]);
  assert.strictEqual(r.text, "他就是有花香。", "done 的全文优先,且不能再拼一遍");
  assert.strictEqual(r.segments.length, 2, "带全文的 done 不该被算成一段");
});

test("done 不带全文时(长音频)靠拼 delta 兜底", () => {
  // _post_sse 的注释写死:长流的 done 不回聚合文本。只认 done 的话会拿到空文本,
  // 而空文本不报错,会被下游当成「这段没人说话」。
  const r = collect([delta("我们", 0, 400) + delta("下周三", 400, 900) + doneEvent("")]);
  assert.strictEqual(r.text, "我们下周三");
  assert.strictEqual(r.segments.length, 2);
});

test("时间戳字段名做兜底读取", () => {
  assert.deepStrictEqual(extractSegment({ text: "喂", start: 10, end: 20 }),
    { text: "喂", start_ms: 10, end_ms: 20 });
  assert.deepStrictEqual(extractSegment({ delta: "喂", start_time: 10, end_time: 20 }),
    { text: "喂", start_ms: 10, end_ms: 20 });
});

test("extractSegment 被直接喂 done 事件时也不成段", () => {
  // 路由在 collectEvent 里,这道过滤对它是冗余的 —— 但 extractSegment 是导出函数,
  // 别的调用方可能直接用它。没有这条测试的话,这道防护就是「看着有、从没验过」:
  // 实测把它删掉,其余 11 条全绿。
  assert.strictEqual(extractSegment({ type: DONE_TYPE, text: "他就是有花香。" }), null);
});

test("空文本的事件不成段", () => {
  assert.strictEqual(extractSegment({ delta: "", start_time: 0 }), null);
});

let failed = 0;
for (const [name, fn] of tests) {
  try { fn(); console.log(`PASS ${name}`); }
  catch (e) { failed++; console.log(`FAIL ${name}\n     ${e.message}`); }
}
console.log(failed ? `\n${failed} 条失败` : `\nall passed (${tests.length})`);
process.exit(failed ? 1 : 0);

// 记账逻辑自测。纯函数,不起 Worker、不调网络。
// 跑:node worker/test_accounting.mjs

import assert from "node:assert/strict";
import {
  ASR_USD_PER_SEC, appendUsage, asrCostUSD, buildRecord, fromOpenAIUsage, isPeak,
  priceUSD, usageKey, isDurationPriced,
} from "./src/accounting.js";
import { readFileSync } from "node:fs";

// 钉死的两个时刻。**每一条算钱的断言都要挑一个**,否则测试会看钟表决定成败。
const OFF_PEAK = new Date("2026-08-18T20:00:00Z");   // 北京次日 04:00
const PEAK     = new Date("2026-08-18T07:00:00Z");   // 北京 15:00

const tests = {
  "deepseek-flash 新请求名使用当前官方错峰价"() {
    const u = { input_tokens: 1_000_000, cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000 };
    assert.ok(Math.abs(priceUSD('deepseek-flash', u, OFF_PEAK) - 0.753) < 1e-12);
    assert.equal(priceUSD('deepseek-flash', u, PEAK), priceUSD('deepseek-flash', u, OFF_PEAK) * 2);
  },
  "Step 5 名义价无高峰倍数，Chat 缓存不重复算输入"() {
    const usage = fromOpenAIUsage({ prompt_tokens: 1000,
      prompt_tokens_details: { cached_tokens: 200 }, completion_tokens: 50 });
    assert.deepEqual(usage, { input_tokens: 800, cache_read_input_tokens: 200, output_tokens: 50 });
    const u = { input_tokens: 1_000_000, cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000 };
    assert.ok(Math.abs(priceUSD('step-5-preview', u, OFF_PEAK) - 3.8) < 1e-12);
    assert.equal(priceUSD('step-5-preview', u, PEAK), priceUSD('step-5-preview', u, OFF_PEAK));
  },

  // ── 🔴 ASR 模型名与「按时长计费」那张前缀表的对撞(铁律 4)──
  //
  // 2026-08-19 对抗审查抓到:表里写的是 `step-asr`,而 `index.js` 里真实的
  // 模型名是 `stepaudio-2.5-asr` ⇒ `isDurationPriced` **恒为 false**。
  // 今天没出事是运气(`buildRecord` 后面那个 `audioSec != null` 分支兜住了),
  // 而**两处对不上却不报错**正是铁律 4 点名的形状。
  //
  // ⚠️ 这条**从源码里读真实模型名**,不手抄 —— 手抄就是第三份真相源,
  // 而它会在下一次改模型名时静默失效。
  "index.js 里的 ASR 模型名必须被认成按时长计费"() {
    const src = readFileSync(new URL("./src/index.js", import.meta.url), "utf8");
    const m = src.match(/^const MODEL = '([^']+)'/m);
    assert.ok(m, "index.js 里找不到 `const MODEL = '…'` —— 这条对撞的一端没了");
    assert.ok(isDurationPriced(m[1]),
      `模型名 ${m[1]} 没被 DURATION_PRICED 认出来 —— ASR 时长缺失时会顺着 token 那条路`
      + `算出一个 0,账面上看起来像免费用了一次,而实际是钱花了没记上`);
  },


  // ── 价表:与 shared/model_router.py 必须是同一组数 ──

  // 🔴 **时间必须钉死。** 2026-08-18 起价表分峰谷,不传 `when` 就等于
  // 「白天跑红、半夜跑绿」—— 一条会看钟表决定成败的测试比没有还糟。
  "deepseek-pro 按三档单价折美元(错峰)"() {
    const cost = priceUSD("deepseek-v4-pro", {
      input_tokens: 1_000_000, cache_read_input_tokens: 1_000_000, output_tokens: 1_000_000,
    }, OFF_PEAK);
    assert.equal(Math.round(cost * 1e4) / 1e4, 0.66 + 0.022 + 1.98);
  },

  "🔴 高峰整齐翻倍 —— 表里存的是错峰价"() {
    const u = { input_tokens: 1_000_000, cache_read_input_tokens: 1_000_000,
                output_tokens: 1_000_000 };
    assert.equal(Math.round(priceUSD("deepseek-v4-pro", u, PEAK) * 1e6) / 1e6,
                 Math.round(priceUSD("deepseek-v4-pro", u, OFF_PEAK) * 2 * 1e6) / 1e6);
  },

  "🔴 高峰窗口按 UTC 判,不是本地时间"() {
    // UTC 07:00 是高峰(北京 15:00);UTC 15:00 是错峰(北京 23:00)。
    // 拿本地时间判的话,在 UTC+8 的机器上两者会**正好судь反**。
    assert.ok(isPeak(new Date("2026-08-18T07:00:00Z")), "UTC 07:00 该是高峰");
    assert.ok(!isPeak(new Date("2026-08-18T15:00:00Z")), "UTC 15:00 该是错峰");
    // 边界:左闭右开
    assert.ok(isPeak(new Date("2026-08-18T01:00:00Z")), "01:00 整该算高峰");
    assert.ok(!isPeak(new Date("2026-08-18T04:00:00Z")), "04:00 整该算错峰");
    assert.ok(!isPeak(new Date("2026-08-18T10:00:00Z")), "10:00 整该算错峰");
  },

  "cache_creation 按 input_miss 计价(与 Python 侧同口径)"() {
    const a = priceUSD("deepseek-v4-pro", { input_tokens: 1_000_000 }, OFF_PEAK);
    const b = priceUSD("deepseek-v4-pro", { cache_creation_input_tokens: 1_000_000 }, OFF_PEAK);
    assert.equal(a, b);
  },

  "前缀匹配:带日期后缀的模型名也能命中价表"() {
    assert.ok(priceUSD("deepseek-v4-pro-20260801", { output_tokens: 1_000_000 }) > 0);
  },

  "没配价返回 null,不是 0"() {
    // 返回 0 会让「漏配价」和「真免费」长得一样,账面上永远查不出来
    assert.equal(priceUSD("某个没进价表的模型", { output_tokens: 999 }), null);
    // ~~「免费额度才是真 0」~~ 2026-08-24 作废(仓规 6):用户拍板改记**官方标价**
    // (仅作记录,不作决策依据)—— 免费额度耗尽那天账本已经是对的,
    // 不会出现一直记 ¥0 的假账(M2-成6 那条待办)。
    assert.ok(priceUSD("step-3.7-flash", { output_tokens: 999 }) > 0,
              "step-3.7-flash 该记官方标价(名义账),记 0 就回到假账");
  },

  // ── ASR 按时长 ──

  "ASR 按 ¥0.15/小时换算"() {
    // 一小时 = ¥0.15 = $0.15/7.2
    assert.equal(Math.round(asrCostUSD(3600) * 1e6) / 1e6,
                 Math.round((0.15 / 7.2) * 1e6) / 1e6);
    assert.ok(ASR_USD_PER_SEC > 0);
  },

  "5 秒音频算得出一个非零的钱"() {
    assert.ok(asrCostUSD(5) > 0);
  },

  // ── 记录形状 ──

  "记录字段与 usage.jsonl 对齐"() {
    const r = buildRecord({
      scene: "extract", model: "deepseek-v4-pro",
      usage: { input_tokens: 100, output_tokens: 50 },
      at: "2026-08-08T15:00:00.000Z",
    });
    assert.deepEqual(Object.keys(r).sort(),
      ["audio_sec", "cache_create", "cache_read", "cost_usd", "input", "model", "output", "scene", "t"]);
    assert.equal(r.scene, "extract");
    assert.ok(r.cost_usd > 0);
  },

  "ASR 记录带 audio_sec,钱按时长算而不是按 token"() {
    const r = buildRecord({ scene: "asr", model: "step-asr-2.5", audioSec: 5,
                            at: "2026-08-08T15:00:00.000Z" });
    assert.equal(r.audio_sec, 5);
    assert.equal(r.input, 0);
    assert.ok(r.cost_usd > 0, "step-asr 在 token 价表里是 0,必须走时长那条路");
  },

  "时长未知时 cost_usd 是 null,不是 0"() {
    // 账上留个显眼的窟窿,好过拿 0 蒙混过去
    const r = buildRecord({ scene: "asr", model: "step-asr-2.5", audioSec: null,
                            at: "2026-08-08T15:00:00.000Z" });
    assert.equal(r.cost_usd, null);
  },

  // ── OpenAI(DeepSeek)口径换算:会把账算多的那个坑 ──

  "prompt_tokens 含缓存命中,换算时必须扣掉"() {
    // DeepSeek 回 prompt_tokens=1200(其中 800 命中缓存)。
    // 直接塞 input_tokens=1200 再加 cache_read=800,那 800 就按
    // 「未命中价 + 命中价」收了两遍。
    const u = fromOpenAIUsage({
      prompt_tokens: 1200, prompt_cache_hit_tokens: 800, completion_tokens: 300,
    });
    assert.deepEqual(u, {
      input_tokens: 400, cache_read_input_tokens: 800, output_tokens: 300,
    });
    const cost = priceUSD("deepseek-v4-pro", u, OFF_PEAK);
    const expected = (400 / 1e6) * 0.66 + (800 / 1e6) * 0.022 + (300 / 1e6) * 1.98;
    assert.equal(Math.round(cost * 1e6) / 1e6, Math.round(expected * 1e6) / 1e6);
    // 手算钉住(错峰):0.000264 + 0.0000176 + 0.000594
    assert.equal(Math.round(cost * 1e6) / 1e6, 0.000876);
  },

  "上游直接给了 miss 数就用它,不自己减"() {
    const u = fromOpenAIUsage({
      prompt_tokens: 1200, prompt_cache_hit_tokens: 800,
      prompt_cache_miss_tokens: 400, completion_tokens: 0,
    });
    assert.equal(u.input_tokens, 400);
  },

  "没有缓存字段时 input 就是 prompt_tokens 全额"() {
    assert.equal(fromOpenAIUsage({ prompt_tokens: 500 }).input_tokens, 500);
  },

  "miss 不会被算成负数"() {
    // 上游字段自相矛盾时宁可记 0,也不要负数把总账拉低
    assert.equal(fromOpenAIUsage({ prompt_tokens: 100, prompt_cache_hit_tokens: 300 }).input_tokens, 0);
  },

  // ── R2 「append」 ──

  "一条记录一个对象,key 按天分目录"() {
    const r = buildRecord({ scene: "asr", model: "step-asr-2.5", audioSec: 5,
                            at: "2026-08-08T15:00:00.000Z" });
    const k = usageKey(r, "abcd1234");
    assert.ok(k.startsWith("usage/2026-08-08/"), k);
    assert.ok(k.endsWith(".json"), k);
  },

  "同一时刻两条账不会撞 key(并发下丢的正好是账)"() {
    const r = buildRecord({ scene: "asr", model: "step-asr-2.5", audioSec: 1,
                            at: "2026-08-08T15:00:00.000Z" });
    assert.notEqual(usageKey(r, "aaaa"), usageKey(r, "bbbb"));
  },

  async "写成功返回 persisted=true 并真的落进桶里"() {
    const store = new Map();
    const bucket = { put: async (k, v) => void store.set(k, v) };
    const r = buildRecord({ scene: "asr", model: "step-asr-2.5", audioSec: 5,
                           at: "2026-08-08T15:00:00.000Z" });
    const out = await appendUsage(bucket, r, "n1");
    assert.equal(out.persisted, true);
    assert.equal(store.size, 1);
    assert.deepEqual(JSON.parse(store.get(out.key)), r);
  },

  async "写失败不抛也不吞:persisted=false 且把记录原样带出来"() {
    // §2.2 写死「不允许先跑着不记」。钱已经花了,不能因为记账失败就把结果扔掉,
    // 更不能假装没事——所以把 record 交回去,让手机有第二次机会记下来。
    const bucket = { put: async () => { throw new Error("R2 挂了"); } };
    const r = buildRecord({ scene: "asr", model: "step-asr-2.5", audioSec: 5,
                           at: "2026-08-08T15:00:00.000Z" });
    const out = await appendUsage(bucket, r, "n1");
    assert.equal(out.persisted, false);
    assert.match(out.error, /R2 挂了/);
    assert.deepEqual(out.record, r, "记录必须原样带回,否则这笔开销就真的消失了");
  },
};

let failed = 0;
for (const [name, fn] of Object.entries(tests)) {
  try {
    await fn();
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    console.error(`FAIL ${name}\n     ${e.message}`);
  }
}
console.log(failed ? `\n${failed} failed` : `\nall passed (${Object.keys(tests).length})`);
process.exit(failed ? 1 : 0);

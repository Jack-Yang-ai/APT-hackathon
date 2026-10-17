// 成本记账。价表与记录形状**照搬 shared/model_router.py**,换价只改这里和那边。
//
// ────────────────────────────────────────────────────────────────
// 二选一定死:**记账写 R2 append**,不走「回传手机随主库存」。
// (§2.2 要求二选一在本任务定死并写进文档;文档见 worker/README.md)
//
// 为什么选 R2:
//   回传手机意味着账目要经过一个可能离线、可能被系统杀掉、可能永远不再回来的
//   客户端。而 CLAUDE.md 写着「没入账的开销等于不存在,会让人拿着过期结论优化
//   错地方」—— 账丢了比钱花了更贵。Worker 到 R2 是同一朵云内的写,失败面小得多。
//
// 「append」在 R2 上怎么落地:**一条记录一个对象**,不是读-改-写一个日报文件。
//   Worker 是并发的,读-改-写在两个请求撞上时会丢记录,而丢的恰好是账 ——
//   这正是要防的那件事。一条一个对象没有竞态,代价只是读的时候要 list。
// ────────────────────────────────────────────────────────────────

/** 美元/百万 token:{模型前缀: [input_miss, cache_read, output]}。前缀匹配。 */
// 🔴 **表里存的是「错峰价」,高峰要乘 `PEAK_MULTIPLIER`**(2026-08-18,U3 定案)。
// 与 `shared/model_router.py` 的 `_PRICES` **必须逐条一致** —— `test_extract.mjs`
// 里有一道对撞守着它(价表漂了**什么都不表现**,只是账本悄悄变假)。
export const PRICES = {
  // 2026-10-15：https://api-docs.deepseek.com/quick_start/pricing/；旧名保留历史口径。
  "deepseek-flash":    [0.15, 0.003, 0.60],
  "deepseek-v4-flash": [0.22, 0.007, 0.66],
  "deepseek-v4-pro":   [0.66, 0.022, 1.98],
  // ⚠️ 这是官方标价,不是我们的真实成本(现走免费额度),仅作记录,不作决策依据。
  //    这样免费额度耗尽的那天,账本已经是对的 —— 不会出现记 ¥0 的假账(M2-成6 那条待办)。
  "step-3.7-flash":    [0.1875, 0.0375, 1.125],
  // 标准 API 名义价，非 Step Plan 实扣：https://platform.stepfun.ai/docs/en/guides/pricing/details
  "step-5-preview":    [1.0, 0.10, 2.70],
  "sonnet":            [3.0, 0.30, 15.0],
  "haiku":             [0.80, 0.08, 4.0],
  "step-asr":          [0.0, 0.0, 0.0],   // 按时长计费,见 ASR_CNY_PER_HOUR
};

/** 按**时长**计费、不按 token 计费的模型前缀。
 *
 *  单列一张表,是因为这些模型在 PRICES 里的三档单价是 0 —— 那 0 表示
 *  「此路不通」,不表示「免费」。不区分的话,ASR 时长缺失时会顺着 token 那条路
 *  算出一个 0,账面上看起来像免费用了一次,而实际是钱花了没记上。 */
export const DURATION_PRICED = ["step-asr", "stepaudio"];
// 🔴 **2026-08-19 补 `stepaudio`:原来只有 `step-asr`,而实际模型名是
// `stepaudio-2.5-asr`(`index.js` 的 `MODEL`)⇒ `isDurationPriced` **恒为 false**。
// 今天没出事是运气:`buildRecord` 后面那个 `audioSec != null` 分支兜住了。
// **两处对不上而不报错 —— 铁律 4 的形状**,由 `test_accounting.mjs` 那条对撞钉住。

export const isDurationPriced = (model) =>
  DURATION_PRICED.some((p) => model && model.startsWith(p));

/** ASR 按音频时长计费。¥0.15/小时 = StepAudio 2.5 实际价(2026-08-06 用户确认)。 */
export const ASR_CNY_PER_HOUR = 0.15;
export const USD_PER_CNY = 1 / 7.2;
export const ASR_USD_PER_SEC = (ASR_CNY_PER_HOUR * USD_PER_CNY) / 3600;

/** 高峰时段(**UTC**):01:00–04:00 与 06:00–10:00,其余全是错峰。
 *  北京时间 = UTC+8 ⇒ 09:00–12:00 与 14:00–18:00,正好是上班时间。
 *  ⚠️ 边界左闭右开(04:00 与 10:00 整点算错峰)—— 与 model_router.py 同一口径。 */
export const PEAK_UTC_HOURS = new Set([1, 2, 3, 6, 7, 8, 9]);
export const PEAK_MULTIPLIER = 2.0;

export function isPeak(when = new Date()) {
  return PEAK_UTC_HOURS.has(when.getUTCHours());
}

/** 按 token × 单价折美元。价表里没有这个模型就返回 null —— **不返回 0**。
 *  返回 0 会让「没配价」和「真免费」长得一模一样,账面上永远查不出来。
 *
 *  `when` 决定按高峰还是错峰计价,默认取现在。 */
export function priceUSD(model, usage = {}, when = new Date()) {
  const key = Object.keys(PRICES).find((k) => model && model.startsWith(k));
  if (!key) return null;
  const mult = isPeak(when) && !model.startsWith('step-5-preview') ? PEAK_MULTIPLIER : 1;
  const [pin, pcache, pout] = PRICES[key].map((x) => x * mult);
  const inp = (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0);
  const cache = usage.cache_read_input_tokens ?? 0;
  const out = usage.output_tokens ?? 0;
  return (inp / 1e6) * pin + (cache / 1e6) * pcache + (out / 1e6) * pout;
}

export function asrCostUSD(seconds) {
  return seconds * ASR_USD_PER_SEC;
}

/** 把 OpenAI 兼容(DeepSeek)的 usage 换成价表用的口径。
 *
 *  ⚠️ 两边的 `input` 含义不一样,这是会把账算多的坑:
 *    · Anthropic / 本价表:`input_tokens` **不含**缓存命中,命中另计 `cache_read`
 *    · DeepSeek(OpenAI 兼容):`prompt_tokens` **含**缓存命中
 *  直接把 prompt_tokens 塞进 input_tokens,再把命中数塞进 cache_read,
 *  那部分就按「未命中价 + 命中价」收了两遍。缓存命中价只有未命中的 1/10,
 *  这个错会把成本系统性高估 —— 而高估会让人去优化根本不贵的地方。 */
export function fromOpenAIUsage(u = {}) {
  u ??= {};
  const hit = u.prompt_cache_hit_tokens ?? u.prompt_tokens_details?.cached_tokens ?? 0;
  const miss = u.prompt_cache_miss_tokens ?? Math.max(0, (u.prompt_tokens ?? 0) - hit);
  return {
    input_tokens: miss,
    cache_read_input_tokens: hit,
    output_tokens: u.completion_tokens ?? 0,
  };
}

/** 一条账。字段与 shared/model_router.py 的 usage.jsonl 对齐,便于两边合并对账。 */
export function buildRecord({ scene, model, usage = {}, audioSec = null, costUSD = null, at }) {
  // 按时长计费的模型**只走时长这条路**:时长不知道就是不知道,不许回落到 token 价表
  // 拿它那三个 0 凑出一个「免费」。
  // 🔴 **按 `at` 计价,不按「现在」。** 峰谷价一上(2026-08-18),两者就不再等价:
  // 落账可能发生在调用之后(重试、批量写),跨过 UTC 整点就会按错的档收费。
  // 记录的时间戳与它的价必须是同一个时刻,否则账本自己和自己对不上。
  const when = at ? new Date(at) : new Date();
  const cost = costUSD ?? (isDurationPriced(model)
    ? (audioSec == null ? null : asrCostUSD(audioSec))
    : (audioSec != null ? asrCostUSD(audioSec) : priceUSD(model, usage, when)));
  return {
    t: at,
    scene,
    model,
    input: usage.input_tokens ?? 0,
    cache_create: usage.cache_creation_input_tokens ?? 0,
    cache_read: usage.cache_read_input_tokens ?? 0,
    output: usage.output_tokens ?? 0,
    audio_sec: audioSec,
    // 没配价时是 null,不是 0 —— 让「漏配价」在账面上露馅
    cost_usd: cost == null ? null : Math.round(cost * 1e6) / 1e6,
  };
}

/** 账本对象的 key。按天分目录便于对账时只 list 一天。 */
export function usageKey(record, nonce) {
  const day = record.t.slice(0, 10);
    return `usage/${day}/${record.t.replace(/[:.]/g, "-")}-${nonce}.json`;
}

/** 写一条账到 R2。
 *
 *  **写失败不吞、也不把已经花掉的钱作废**:调用方拿到 persisted=false 之后
 *  连同 record 一起回给手机,让手机有第二次机会记下来。§2.2 写死了
 *  「不允许先跑着不记」,所以这里绝不能 catch 完就算了。 */
export async function appendUsage(bucket, record, nonce) {
  const key = usageKey(record, nonce);
  try {
    await bucket.put(key, JSON.stringify(record), {
      httpMetadata: { contentType: "application/json" },
    });
    return { persisted: true, key, record };
  } catch (e) {
    return { persisted: false, key, record, error: String(e && e.message || e) };
  }
}

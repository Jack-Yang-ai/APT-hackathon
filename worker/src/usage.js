// 对账口:把 R2 里那些一条一个对象的账汇总起来(2026-08-17)。
//
// ## 为什么必须有这个口
//
// 仓规原则 5:「没入账的开销等于不存在」。而**写得进、读不出来**离「不存在」
// 只差一步 —— 今天就撞上了:账老老实实落在 `usage/<日>/` 下,而 wrangler
// 没有 list objects,于是想看一眼「今天花了多少」得去翻 Cloudflare 面板。
// 查不出来的账,用完第二天就没人再看,和没记一样。
//
// ## 为什么按 token 报,不只报钱
//
// 钱是结果,token 是**原因**。只看钱只能知道「贵了」,看 token 才知道
// 贵在输入还是输出 —— 而抽取的成本几乎全在输出上(推理档输出单价是输入的
// 4~5 倍),降本的着力点完全不同。缓存命中也要单列:它的单价只有未命中的
// 1/10,混在一起看会把「缓存没生效」这种问题藏起来。

export const USAGE_PREFIX = 'usage/';

/**
 * 汇总某一天(或全部)的账。
 *
 * `day` 形如 `2026-08-17`;不给就把 `usage/` 下全部扫一遍。
 *
 * ⚠️ **`cost_usd` 为 null 的单独计数,不当 0。**
 * null 的意思是「这个模型没配价」,而当成 0 会让漏配价和真免费长得一模一样 ——
 * `accounting.js` 特意让它返回 null 就是为了这个,汇总时再抹平就白设计了。
 */
export async function summarize({ bucket, day, maxObjects = 5000 }) {
  if (!bucket) return { error: 'R2 没绑' };
  const prefix = day ? `${USAGE_PREFIX}${day}/` : USAGE_PREFIX;

  const total = blank();
  const byScene = {};
  let cursor, scanned = 0, unreadable = 0;

  do {
    const page = await bucket.list({ prefix, cursor, limit: 1000 });
    for (const obj of page.objects ?? []) {
      if (scanned >= maxObjects) break;
      scanned++;
      const o = await bucket.get(obj.key);
      const rec = o ? await o.json().catch(() => null) : null;
      // 读不出来的账**要数出来**,不能当它不存在 —— 那正是这个口要防的事。
      if (!rec) { unreadable++; continue; }
      const scene = rec.scene || '(没写场景)';
      byScene[scene] ??= blank();
      add(total, rec);
      add(byScene[scene], rec);
    }
    cursor = page.truncated && scanned < maxObjects ? page.cursor : undefined;
  } while (cursor);

  return {
    day: day ?? '(全部)',
    scanned, unreadable,
    total: finish(total),
    by_scene: Object.fromEntries(
      Object.entries(byScene)
        .sort((a, b) => (b[1].cost_usd ?? 0) - (a[1].cost_usd ?? 0))
        .map(([k, v]) => [k, finish(v)])),
  };
}

const blank = () => ({
  calls: 0, input: 0, cache_create: 0, cache_read: 0, output: 0,
  audio_sec: 0, cost_usd: 0, unpriced: 0,
});

function add(acc, rec) {
  acc.calls++;
  acc.input        += rec.input ?? 0;
  acc.cache_create += rec.cache_create ?? 0;
  acc.cache_read   += rec.cache_read ?? 0;
  acc.output       += rec.output ?? 0;
  acc.audio_sec    += rec.audio_sec ?? 0;
  // null 单独计数 —— 见文件头那段:漏配价与真免费不能长得一样
  if (rec.cost_usd == null) acc.unpriced++; else acc.cost_usd += rec.cost_usd;
}

function finish(a) {
  const usd = Math.round(a.cost_usd * 1e6) / 1e6;
  return {
    ...a,
    cost_usd: usd,
    // 日常看的是人民币,而红线(¥1.5/天)也是人民币的
    cost_cny: Math.round(usd * 7.2 * 1e4) / 1e4,
    tokens: a.input + a.cache_create + a.cache_read + a.output,
    audio_min: Math.round(a.audio_sec / 6) / 10,
  };
}

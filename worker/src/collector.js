// 云端替手机盯着转写结果(2026-08-17 用户拍板)。
//
// ## 为什么这件事不能让手机干
//
// 转写是异步的,总得有人去取结果。原来让**手机**去轮 —— 而手机恰恰是整条链上
// **最不可用**的一环:会熄屏、会被切走、被 iOS 掐着后台配额。
// 实测的形态是:用户点完结束就得把 App 开着盯到出稿,一熄屏就停在半路;
// 而后台唤醒每次只给几十秒,刚够问一两次「转完了吗」就又睡了。
//
// 云代理是这条链上**唯一一直醒着**的东西。让它去轮,手机只在醒来时取一次。
//
// ## 落地形状
//
//   提交成功 → 写一条待办  asr/pending/<task_id>.json
//   Cron 每分钟 → 逐条问上游 → 出结果就写 asr/result/<task_id>.json 并删待办
//   手机来查   → **先看 asr/result/**,有就直接给(不碰上游、零等待)
//
// 手机侧**一行都不用改**:`/asr/query` 的语义没变,只是通常瞬间就有答案。
//
// ## 三条纪律
//
// · **先写结果,再删待办。** 反过来的话,两步之间挂掉就把这条任务弄丢了 ——
//   而丢的表现是「这一场永远在整理中」,没有任何地方报错。
// · **失败也要落成结果。** 只落成功的话,失败的任务会一直躺在待办里被反复问,
//   而手机那头永远等不到答案。
// · **待办要有兜底期限。** 上游万一永远不给终态,这条待办会被问到天荒地老;
//   超过期限就自己判失败并写结果,让手机看见「它没成」而不是无限等。

export const PENDING_PREFIX = 'asr/pending/';
export const RESULT_PREFIX = 'asr/result/';
export const CLAIM_PREFIX  = 'asr/claim/';
export const TRACE_PREFIX  = 'asr/trace/';

/** 一次 cron 最多问几条。
 *
 *  Workers 免费档一次调用有子请求上限,而 list 本身也占一次;
 *  留足余量。积压超过这个数就下一分钟接着处理 —— 慢一点没关系,
 *  **撞上限会让整次 cron 失败,那才是真丢东西**。 */
export const MAX_PER_RUN = 20;

/** 待办的兜底期限:6 小时。超过就判失败。
 *
 *  比音频保留期短得多,也比任何正常转写长得多(实测几十秒的音频秒级出结果)。 */
export const PENDING_TTL_MS = 6 * 3600 * 1000;

/** 结果留多久。手机可能在几小时后才醒来取,留一天足够;
 *  留太久是白占空间,而 R2 没有 TTL,只能自己扫。 */
export const RESULT_TTL_MS = 24 * 3600 * 1000;

export const pendingKey = (taskID) => `${PENDING_PREFIX}${taskID}.json`;

/** 「这块音频已经有一个在跑的转写任务了」的认领对象。
 *
 *  🔴 **它挡的是重复付费,不是重复调用。** 2026-08-18 实测的形态:
 *  提交在云代理这边成功了(任务建了、钱花了),而手机那边超时没等到 task_id ——
 *  手机的去重凭据是「拿到过 remote_id」,**恰恰失败的那一块没有**,
 *  于是下一轮原样再提交一次。当天云端记了 13 次 ASR、手机只有 10 条作业。
 *
 *  认领**按音频键**存,不按 task_id —— 手机重来时手里只有音频键。 */
export const claimKey = (audioKey) => `${CLAIM_PREFIX}${audioKey}.json`;
export const resultKey  = (taskID) => `${RESULT_PREFIX}${taskID}.json`;

/**
 * 把上游回复分档。**和手机侧 `ProxyClient.classify` 同一套判据** ——
 * 两边给出不同答案的话,云端会把「还在算」当成终态存下来,而手机拿到一份
 * 半成品还以为完了。
 *
 * 这个接口**没有 `status=SUCCESS` 那种终态**(2026-08-17 实测:完成的回复
 * 形如 `{"duration":270.14,"result":[…]}`,一个 status 字段都没有),
 * 所以完成判定看 **`result` 出现**。
 */
export function classify(parsed) {
  const d = (parsed && parsed.data) || parsed || {};
  const st = String(d.status ?? '').toUpperCase();
  if (['FAIL', 'ERROR', 'BLOCK'].some((k) => st.includes(k))) return 'failed';
  const r = d.result;
  const empty = r == null
    || (Array.isArray(r) && r.length === 0)
    || (typeof r === 'object' && !Array.isArray(r) && Object.keys(r).length === 0);
  // ⚠️ `result:[{}]` **算终态**(「转完了,一个字都没有」)。判成还没好的话,
  // 就退回那个永远轮询的洞里 —— 那正是这次要修的东西。
  return empty ? 'pending' : 'done';
}

/**
 * 跑一轮收割。返回这一轮做了什么,给日志与自测看。
 *
 * `fetchQuery(taskID)` 注进来:自测不打真上游 —— 打真上游要钱,
 * 而这一层最该测的(先写后删、失败也落、过期兜底)和真网络无关。
 */
export async function collect({ bucket, fetchQuery, now = Date.now(),
                                maxPerRun = MAX_PER_RUN }) {
  if (!bucket) return { error: 'R2 没绑' };
  const listed = await bucket.list({ prefix: PENDING_PREFIX, limit: maxPerRun });
  const out = { checked: 0, done: 0, failed: 0, stillRunning: 0, expired: 0, errors: [] };

  for (const obj of listed.objects ?? []) {
    const taskID = obj.key.slice(PENDING_PREFIX.length).replace(/\.json$/, '');
    if (!taskID) continue;
    out.checked++;

    // 🔴 **已经换到 SSE 的,收割器一个字都别碰**(M1-34)。
    //
    // 不跳过的两个后果,都真会发生:
    // · `finish` 是**无条件** `put(resultKey)` ⇒ 文件端点的迟到结果会把
    //   Mac 用 SSE 出好的稿**盖掉**;
    // · 下面那条 6 小时兜底会写成 `{"error":"asr timeout"}` ⇒
    //   **一块已经出稿的音频几小时后在 R2 里变成失败记录**,
    //   而手机若此时才醒来(「整夜不开」正是 M2-B8 的目标),拿到的就是那份失败。
    //
    // ⚠️ **待办本身不删** —— `index.js` 那道防重复付费的闸判据就是
    // 「待办还在 = 复用」,删了等于把「同一块再付一次钱」的窗口重新打开。
    // 所以用第三态:标记留在待办里,闸继续生效,收割器不再理它。
    const claimedBySSE = await bucket.get(obj.key)
      .then((o) => (o ? o.json().catch(() => null) : null))
      .then((j) => Boolean(j && j.switched_to_sse))
      .catch(() => false);
    if (claimedBySSE) { out.skippedToSSE = (out.skippedToSSE ?? 0) + 1; continue; }

    let verdict, body;
    try {
      const r = await fetchQuery(taskID);
      body = r.body;
      // 🔴 **上游一次非 2xx 也不算终态**(2026-08-19 改,对抗审查抓到)。
      //
      // 原来这里是 `r.ok ? classify(...) : 'failed'` —— 一次 429 / 500 / 502
      // 就把这一块**永久判失败**,那 5 分钟的内容以占位行落库,而它其实还在跑。
      // 抛出来的网络错早就按「不算终态」处理了(下面那个 catch),
      // 而非 2xx 与它是同一件事的两种表现形式,没有理由分开对待。
      //
      // ⚠️ 这条改动**变贵了**,所以要说清楚:自本次起 `asr/pending/` 还是不是
      // 那条待办,同时是云代理那道幂等闸的唯一判据。误删待办 = 重新打开
      // 「同一块再付一次钱」的窗口。
      //
      // 「手机必须等得到一个答案」这条要求仍然成立 —— 由下面的
      // `PENDING_TTL_MS`(6 小时)兜底:超期就自己判失败并写结果。
      // 差别只是答案最慢 6 小时到,而不是一次抖动就给个错答案。
      if (!r.ok) {
        out.errors.push(`${taskID}: 上游 ${r.status ?? '非 2xx'},不当终态`);
        continue;
      }
      verdict = classify(safeParse(body));
    } catch (e) {
      // 问不通不算终态 —— 网络抖一下就把任务判死,是拿一次偶发换掉一整场。
      out.errors.push(`${taskID}: ${String((e && e.message) || e)}`);
      continue;
    }

    if (verdict === 'pending') {
      // 上游还在算。**只有这一条会看期限** —— 已经有终态的不该被期限影响。
      const age = now - Date.parse(obj.uploaded ?? new Date(now).toISOString());
      if (age > PENDING_TTL_MS) {
        out.expired++;
        await finish(bucket, taskID, JSON.stringify({
          error: 'asr timeout',
          detail: `提交后 ${Math.round(age / 3600000)} 小时仍未出终态,云端判失败`,
        }), 'failed');
      } else {
        out.stillRunning++;
      }
      continue;
    }

    out[verdict === 'done' ? 'done' : 'failed']++;
    await finish(bucket, taskID, body, verdict);
  }
  return out;
}

/** **先写结果,再删待办。** 反过来的话中间挂掉就丢了这条任务,
 *  而丢的表现是「这一场永远在整理中」,没有任何地方报错。 */
async function finish(bucket, taskID, body, verdict) {
  await bucket.put(resultKey(taskID), JSON.stringify({ verdict, body, at: new Date().toISOString() }),
                   { httpMetadata: { contentType: 'application/json' } });
  await bucket.delete(pendingKey(taskID));
}

/** 扫掉某个前缀下过期的对象。R2 没有 TTL,不扫就一直涨 ——
 *  **而涨到天荒地老也不会有东西红**(CLAUDE.md 第四条铁律点名的形状)。 */
export async function sweepStale({ bucket, prefix, ttlMs, now = Date.now(), limit = 200 }) {
  const listed = await bucket.list({ prefix, limit });
  let deleted = 0;
  for (const obj of listed.objects ?? []) {
    if (now - Date.parse(obj.uploaded ?? new Date(now).toISOString()) > ttlMs) {
      await bucket.delete(obj.key);
      deleted++;
    }
  }
  return deleted;
}

/** 扫掉过期的结果。R2 没有 TTL,不扫就一直涨。 */
export async function sweepResults({ bucket, now = Date.now(), limit = 200 }) {
  const listed = await bucket.list({ prefix: RESULT_PREFIX, limit });
  let deleted = 0;
  for (const obj of listed.objects ?? []) {
    if (now - Date.parse(obj.uploaded ?? new Date(now).toISOString()) > RESULT_TTL_MS) {
      await bucket.delete(obj.key);
      deleted++;
    }
  }
  return deleted;
}

function safeParse(s) { try { return JSON.parse(s); } catch { return null; } }

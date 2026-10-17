/**
 * 声纹判决队列(`M2-认8` ③)。形状照 `extract_queue.js`,但**没有 cron 兜底**:
 *
 * 🔴 **执行方只有 Mac,Worker 永远不判。** 判决要跑 ONNX + 冒充集,cron 上没有;
 * 更重要的是「兜底判」意味着第二份判决实现(铁律 4 点名的形态)。
 * Mac 挂了就等 —— 心跳(`scripts/daemons.sh status`)让「挂了」看得见,
 * 手机侧界面按「说话人整理中」如实显示(它真的会自己好)。
 *
 * ## 幂等
 *
 * 产物已在 ⇒ 直接说「好了」;job 已在 ⇒ 说「排过了」。**不靠手机记得只排一次**
 * (App 重启、后台唤醒都会重放)。声纹不花钱,但重复判会让 Mac 白烧 CPU,
 * 更重要的是同一场两份产物会让手机合并两次 —— 合并侧靠 (session, cluster_key)
 * upsert 兜住,这里靠幂等少制造一份。
 *
 * ## 键是 session,不带 part
 *
 * 判决要跨块看整场(聚类是全场的),一场一个 job —— 与抽取按块切不同。
 */

const JOB_PREFIX = 'voiceprint/jobs/';
const OUT_PREFIX = 'voiceprint/out/';

export const jobKey = (session) => `${JOB_PREFIX}${session}.json`;
export const outKey = (session) => `${OUT_PREFIX}${session}.json`;

/** 手机排一场。`payload` 整体透传给 Mac(契约见方案 §3.2:model / lines / ext)。 */
export async function enqueue(bucket, { session, payload }) {
  // force = 强制重判(enroll 之后 / 用户点「重新认人」):旧产物作废删掉,
  // 重新排 job。没有 force 时旧产物短路 —— 那是幂等的正身。
  if (payload?.force) {
    await bucket.delete(outKey(session));
  } else {
    if (await bucket.head(outKey(session))) return { state: 'done' };
    if (await bucket.head(jobKey(session))) return { state: 'queued' };
  }
  await bucket.put(jobKey(session), JSON.stringify({
    ...payload, session, at: new Date().toISOString(),
  }), { httpMetadata: { contentType: 'application/json' } });
  return { state: 'queued', created: true };
}

/** 手机来取判决。**取走不删** —— 重装/重放还要再取,产物幂等靠 upsert。 */
export async function takeResult(bucket, { session }) {
  const got = await bucket.get(outKey(session));
  if (got) return { state: 'done', body: await got.text() };
  if (await bucket.head(jobKey(session))) return { state: 'running' };
  return { state: 'none' };
}

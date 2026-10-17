/**
 * 场次级云端清除(`M2-审12`,2026-08-24)。
 *
 * ## 为什么必须有这条口
 *
 * 界面上那句承诺是**「音频、逐字稿、纪要、归属都会删掉,撤不回来」**
 * (`HomeView.swift`)。而在这条口之前,`MemoryRemoval` **只动手机**:
 * 改本地库、删本地 m4a。云上那一份 —— 原始音频、ASR 报文、抽取产物 ——
 * **一个都没删,也没有任何定时清理**(cron 只扫 `asr/result` / `asr/claim` / `asr/trace`)。
 *
 * 🔴 用户以为内容没了,而云端还能还原出音频与模型产物。
 * 这不是「差一点」:**说了删而没删,比不提供删除更糟**。
 *
 * ## 为什么是「手机报清单」,不是「云端自己推算」
 *
 * 云端**推算不出来**这一场有哪些对象:
 * · `asr/pending|result` 的键是**手机任务表的行号**;
 * · `extract/*` 的键是**手机转写表的行号**。
 * 两者云端都无从反查。让云端猜的唯一办法是再存一份「场次 → 对象」的映射,
 * 而那就是第二个出处(铁律 4),且对不上时的表现是**悄悄漏删**。
 * ⇒ 手机报它自己知道的那几个号,云端只负责按前缀删干净。
 *
 * ## 幂等
 *
 * 删不存在的对象**不算错**(R2 的 `delete` 本来就幂等)。重复调用返回同样的 200 ——
 * 手机侧会重试,而「第二次调用报错」会让一次成功的删除看起来像失败。
 */

/** 一次列一页,删一页,直到列空。R2 单次 list 上限 1000。 */
async function deletePrefix(bucket, prefix) {
  let deleted = 0;
  for (;;) {
    const listed = await bucket.list({ prefix, limit: 1000 });
    const objects = listed.objects ?? [];
    if (!objects.length) return deleted;
    for (const o of objects) {
      await bucket.delete(o.key);
      deleted++;
    }
    // 没有截断标记就说明列完了。**不靠「这一页少于 limit」判断** ——
    // R2 允许返回少于 limit 条而仍未列完。
    if (!listed.truncated) return deleted;
  }
}

/**
 * 删掉一场的全部云端副本。
 *
 * @param session   手机 `sessions.id`。音频与声纹队列按它组织。
 * @param transcripts 这一场的转写行号。抽取的 job 与产物按它组织。
 * @param tasks     这一场的任务行号。ASR 的 pending 与 result 按它组织。
 * @returns 每一类删了几个 —— **要能对账**。悄悄返回 `{ok:true}` 的话,
 *          「删了 0 个」与「删干净了」在手机那头长得一模一样。
 */
export async function purgeSession(bucket, { session, transcripts = [], tasks = [] }) {
  const counts = {};
  counts.audio = await deletePrefix(bucket, `inbox/audio/${session}/`);
  // 认领标记的键里嵌着音频键 ⇒ 按同一个前缀能一网打尽。
  counts.claims = await deletePrefix(bucket, `asr/claim/inbox/audio/${session}/`);
  counts.voiceprint = await deletePrefix(bucket, `voiceprint/jobs/${session}.json`)
                    + await deletePrefix(bucket, `voiceprint/out/${session}.json`);
  // 🔴 说话人代表片段。**它躲的是 7 天保留期,不是「移出记忆」。**
  // 前者是时间到了自动清,后者是用户主动的隐私动作 —— 界面上那句承诺是
  // 「删掉,撤不回来」。漏了这一行,云上就留着一份**用户以为已经删掉的录音**,
  // 而两边都不会报错。反向那一半(保留期扫描不许碰 clips/)由
  // `eval/checks/test_clip_prefix.py` 一起钉住。
  counts.clips = await deletePrefix(bucket, `clips/${session}/`);

  let extract = 0;
  for (const t of transcripts) {
    extract += await deletePrefix(bucket, `extract/jobs/${t}-`);
    extract += await deletePrefix(bucket, `extract/out/${t}-`);
  }
  counts.extract = extract;

  let asr = 0;
  for (const id of tasks) {
    asr += await deletePrefix(bucket, `asr/pending/${id}.json`);
    asr += await deletePrefix(bucket, `asr/result/${id}.json`);
    asr += await deletePrefix(bucket, `asr/trace/${id}`);
  }
  counts.asr = asr;

  counts.total = counts.audio + counts.claims + counts.voiceprint + counts.clips
               + counts.extract + counts.asr;
  return counts;
}

/**
 * 清完之后再列一遍,确认真的空了。
 *
 * 🔴 **这不是多余的一步。** 「以为删了其实没删」在隐私上是最贵的一种静默失败,
 * 而 `delete` 不报错**不等于**对象没了(分页漏了一半、前缀写错了一个字符,
 * 两种都不会抛)。`MemoryRemoval` 在本地音频那半已经这么做了(删完回读一次),
 * 云端这半照搬同一条纪律。
 */
export async function remaining(bucket, { session, transcripts = [], tasks = [] }) {
  const prefixes = [
    `inbox/audio/${session}/`,
    `asr/claim/inbox/audio/${session}/`,
    `voiceprint/jobs/${session}.json`,
    `voiceprint/out/${session}.json`,
    `clips/${session}/`,
    ...transcripts.flatMap((t) => [`extract/jobs/${t}-`, `extract/out/${t}-`]),
    ...tasks.flatMap((id) => [`asr/pending/${id}.json`, `asr/result/${id}.json`,
                              `asr/trace/${id}`]),
  ];
  const left = [];
  for (const p of prefixes) {
    const listed = await bucket.list({ prefix: p, limit: 1 });
    if ((listed.objects ?? []).length) left.push(listed.objects[0].key);
  }
  return left;
}

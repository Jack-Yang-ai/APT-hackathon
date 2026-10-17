/**
 * 云端抽取队列(`M2-B8`)。**手机醒来几秒就够,剩下的云端自己跑完。**
 *
 * ## 为什么是这个方向
 *
 * 用户 2026-08-21:「为啥还有 app 走了就不干活的逻辑」。真相是 iOS 把 App 挂起了,
 * 而抽取实测要 **4.8 分钟**(step-3.7-flash 两阶段;单阶段也要 243 秒)——
 * 前台等 5 分钟不可能,后台配额又由 iOS 说了算 ⇒ 这一步必须搬到云上。
 *
 * ## 为什么手机上传的是**渲染好的 prompt**,不是原始转写
 *
 * 🔴 **`line_id` 是手机 SQLite 的 `lastInsertedRowID`**(`TranscriptFreeze.swift:306`)
 * —— 云端算不出来。而抽取产物每一条都要带 `line_id`(三项校验、跳原话、进展归属
 * 全靠它)。所以顺序只能是**手机先冻结拿到 id,再把带 id 的材料交给云**。
 *
 * 而 prompt 的契约(§4.2 那份 JSON 的字段与硬要求)已经有 Swift 与 Python **两份**
 * 实现在靠金标测试对齐;云端再渲染一次就是**没人测的第三份**(铁律 4)。
 * ⇒ 手机渲染好再上传,云端只负责「送出去、收回来、存住」。
 *
 * ## 分块与合并留在手机
 *
 * `ExtractionRunner` 按 800 行切块,多块时额外跑一次很小的合并调用(约 200 进 / 50 出)。
 * **一块 = 一个 job**;合并那次太小,不值得为它多跑一趟云。
 * 校验(`ExtractValidate`)也留在手机 —— 它要逐行比对,而行只有手机有。
 */

const JOB_PREFIX = 'extract/jobs/';
const OUT_PREFIX = 'extract/out/';

/**
 * 产物的身份由**什么决定这个答案**来定,不由「这是第几场第几块」来定
 * (`M2-审11`,2026-08-24)。
 *
 * 🔴 原来键是 `extract/out/<transcriptID>-<part>.json`,而 `transcriptID` 是
 * **手机 SQLite 的自增行号**。三个后果,每一个都不报错:
 *
 * · **改了 prompt / 抽取规则,旧产物照样被当成有效结果** —— `enqueue` 见到
 *   产物就返回 `done`,新配方一次都不会被跑到。而「纪要是老配方出的」
 *   这件事在界面上完全看不出来。
 * · **换了模型同理** —— 同一份 prompt 在两个模型下是两个答案,却共用一个键。
 * · **App 重装后行号从头再来** ⇒ 新场次可能撞上旧安装留在云端的产物,
 *   拿到的是**别人那一场的纪要**。
 *
 * ⇒ 键 = `<session>-<part>-<指纹>`,指纹 = SHA-256(prompt ‖ 模型 id)。
 * prompt 里已经含了转写正文、行号与模板本身,所以它**同时覆盖**了
 * 「内容变了」「模板变了」「规则变了」三件事 —— 不需要再单独维护一个
 * 「prompt 版本号」,而**版本号是要人记得手动 +1 的,那正是会漏的东西**。
 *
 * ⚠️ **指纹只在 Worker 这一侧算。** 手机拿到的是一个不透明串,原样带回来取产物 ——
 * 两侧各算一份哈希就是第二个出处(铁律 4),而对不上时的表现是「永远取不到产物」。
 *
 * ⚠️ 重装撞号也被它顺带解决了:内容不同 ⇒ prompt 不同 ⇒ 指纹不同。
 * 内容真的一模一样时复用是**对的,而且免费**,不需要安装 UUID 来阻止它。
 */
/** 规范化 JSON:对象键按字典序排,数组保序。**指纹只算它,不算原始字节。** */
export function canonical(v) {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (v && typeof v === 'object') {
    return `{${Object.keys(v).sort()
      .map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(',')}}`;
  }
  return JSON.stringify(v);
}

export async function fingerprint(prompt, model) {
  const data = new TextEncoder().encode(`${model}\n${prompt}`);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(digest)].slice(0, 8)
    .map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** 一个待抽取的块。`part` 是块号,一场多块时各自一条。 */
export const jobKey = (session, part, fp) => `${JOB_PREFIX}${session}-${part}-${fp}.json`;
/** 抽完的产物。**手机取走后不删** —— 见 `takeResult` 那段。 */
export const outKey = (session, part, fp) => `${OUT_PREFIX}${session}-${part}-${fp}.json`;

/** 一拍最多跑几个 job。
 *
 * ⚠️ **不是性能考虑,是 cron 的寿命**:一次抽取实测 243 秒,而 cron 每分钟一拍。
 * 一拍跑太多会撞上调度的时间上限,而**撞上的表现是「跑了一半没了」** ——
 * job 还在、产物没有,下一拍从头再来 ⇒ **每一拍都在重复付费**。
 * 取 1:宁可慢,不重复付费。 */
export const MAX_PER_TICK = 1;

/** 认领标记的有效期。跑挂了之后多久允许别人重跑。
 *
 * ⚠️ 它必须**明显长于一次抽取**(243 秒实测)——短了的话上一拍还在跑、
 * 下一拍就以为它死了又跑一次,而两次都会真的花钱。 */
export const CLAIM_TTL_MS = 20 * 60 * 1000;

/**
 * cron 只捡**排了这么久还没人动**的 job(`M2-B8`,2026-08-21 用户拍板分层)。
 *
 * 🔴 **这是为了让 Worker 与 Mac daemon 结构上不可能抢同一个 job。**
 * 认领是「读-改-写」,**不是原子的** —— 两个消费者会在读与写之间抢,
 * 而抢上的后果是**同一个 job 付两次钱**(不是跑两遍,是花两笔)。
 *
 * 取 10 分钟:比一次抽取(实测 100 秒;v2.5 两阶段 4.8 分钟)长得多,
 * 也比 Mac 的轮询间隔(20 秒)长得多 ⇒ **Mac 只要活着,Worker 永远碰不到**。
 * 而 Mac 关机/断网时,10 分钟之后 Worker 接手 —— 链子不断。
 *
 * ⚠️ **不要为了「快一点」把它调小到接近 `CLAIM_TTL_MS`** ——
 * 那等于把两个消费者放回同一个窗口里,而重复付费不会有任何东西报错。
 */
export const STALE_MS = 10 * 60 * 1000;

/**
 * 手机排一个块进队列。**幂等**:同一 (session, part) 重复排不会多花钱。
 *
 * 幂等靠两样:产物已经在 ⇒ 直接说「好了」;job 已经在 ⇒ 说「排过了」。
 * 🔴 **不靠调用方记得只排一次** —— 手机会重放(App 重启、后台唤醒),
 * 而重放一次就是重复付一次抽取的钱,这个仓在这上面栽过不止一次。
 */
export async function enqueue(bucket, { session, part, prompt, lines, model }) {
  // 🔴 **两条料只能有一条**(`M2-成7`):`prompt` = v1 单次调用;
  // `lines` = 两阶段 R5(渲染与多次调用都在 Mac 上做)。
  // 指纹按**实际送出去的料**算 —— 拿 prompt 给 lines job 算指纹的话,
  // 改了行内容而指纹不变,**手机会取到上一版的产物**,而两头都不报错。
  // 🔴 **指纹必须算在规范形上,不能算在「收到什么字节」上。**
  //
  // 2026-08-25 实测:两份 job 的 `lines` **内容完全相同**,只有键序不同 ——
  //   A: ["text","line_id","is_gap","cluster_tag"]
  //   B: ["text","is_gap","line_id","cluster_tag"]
  // 因为 Swift 的 `Dictionary` **没有稳定键序**,而手机序列化时没排序。
  // 于是同一块材料**几乎每一拍一个新指纹** ⇒ 手机永远取不到自己那一份产物、
  // 每拍重排一次、Mac 每拍**真抽一次(付费)**。当天 `29-0` 攒了 5 个指纹、
  // `30-0` 攒了 4 个,而两端都不报错:daemon 说「抽完了」,手机说「云端正在抽」。
  //
  // ⚠️ 修在这一侧是**因为指纹是身份函数**:同样的材料必须给同样的键。
  // 把这件事托付给发送方,就是把正确性押在一个远端实现细节上
  // (手机那边也一并排了序,但那是第二道保险,不是这一道)。
  const material = prompt ?? canonical(lines);
  const fp = await fingerprint(material, model);
  // 🔴 **`ticket` 是手机唯一需要记的东西**,而且它不需要记 —— 每一拍重新 enqueue
  // 都会拿到同一张(幂等),所以 App 重启、后台唤醒之后都不用持久化任何状态。
  const ticket = `${session}-${part}-${fp}`;
  if (await bucket.head(outKey(session, part, fp))) return { state: 'done', ticket };
  if (await bucket.head(jobKey(session, part, fp))) return { state: 'queued', ticket };
  await bucket.put(jobKey(session, part, fp), JSON.stringify({
    session, part, fp, model, prompt, lines, at: new Date().toISOString(),
  }), { httpMetadata: { contentType: 'application/json' } });
  return { state: 'queued', created: true, ticket };
}

/** 手机来取产物。`ticket` 由 `enqueue` 发,原样带回来。 */
export async function takeResult(bucket, { ticket }) {
  const got = await bucket.get(`${OUT_PREFIX}${ticket}.json`);
  if (got) return { state: 'done', body: await got.text() };
  if (await bucket.head(`${JOB_PREFIX}${ticket}.json`)) return { state: 'running' };
  return { state: 'none' };
}

/**
 * cron 一拍:把待办跑掉。
 *
 * @param call 注入的「把 prompt 送出去拿正文回来」。**注入而不是内联** ——
 *   这一层最该测的(幂等、认领、失败留痕)与真网络无关。
 */
export async function runPending(bucket, call, { now = () => Date.now(),
                                                 log = () => {},
                                                 // cron 传 STALE_MS(只当兜底);
                                                 // Mac daemon 那边不走这个函数。
                                                 staleAfterMs = 0 } = {}) {
  const listed = await bucket.list({ prefix: JOB_PREFIX, limit: 100 });
  let ran = 0, skipped = 0;
  for (const obj of listed.objects ?? []) {
    if (ran >= MAX_PER_TICK) break;
    const raw = await bucket.get(obj.key);
    if (!raw) continue;
    const job = await raw.json().catch(() => null);
    // 🔴 **两阶段的 job(`lines`)cron 跑不了,留给 Mac**(`M2-成7`)。
    // 它要跑 `worker/extract_two_stage.py`(候选块预切、逐块打标、event 派生),
    // 那是 Python;cron 上没有。**跳过而不是判失败** ——
    // 判失败会写一份错误产物,而手机会把它当成「抽完了」。
    // ⚠️ 代价说清楚:Mac 长期挂着时这些 job 没有兜底,会一直排着。
    // 那与声纹队列同一条取舍(单执行方),而「Mac 挂没挂」由心跳看得见。
    if (job?.lines && !job?.prompt) { skipped++; continue; }
    if (!job?.prompt) {
      // 读不懂的 job **不能留着**:它会让每一拍都白跑一遍 list。
      // 但也不能悄悄删 —— 删了就没人知道曾经有一块没抽成。
      await bucket.put(`${OUT_PREFIX}${obj.key.slice(JOB_PREFIX.length)}`,
                       JSON.stringify({ error: 'job 读不懂', raw_key: obj.key }));
      await bucket.delete(obj.key);
      log(`[extract-queue] ${obj.key} 读不懂,已判失败`);
      continue;
    }
    // 🔴 **兜底口径**:排了不够久的,留给主力(Mac daemon)。见 `STALE_MS`。
    if (staleAfterMs > 0) {
      const born = job.at ? Date.parse(job.at) : 0;
      if (!born || now() - born < staleAfterMs) { skipped++; continue; }
      log(`[extract-queue] 场次 ${job.session} 块 ${job.part} 排了太久,兜底接手`);
    }
    // 🔴 **认领**:两拍之间会重叠(一次抽取 243 秒 > 一拍 60 秒)。
    // 不认领的话第二拍会把同一个 job 再跑一遍 —— **而那一遍是真花钱的**。
    const claimedAt = job.claimed_at ? Date.parse(job.claimed_at) : 0;
    if (claimedAt && now() - claimedAt < CLAIM_TTL_MS) { skipped++; continue; }
    await bucket.put(obj.key, JSON.stringify({ ...job, claimed_at: new Date(now()).toISOString() }));

    try {
      const body = await call(job.prompt);
      // 🔴 **不是合法 JSON 就不能当正常产物存**(`M2-审11`)。
      // 存进去的话手机每次重试都拿到同一份坏结果:解析失败 → 记失败 → 再取 → 还是它,
      // **一直到重试上限,而模型一次都不会被重跑** —— 「坏结果永久复用」。
      // 存成带 `error` 的产物是刻意的:它让这一块**当场判死且看得见**,
      // 而不是悄悄重试到底。⚠️ 不留 job(留了下一拍会重新付费跑一遍确定性失败)。
      let parseError = null;
      try { JSON.parse(body); } catch (e) { parseError = String(e); }
      const stored = parseError === null
        ? body
        : JSON.stringify({ error: '模型输出不是合法 JSON', detail: parseError,
                           raw: String(body).slice(0, 2000) });
      await bucket.put(outKey(job.session, job.part, job.fp), stored,
                       { httpMetadata: { contentType: 'application/json' } });
      await bucket.delete(obj.key);
      ran++;
      log(parseError === null
        ? `[extract-queue] 场次 ${job.session} 块 ${job.part} 抽完`
        : `[extract-queue] 场次 ${job.session} 块 ${job.part} 输出不是 JSON,已判失败`);
    } catch (e) {
      // 失败留痕并**保留 job**:认领会过期,下一轮还能再试。
      // ⚠️ 不把失败写成产物 —— 写了手机就当它抽完了,而那是一份空纪要。
      await bucket.put(obj.key, JSON.stringify({
        ...job, claimed_at: new Date(now()).toISOString(),
        last_error: String(e), attempts: (job.attempts ?? 0) + 1,
      }));
      log(`[extract-queue] 场次 ${job.session} 块 ${job.part} 失败:${e}`);
    }
  }
  return { ran, skipped, pending: (listed.objects ?? []).length };
}

/**
 * 云代理 —— 持密钥、转发转写、记账。
 *
 * 技术方案(旧仓 `docs/技术方案-总体.md`)给它的定义就三句:
 * 「转发转写与 LLM 调用 · 持有模型密钥 · 成本记账」。这个文件不做别的。
 *
 * ## 主路径是文件端点,不是 SSE
 *
 * P4a 按人工逐行金标改判(2026-08-10):**文件端点一次拿到转写 + 分人标签**,
 * 而它自带的说话人标签在 20 字以上长句上错误率 **10%**(Mac 本地 pyannote 是 15%)——
 * 而产品要的表态与承诺都在长句里。SSE 退为兜底(只有文字,分人要 Mac 回流)。
 *
 * ## 为什么必须有 R2
 *
 * 文件端点**只吃公网可达的 URL**,不吃 base64。
 * 2026-08-13 实测:塞 `audio.data` 时提交返回 **200 + task_id**(看起来成功了),
 * 而查询阶段才报 `{"status":"FAILED","error":{"stage":"audio_download",
 * "message":"invalid audio url"}}`。
 * ⚠️ **「提交 200」不等于「收下了」** —— 按 200 就当成功写代码,是一条静默失败路径。
 *
 * 所以音频要先落到一个 StepFun 拉得到的地方。用 R2,而且**桶保持私有**:
 * 对外的可读地址由这个 Worker 自己发(`/audio/<key>?t=<token>`),
 * 不开公共桶 —— 桶一公开,任何人拿到 key 就能听你的录音。
 *
 * ## 为什么这个设计天然适配「真后台」
 *
 * 提交是**异步**的:交上去拿一个 task_id 就返回,不占长连接。
 * 手机被系统唤醒时轮询一次 query 即可 —— 正是 PRD §2.1 那条
 * 「靠可续跑而不是靠常驻」的落地形态。
 *
 * ## 为什么免费档跑得动
 *
 * Workers 免费档每次请求只有 **10ms CPU**。这里所有重活都是**流**:
 * 上传是 `env.BUCKET.put(key, request.body)`,回放是 `object.body` 直接返回 ——
 * 音频字节不进 Worker 内存,也不做 base64。submit/query 的载荷是几百字节的 JSON。
 */

import { appendUsage, buildRecord, fromOpenAIUsage } from './accounting.js';
import { readChatCompletion } from './chat_response.js';
import { streamJSONResult } from './json_stream.js';
import { claimKey, collect, pendingKey, PENDING_TTL_MS, resultKey,
         sweepResults, sweepStale, CLAIM_PREFIX, TRACE_PREFIX } from './collector.js';
import { summarize } from './usage.js';
// 云端抽取队列(M2-B8):手机排队 → cron 跑 → 手机取。
import { enqueue as queueEnqueue, takeResult as queueTake,
         runPending as queueRun, STALE_MS } from './extract_queue.js';
import { enqueue as vpEnqueue, takeResult as vpTake } from './voiceprint_queue.js';
// 场次级云端清除(M2-审12):界面承诺「都会删掉」,而在这之前云端一个都没删。
import { purgeSession, remaining as purgeRemaining } from './purge.js';
import { handleRecordingMemory } from './recording_memory.js';
import { handleInputMemory } from './input_memory.js';
// /agent/model 云隧道中继:MacBook 的模型调用经此转发到 mini 18791(记忆中枢,docs/intents/mac-memory-hub/)。
import { relayAgentModel } from './agent_relay.js';
import { storedStepXSeconds } from './stepx_audio.js';

/** 合法的音频键。**一个出处** —— 以前 `/upload` 有正则、`/asr/submit` 只看
 *  后缀,于是同一个「什么算合法」有两套答案,而对不上时两边都不报错
 *  (第四条铁律点名的形状)。长度上限也在这儿:R2 对象键上限 1024 字节,
 *  而认领对象是 `asr/claim/` + key + `.json`。 */
// ⚠️ **`+` 是 2026-08-24 补的,不是顺手放宽。** 底库快照的键带 ISO 时间戳
// (`…T17-05-00+08-00.json`),而 `+` 不在原来的字符集里 ⇒ 云代理判 400
// ⇒ 快照永远推不上去 ⇒ Mac 判不了任何一场,**而这只在真机上撞得到**。
// `worker/test_extract.mjs` 有一条对撞拿真实的快照键形状打这个正则。
const KEY_RE = /^[\w./+-]{1,200}$/;
const isLegalKey = (k) => typeof k === 'string' && KEY_RE.test(k);

// 🔴 **不用 `url.searchParams.get('key')`。**
//
// `URLSearchParams` 按 `application/x-www-form-urlencoded` 解,而那套编码里
// **`+` 表示空格**。可 key 是**不透明标识**,不是表单字段 —— 它里面的 `+`
// 就是一个加号(快照的 key 带 ISO 时间的时区偏移 `+08:00`)。
//
// 2026-08-25 实测:手机每一拍推底库快照都被这里判 400「key 缺失或不合法」,
// 而真相是 `…T16-37-00+08-00.json` 到这儿变成了 `…T16-37-00 08-00.json`,
// 空格不在 `KEY_RE` 里。⇒ `RemoteSnapshotStore` 那条路**一次都没成功过**,
// 而 `M2-认8` 之后快照是 **Mac 判决的输入** —— 推不上去 = Mac 一直拿旧底库判人,
// **两端都不报错**。
//
// 从原始 query 取,只做 `decodeURIComponent`:`%2B` 照样解成 `+`,
// 而裸 `+` 保持原样。发送方(手机)已经改成把 `+` 编码成 `%2B`,两边都对。
export function keyFromQuery(url) {
  const raw = url.search.slice(1).split('&').find((p) => p.startsWith('key='));
  if (!raw) return null;
  try { return decodeURIComponent(raw.slice(4)); } catch { return null; }
}

const ASR_SUBMIT = 'https://api.stepfun.com/v1/audio/asr/file/submit';
const ASR_QUERY  = 'https://api.stepfun.com/v1/audio/asr/file/query';
/** 兜底腿:SSE 只有文字,没有分人标签。用它意味着分人要走 Mac 回流。 */
const ASR_SSE = 'https://api.stepfun.com/step_plan/v1/audio/asr/sse';
const MODEL = 'stepaudio-2.5-asr';

/** ¥0.15/小时 —— 2026-08-06 用户确认的 StepAudio 2.5 实际价。 */
const ASR_CNY_PER_HOUR = 0.15;

/** DeepSeek 的 OpenAI 兼容端点。用它而不是 anthropic 兼容那条,是因为
 *  `accounting.js` 的 `fromOpenAIUsage` 修过 DeepSeek 特有的缓存口径坑,
 *  换一条协议那段修正就白写了。 */
const LLM_URL = 'https://api.deepseek.com/v1/chat/completions';

/** 服务商 → 端点 + 用哪把钥匙。**场景挑服务商,不是全局写死一个。**
 *  2026-08-21 加:抽取换 StepFun 之后,一个 `LLM_URL` 不够用了。 */
const PROVIDERS = {
  deepseek: { url: LLM_URL, keyEnv: 'DEEPSEEK_API_KEY' },
  // ⚠️ 路径是 `step_plan/v1`,不是常见的 `v1` —— 用户给的就是这条,实测通。
  stepfun:  { url: 'https://api.stepfun.com/step_plan/v1/chat/completions',
              keyEnv: 'STEPFUN_PLAN_API_KEY' },
  'deepseek-flash': { url: LLM_URL, keyEnv: 'DEEPSEEK_API_KEY', model: 'deepseek-flash' },
};

/**
 * 场景 → 模型。**手机不选模型**,只报场景。
 *
 * 手机选模型意味着换模型要发一版 App,而降本这件事必须能当天生效;
 * 顺带也堵住「业务代码里写死模型」(仓规 §五)。
 *
 * ⚠️ 这张表是 `shared/model_router.py` 的 `SCENE_ROUTES` 在手机侧的**镜像**,
 * 不是第二个真相源。改路由要两处一起改 —— **`test_extract.mjs`** 会逐场景对撞它俩,
 * 漂了就红(价表也在那里对撞,见下)。
 *
 * 🔴 ~~`test_scene_routes.mjs`~~ **那个文件从来不存在**(2026-08-18 复核发现)。
 * 这行字指着一道**不存在的闸**:去核实「是不是真的守着」的人会 grep 不到它,
 * 于是要么以为没人守、要么再造一个第二道。真正在守的是 `test_extract.mjs`,
 * 而 `model_router.py` 那侧写的一直是对的名字 —— **两处指着不同的文件名**,
 * 这才是最容易骗过复核的形态。
 *
 * ⚠️ **max_tokens 用 20000,不是 SCENE_ROUTES 里的 4000。**
 * 两处冲突,取后写且有实测的那个:`worker/extract.py` 写着「实测 8000 会被
 * thinking 吃光、返回空正文,**这是下限不是建议值**」。4000 拿到的是一份空正文,
 * 而空正文在下游长得和「这场没抽到内容」一模一样 —— 花了钱还看不出错。
 */
const SCENE_ROUTES = {
  // 2026-08-14 用户拍板降 flash。`model_router.py` 那条注释本来就写着
  // 「品味敏感,可 A/B 降 flash」—— 这次就是那个 A/B,只是先降了再量。
  // 为什么现在降:pro 的输出单价 $2.19/M 是 flash 的 5.2 倍,而抽取是
  // 「长输出 × 每场一次」,成本几乎全在输出上。按 pro 估一天 8 场约 ¥0.8–1.2,
  // 加上转写的 ¥0.73 **顶破 ¥1.5/天 的红线**;flash 之后余量很宽。
  // ⚠️ 够不够用由 M0-3d 那套判卷台说了算,不由这条注释说了算。要换回去改这一行,
  //    但**必须连 shared/model_router.py 一起改** —— 只改这里的话,判卷台量的
  //    就不是生产在跑的那个模型了(仓规:被测对象必须与生产同一条路由)。
  // 🔴 **2026-08-21 用户拍板换 StepFun**:`step-3.7-flash` @ `step_plan/v1`。
  // · **关不掉 thinking**(实测:回包带 `reasoning_content`)⇒ 只能把上限开高,
  //   不能像 DeepSeek 那样用 `reasoning_effort: "none"` 把它关掉;
  // · `max_tokens` 开到 **64000**(实测 32000/64000/128000 都接受)——
  //   用户原话「output 要开高点,不然很容易截断」。**它是上限不是花费。**
  // ⚠️ **它的用量分解不可信**:实测回包里有 `reasoning_content` 68 字符,
  //   而 `completion_tokens_details.reasoning_tokens` 报的是 **0**
  //   ⇒ 记账只能按 `completion_tokens` 总数算,别拿那个分解去拆思考与正文。
  // 2026-10-15 长短对照后选 Step 5 默认推理：低档长段漏明确工作要求；ASR 独立。
  extract: { provider: 'stepfun', model: 'step-5-preview', max_tokens: 64000 },
  // 两阶段抽取(`M2-成7`,v2.5 的新逻辑)。**与 `extract` 分开记账** ——
  // 阶段一是「逐块打标」(短输出 × 块数),阶段二是「块内抽取」(长输出),
  // 两者的降本着力点完全不同,混一个场景 `/usage` 就分不出是谁在烧钱。
  // ⚠️ 三处必须一致:这里 / `shared/model_router.py` / `worker/extract_two_stage.py`
  //   的 `S1_MAX_TOKENS`、`S2_MAX_TOKENS` —— test_extract.mjs 双向对撞前两处。
  extract_s1: { provider: 'stepfun', model: 'step-5-preview', max_tokens: 30000 },
  extract_s2: { provider: 'stepfun', model: 'step-5-preview', max_tokens: 30000 },
  // 自由提问(PRD §4.7.3,用户 2026-08-17 定为 M1)。
  // ⚠️ **单开一个场景,不复用 `extract` 也不挂旧仓的 `answer`** ——
  // 两笔钱要记得开:抽取是「每场一次的长输出」,提问是「随手问的短输出」,
  // 降本的着力点完全不同,混在一个场景里 `/usage` 就分不出是谁在烧钱。
  // ⚠️ `max_tokens` 同样取 20000 而不是 Python 侧的 4000 —— 理由见上面那段:
  // 8000 会被 thinking 吃光返回空正文。它是**上限不是花费**,答案短就花得少。
  ask: { model: 'deepseek-flash', max_tokens: 20000 },
  // 进展归属(M2-B3,2026-08-20)。**单开一个场景,不复用 `extract`**——
  // 与上面 `ask` 同一条理由:两笔钱要记得开。抽取是「把一场逐字稿压成结构化产物」,
  // 比对是「拿抽取产物去撞活跃的事」,输出量差着数量级;
  // 混在一个场景里 `/usage` 就分不出是谁在烧钱,而降本时最需要的正是这个分解。
  //
  // 🔴 **这一行与 `shared/model_router.py` 的 `"progress"` 是一对,两边必须同时有** ——
  // 只加这边的话,手机发过来会撞 `未知场景` 返 400(这条腿在生产上直接是死的);
  // 只加那边的话,判卷台量的就不是生产在跑的模型。`test_extract.mjs` 逐场景对撞它俩。
  progress: { model: 'deepseek-flash', max_tokens: 20000 },
};

export default {
  /**
   * Cron 每分钟跑一次:替手机盯着还没出结果的转写(见 `collector.js`)。
   *
   * ⚠️ **失败要喊出来。** cron 静默失败的表现是「转写永远不出结果」,
   * 而那和「上游很慢」在手机那头长得一模一样 —— 排查时无从下手。
   */
  async scheduled(event, env, ctx) {
    // 🔴 **抽取队列先跑,而且与收割器互不牵连**(`M2-B8`)。
    // 放在收割器的密钥闸**外面**:那道闸查的是 `STEPFUN_API_KEY`(转写用的),
    // 而抽取用的是另一把 —— 挤在闸里面的话,转写钥匙一没配,抽取也跟着不跑,
    // **而表现只是「纪要一直不出来」**,没有任何东西说得清为什么。
    if (env.AUDIO) {
      // ⚠️ **传 `staleAfterMs` = 降为兜底**(2026-08-21 用户拍板:Mac 是主力)。
      // 不传的话 Worker 会和 Mac daemon 抢同一个 job,而抢上的后果是**付两次钱**。
      ctx.waitUntil(queueRun(env.AUDIO,
        (prompt) => callScene(env, 'extract', [{ role: 'user', content: prompt }]),
        { log: (m) => console.log(m), staleAfterMs: STALE_MS }).then(
          (r) => r.pending && console.log(`[extract-queue] 待办 ${r.pending} · 本拍跑 ${r.ran}`),
          (e) => console.log(`[extract-queue] 整拍挂了:${e}`)));
    }

    if (!env.AUDIO || !env.STEPFUN_API_KEY) {
      console.log('[collector] 跳过:R2 或密钥没绑');
      return;
    }
    const fetchQuery = async (taskID) => {
      const r = await fetch(ASR_QUERY, {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.STEPFUN_API_KEY}`,
                   'Content-Type': 'application/json' },
        body: JSON.stringify({ task_id: taskID }),
      });
      return { ok: r.ok, status: r.status, body: await r.text() };
    };
    const out = await collect({ bucket: env.AUDIO, fetchQuery });
    console.log('[collector]', JSON.stringify(out));
    // 顺手扫掉过期结果 —— R2 没有 TTL,不扫就一直涨。
    ctx.waitUntil(sweepResults({ bucket: env.AUDIO }).then(
      (n) => n && console.log('[collector] 扫掉过期结果', n)));
    // 认领与痕迹同样没有 TTL,不扫就一直涨,**而涨到天荒地老也不会有东西红**
    // (第四条铁律)。认领的期限必须**大于**待办的 6 小时,否则会在任务还在跑时
    // 把锁扫掉、重新打开重复付费的窗口;取 24 小时,与结果同档。
    // 抽取的 job 与产物本来一个都不扫(`M2-审11`)—— R2 没有 TTL,不扫就一直涨,
    // 而「涨到天荒地老也不会有东西红」正是铁律 4 点名的形状。
    // 产物留 7 天:与音频保留期同一个数,手机取走之后没有人再需要它。
    ctx.waitUntil(sweepStale({ bucket: env.AUDIO, prefix: 'extract/out/',
                               ttlMs: 7 * 24 * 3600 * 1000 }).then(
      (n) => n && console.log(`[cron] 扫掉 ${n} 个过期抽取产物`)));
    ctx.waitUntil(sweepStale({ bucket: env.AUDIO, prefix: 'extract/jobs/',
                               ttlMs: 7 * 24 * 3600 * 1000 }).then(
      (n) => n && console.log(`[cron] 扫掉 ${n} 个过期抽取 job`)));
    ctx.waitUntil(sweepStale({ bucket: env.AUDIO, prefix: CLAIM_PREFIX,
                               ttlMs: 24 * 3600 * 1000 }).then(
      (n) => n && console.log('[collector] 扫掉过期认领', n)));
    // 痕迹是排查用的,留得比音频保留期(7 天)久没有意义。
    ctx.waitUntil(sweepStale({ bucket: env.AUDIO, prefix: TRACE_PREFIX,
                               ttlMs: 7 * 24 * 3600 * 1000 }).then(
      (n) => n && console.log('[collector] 扫掉过期痕迹', n)));
  },

  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === '/health') {
      // 只报「有没有」,永远不报值 —— 排查时要知道哪一样没绑上,而不是它是什么。
      // ⚠️ 曾经在这里加过 tokenLen 排查(它抓到了剪贴板被覆盖导致 token 长度 92≠64),
      //    查完立刻删掉了:这个地址公网可达,泄露密钥长度是白送的攻击面。
      //
      // `tokenOK`:调用方**带了**令牌时才出现,报它对不对。
      // 为什么必须有这一项:`/health` 本身不要门禁(不然配错了连诊断都做不了),
      // 于是「探活通了」只证明 worker 那边有令牌,**不证明手机填的这个对**。
      // 贴错的话探活照样绿,要等第一次真上传才 401 —— 而那时用户已经以为配好了。
      // 不增加攻击面:打 /upload 看 401 还是 400 本来就能试出同样的信息。
      const given = request.headers.get('X-Growth-Token');
      return json({ ok: true, hasKey: !!env.STEPFUN_API_KEY,
                    stepxAudioFormats: ['wav','m4a'],
                    hasLLMKey: !!env.DEEPSEEK_API_KEY,
                    hasBucket: !!env.AUDIO, hasClientToken: !!env.CLIENT_TOKEN,
                    hasAgentTunnel: !!env.AGENT_TUNNEL_URL,
                    ...(given == null ? {} : { tokenOK: given === env.CLIENT_TOKEN }) });
    }

    // 音频回放。**StepFun 来拉的就是这个地址** —— 所以它不能要 X-Growth-Token
    // (对方不会带),改用地址里那个一次性 token 认。
    if (path.startsWith('/audio/')) return serveAudio(request, env, url);

    // 其余接口都要门禁。这个地址公网可达,没门禁等于把转写额度挂在门外。
    if (!env.CLIENT_TOKEN || request.headers.get('X-Growth-Token') !== env.CLIENT_TOKEN) {
      return json({ error: 'unauthorized' }, 401);
    }
    if (path.startsWith('/recording-memory/')) return handleRecordingMemory(request, env, url);
    if (path.startsWith('/input-memory/')) return handleInputMemory(request, env, url);
    // 对账口。**GET**,放在 POST-only 之前 —— 它是给人在浏览器里看的。
    // 仓规原则 5「没入账的开销等于不存在」,而写得进读不出来离「不存在」只差一步。
    // 提交痕迹。**写得进读不出来离「不存在」只差一步**(`usage.js` 开头那段话,
    // 同一个道理)—— 这条口存在的全部理由就是让 08-18 那种事故第二次发生时
    // 能当场问出「请求到没到我这儿」。
    if (path === '/trace') {
      if (!env.AUDIO) return json({ error: 'R2 没绑' }, 500);
      const day = url.searchParams.get('day') ?? new Date().toISOString().slice(0, 10);
      // **一次 list 读完**(痕迹写在 customMetadata 里)。逐条 get 会按
      // 「1 + N 个子请求」计,提交多的那天正好把这条排查口自己打挂。
      const listed = await env.AUDIO.list({ prefix: `${TRACE_PREFIX}${day}/`,
                                            limit: 1000, include: ['customMetadata'] });
      // 读不出来的要数出来,不能当它不存在 —— 和账本那口同一条纪律。
      const out = (listed.objects ?? []).map(
        (o) => o.customMetadata ?? { key: o.key, unreadable: true });
      out.sort((a, b) => String(a.at).localeCompare(String(b.at)));
      return json({ day, count: out.length,
                    truncated: !!listed.truncated, submits: out });
    }

    // 线上跑的到底是哪一版源码。**这是一道对撞的一半**(另一半在
    // `scripts/check_worker_deployed.sh`):判据是「线上 == 仓库 HEAD 的
    // `worker/src` 树哈希」,对不上即红。
    //
    // 🔴 **为什么必须有这个口**(M1-35,2026-08-20 真吃过亏):
    // `M1-34` 防收割器覆盖的闸提交于 08-19 傍晚,而当天最后一次部署在 13:47 ——
    // 晚了四五个小时,于是**源码里有、线上没有**。后果不是抽象的:
    // 两块已经靠 SSE 出稿的音频被 6 小时兜底覆盖成「asr timeout 判失败」。
    // 那期间 commit 绿、`worker/` 47 条测试绿、`premerge` 绿 —— **没有任何东西会红**。
    //
    // ⚠️ 取的是 `worker/src` 的**树哈希**,不是 HEAD 的 commit sha:
    // 后者会因为任何无关改动而变,天天红的闸会被人开始跳过,等于没有闸。
    if (path === '/version') {
      return json({ src_sha: env.WORKER_SRC_SHA ?? null });
    }

    if (path === '/usage') {
      return json(await summarize({ bucket: env.AUDIO,
                                    day: url.searchParams.get('day') ?? undefined }));
    }

    if (request.method !== 'POST') return json({ error: 'POST only' }, 405);

    // ⚠️ 密钥检查**按路由分**,不在这儿一刀切。
    // 以前这里统一挡 STEPFUN_API_KEY,那对 /extract 是错的:它用的是
    // DeepSeek 那把,而报出来的是「STEPFUN_API_KEY 没配」—— 排查方向全错。
    switch (path) {
      case '/upload': return upload(request, env, url);
      case '/asr/submit': return needKey(env, 'STEPFUN_API_KEY') ?? submit(request, env, ctx, url);
      case '/asr/query':  return needKey(env, 'STEPFUN_API_KEY') ?? query(request, env);
      case '/asr/sse':    return needKey(env, 'STEPFUN_API_KEY') ?? sse(request, env, ctx);
      // ⚠️ **钥匙检查挪进 `extract()` 里按场景查**(2026-08-21):抽取换 StepFun 之后,
      // 在这儿一刀切挡 `DEEPSEEK_API_KEY` 会让「抽取」被一把它根本不用的钥匙挡下 ——
      // 而报出来的名字还是错的,排查的人会去看错的配置(这一坑上面 ASR 那条注释里踩过一次)。
      case '/extract':    return extract(request, env, ctx);
      // 记忆中枢中继(Mac mini 大管家):验过门禁后原样透传到 mini,见 agent_relay.js 的三条铁律。
      case '/agent/model': return relayAgentModel(request, env);
      // 云端抽取队列(M2-B8)。手机醒来几秒就够,4.8 分钟的抽取交给云端 cron。
      case '/extract/enqueue': return extractEnqueue(request, env);
      case '/extract/result':  return extractResult(request, env);
      case '/session/purge':   return sessionPurge(request, env);
      case '/voiceprint/enqueue': return voiceprintEnqueue(request, env);
      case '/voiceprint/result':  return voiceprintResult(request, env);
      default: return json({ error: 'not found' }, 404);
    }
  },
};

// ── 上传:流进 R2,不进内存 ────────────────────────────────────────

async function upload(request, env, url) {
  if (!env.AUDIO) return json({ error: 'R2 没绑 —— 见 wrangler.toml 的 r2_buckets' }, 500);
  const key = keyFromQuery(url);
  if (!isLegalKey(key)) {
    return json({ error: 'key 缺失或不合法' }, 400);
  }
  if (key.startsWith('stepx/') && key.endsWith('.m4a')) return json({ error: 'use_stepx_validated_upload' },400);
  // body 是流,直接落桶 —— 音频字节不经过 Worker 的内存。
  await env.AUDIO.put(key, request.body);
  return json({ key, playbackToken: await signKey(key, env) });
}

/**
 * 把桶里的对象读出来给 StepFun。**桶保持私有**,靠地址里的 token 认。
 *
 * token = HMAC(key),同一个 key 永远同一个 token。够用的理由:
 * key 里带随机的场次/块标识,猜不到;而这个地址只在一次转写的窗口里被用到。
 * ⚠️ 它不是长期凭证 —— 别拿它当分享链接用。
 */
async function serveAudio(request, env, url) {
  if (!env.AUDIO) return new Response('no bucket', { status: 500 });
  const key = decodeURIComponent(url.pathname.slice('/audio/'.length));
  const token = url.searchParams.get('t');
  if (!token || token !== await signKey(key, env)) {
    return new Response('forbidden', { status: 403 });
  }
  const obj = await env.AUDIO.get(key);
  if (!obj) return new Response('not found', { status: 404 });
  return new Response(obj.body, {
    headers: { 'Content-Type': key.endsWith('.m4a') ? 'audio/mp4' : key.endsWith('.wav') ? 'audio/wav' : 'audio/mpeg', 'Content-Length': String(obj.size) },
  });
}

async function signKey(key, env) {
  const data = new TextEncoder().encode(key + '|' + (env.CLIENT_TOKEN || ''));
  const digest = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(digest)].slice(0, 16)
    .map(b => b.toString(16).padStart(2, '0')).join('');
}

// ── 提交转写 ──────────────────────────────────────────────────

/**
 * 手机传 `{key, seconds}`;这里拼出 StepFun 要的形状并提交。
 *
 * 载荷形状是**探出来的**,不是猜的(2026-08-13,六轮 4xx 才定位):
 *   · `model_name` 在 **`request`** 里,不在顶层、不在 audio 下 —— 放错就报 model "" 不存在
 *   · `audio.format` 是**字符串** `"mp3"`,不是 `{"type":"mp3"}`
 *   · 分人要**两个开关同时开**:`enable_speaker_info` + `show_utterances`
 */
/**
 * 每一次到达的提交都留一条痕,**成功、复用、失败一视同仁**。(2026-08-19)
 *
 * 🔴 为什么必须包含成功那一档:只在失败时留痕的话,「没有痕迹」有**两种**含义 ——
 * 「请求根本没到中转站」和「到了而且成了」。而 08-18 那次事故要判的恰恰是这个:
 * 手机报超时,我们分不出请求走到哪儿了。一条路径一种含义,才问得出答案。
 *
 * 与账本(`usage/`)的分工:账本记**花掉的钱**,只有真提交才有;
 * 这里记**发生过的请求**,复用与失败也有。两者故意不合并 ——
 * 合并之后「复用」要么污染账、要么在痕迹里消失。
 */
async function traceSubmit(env, ctx, rec) {
  const line = { at: new Date().toISOString(), ...rec };
  console.log('[submit]', JSON.stringify(line));
  if (!env.AUDIO) return;
  const day = line.at.slice(0, 10);
  const nonce = crypto.randomUUID().slice(0, 8);
  // 🔴 **痕迹同时写进 customMetadata**,`/trace` 才能靠**一次 list** 读完。
  // 逐条 `get` 的写法(我的第一版)在**提交次数多的那天**会撞免费档的子请求
  // 上限 —— 而那正是最需要这条口的一天。`collector.js` 里 `MAX_PER_RUN = 20`
  // 就是按同一套账算出来的。
  const meta = {};
  for (const [k, v] of Object.entries(line)) {
    if (v != null) meta[k] = String(v).slice(0, 180);
  }
  // 留痕失败不许把提交本身弄失败 —— 钱可能已经花了。记一行日志就够。
  ctx.waitUntil(env.AUDIO
    .put(`${TRACE_PREFIX}${day}/${line.at.replace(/[:.]/g, '-')}-${nonce}.json`,
         JSON.stringify(line),
         { httpMetadata: { contentType: 'application/json' }, customMetadata: meta })
    .catch((e) => console.log('[submit] 痕迹没落盘:', String(e))));
}

async function submit(request, env, ctx, url) {
  const started = Date.now();
  const { key, seconds = 0 } = await request.json().catch(() => ({}));
  if (!key) return json({ error: '缺 key' }, 400);

  // 🔴 **必须是 wav。** 2026-08-17 实测:传 m4a 而声明 `format:"mp3"` 时,
  // StepFun 读出了正确的时长(音频确实拉到了)、`result` 却是 `[{}]` ——
  // 一个字都没有。对格式撒谎的代价不是报错,是**静默的空结果**。
  // 而 `docs/evidence/p4a/run_asr_file.py`(P4a 真跑通过)写着:
  // 「喂 wav 别喂 mp3:有损压缩会把说话人并少(实测 3→2)」。
  //
  // 在这儿挡一道:键不是 .wav 就直接拒。**契约要被执行,不能只被假设** ——
  // 假设的话,手机哪天改回 m4a,表现又是「转写回来是空的」,而没人会想到是格式。
  if (!isLegalKey(key)) {
    return json({ error: 'key 不合法' }, 400);
  }
  const compressed = /^stepx\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9a-f-]{36}-[0-9a-f]{64}\.m4a$/.test(key);
  if (compressed) {
    const object = await env.AUDIO?.head(key);
    const actual = storedStepXSeconds(object, key);
    if (actual === null || actual > 600 || Math.ceil(actual) !== Number(seconds)) return json({ error: 'invalid_stepx_aac_receipt' }, 400);
  }
  if (!key.endsWith('.wav') && !compressed) {
    return json({ error: `只收 wav:${key} —— 手机侧要先转 16k 单声道 16bit PCM` }, 400);
  }

  // 🔴 **同一块音频,同一时刻只许有一个在跑的转写任务。**(2026-08-19)
  //
  // 手机侧的去重凭据是「拿到过 task_id」,所以它挡不住**提交成功但回执丢了**
  // 这一种 —— 而那恰恰是最常发生的一种:跨境这一跳超时,任务已经建好、钱已经花了,
  // 手机什么都没拿到,下一轮原样再提交一次。
  //
  // 判据不用 TTL 猜:认领里存着 task_id,而 `asr/pending/<task_id>.json`
  // 在 collector 判出终态时会被删掉。**待办还在 = 那个任务还在跑 = 复用它**;
  // 待办没了 = 已经有终态了 = 这次是真的要重转(用户点了「再试一次」),照常提交。
  if (env.AUDIO) {
    const claimed = await env.AUDIO.get(claimKey(key));
    if (claimed) {
      const prior = await claimed.json().catch(() => null);
      // ⚠️ **锁自己要有上限。** 待办删不掉时(cron 早退、delete 一直失败)
      // 这块音频会永远拿回同一个 task_id,而手机再没有任何办法强制重转。
      // 这里的 TTL **不是判据**(判据仍是「待办还在不在」),是**上限** ——
      // 超过 6 小时,collector 本来就会把待办强制判死,锁没有理由还立着。
      const age = Date.parse(prior?.submitted_at ?? '') || 0;
      const fresh = age > 0 && (Date.now() - age) < PENDING_TTL_MS;
      if (prior?.task_id && fresh && await env.AUDIO.head(pendingKey(prior.task_id))) {
        // **不记账** —— 这一次没有向上游提交,没花钱。记了的话账本会把
        // 一次省下来的钱记成花掉的,而账本是判「值不值」的唯一依据。
        // 但**要留痕**:「这次复用了」是排查时最需要的一句话。
        await traceSubmit(env, ctx, { key, verdict: 'reused', task_id: prior.task_id,
                                      ms: Date.now() - started });
        return json({ task_id: prior.task_id, reused: true });
      }
    }
  }

  const audioURL = `${url.origin}/audio/${encodeURIComponent(key)}?t=${await signKey(key, env)}`;
  const payload = {
    // 形状照参考实现逐字段抄,不自己发挥
    audio: compressed ? { format: 'm4a', channel: 1, url: audioURL }
      : { format: 'wav', codec: 'raw', rate: 16000, bits: 16, channel: 1, url: audioURL },
    request: {
      model_name: MODEL,
      show_utterances: true,        // 不开它,分人标签不会出现在分句上
      enable_speaker_info: true,    // 主路径的价值全在这一个开关上
    },
  };

  // 上游这一跳单独计时:手机报「超时」时,要能分出**是我们等上游等久了**,
  // 还是请求压根没到这儿。两者的修法完全不同。
  const upstreamAt = Date.now();
  let resp, text;
  try {
    resp = await fetch(ASR_SUBMIT, {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.STEPFUN_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    text = await resp.text();
  } catch (e) {
    // 打不通上游。以前这里什么都不留 —— 手机看到的是超时,而云端一片空白。
    await traceSubmit(env, ctx, { key, verdict: 'upstream_threw', error: String(e),
                                  upstream_ms: Date.now() - upstreamAt,
                                  ms: Date.now() - started });
    return json({ error: 'submit failed', reason: String(e) }, 502);
  }
  const upstreamMs = Date.now() - upstreamAt;
  if (!resp.ok) {
    // ⚠️ 非 2xx 的正文必须带出去。旧仓踩过:只报「502 Bad Gateway」,
    //    而真因(api key 是 undefined)就写在正文里,被扔了。
    // ⚠️ **500 时正文是空的,真因在响应头里**(P4a 踩过,见 run_asr_file.py 的 _err)。
    //    只带正文的话看到的是一个空 body,而 Trpc-Error-Msg 里写着到底怎么了。
    await traceSubmit(env, ctx, { key, verdict: 'upstream_error', status: resp.status,
                                  body: text.slice(0, 300), upstream_ms: upstreamMs,
                                  ms: Date.now() - started });
    return json({ error: 'submit failed', status: resp.status, body: text.slice(0, 2000),
                  trpc: resp.headers.get('Trpc-Error-Msg'),
                  trace: resp.headers.get('X-Trace-Id') }, 502);
  }

  // 🔴 **落一条待办,交给 Cron 去盯。**(2026-08-17 用户拍板)
  // 原来是手机自己轮 —— 而手机会熄屏、会被切走、被 iOS 掐着后台配额,
  // 实测的形态是「点完结束得把 App 开着盯到出稿」。云代理是这条链上
  // 唯一一直醒着的东西,让它去盯,手机醒来取一次就行。
  //
  // 待办里存的是**手机认识的那个 task_id**,不是我们自己编的 —— 手机拿它来查。
  const taskID = (() => { try { const j = JSON.parse(text);
    return (j.data || j).task_id || (j.data || j).id; } catch { return null; } })();

  // 🔴 **从这一行往下,钱已经花了(上游已经 2xx、任务已经建好)。**
  // 所以下面每一步都必须满足一条:**失败可以,抛出去不行。**
  //
  // 这不是洁癖。`await` 的两个 put 一旦抛出,`submit` 整个抛 → 返 500 →
  // 账没记(仓规「没入账的开销等于不存在」)、痕没留(而 `/trace` 存在的
  // 全部理由就是消除「没痕迹」的二义性)、认领没落盘 → 手机拿到 500 会退避
  // 重试 → **同一块第二次付费**。方向正好和这道闸要挡的事相反。
  //
  // (对抗审查 2026-08-19 抓到的:我在 100 行之上刚给 trace 写过
  //  「留痕失败不许把提交本身弄失败 —— 钱可能已经花了」,转头对同样处在
  //  「钱已花」之后的这两个 put 做了完全相反的处置。)
  let putError = null;
  if (taskID && env.AUDIO) {
    // `await` 而不是 `waitUntil`:回话**之前**落盘,才能保证「客户端拿到
    // task_id」时认领一定已经在了。`await` 留着,抛出去挡掉。
    //
    // ⚠️ 这一条**有测试守着**(`test_submit_idempotency.mjs`,改回 `waitUntil`
    // 会红两条)。我一开始写过「没有测试守着」——那句话是错的,错在假桶的
    // `put` 是同步的,不是这条性质测不出来。保真度不够的假件会让一整类断言恒真。
    const meta = { task_id: taskID, key, seconds, submitted_at: new Date().toISOString() };
    const body = { httpMetadata: { contentType: 'application/json' } };
    try {
      await env.AUDIO.put(pendingKey(taskID), JSON.stringify(meta), body);
      await env.AUDIO.put(claimKey(key), JSON.stringify(meta), body);
    } catch (e) {
      putError = String(e);
      console.log('[submit] 幂等对象没落盘(本次提交照常返回):', putError);
    }
  }

  const costCNY = (Number(seconds) / 3600) * ASR_CNY_PER_HOUR;
  // `audioSec` 给 null 而不是 0:时长不知道就是不知道,记 0 会让账面上多出一次
  // 「免费的转写」。见 accounting.js 里 DURATION_PRICED 那段。
  ctx.waitUntil(logUsage(env, buildRecord({
    scene: 'asr', model: MODEL, audioSec: Number(seconds) || null,
    at: new Date().toISOString(),
  }), { op: 'submit', key }));
  // 痕迹里带上闸有没有立住 —— 「痕迹说成功了而认领其实没落盘」是新的二义性,
  // 而这条口存在的理由就是消灭二义性。
  await traceSubmit(env, ctx, { key, verdict: 'ok', task_id: taskID, seconds: Number(seconds) || null,
                                upstream_ms: upstreamMs, ms: Date.now() - started,
                                claim_ok: !putError, put_error: putError });
  return new Response(text, {
    status: 200,
    headers: { 'Content-Type': 'application/json', 'X-Growth-Cost-CNY': costCNY.toFixed(6) },
  });
}

/**
 * 查结果。
 *
 * ⚠️ **「HTTP 200」不等于「成功」。** 实测:载荷不对时提交返回 200 + task_id,
 * 而失败要到这里才以 `{"status":"FAILED","error":{...}}` 的形式出现。
 * 所以这里把 FAILED 显式翻成非 2xx —— 让调用方没机会把它当成功。
 */
async function query(request, env) {
  const body = await request.text();

  // 🔴 **先看 Cron 收好的结果。** 有就直接给 —— 不碰上游、零等待。
  // 这是「手机不用一直开着」的全部意义:手机睡多久都不丢,醒来一取就有。
  // 收不到才回落去问上游(Cron 还没跑到、或刚提交完手机就来查)。
  const asked = (() => { try { const j = JSON.parse(body); return j.task_id || j.id; }
                         catch { return null; } })();
  if (asked && env.AUDIO) {
    const cached = await env.AUDIO.get(resultKey(asked));
    if (cached) {
      const saved = await cached.json().catch(() => null);
      if (saved?.verdict === 'failed') {
        return json({ error: 'asr failed', detail: saved.body ?? null, from: 'collector' }, 502);
      }
      if (saved?.body) {
        return new Response(saved.body, {
          status: 200,
          headers: { 'Content-Type': 'application/json', 'X-Growth-From': 'collector' },
        });
      }
    }
  }

  const resp = await fetch(ASR_QUERY, {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.STEPFUN_API_KEY}`, 'Content-Type': 'application/json' },
    body,
  });
  const text = await resp.text();
  if (!resp.ok) {
    return json({ error: 'query failed', status: resp.status, body: text.slice(0, 2000),
                  trpc: resp.headers.get('Trpc-Error-Msg'),
                  trace: resp.headers.get('X-Trace-Id') }, 502);
  }

  let parsed;
  try { parsed = JSON.parse(text); } catch { return new Response(text, { status: 200 }); }
  // ⚠️ **这个接口没有 status=SUCCESS 那种终态**(2026-08-17 实测:完成的回复形如
  // `{"duration":270.14,"result":[…]}`,一个 status 字段都没有)。
  // 所以这里只翻**明确的失败**,完成与否交给手机按「result 出现没有」判 ——
  // 在这儿猜一个终态,等于给下游一个它没法验证的结论。
  const st = String(parsed?.status ?? '').toUpperCase();
  if (['FAIL', 'ERROR', 'BLOCK'].some((k) => st.includes(k))) {
    return json({ error: 'asr failed', detail: parsed.error ?? parsed ?? null }, 502);
  }
  return new Response(text, { status: 200, headers: { 'Content-Type': 'application/json' } });
}

// ── 兜底腿:SSE(只有文字,没有分人)────────────────────────────

/**
 * 文件端点失败时走这里。调用方发来的就是 StepFun 要的完整载荷(base64 由调用方做),
 * 这里只加钥匙、body 当流穿过去 —— CPU 几乎为零。
 *
 * ⚠️ 走到这条腿意味着**这一块没有分人标签**(实测:SSE 流里 `speaker` 出现 0 次)。
 * 按 `M1-34`(2026-08-19 拍板)这个降级**必须在界面上看得见** ——
 * 不可见的话「上游没给分人」与「这一场只有一个人说话」在库里长得一模一样。
 *
 * 🔴 ~~实测约 15% 的场次会落到这里,而且重试救不了(是内容特性不是偶发)。~~
 * **2026-08-19 标作废:查无出处。** 全仓 `grep asr/sse` 至今**零调用方**,
 * 那个 15% 不可能是这条腿量出来的。而 `M1-34` 的触发因子是**上游端点故障**,
 * 与「内容特性」无关 —— 照着这句去估兜底命中率会估错一个数量级。
 * 谁把出处找回来了就把这句改回去,别再原样引用。
 *
 * ⚠️ 调用方是 **Mac**(`M1-34`):它有 ffmpeg,把 R2 那块 WAV 转 mp3 再来。
 * Worker 不碰音频字节 —— 这是它能留在免费档的原因(cron CPU 上限 10ms,
 * 而「读 10.5MB + base64」实测 49ms)。
 */
async function sse(request, env, ctx) {
  const seconds = Number(request.headers.get('X-Audio-Seconds') || 0);
  const resp = await fetch(ASR_SSE, {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.STEPFUN_API_KEY}`, 'Content-Type': 'application/json' },
    body: request.body,
  });
  if (!resp.ok) {
    const body = await resp.text().catch(() => '');
    return json({ error: 'sse failed', status: resp.status, body: body.slice(0, 2000) }, 502);
  }
  const costCNY = (seconds / 3600) * ASR_CNY_PER_HOUR;
  ctx.waitUntil(logUsage(env, buildRecord({
    scene: 'asr', model: MODEL, audioSec: seconds || null,
    at: new Date().toISOString(),
  }), { op: 'sse' }));
  const h = new Headers(resp.headers);
  h.set('X-Growth-Cost-CNY', costCNY.toFixed(6));
  return new Response(resp.body, { status: resp.status, headers: h });
}

// ── 抽取(LLM)────────────────────────────────────────────────

/**
 * 抽取转发。手机送 `{scene, messages}`,**模型由这里定**(见 `SCENE_ROUTES`)。
 *
 * ## 为什么 prompt 由手机渲染,不由这里渲染
 *
 * prompt 是**契约**(§4.2 那份 JSON 的字段与硬要求),它已经有两份实现要对齐了
 * (`worker/extract.py` 与手机侧)。在这里再写一份就是第三份,而这一份还没人测。
 * 这里只管路由与记账 —— 这个文件的自我定义就是「转发 + 记账,不做别的」。
 *
 * ## 为什么现在是同步调用
 *
 * 推理档一次可能跑很久,而同步调用一旦超时就是**钱花了、结果丢了**。
 * 但「多久」现在是猜的:所以先同步接上,把 `elapsed_ms` 记进账,
 * **拿真实测量决定要不要改成流式**。没量到数就先上流式,是拿复杂度换一个想象中的风险。
 */
async function extract(request, env, ctx) {
  if (request.headers.get('accept') === 'application/x-ndjson') {
    return streamJSONResult((signal, diagnostics) => extractJSON(request, env, ctx, signal, diagnostics), ctx);
  }
  return extractJSON(request, env, ctx);
}

async function extractJSON(request, env, ctx, signal, diagnostics) {
  const body = await request.json().catch(() => ({}));
  const { scene, messages } = body;


  // 不认识的场景**直接拒**,不回落到某个默认模型。回落的后果是一笔
  // 记不进任何场景的钱 —— 而拆场景的全部意义就是「降本时知道该降哪一笔」。
  const route = SCENE_ROUTES[scene];
  if (!route) {
    return json({ error: `未知场景 ${scene};已知:${Object.keys(SCENE_ROUTES).join(', ')}` }, 400);
  }
  if (!Array.isArray(messages) || messages.length === 0) {
    return json({ error: '缺 messages' }, 400);
  }

  // ✅ **抽取闸已于 2026-08-21 撤掉。**
  // 关它的理由是 DeepSeek 上「¥0.24/小时,全时录音下是预算两倍」(见 `M2-成1`);
  // 用户当天拍板改用 StepFun `step-3.7-flash`(价表里是免费额度档)⇒ 那条理由不再成立。
  // ⚠️ **不是「问题解决了」,是「换了一条计价不同的路」** —— 免费额度用完之后
  // 账本会继续记 ¥0(价表 `step-3.7-flash: [0,0,0]`),而那时的账是假的。
  // 见 `M2-成1` 里那条待办。

  const startedAt = Date.now();
  // 场景挑服务商;没写 provider 的照旧走 deepseek(不改动既有场景的行为)。
  // 🔴 **调用方可以覆盖 provider**(`M2-成7`:两阶段双败换 deepseek-flash 兜底)。
  // 允许它是对的 —— 记账记的是**实际用的 model**,兜底那次真的走了别的模型,
  // 账上就该是别的模型;写死场景默认会让兜底那笔记成 StepFun,而那是假账。
  // ⚠️ 不认识的名字**拒**,不回落 —— 回落的后果是一笔记不进任何场景的钱。
  const overrideName = typeof body.provider === 'string' ? body.provider : null;
  if (overrideName && !PROVIDERS[overrideName]) {
    return json({ error: `未知 provider ${overrideName};已知:${Object.keys(PROVIDERS).join(', ')}` }, 400);
  }
  const provider = PROVIDERS[overrideName ?? route.provider ?? 'deepseek'];
  const model = provider.model ?? (overrideName === 'deepseek' ? 'deepseek-flash' : route.model);
  const apiKey = env[provider.keyEnv];
  if (!apiKey) {
    // 缺哪把钥匙就报哪把 —— 报错了另一把的话,排查的人会去看错的配置。
    return json({ error: `${provider.keyEnv} 没配` }, 500);
  }
  const unknownFailure = async error => {
    const record = buildRecord({ scene, model, at: new Date().toISOString() });
    record.cost_usd = null; record.usage_unknown = true;
    const elapsedMs = Date.now() - startedAt;
    const accounting = await logUsage(env, record, { elapsed_ms: elapsedMs });
    return json({ error, accounting, elapsed_ms: elapsedMs }, 502);
  };
  let resp;
  try {
    resp = await fetch(provider.url, {
      signal,
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model,
        messages,
        max_tokens: route.max_tokens,
        stream: model === 'step-5-preview',
        ...(model === 'step-5-preview' && route.reasoning_effort ? { reasoning_effort: route.reasoning_effort } : {}),
      }),
    });
  } catch {
    return unknownFailure('llm 连接中断或超时');
  }
  if (!resp.ok) {
    const text = await resp.text();
    // 非 2xx 的正文必须带出去 —— 真因(比如 api key 是 undefined)就写在里面。
    return json({ error: 'llm failed', status: resp.status,
                  body: text.slice(0, 2000), elapsed_ms: Date.now() - startedAt }, 502);
  }

  let parsed;
  try { parsed = await readChatCompletion(resp, diagnostics); }
  catch { return unknownFailure('llm 回复读取失败或不是 JSON'); }
  const elapsedMs = Date.now() - startedAt;

  const record = buildRecord({
    scene,
    model: parsed.model ?? model,
    // 口径换算收在 fromOpenAIUsage 里 —— DeepSeek 的 prompt_tokens 含缓存命中,
    // 直接塞进 input_tokens 会把命中那部分按「未命中价 + 命中价」收两遍。
    usage: fromOpenAIUsage(parsed.usage),
    at: new Date().toISOString(),
  });
  if (parsed.usage_unknown) { record.cost_usd = null; record.usage_unknown = true; }
  const accounting = await logUsage(env, record, { elapsed_ms: elapsedMs });
  if (parsed.stream_error) return json({ error: parsed.stream_error, accounting, elapsed_ms: elapsedMs }, 502);
  if (parsed.model && parsed.model !== model) {
    return json({ error: 'llm 返回模型与路由不一致', model, upstream_model: parsed.model,
                  accounting, elapsed_ms: elapsedMs }, 502);
  }

  // 正文可能是空的 —— **那是一种已发生过的失败**(max_tokens 被 thinking 吃光),
  // 不是「这场没抽到内容」。在这里就翻成非 2xx,不让手机把它当成功。
  const content = parsed.choices?.[0]?.message?.content ?? '';
  if (!content.trim()) {
    return json({ error: 'llm 返回空正文 —— max_tokens 可能被 thinking 吃光(§4.2)',
                  finish_reason: parsed.choices?.[0]?.finish_reason ?? null,
                  usage: parsed.usage ?? null, accounting, elapsed_ms: elapsedMs }, 502);
  }

  return json({ content, model, upstream_model: parsed.model ?? null, usage: parsed.usage ?? null,
                accounting, elapsed_ms: elapsedMs });
}

/** 手机把一块渲染好的 prompt 排进队列(`M2-B8`)。**幂等**,重复排不会多花钱。 */
async function extractEnqueue(request, env) {
  if (!env.AUDIO) return json({ error: 'R2 没绑' }, 500);
  const { session, part = 0, prompt, lines } = await request.json().catch(() => ({}));
  // 两条料二选一(`M2-成7`):`prompt` = v1 单次调用;`lines` = 两阶段(只有 Mac 跑得了)。
  if (!session || (!prompt && !Array.isArray(lines))) {
    return json({ error: '缺 session,以及 prompt 或 lines 之一' }, 400);
  }
  // 模型 id 进指纹(`M2-审11`):同一份料换了模型就是另一个答案,
  // 共用一个键的话新模型一次都跑不到。**取 `SCENE_ROUTES`,不写死** —— 写死就是第二个出处。
  // 两阶段用 s2 的模型:s1/s2 现在同一个,将来分开时**这里要跟着分**,
  // 否则换了 s2 的模型而指纹不变,手机会取到上一版产物,两头都不报错。
  const model = lines ? `${SCENE_ROUTES.extract_s1.model}|${SCENE_ROUTES.extract_s2.model}` : SCENE_ROUTES.extract.model;
  return json(await queueEnqueue(env.AUDIO, { session, part, prompt, lines, model }));
}

// ── 声纹队列(M2-认8):Worker 只中转,永远不判 —— 见 voiceprint_queue.js 头 ──

async function voiceprintEnqueue(request, env) {
  if (!env.AUDIO) return json({ error: 'R2 没绑' }, 500);
  const body = await request.json().catch(() => ({}));
  const { session, model, lines } = body;
  // 契约把关在门口:缺 model 的 job Mac 侧会拒(空间对不上判了也是错的),
  // 与其让它排进去烂在队列里,不如 400 当场说清。
  if (!session || !model || !Array.isArray(lines) || !lines.length) {
    return json({ error: '缺 session / model / lines' }, 400);
  }
  return json(await vpEnqueue(env.AUDIO, { session, payload: body }));
}

async function voiceprintResult(request, env) {
  if (!env.AUDIO) return json({ error: 'R2 没绑' }, 500);
  const { session } = await request.json().catch(() => ({}));
  if (!session) return json({ error: '缺 session' }, 400);
  const r = await vpTake(env.AUDIO, { session });
  return json(r, r.state === 'done' ? 200 : 202);
}

/**
 * 移出记忆:把这一场在云上的副本删干净(`M2-审12`)。
 *
 * 🔴 **删完必须回读一遍再说「删干净了」。** `delete` 不报错不等于对象没了 ——
 * 分页漏了一半、前缀差一个字符,两种都不抛。手机侧本地音频那半已经这么做了,
 * 云端这半照搬同一条纪律:还剩东西就返 500 **并把剩下的键名带回去**,
 * 让手机那句「已删完」说不出口。
 */
async function sessionPurge(request, env) {
  if (!env.AUDIO) return json({ error: 'R2 没绑' }, 500);
  const { session, transcripts = [], tasks = [] } = await request.json().catch(() => ({}));
  if (!session) return json({ error: '缺 session' }, 400);
  if (!Array.isArray(transcripts) || !Array.isArray(tasks)) {
    return json({ error: 'transcripts / tasks 必须是数组' }, 400);
  }
  const args = { session, transcripts, tasks };
  const deleted = await purgeSession(env.AUDIO, args);
  const left = await purgeRemaining(env.AUDIO, args);
  if (left.length) {
    return json({ error: '删完回读还有剩', remaining: left, deleted }, 500);
  }
  return json({ ok: true, deleted });
}

/** 手机来取一块的产物。 */
async function extractResult(request, env) {
  if (!env.AUDIO) return json({ error: 'R2 没绑' }, 500);
  const { ticket } = await request.json().catch(() => ({}));
  // `ticket` 是 `/extract/enqueue` 发的不透明串(`M2-审11`)。手机不自己拼键 ——
  // 拼键就要在 Swift 里再算一遍指纹,而两侧算得不一样时的表现是「永远取不到产物」。
  if (!ticket || !/^[\w.-]{1,200}$/.test(ticket)) {
    return json({ error: '缺 ticket 或不合法(它由 /extract/enqueue 返回)' }, 400);
  }
  const r = await queueTake(env.AUDIO, { ticket });
  // 「还在跑」不是错 —— 用 202 让手机一眼分得开「等着」与「出事了」。
  return json(r, r.state === 'done' ? 200 : 202);
}

/**
 * 送一次 LLM 并记一笔账,**返回正文**(不是 Response)。
 *
 * 🔴 **cron 队列与 `/extract` 必须走同一段代码。** 另写一份的话,记账口径、
 * 场景路由、空正文的判定会各自漂 —— 而漂了之后**账本上看不出来**:
 * 云端跑的那一半悄悄记进另一个口径,降本时拿到的分解是假的(铁律 4)。
 *
 * 与 `/extract` 的唯一区别是**出错时抛而不是返 Response** ——
 * 队列那边要靠抛出来决定「留着 job 下一轮再试」。
 */
async function callScene(env, scene, messages) {
  const route = SCENE_ROUTES[scene];
  if (!route) throw new Error(`未知场景 ${scene}`);
  const provider = PROVIDERS[route.provider ?? 'deepseek'];
  const apiKey = env[provider.keyEnv];
  if (!apiKey) throw new Error(`${provider.keyEnv} 没配`);
  const startedAt = Date.now();
  const resp = await fetch(provider.url, {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: route.model, messages,
                           max_tokens: route.max_tokens, stream: route.model === 'step-5-preview',
                           ...(route.reasoning_effort ? { reasoning_effort: route.reasoning_effort } : {}) }),
  });
  if (!resp.ok) throw new Error(`llm ${resp.status}: ${(await resp.text()).slice(0, 500)}`);
  const parsed = await readChatCompletion(resp);
  const record = buildRecord({ scene, model: parsed.model ?? route.model,
                                    usage: fromOpenAIUsage(parsed.usage),
                                    at: new Date().toISOString() });
  if (parsed.usage_unknown) { record.cost_usd = null; record.usage_unknown = true; }
  await logUsage(env, record, { elapsed_ms: Date.now() - startedAt });
  if (parsed.stream_error) throw new Error(parsed.stream_error);
  if (parsed.model && parsed.model !== route.model) {
    throw new Error(`llm 返回模型 ${parsed.model} 与路由 ${route.model} 不一致`);
  }
  const content = parsed.choices?.[0]?.message?.content ?? '';
  // 空正文是**一种已发生过的失败**(max_tokens 被 thinking 吃光),不是「这场没内容」。
  // 抛出去,让 job 留着重试 —— 写成产物的话手机会把空纪要当成抽完了。
  if (!content.trim()) {
    throw new Error(`llm 返回空正文(finish=${parsed.choices?.[0]?.finish_reason})`);
  }
  return content;
}

// ── 记账 ──────────────────────────────────────────────────────

/** 缺密钥时的 400 级回复;不缺返回 null(调用点用 `?? handler()` 串起来)。 */
function needKey(env, name) {
  // 密钥没配要**明说**。含糊地返 401 会让人以为是门禁问题,排查方向全错。
  return env[name] ? null : json({ error: `${name} 没配 —— wrangler secret put ${name}` }, 500);
}

/**
 * 记一笔,**落 R2**(§2.2 二选一定死的那条,不是 KV、不是 console)。
 *
 * ⚠️ 2026-08-14 修:`091afaa` 把这里换成了 `console.log` + 一个 binding 一直
 * 注释着的 KV,后果是「记账代码在跑、账一条都没落盘」—— 只活在 `wrangler tail`
 * 的输出里,关掉终端就没了。仓规原则 5:没入账的开销等于不存在。
 *
 * 一条记录一个对象,不是读-改-写一个日报文件:Worker 是并发的,读-改-写撞上
 * 就丢记录,而丢的恰好是账。
 *
 * **写失败不吞、也不装作没花钱**:返回 `persisted:false` 连同整条 record 给手机,
 * 让它有第二次机会记下来。
 */
async function logUsage(env, record, extra = {}) {
  const line = { ...record, ...extra };
  console.log('[usage]', JSON.stringify(line));
  if (!env.AUDIO) return { persisted: false, record: line, error: 'R2 没绑' };
  const nonce = crypto.randomUUID().slice(0, 8);
  const r = await appendUsage(env.AUDIO, line, nonce);
  if (!r.persisted) console.log('[usage] R2 写失败:', r.error);
  return r;
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status, headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}

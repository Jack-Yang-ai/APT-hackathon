// StepAudio 2.5 ASR 的 SSE 客户端(M0-9b)。
//
// 契约来源是**现役、在跑**的 `mac/asr_stepfun.py:34-36,158-220` —— 不是文档转述,
// 也不是我按 OpenAI 习惯猜的。M0-9 那版猜错了五处(端点/模型名/请求形状/参数位置/
// 响应解析),而它的验收当时是绿的:绿的是「链路跑通」,不是「上游接受这个形状」。

/** 端点优先 step_plan,失败回落非 plan 的 /v1。两个都收 JSON + base64。
 *
 * 两条路径是**契约的一部分**(主 + 兜底),不是配置项,所以写死;
 * 而 host 从 `ASR_BASE_URL` 来 —— 指到 127.0.0.1 就能起个假上游把链路走通,
 * 这是 M0-9 就有的设计,别在重写时把它弄丢。 */
export const ASR_PATHS = [
  "/step_plan/v1/audio/asr/sse",
  "/v1/audio/asr/sse",
];

export const asrURLs = (baseURL = "https://api.stepfun.com") =>
  ASR_PATHS.map((p) => `${baseURL.replace(/\/$/, "")}${p}`);

export const ASR_MODEL = "stepaudio-2.5-asr";

/** `format.type` 的闭集。
 *
 * ⚠️ 只有 mp3 与 pcm 是 `mac/asr_stepfun.py` 实际跑过的(`_build_payload`)。
 *
 * ~~手机录的是 **AAC/m4a**,而 Worker 里没有 ffmpeg —— 这条缝没合上。~~
 * 🔴 **2026-08-19 作废:那个前提早就消失了**(仓规 6)。
 * `index.js` 的 `upload` 现在**硬挡非 `.wav` 的键**,R2 里躺的全是
 * 16k/16bit 单声道 WAV(手机侧 `WavExport` 转好才传)⇒ **没有 m4a 这回事了**。
 * 留着这句的代价很具体:`M1-34` 要做 SSE 兜底时,读到它会以为**根本做不了**。
 *
 * ⇒ 兜底的执行方是 **Mac**(`M1-34`,2026-08-19 拍板):它有 ffmpeg,
 * 把 R2 里那块 WAV 转 mp3 再走 SSE。**Worker 不碰音频字节**,
 * 这也是它能留在免费档的原因(所有重活都是流,见 `index.js` 开头)。
 *
 * 这里**不猜**:传个没验过的 type 上去,上游要么报错要么静默给出空转写,
 * 后者会被当成「这段没人说话」,是最贵的那种。 */
export const SUPPORTED_FORMATS = new Set(["mp3", "pcm"]);

export class ASRError extends Error {
  constructor(message, { status = null, detail = null } = {}) {
    super(message);
    this.status = status;
    this.detail = detail;
  }
}

/** 按 `_build_payload` 的形状组请求体。mp3 不带 rate/bits/channel(仅 pcm 必填)。 */
export function buildPayload(dataB64, {
  format = "mp3", language = "zh", enableTimestamp = true, enableITN = true,
} = {}) {
  if (!SUPPORTED_FORMATS.has(format)) {
    throw new ASRError(
      `format.type=${format} 不在验过的闭集 ${[...SUPPORTED_FORMATS].join("/")} 里。` +
      `手机录的是 m4a,而 Worker 里没有 ffmpeg —— 这条缝还没合上,别在这里猜一个 type 上去`);
  }
  const formatBlock = format === "mp3"
    ? { type: "mp3" }
    : { type: "pcm", codec: "pcm_s16le", rate: 16000, bits: 16, channel: 1 };

  return {
    audio: {
      data: dataB64,
      input: {
        transcription: {
          model: ASR_MODEL,
          language,
          enable_itn: enableITN,
          enable_timestamp: enableTimestamp,
        },
        format: formatBlock,
      },
    },
  };
}

/** 把 SSE 的字节流切成一个个 JSON 事件。
 *
 * 规则照 `_iter_sse_events`:连续的 `data:` 行拼成一个事件,空行分隔,
 * `:` 开头是心跳,`[DONE]` 不是 JSON。**跨 chunk 的半行必须留到下一块**——
 * Workers 的 ReadableStream 在任意字节处切,按 chunk 直接 split 会把一个事件劈成两半。 */
export function* parseSSEChunk(state, chunk) {
  state.buffer += chunk;
  const lines = state.buffer.split("\n");
  state.buffer = lines.pop() ?? "";        // 最后一段可能是半行,留着

  for (const raw of lines) {
    const line = raw.replace(/\r$/, "");
    if (line === "") {
      const payload = state.data.join("\n").trim();
      state.data = [];
      if (payload && payload !== "[DONE]") {
        try { yield JSON.parse(payload); } catch { /* 不是完整 JSON 就丢这一个事件 */ }
      }
      continue;
    }
    if (line.startsWith(":")) continue;    // 心跳
    if (line.startsWith("data:")) state.data.push(line.slice(5).replace(/^ /, ""));
  }
}

export const newSSEState = () => ({ buffer: "", data: [] });

/** 事件类型。**必须按它分流**:同一条流里既有字级 delta,也有一条带全文的 done。
 * 不分流就会把全文再拼一遍 —— 实测 5 秒音频出来的是「他就是有花香。他就是有花香。」,
 * HTTP 200、测试全绿、文本是错的。 */
export const DELTA_TYPE = "transcript.text.delta";
export const DONE_TYPE = "transcript.text.done";

/** 从 delta 事件里读字级文本与时间戳。字段名按文档,做兜底读取。 */
export function extractSegment(event) {
  if (event.type && event.type !== DELTA_TYPE) return null;
  const text = event.delta || event.text || "";
  if (!text) return null;
  return {
    text,
    start_ms: event.start_time ?? event.start ?? null,
    end_ms: event.end_time ?? event.end ?? null,
  };
}

/** 组装整段文本。口径与 `mac/asr_stepfun.py::_post_sse` 一致:
 * **`done` 的 text 优先,拼 delta 是兜底。**
 *
 * 两头都要防:
 * · 短音频的 `done` **会**回全文(实测 5 秒),只拼 delta 再加上它 = 文本翻倍;
 * · 长音频的 `done` **不回**全文(`_post_sse` 注释写死),只认 done = 拿到空文本,
 *   而空文本不会报错,会被下游当成「这段没人说话」。 */
/** 事件路由 + 收集。**index.js 与测试共用这一份** ——
 * 测试里另抄一遍路由的话,打的是测试自己的副本:实测中把
 * `extractSegment` 的 type 过滤删掉,测试竟然还是绿的。 */
export const newCollector = () => ({ segments: [], doneText: "" });

export function collectEvent(c, event) {
  if (event.type === DONE_TYPE) { c.doneText = event.text || ""; return c; }
  const seg = extractSegment(event);
  if (seg) c.segments.push(seg);
  return c;
}

export const collected = (c) => assemble(c.segments, c.doneText);

export function assemble(segments, doneText = "") {
  return {
    text: doneText || segments.map((s) => s.text).join(""),
    segments,
  };
}

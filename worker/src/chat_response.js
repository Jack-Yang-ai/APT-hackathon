/** Step 5 上游用 SSE 保持连接；外部抽取接口仍只交付最终完整 JSON。 */
export async function readChatCompletion(response, diagnostics) {
  if (!response.headers.get('content-type')?.includes('text/event-stream')) {
    return JSON.parse(await response.text());
  }
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let pending = [], pendingChars = 0, data = [], content = '', model = null, usage = null;
  let finish = null, done = false, error = null, bytes = 0, eventChars = 0, identityUnknown = false;
  if (diagnostics) Object.assign(diagnostics, { bytes: 0, chunks: 0, frames: 0, max_frame_chars: 0, content_chars: 0 });
  const fail = (reason) => { error ??= reason; };
  const event = () => {
    if (!data.length) return;
    const text = data.join('\n'); data = []; eventChars = 0;
    if (diagnostics) { diagnostics.frames++; diagnostics.max_frame_chars = Math.max(diagnostics.max_frame_chars, text.length); }
    if (text === '[DONE]') { done = true; return; }
    if (done) { fail('结束标记后仍有数据'); return; }
    let chunk;
    try { chunk = JSON.parse(text); } catch { fail('上游SSE帧不是JSON'); return; }
    if (!chunk || typeof chunk !== 'object' || Array.isArray(chunk)) { fail('上游SSE帧无效'); return; }
    if (chunk.error) fail('上游SSE返回错误');
    if (chunk.model != null) {
      if (typeof chunk.model !== 'string' || !chunk.model) { fail('上游SSE模型无效'); identityUnknown = true; }
      else {
        if (model && model !== chunk.model) { fail('上游SSE模型不一致'); identityUnknown = true; }
        model ??= chunk.model;
      }
    }
    if (chunk.usage != null) {
      if (typeof chunk.usage !== 'object' || Array.isArray(chunk.usage)) fail('上游SSE用量无效');
      else usage = chunk.usage;
    }
    if (!Array.isArray(chunk.choices ?? [])) { fail('上游SSE候选无效'); return; }
    for (const choice of chunk.choices ?? []) {
      if (!choice || typeof choice !== 'object' || Array.isArray(choice)) { fail('上游SSE候选无效'); continue; }
      if (choice.index != null && choice.index !== 0) { fail('上游SSE返回多个候选'); continue; }
      if (choice.delta != null && (typeof choice.delta !== 'object' || Array.isArray(choice.delta))) {
        fail('上游SSE增量无效'); continue;
      }
      const part = choice.delta?.content;
      if (part != null && typeof part !== 'string') { fail('上游SSE正文类型无效'); continue; }
      if (finish != null && part) { fail('上游SSE结束后仍有正文'); continue; }
      if (part) content += part;
      if (choice.finish_reason != null) {
        if (typeof choice.finish_reason !== 'string' || (finish != null && finish !== choice.finish_reason)) {
          fail('上游SSE结束状态冲突');
        } else finish ??= choice.finish_reason;
      }
    }
  };
  const line = (raw) => {
    const text = raw.replace(/\r$/, '');
    if (!text) event();
    else if (text.startsWith('data:')) {
      eventChars += text.length;
      if (eventChars > 1024 * 1024) { fail('上游SSE事件超出上限'); return; }
      data.push(text.slice(5).replace(/^ /, ''));
    }
  };
  // 大帧可能按极小网络块到达。仅扫描本次解码的文字，完整行到齐才join；
  // 反复拼接／扫描整个未完成行会在长推理帧上形成二次方开销。
  const feed = (text) => {
    let from = 0, end;
    while ((end = text.indexOf('\n', from)) >= 0) {
      const part = text.slice(from, end);
      pendingChars += part.length;
      if (pendingChars > 1024 * 1024) { fail('上游SSE行超出上限'); return false; }
      pending.push(part); line(pending.join('')); pending = []; pendingChars = 0;
      from = end + 1;
    }
    const tail = text.slice(from);
    if (tail) { pending.push(tail); pendingChars += tail.length; }
    if (pendingChars > 1024 * 1024) { fail('上游SSE行超出上限'); return false; }
    return true;
  };
  let reader;
  try {
    if (response.body) {
      try {
        const byob = response.body.getReader({ mode: 'byob' });
        if (typeof byob.readAtLeast === 'function') reader = byob;
        else byob.releaseLock();
      } catch { /* Node／非字节流不支持，仍用原读取与全部校验。 */ }
      reader ??= response.body.getReader();
    }
    if (!reader) fail('上游SSE缺响应流');
    while (reader && !done) {
      // Cloudflare原生聚合小包，减少逐token唤醒JS；EOF不足一批仍会交付。
      const { value, done: eof } = typeof reader.readAtLeast === 'function'
        ? await reader.readAtLeast(16384, new Uint8Array(16384)) : await reader.read();
      if (eof) break;
      bytes += value.byteLength;
      if (diagnostics) { diagnostics.bytes = bytes; diagnostics.chunks++; }
      const decoded = decoder.decode(value, { stream: true });
      if (bytes > 64 * 1024 * 1024 || decoded.length > 1024 * 1024 || content.length > 1024 * 1024) {
        fail('上游SSE超出响应上限'); await reader.cancel(); break;
      }
      if (!feed(decoded)) { await reader.cancel(); break; }
      if (diagnostics) diagnostics.content_chars = content.length;
      if (content.length > 1024 * 1024) { fail('上游SSE正文超出上限'); await reader.cancel(); break; }
    }
    feed(decoder.decode());
    if (pending.length) line(pending.join(''));
    event();
    if (done) await reader?.cancel();
  } catch { fail('上游SSE连接中断或UTF8无效'); }
  finally { reader?.releaseLock(); }
  if (content.length > 1024 * 1024) fail('上游SSE正文超出上限');
  if (!done || finish !== 'stop') fail('上游SSE未正常结束');
  if (!model) fail('上游SSE缺实际模型');
  const tokenCount = value => Number.isSafeInteger(value) && value >= 0;
  if (usage && (!tokenCount(usage.prompt_tokens) || !tokenCount(usage.completion_tokens)
      || [usage.prompt_cache_hit_tokens, usage.prompt_cache_miss_tokens,
          usage.prompt_tokens_details?.cached_tokens].some(value => value != null && !tokenCount(value))
      || (usage.prompt_cache_hit_tokens ?? usage.prompt_tokens_details?.cached_tokens ?? 0) > usage.prompt_tokens)) {
    fail('上游SSE用量无效'); usage = null;
  }
  return { model, usage, choices: [{ message: { content }, finish_reason: finish }],
           stream_error: error, usage_unknown: !usage || !model || identityUnknown };
}

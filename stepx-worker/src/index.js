// StepX transport adapter. Model selection, ASR jobs and accounting remain in Growth.
// This worker owns only /stepx/*, so deploying it cannot replace the native app's worker.
import { claimKey, resultKey, PENDING_TTL_MS } from '../../worker/src/collector.js';
import { m4aInfo, m4aSourceSeconds, storedStepXSeconds } from '../../worker/src/stepx_audio.js';
import { RecordingCoordinator } from './recording_coordinator.js';
const UPSTREAM = 'https://apt-backend.example';
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const AUDIO_KEY = new RegExp(`^stepx/${UUID}/${UUID}/${UUID}-[0-9a-f]{64}\\.(wav|m4a)$`);
const SESSION = new RegExp(`^stepx_${UUID}_${UUID}$`);
const TICKET = new RegExp(`^stepx_${UUID}_${UUID}-[0-9]{1,6}-[0-9a-f]{16}$`);
export const STREAM_RECIPE = 'v3-semantic-continuity';
export const ACTION_PROTOCOL = 'personal-actions/v1';
const TASK = /^[a-zA-Z0-9_-]{1,160}$/;
const JSON_LIMIT = 256 * 1024;
const AUDIO_LIMIT = 20 * 1024 * 1024;
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Growth-Token',
  'Access-Control-Max-Age': '600',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
};
const ROUTES = new Set(['/health', '/version', '/chat', '/upload', '/asr/submit', '/asr/query', '/extract/enqueue', '/extract/result', '/recording-memory/sync',
  '/background/claim','/background/piece','/background/capture','/background/control','/background/status','/background/artifact','/background/revoke']);

class Failure extends Error {
  constructor(code, status = 400) { super(code); this.status = status; }
}
const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { ...CORS, 'Content-Type': 'application/json' },
});
async function authorized(given, expected) {
  if (!given || !expected) return false;
  const digest = async value => new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
  const [a, b] = await Promise.all([digest(given), digest(expected)]);
  let different = 0;
  for (let i = 0; i < a.length; i++) different |= a[i] ^ b[i];
  return different === 0;
}
async function readBounded(request, max) {
  const declared = request.headers.get('Content-Length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > max)) throw new Failure('payload_too_large', 413);
  if (!request.body) throw new Failure('empty_body');
  const reader = request.body.getReader();
  const chunks = []; let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > max) { await reader.cancel(); throw new Failure('payload_too_large', 413); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}
async function readJson(request, limit = JSON_LIMIT) {
  if (!(request.headers.get('Content-Type') ?? '').toLowerCase().startsWith('application/json')) throw new Failure('json_required', 415);
  const bytes = await readBounded(request, limit);
  let value;
  try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
  catch { throw new Failure('invalid_json'); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Failure('invalid_json');
  return value;
}
function only(body, names) {
  if (Object.keys(body).some(name => !names.includes(name))) throw new Failure('unexpected_field');
}
function requireString(value, max, code) {
  if (typeof value !== 'string' || !value.trim() || value.length > max) throw new Failure(code);
  return value;
}
function key(value) {
  if (typeof value !== 'string' || !AUDIO_KEY.test(value)) throw new Failure('invalid_stepx_audio_key');
  return value;
}
function submissionBody(body) {
  only(body, ['key', 'seconds', 'retryFailed', 'retryId']); key(body.key);
  if (!Number.isFinite(body.seconds) || body.seconds <= 0 || body.seconds > 601) throw new Failure('invalid_duration');
  if (body.retryFailed !== undefined && typeof body.retryFailed !== 'boolean') throw new Failure('invalid_retry');
  if (body.retryId !== undefined && (body.retryFailed !== true || typeof body.retryId !== 'string'
    || !new RegExp(`^${UUID}$`).test(body.retryId))) throw new Failure('invalid_retry');
}
export function wavDuration(bytes) {
  if (bytes.byteLength < 44) throw new Failure('wav_required');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const text = (start, length) => String.fromCharCode(...bytes.subarray(start, start + length));
  if (text(0, 4) !== 'RIFF' || text(8, 4) !== 'WAVE' || text(12, 4) !== 'fmt '
    || text(36, 4) !== 'data' || view.getUint32(16, true) !== 16
    || view.getUint16(20, true) !== 1 || view.getUint16(22, true) !== 1
    || view.getUint32(24, true) !== 16000 || view.getUint32(28, true) !== 32000
    || view.getUint16(32, true) !== 2 || view.getUint16(34, true) !== 16
    || view.getUint32(4, true) !== bytes.byteLength - 8
    || view.getUint32(40, true) !== bytes.byteLength - 44
    || (bytes.byteLength - 44) % 2 !== 0) throw new Failure('wav_16k_mono_pcm16_required');
  const seconds = (bytes.byteLength - 44) / 32000;
  if (seconds <= 0 || seconds > 601) throw new Failure('audio_duration_out_of_range');
  return seconds;
}

function asrState(receipt) {
  if (!receipt || typeof receipt !== 'object' || receipt.error || receipt.data?.error) return 'invalid';
  const result = receipt.data && typeof receipt.data === 'object' ? receipt.data : receipt;
  const state = String(result.status ?? '').toUpperCase();
  if (['FAIL', 'ERROR', 'BLOCK'].some(code => state.includes(code))) return 'failed';
  if (['RUNNING', 'PENDING', 'QUEUED', 'PROCESSING', 'IN_PROGRESS'].includes(state)) return 'waiting';
  // The Growth ASR contract uses presence of result, including [], as terminal.
  if (Array.isArray(result.result)) return 'done';
  return state ? 'waiting' : 'invalid';
}

export function createBridge(fetchUpstream = fetch) {
  return {
    async fetch(request, env) {
      const url = new URL(request.url);
      const route = url.pathname.startsWith('/stepx/') ? url.pathname.slice(6) : '';
      if (!ROUTES.has(route)) return json({ error: 'not_found' }, 404);
      if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
      if (!env.GROWTH_CLIENT_TOKEN) return json({ error: 'connection_not_configured' }, 503);
      if (!await authorized(request.headers.get('X-Growth-Token'), env.GROWTH_CLIENT_TOKEN)) return json({ error: 'unauthorized' }, 401);
      const upstream = async (path, payload, contentType = 'application/json', method = 'POST') => {
        const call = env.GROWTH_UPSTREAM ? (url, init) => env.GROWTH_UPSTREAM.fetch(new Request(url, init)) : fetchUpstream;
        const response = await call(UPSTREAM + path, {
          method, redirect: 'manual', signal: AbortSignal.timeout(path === '/extract' ? 180000 : 90000),
          headers: { 'X-Growth-Token': env.GROWTH_CLIENT_TOKEN, ...(method === 'POST' ? { 'Content-Type': contentType } : {}) },
          ...(method === 'POST' ? { body: payload } : {}),
        });
        return response;
      };
      try {
        if (route === '/version') {
          if (request.method !== 'GET') return json({ error: 'get_required' }, 405);
          return json({ source: env.STEPX_SRC_SHA ?? null });
        }
        if (route === '/health') {
          if (request.method !== 'GET') return json({ error: 'get_required' }, 405);
          const response = await upstream('/health', undefined, undefined, 'GET');
          if (!response.ok) throw new Failure('upstream_unavailable', 502);
          const health = await response.json();
          if (health.tokenOK !== true) throw new Failure('upstream_auth_failed', 502);
          return json({ ok: true, chatConfigured: health.hasLLMKey === true,
            asrConfigured: health.hasKey === true && health.hasBucket === true,
            extractionQueueConfigured: health.hasBucket === true,
            audioFormats: health.stepxAudioFormats?.includes('m4a') ? ['wav','m4a'] : ['wav'],
            semanticRecipe: STREAM_RECIPE,
            backgroundConfigured:!!env.RECORDING_JOBS && !!env.RECORDING_PRODUCER_TOKEN,
            source: env.STEPX_SRC_SHA ?? null });
        }
        if (request.method !== 'POST') return json({ error: 'post_required' }, 405);
        let response;
        if (route === '/upload') {
          const audioKey = key(url.searchParams.get('key'));
          const bytes = await readBounded(request, AUDIO_LIMIT);
          let durationSec;
          const compressed = audioKey.endsWith('.m4a');
          try { durationSec = compressed ? m4aSourceSeconds(m4aInfo(bytes), Number(url.searchParams.get('frames'))) : wavDuration(bytes); }
          catch (error) { throw new Failure(error.message); }
          const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(b => b.toString(16).padStart(2, '0')).join('');
          if (!audioKey.endsWith(`-${hash}.${compressed ? 'm4a' : 'wav'}`)) throw new Failure('audio_fingerprint_mismatch');
          if (compressed) {
            if (!env.AUDIO) throw new Failure('audio_storage_not_configured', 503);
            const saved = await env.AUDIO.put(audioKey, bytes, { onlyIf: { etagDoesNotMatch: '*' }, httpMetadata: { contentType: 'audio/mp4' }, customMetadata: {
              audioFormat: 'm4a', profile: 'apt.aac-lc-16k-mono/1', sourceFrames: String(Math.round(durationSec * 16000)), sha256: hash,
            } });
            const object = saved ?? await env.AUDIO.head(audioKey);
            if (storedStepXSeconds(object, audioKey) !== durationSec || object.size !== bytes.length)
              throw new Failure('audio_identity_conflict',409);
            return json({ key: audioKey, durationSec });
          }
          response = await upstream(`/upload?key=${encodeURIComponent(audioKey)}`, bytes, 'audio/wav');
          if (!response.ok) throw new Failure('upload_failed', response.status === 401 ? 401 : 502);
          const receipt = await response.json();
          if (receipt.key !== audioKey) throw new Failure('invalid_upload_receipt', 502);
          return json({ key: audioKey, durationSec });
        }
        const body = await readJson(request, ['/recording-memory/sync','/background/claim','/background/control'].includes(route) ? 8 * 1024 * 1024 : JSON_LIMIT);
        if(route.startsWith('/background/')) {
          if(!env.RECORDING_JOBS||!env.RECORDING_PRODUCER_TOKEN)throw new Failure('background_not_configured',503);
          if(![body.device_id,body.recording_id,body.generation].every(value=>typeof value==='string'&&new RegExp('^'+UUID+'$').test(value)))throw new Failure('invalid_background_identity');
          const stub=env.RECORDING_JOBS.get(env.RECORDING_JOBS.idFromName(body.device_id+'/'+body.recording_id));
          const result=await stub.fetch(new Request('https://recording.internal/'+route.slice('/background/'.length),{
            method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}));
          return json(await result.json(),result.status);
        }
        if (route === '/recording-memory/sync') {
          only(body, ['schema', 'device_id', 'records']);
          if (body.schema !== 'apt.recording-memory.batch/1' || !new RegExp('^' + UUID + '$').test(body.device_id ?? '')
            || !Array.isArray(body.records) || !body.records.length || body.records.length > 2000) throw new Failure('invalid_recording_batch');
          // Shared Worker owns schema validation, versions, canonical fingerprints and exact receipts.
          response = await upstream('/recording-memory/sync', JSON.stringify(body));
          if (response.status >= 300 && response.status < 400) throw new Failure('unexpected_redirect', 502);
          const value = await response.json();
          return json(value, response.status);
        }
        if (route === '/chat') {
          only(body, ['messages']);
          if (!Array.isArray(body.messages) || !body.messages.length || body.messages.length > 20) throw new Failure('invalid_messages');
          const messages = body.messages.map(message => {
            if (!message || !['system', 'user', 'assistant'].includes(message.role)) throw new Failure('invalid_message_role');
            only(message, ['role', 'content']);
            return { role: message.role, content: requireString(message.content, 32000, 'invalid_message_content') };
          });
          if (messages.reduce((sum, message) => sum + message.content.length, 0) > 64000) throw new Failure('messages_too_long', 413);
          response = await upstream('/extract', JSON.stringify({ scene: 'ask', messages }));
          if (!response.ok) throw new Failure('chat_failed', response.status === 401 ? 401 : 502);
          const reply = await response.json();
          const text = requireString(reply.content, 200000, 'empty_reply');
          return json({ text });
        }
        if (route === '/asr/submit') {
          submissionBody(body);
          if (!env.AUDIO) throw new Failure('audio_storage_not_configured', 503);
          const object = await env.AUDIO.head(body.key);
          const seconds = storedStepXSeconds(object, body.key);
          if (seconds === null) throw new Failure('uploaded_audio_missing', 409);
          if (seconds <= 0 || seconds > 601) throw new Failure('invalid_duration');
          if (!env.SUBMISSIONS) throw new Failure('submission_storage_not_configured', 503);
          const stub = env.SUBMISSIONS.get(env.SUBMISSIONS.idFromName(body.key));
          return await stub.fetch(new Request('https://submission.internal/submit', {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
          }));
        } else if (route === '/asr/query') {
          only(body, ['task_id']);
          if (typeof body.task_id !== 'string' || !TASK.test(body.task_id)) throw new Failure('invalid_task_id');
          response = await upstream('/asr/query', JSON.stringify(body));
        } else if (route === '/extract/enqueue') {
          only(body, ['session', 'part', 'lines']);
          if (typeof body.session !== 'string' || !SESSION.test(body.session)) throw new Failure('invalid_stepx_session');
          if (!Number.isSafeInteger(body.part) || body.part < 0 || body.part > 999999) throw new Failure('invalid_part');
          if (!Array.isArray(body.lines) || !body.lines.length || body.lines.length > 2000) throw new Failure('invalid_lines');
          const ids = new Set();
          for (const [index,line] of body.lines.entries()) {
            if (!line || typeof line !== 'object' || Array.isArray(line)) throw new Failure('invalid_line');
            only(line, ['line_id', 'text', 'cluster_tag', 't_sec', 't_end_sec', 'is_gap',
              ...(index===0?['recipe', 'streaming', 'stream_context','action_protocol','action_only','action_request','source_revision']:[])]);
            if (!Number.isSafeInteger(line.line_id) || line.line_id <= 0 || ids.has(line.line_id)) throw new Failure('invalid_line_id');
            ids.add(line.line_id);
            requireString(line.text, 16000, 'invalid_line_text');
            if (!Number.isFinite(line.t_sec) || line.t_sec < 0 || typeof line.is_gap !== 'boolean') throw new Failure('invalid_line_time');
            if (line.t_end_sec !== undefined && (!Number.isFinite(line.t_end_sec) || line.t_end_sec < line.t_sec)) throw new Failure('invalid_line_time');
            if (line.cluster_tag !== null && (typeof line.cluster_tag !== 'string' || line.cluster_tag.length>160)) throw new Failure('invalid_cluster');
          }
          const first = body.lines[0];
          if (first.recipe !== STREAM_RECIPE || first.streaming !== true) throw new Failure('semantic_recipe_required');
          if (['action_protocol','action_only','action_request','source_revision'].some(field=>field in first)) {
            if(first.action_protocol!==ACTION_PROTOCOL || typeof first.action_request!=='string'
              || !new RegExp(`^${UUID}$`).test(first.action_request) || !Number.isSafeInteger(first.source_revision)
              || first.source_revision<0 || (first.action_only!==undefined && first.action_only!==true)) throw new Failure('invalid_action_protocol');
            if(first.action_only && first.stream_context)throw new Failure('action_only_context_forbidden');
          }
          if (first.stream_context) {
            const previous = first.stream_context;
            only(previous, ['event_id', 'title', 'latest_title', 'summary', 'tail', 't_end_sec']);
            if (!Number.isSafeInteger(previous.event_id) || previous.event_id <= 0 || !Number.isFinite(previous.t_end_sec)
              || previous.t_end_sec < 0) throw new Failure('invalid_stream_context');
            for (const field of ['title', 'latest_title', 'summary', 'tail']) if (previous[field] !== undefined
              && (typeof previous[field] !== 'string' || previous[field].length > 32000)) throw new Failure('invalid_stream_context');
          }
          response = await upstream('/extract/enqueue', JSON.stringify(body));
        } else if (route === '/extract/result') {
          only(body, ['ticket']);
          if (typeof body.ticket !== 'string' || !TICKET.test(body.ticket)) throw new Failure('invalid_stepx_ticket');
          response = await upstream('/extract/result', JSON.stringify(body));
        }
        if (!response || !response.ok) {
          if (route === '/asr/query' && response?.status === 502) {
            let failure; try { failure = await readJson(response); } catch { /* Unknown or oversized failures retain the same task identity. */ }
            // Only a confirmed terminal result permits a new paid submission.
            // Ordinary query outages must retain the existing task identity.
            if (['asr failed', 'asr_failed'].includes(failure?.error)) throw new Failure('asr_failed', 502);
            if (failure?.error === 'asr_cached_result_invalid') throw new Failure('asr_cached_result_invalid', 502);
          }
          throw new Failure('processing_failed', response?.status === 401 ? 401 : 502);
        }
        let receipt;
        try { receipt = await response.json(); } catch { throw new Failure('invalid_processing_receipt', 502); }
        if (!receipt || typeof receipt !== 'object' || receipt.error || receipt.data?.error) throw new Failure('processing_failed', 502);
        if (route === '/extract/enqueue') {
          if (!['queued', 'done'].includes(receipt.state) || typeof receipt.ticket !== 'string'
            || !TICKET.test(receipt.ticket)) throw new Failure('invalid_extraction_receipt', 502);
          return json({ state: receipt.state, ticket: receipt.ticket });
        }
        if (route === '/extract/result') {
          if (!['done', 'running', 'none'].includes(receipt.state)) throw new Failure('invalid_extraction_receipt', 502);
          if (receipt.state !== 'done') return json({ state: receipt.state });
          let payload;
          try { payload = JSON.parse(receipt.body); } catch { throw new Failure('invalid_extraction_result', 502); }
          if(payload?.terminal===true && typeof payload.error==='string')return json({state:'done',payload:{terminal:true,error:'个人行动识别失败，请重新识别这场录音。'}});
          const personal=payload?.action_protocol===ACTION_PROTOCOL && Array.isArray(payload.personal_actions);
          if (!payload || payload.error || payload.pipeline_version !== STREAM_RECIPE
            || (!Array.isArray(payload.events) && !personal) || (('action_protocol' in payload || 'personal_actions' in payload) && !personal))
            throw new Failure('invalid_extraction_result', 502);
          const allowed = ['pipeline_version', 'one_liner', 'events', 'key_points', 'commitments', 'stances', 'pendings', 'topic_keys','action_protocol','personal_actions'];
          return json({ state: 'done', payload: Object.fromEntries(allowed.filter(k => k in payload).map(k => [k, payload[k]])) });
        }
        if (route === '/asr/submit') {
          if (typeof receipt.task_id !== 'string' || !TASK.test(receipt.task_id)) throw new Failure('invalid_asr_receipt', 502);
          return json({ task_id: receipt.task_id });
        }
        const result = receipt.data && typeof receipt.data === 'object' ? receipt.data : receipt;
        const state = asrState(receipt);
        if (state === 'failed') throw new Failure('asr_failed', 502);
        if (state === 'done') return json({ state: 'done', result: result.result,
          ...(typeof result.duration === 'number' ? { duration: result.duration } : {}),
          degraded: receipt.growth_no_speaker === true });
        if (state === 'waiting') return json({ state: 'waiting' });
        throw new Failure('unknown_asr_response', 502);
      } catch (error) {
        if (route === '/health' && !(error instanceof Failure)) console.error('stepx_health_transport', error?.name, String(error?.message ?? '').replaceAll(env.GROWTH_CLIENT_TOKEN, '[redacted]').slice(0, 300));
        return json({ error: error instanceof Failure ? error.message : 'upstream_unavailable' }, error instanceof Failure ? error.status : 502);
      }
    },
  };
}
/** One durable receipt coordinator per immutable audio object. A provider timeout is
 * not permission to charge again. Store that uncertainty before any paid request. */
export class StepXSubmissions {
  constructor(ctx, env, fetchUpstream = fetch) {
    this.storage = ctx.storage; this.env = env; this.fetchUpstream = fetchUpstream;
    this.serial = Promise.resolve();
  }
  fetch(request) {
    const task = this.serial.catch(() => undefined).then(() => this.submit(request));
    this.serial = task.catch(() => undefined);
    return task;
  }
  async submit(request) {
    try {
      const body = await readJson(request);
      submissionBody(body);
      const object = await this.env.AUDIO.head(body.key);
      const seconds = storedStepXSeconds(object, body.key);
      if (seconds === null) throw new Failure('uploaded_audio_missing', 409);
      if (seconds <= 0 || seconds > 601) throw new Failure('invalid_duration');
      const stored = await this.storage.get('receipt');
      const claim = await this.env.AUDIO.get(claimKey(body.key));
      const prior = claim ? await claim.json().catch(() => null) : null;
      const priorTask = typeof prior?.task_id === 'string' && TASK.test(prior.task_id) ? prior.task_id : undefined;
      const priorAt = Date.parse(prior?.submitted_at ?? '');
      // R2 may still contain the failed claim from before this durable attempt.
      // Recover a lost receipt only when it identifies this new attempt.
      const recovered = priorTask && (!stored || priorTask === stored.task_id
        || (priorTask !== stored.supersedes && Number.isFinite(priorAt) && priorAt >= stored.submittedAt));
      const taskId = stored?.task_id ?? (recovered ? priorTask : undefined);
      const submittedAt = stored?.submittedAt ?? priorAt;
      const expired = Number.isFinite(submittedAt) && Date.now() - submittedAt > PENDING_TTL_MS;
      if (typeof taskId === 'string' && TASK.test(taskId)) {
        const cached = await this.env.AUDIO.get(resultKey(taskId));
        const terminal = cached ? await cached.json().catch(() => null) : null;
        let invalidDone = false;
        if (terminal?.verdict === 'done') {
          let parsed; try { parsed = JSON.parse(terminal.body); } catch { parsed = null; }
          if (asrState(parsed) === 'done') return json({ task_id: taskId });
          invalidDone = true;
          if (!(body.retryFailed === true && expired)) throw new Failure('asr_cached_result_invalid', 502);
        }
        const failed = terminal?.verdict === 'failed' || invalidDone;
        if (failed && body.retryFailed !== true) throw new Failure('asr_failed', 502);
        if (!(body.retryFailed === true && (failed || expired))) return json({ task_id: taskId });
      } else if (stored && !(body.retryFailed === true && expired)) {
        // Keep expiry visible to old clients; paid recovery needs identified consent.
        if (expired) return json({ error: 'asr_failed', reason: 'asr_submission_expired' }, 409);
        throw new Failure('asr_submission_unknown', 409);
      }
      if (body.retryFailed === true) {
        // A legacy boolean cannot distinguish another user click from automatic
        // replay. Every paid retry needs a fresh, user-created identity, whose
        // consumption survives all future receipt replacements and expiries.
        if (!body.retryId) throw new Failure('asr_retry_authorization_required', 409);
        const authorization = 'retry:' + body.retryId;
        if (await this.storage.get(authorization)) throw new Failure('asr_retry_authorization_required', 409);
        await this.storage.put(authorization, { consumedAt: Date.now() });
      }
      // Survives a request timeout, isolate restart and a lost upstream R2 claim.
      const submitted = { submittedAt: Date.now(), state: 'unknown', supersedes: taskId ?? stored?.supersedes ?? null };
      await this.storage.put('receipt', submitted);
      let receipt;
      try {
        const call = this.env.GROWTH_UPSTREAM ? (url, init) => this.env.GROWTH_UPSTREAM.fetch(new Request(url, init)) : this.fetchUpstream;
        const response = await call(UPSTREAM + '/asr/submit', {
          method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(90000),
          headers: { 'X-Growth-Token': this.env.GROWTH_CLIENT_TOKEN, 'Content-Type': 'application/json' },
          body: JSON.stringify({ key: body.key, seconds: Math.ceil(seconds) }),
        });
        if (!response.ok) throw new Error('unknown');
        receipt = await response.json();
        if (receipt?.error || typeof receipt?.task_id !== 'string' || !TASK.test(receipt.task_id)) throw new Error('unknown');
      } catch { throw new Failure('asr_submission_unknown', 409); }
      try { await this.storage.put('receipt', { ...submitted, state: 'accepted', task_id: receipt.task_id }); }
      catch { return json({ task_id: receipt.task_id, receiptPersisted: false }); }
      return json({ task_id: receipt.task_id });
    } catch (error) {
      return json({ error: error instanceof Failure ? error.message : 'submission_unavailable' }, error instanceof Failure ? error.status : 502);
    }
  }
}
export class StepXRecordings extends RecordingCoordinator {
  constructor(ctx,env) {
    super(ctx,env,async(path,body)=>{
      if(!['/asr/submit','/asr/query','/extract/enqueue','/extract/result'].includes(path))throw Error('invalid_background_call');
      const response=await createBridge().fetch(new Request(UPSTREAM+'/stepx'+path,{method:'POST',
        headers:{'Content-Type':'application/json','X-Growth-Token':env.GROWTH_CLIENT_TOKEN},body:JSON.stringify(body)}),env);
      const value=await response.json();
      if(!response.ok)throw Object.assign(Error(value.error??'upstream_unavailable'),{code:value.error,status:response.status});
      return value;
    });
  }
}
export default createBridge();

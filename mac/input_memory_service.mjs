#!/usr/bin/env node
// Local Mac service, reusable behind the unified Growth backend at merge time.
import http from 'node:http';
import https from 'node:https';
import { readFileSync, existsSync } from 'node:fs';
import { createHash, timingSafeEqual } from 'node:crypto';
import { resolve, join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { handleInputMemory } from '../worker/src/input_memory.js';
import { replicaChanges } from './input_memory_feed.mjs';
import { InputMemoryPuller } from './input_memory_pull.mjs';
import { InputMemoryReplica } from './input_memory_store.mjs';
import { InputMemoryProvider, InputMemoryError } from './input_memory_agent.mjs';
import { RecordingMemoryReplica, RecordingMemoryPuller, RecordingMemoryProvider } from './recording_memory.mjs';
import { createMacAgent, createIndexWarmer } from './common_agent.mjs';

const MAX_BYTES = 1024 * 1024;
const LOCAL_HOSTS = ['127.0.0.1', '::1', 'localhost'];
export const RELEASE = Object.freeze(JSON.parse(readFileSync(new URL('input_memory_release.json',import.meta.url),'utf8')));
const json = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: {
  'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
} });
export function sourceFingerprint() {
  const digest = createHash('sha256');
  for (const name of ['input_memory_service.mjs', 'input_memory_store.mjs', 'input_memory_agent.mjs', 'input_memory_pull.mjs', 'input_memory_feed.mjs', 'input_memory_release.json', 'recording_memory.mjs', '../worker/src/recording_memory.js', '../worker/migrations/0002_recording_memory.sql', '../worker/src/input_memory.js', '../worker/migrations/0001_input_memory.sql']) digest.update(readFileSync(new URL(name, import.meta.url)));
  digest.update(readFileSync(new URL('common_agent.mjs',import.meta.url)));
  return digest.digest('hex');
}
function authorized(value, token) {
  const a = Buffer.from(typeof value === 'string' ? value : ''), b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
}
async function body(request,limit=MAX_BYTES) {
  const blocks = []; let size = 0;
  const length = request.headers['content-length'];
  if (length && (!/^\d+$/.test(length) || Number(length) > limit)) throw new InputMemoryError('payload_too_large', 413);
  await new Promise((done, fail) => {
    const cleanup = () => { request.off('data', data); request.off('end', end); request.off('error', error); request.off('aborted', aborted); };
    const data = chunk => {
      size += chunk.length;
      if (size > limit) { cleanup(); request.pause(); fail(new InputMemoryError('payload_too_large', 413)); }
      else blocks.push(chunk);
    };
    const end = () => { cleanup(); done(); };
    const error = () => { cleanup(); fail(new InputMemoryError('request_failed')); };
    const aborted = () => { cleanup(); fail(new InputMemoryError('request_aborted')); };
    request.on('data', data); request.on('end', end); request.on('error', error); request.on('aborted', aborted);
  });
  return Buffer.concat(blocks);
}
export function createInputMemoryServer({ replica, token, host = '127.0.0.1', tls, allowRemote = false, allowedHosts = [], refresh = async () => {}, synchronization = () => ({mode:'direct',state:'ready',ready:true}), agent=null, recordings=null, recordingStatus=()=>({state:'not_connected',ready:false}), logger = () => {} }) {
  if (typeof token !== 'string' || !token.trim()) throw new Error('input_memory_token_required');
  if (!LOCAL_HOSTS.includes(host) && (!allowRemote || !tls || !allowedHosts.length)) throw new Error('remote_requires_tls_and_allowed_hosts');
  const provider = new InputMemoryProvider(replica, { refresh }), fingerprint = sourceFingerprint();
  const startedAt=new Date().toISOString();
  let active = 0;
  const handler = async (request, response) => {
    request.on('error', () => {});
    let result;
    try {
      const address = server.address(), port = address.port;
      const hosts = LOCAL_HOSTS.includes(host) ? [...LOCAL_HOSTS, ...allowedHosts] : allowedHosts;
      const authorities = hosts.flatMap(name => {
        const h = name.includes(':') && !name.startsWith('[') ? '[' + name + ']' : name;
        return [h + ':' + port, ...((tls && port === 443) || (!tls && port === 80) ? [h] : [])];
      });
      if (!authorities.includes((request.headers.host ?? '').toLowerCase()) || request.headers.origin) result = json({ error: 'host_or_origin_not_allowed' }, 403);
      else if (!authorized(request.headers['x-growth-token'], token)) result = json({ error: 'unauthorized' }, 401);
      else if (active >= 32) result = json({ error: 'input_memory_busy' }, 503);
      else {
        active++;
        try {
          if (!request.url?.startsWith('/') || request.url.startsWith('//')) throw new InputMemoryError('invalid_path');
          const url = new URL(request.url, (tls ? 'https' : 'http') + '://localhost:' + port);
          if (url.pathname === '/health' && request.method === 'GET') {
            const coverage=replica.sqlite.prepare(`SELECT COUNT(CASE WHEN deleted=0 THEN 1 END) AS sources,COUNT(DISTINCT CASE WHEN deleted=0 THEN device_id END) AS devices,
              COUNT(CASE WHEN deleted=1 THEN 1 END) AS tombstones,
              MIN(CASE WHEN deleted=0 THEN created END) AS first_record_at,
              MAX(CASE WHEN deleted=0 THEN created END) AS last_record_at,MAX(received_at) AS received_at FROM input_memory_sources`).get();
            result = json({ schema:'growth.input-memory.service/1', ...RELEASE, pid:process.pid, source:fileURLToPath(import.meta.url),
              working_directory:process.cwd(),started_at:startedAt,source_fingerprint:fingerprint,storage:'sqlite_source_replica',database:replica.path,node:process.versions.node,
              synchronization:synchronization(),agent:agent ? await agent.status() : {ready:false,state:'not_configured'},coverage:{scope:'synced_input_memory_only',...coverage},recording_database:recordings?.replica.path ?? null,recordings:recordings ? {...recordings.coverage(),...recordingStatus(),scope:'synced_recording_readonly'} : {state:'not_connected',ready:false},capabilities:['sync','changes','search','read','context','validate',...(agent ? ['agent_answer','model_text','model_asr','shared_input_sources',...(recordings ? ['recording_sources','source_validation'] : [])] : [])] });
          }
          else if (request.method === 'POST') {
            if (!(request.headers['content-type'] ?? '').toLowerCase().startsWith('application/json')) throw new InputMemoryError('json_required', 415);
            const bytes = await body(request,url.pathname==='/agent/model' ? 8*MAX_BYTES : MAX_BYTES);
            if(['/agent/answer','/agent/model','/agent/validate'].includes(url.pathname)) {
              if(!agent)throw new InputMemoryError('agent_not_configured',503);
              request.socket.setTimeout(300000);
              let input;try{input=JSON.parse(bytes.toString('utf8'));}catch{throw new InputMemoryError('invalid_json');}
              const controller=new AbortController(),closed=()=> {if(!response.writableEnded)controller.abort();};
              response.on('close',closed);
              try {result=json(await (url.pathname==='/agent/model' ? agent.model(input,{signal:controller.signal}) : url.pathname==='/agent/validate' ? agent.validate(input,{signal:controller.signal}) : agent.answer(input,{signal:controller.signal})));}finally{response.off('close',closed);}
            } else if (['/input-memory/read', '/input-memory/context', '/input-memory/validate'].includes(url.pathname)) {
              let input;
              try { input = JSON.parse(bytes.toString('utf8')); } catch { throw new InputMemoryError('invalid_json'); }
              if (!input || typeof input !== 'object' || Array.isArray(input)) throw new InputMemoryError('invalid_body');
              if (url.pathname.endsWith('/read')) { result = json(await provider.read(input)); }
              if (url.pathname.endsWith('/context')) result = json(await provider.context(input));
              if (url.pathname.endsWith('/validate')) {
                const checked = await provider.validate(input); result = json(checked, checked.valid ? 200 : 409);
              }
            } else {
              // An upstream mirror is written only by its puller; a local write would fork the authoritative cloud copy.
              if (url.pathname === '/input-memory/sync' && synchronization().mode === 'upstream') throw new InputMemoryError('replica_is_upstream_mirror', 409);
              if (url.pathname === '/input-memory/search') await provider.refresh(); result = await handleInputMemory(new Request(url, { method: request.method, body: bytes }), { INPUT_MEMORY: replica.db }, url); }
          } else if (request.method === 'GET' && url.pathname === '/input-memory/changes') { await provider.refresh(); result=json(replicaChanges(replica,url)); }
          else if (request.method === 'GET') result = await handleInputMemory(new Request(url), { INPUT_MEMORY: replica.db }, url);
          else result = json({ error: 'method_or_path_not_allowed' }, 405);
        } finally { active--; }
      }
    } catch (error) {
      result = json({ error: error instanceof InputMemoryError ? error.message : 'input_memory_storage_failed',...(error.publicMessage ? {message:error.publicMessage} : {}) }, error instanceof InputMemoryError ? error.status : 500);
    }
    // Logs contain no payload, query strings, source IDs or token.
    logger({ status: result.status });
    if (result.status === 413) request.resume(); // Discard without buffering so clients can receive the error during upload.
    response.writeHead(result.status, { ...Object.fromEntries(result.headers), 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'connection': result.status === 413 ? 'keep-alive' : 'close' });
    response.end(Buffer.from(await result.arrayBuffer()));
  };
  const server = tls ? https.createServer(tls, handler) : http.createServer(handler);
  server.requestTimeout = 15000; server.headersTimeout = 10000; server.keepAliveTimeout = 5000;
  server.maxHeadersCount = 32; server.maxConnections = 64;
  server.on('connection', socket => socket.setTimeout(25000, () => socket.destroy()));
  return { server, provider, fingerprint };
}

async function main() {
  const { values } = parseArgs({ options: {
    db: { type: 'string' }, upstream: { type: 'string' }, host: { type: 'string' }, port: { type: 'string' },
    'tls-cert': { type: 'string' }, 'tls-key': { type: 'string' }, 'allow-remote': { type: 'boolean' }, 'allowed-host': { type: 'string', multiple: true },
  } });
  const token = process.env.GROWTH_INPUT_MEMORY_TOKEN || process.env.GROWTH_CLIENT_TOKEN || process.env.GROWTH_PROXY_TOKEN;
  if (!token?.trim()) throw new Error('input_memory_token_required');
  const host = values.host ?? process.env.GROWTH_INPUT_MEMORY_HOST ?? '127.0.0.1', port = Number(values.port ?? process.env.GROWTH_INPUT_MEMORY_PORT ?? 18791);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('invalid_port');
  const cert = values['tls-cert'] ?? process.env.GROWTH_INPUT_MEMORY_TLS_CERT, key = values['tls-key'] ?? process.env.GROWTH_INPUT_MEMORY_TLS_KEY;
  if (!!cert !== !!key) throw new Error('tls_certificate_and_key_required');
  const tls = cert ? { cert: readFileSync(cert), key: readFileSync(key) } : undefined;
  process.umask(0o077);
  const replica = new InputMemoryReplica(values.db ?? process.env.GROWTH_INPUT_MEMORY_DB ?? join(homedir(), 'Library/Application Support/GrowthApp/InputMemory/sources.sqlite'));
  let runtime, puller, recordingReplica, recordingPuller, recordings;
  try {
    const upstream=values.upstream ?? process.env.GROWTH_INPUT_MEMORY_UPSTREAM;
    if(upstream) {
      const target=new URL(upstream),targetPort=Number(target.port || 443),targetHost=target.hostname.replace(/^\[|\]$/g,'');
      if((LOCAL_HOSTS.includes(targetHost) && LOCAL_HOSTS.includes(host) && targetPort===port) || (values['allowed-host'] ?? []).includes(targetHost)) throw new Error('upstream_self_reference');
      puller=new InputMemoryPuller(replica,{origin:upstream,token:process.env.GROWTH_CLIENT_TOKEN || token});
    }
    const recordingUpstream=process.env.GROWTH_RECORDING_MEMORY_UPSTREAM ?? upstream;
    if(recordingUpstream) {
      recordingReplica=new RecordingMemoryReplica(process.env.GROWTH_RECORDING_MEMORY_DB ?? join(homedir(),'Library/Application Support/GrowthApp/RecordingMemory/sources.sqlite'));
      recordingPuller=new RecordingMemoryPuller(recordingReplica,{origin:recordingUpstream,token:process.env.GROWTH_CLIENT_TOKEN || token});
      recordings=new RecordingMemoryProvider(recordingReplica,{refresh:()=>recordingPuller.refresh({fresh:true})});
    }
    const refresh=async()=> { if(puller)await puller.refresh({fresh:true}); };
    runtime = createInputMemoryServer({ replica, token, host, tls, allowRemote: values['allow-remote'] ?? false, allowedHosts: values['allowed-host'] ?? [], refresh, synchronization:puller ? () => puller.status() : undefined,agent:createMacAgent({app:process.env.GROWTH_AGENT_IME_APP,replica,refresh,recordings}),recordings,recordingStatus:recordingPuller ? ()=>recordingPuller.status() : undefined });
  }
  catch (error) { replica.close(); recordingReplica?.close(); throw error; }
  runtime.server.on('error', () => { console.error('input_memory_listen_failed'); replica.close(); process.exit(1); });
  runtime.server.listen(port, host, () => console.log(JSON.stringify({ schema: 'growth.input-memory.runtime/1', source: fileURLToPath(import.meta.url), pid: process.pid, source_fingerprint: runtime.fingerprint, host, port, tls: !!tls })));
  // Background index warming: embedding must never sit on a lookup's critical path again. The
  // host app's bridge.py is the embedding implementation, and the warmer only arms when it is
  // installed (its first cycle also verifies the bundle still matches this source tree).
  const agentApp = process.env.GROWTH_AGENT_IME_APP ?? join(homedir(), 'Library/Input Methods/APT.app');
  const warmer = existsSync(join(agentApp, 'Contents/Resources/bridge.py'))
    ? createIndexWarmer({ replica, recordings, app: agentApp, log: line => console.log('index warm · ' + line) }) : null;
  const pulled = result => { if (result?.changed > 0) warmer?.kick('changes'); };
  const poll = puller ? setInterval(() => puller.refresh().then(pulled).catch(() => console.error('input_memory_upstream_not_ready')),60000) : null;
  if(puller) puller.refresh().then(pulled).catch(() => console.error('input_memory_upstream_not_ready'));
  const recordingPoll=recordingPuller ? setInterval(()=>recordingPuller.refresh().then(pulled).catch(()=>console.error('recording_memory_upstream_not_ready')),60000) : null;
  if(recordingPuller)recordingPuller.refresh().then(pulled).catch(()=>console.error('recording_memory_upstream_not_ready'));
  // Catch-up covers a manually cleared index and any missed change, without polling the replicas.
  const warmPoll = warmer ? setInterval(() => warmer.kick('catchup'), 600000) : null; warmPoll?.unref();
  warmer?.kick('startup');
  const heartbeat = setInterval(() => console.log('input-memory heartbeat · 最多 1200 秒不吭声'), 600000); heartbeat.unref();
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { clearInterval(heartbeat); if(poll) clearInterval(poll); if(recordingPoll)clearInterval(recordingPoll); if(warmPoll)clearInterval(warmPoll); warmer?.stop(); runtime.server.close(() => { replica.close();recordingReplica?.close(); process.exit(0); }); });
}
if (import.meta.main) main().catch(() => { console.error('input_memory_startup_failed (check token, database, TLS and bind configuration)'); process.exit(1); });

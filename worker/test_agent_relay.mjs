import assert from 'node:assert/strict';
import worker from './src/index.js';

// /agent/model 云隧道中继:验门禁后原样透传到 mini,请求体(里面有凭据)任何日志都不碰。
let assertions = 0;
const check = new Proxy(assert, {get(target, property) {
  const value = target[property];
  return typeof value === 'function' ? (...args) => { assertions++; return value(...args); } : value;
}});
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const TUNNEL = 'https://apt-agent.example.test';
const req = (path, body, headers = {}) => new Request('https://worker.test' + path, {
  method: body === undefined ? 'GET' : 'POST', headers,
  ...(body === undefined ? {} : {body: JSON.stringify(body)})});
const call = (path, body, headers, env) =>
  worker.fetch(req(path, body, headers), env, {});

test('relay is behind the shared gate: absent or wrong token never reaches the tunnel', async () => {
  let called = 0;
  globalThis.fetch = async () => { called++; return new Response('{}'); };
  for (const token of [undefined, 'wrong']) {
    const headers = token ? {'X-Growth-Token': token} : {};
    const response = await call('/agent/model', {scene:'by_day'}, headers,
      {CLIENT_TOKEN:'secret', AGENT_TUNNEL_URL:TUNNEL});
    check.equal(response.status, 401); check.equal((await response.json()).error, 'unauthorized');
  }
  check.equal(called, 0, '凭据在请求体里,401 时必须一个字节都不出门');
});
test('unconfigured or malformed tunnel is a controlled 503, fetch is never called', async () => {
  let called = 0;
  globalThis.fetch = async () => { called++; return new Response('{}'); };
  for (const env of [{CLIENT_TOKEN:'secret'}, {CLIENT_TOKEN:'secret', AGENT_TUNNEL_URL:'not a url'}]) {
    const response = await call('/agent/model', {scene:'by_day'}, {'X-Growth-Token':'secret'}, env);
    check.equal(response.status, 503); check.equal((await response.json()).error, 'agent_relay_not_configured');
  }
  check.equal(called, 0);
});
test('happy path: method, target, headers, body and upstream response pass through untouched', async () => {
  const payload = {schema:'apt.model.request/1', scene:'by_day', credential:{endpoint:'x', key:'sk-secret'}};
  let captured;
  globalThis.fetch = async (url, init) => {
    captured = {url: String(url), init};
    return new Response(JSON.stringify({schema:'apt.model.reply/1', text:'整理正文'}), {
      status: 200, headers: {'Content-Type': 'application/json', 'CF-Ray': 'leak-attempt'}});
  };
  const response = await call('/agent/model', payload,
    {'X-Growth-Token':'secret', 'Content-Type':'application/json'},
    {CLIENT_TOKEN:'secret', AGENT_TUNNEL_URL:TUNNEL});
  check.equal(response.status, 200);
  check.equal(await response.text(), JSON.stringify({schema:'apt.model.reply/1', text:'整理正文'}));
  check.equal(response.headers.get('content-type'), 'application/json');
  check.equal(response.headers.get('cache-control'), 'no-store');
  check.equal(response.headers.get('cf-ray'), null, '隧道侧指纹头不回带');
  check.equal(captured.url, TUNNEL + '/agent/model');
  check.equal(captured.init.method, 'POST');
  check.equal(captured.init.redirect, 'manual', '不跟随重定向:3xx 会把带凭据的 body 转手');
  check.ok(captured.init.signal instanceof AbortSignal, '中继 260s 超时必须真实挂上');
  check.equal(captured.init.headers['x-growth-token'], 'secret');
  check.equal(captured.init.headers['content-type'], 'application/json');
  check.equal(await new Response(captured.init.body).text(), JSON.stringify(payload), 'body 字节直传');
});
test('upstream status and body pass through verbatim, including controlled errors', async () => {
  globalThis.fetch = async () => new Response(JSON.stringify({error:'input_memory_busy'}), {status: 503});
  const busy = await call('/agent/model', {scene:'by_day'}, {'X-Growth-Token':'secret'},
    {CLIENT_TOKEN:'secret', AGENT_TUNNEL_URL:TUNNEL});
  check.equal(busy.status, 503);
  check.equal((await busy.json()).error, 'input_memory_busy', '上游受控错误是客户端排查的唯一线索,不翻译');
});
test('redirects are never followed with the credentialed body and surface a controlled error', async () => {
  let called = 0;
  globalThis.fetch = async () => { called++;
    return new Response(null, {status: 301, headers: {Location: 'https://attacker.example/steal'}}); };
  const response = await call('/agent/model', {scene:'by_day'}, {'X-Growth-Token':'secret'},
    {CLIENT_TOKEN:'secret', AGENT_TUNNEL_URL:TUNNEL});
  check.equal(response.status, 502, '18791 从不重定向,3xx 翻译成受控错误而非哑巴透传');
  const body = await response.json();
  check.equal(body.error, 'agent_unreachable');
  check.equal(body.upstream_status, 301);
  check.equal(called, 1, 'manual 模式下 fetch 不跟随,凭据 body 没有第二个目的地');
});
test('upstream failure answers 502 without leaking the tunnel address', async () => {
  globalThis.fetch = async () => { throw new TypeError('fetch failed: ' + TUNNEL + ' unreachable'); };
  const response = await call('/agent/model', {scene:'by_day'}, {'X-Growth-Token':'secret'},
    {CLIENT_TOKEN:'secret', AGENT_TUNNEL_URL:TUNNEL});
  check.equal(response.status, 502);
  const body = await response.text();
  check.equal((JSON.parse(body)).error, 'agent_unreachable');
  check.ok(!body.includes(TUNNEL), '隧道地址是 secret,不进任何响应或日志');
});
test('GET is rejected by the POST-only gate before the relay', async () => {
  let called = 0;
  globalThis.fetch = async () => { called++; return new Response('{}'); };
  const response = await worker.fetch(new Request('https://worker.test/agent/model',
    {headers: {'X-Growth-Token': 'secret'}}), {CLIENT_TOKEN:'secret', AGENT_TUNNEL_URL:TUNNEL}, {});
  check.equal(response.status, 405); check.equal(called, 0);
});
test('health reports the tunnel binding for deployment checks', async () => {
  for (const [env, expected] of [[{}, false], [{AGENT_TUNNEL_URL:TUNNEL}, true]]) {
    const response = await worker.fetch(new Request('https://worker.test/health'), env, {});
    check.equal((await response.json()).hasAgentTunnel, expected);
  }
});

const realFetch = globalThis.fetch;
let failures = 0;
for (const [name, fn] of tests) {
  try { await fn(); }
  catch (error) { failures++; console.log('🔴 ' + name + '\n  ' + (error?.message ?? error)); }
  finally { globalThis.fetch = realFetch; }
}
console.log(`${tests.length - failures}/${tests.length} relay tests passed, ${assertions} assertions`);
if (failures) process.exit(1);

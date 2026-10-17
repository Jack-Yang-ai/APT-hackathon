/**
 * /agent/model 云隧道中继 —— MacBook 的模型调用经云代理转发到 mini 的 18791 服务。
 *
 * 定位见 `docs/intents/mac-memory-hub/`：Mac mini 是记忆中枢大管家，by_day 等整理链路
 * 的模型调用必须落在 mini 的完整 Agent 上。跨机不走 SSH(用户拍板)，通道统一走云：
 * mini 上 cloudflared 常驻(launchd，纯出站)把 127.0.0.1:18791 暴露成隧道地址，
 * Worker 把 /agent/model 原样透传过去 —— mini 侧 18791 服务零改动。
 *
 * ## 三条铁律
 * 1. **绝不记录请求体**：`credential.key`(StepFun/DeepSeek 凭据)在请求体里过境 ——
 *    body 以流直传(request.body → fetch)，日志永远只有固定字符串。
 * 2. **不跟随重定向**：`redirect:'manual'`。fetch 的默认行为是跟随 3xx 并把
 *    带凭据的 body 一起送过去 —— 隧道地址配错返回 301 时，凭据就被转手了。
 *    18791 从不重定向，中继把 3xx 翻译成 502 + upstream_status(凭据不出门)。
 * 3. **上游状态原样透传**：`input_memory_busy` 503、`agent_not_configured` 503 是
 *    客户端排查的唯一线索。Worker 不吞、不改、不翻译上游的错误。
 *
 * ## 超时三方不互相假装
 * 客户端 300s(AgentModels) → 本中继 260s → mini socket 300s。中继最先掐：
 * 掐了报 502 `agent_unreachable`，而不是让客户端在 300s 后猜。
 * ⚠️ step-5-preview 长思考期间上游一个字节都不发(实测 240s 批次)；
 * 若 Cloudflare 边缘对静默回源有更短空闲超时，端到端验收会暴露，
 * 届时才考虑上游心跳——那是部署验证边界，不是现在改设计的理由。
 */

const UPSTREAM_TIMEOUT_MS = 260_000;
const FORWARDED_HEADERS = ['content-type', 'x-growth-token'];

const reply = (value, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
});

export async function relayAgentModel(request, env) {
  // 隧道地址是部署期配置(secrets)，不进版本库:`wrangler secret put AGENT_TUNNEL_URL`。
  // 没配就是 503「未配置」——与 18791 的 agent_not_configured 同风格，探活能分清两者。
  const root = env.AGENT_TUNNEL_URL;
  if (!root || typeof root !== 'string') return reply({ error: 'agent_relay_not_configured' }, 503);
  let target;
  try { target = new URL('/agent/model', root); } catch { return reply({ error: 'agent_relay_not_configured' }, 503); }
  const headers = {};
  for (const name of FORWARDED_HEADERS) {
    const value = request.headers.get(name);
    if (value != null) headers[name] = value;
  }
  try {
    // 流式直传：body 字节不进 Worker 内存 —— 与 /upload 同一条纪律。
    const upstream = await fetch(target, {
      method: 'POST', headers, body: request.body, redirect: 'manual',
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    // 18791 服务从不重定向 —— 隧道上出现 3xx 只可能是配置错或劫持(manual 已保证
    // 凭据 body 没有被送到第二个目的地)。哑巴透传会让客户端报「无效的模型结果」,
    // 排查方向全错;翻译成 502 + upstream_status 直接指向隧道配置。
    if (upstream.status >= 300 && upstream.status < 400) {
      console.log('[agent-relay] upstream redirected: ' + upstream.status);
      return reply({ error: 'agent_unreachable', upstream_status: upstream.status }, 502);
    }
    // 状态与响应体一字不改；响应头只留 content-type —— 不把隧道侧的
    // cf-ray/server 等指纹带回，也不让上游的缓存头进我们的边缘。
    const passthrough = new Headers();
    const type = upstream.headers.get('content-type');
    if (type) passthrough.set('content-type', type);
    passthrough.set('cache-control', 'no-store');
    return new Response(upstream.body, { status: upstream.status, headers: passthrough });
  } catch {
    // 固定字符串：上游地址、请求细节都不进日志(请求体里有凭据)。
    console.log('[agent-relay] upstream unreachable');
    return reply({ error: 'agent_unreachable' }, 502);
  }
}

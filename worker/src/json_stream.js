/** Mac 显式协商的最终JSON流；心跳避免等待完整结果时连接被约300秒断开。 */
export function streamJSONResult(run, ctx) {
  const encoder = new TextEncoder();
  const abort = new AbortController();
  const upstream = {};
  let cancelled = false, interval, deadline;
  const body = new ReadableStream({
    start(controller) {
      const send = frame => { if (!cancelled) controller.enqueue(encoder.encode(JSON.stringify(frame) + '\n')); };
      send({ type: 'ping' });
      interval = setInterval(() => send({ type: 'ping', upstream }), 15000);
      deadline = setTimeout(() => abort.abort(), 900000);
      const task = (async () => {
        try {
          const result = await run(abort.signal, upstream);
          send({ type: 'result', status: result.status, body: await result.json() });
        } catch {
          send({ type: 'result', status: 502, body: { error: '抽取请求失败' } });
        } finally {
          clearInterval(interval);
          clearTimeout(deadline);
          if (!cancelled) controller.close();
        }
      })();
      ctx.waitUntil(task);
    },
    cancel() { cancelled = true; clearInterval(interval); clearTimeout(deadline); abort.abort(); },
  });
  return new Response(body, { headers: { 'Content-Type': 'application/x-ndjson', 'Cache-Control': 'no-store' } });
}

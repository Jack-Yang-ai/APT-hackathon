#!/usr/bin/env python3
"""Local bridge: WithEcho reads and optional local embeddings; no ASR exports."""
import datetime as dt
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).parent

def fetch(*args):
    p = subprocess.run([sys.executable, str(ROOT / 'fetch.py'), *args], capture_output=True, text=True, timeout=120)
    if p.returncode:
        try:
            error = json.loads(p.stderr)
            raise ValueError(error.get('error_description') or error.get('error') or '读取失败')
        except json.JSONDecodeError:
            raise ValueError('WithEcho 读取失败，请检查授权或网络。')
    return json.loads(p.stdout)

def demo(day):
    return [
        {'event_id':'demo-1','date':day,'title':'记忆输入助手 · 方案讨论（虚构示例）',
         'summary':'讨论 Mac 原型、记忆来源和第一版范围。',
         'detail':'## 会议结论\n- 先做 Mac 桌面原型，通过快捷键唤起。\n- 第一版接入 WithEcho 日常，支持检索会议结论、展示来源和插入草稿。\n- 手机版本暂未决定，等原型验证后再讨论。\n## 待办\n- 整理第一版交互。'},
        {'event_id':'demo-2','date':day,'title':'发布计划讨论（虚构示例）',
         'summary':'讨论发布节奏，尚未决定具体日期。',
         'detail':'## 会议结论\n- 发布日期尚未确定，需要等测试结果。\n- 当前没有对外承诺上线时间。'}]

def event_body(event):
    # Only event text is evidence. Generated insight cards are not user facts,
    # and sending them also adds substantial, irrelevant model context.
    return event.get('detail') or event.get('summary') or ''

def retrieve(req):
    start, end = dt.date.fromisoformat(req['from']), dt.date.fromisoformat(req['to'])
    if start > end or (end-start).days > 30:
        raise ValueError('检索日期范围必须在 31 天以内。请在请求中补充具体时间。')
    cache = 'demo'
    if req.get('demo',False):
        events = demo(end.isoformat())
    else:
        data = fetch('digest','--from',start.isoformat(),'--to',end.isoformat(),'--refresh')
        cache = (data.get('_cache') or {}).get('source') or 'unknown'
        digests = data.get('digests') or ([data] if 'events' in data else [])
        if not digests:
            raise ValueError('WithEcho 返回了无法识别的记录目录。')
        if any(d.get('events') is None for d in digests):
            raise ValueError('未授权日常读取权限，请重新连接 WithEcho。')
        events = []
        for digest in digests:
            for event in digest.get('events') or []:
                event['date'] = event.get('date') or digest['date']
                events.append(event)
    unique = {e['event_id']:e for e in events if e.get('event_id')}
    events = sorted(unique.values(),key=lambda e:e.get('start_time') or e.get('date',''),reverse=True)
    keywords = [k for k in req.get('keywords',[]) if isinstance(k,str) and k.strip()][:5]
    if keywords:
        events.sort(key=lambda e:sum(k.lower() in (e.get('title','')+' '+e.get('summary','')).lower() for k in keywords),reverse=True)
    limit = 2000 if req.get('search_pool') is True else 120
    omitted = max(0,len(events)-limit)
    metadata = [{k:e.get(k,'') for k in ['event_id','date','start_time','end_time','title','summary']} for e in events[:limit]]
    return {'events':metadata,'omitted':omitted,'date':f'{start} 至 {end}','cache':cache}

def details(req):
    ids = list(dict.fromkeys(req.get('ids',[])))
    limit = 120 if req.get('full_pool') is True else 6
    if not ids or len(ids)>limit or any(not isinstance(i,str) or not i for i in ids):
        raise ValueError(f'每次最多读取 {limit} 条记录。')
    cache = 'demo'
    if req.get('demo',False):
        indexed = {e['event_id']:e for e in demo(req['date'])}
        events = [indexed[i] for i in ids if i in indexed]
    else:
        data = fetch('daily-detail','--event-id',*ids, *(['--refresh'] if req.get('refresh') else []))
        cache = (data.get('_cache') or {}).get('source') or 'unknown'
        events = data.get('events',[]) if len(ids)>1 else [data]
    sources = []
    for event in events:
        if event.get('error') or event.get('event_id') not in ids:
            continue
        body = event_body(event)
        if not isinstance(body, str) or not body.strip():
            continue
        if not event.get('detail'):
            body = '以下只有事件摘要，完整正文不可用，不能据此声称已读完这段记录。\n' + body
        time = ' 至 '.join(str(event.get(k) or '') for k in ('start_time', 'end_time'))
        if event.get('start_time'):
            body = '记录时间：' + time + '\n' + body
        sources.append({'event_id':event['event_id'],'date':event.get('date',''),'title':event.get('title',''),'body':body})
    return {'sources':sources,'cache':cache}

def muse(req):
    # WithEcho 碎碎念: AI-written notes about the user's day that quote what they said; for Style.md only.
    data = fetch('muse','--limit',str(min(int(req.get('limit') or 40),100)))
    since = req.get('since') or ''
    sources = [{'event_id':m.get('muse_id',''),'date':(m.get('created_at') or '')[:10],'title':'碎碎念','body':m.get('content','')}
               for m in data.get('muses',[]) if m.get('content') and (m.get('created_at') or '')[:10] >= since]
    return {'sources':sources,'cache':(data.get('_cache') or {}).get('source') or 'unknown'}

def run(req):
    action = req.get('action')
    if action == 'retrieve':
        return retrieve(req)
    if action == 'details':
        return details(req)
    if action == 'muse':
        return muse(req)
    if action == 'hybrid':
        import memory_index
        return memory_index.hybrid(req.get('query'), req.get('sources'), model=req.get('model') or memory_index.DEFAULT_MODEL, use_vectors=req.get('use_vectors', True))
    if action == 'warm':
        # Background pre-embedding. Sources must be built exactly as the retrieval path
        # builds them: chunk hashes are content-addressed, so any drift warms nothing.
        import memory_index
        sources = req.get('sources')
        if not isinstance(sources, list):
            raise ValueError('warm 需要 sources 数组。')
        budget = req.get('budget_seconds', 60)
        if not isinstance(budget, (int, float)) or isinstance(budget, bool) or not 0 < budget <= 600:
            raise ValueError('warm 预算必须是 1—600 秒。')
        return {'index': memory_index.warm(sources, model=req.get('model') or memory_index.DEFAULT_MODEL, budget_seconds=budget)}
    if action == 'index_status':
        import memory_index
        return memory_index.status(model=req.get('model') or memory_index.DEFAULT_MODEL)
    if action == 'index_clear':
        import memory_index
        return memory_index.clear()
    if action == 'lark_sync':
        import lark  # only when Feishu meetings are on
        return lark.sync(req)
    if action == 'login':
        p = subprocess.run([sys.executable,str(ROOT/'auth.py'),'login'], capture_output=True,text=True,timeout=310)
        if p.returncode:
            raise ValueError('授权未完成，请重试连接 WithEcho。')
        return {'message':'WithEcho 授权完成，可以切换到真实数据。'}
    raise ValueError(f'unsupported_action:{action}')

if __name__ == '__main__':
    try:
        result = run(json.load(sys.stdin))
        print(json.dumps(result,ensure_ascii=False))
    except Exception as e:
        print(json.dumps({'error':str(e)},ensure_ascii=False))

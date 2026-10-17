#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""




































from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

JOB_PREFIX = "extract/jobs/"
OUT_PREFIX = "extract/out/"

#: 认领多久算过期。**必须明显长于一次抽取**(实测 100 秒;v2.5 两阶段 4.8 分钟)——
#: 短了的话上一轮还在跑、下一轮就以为它死了又跑一次,而两次都真花钱。
CLAIM_TTL_SEC = 20 * 60

#: 两轮之间歇多久。抽取本身以分钟计,轮询密一点没意义。
POLL_SEC = 20

#: 空转时多久打一行心跳。
#:
#: 🔴 **不是为了好看,是为了让「日志不动」只有一种解释。**
#: 在此之前这个 daemon **只在有待办时才打印** ⇒ 闲了一天的日志和挂了一天的日志
#: 长得一模一样,而 `scripts/daemons.sh status` 只能看 mtime
#: ⇒ 它给出的提示是「确认它是闲着还是挂了」——**把判断推回给人**,
#: 而那正是这个脚本存在的意义要挡掉的东西(见 daemons.sh 头部)。
HEARTBEAT_SEC = 600

#: 静默多久算死。**这个数由 daemon 自己声明、写进每一行心跳**,
#: `daemons.sh` 从日志里读它 —— 不许 shell 那边再写一个(铁律 4:
#: 两处各写一份「多久算死」,改一边忘另一边**不会有任何东西红**)。
MAX_SILENCE_SEC = 2 * HEARTBEAT_SEC

PROXY = os.environ.get("GROWTH_PROXY_URL", "https://apt-backend.example")


def _client():
    """R2 的 S3 兼容客户端。密钥来自仓外的 `secrets.env`,**不进版本库**。"""
    need = ["R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"]
    missing = [k for k in need if not os.environ.get(k)]
    if missing:
        sys.exit(f"🔴 缺环境变量 {missing} —— "
                 f"先 `set -a; . ~/.config/growth-agent/secrets.env; set +a`")
    return boto3.client(
        "s3",
        endpoint_url=f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name="auto",
        config=Config(signature_version="s3v4",
                      # 抽取一次几分钟,而这一跳只是排队/回写,快得多。
                      read_timeout=120, retries={"max_attempts": 3}),
    )


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _call_proxy(prompt: str, timeout: int, *, scene: str = "extract",
                max_tokens: int | None = None, provider: str | None = None) -> str:
    """经云代理送一次抽取。**记账在那一侧**,见文件头。

    `scene` / `provider` 透传给云代理:两阶段(`M2-成7`)按 `extract_s1`/`extract_s2`
    分开记账,双败时换 `deepseek-flash` 兜底 —— **记账记的是实际用的模型**,
    兜底那次真走了别的模型,账上就该是别的模型。"""
    import urllib.request

    token = os.environ.get("GROWTH_CLIENT_TOKEN")
    if not token:
        raise RuntimeError("缺 GROWTH_CLIENT_TOKEN")
    payload: dict = {"scene": scene,
                     "messages": [{"role": "user", "content": prompt}]}
    if max_tokens:
        payload["max_tokens"] = max_tokens
    if provider:
        payload["provider"] = provider
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{PROXY}/extract", data=body,
        headers={"X-Growth-Token": token, "Content-Type": "application/json",
                 "Accept": "application/x-ndjson",
                 # ⚠️ **必须给 UA**。2026-08-21 实测:Python urllib 的默认 UA
                 # 被 Cloudflare 挡成 **403**,而那与业务代码无关 ——
                 # 不写这一条的话,将来撞上会有人去查错的地方。
                 "User-Agent": "growth-extract-daemon/1"})
    deadline = time.monotonic() + timeout
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = _read_proxy_response(r, deadline)
    content = d.get("content")
    if not content:
        raise RuntimeError(f"云代理没给正文:{json.dumps(d, ensure_ascii=False)[:300]}")
    return content


def _read_proxy_response(response, deadline: float) -> dict:
    """协商心跳流仍只接受一个完整终态；兼容旧JSON，绝不把EOF当成功。"""
    def limit_read():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("抽取流超过单次调用窗口")
        # urllib.HTTPResponse 没有公开的 settimeout；更新实际socket，
        # 防止临近截止时一次readline又阻塞完整900秒。BytesIO仅供离线回归。
        sock = getattr(getattr(getattr(response, "fp", None), "raw", None), "_sock", None)
        if sock is not None:
            sock.settimeout(remaining)

    limit_read()
    if "application/x-ndjson" not in response.headers.get("Content-Type", ""):
        return json.loads(response.read())
    for _ in range(128):
        limit_read()
        raw = response.readline(2 * 1024 * 1024 + 1)
        if time.monotonic() >= deadline:
            raise TimeoutError("抽取流超过单次调用窗口")
        if not raw or len(raw) > 2 * 1024 * 1024 or not raw.endswith(b"\n"):
            raise RuntimeError("抽取流中断或帧超出上限")
        frame = json.loads(raw.decode("utf-8"))
        if not isinstance(frame, dict):
            raise RuntimeError("抽取流帧无效")
        if frame.get("type") == "ping":
            continue
        if frame.get("type") != "result" or type(frame.get("status")) is not int or not isinstance(frame.get("body"), dict):
            raise RuntimeError("抽取流终态无效")
        if frame["status"] != 200:
            raise RuntimeError(f"云代理抽取失败({frame['status']}):{str(frame['body'].get('error', '未知错误'))[:200]}")
        return frame["body"]
    raise RuntimeError("抽取流心跳超过上限，未收到终态")


def _run(job: dict, timeout: int, log=print) -> str:
    """跑一个 job,返回抽取产物的 JSON 文本。

    ## 两条路,按 job 里有什么决定(`M2-成7`)

    · `lines` ⇒ **两阶段 R5**(v2.5 的新逻辑):候选块代码预切、模型逐块打标、
      event 边界与 event_id 全由代码派生。多次模型调用都在这里发生。
    · `prompt` ⇒ v1 单次调用。**保留它不是过渡期的凑合** ——
      切换那一刻队列里还躺着 v1 的 job,丢掉它们等于让那几场永远不出稿。

    🔴 **两阶段是 fail-closed**:每阶段重试一次 → 换 deepseek-flash 兜底两次 → 抛。
    抛出来由调用方保留 job、下一轮再试。**不许改成 fail-open** ——
    那会让「抽取失败」和「这场真没内容」长得一样(PRD 附录 E.3 缺陷 4)。
    """
    if job.get("lines"):
        import sys as _sys
        _sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        from worker import extract_two_stage as two

        def call(prompt: str, *, scene: str, max_tokens: int, provider=None) -> str:
            return _call_proxy(prompt, timeout, scene=scene,
                               max_tokens=max_tokens, provider=provider)

        payload, stats, meta = two.run(job["lines"], model_call=call)
        # ⚠️ **重试率要能被看见**:实测两场的 Stage 2 都是首试失败、重试即过。
        # 重试率涨 = 上游在变差,而产出看起来一切正常 —— 它是生产监控的一级指标。
        retries = sum(1 for a in meta.get("attempts", []) if not a.get("ok"))
        if job["lines"][0].get("action_only"):
            log(f"   整场个人行动: {len(payload.get('personal_actions', []))} 条 · 重试 {retries} 次")
            return json.dumps(payload, ensure_ascii=False)
        log(f"   两阶段:候选 {meta.get('candidates')} 块 · 分组 {meta.get('groups')} · "
            f"展示 {len(payload.get('events', []))} 件 · 无重点 {len(meta.get('suppressed_event_ids', []))} 组 · "
            f"重试 {retries} 次 · 三项校验丢弃 {stats.discarded}")
        return json.dumps(payload, ensure_ascii=False)
    return _call_proxy(job["prompt"], timeout)


def run_once(s3, bucket: str, *, timeout: int, log=print) -> dict:
    """跑一轮:把能认领的 job 跑掉。返回这一轮的计数。"""
    listed = s3.list_objects_v2(Bucket=bucket, Prefix=JOB_PREFIX, MaxKeys=100)
    objs = listed.get("Contents", [])
    ran = skipped = failed = 0

    for obj in objs:
        key = obj["Key"]
        out_key = OUT_PREFIX + key[len(JOB_PREFIX):]
        # 先落产物、后删 job；清理失败时只重试清理，不能再买一次模型调用。
        try:
            s3.head_object(Bucket=bucket, Key=out_key)
        except ClientError as e:
            if str(e.response.get("Error", {}).get("Code")) not in {"404", "NoSuchKey", "NotFound"}:
                log(f"🔴 {key} 无法确认产物是否已存在:{e}")
                failed += 1
                continue
        else:
            try:
                s3.delete_object(Bucket=bucket, Key=key)
            except Exception as e:                  # noqa: BLE001
                log(f"🔴 {key} 已有终态产物，清理待重试:{e}")
                failed += 1
            skipped += 1
            continue
        try:
            job = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
        except Exception as e:                       # noqa: BLE001
            # 读不懂的 job 要**留痕**,不能悄悄跳过 —— 悄悄跳过的表现是
            # 「这一块永远不出纪要」,而队列看起来一切正常。
            log(f"🔴 {key} 读不出来:{e}")
            failed += 1
            continue

        if not job.get("prompt") and not job.get("lines"):
            log(f"🔴 {key} 既没有 prompt 也没有 lines,跳过"
                f"(不删:删了就没人知道曾经有一块没抽成)")
            failed += 1
            continue

        claimed = job.get("claimed_at")
        if claimed:
            try:
                age = time.time() - datetime.fromisoformat(claimed).timestamp()
            except Exception:                        # noqa: BLE001
                age = CLAIM_TTL_SEC + 1              # 认领时间看不懂 ⇒ 当它过期
            if age < CLAIM_TTL_SEC:
                skipped += 1
                continue

        # 认领。⚠️ 这不是原子的 —— 单消费者才安全,见文件头「不能同时抢」。
        job["claimed_at"] = _now()
        job["claimed_by"] = "mac"
        s3.put_object(Bucket=bucket, Key=key, Body=json.dumps(job, ensure_ascii=False).encode(),
                      ContentType="application/json")

        session, part = job.get("session"), job.get("part", 0)
        t0 = time.time()
        try:
            content = _run(job, timeout, log=log)
        except Exception as e:                       # noqa: BLE001
            # 失败**保留 job**(认领会过期,下一轮再试),并且**不写成产物** ——
            # 写了手机会把一份空纪要当成抽完了,而空产物落库会永久挡住重抽
            # (`M2-成2` 那条)。
            # 新行动协议在内部有界尝试后失败就留下错误终态；不再无限买同一份结果。
            header = (job.get("lines") or [{}])[0]
            if header.get("action_protocol") == "personal-actions/v1" or "personal-actions/v1" in (job.get("prompt") or ""):
                s3.put_object(Bucket=bucket, Key=out_key, Body=json.dumps({"terminal": True, "error": "个人行动识别失败，请重新识别这场录音。"}).encode(), ContentType="application/json")
                s3.delete_object(Bucket=bucket, Key=key)
                failed += 1
                log(f"🔴 场次 {session} 块 {part} 行动识别失败，已停止自动付费重试")
                continue
            job["last_error"] = str(e)[:500]
            job["attempts"] = job.get("attempts", 0) + 1
            s3.put_object(Bucket=bucket, Key=key,
                          Body=json.dumps(job, ensure_ascii=False).encode(),
                          ContentType="application/json")
            log(f"🔴 场次 {session} 块 {part} 第 {job['attempts']} 次失败:{str(e)[:160]}")
            failed += 1
            continue

        # 🔴 **产物的键由 job 的键推出来,不重新拼。**
        #
        # 云代理发给手机的 `ticket` 就是 job 键去掉前缀与 `.json`
        # (`extract_queue.js`:`ticket = `${session}-${part}-${fp}``),
        # 而手机取产物时 Worker 找的是 `extract/out/<ticket>.json`。
        #
        # ⚠️ 这里原来拼的是 `{session}-{part}.json` —— **少了指纹**。
        # 于是 Mac 抽完写 `29-0.json`,手机拿着 `29-0-<指纹>` 去取,**永远取不到**;
        # 而 job 已经被下面那行删掉,手机下一拍**重新排一份**,Mac **再抽一次**
        # ⇒ 一个**每拍都真花钱**的环,而两端都不报错:
        # daemon 日志说「抽完了」,手机说「云端正在抽」。
        # (2026-08-25 发现时它还没开始烧钱,只因为 daemon 跑的是旧代码、
        #  把所有两阶段 job 都拒了 —— 两个缺陷互相盖住了。)
        #
        # ⇒ 从 job 键推,两者**结构上就不可能漂**,不是「记得同步改」。
        out_key = OUT_PREFIX + key[len(JOB_PREFIX):]
        s3.put_object(Bucket=bucket, Key=out_key,
                      Body=content.encode(), ContentType="application/json")
        s3.delete_object(Bucket=bucket, Key=key)
        ran += 1
        log(f"✅ 场次 {session} 块 {part} 抽完,用时 {time.time() - t0:.0f} 秒,"
            f"产物 {len(content)} 字符")

    return {"ran": ran, "skipped": skipped, "failed": failed, "pending": len(objs)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--once", action="store_true", help="跑一轮就退")
    ap.add_argument("--bucket", default=os.environ.get("R2_BUCKET", "growth-audio"))
    # 抽取一次实测 100 秒;v2.5 两阶段 4.8 分钟。给足余量,**别让超时变成重复付费**。
    ap.add_argument("--timeout", type=int, default=900, help="单次调用超时(秒)")
    a = ap.parse_args()

    s3 = _client()
    print(f"▸ 抽取 daemon 起来了 · bucket={a.bucket} · 云代理={PROXY} · "
          f"轮询 {POLL_SEC}s · 单次超时 {a.timeout}s", flush=True)
    # 起来就先打一条 —— 否则「刚起来还没到第一个心跳」这段时间里,
    # 日志是空的,而空日志在 status 那边等于「每次起来就崩」。
    last_beat = 0.0
    while True:
        try:
            r = run_once(s3, a.bucket, timeout=a.timeout)
            if r["pending"]:
                print(f"[{datetime.now():%H:%M:%S}] 待办 {r['pending']} · 跑 {r['ran']} · "
                      f"跳过 {r['skipped']} · 失败 {r['failed']}", flush=True)
                last_beat = time.time()
            elif time.time() - last_beat >= HEARTBEAT_SEC:
                # ⚠️ 这一行**必须带上 `最多 N 秒不吭声`** —— `daemons.sh` 就是读它
                # 来判死的。改了格式那边会退回默认阈值,所以格式变了要一起改。
                print(f"[{datetime.now():%H:%M:%S}] 心跳 · 队列空 · "
                      f"最多 {MAX_SILENCE_SEC} 秒不吭声", flush=True)
                last_beat = time.time()
        except Exception as e:                       # noqa: BLE001
            # 整轮挂了也不许退出 —— 退出的表现是「从此再也不抽」,而没人会发现。
            print(f"🔴 这一轮整个挂了(下一轮照跑):{e}", flush=True)
            last_beat = time.time()
        if a.once:
            return 0
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    raise SystemExit(main())

"""Generic implementation; local private materials are not distributed."""
























from __future__ import annotations

import json
import os
import pathlib
import re
import sys
import tempfile
import time

from mac import diarize_subprocess
from dataclasses import dataclass

PENDING_PREFIX = "asr/pending/"     # 与 worker/src/collector.js 逐字一致
RESULT_PREFIX = "asr/result/"       # 同上

#: 超过这么久还没结果就换路。**暂定值**,理由见 `TASKS.md` 的 `M1-34` G 条:
#: 仓里至今没有一条满尺寸块的 submit→result 时延记录,所以这个数没有实测依据。
#: 它比任何正常值都大得多(实测正常是秒级到分钟级),所以今天定它无害;
#: **但别把它当成量出来的**——有了分布再改。
STUCK_AFTER_SEC = 10 * 60

#: 一块最多换路几次。**每次都要花钱**,所以必须有上限。
#: 取 1:换路是兜底,兜底再失败说明问题不在这条路上,再打第二次只是买单。
MAX_SSE_ATTEMPTS = 1

#: 一次扫最多换几块。**cron 一分钟一次而一块 SSE 实测要 49 秒** ——
#: 不限的话上一轮还没跑完下一轮就开跑,对同一块发起第二次 = 纯重复付费。
MAX_PER_RUN = 1


@dataclass
class Outcome:
    scanned: int = 0
    stuck: int = 0
    switched: int = 0
    failed: int = 0
    notes: list[str] = None

    def __post_init__(self):
        if self.notes is None:
            self.notes = []


SENTENCE_END = "。！？!?…"          # 逗号不算 —— 它切出来的不是句子


def _merge_to_sentences(segments):
    """Generic implementation; local private materials are not distributed."""














    out, buf, start, end = [], [], None, None
    for seg in segments:
        t = seg.text or ""
        if not t:
            continue
        if not buf:
            start = seg.start_ms
        buf.append(t)
        end = seg.end_ms
        tail = t.rstrip()
        if tail and tail[-1] in SENTENCE_END:
            out.append(("".join(buf).strip(), start, end))
            buf, start, end = [], None, None
    if buf:                                   # 末尾没有标点收尾的残句,不丢
        out.append(("".join(buf).strip(), start, end))
    return [(t, a, b) for t, a, b in out if t]


def speech_seconds(result) -> float:
    """这一块 ASR 认为有多少秒语音 —— **分人检出率闸的分母**(`M2-认6`)。

    按合成后的**句子**算,不按字级 delta 累加:delta 之间会挨着甚至重叠,
    加起来的数没有物理意义,而闸是拿它当分母的。
    """
    return sum((b - a) for _, a, b in _merge_to_sentences(result.segments)
               if a is not None and b is not None) / 1000.0


def as_file_endpoint_shape(result, duration_sec: float | None,
                           turns: list[tuple[int, int, str]] | None = None) -> dict:
    """把 SSE 的产出转成**文件端点那个形状**。

    🔴 **靶子是两个消费方,不是一个。** 手机侧要过两道:
    · `ProxyClient.classify` —— 只在**顶层 `result` 非空**时判 `.done`,
      否则返回 `.unknown` ⇒ 按 pending 处理 ⇒ **永远轮询下去**
      (那个洞 2026-08-17 花了「提交十一分钟、问过四次、状态纹丝不动」才填上);
    · `ASRResponseParser` —— 只认 `utterances / sentences / segments`。
    ⇒ 唯一同时满足两者的形状:`{"duration":…, "result":[{"utterances":[…]}]}`。

    ~~⚠️ **没有 speaker 字段**,这是事实不是遗漏:SSE 流里 `speaker` 出现 0 次。~~
    🔴 **2026-09-02 补上了**(`M2-认6`):SSE 流确实不给,但 **Mac 自己能分**
    (`mac/diarize_subprocess.turns_for`)。传了 `turns` 就按时间重叠给每条句子
    贴标签,形状与文件端点**逐字一致**(`{"speaker": {"id": "speaker_0"}}`,
    2026-08-17 真机抓的那个形状)⇒ **手机侧一行都不用改**。

    ⚠️ 归行用 `align.speaker_of` —— 那条规则的唯一出处,与旧链路共用。
    重叠为 0 的句子**不给标签**:「不知道这句是谁说的」与「是某个人」是两件事。

    `growth_no_speaker` 仍然是给手机侧的**明示标记**:分人没做成(`turns is None`)
    时留 True —— 不带的话,「上游没给分人」与「这一场只有一个人说话」
    在库里长得一模一样。
    """
    from mac.align import speaker_of

    utterances = []
    for t, a, b in _merge_to_sentences(result.segments):
        u = {"text": t, "start_time": a if a is not None else 0,
             "end_time": b if b is not None else 0}
        if turns and a is not None and b is not None:
            hit = speaker_of(a, b, turns)
            # ⚠️ 低置信(重叠占比小)**照样给标签,不加后缀**:下游是声纹判决,
            # 它自己有 τ 与投票;而带 `?` 的标签会让「同一个人」在句与句之间
            # 分成两个簇(旧链路那个 `?` 是给人看的,不是给判决看的)。
            if hit is not None:
                u["speaker"] = {"id": hit[0]}
        utterances.append(u)
    if not utterances and (result.full_text or "").strip():
        # 一句都没切出来但有全文 —— 整段当一句,别丢内容。
        utterances = [{"text": result.full_text.strip(), "start_time": 0,
                       "end_time": int((duration_sec or 0) * 1000)}]
    return {
        "duration": duration_sec,
        "result": [{"utterances": utterances}],
        # 🔴 降级标记。手机侧据它在界面上显示「这一块没有分人」。
        "growth_no_speaker": turns is None,
        "growth_source": "sse_fallback",
    }


def _write_terminal_failure(storage, meta: dict, reason: str) -> None:
    """Generic implementation; local private materials are not distributed."""
















    task_id = meta.get("task_id")
    if not task_id:
        return
    storage.put(
        f"{RESULT_PREFIX}{task_id}.json",
        json.dumps({
            "verdict": "failed",
            "body": json.dumps({"error": "sse fallback failed", "detail": reason[:500]},
                               ensure_ascii=False),
            "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "from": "mac_sse_fallback",
        }, ensure_ascii=False).encode("utf-8"))


def _pending_records(storage) -> list[tuple[str, dict]]:
    out = []
    for key in storage.list(PENDING_PREFIX):
        if not key.endswith(".json"):
            continue
        try:
            out.append((key, json.loads(storage.get(key).decode("utf-8"))))
        except Exception as e:                       # noqa: BLE001
            # §3.2:兜底的 except 要么记录要么抛,不要 pass。
            out.append((key, {"_broken": str(e)}))
    return out


def _age_sec(meta: dict, now: float) -> float | None:
    at = meta.get("submitted_at")
    if not at:
        return None
    try:
        import datetime
        t = datetime.datetime.fromisoformat(at.replace("Z", "+00:00"))
        return now - t.timestamp()
    except Exception:                                # noqa: BLE001
        return None


def scan(storage, *, now: float | None = None, dry_run: bool = False,
         transcribe=None, api_key: str | None = None) -> Outcome:
    """扫一遍待办,把卡住的块换到 SSE。

    - Parameter transcribe: 注入的转写函数(测试用)。生产传 `asr_stepfun.transcribe`。
    """
    now = now or time.time()
    out = Outcome()

    for key, meta in _pending_records(storage):
        out.scanned += 1
        if "_broken" in meta:
            out.notes.append(f"{key}:待办读不出来({meta['_broken']})")
            continue
        # 🔴 **已经换过路的直接跳过,而且待办不删。**
        # 删待办会捅穿云代理那道防重复付费的闸(它的判据就是「待办还在 = 复用」);
        # 不标记又会被收割器无条件覆盖、被 6 小时兜底写成失败
        # ⇒ 一块已经靠 SSE 出稿的音频几小时后在 R2 里变成失败记录。
        if meta.get("switched_to_sse"):
            continue
        age = _age_sec(meta, now)
        if age is None:
            out.notes.append(f"{key}:待办里没有 submitted_at,判不了年龄")
            continue
        if age < STUCK_AFTER_SEC:
            continue
        out.stuck += 1
        if out.switched >= MAX_PER_RUN:
            out.notes.append(f"{key}:本轮名额用完(一块 SSE 实测约 49 秒),下轮再来")
            continue
        if int(meta.get("sse_attempts", 0)) >= MAX_SSE_ATTEMPTS:
            out.notes.append(f"{key}:换路已达上限 {MAX_SSE_ATTEMPTS} 次,不再买单")
            continue
        if dry_run:
            out.notes.append(f"{key}:该换路(已等 {int(age/60)} 分钟)")
            out.switched += 1
            continue
        out.switched += 1
        try:
            _switch_one(storage, key, meta, transcribe=transcribe, api_key=api_key)
        except Exception as e:                       # noqa: BLE001
            out.failed += 1
            out.notes.append(f"{key}:换路失败 —— {e}")
            # 次数用尽 ⇒ 没有下一次了 ⇒ **必须把失败写成结果**,
            # 否则收割器已跳过、兜底不再买单,这一块就永久悬空(见函数注释)。
            if int(meta.get("sse_attempts", 0)) + 1 >= MAX_SSE_ATTEMPTS:
                _write_terminal_failure(storage, meta, str(e))
                out.notes.append(f"{key}:已写终态失败 —— 手机会看到失败,不再空轮询")
    return out


def _switch_one(storage, pending_key: str, meta: dict, *, transcribe, api_key):
    """把一块换到 SSE。**先认领再干活** —— 认领写失败就不发请求。"""
    task_id = meta.get("task_id")
    audio_key = meta.get("key")
    if not task_id or not audio_key:
        raise ValueError(f"待办缺 task_id/key:{meta!r}")

    # ① 认领。cron 一分钟一次而一块 SSE 要 49 秒 —— 不先认领,
    #    下一拍会看到同一条仍超龄的待办,对同一块发起第二次(纯重复付费)。
    claimed = dict(meta)
    claimed["switched_to_sse"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    claimed["sse_attempts"] = int(meta.get("sse_attempts", 0)) + 1
    storage.put(pending_key, json.dumps(claimed, ensure_ascii=False).encode("utf-8"))

    # ② 拉音频 → 转写。`transcribe` 内部自己转 mp3(实测 SSE 端点收 mp3)。
    audio = storage.get(audio_key)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        f.write(audio)
        path = f.name
    turns = None
    try:
        result = transcribe(path, api_key)
        # 🔴 **分人在这里做,不在别处**(`M2-认6`):同一份 wav,而下面 `finally` 就删了它。
        # `turns_for` 自己吞掉一切异常并带检出率闸 —— 它返回 None 时照旧发无分人稿。
        turns = diarize_subprocess.turns_for(path, speech_seconds(result))
    finally:
        os.unlink(path)

    # ③ 记账。**与付费调用落在同一处** —— 原则 5「每个付费调用接入的同时接记账」。
    #    这条腿走的是 SSE 端点、由 Mac 直接发,**不经过 worker**,所以 worker 那套
    #    往 `usage/` 前缀写的账根本看不到它。不在这儿记,这笔开销就等于不存在,
    #    而下次有人算「转写一天花多少」时会拿一个漏了兜底腿的数去做决定。
    #    log_asr 自吞异常(与 _log_usage 同纪律):账落不下,不该把已经转好的稿弄丢。
    from shared.model_router import log_asr
    log_asr(meta.get("seconds") or 0, scene="asr_sse_fallback", path=audio_key)

    # ④ 写结果。形状必须同时喂饱两个消费方,见 `as_file_endpoint_shape`。
    payload = as_file_endpoint_shape(result, meta.get("seconds"), turns=turns)
    storage.put(f"{RESULT_PREFIX}{task_id}.json",
                json.dumps({"verdict": "done", "body": json.dumps(payload, ensure_ascii=False),
                            "at": claimed["switched_to_sse"], "from": "mac_sse_fallback"},
                           ensure_ascii=False).encode("utf-8"))


def worker_bucket_name() -> str | None:
    """从 `worker/wrangler.toml` 读 worker 真正写的桶名 —— 桶名的**唯一出处**在那边。

    读不到就返回 None(不硬失败):这道对撞是加固,不该因为找不到文件把整条腿弄停。
    """
    toml = pathlib.Path(__file__).resolve().parent.parent / "worker" / "wrangler.toml"
    if not toml.exists():
        return None
    m = re.search(r'^\s*bucket_name\s*=\s*"([^"]+)"', toml.read_text(), re.M)
    return m.group(1) if m else None


def main(argv: list[str]) -> int:
    from mac import r2_service
    from mac import asr_stepfun

    key = os.environ.get("STEPFUN_API_KEY")
    if not key:
        print("缺 STEPFUN_API_KEY —— 不猜,直接退出", file=sys.stderr)
        return 2

    # 🔴 **2026-08-19 作废上一版注释**(它说「Mac 侧至今没有 R2 凭证,四个变量都不存在」)。
    # 当时那句是我没查就写的,**四个变量一直都在** `secrets.env` 里。
    # 但结论方向歪打正着 —— 真相更坏:凭证在,却指着**另一个桶**。
    # 现有 access key 的作用域是 `growth-agent`(旧仓 2026-08-06 建的),
    # 而 worker 写的是 `growth-audio`(2026-08-13 建的)。实测:列 `growth-audio` → AccessDenied。
    need = ["R2_BUCKET", "R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"]
    missing = [n for n in need if not os.environ.get(n)]
    if missing:
        print(f"缺 R2 凭证:{missing}\n"
              f"  它们该放进 ~/.config/growth-agent/secrets.env(仓外,不进版本库)。\n"
              f"  桶名与 account id 在 Cloudflare 控制台;access key 要建一个\n"
              f"  **只读 inbox/ + 读写 asr/ 的** API 令牌,别给全桶写权限。",
              file=sys.stderr)
        return 2

    # 🔴 铁律 4 的形状,而且**已经真的发生了**:桶名有两份,对不上时没有任何东西会红 ——
    # 扫错桶的表现是「扫了 0 条」,与「一切正常,没有卡住的活」**在输出上一模一样**。
    # ⇒ 开跑前拿 worker 的 `wrangler.toml` 对一次。**比源码不比数据**:
    #   数据断言只能证明「今天这个桶里有东西」,挡不住桶名将来又被改一处。
    want = worker_bucket_name()
    if want and os.environ["R2_BUCKET"] != want:
        print(f"桶名对不上:R2_BUCKET={os.environ['R2_BUCKET']!r},"
              f"而 worker/wrangler.toml 写的是 {want!r}。\n"
              f"  照 R2_BUCKET 扫会扫到一个没有待办的桶,输出是「扫 0 条」——\n"
              f"  和「没有卡住的活」看起来完全一样,所以这里必须硬失败,不能往下走。",
              file=sys.stderr)
        return 2

    storage = r2_service.R2Storage(
        bucket=os.environ["R2_BUCKET"], account_id=os.environ["R2_ACCOUNT_ID"],
        access_key=os.environ["R2_ACCESS_KEY_ID"],
        secret_key=os.environ["R2_SECRET_ACCESS_KEY"])
    out = scan(storage, dry_run="--dry-run" in argv,
               transcribe=asr_stepfun.transcribe, api_key=key)
    print(f"扫 {out.scanned} 条 · 卡住 {out.stuck} · 换路 {out.switched} · 失败 {out.failed}")
    for n in out.notes:
        print("  -", n)
    return 1 if out.failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

"""StepAudio 2.5 ASR SSE 客户端（并入 growth-agent）。

接口契约（来自 platform.stepfun.com 文档）：
  POST {step_plan 优先，失败 fallback 非 plan}/audio/asr/sse   见 ASR_URLS
  Authorization: Bearer $STEPFUN_API_KEY
  Content-Type: application/json   Accept: text/event-stream
  body: {"audio": {"data": <base64>, "input": {"transcription": {...}, "format": {...}}}}

返回 SSE：逐条 transcript.text.delta（开 enable_timestamp 时带 start_time/end_time 毫秒、字级），
以 transcript.text.done 结束。**注：整条长音频的 done 不回聚合文本，靠拼 delta 兜底。**

音频默认转 **mp3** 发（不发裸 PCM）：mp3 体积只有 PCM 的 ~1/4，整条 86min 才 41MB、一个
请求就能转完全程，不必再切「12 分钟」（那是被 PCM 体积逼出来的伪限制）。详见下方常量注释。

并入改动（vs meeting-notes 原版）：
- `requests` 改为**函数内惰性 import**——`import ingest.meeting` 不应硬依赖它（虽然轻，但保持
  「import 包不触发任何外部依赖」的纪律，与 torch/modelscope/soundfile 一致）。
- key 来源统一走 growth：调用方从 model_router.load_secrets() 注入的 STEPFUN_API_KEY 取，
  transcribe()/process() 不再读 meeting-notes 的 STEP_API_KEY（见 run.py）。
- 字段名/层级以真实接口为准——先跑 spike 验证，本模块对字段做防御性读取。
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import time
from dataclasses import dataclass, field
from typing import Any

ASR_URLS = (
    "https://api.stepfun.com/step_plan/v1/audio/asr/sse",
    "https://api.stepfun.com/v1/audio/asr/sse",
)
MODEL = "stepaudio-2.5-asr"

_MP3_BITRATE = "64k"                     # 16k mono 64k：质量≈裸PCM，体积 0.48MB/min
_MP3_BYTES_PER_SEC = 64_000 // 8         # 估算用：≈8000 B/s（CBR，实测与真实体积吻合）
_MP3_MAX_BYTES = 42 * 1024 * 1024        # 单请求上限：41.4MB/86min 实测过，留一点余量≈87min
_MP3_CHUNK_SECONDS = 80 * 60             # 超上限才切：每片 80min(≈38MB)，2.6h 录音→2 片
_INTER_CHUNK_SLEEP = 7.0
_VAD_MIN_SAVE_SEC = float(os.environ.get("GROWTH_VAD_MIN_SAVE_SEC", "600"))
_RATE_LIMIT_RETRIES = 5


def _requests():
    """惰性取 requests（保持 import 包零外部依赖；真要转写时才需要它）。"""
    import requests  # noqa: PLC0415
    return requests


@dataclass
class Segment:
    text: str
    start_ms: int | None
    end_ms: int | None


@dataclass
class ASRResult:
    full_text: str
    segments: list[Segment] = field(default_factory=list)
    raw_events: list[dict[str, Any]] = field(default_factory=list)


def _ffmpeg() -> str:
    """解析 ffmpeg 路径——launchd daemon 的 PATH 很窄，bare 'ffmpeg' 找不到（ffmpeg 在 ~/.local/bin）。"""
    import os
    import shutil
    from pathlib import Path
    return (os.environ.get("GROWTH_FFMPEG") or shutil.which("ffmpeg")
            or str(Path.home() / ".local" / "bin" / "ffmpeg") or "ffmpeg")


def _ffprobe() -> str:
    """解析 ffprobe 路径——同 _ffmpeg 的窄 PATH 问题；优先环境/which，再退 ffmpeg 同目录。"""
    import os
    import shutil
    from pathlib import Path
    cand = os.environ.get("GROWTH_FFPROBE") or shutil.which("ffprobe")
    if cand:
        return cand
    sib = Path(_ffmpeg()).with_name("ffprobe")     # 多数发行版 ffprobe 和 ffmpeg 同目录
    return str(sib) if sib.exists() else "ffprobe"


def _audio_duration(audio_path: str) -> float | None:
    """ffprobe 读时长（秒）。读不到返回 None——调用方退化为「先编码再按实际体积判」。"""
    proc = subprocess.run(
        [_ffprobe(), "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", audio_path],
        capture_output=True,
    )
    try:
        return float(proc.stdout.decode("utf-8", "ignore").strip())
    except (ValueError, AttributeError):
        return None


def audio_to_mp3(audio_path: str, *, bitrate: str = _MP3_BITRATE,
                 start_sec: float | None = None, dur_sec: float | None = None) -> bytes:
    """转成 16k 单声道 mp3 字节（默认整条；给 start/dur 则只编码该时间片，供长音频切片）。

    -ss 放 -i 前是快速 seek；-f mp3 直接吐到 stdout，不落临时文件。
    """
    cmd = [_ffmpeg(), "-y"]
    if start_sec is not None:
        cmd += ["-ss", str(start_sec)]
    cmd += ["-i", audio_path]
    if dur_sec is not None:
        cmd += ["-t", str(dur_sec)]
    cmd += ["-ar", "16000", "-ac", "1", "-b:a", bitrate, "-f", "mp3", "-"]
    proc = subprocess.run(cmd, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg 转 mp3 失败: {proc.stderr.decode('utf-8', 'ignore')[-500:]}")
    if not proc.stdout:
        raise RuntimeError("ffmpeg mp3 输出为空——音频可能无有效音轨")
    return proc.stdout


def audio_to_pcm16k(audio_path: str) -> bytes:
    """用 ffmpeg 把任意输入转成 16k 单声道 16bit 裸 PCM（s16le），匹配文档 format 块。

    注：转写主路已改走 mp3（见 transcribe）；保留本函数供需要裸 PCM 的旧调用方。
    """
    proc = subprocess.run(
        [_ffmpeg(), "-i", audio_path, "-f", "s16le", "-acodec", "pcm_s16le",
         "-ar", "16000", "-ac", "1", "-"],
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg 转码失败: {proc.stderr.decode('utf-8', 'ignore')[-500:]}")
    if not proc.stdout:
        raise RuntimeError("ffmpeg 输出为空——音频可能无有效音轨")
    return proc.stdout


def audio_to_wav16k(audio_path: str, out_path: str) -> str:
    """转成 16k 单声道 wav 落盘，供本地 diarization 用（soundfile 读不了 m4a）。"""
    proc = subprocess.run(
        [_ffmpeg(), "-y", "-i", audio_path, "-ar", "16000", "-ac", "1", out_path],
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg 转 wav 失败: {proc.stderr.decode('utf-8', 'ignore')[-500:]}")
    return out_path


def _build_payload(data_b64: str, fmt: str, language: str,
                   enable_timestamp: bool, enable_itn: bool) -> dict:
    """fmt='mp3'（主路）或 'pcm'（旧路）。mp3 不用带 rate/bits/channel（文档：仅 pcm 必填）。"""
    if fmt == "mp3":
        format_block = {"type": "mp3"}
    else:
        format_block = {"type": "pcm", "codec": "pcm_s16le",
                        "rate": 16000, "bits": 16, "channel": 1}
    return {
        "audio": {
            "data": data_b64,
            "input": {
                "transcription": {
                    "model": MODEL,
                    "language": language,
                    "enable_itn": enable_itn,
                    "enable_timestamp": enable_timestamp,
                },
                "format": format_block,
            },
        }
    }


def _iter_sse_events(resp):
    """解析 text/event-stream：把连续的 data: 行拼成一个 JSON 事件。"""
    resp.encoding = "utf-8"
    data_buf: list[str] = []
    for raw in resp.iter_lines(decode_unicode=True):
        if raw is None:
            continue
        line = raw.rstrip("\r")
        if line == "":  # 事件分隔
            if data_buf:
                payload = "\n".join(data_buf)
                data_buf = []
                if payload.strip() and payload.strip() != "[DONE]":
                    try:
                        yield json.loads(payload)
                    except json.JSONDecodeError:
                        continue
            continue
        if line.startswith(":"):  # 注释/心跳
            continue
        if line.startswith("data:"):
            data_buf.append(line[len("data:"):].lstrip())
    if data_buf:  # 末尾无空行收尾
        payload = "\n".join(data_buf).strip()
        if payload and payload != "[DONE]":
            try:
                yield json.loads(payload)
            except json.JSONDecodeError:
                pass


def _extract_segment(event: dict) -> Segment | None:
    """从 delta 事件读字级文本+时间戳，字段名按文档但做兜底。"""
    text = event.get("delta") or event.get("text") or ""
    if not text:
        return None
    start = event.get("start_time", event.get("start"))
    end = event.get("end_time", event.get("end"))
    return Segment(text=text, start_ms=start, end_ms=end)


def _parse_retry_after(value: str | None) -> float | None:
    """解析 Retry-After 头：仅支持「秒数」形式（HTTP 日期形式接口不用，忽略）。"""
    if not value:
        return None
    try:
        secs = float(value.strip())
        return secs if secs >= 0 else None
    except ValueError:
        return None


def _post_sse(
    url: str, payload: dict, api_key: str, *, max_retries: int, timeout: int,
) -> ASRResult:
    """向单个 SSE 端点发一个预建 payload，做 429/5xx 重试。时间戳相对本段起点。

    长流（整条音频）的 transcript.text.done **不回聚合文本**——靠下面把 delta 拼回 full_text 兜底。
    """
    requests = _requests()
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }

    last_err: Exception | None = None
    rate_limit_hits = 0  # 429 单独计数：用更大的预算（_RATE_LIMIT_RETRIES）而非 max_retries
    attempt = 0
    while True:
        try:
            with requests.post(url, headers=headers, json=payload,
                               stream=True, timeout=timeout) as resp:
                if resp.status_code != 200:
                    body = resp.text[:500]
                    if resp.status_code == 429:
                        retry_after = _parse_retry_after(resp.headers.get("Retry-After"))
                        rate_limit_hits += 1
                        if rate_limit_hits <= _RATE_LIMIT_RETRIES:
                            sleep_s = retry_after if retry_after is not None \
                                else min(2.0 * (2 ** (rate_limit_hits - 1)), 30.0)
                            print(f"[warn] ASR 限频 429（第 {rate_limit_hits} 次），"
                                  f"{sleep_s:.1f}s 后重试：{body[:120]}")
                            time.sleep(sleep_s)
                            continue
                        raise RuntimeError(
                            f"StepAudio ASR 持续限频 429（重试 {_RATE_LIMIT_RETRIES} 次后仍超限）：{body}")
                    if resp.status_code in (500, 502, 503, 504):
                        raise requests.HTTPError(f"{resp.status_code}: {body}")
                    resp.raise_for_status()  # 4xx 等不重试，直接抛
                result = ASRResult(full_text="")
                for event in _iter_sse_events(resp):
                    result.raw_events.append(event)
                    etype = event.get("type")
                    if etype == "transcript.text.delta":
                        seg = _extract_segment(event)
                        if seg:
                            result.segments.append(seg)
                    elif etype == "transcript.text.done":
                        result.full_text = event.get("text", "")
                if not result.full_text and result.segments:
                    result.full_text = "".join(s.text for s in result.segments)
                return result
        except (requests.Timeout, requests.ConnectionError, requests.HTTPError) as e:
            last_err = e
            if attempt < max_retries:
                attempt += 1
                time.sleep(1.5 * attempt)
                continue
            raise RuntimeError(f"StepAudio ASR 调用失败（重试 {max_retries} 次后）：{e}") from e
    raise RuntimeError(f"StepAudio ASR 调用失败：{last_err}")


def _transcribe_payload(payload: dict, api_key: str, *, max_retries: int, timeout: int) -> ASRResult:
    """按 ASR_URLS 顺序发：优先 step_plan，端点报错或返回空转写就 fallback 到下一个。

    「空也 fallback」是因为旧 /v1 对超长输入是**静默返回空**而非报错——只看 HTTP 200 会漏。
    两个端点都拿不到非空文本才抛（不静默吞）。
    """
    errors: list[str] = []
    for url in ASR_URLS:
        tag = "step_plan" if "step_plan" in url else "std"
        try:
            res = _post_sse(url, payload, api_key, max_retries=max_retries, timeout=timeout)
            if res.full_text.strip():
                return res
            errors.append(f"{tag}: 空转写")
            print(f"[warn] ASR 端点 {tag} 返回空转写，fallback 下一个端点")
        except Exception as e:  # noqa: BLE001 — 收集各端点错误，全失败再抛
            errors.append(f"{tag}: {e}")
            print(f"[warn] ASR 端点 {tag} 失败，fallback：{e}")
    raise RuntimeError("StepAudio ASR 所有端点失败/空：" + " | ".join(errors))


def _transcribe_spans(audio_path, api_key, payload_fn, regions, *, max_retries, timeout) -> ASRResult:
    """逐块转写 VAD 人声块并按块起点偏移时间戳拼接。块长超 _MP3_CHUNK_SECONDS 再对半细分。

    与超长切片同纪律：块间 sleep 压限频；任一块空文本即抛（VAD 判定有人声的块不该转出空，
    不静默拼半截）。full_text 块间以换行相接（块边界=长静音，本就不是同一句话）。"""
    spans: list[tuple[float, float]] = []
    for a, b in regions:
        while b - a > _MP3_CHUNK_SECONDS:
            spans.append((a, a + _MP3_CHUNK_SECONDS))
            a += _MP3_CHUNK_SECONDS
        if b - a > 0:
            spans.append((a, b))
    kw = dict(max_retries=max_retries, timeout=timeout)
    merged = ASRResult(full_text="")
    texts: list[str] = []
    for i, (a, b) in enumerate(spans):
        if i > 0:
            time.sleep(_INTER_CHUNK_SLEEP)
        print(f"[info] 转写人声块 {i + 1}/{len(spans)}（{a / 60:.1f}–{b / 60:.1f} 分钟）...")
        mp3 = audio_to_mp3(audio_path, start_sec=a, dur_sec=b - a)
        part = _transcribe_payload(payload_fn(mp3), api_key, **kw)
        if not part.full_text:
            raise RuntimeError(
                f"人声块 {i + 1}/{len(spans)}（{a:.0f}s–{b:.0f}s）转写为空——"
                f"VAD 判定有人声，不静默拼接，检查接口/音轨。")
        offset_ms = int(a * 1000)
        for s in part.segments:
            merged.segments.append(Segment(
                text=s.text,
                start_ms=(s.start_ms + offset_ms) if s.start_ms is not None else None,
                end_ms=(s.end_ms + offset_ms) if s.end_ms is not None else None,
            ))
        texts.append(part.full_text)
        merged.raw_events.extend(part.raw_events)
    merged.full_text = "\n".join(texts)
    return merged


def transcribe(
    audio_path: str,
    api_key: str,
    *,
    language: str = "zh",
    enable_timestamp: bool = True,
    enable_itn: bool = True,
    max_retries: int = 2,
    timeout: int = 300,
    speech_regions: list | None = None,
) -> ASRResult:
    """转写任意时长音频。**默认整条转 mp3 一把走**（mp3 体积小，长音频也塞得下，
    保证不丢内容）；只有 mp3 体积真超 _MP3_MAX_BYTES 才按时间切片、逐片 mp3 转写并拼接。

    speech_regions：VAD 人声块 [[起,止]秒,…]（vad_gate.check 产出，切点全在长静音处）。
    给了且省下的静音 ≥ _VAD_MIN_SAVE_SEC 才按块送检——逐块转写、时间戳偏移回原始
    时间轴后拼接，下游（分人/声纹/SED 都按原音频对齐）零感知；省不够就照旧整条走。

    为什么不再切裸 PCM 的 12 分钟：见模块顶部常量注释——那是被 PCM 体积逼的伪限制。
    每片时间戳按 片序×片长 偏移回全局；任一片转出空文本即整体抛错，不静默拼半截。
    """
    def _payload(mp3_bytes: bytes) -> dict:
        return _build_payload(base64.b64encode(mp3_bytes).decode(), "mp3",
                              language, enable_timestamp, enable_itn)
    kw = dict(max_retries=max_retries, timeout=timeout)

    def _bill(result, seconds):
        """转写成功后按**实际送检秒数**入账（2026-08-06）。ASR 是成本大头却一直没进
        usage.jsonl（本模块 requests 直调，不经 model_router._log_usage）。计费口径 = 送出去的
        音频秒数：走 VAD 就只算人声块，这样 vad_gate 省下的钱在账本上直接看得见。
        惰性 import + 静默失败：记账绝不拖累转写。"""
        try:
            import sys
            from pathlib import Path as _P
            _srv = str(_P(__file__).resolve().parents[2] / "server")
            if _srv not in sys.path:
                sys.path.insert(0, _srv)
            import model_router
            model_router.log_asr(seconds, path=audio_path)
        except Exception:  # noqa: BLE001
            pass
        return result

    dur = _audio_duration(audio_path)

    if speech_regions:
        covered = sum(b - a for a, b in speech_regions)
        total = dur if dur is not None else (speech_regions[-1][1])
        if total - covered >= _VAD_MIN_SAVE_SEC:
            print(f"[vad] 按人声块送检：{len(speech_regions)} 块共 {covered / 60:.1f} 分钟"
                  f"（全长 {total / 60:.1f} 分钟，省 {(total - covered) / 60:.1f} 分钟静音）")
            return _bill(_transcribe_spans(audio_path, api_key, _payload, speech_regions, **kw),
                         covered)
    if dur is None or dur * _MP3_BYTES_PER_SEC <= _MP3_MAX_BYTES:
        mp3 = audio_to_mp3(audio_path)
        if len(mp3) <= _MP3_MAX_BYTES:
            return _bill(_transcribe_payload(_payload(mp3), api_key, **kw),
                         dur if dur is not None else len(mp3) / _MP3_BYTES_PER_SEC)
        dur = dur or (len(mp3) / _MP3_BYTES_PER_SEC)   # 估偏小、实际超阈值 → 落切片

    n_chunks = int((dur + _MP3_CHUNK_SECONDS - 1) // _MP3_CHUNK_SECONDS)
    print(f"[info] 音频约 {dur / 60:.1f} 分钟，mp3 超单请求上限，"
          f"自动切 {n_chunks} 片（每片 {_MP3_CHUNK_SECONDS // 60} 分钟）")
    merged = ASRResult(full_text="")
    texts: list[str] = []
    for i in range(n_chunks):
        if i > 0:
            time.sleep(_INTER_CHUNK_SLEEP)  # 片间留间隔，从构造上压住限频
        print(f"[info] 转写片 {i + 1}/{n_chunks} ...")
        chunk_mp3 = audio_to_mp3(audio_path, start_sec=i * _MP3_CHUNK_SECONDS,
                                 dur_sec=_MP3_CHUNK_SECONDS)
        part = _transcribe_payload(_payload(chunk_mp3), api_key, **kw)
        if not part.full_text:
            raise RuntimeError(
                f"第 {i + 1}/{n_chunks} 片转写为空——切片更小或检查接口/音轨，"
                f"已转片不静默拼接。")
        offset_ms = i * _MP3_CHUNK_SECONDS * 1000
        for s in part.segments:
            merged.segments.append(Segment(
                text=s.text,
                start_ms=(s.start_ms + offset_ms) if s.start_ms is not None else None,
                end_ms=(s.end_ms + offset_ms) if s.end_ms is not None else None,
            ))
        texts.append(part.full_text)
        merged.raw_events.extend(part.raw_events)
    merged.full_text = "".join(texts)
    return _bill(merged, dur)

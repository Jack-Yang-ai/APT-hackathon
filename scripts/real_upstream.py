#!/usr/bin/env python3
"""真云代理:走本地 `wrangler dev` 起的 Worker,打真 StepFun 与真 DeepSeek(M0-12)。

与 `fake_upstream.py` 是同一组函数签名的两个实现,编排器按 `--real` 二选一 ——
**跑的是同一段编排代码**,否则测的就不是生产那条路(与 `mac/r2_service.py`
的 Storage 接口同一个先例)。

⚠️ **音频必须真裁剪。** 假上游不在乎时间轴,真 ASR 在乎:它返回的时间戳是
**它收到的那段音频**的时间轴。传了保留区间表却送整块音频,`TranscriptFreeze`
会把「裁剪后毫秒」当成真的去还原,整条时间轴系统性错位 —— 而错位之后
每一行仍然有一个看起来合理的时间戳,没有任何东西会报错。
"""
from __future__ import annotations

import json
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

#: 抽取用的模型。**从路由表取,不在这里写死**(CLAUDE.md §五)。
def extract_model() -> str:
    from shared import model_router
    return model_router.PROVIDERS[model_router.SCENE_ROUTES["extract"]["provider"]]["model"]


def trim(src: Path, kept_intervals: list[dict], dst: Path) -> float:
    """按保留区间裁剪音频,返回裁剪后时长(秒)。

    一次 ffmpeg 走 `aselect` 把区间挑出来再重排时间戳 —— 分段导出再 concat
    会在每个接缝上引入编码边界,而接缝正好落在人声起点上。
    """
    if not kept_intervals:
        raise ValueError(f"{src.name} 没有保留区间,不该送检")
    expr = "+".join(f"between(t,{k['startMs']/1000:.3f},{k['endMs']/1000:.3f})"
                    for k in kept_intervals)
    r = subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", str(src),
         "-af", f"aselect='{expr}',asetpts=N/SR/TB",
         "-ar", "16000", "-ac", "1", "-b:a", "64k", str(dst)],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"裁剪失败 {src.name}:{r.stderr[-300:]}")
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "csv=p=0", str(dst)], capture_output=True, text=True)
    return float(out.stdout.strip())


def _post(url: str, payload: dict, timeout: int = 600) -> dict:
    """POST 一个 JSON。

    ⚠️ **4xx/5xx 的正文要读出来。** `urlopen` 遇到非 2xx 直接抛 `HTTPError`,
    而云代理恰恰把「到底哪儿错了」放在正文里 —— 让它抛就只剩一句
    「502 Bad Gateway」,等于把唯一有用的信息扔了。
    """
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode("utf-8"),
        headers={"content-type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"{url} 返回 {e.code}:{body[:600]}") from None


def transcribe(proxy: str, audio_url: str, audio_sec: float) -> dict:
    """真转写。返回 `{text, segments, accounting}`。

    失败**抛**,不返回空转写 —— 空转写会被下游当成「这段没人说话」,
    而那是最贵的一种静默失败(§4.2 把它单列)。
    """
    out = _post(f"{proxy}/transcribe",
                {"audio_url": audio_url, "format": "mp3", "audio_sec": round(audio_sec, 2)})
    if "error" in out:
        raise RuntimeError(f"转写失败:{json.dumps(out, ensure_ascii=False)[:400]}")
    t = out["transcript"]
    if not t.get("segments"):
        raise RuntimeError("转写回来是空的 —— 不当成「这段没人说话」放过去")
    return {"text": t["text"], "segments": t["segments"], "accounting": out.get("accounting")}


def extract(proxy: str, lines: list[dict]) -> tuple[dict, dict]:
    """真抽取。返回 (原始 payload, 记账)。

    ⚠️ `max_tokens` 用 `worker.extract.MAX_TOKENS`(判 4 定的 ≥20000),
    **不用路由表里 extract 场景那个 4000** —— 判 4 的理由正是推理档的 thinking
    会吃光预算导致正文空返,4000 是那条裁决之前的旧值。
    """
    from worker.extract import MAX_TOKENS, parse_model_output, render_prompt

    out = _post(f"{proxy}/llm", {
        "scene": "extract",
        "model": extract_model(),
        "max_tokens": MAX_TOKENS,
        "messages": [{"role": "user", "content": render_prompt(lines)}],
    })
    if "error" in out:
        raise RuntimeError(f"抽取失败:{json.dumps(out, ensure_ascii=False)[:400]}")
    content = out["completion"]["choices"][0]["message"]["content"]
    return parse_model_output(content), out.get("accounting")

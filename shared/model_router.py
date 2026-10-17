#!/usr/bin/env python3
"""场景 → 模型 路由 + 调度（CLAUDE.md「不写死要扩展」：数据驱动注册表，
加场景 / 换模型 / 调参只改 SCENE_ROUTES 或 PROVIDERS 一条，核心逻辑不动）。

为什么有这一层（2026-06-11 选型决议，见 docs/HANDOFF.md「模型分工」）：
  原来所有非聊天场景都 subprocess 起本地 `claude` CLI —— 这是把整套服务焊在这台
  Mac 上、挡着搬服务器的唯一硬依赖。把「哪个场景用哪个 provider」收敛到这里、
  改走 API（DeepSeek / StepFun），后端就退化成纯 Python + secrets.env，可搬任意机器。

  选型经两轮 benchmark + 盲评定（详见 HANDOFF）：
    ~~narrate/reflect/distill/persona/加工/答题/判分（质量敏感）→ deepseek-v4-pro~~
    L1 打标(label) / L2 聚合(merge)（高频蒸馏，降本）        → deepseek-v4-flash

  🔴 **2026-08-18 用户拍板:「后续都用 DS V4 flash 就行,这个拍板定了」。**
  上面那条 2026-06-11 的选型分工**整体作废**（标掉不删——删了下一个人会重新提一遍
  同样的问题）。除 `judge` 外的场景全部改指 deepseek-v4-flash，逐条见下。
  ⚠️ **`judge` 没跟着换**：它是评测的尺子，而 CLAUDE.md 写着
  「判分/出题模型**永不降级**——判官换了历史分数全部不可比」。
  评测不是高频场景，降它省不到什么钱，却会让所有历史分数作废。
  真要一起换，改那一行即可，但**换的当天所有历史分数就不可比了**。
    outreach / ack / evolve                                → step-3.7-flash（便宜够用，非记忆）
    聊天主脑 agent_loop 另走自己的 ChatProvider（deepseek-v4-flash），不经这里。

  2026-08-06 拆账：原 extract 一个场景塞了三样活（加工 / 答题 / 判分），后果是
  ①成本账分不清「生产花的」和「做实验花的」——8/5 花了 $2.35 要翻 Claude Code 会话日志
  才知道 81% 是评测、19% 是 dry-run；②降本时无法只降能降的那部分。现拆三场景，
  路由暂时全指 deepseek-pro（纯分账，零行为变化），降级留给各自 A/B 决定。
  蒸馏三模型横评（2026-07-09，memory/eval/distill_bench.py）：pro→flash 砍 L1/L2 约省 35% LLM 成本、
  延迟减半、完整度不降。step-3.7"记忆管线不可用"结论已于 2026-07-17 推翻：根因是 max_tokens=4000
  饿死 reasoner（thinking 吃光预算→正文空返），8000+ 预算下三轮复测零伪造、L1 抽取最多最准；
  现定位=挂 ≤2 条纪律当免费记录员（批量回灌/obs 传感），编辑品味弱于 ds-flash 故精加工不用它。

provider 类型（kind）：
  anthropic_compat —— anthropic SDK 指 base_url（DeepSeek）。system 挂 cache_control 吃缓存。
  stepfun_plan     —— StepFun step_plan /messages（reasoning，output_config.effort）。
  cli              —— subprocess 起本地 claude（过渡期可回滚；唯一支持 web search 工具）。

env 覆盖（不改码就能 A/B、回滚）：
  GROWTH_AGENT_SCENE_<scene>=<provider_key>     单场景换 provider（如 orchestrate=claude-cli 回滚）
  GROWTH_AGENT_PROVIDER_<key>_MODEL=<model>     换某 provider 的模型名
"""
from __future__ import annotations

import json
import os
import subprocess
import urllib.request
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
USAGE_LOG = ROOT / "data" / "usage.jsonl"
SECRETS_PATHS = (
    Path.home() / ".config" / "growth-agent" / "secrets.env",
    Path.home() / ".config" / "health-agent" / "secrets.env",
)

DS_BASE = os.environ.get("GROWTH_AGENT_DS_BASE_URL", "https://api.deepseek.com/anthropic")
STEP_URL = os.environ.get("STEPFUN_PLAN_URL", "https://api.stepfun.com/step_plan/v1/messages")
STEP_CHAT_URL = os.environ.get("STEPFUN_PLAN_CHAT_URL", "https://api.stepfun.com/step_plan/v1/chat/completions")
STEP_OPENAI_BASE = os.environ.get("STEPFUN_OPENAI_BASE", "https://api.stepfun.com/v1")
AUDIO_PERCEIVE_MODEL = os.environ.get("AUDIO_PERCEIVE_MODEL", "step-audio-r1.1")  # 配置槽可换（§3.6）


def load_secrets(paths=SECRETS_PATHS):
    """把 secrets.env 注入 env（已存在不覆盖；多文件按序前者优先）。仓外 600，缺失静默。"""
    for path in ([paths] if isinstance(paths, (str, Path)) else paths):
        try:
            for line in Path(path).read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())
        except (FileNotFoundError, OSError):
            continue



def _pmodel(key, default):
    return os.environ.get(f"GROWTH_AGENT_PROVIDER_{key.replace('-', '_').upper()}_MODEL", default)


PROVIDERS = {
    "deepseek-pro":   {"kind": "anthropic_compat", "model": _pmodel("deepseek-pro", "deepseek-v4-pro"),
                       "base_url": DS_BASE, "key_env": "DEEPSEEK_API_KEY"},
    "deepseek-flash": {"kind": "anthropic_compat", "model": _pmodel("deepseek-flash", "deepseek-flash"),
                       "base_url": DS_BASE, "key_env": "DEEPSEEK_API_KEY"},
    "stepfun-flash":  {"kind": "stepfun_plan", "model": _pmodel("stepfun-flash", "step-3.7-flash"),
                       "url": STEP_URL, "key_env": "STEPFUN_PLAN_API_KEY", "min_tokens": 20000},
    "stepfun-preview": {"kind": "stepfun_chat", "model": _pmodel("stepfun-preview", "step-5-preview"),
                       "url": STEP_CHAT_URL, "key_env": "STEPFUN_PLAN_API_KEY", "min_tokens": 20000},
    "stepfun-audio":  {"kind": "openai_audio", "model": AUDIO_PERCEIVE_MODEL,
                       "base_url": STEP_OPENAI_BASE, "key_env": "STEPFUN_API_KEY"},
    "claude-cli":     {"kind": "cli", "model": "sonnet"},
}

SCENE_ROUTES = {
    "narrate":         {"provider": "deepseek-flash",   "max_tokens": 6000},   # 自动每日叙事合成（§4，S0 核心）
    "reflect":         {"provider": "deepseek-flash",   "max_tokens": 4000},   # 结构化反思 → personal_model（§4，S2）
    "brief":           {"provider": "deepseek-flash",   "max_tokens": 1500},   # 晨间简报（v2 主动腿）
    "audio_perceive":  {"provider": "stepfun-audio",  "max_tokens": 1200},   # R1.1 原生音频感知（§3）配置槽
    "dialog":          {"provider": "deepseek-flash",   "max_tokens": 1400},   # 聊天主脑（agent_loop 另走 ChatProvider）
    "extract":         {"provider": "stepfun-preview", "max_tokens": 64000},   # 加工：会议抽取/摘要
    "extract_s1":      {"provider": "stepfun-preview", "max_tokens": 30000},   # 阶段一：逐块打标
    "extract_s2":      {"provider": "stepfun-preview", "max_tokens": 30000},   # 阶段二：块内抽取
    "progress":        {"provider": "deepseek-flash", "max_tokens": 4000},   # 进展归属比对
    "ask":             {"provider": "deepseek-flash", "max_tokens": 4000},   # 自由提问：带出处作答，不编造
    "answer":          {"provider": "deepseek-flash", "max_tokens": 4000},   # 答题：recall2 生产问答 + 评测各臂
    "judge":           {"provider": "deepseek-pro",   "max_tokens": 8000},   # 评测尺子：出题(gen_questions) + 判分(run_eval)。
    "label":           {"provider": "deepseek-flash", "max_tokens": 4000},   # L1 打标（会议原子抽取，量最大=降本主战场；flash 比 pro 便宜 4×/快 2×/更全/从不返空）
    "merge":           {"provider": "deepseek-flash", "max_tokens": 3000},   # L2 聚合（场景/线程/topic_merge/reconcile；flash 引用 ID 全真、够细）
    "distill":         {"provider": "deepseek-flash", "max_tokens": 6000},   # 自我模型蒸馏 user.md/memory.md（v2 中枢，整库通读输出长）
    "perceive_select": {"provider": "deepseek-flash", "max_tokens": 4000},   # 精华终判：哪些片段值得上 R1.1（§3.5）
    "bench":           {"provider": "deepseek-flash", "max_tokens": 2000},
}
DEFAULT_PROVIDER = os.environ.get("GROWTH_AGENT_DEFAULT_PROVIDER", "deepseek-pro")


def route(scene):
    """返回 (scene_cfg, provider_cfg)。env GROWTH_AGENT_SCENE_<scene> 可单场景改 provider。"""
    cfg = dict(SCENE_ROUTES.get(scene) or {"provider": DEFAULT_PROVIDER})
    override = os.environ.get(f"GROWTH_AGENT_SCENE_{scene}")
    if override:
        cfg["provider"] = override
    pkey = cfg["provider"]
    if pkey not in PROVIDERS:
        raise RuntimeError(f"未知 provider '{pkey}'（scene={scene}）")
    return cfg, PROVIDERS[pkey]


def extract_backend(scene):
    """给 extract 层用：把场景的 provider 翻成 extract 的 backend 名（stepfun/deepseek/haiku）。
    这样 ack/stimulus 的「用哪个模型」也由这同一张 SCENE_ROUTES governs，单一真相源。"""
    _, prov = route(scene)
    kind = prov["kind"]
    if kind in ("stepfun_plan", "stepfun_chat"):
        return "stepfun"
    if kind == "anthropic_compat":
        return "deepseek"
    return "haiku"  # cli → haiku（数据不出 Anthropic）



_PRICES = {
    "deepseek-flash":    (0.15, 0.003, 0.60),
    "deepseek-v4-flash": (0.22, 0.007, 0.66),
    "deepseek-v4-pro":   (0.66, 0.022, 1.98),
    "step-3.7-flash":    (0.1875, 0.0375, 1.125),
    "step-5-preview":    (1.0, 0.10, 2.70),
    "sonnet":            (3.0, 0.30, 15.0),
    "haiku":             (0.80, 0.08, 4.0),
    "step-asr":          (0.0, 0.0, 0.0),      # 按时长计费，不按 token；单价见 ASR_USD_PER_SEC
}

ASR_CNY_PER_HOUR = float(os.environ.get("GROWTH_ASR_CNY_PER_HOUR", "0.15"))
ASR_USD_PER_SEC = ASR_CNY_PER_HOUR / 7.2 / 3600


def log_asr(seconds: float, *, model: str = "step-asr", scene: str = "asr", path: str = "") -> None:
    """ASR 用量入账（2026-08-06）。为什么要有这个函数：ASR 是成本大头（cost_baseline.md
    估占全项目 90%，¥83.6 vs LLM ¥9.2），却因为 asr_stepfun 是 urllib/requests 直调、
    没走 _log_usage，在 usage.jsonl 里一条记录都没有——于是我们一直在拿放大镜抠占 10%
    的那部分。计量单位是秒不是 token（token 字段留 0，下游 sum 不会串味）。
    记账失败绝不影响转写主流程，与 _log_usage 同纪律。"""
    try:
        if not seconds or seconds <= 0:
            return
        rec = {
            "t": datetime.now().isoformat(timespec="seconds"),
            "scene": scene, "model": model,
            "input": 0, "cache_create": 0, "cache_read": 0, "output": 0,
            "audio_sec": round(float(seconds), 1),
            "cost_usd": round(float(seconds) * ASR_USD_PER_SEC, 6),
        }
        if path:
            rec["src"] = os.path.basename(path)
        USAGE_LOG.parent.mkdir(parents=True, exist_ok=True)
        with USAGE_LOG.open("a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:  # noqa: BLE001
        pass


PEAK_UTC_HOURS = frozenset(range(1, 4)) | frozenset(range(6, 10))
PEAK_MULTIPLIER = 2.0


def is_peak(when=None) -> bool:
    """这一刻是不是高峰。`when` 给 None 就取现在（UTC）。"""
    from datetime import datetime, timezone
    t = when or datetime.now(timezone.utc)
    return t.astimezone(timezone.utc).hour in PEAK_UTC_HOURS


def _price(model: str, usage: dict, when=None) -> float:
    """按 token × 单价折美元。找不到价表返 0（不阻断，但 cost_usd 会露馅提示补价）。"""
    rate = next((v for k, v in _PRICES.items() if model and model.startswith(k)), None)
    if not rate:
        return 0.0
    mult = PEAK_MULTIPLIER if is_peak(when) and not model.startswith("step-5-preview") else 1.0
    pin, pcache, pout = (x * mult for x in rate)
    inp = (usage.get("input_tokens", 0) or 0) + (usage.get("cache_creation_input_tokens", 0) or 0)
    cache = usage.get("cache_read_input_tokens", 0) or 0
    out = usage.get("output_tokens", 0) or 0
    return inp / 1e6 * pin + cache / 1e6 * pcache + out / 1e6 * pout


import threading as _threading

_TLS = _threading.local()  # 线程本地计量：并发评测里"每题一账"（题跑在各自线程，同步调用同线程回账）


def usage_capture_start() -> None:
    _TLS.acc = {"input": 0, "output": 0, "cost_usd": 0.0, "calls": 0}


def usage_capture_read() -> dict:
    return getattr(_TLS, "acc", None) or {}


def _log_usage(scene, model, usage, cost_usd=0.0):
    """统一落 data/usage.jsonl（每次调用一行）。记账失败绝不影响主流程。
    cost_usd 缺省(0)时按定价表自算——adapter 不用各自算钱，一处统一。"""
    acc = getattr(_TLS, "acc", None)
    if acc is not None:
        try:
            acc["input"] += usage.get("input_tokens", 0) or 0
            acc["output"] += usage.get("output_tokens", 0) or 0
            acc["cost_usd"] += cost_usd or _price(model, usage) or 0
            acc["calls"] += 1
        except Exception:  # noqa: BLE001
            pass
    try:
        if not cost_usd:
            cost_usd = _price(model, usage)
        rec = {
            "t": datetime.now().isoformat(timespec="seconds"),
            "scene": scene, "model": model,
            "input": usage.get("input_tokens", 0) or 0,
            "cache_create": usage.get("cache_creation_input_tokens", 0) or 0,
            "cache_read": usage.get("cache_read_input_tokens", 0) or 0,
            "output": usage.get("output_tokens", 0) or 0,
            "cost_usd": round(cost_usd or 0, 6),
        }
        USAGE_LOG.parent.mkdir(parents=True, exist_ok=True)
        with USAGE_LOG.open("a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:  # noqa: BLE001
        pass



def _call_anthropic_compat(prompt, system, *, prov, scene, max_tokens, thinking=None,
                           temperature=None, **_):
    """Generic implementation; local private materials are not distributed."""





    import anthropic
    key = os.environ.get(prov["key_env"])
    if not key:
        raise RuntimeError(f"缺 {prov['key_env']}（{prov['model']} 的 key）")
    tmo = float(os.environ.get("GROWTH_AGENT_API_TIMEOUT", "120"))
    http_client = None
    if os.environ.get("GROWTH_AGENT_KEEPALIVE") != "1":
        try:
            import httpx
            http_client = httpx.Client(
                limits=httpx.Limits(max_keepalive_connections=0), timeout=tmo)
        except Exception:  # noqa: BLE001 — httpx 异常时退回 SDK 默认
            http_client = None
    client = anthropic.Anthropic(api_key=key, base_url=prov["base_url"],
                                 timeout=tmo, max_retries=3,
                                 **({"http_client": http_client} if http_client else {}))
    r = client.messages.create(
        model=prov["model"], max_tokens=max_tokens,
        system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        messages=[{"role": "user", "content": prompt}],
        **({"thinking": thinking} if thinking is not None else {}),
        **({"temperature": temperature} if temperature is not None else {}))
    text = "".join(b.text for b in r.content if getattr(b, "type", "") == "text")
    u = r.usage
    usage = {k: getattr(u, k, 0) for k in
             ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")}
    if not text.strip():
        raise RuntimeError(
            f"{prov['model']} 返回空正文（stop_reason={getattr(r, 'stop_reason', '?')}, "
            f"max_tokens={max_tokens}, output_tokens={usage.get('output_tokens', 0)}）"
            f"——若 output_tokens 接近 max_tokens，多半是 thinking 吃光预算，调大 max_tokens")
    return text, usage, 0.0


def _call_stepfun_chat(prompt, system, *, prov, scene, max_tokens, effort=None,
                       temperature=None, **_):
    """与 Worker 相同的 Step Plan Chat 协议；未指定 effort 时保持默认推理。"""
    key = os.environ.get(prov["key_env"])
    if not key:
        raise RuntimeError(f"缺 {prov['key_env']}（StepFun key）")
    messages = ([{"role": "system", "content": system}] if system else [])
    messages.append({"role": "user", "content": prompt})
    body = {"model": prov["model"], "messages": messages,
            "max_tokens": max_tokens, "stream": False}
    if effort is not None:
        body["reasoning_effort"] = effort
    if temperature is not None:
        body["temperature"] = temperature
    req = urllib.request.Request(prov["url"], data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=int(os.environ.get("GROWTH_AGENT_STEP_TIMEOUT", "900"))) as response:
        result = json.loads(response.read())
    usage = result.get("usage") or {}
    hit = usage.get("prompt_cache_hit_tokens", (usage.get("prompt_tokens_details") or {}).get("cached_tokens", 0)) or 0
    metering = {"input_tokens": max(0, (usage.get("prompt_tokens") or 0) - hit),
                "cache_read_input_tokens": hit, "output_tokens": usage.get("completion_tokens") or 0}
    if result.get("model") != prov["model"]:
        _log_usage(scene, result.get("model") or prov["model"], metering)
        raise RuntimeError(f"StepFun 返回模型 {result.get('model')!r} ≠ {prov['model']}")
    choice = (result.get("choices") or [{}])[0]
    text = choice.get("message", {}).get("content")
    if not isinstance(text, str) or not text.strip():
        _log_usage(scene, prov["model"], metering)
        raise RuntimeError(f"{prov['model']} 返回空正文（finish_reason={choice.get('finish_reason')}）")
    return text, metering, 0.0


def _call_stepfun_plan(prompt, system, *, prov, scene, max_tokens, effort=None,
                       temperature=None, **_):
    """Generic implementation; local private materials are not distributed."""






    key = os.environ.get(prov["key_env"])
    if not key:
        raise RuntimeError(f"缺 {prov['key_env']}（StepFun key）")
    body = {"model": prov["model"], "max_tokens": max_tokens, "system": system,
            "messages": [{"role": "user", "content": prompt}],
            "output_config": {"effort": effort or "low"}}
    if temperature is not None:
        body["temperature"] = temperature
    req = urllib.request.Request(
        prov["url"], data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    resp = json.loads(urllib.request.urlopen(req, timeout=int(os.environ.get("GROWTH_AGENT_STEP_TIMEOUT", "180"))).read())
    text = "".join(b.get("text", "") for b in (resp.get("content") or []) if b.get("type") == "text")
    return text, (resp.get("usage") or {}), 0.0


_CLI = os.path.expanduser(os.environ.get("GROWTH_AGENT_CLAUDE_BIN", "~/.local/bin/claude"))
_CLI_TOOLS = os.environ.get(
    "GROWTH_AGENT_ALLOWED_TOOLS",
    "mcp__web-search__web_search mcp__web-search__web_fetch WebSearch WebFetch")
_CLI_TIMEOUT = int(os.environ.get("GROWTH_AGENT_CLAUDE_TIMEOUT", "150"))


def _call_cli(prompt, system, *, prov, scene, max_tokens, tools=False, model=None, **_):
    """过渡期 / 回滚：subprocess 起本地 claude。唯一支持 web search 工具的 provider。"""
    cmd = [_CLI, "-p", "--append-system-prompt", system, "--output-format", "json",
           "--model", model or prov["model"]]
    if tools and _CLI_TOOLS.strip():
        cmd += ["--allowedTools", *_CLI_TOOLS.split()]
    r = subprocess.run(cmd, input=prompt, capture_output=True, text=True,
                       timeout=_CLI_TIMEOUT, cwd=str(ROOT))
    if r.returncode != 0:
        raise RuntimeError(f"claude exit {r.returncode}: {(r.stderr or '')[:400]}")
    try:
        d = json.loads(r.stdout or "{}")
    except json.JSONDecodeError:
        raise RuntimeError(f"claude 输出非 JSON: {(r.stdout or '')[:200]}")
    if d.get("is_error"):
        raise RuntimeError(f"claude error: {(d.get('result') or '')[:200]}")
    text = (d.get("result") or "").strip()
    if not text:
        raise RuntimeError("claude 返回空")
    return text, (d.get("usage") or {}), (d.get("total_cost_usd") or 0.0)


def _call_openai_audio(prompt, system, *, prov, scene, **_):
    """R1.1 原生音频感知不走纯文本 call()——它要 input_audio base64（§3.4）。
    这里只占位：实际调用在 perceive/r1_client.py（用 route('audio_perceive') 取本 provider 配置）。"""
    raise NotImplementedError(
        "audio_perceive 是配置槽，不经 model_router.call() —— 用 perceive.r1_client.perceive(audio, ...)")


_ADAPTERS = {
    "anthropic_compat": _call_anthropic_compat,
    "stepfun_chat": _call_stepfun_chat,
    "stepfun_plan": _call_stepfun_plan,
    "openai_audio": _call_openai_audio,
    "cli": _call_cli,
}



def call(prompt, system, *, scene="dialog", tools=False, effort=None,
         max_tokens=None, model=None, usage_sink=None, provider=None, thinking=None,
         temperature=None):
    """Generic implementation; local private materials are not distributed."""









    cfg, prov = route(scene)
    if provider is not None:
        if provider not in PROVIDERS:
            raise KeyError(f"未知 provider：{provider}（可用：{sorted(PROVIDERS)}）")
        prov = PROVIDERS[provider]
    mt = max_tokens or cfg.get("max_tokens") or 2000
    mt = max(mt, prov.get("min_tokens", 0))  # provider 预算下限：reasoner 防饿死（见 PROVIDERS 注释）
    eff = effort or cfg.get("effort")
    if temperature is None and os.environ.get("GROWTH_TEMPERATURE"):
        temperature = float(os.environ["GROWTH_TEMPERATURE"])
    adapter = _ADAPTERS[prov["kind"]]
    text, usage, cost = adapter(prompt, system, prov=prov, scene=scene,
                                max_tokens=mt, effort=eff, tools=tools, model=model,
                                thinking=thinking, temperature=temperature)
    if usage_sink:
        usage_sink(scene, prov["model"], {"usage": usage})
    else:
        _log_usage(scene, prov["model"], usage, cost)
    return text

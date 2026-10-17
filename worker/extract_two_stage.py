"""Generic implementation; local private materials are not distributed."""














from __future__ import annotations

import json
import os
import re

from . import extract as v1
from . import personal_actions as actions

PROMPT_VERSION = "v3-semantic-continuity"

# ── 参数（都有实测出处，改前先看 docs/evidence/extraction/）──
TARGET_CHARS = 2000     # 候选块目标粒度 = 案卷 6000 ÷ 3（话段同款算法）
MIN_CHARS = 80          # 短于此并入前块，防碎片
# 静音时长只作语义证据，不以固定时长强制断一件事（M5-2 用户明确）。
S1_MAX_TOKENS = 30000   # step-3.7 thinking 占输出 ~76%，给足
S2_MAX_TOKENS = 30000
SCENE_S1 = "extract_s1"
SCENE_S2 = "extract_s2"
FALLBACK_PROVIDER = "deepseek-flash"   # 双败兜底（DS 偶发空正文但可重试，实测 3 场 2 次一重即过）


# ─────────────────────────── 候选预切（纯代码，＝话段切分算法） ───────────────────────────

def candidates(lines: list[dict]) -> list[dict]:
    """递归切最长静音直到每块 ≤TARGET_CHARS。lines 需含 line_id/text，可选 t_sec/cluster_tag。
    返回 [{no, line_from, line_to, chars, t_from, t_to, speakers, gap_prev}]。"""
    n = len(lines)
    if n == 0:
        return []

    def chars(a: int, b: int) -> int:
        return sum(len(lines[i]["text"]) for i in range(a, b))

    def split(a: int, b: int) -> list[tuple[int, int]]:
        if chars(a, b) <= TARGET_CHARS or b - a < 2:
            return [(a, b)]
        half = chars(a, b) / 2
        best = None   # (gap, 平衡度) 双键：先最长静音；同分取离字数中点最近的，防
        for i in range(a + 1, b):   # 均匀间隔/无时间戳时退化成一行一块（test_candidates 抓过）
            if chars(a, i) < MIN_CHARS or chars(i, b) < MIN_CHARS:
                continue
            gap = (lines[i].get("t_sec") or 0) - (lines[i - 1].get("t_sec") or 0)
            key = (gap, -abs(chars(a, i) - half))
            if best is None or key > best[0]:
                best = (key, i)
        if best is None:
            return [(a, b)]
        return split(a, best[1]) + split(best[1], b)

    out = []
    prev_end = None
    for k, (a, b) in enumerate(split(0, n), 1):
        t0 = lines[a].get("t_sec") or 0
        t1 = lines[b - 1].get("t_end_sec", lines[b - 1].get("t_sec")) or 0
        spk = sorted({(lines[i].get("cluster_tag") or "未分人") for i in range(a, b)})
        out.append({"no": k, "line_from": lines[a]["line_id"], "line_to": lines[b - 1]["line_id"],
                    "chars": chars(a, b), "t_from": t0, "t_to": t1,
                    "speakers": spk, "gap_prev": (t0 - prev_end) if prev_end is not None else 0})
        prev_end = t1
    return out


# ─────────────────────────────── Stage 1：逐块打标 ───────────────────────────────

STAGE1_PROMPT = """你是 ASR 结构分析器。输入给了 N 个候选块 C1…CN（边界已由规则切好）。
**你必须为每一个候选块输出恰好一行，一个不落，按编号顺序。**不做分组、不定边界——那些由代码完成。

每行格式（严格，行首必须是 #C）：
#C <编号> <tier_event> <tier_detail> <user_relevance> <一句话主题>

tier_event ∈ high | medium | low：
- high   = 这一块相对上一块开始了**另一件事**。核心是正在处理的目标/事件是否变了。
- medium = 承接上一块的同一件事。围绕同一事情的进度、成本、分工、风险等自然漂移仍算延续。
- low    = 无信息量：纯播报、纯寒暄、纯环境音
tier_detail ∈ full | compressed：含决策/成本数字/排期/分工/风险/技术方案 → full，否则 compressed
user_relevance ∈ 相关 | 无关：这一块的内容跟用户的工作、项目、个人事务有没有关系

执行纪律：
- 逐块打标，写完一块就收，不要回头改，不要在推理里穷举组合
- 拿不准取保守档（medium / compressed / 相关）
- 时间间隔、地点、说话人变化只作证据，不能单独强制另起。ASR 簇标签只在本分片内有效，不证明跨片身份。
- 若提供了【前一件事】，C1 要与此前文比较；此前文不是本批的新材料，不从中重复抽取原话或条目。
- 以持续进行的活动/事项为单位，不以聊天微话题为单位。同一次训练里的动作、恢复、会籍和间歇闲聊仍可承接；明确结束训练、开始另一场独立活动才另起，不能因同属健身而强行合并两场。
- 前文 title 是既有活动的稳定锚；latest_title 和 summary 可能只描述最近一片的闲聊，不据此把回到原活动误判为新事。仍须核当前原话是否确实延续，不按标题或词语相同强制合并。
- 只有“然后”“他在那个地方”等指代不明残句、零星语气词、场馆播报，没有可辨识事项或进展时取 low；不能为了写摘要补成一件事。信息不足的随口问句也不等于有待办或悬点。
- 最后一行输出：#META {"recommended_event_count":<整数>}
- 不要 markdown 围栏，不要解释文字，不要把输出包进 JSON 信封

候选块（编号 | 行号区间 | 起止时间 | 与上块间隔 | 字数 | 说话人 | 开头）：
{candidates}

转写全文（行号 | 簇标签 | 原话）：
{transcript}
"""

# Step 5 实测常省略 C 与编号间的空格；只兼容词法，不补块或猜枚举。
_C_LINE = re.compile(r"#C\s*(\d+)\s+(high|medium|low)\s+(full|compressed)\s+(\S+)\s*(.*)")


def unwrap(raw: str) -> str:
    """Generic implementation; local private materials are not distributed."""
    t = raw.strip()
    if t.startswith("```"):
        t = re.sub(r"^```\w*\s*|\s*```$", "", t, flags=re.S).strip()
    if t.startswith("{") and '"output"' in t[:20]:
        try:
            return json.loads(t).get("output") or t
        except Exception:  # noqa: BLE001 — 信封解不开就按原文走，parse 覆盖率会暴露问题
            pass
    if t.startswith("["):
        try:
            arr = json.loads(t)
            if isinstance(arr, list):
                return "\n".join(str(x) for x in arr)
        except Exception:  # noqa: BLE001
            pass
    return t


def parse_stage1(raw: str, ncand: int) -> tuple[dict[int, dict], int]:
    """返回 (labels{块号: {...}}, 坏行数)。覆盖率由调用方检查——缺块必须可见。"""
    labels: dict[int, dict] = {}
    bad = 0
    for ln in unwrap(raw).splitlines():
        ln = ln.strip()
        if not ln.startswith("#C"):
            continue
        m = _C_LINE.match(ln)
        if not m:
            bad += 1
            continue
        no = int(m.group(1))
        if m.group(4) not in ("相关", "无关"):
            bad += 1
            continue
        if 1 <= no <= ncand:
            if no in labels:
                bad += 1
            labels[no] = {"tier_event": m.group(2), "tier_detail": m.group(3),
                          "user_relevance": m.group(4), "topic": m.group(5)}
        else:
            bad += 1
    return labels, bad


class Stage1CoverageError(v1.SchemaError):
    """打标覆盖率不足——缺的块宁可报错也不默认填档（默认填档＝静默降质）。"""


def check_coverage(labels: dict[int, dict], ncand: int, *, min_ratio: float = 0.9) -> None:
    if ncand and len(labels) / ncand < min_ratio:
        missing = [i for i in range(1, ncand + 1) if i not in labels][:10]
        raise Stage1CoverageError(f"打标覆盖 {len(labels)}/{ncand}，缺块示例 {missing}")


# ────────────────────────────── 分组与剔噪（纯代码） ──────────────────────────────

def group_blocks(cands: list[dict], labels: dict[int, dict], previous: dict | None = None) -> tuple[list[dict], list[int]]:
    """high 断组，时间只作模型证据；low/无关 剔除，原文仍可搜。
    返回 (groups[{event_id, blocks}], dropped_block_nos)。"""
    groups: list[dict] = []
    dropped: list[int] = []
    cur = None
    can_continue = bool(previous)
    for c in cands:
        lab = labels.get(c["no"]) or {}
        te = lab.get("tier_event", "medium")
        if te == "low" or lab.get("user_relevance") == "无关":
            if te == "high":
                can_continue = False  # 被剔除的新事也意味着前一件事已经换了
                cur = None
            dropped.append(c["no"])
            continue
        if cur is None or te == "high":
            cur = {"event_id": f"E{len(groups) + 1}", "blocks": []}
            if not groups and te == "medium" and can_continue:
                cur["continuation_id"] = previous["event_id"]
            groups.append(cur)
        cur["blocks"].append(c["no"])
    return groups, dropped


def assign_event_ids(payload: dict, groups: list[dict], cands: list[dict]) -> None:
    """条目的 event_id 由 line_id 落在哪个组**机械回填**，不采信模型输出的任何归属。"""
    span = {}
    by_no = {c["no"]: c for c in cands}
    for g in groups:
        for no in g["blocks"]:
            c = by_no[no]
            span[(c["line_from"], c["line_to"])] = g["event_id"]

    def eid(line_id: int) -> str | None:
        for (a, b), e in span.items():
            if a <= line_id <= b:
                return e
        return None

    for kind in v1.ITEM_KINDS:
        for item in payload.get(kind) or []:
            item["event_id"] = eid(item.get("line_id") or -1)

    # 事件自己的行范围(`M5-1`:手机详情页按它算起止钟点与在场的人)。
    # 同样**机械地**从分组来,不问模型 —— 模型给的 time_range 是自由文本,不能当数用。
    # ⚠️ 键名 line_from / line_to 与 ios ExtractionStore 读的是同一对,
    # 由 shared/test_cross_language_contracts.py 钉着。
    bounds = {}
    for g in groups:
        rngs = [(by_no[no]["line_from"], by_no[no]["line_to"]) for no in g["blocks"]]
        if rngs:
            bounds[g["event_id"]] = (min(a for a, _ in rngs), max(b for _, b in rngs))
    for ev in payload.get("events") or []:
        b = bounds.get(ev.get("event_id"))
        if b:
            ev["line_from"], ev["line_to"] = b
            # 不采信 S2 模型提供的跨片身份。它由 S1 标签 + 已校验的前文机械派生。
            group = next(g for g in groups if g["event_id"] == ev["event_id"])
            ev.pop("continuation_id", None)
            if group.get("continuation_id"):
                ev["continuation_id"] = group["continuation_id"]
        else:   # 对不上分组的:模型自己写的范围一律不采信
            ev.pop("line_from", None)
            ev.pop("line_to", None)


def retain_supported_events(payload: dict, raw: dict, groups: list[dict], cands: list[dict]) -> list[str]:
    """事件须有已校验的本组重点；原话仍在来源层，不因不展示而删除。

    归属用实际候选块，不能用跨过low块的事件首尾范围，也不采信模型event_id。
    候选重点全部证据失败与本来无重点是两回事，前者交回有界重试。
    """
    by_no = {c["no"]: c for c in cands}
    spans = [(by_no[no]["line_from"], by_no[no]["line_to"], g["event_id"])
             for g in groups for no in g["blocks"]]

    def owner(line_id):
        return next((event_id for start, end, event_id in spans
                     if type(line_id) is int and start <= line_id <= end), None)

    def focus_rows(value):
        return [item for kind in v1.ITEM_KINDS for item in value.get(kind, [])] + value.get("personal_actions", [])

    supported = {owner(item.get("line_id")) for item in focus_rows(payload)} - {None}
    suppressed = [event["event_id"] for event in payload["events"] if event["event_id"] not in supported]
    unresolved = {None, *suppressed}
    if suppressed and any(owner(item.get("line_id")) in unresolved for item in focus_rows(raw)):
        raise v1.SchemaError("事件候选重点未通过原话校验，不能当作无重点")
    payload["events"] = [event for event in payload["events"] if event["event_id"] in supported]
    return suppressed


# ─────────────────────────────── Stage 2：契约抽取 ───────────────────────────────

# v1 EXTRACT_PROMPT 的超集：结构、六类产出、硬要求全部原样，只加 events 数组与三条纪律。
STAGE2_EXTRA = """
另外输出一个 "events" 数组：输入按【EVENT k】分好了组，每组恰好输出一个对象
  {"event_id": "Ek", "title": "...", "summary": "...", "time_range": "..."}。
- 严格按给定分组，一组一个，不合并不再切。
- summary 写成连贯的一到几段，不罗列微话题；同一话题的反复讨论合成一次表述。
- 一条内容都值不上写的组，summary 如实写短，不要硬凑。
key_points 收有原话依据的实质重点：决定、进展、结果、后续安排、风险、方案与重要数字。
个人训练、就医、出行等活动中可辨识的事实、进展、结果同样可以是重点，不因不是工作项目而漏掉；当场训练或服务不能硬包装成后续个人行动。
纯播报、寒暄、语气词、指代不明残句和没有可辨识事项的随口问句不收，不为了保留事件凑重点；“未形成议题/没有结论/零碎发言”不是重点。
提交前逐条核对引文：每个 quote 只能逐字引用一行真实原话，不拼接多行、不润色、不引用缺口占位。
若有 personal_actions，每条 evidence 必须显式包含本条 line_id 的原话及 quote，另列所需前后文。
这只是输出前自查；不满足责任和最终状态依据的行动不要输出，不补造证据。
"""


def render_stage2_prompt(lines: list[dict], groups: list[dict], cands: list[dict], *, include_actions: bool = False) -> str:
    by_no = {c["no"]: c for c in cands}
    by_id = {l["line_id"]: l for l in lines}
    parts = []
    for g in groups:
        sel = []
        for no in g["blocks"]:
            c = by_no[no]
            sel += [by_id[i] for i in range(c["line_from"], c["line_to"] + 1) if i in by_id]
        body = "\n".join(f'{l["line_id"]} | {l.get("cluster_tag") or "未分人"} | {l["text"]}' for l in sel)
        parts.append(f"【EVENT {g['event_id'][1:]}】\n{body}")
    base = v1.EXTRACT_PROMPT.replace("{transcript}", "\n\n".join(parts))
    return base + STAGE2_EXTRA + (actions.PROMPT if include_actions else "")


def render_stage1_prompt(lines: list[dict], cands: list[dict], previous: dict | None = None) -> str:
    by_id = {l["line_id"]: l for l in lines}
    rows = []
    for c in cands:
        head = "".join(by_id[i]["text"] for i in range(c["line_from"], c["line_to"] + 1)
                       if i in by_id)[:36]
        rows.append(f'C{c["no"]} | 行{c["line_from"]}-{c["line_to"]} | {c["t_from"]}s~{c["t_to"]}s'
                    f' | 间隔{c["gap_prev"]}s | {c["chars"]}字 | 说话人{",".join(c["speakers"])} | {head}…')
    body = "\n".join(f'{l["line_id"]} | {l.get("cluster_tag") or "未分人"} | {l["text"]}' for l in lines)
    prompt = (STAGE1_PROMPT.replace("{candidates}", "\n".join(rows)).replace("{transcript}", body))
    if previous:
        prompt = "【前一件事，仅用于判断延续】\n" + json.dumps(previous, ensure_ascii=False) + "\n\n" + prompt
    return prompt


# ─────────────────────────────────── 编排 ───────────────────────────────────

def _default_call(prompt: str, *, scene: str, max_tokens: int, provider: str | None):
    from shared import model_router
    model_router.load_secrets()
    return model_router.call(prompt, "只按指令输出，不要解释。", scene=scene,
                             max_tokens=max_tokens, provider=provider)


def run(lines: list[dict], model_call=None) -> tuple[dict, v1.ExtractionStats, dict]:
    """全流程。lines: [{line_id, text, cluster_tag?, t_sec?, is_gap?, person_id?}]。
    返回 (payload 含 events 与 event_id, 三项校验 stats, meta 运行元数据)。"""
    call = model_call or _default_call
    header = lines[0] if lines else {}
    action_protocol = header.get("action_protocol")
    if action_protocol is not None and action_protocol != actions.PROTOCOL:
        raise v1.SchemaError("未知个人行动识别协议")
    if header.get("action_only") is True:
        if action_protocol != actions.PROTOCOL:
            raise v1.SchemaError("整场行动识别缺协议")
        clean, meta = actions.run(lines, call)
        clean["pipeline_version"] = PROMPT_VERSION
        return clean, v1.ExtractionStats(), meta
    streaming = header.get("streaming") is True
    if header.get("recipe") and header["recipe"] != PROMPT_VERSION:
        raise v1.SchemaError("未知语义管线配方，不能复用旧判据")
    previous = header.get("stream_context") or None
    if previous and (not isinstance(previous, dict) or type(previous.get("event_id")) is not int
                     or previous["event_id"] <= 0 or not isinstance(previous.get("t_end_sec"), (int, float))):
        raise v1.SchemaError("前一件事缺稳定身份或时间")
    lines = [{k: v for k, v in line.items() if k not in ("recipe", "streaming", "stream_context", "action_protocol", "action_request", "source_revision")} for line in lines]
    cands = candidates(lines)
    if cands and previous:
        cands[0]["gap_prev"] = cands[0]["t_from"] - previous["t_end_sec"]
    meta: dict = {"prompt_version": PROMPT_VERSION, "candidates": len(cands), "attempts": []}

    def attempt(stage: str, prompt: str, scene: str, max_tokens: int, parse):
        """重试一次 → 换兜底模型再重试一次 → 抛。每次尝试都进 meta，失败必须可见。"""
        last = None
        for provider in (None, None, FALLBACK_PROVIDER, FALLBACK_PROVIDER):
            try:
                raw = call(prompt, scene=scene, max_tokens=max_tokens, provider=provider)
                out = parse(raw)
                meta["attempts"].append({"stage": stage, "provider": provider or "primary", "ok": True})
                return out
            except Exception as e:  # noqa: BLE001 — 记录后继续降级，最终仍抛
                last = e
                meta["attempts"].append({"stage": stage, "provider": provider or "primary",
                                         "ok": False, "err": str(e)[:120]})
        raise last

    def parse_s1(raw):
        labels, bad = parse_stage1(raw, len(cands))
        if streaming and bad:
            raise Stage1CoverageError(f"打标有 {bad} 行重复、越界或无效，不能猜延续")
        check_coverage(labels, len(cands), min_ratio=1.0 if streaming else 0.9)
        meta["stage1_bad_lines"] = bad
        return labels

    labels = attempt("stage1", render_stage1_prompt(lines, cands, previous), SCENE_S1, S1_MAX_TOKENS, parse_s1)
    groups, dropped = group_blocks(cands, labels, previous)
    meta.update(labels_high=sum(1 for v in labels.values() if v["tier_event"] == "high"),
                groups=len(groups), dropped_blocks=dropped)
    if not groups:
        # 全场被剔（全 low/无关）：合法终态，与失败不同——payload 空数组 + events 空。
        empty = {k: [] for k in v1.ALL_KINDS}
        empty.update(one_liner="（本场全部为无信息量或与用户无关内容，未抽取）", events=[], pipeline_version=PROMPT_VERSION)
        if action_protocol:
            empty.update(action_protocol=actions.PROTOCOL, personal_actions=[])
        return empty, v1.ExtractionStats(), meta

    def parse_s2(raw):
        payload = v1.parse_model_output(raw)
        v1.validate_schema(payload)
        if action_protocol:
            payload.update(actions.from_model(payload, lines))
        actions.validate(payload, lines)
        evs = payload.get("events")
        if not isinstance(evs, list) or len(evs) != len(groups):
            raise v1.SchemaError(f"events 数量 {len(evs) if isinstance(evs, list) else '非数组'} ≠ 分组数 {len(groups)}")
        # 🔴 编号也要一一对上(`M5-1`,2026-10-12 对抗审查):只比条数的话,模型写两个 E1 漏掉 E2,
        # 两段会领到同一个行范围(第二段显示第一段的钟点与在场的人);编号写成 "1" 则全部范围被丢,
        # 看起来跟老产物一样。**在这里抛** —— 走重试 / 换兜底模型,钱还没白花;
        # 到了手机再拒收,同一份产物会被永久挡住。
        got = sorted(str(e.get("event_id")) for e in evs if isinstance(e, dict))
        want = sorted(g["event_id"] for g in groups)
        if got != want:
            raise v1.SchemaError(f"events 编号 {got} 与分组 {want} 对不上")
        for event in evs:
            for field in ("title", "summary"):
                if not isinstance(event.get(field), str) or not event[field].strip():
                    raise v1.SchemaError(f"event {event.get('event_id')} 缺非空 {field}")
        by_event = {event["event_id"]: event for event in evs}
        payload["events"] = [by_event[g["event_id"]] for g in groups]
        clean, stats = v1.validate(payload, lines)
        clean["events"] = payload["events"]
        assign_event_ids(clean, groups, cands)
        suppressed = retain_supported_events(clean, payload, groups, cands)
        meta["suppressed_event_ids"] = suppressed
        if suppressed and not clean["events"]:
            clean["one_liner"] = "（本片没有可展示的有效重点，原话已保留）"
        return clean, stats

    payload, stats = attempt("stage2", render_stage2_prompt(lines, groups, cands, include_actions=bool(action_protocol)), SCENE_S2, S2_MAX_TOKENS, parse_s2)
    payload["pipeline_version"] = PROMPT_VERSION
    return payload, stats, meta

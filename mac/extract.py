"""Generic implementation; local private materials are not distributed."""



















from __future__ import annotations

import datetime as _dt
import json
import re
from pathlib import Path

from shared import paths as config, errlog

_TEMPLATE_DIR = Path(__file__).resolve().parent
_EXTRACT_SPEC = _TEMPLATE_DIR / "EXTRACT.md"

# extract 抽取的 system（把 EXTRACT.md 的「步骤3 抽取 + 胡编防护」规范固化成指令）。
_SYSTEM = """你是会议纪要抽取助手。读用户给的会议转写（含逐句 + 全文核对底本），产出结构化抽取。
铁律（来自抽取工作流规范）：
- 忠于原文，不脑补；每条观点/todo 必须能在「全文核对底本」里找到出处，拿不准的不要编。
- 各人观点：按说话人/真名分组，每人 2-5 条核心主张。
- 分歧点：谁在什么问题上没达成一致；没有就写「无明显分歧」。
- 待办 to-do：负责人 + 事项 +（若提到）截止日。
- 判断哪些 todo 的负责人是「我/用户本人」（按转写里的第一人称/用户姓名别名），标 is_mine=true。
只输出一个 JSON 对象，不要任何额外文字、不要 markdown 代码围栏。schema：
{"topic": "会议主题", "participants": ["说话人或真名", ...],
 "disagreements": ["...", ...],
 "viewpoints": {"说话人或真名": ["观点1", "观点2", ...]},
 "todos": [{"assignee": "负责人", "task": "事项", "due": "YYYY-MM-DD 或 null", "is_mine": true/false}]}"""


def _slug(topic: str) -> str:
    topic = (topic or "会议").strip()
    return re.sub(r"[/\\:*?\"<>|]+", "_", topic)[:40] or "会议"


def _vault() -> Path | None:
    root = config.OBSIDIAN_VAULT or __import__("os").environ.get("GROWTH_OBSIDIAN_VAULT")
    return Path(root) if root else None


def _within_vault(path: Path, vroot: Path) -> bool:
    try:
        path.resolve().relative_to(vroot)
        return True
    except (ValueError, OSError):
        return False


def _read_transcript(transcript_md_path: str) -> tuple[str, str, str]:
    """读 transcript.md，回 (full_text_for_prompt, date, topic)。date/topic 从头部元信息抓，缺则兜底。"""
    text = Path(transcript_md_path).read_text(encoding="utf-8", errors="ignore")
    date = None
    topic = None
    m = re.search(r"^-\s*日期:\s*(\d{4}-\d{1,2}-\d{1,2})", text, re.M)
    if m:
        d = re.match(r"(\d{4})-(\d{1,2})-(\d{1,2})", m.group(1))
        date = f"{d.group(1)}-{int(d.group(2)):02d}-{int(d.group(3)):02d}"
    m = re.search(r"^#\s*会议转写\s*·\s*(.+?)\s*$", text, re.M)
    if m:
        topic = m.group(1).strip()
    date = date or _dt.date.today().isoformat()
    topic = topic or "会议"
    return text, date, topic


def _build_prompt(transcript_text: str) -> str:
    spec = ""
    try:
        spec = _EXTRACT_SPEC.read_text(encoding="utf-8")
    except OSError:
        pass
    parts = []
    if spec:
        parts.append("【抽取工作流规范（参考，按其精神抽取；最终只输出 JSON）】\n" + spec[:4000])
    parts.append("【会议转写（抽取对象）】\n" + transcript_text)
    return "\n\n".join(parts)


def _call_model(prompt: str, *, dry_run: bool) -> str:
    if dry_run:
        # 离线占位：返回一个最小合法 JSON，让全链路（解析+写盘）可在无 key 下走通。
        return json.dumps({
            "topic": "（dry-run）", "participants": ["说话人1"],
            "disagreements": ["无明显分歧"],
            "viewpoints": {"说话人1": ["（dry-run 占位观点）"]},
            "todos": [{"assignee": "我", "task": "（dry-run 占位待办）", "due": None, "is_mine": True}],
        }, ensure_ascii=False)
    from shared import model_router
    model_router.load_secrets()
    # 长会（多小时/多人）extract 的两个坑，都靠加输出预算解：
    #   1) 观点+todo 的 JSON 本身超长 → 4000 截断成 "Unterminated string"；
    #   2) deepseek-pro 是 reasoner，思考先吃预算，预算不够→正文空（"Expecting value char 0"）。
    # 单独给到 16000（recall/eval 仍走 SCENE_ROUTES 的 4000，不受影响）。
    return model_router.call(prompt, _SYSTEM, scene="extract", max_tokens=16000)


def _parse_json(raw: str) -> dict:
    """容模型偶尔包代码围栏 / 前后缀文字：抓第一个 {…} 平衡块。"""
    raw = raw.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```[a-zA-Z]*\n?", "", raw)
        raw = re.sub(r"\n?```$", "", raw).strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        s, e = raw.find("{"), raw.rfind("}")
        if s != -1 and e != -1 and e > s:
            return json.loads(raw[s:e + 1])
        raise


def _render_note(data: dict, *, date: str, slug: str, topic: str, source_audio: str,
                 transcript_text: str) -> str:
    participants = data.get("participants") or []
    pstr = "[" + ", ".join(str(p) for p in participants) + "]"
    fm = [
        "---",
        f"date: {date}",
        f"title: {topic}",
        f"topic: {topic}",
        f"participants: {pstr}",
        "source: 整理自录音",
        "owner: local-agent",
        "type: meeting",
        "---",
        f"# {topic}（{date}）",
        "",
        "## 分歧点",
    ]
    diss = data.get("disagreements") or ["无明显分歧"]
    fm += [f"- {d}" for d in diss]
    fm += ["", "## 各人观点"]
    for name, views in (data.get("viewpoints") or {}).items():
        fm.append(f"### {name}")
        fm += [f"- {v}" for v in (views or [])]
    fm += ["", "## 待办"]
    for td in (data.get("todos") or []):
        due = f"（截止 {td['due']}）" if td.get("due") else ""
        fm.append(f"- {td.get('assignee', '?')}：{td.get('task', '')}{due}")
    fm += ["", f"> 我的 todo 已同步至 [[{date}]]（工作日记）。", "",
           "---", "", "> [!quote]- 全文转写（核对底本，点击展开）"]
    for line in transcript_text.splitlines():
        fm.append(f"> {line}")
    return "\n".join(fm) + "\n"


def _append_journal(vault: Path, vroot: Path, date: str, slug: str, todos: list) -> int:
    """把 is_mine 的 todo 追加到当天工作日记的「## 待办」区，Obsidian Tasks 格式 + 回链。返回写入条数。"""
    mine = [t for t in todos if t.get("is_mine")]
    if not mine:
        return 0
    jdir = vault / config.MEETING_JOURNAL_DIR
    jpath = jdir / f"{date}.md"
    if not _within_vault(jpath, vroot):
        return 0
    jdir.mkdir(parents=True, exist_ok=True)
    lines = []
    for t in mine:
        due = f"  📅 {t['due']}" if t.get("due") else ""
        lines.append(f"- [ ] {t.get('task', '')}{due}  [[{date}-{slug}]]")
    block = "\n".join(lines) + "\n"
    existing = jpath.read_text(encoding="utf-8") if jpath.exists() else ""
    if "## 待办" in existing:
        # 追加到「## 待办」段末（简单稳妥：插在该标题行之后）
        out = re.sub(r"(##\s*待办[^\n]*\n)", r"\1" + block, existing, count=1)
    else:
        sep = "" if existing.endswith("\n") or not existing else "\n"
        out = existing + sep + "\n## 待办\n" + block
    jpath.write_text(out, encoding="utf-8")
    return len(mine)


def extract_meeting(transcript_md_path: str, *, source_audio: str | None = None,
                    dry_run: bool = False) -> dict:
    """transcript.md → 抽取 → 写 Obsidian 纪要 + 工作日记。

    返回 dict：
      {"ok": bool, "written": bool, "note_path": str|None, "journal_path": str|None,
       "todos_to_journal": int, "data": <抽取的 JSON dict>, "note": <纪要 md 文本>,
       "reason": str|None}
    vault 未配置 → ok=True、written=False、note=纪要文本（仍可用于预览/Track2），reason 说明。
    """
    tpath = Path(transcript_md_path)
    if not tpath.exists():
        return {"ok": False, "written": False, "reason": f"找不到 transcript: {tpath}"}
    transcript_text, date, topic = _read_transcript(str(tpath))
    source_audio = source_audio or tpath.name

    try:
        raw = _call_model(_build_prompt(transcript_text), dry_run=dry_run)
        data = _parse_json(raw)
    except Exception as e:  # noqa: BLE001
        errlog.log("meeting:extract", e, transcript=str(tpath))
        return {"ok": False, "written": False, "reason": f"抽取/解析失败：{e}"}

    topic = data.get("topic") or topic
    slug = _slug(topic)
    note_md = _render_note(data, date=date, slug=slug, topic=topic,
                           source_audio=source_audio, transcript_text=transcript_text)

    vault = _vault()
    if vault is None:
        return {"ok": True, "written": False, "note_path": None, "journal_path": None,
                "todos_to_journal": 0, "data": data, "note": note_md,
                "reason": "vault 未配置（设 GROWTH_OBSIDIAN_VAULT 后写回）"}

    try:
        vroot = vault.resolve()
    except OSError as e:
        return {"ok": False, "written": False, "data": data, "note": note_md,
                "reason": f"vault 路径解析失败：{e}"}

    mdir = vault / config.MEETING_VAULT_DIR
    note_path = mdir / f"{date}-{slug}.md"
    n = 1
    while note_path.exists():  # 同名不覆盖
        note_path = mdir / f"{date}-{slug}-{n}.md"
        n += 1
    if not _within_vault(note_path, vroot):
        return {"ok": False, "written": False, "data": data, "note": note_md,
                "reason": "纪要路径越出 vault，已拒绝写回"}
    try:
        mdir.mkdir(parents=True, exist_ok=True)
        note_path.write_text(note_md, encoding="utf-8")
        n_journal = _append_journal(vault, vroot, date, slug, data.get("todos") or [])
    except OSError as e:
        errlog.log("meeting:extract:write", e, note=str(note_path))
        return {"ok": False, "written": False, "data": data, "note": note_md,
                "reason": f"写回失败：{e}"}

    return {"ok": True, "written": True, "note_path": str(note_path),
            "journal_path": str(vault / config.MEETING_JOURNAL_DIR / f"{date}.md") if n_journal else None,
            "todos_to_journal": n_journal, "data": data, "note": note_md, "reason": None}


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(
        description="自动抽取会议纪要：transcript.md → Obsidian 纪要 + 工作日记")
    ap.add_argument("transcript", help="inbox 里的 *.transcript.md 路径")
    ap.add_argument("--source-audio", default=None, help="原音频文件名（写进 frontmatter 注释，可选）")
    ap.add_argument("--dry-run", action="store_true", help="不调 API，用占位 JSON 走通写盘链路")
    args = ap.parse_args()
    r = extract_meeting(args.transcript, source_audio=args.source_audio, dry_run=args.dry_run)
    if not r.get("ok"):
        print("✗ " + (r.get("reason") or "抽取失败"))
        return 1
    if r.get("written"):
        print(f"✓ 纪要: {r['note_path']}")
        if r.get("todos_to_journal"):
            print(f"✓ {r['todos_to_journal']} 条我的 todo → {r['journal_path']}")
    else:
        print("· 未写回（" + (r.get("reason") or "") + "）；纪要预览：\n")
        print(r["note"][:600])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""ingest.meeting —— 把 meeting-notes 管线并入 growth-agent 的子代理包。

音频 → StepAudio ASR →（可选 CAM++ 匿名分人）→ 声纹推测 → inbox transcript →
自动抽取（每人观点+分歧点+todo）→ 写回 Obsidian 纪要 + 工作日记。

纪律：
- `import ingest.meeting` **零外部依赖**——torch/modelscope/soundfile/numpy/requests
  全部在函数内惰性 import。没装重依赖时 diarization 退化为「未分人」，与上游 run.py 一致。
- 抽取走 server.model_router.call(scene='extract')（deepseek-pro），复用 growth 的 secrets。
- 路径/来源纪律全收敛到 ingest/config.py（MEETING_INBOX / MEETING_ARTIFACTS / MEETING_VOICEPRINTS）。

────────────────────────── Track 2 稳定接口契约 ──────────────────────────
Track 2（说话人确认 UI）只依赖本模块这两个函数 + 一份每会 JSON，不碰内部实现。

clusters_for_meeting(meeting_id: str) -> list[dict]
    每个 dict（一个匿名说话人簇）：
      {
        "cluster_id":  str,            # 簇代号，如 "说话人1"
        "snippet_path": str | None,    # 3-5s 代表音频切片的绝对路径（无音频/未装 soundfile→None）
        "suggestion":  {"name": str, "score": float} | None,  # 声纹底库提名（≥阈值才有；否则 None）
        "sample_text": str,            # 该簇最长一句台词（辨识用）
        "seconds":     float,          # 该簇总发言时长（秒）
      }

confirm_speaker(meeting_id: str, cluster_id: str, name: str) -> {"ok": bool, "enrolled": bool}
    把某簇人工确认为真名：(1) 在 transcript.md 里把该 cluster_id 标注成「cluster_id（name）」，
    (2) 若该会有声纹边车，调 enroll 把该簇声纹种入底库（越用越准；下次同人自动被推测）。
    enrolled=False 表示边车里无该簇声纹（语音太少未提取）或库未配置——确认仍生效（标注成功）。

每会 JSON（管线写、Track 2 读）：config.MEETING_ARTIFACTS/<meeting_id>/clusters.json
  {
    "meeting_id":      str,
    "transcript_path": str,          # 该会 inbox transcript.md 绝对路径
    "clusters": [ <上面 clusters_for_meeting 的 dict>, ... ]
  }
配套边车 <meeting_id>.speakers.json（同目录）：{cluster_id: {"pred": [name,score]|null, "emb":[192 floats]}}
  —— confirm_speaker 的 enroll 从这里取声纹向量，免重算。
─────────────────────────────────────────────────────────────────────────
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from . import speaker_id as _sid
from shared import paths as config

__all__ = ["clusters_for_meeting", "confirm_speaker", "list_meetings"]

_DATE_PREFIX = re.compile(r"^(\d{4}-\d{2}-\d{2})[-_ ]?(.*)$")


def clusters_for_meeting(meeting_id: str) -> list[dict]:
    """读每会 clusters.json，返回各匿名簇供确认门展示。不存在 → []（无重依赖）。"""
    data = _sid.read_clusters(meeting_id)
    return data.get("clusters") or []


def list_meetings() -> list[dict]:
    """扫 MEETING_ARTIFACTS 下各会的 clusters.json，给 app 的会议选择器。无目录 → []。
    每条：{id, date, title, n_speakers, n_unconfirmed}（date 取 meeting_id 的 YYYY-MM-DD 前缀）。"""
    root = Path(config.MEETING_ARTIFACTS)
    out: list[dict] = []
    if not root.is_dir():
        return out
    for d in root.iterdir():
        cj = d / "clusters.json"
        if not cj.is_file():
            continue
        try:
            data = json.loads(cj.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        mid = data.get("meeting_id") or d.name
        clusters = data.get("clusters") or []
        m = _DATE_PREFIX.match(str(mid))
        date = m.group(1) if m else ""
        title = ((m.group(2) if m else str(mid)) or "").strip() or str(mid)
        out.append({
            "id": mid,
            "date": date,
            "title": title,
            "n_speakers": len(clusters),
            "n_unconfirmed": sum(1 for c in clusters if not (c or {}).get("confirmed_name")),
        })
    out.sort(key=lambda r: r["date"], reverse=True)  # 新会在前；无 date 殿后
    return out


def _relabel_transcript(transcript_path: Path, cluster_id: str, name: str) -> bool:
    """把 transcript.md 里 **{cluster_id}** 的粗体标注改成 **{cluster_id}（{name}）**。
    只动逐句行的说话人标签，幂等（已含真名则不重复加）。返回是否改动。"""
    try:
        text = transcript_path.read_text(encoding="utf-8")
    except OSError:
        return False
    # 匹配行首的 `- **说话人N**` / `- **说话人N?**`，避开已带（真名）的
    pat = re.compile(r"(- \*\*" + re.escape(cluster_id) + r"\??)(\*\*)")
    new, n = pat.subn(lambda m: m.group(1) + f"（{name}）" + m.group(2)
                      if "（" not in m.group(0) else m.group(0), text)
    if n and new != text:
        transcript_path.write_text(new, encoding="utf-8")
        return True
    return False


def confirm_speaker(meeting_id: str, cluster_id: str, name: str) -> dict:
    """确认某簇真名：标注 transcript + enroll 声纹。返回 {"ok": bool, "enrolled": bool}。
    标注永远尝试；enroll 仅在有边车声纹时发生（越用越准）。任何子步失败不互相拖累。"""
    data = _sid.read_clusters(meeting_id)
    ok = False
    tpath = data.get("transcript_path")
    if tpath:
        ok = _relabel_transcript(Path(tpath), cluster_id, name)

    enrolled = False
    sidecar = _sid._meeting_dir(meeting_id) / f"{meeting_id}.speakers.json"
    if sidecar.exists():
        try:
            from .enroll import enroll_one  # 惰性：用到 numpy/底库时才 import
            r = enroll_one(sidecar, cluster_id, name, meeting=meeting_id)
            enrolled = bool(r.get("enrolled"))
        except Exception:  # noqa: BLE001
            enrolled = False
    # 把确认结果回写进 clusters.json（confirmed 字段），让 UI 刷新后看到已定
    for c in data.get("clusters", []):
        if c.get("cluster_id") == cluster_id:
            c["confirmed_name"] = name
            break
    try:
        _sid.write_clusters(meeting_id, data)
        ok = True
    except OSError:
        pass
    return {"ok": bool(ok), "enrolled": enrolled}


def confirm_speaker_v2(meeting_id: str, cluster_id: str, name: str, *, text: str | None = None) -> dict:
    """v2 平行入口（声纹迁移 P0.6，见 docs/voiceprint-migration-checklist.md 检查点A）：
    确认某簇真名 → 标注 transcript（与 v1 共用同一份 transcript.md，标注逻辑不重复造）→
    该簇代表音频片段(snippet_path)过 check_enroll_gates 硬门 → 过门才用 embed_v2 入 registry_v2。

    与 confirm_speaker（v1）完全并行、互不调用：v1 走 CAM++ 192d + 边车 emb 直接入库（无门），
    v2 走 pyannote 256d + 广播硬门（不过门直接拒绝，不落库）。老函数 confirm_speaker 零改动。

    返回 {"ok": bool, "enrolled": bool, "reason": str|None}：
      ok=标注是否成功；enrolled=是否真的写进了 registry_v2；
      reason 在 enrolled=False 时给出人话解释（没有代表音频 / 未过硬门 / 声纹算不出来）。
    """
    data = _sid.read_clusters(meeting_id)
    ok = False
    tpath = data.get("transcript_path")
    if tpath:
        ok = _relabel_transcript(Path(tpath), cluster_id, name)

    enrolled = False
    reason: str | None = None
    snippet_path = None
    for c in data.get("clusters", []):
        if c.get("cluster_id") == cluster_id:
            snippet_path = c.get("snippet_path")
            c["confirmed_name_v2"] = name
            break

    if not snippet_path:
        reason = "该簇没有代表音频片段(snippet_path)，v2 声纹入不了库——标注已生效，声纹库需另外补录一段音频。"
    else:
        try:
            from .enroll import enroll_audio_v2  # 惰性：用到 torch/pyannote 时才 import
            r = enroll_audio_v2(name, snippet_path, meeting=meeting_id, text=text)
            enrolled = bool(r.get("enrolled"))
            if not enrolled:
                reason = r.get("reason")
        except Exception as e:  # noqa: BLE001
            reason = f"v2 入库子流程异常（{type(e).__name__}: {e}）——标注仍生效，声纹库未受影响。"

    try:
        _sid.write_clusters(meeting_id, data)
        ok = True
    except OSError:
        pass
    return {"ok": bool(ok), "enrolled": enrolled, "reason": reason}

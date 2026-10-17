"""声纹底库：把已确认的「真名→声纹」存起来，给新会的匿名簇做身份推测（并入 growth-agent）。

设计要点（见上游 README「声纹底库」）：
- 复用 CAM++ SV 模型（damo/speech_campplus_sv_zh-cn_16k-common）产出 192 维 embedding。
  接口已核对：sv([wav_path], output_emb=True) -> {'embs': (1,192)}。
- 底库 registry.json（config.MEETING_VOICEPRINTS 下）：
  {people: {真名: {embeddings:[…多条…], meetings, samples, updated}}}。
  一人存多条（不同会/音质），匹配取最高余弦相似度。embedding 入库前 L2 归一化，相似度=点积。
- 安全：只「建议」不「自动落定」——高于 _MATCH_THRESHOLD 才提名，最终由确认门人工拍板；
  只注册人工确认过的簇（enroll 由确认门后触发），防污染。短簇（音频太少）不提名/不入库。

并入改动：
- `numpy` / `soundfile` / `modelscope` 全部**函数内惰性 import**——`import ingest.meeting`
  不装它们也成功（match()/enroll() 用到 numpy 时才 import，本机已装 numpy）。
- REGISTRY 路径走 config.MEETING_VOICEPRINTS（随仓走，可 env 覆盖），不再硬编码包内目录。
"""
from __future__ import annotations

import datetime as _dt
import json
import tempfile
from pathlib import Path

from shared import paths as config

_SV_MODEL = "damo/speech_campplus_sv_zh-cn_16k-common"
REGISTRY = Path(config.MEETING_VOICEPRINTS) / "registry.json"
_MATCH_THRESHOLD = 0.62   # 余弦≥此值才提名。经验：本模型同人跨会约 0.6~0.85、异人多 <0.4；
                          # 仅「建议」由人工确认门拍板，故取能召回真匹配又不易误报的 0.62
_MIN_SPEAKER_SEC = 8.0    # 簇总时长不足则不提名/不入库（声纹不可靠）
_MAX_SPEAKER_SEC = 60.0   # 每人最多采 60s 算声纹：够用，且避免长会议拼几十分钟音频 OOM
_BYTES_PER_SEC = 16000 * 2

_sv = None


def _np():
    """惰性取 numpy（保持 import 包零外部依赖）。"""
    import numpy as np  # noqa: PLC0415
    return np


def _load_sv():
    global _sv
    if _sv is None:
        from modelscope.pipelines import pipeline
        from modelscope.utils.constant import Tasks
        _sv = pipeline(task=Tasks.speaker_verification, model=_SV_MODEL)
    return _sv


def _l2(v):
    np = _np()
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


def embed_wav(wav_path: str):
    """对一个 16k mono wav 算 L2 归一化的 192 维声纹。"""
    np = _np()
    r = _load_sv()([wav_path], output_emb=True)
    return _l2(np.asarray(r["embs"]).reshape(-1).astype(np.float32))


def embed_speaker_spans(full_wav: str, spans_ms: list[tuple[int, int]]):
    """裁出某说话人的所有片段拼接后算声纹；总时长不足返回 None。
    用 SoundFile.seek 只读所需帧（长会议整段读入会 OOM——这是踩过的坑）。"""
    import soundfile as sf
    np = _np()
    chunks = []
    total = 0
    with sf.SoundFile(full_wav) as f:
        sr, nframes = f.samplerate, len(f)
        cap = int(_MAX_SPEAKER_SEC * sr)  # 采够 60s 即停，避免长会议拼几十分钟 OOM
        # 优先取最长的几段（长连续发言更可能是干净单人语音，避开开场嘈杂/串音的碎片）
        for s_ms, e_ms in sorted(spans_ms, key=lambda p: p[1] - p[0], reverse=True):
            if total >= cap:
                break
            a = max(0, min(int(s_ms / 1000 * sr), nframes))
            b = max(0, min(int(e_ms / 1000 * sr), nframes))
            if b > a:
                b = min(b, a + (cap - total))  # 末段截到刚好够 60s
                f.seek(a)
                data = f.read(b - a, dtype="float32")
                if data.ndim > 1:
                    data = data[:, 0]
                chunks.append(data)
                total += b - a
    if not chunks or total / sr < _MIN_SPEAKER_SEC:
        return None
    cat = np.concatenate(chunks)
    with tempfile.TemporaryDirectory() as td:
        tmp = str(Path(td) / "spk.wav")
        sf.write(tmp, cat, sr)
        return embed_wav(tmp)


def write_speaker_clip(full_wav: str, spans_ms: list[tuple[int, int]], out_path: str,
                       *, clip_seconds: float = 10.0, num_clips: int = 4,
                       gap_seconds: float = 0.4) -> str | None:
    """裁该说话人最长的 num_clips 段（各约 clip_seconds 秒，段间留白）拼成一条代表切片，落到
    out_path 供确认门试听。多段更长更好认人——单段几秒太难分辨谁是谁（用户反馈）。
    Track 2 用：clusters_for_meeting() 返回的 snippet_path 指向它。没装 soundfile 返回 None。"""
    try:
        import soundfile as sf
    except Exception:
        return None
    if not spans_ms:
        return None
    np = _np()
    # 取最长的几段（长段更可能是干净单人语音），再按时间先后排回去，听起来自然不跳。
    picked = sorted(spans_ms, key=lambda p: p[1] - p[0], reverse=True)[:max(1, num_clips)]
    picked.sort(key=lambda p: p[0])
    try:
        with sf.SoundFile(full_wav) as f:
            sr, nframes = f.samplerate, len(f)
            want = int(clip_seconds * sr)
            gap = np.zeros(max(0, int(gap_seconds * sr)), dtype="float32")  # 段间留白，听感上分得清是不同段
            parts = []
            for s_ms, e_ms in picked:
                a = max(0, min(int(s_ms / 1000 * sr), nframes))
                b = max(0, min(int(e_ms / 1000 * sr), nframes))
                if b - a > want:                 # 段比目标长 → 取中段；短 → 整段都要（凑时长 + 多样性）
                    mid = (a + b) // 2
                    a = max(0, mid - want // 2)
                    b = min(nframes, a + want)
                if b <= a:
                    continue
                f.seek(a)
                data = f.read(b - a, dtype="float32")
                if data.ndim > 1:
                    data = data[:, 0]
                if parts and gap.size:
                    parts.append(gap)
                parts.append(data)
            if not parts:
                return None
            clip = np.concatenate(parts)
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        sf.write(out_path, clip, sr)
        return out_path
    except Exception:
        return None


def spans_by_speaker(lines) -> dict[str, list[tuple[int, int]]]:
    """从 diarization 后的 Line（带 speaker/start_ms/end_ms）聚出每个说话人的时间片段。
    speaker 后缀 '?'（低置信）归并到主代号。"""
    out: dict[str, list[tuple[int, int]]] = {}
    for ln in lines:
        spk = getattr(ln, "speaker", None)
        if not spk or ln.start_ms is None or ln.end_ms is None:
            continue
        spk = spk.rstrip("?")
        out.setdefault(spk, []).append((ln.start_ms, ln.end_ms))
    return out


# ---------------- 底库读写 / 匹配 / 注册 ----------------

def load_registry() -> dict:
    if REGISTRY.exists():
        return json.loads(REGISTRY.read_text(encoding="utf-8"))
    return {"version": 1, "people": {}}


def save_registry(reg: dict) -> None:
    REGISTRY.parent.mkdir(parents=True, exist_ok=True)
    REGISTRY.write_text(json.dumps(reg, ensure_ascii=False, indent=2), encoding="utf-8")


def match(emb, reg: dict, threshold: float = _MATCH_THRESHOLD):
    """返回 (真名, 相似度) 或 None。对每人取其多条声纹的最高相似度，再全局取最高。"""
    np = _np()
    best_name, best_score = None, 0.0
    for name, rec in reg.get("people", {}).items():
        for e in rec.get("embeddings", []):
            score = float(np.dot(emb, _l2(np.asarray(e, dtype=np.float32))))
            if score > best_score:
                best_name, best_score = name, score
    if best_name is not None and best_score >= threshold:
        return best_name, best_score
    return None


def enroll(reg: dict, name: str, emb, meeting: str = "") -> dict:
    """把一条人工确认过的声纹入库（去重：与同名已有声纹过近则跳过）。"""
    np = _np()
    people = reg.setdefault("people", {})
    rec = people.setdefault(name, {"embeddings": [], "meetings": [], "samples": 0, "updated": ""})
    for e in rec["embeddings"]:
        if float(np.dot(emb, _l2(np.asarray(e, dtype=np.float32)))) > 0.97:
            return reg  # 已有几乎相同的声纹，不重复存
    rec["embeddings"].append([round(float(x), 6) for x in emb.tolist()])
    rec["samples"] = len(rec["embeddings"])
    if meeting and meeting not in rec["meetings"]:
        rec["meetings"].append(meeting)
    rec["updated"] = _dt.date.today().isoformat()
    return reg


def predict(full_wav: str, lines, reg: dict, threshold: float = _MATCH_THRESHOLD):
    """对每个匿名说话人簇算声纹并匹配底库。
    返回 (predictions, embeddings)：
      predictions = {说话人N: (真名, 相似度) | None}
      embeddings  = {说话人N: [192 floats]}  —— 供确认门后 enroll 复用，免重算。
    """
    preds, embs = {}, {}
    for spk, spans in spans_by_speaker(lines).items():
        emb = embed_speaker_spans(full_wav, spans)
        if emb is None:
            preds[spk] = None
            continue
        embs[spk] = [round(float(x), 6) for x in emb.tolist()]
        preds[spk] = match(emb, reg, threshold)
    return preds, embs


# ---------------- Track 2 接口：每会聚类 JSON 的读写 + 确认门 ----------------
# 见 ingest/meeting/__init__.py 的 clusters_for_meeting / confirm_speaker（公开入口）。
# 这里是它们的实现，依赖 config.MEETING_ARTIFACTS/<meeting_id>/clusters.json（run.py 写）。

def _meeting_dir(meeting_id: str) -> Path:
    """每会的 artifact 目录（边车 / clusters.json / 代表切片都落这里）。
    meeting_id 清洗防路径穿越。"""
    import re
    safe = re.sub(r"[/\\]", "_", str(meeting_id or "")).replace("..", "_").strip()
    return Path(config.MEETING_ARTIFACTS) / (safe or "未命名会议")


def clusters_json_path(meeting_id: str) -> Path:
    return _meeting_dir(meeting_id) / "clusters.json"


def read_clusters(meeting_id: str) -> dict:
    """读每会 clusters.json（run.py 写）。不存在返回空骨架。"""
    p = clusters_json_path(meeting_id)
    if p.exists():
        return json.loads(p.read_text(encoding="utf-8"))
    return {"meeting_id": meeting_id, "transcript_path": None, "clusters": []}


def write_clusters(meeting_id: str, data: dict) -> Path:
    p = clusters_json_path(meeting_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return p

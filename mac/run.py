"""编排：音频 → ASR →（可选 diarize）→ 声纹推测 → 写 inbox transcript → extract → 写回 vault。

并入 growth-agent（vs meeting-notes/pipeline/run.py）：
- key 走 growth 的 STEPFUN_API_KEY（model_router.load_secrets() 注入），不再读 STEP_API_KEY。
- 路径走 config：transcript 落 MEETING_INBOX；每会边车/聚类/代表切片落 MEETING_ARTIFACTS/<mid>/。
- 自动接 extract（原来是手工 Claude 动作）：转写落地后直接 extract_meeting()，--no-extract 可关。
- 写 clusters.json（Track 2 确认门 UI 依赖的稳定产物，shape 见 __init__.py 文档）。
- diarization 没装时自动退化为「未分人」，与上游一致。
- --dry-run：不调真 ASR/extract、不碰真音频，用占位转写走通全链路（无 key/无 audio 可测）。

CLI：
  python3 -m ingest.meeting.run <audio_file> [--topic 周会] [--dry-run] [--no-extract]
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

from shared import paths as config
from . import speaker_id as sid
from .broadcast_gate import BROADCAST_TAG
from .extract import extract_meeting
from .transcript import group_segments_into_lines, render_transcript

# torch/modelscope（分人+声纹）装在 _pipeline/.venv（3.11），不在 growth 守护的 3.9 里。
# 本地能 import torch → 直接跑；否则 subprocess 到 .venv 跑 sv_worker（口径与 recording_pipeline 一致）。
_SV_PY = (os.environ.get("GROWTH_SV_PYTHON") or os.environ.get("GROWTH_PIPELINE_PY")
          or str(config.PIPELINE_DIR / ".venv" / "bin" / "python"))
_SV_WORKER = str(Path(__file__).resolve().parent / "sv_worker.py")
_GROWTH_ROOT = str(Path(__file__).resolve().parents[2])
_SV_TIMEOUT = int(os.environ.get("GROWTH_SV_TIMEOUT", "3600"))


def _safe_topic(topic: str) -> str:
    topic = (topic or "会议").strip()
    return re.sub(r"[/\\:*?\"<>|]+", "_", topic)[:40]


def _have_torch() -> bool:
    try:
        import torch  # noqa: F401,PLC0415
        return True
    except Exception:  # noqa: BLE001
        return False


def _sv_subprocess(cmd_args, *, timeout=_SV_TIMEOUT):
    """在 .venv 跑 sv_worker，返回解析后的 JSON dict；不可用/失败 → None。PYTHONPATH 指向 growth 根。"""
    if not Path(_SV_PY).exists():
        print(f"[info] .venv python 不在（{_SV_PY}），跳过分人/声纹")
        return None
    env = dict(os.environ, PYTHONPATH=_GROWTH_ROOT)
    try:
        r = subprocess.run([_SV_PY, _SV_WORKER, *cmd_args],
                           capture_output=True, text=True, timeout=timeout, env=env)
    except Exception as e:  # noqa: BLE001
        print(f"[info] sv_worker 调用失败（{e}）")
        return None
    if r.returncode != 0:
        print(f"[info] sv_worker rc={r.returncode}: {(r.stderr or '')[-200:]}")
        return None
    try:
        return json.loads(r.stdout)
    except Exception:  # noqa: BLE001 — stdout 偶有噪声前缀（模型下载）→ 兜底抠 JSON
        from shared.ingest_store import extract_json
        d = extract_json(r.stdout, kind="object")
        if d is not None:
            return d
        print(f"[info] sv_worker 输出非 JSON: {(r.stdout or '')[:120]}")
        return None


def _maybe_diarize(audio_path: str, lines):
    """分说话人对齐：本地有 torch 直接跑，否则 .venv 子进程；都不行则退化为「未分人」。"""
    from .align import assign_speakers
    if _have_torch():
        try:
            from .diarize import diarize_turns
            return assign_speakers(lines, diarize_turns(audio_path))
        except Exception as e:  # noqa: BLE001
            print(f"[info] 跳过 diarization（{e}）")
            return lines
    data = _sv_subprocess(["diarize", "--wav", audio_path])
    if not data or "turns" not in data:
        return lines
    from .align import SpeakerTurn
    turns = [SpeakerTurn(start_ms=t["start_ms"], end_ms=t["end_ms"], speaker=t["speaker"])
             for t in data["turns"]]
    return assign_speakers(lines, turns)


def _maybe_speaker_id(wav_path: str, lines, clips_dir=None, skip_clusters=None):
    """对每个匿名簇算声纹、与底库匹配（CAM++ SV，余弦相似度）。返回 (guesses, embeddings)；异常降级为空。
    本地有 torch 直接 sid.predict；否则把每簇时间片传 .venv worker 算声纹+匹配（+ 可选写代表切片到 clips_dir）。
    切片落 clips_dir/<簇>.wav（soundfile 在 .venv 才有），_write_clusters_json 优先用它。
    skip_clusters：播报闸判定的整簇播报（地铁/导航/广告），不算声纹、不进匹配（源头挡假阳性）。"""
    skip = skip_clusters or set()
    if skip:  # 播报簇的行不参与声纹计算（省算力 + 不产生 suggestion）
        lines = [l for l in lines if ((getattr(l, "speaker", None) or "").rstrip("?")) not in skip]
    try:
        if _have_torch():
            reg = sid.load_registry()
            preds, embs = sid.predict(wav_path, lines, reg)
            return {spk: pred for spk, pred in preds.items() if pred}, embs
        spans = sid.spans_by_speaker(lines)
        if not spans:
            return {}, {}
        tmp = Path(tempfile.gettempdir()) / f"svspans_{os.getpid()}.json"
        tmp.write_text(json.dumps({k: v for k, v in spans.items()}, ensure_ascii=False), encoding="utf-8")
        args = ["speaker_id", "--wav", wav_path, "--spans", str(tmp)]
        if clips_dir:
            args += ["--clips-dir", str(clips_dir)]
        try:
            data = _sv_subprocess(args)
        finally:
            try:
                tmp.unlink()
            except OSError:
                pass
        if not data:
            return {}, {}
        preds = data.get("predictions") or {}
        guesses = {spk: (p[0], p[1]) for spk, p in preds.items() if p}   # [name,score] → (name,score)
        return guesses, (data.get("embeddings") or {})
    except Exception as e:  # noqa: BLE001
        print(f"[info] 跳过声纹推测（{e}）")
        return {}, {}


def _archive_line_embs(meeting_id: str, wav_path: str, lines) -> None:
    """① 逐句声纹留档（核心集方案纪律：embedding 跟着 L0 走，永久留存）。
    音频是易逝的，这是匿名说话人日后能「回溯重认」的唯一前提——转写落地时必须顺手算掉。
    fail-open：留档失败只警告不挡管线（可用 memory/line_embs --backfill 补）。"""
    try:
        from shared import line_embs
        from .transcript import _ms_to_mmss
        spans = {_ms_to_mmss(ln.start_ms): (ln.start_ms, ln.end_ms)
                 for ln in lines if ln.start_ms is not None and ln.end_ms is not None}
        if not spans:
            return
        _, n = line_embs.ensure(meeting_id, wav_path, spans)
        _, nd = line_embs.ensure_db(meeting_id, wav_path, spans)   # 逐行能量（近场判据，轻量）
        if n or nd:
            print(f"[emb] 逐句留档 声纹+{n} 能量+{nd} → data/line_embs/{meeting_id}[.db].npz")
    except Exception as e:  # noqa: BLE001
        print(f"[warn] 逐句声纹留档失败（不挡管线，可 --backfill 补）: {e}")


def _broadcast_filter(lines) -> dict:
    """播报闸：diarize 之后、声纹之前，文本层判掉录进来的非参与者音源（报站/导航/广告/电视）。
    返回 broadcast_gate.classify 的结果 dict。fail-open：任何异常 → 空（不挡管线）。"""
    try:
        from . import broadcast_gate
        r = broadcast_gate.classify(lines)
        if r["broadcast_lines"]:
            print(f"[bcast] 播报行 {len(r['broadcast_lines'])}（整簇播报 {sorted(r['broadcast_clusters'])}）"
                  f"→ 不进声纹/enroll/core_gate/L1")
        return r
    except Exception as e:  # noqa: BLE001
        print(f"[info] 播报闸跳过（{e}）")
        return {"broadcast_lines": set(), "broadcast_clusters": set(), "verdicts": {}}


def _core_autoconfirm(lines, embs: dict, meeting_id: str = "", bcast: dict | None = None) -> dict:
    """② 核心集闭集判定（严阈值+边界LDA+近场判据，见 core_gate 模块文档）。
    返回 {簇: {name,score,runner_up,via}}；任何异常都按不放行处理。"""
    try:
        from . import core_gate
        spans = sid.spans_by_speaker(lines)
        seconds = {spk: sum(e - s for s, e in sp) / 1000.0 for spk, sp in spans.items()}
        near = {}
        if meeting_id:  # 近场相对分（佩戴者=近场响；「我」的判定要过能量关）
            try:
                from shared import line_embs
                from .transcript import _ms_to_mmss
                bl = (bcast or {}).get("broadcast_lines") or set()
                by_spk, exclude = {}, set()
                for i, ln in enumerate(lines):
                    if ln.start_ms is None:
                        continue
                    ts = _ms_to_mmss(ln.start_ms)
                    if i in bl:      # 播报行不进参考分布（PA 喇叭比佩戴者响，会抬高 P90）
                        exclude.add(ts)
                        continue
                    s = (getattr(ln, "speaker", None) or "").rstrip("?")
                    if s:
                        by_spk.setdefault(s, []).append(ts)
                near = {s: line_embs.near_rel_db(meeting_id, tss, exclude_ts=exclude)
                        for s, tss in by_spk.items()}
            except Exception:  # noqa: BLE001
                near = {}
        auto = core_gate.decide(embs, seconds, sid.load_registry(), near_rel=near)
        for spk, info in auto.items():
            print(f"[core] 自动落定 {spk} → {info['name']}（cos {info['score']}，{info['via']}）")
        return auto
    except Exception as e:  # noqa: BLE001
        print(f"[info] 核心集闸跳过（{e}）")
        return {}


def _stepfun_key() -> str:
    import os
    from shared import model_router
    model_router.load_secrets()
    key = os.environ.get("STEPFUN_API_KEY")
    if not key:
        raise RuntimeError("缺 STEPFUN_API_KEY（~/.config/growth-agent/secrets.env）")
    return key


def _line_text_for(spk: str, lines) -> str:
    """取该说话人最长的一句作 sample_text（确认门展示用）。"""
    best = ""
    for ln in lines:
        s = (getattr(ln, "speaker", None) or "").rstrip("?")
        if s == spk and len(getattr(ln, "text", "")) > len(best):
            best = ln.text
    return best[:120]


def _write_clusters_json(meeting_id: str, transcript_path: Path, wav_path: str | None,
                         lines, guesses: dict, embs: dict, clips_dir=None,
                         auto: dict | None = None, bcast: dict | None = None) -> None:
    """写每会 clusters.json + 代表音频切片（Track 2 确认门 UI 依赖的稳定产物）。
    shape 见 ingest/meeting/__init__.py 模块文档。
    clips_dir 给了且其中已有 <簇>.wav（.venv worker 预写）→ 直接用；否则就地写（需本地 soundfile）。"""
    mdir = sid._meeting_dir(meeting_id)
    mdir.mkdir(parents=True, exist_ok=True)
    spans = sid.spans_by_speaker(lines)
    clusters = []
    for spk in sorted(spans):
        span_list = spans[spk]
        seconds = sum((e - s) for s, e in span_list) / 1000.0
        snippet_path = None
        pre = Path(clips_dir) / f"{spk}.wav" if clips_dir else None
        if pre and pre.exists():                       # .venv worker 已写好的代表切片
            snippet_path = str(pre)
        elif wav_path:
            clip = str(mdir / f"{spk}.wav")
            snippet_path = sid.write_speaker_clip(wav_path, span_list, clip)
        sug = None
        if spk in guesses:
            name, score = guesses[spk]
            sug = {"name": name, "score": round(float(score), 4)}
        c = {
            "cluster_id": spk,
            "snippet_path": snippet_path,
            "suggestion": sug,
            "sample_text": _line_text_for(spk, lines),
            "seconds": round(seconds, 2),
        }
        if auto and spk in auto:      # 核心集严闸自动落定（人工仍可在工作台覆盖/撤销）
            c["auto_confirmed"] = auto[spk]
        if bcast and spk in bcast.get("broadcast_clusters", ()):  # 整簇播报：工作台可隐藏，不是人
            c["broadcast"] = True
            c["suggestion"] = None
        elif bcast and bcast.get("verdicts", {}).get(spk) == "mixed":
            c["mixed_broadcast"] = True   # 混杂簇：真人身份保留，部分行是播报
        clusters.append(c)
    sid.write_clusters(meeting_id, {
        "meeting_id": meeting_id,
        "transcript_path": str(transcript_path),
        "clusters": clusters,
    })
    # 声纹边车（enroll 复用，免重算）
    if embs:
        sidecar = mdir / f"{meeting_id}.speakers.json"
        payload = {spk: {"pred": list(guesses[spk]) if spk in guesses else None,
                         "emb": embs[spk]} for spk in embs}
        sidecar.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")


def _dry_run_transcript(audio_name: str):
    """离线占位：不碰真音频/ASR，造两行「未分人」转写，让全链路可测。"""
    from .transcript import Line
    # 造两个带标签的簇（不调真 diarize），让 Track 2 的 clusters_for_meeting/confirm_speaker
    # 在无音频/无重依赖下也能被走通验证（snippet_path 会是 None——没有真 wav）。
    lines = [
        Line(text="（dry-run）这是占位转写第一句，用来走通管线。", start_ms=0, end_ms=4000, speaker="说话人1"),
        Line(text="（dry-run）这是占位转写第二句，由另一个人说。", start_ms=4000, end_ms=12000, speaker="说话人2"),
    ]
    full_text = "（dry-run）占位全文核对底本。"
    return lines, full_text


def process(audio_path: str, *, topic: str = "会议", do_extract: bool = True,
            dry_run: bool = False, date: str | None = None) -> dict:
    """跑一场会。返回 {meeting_id, transcript_path, clusters_path, extract: <extract_meeting 结果>}。
    date：录音归属日（YYYY-MM-DD），缺省今天——补录历史录音必传，否则错归到处理日。"""
    date = date or _dt.date.today().isoformat()
    safe = _safe_topic(topic)
    audio_name = Path(audio_path).name

    guesses, embs, wav_for_clusters = {}, {}, None
    if dry_run:
        lines, full_text = _dry_run_transcript(audio_name)
    else:
        from .asr_stepfun import audio_to_wav16k, transcribe
        speech_regions = None
        try:  # VAD 送检门：整条没有有效人声 → 不调云 ASR，整条跳过；有人声则把人声块
            #   透传给 transcribe（长录音只送人声块，静音不花 ASR 钱）。失败不挡管线（fail-open）
            from . import vad_gate
            v = vad_gate.check(audio_path)
            if not v["has_speech"]:
                print(f"[vad] 无有效人声（{v['speech_sec']}s / {v['total_sec']}s，"
                      f"阈值 {v['min_speech_sec']}s），跳过送检：{audio_name}")
                return {"meeting_id": None, "transcript_path": None,
                        "clusters_path": None, "extract": None,
                        "skipped": "no_speech", "vad": v}
            print(f"[vad] 人声 {v['speech_sec']}s / {v['total_sec']}s"
                  f"（{v['speech_ratio']:.0%}），送检")
            # 按块送检默认开（阈值0.35+垫30s，2026-08-07 用户定档）：全天字召回 91~94%
            # 换省近四成 ASR 送检量，密会近无损。要整条全送：GROWTH_VAD_SLICE=0。
            # 判决与数据：docs/VAD选型-并列实测-2026-08.md
            if os.environ.get("GROWTH_VAD_SLICE") != "0":
                speech_regions = v.get("speech_regions")
        except Exception as e:  # noqa: BLE001
            print(f"[warn] VAD 门不可用，照常送检: {e}")
        key = _stepfun_key()
        result = transcribe(audio_path, key, enable_timestamp=True,
                            speech_regions=speech_regions)
        lines = group_segments_into_lines(result.segments)
        full_text = result.full_text
        # 先定 meeting_id / 路径：代表切片要落到**持久**的 meeting 目录（确认门 /snippet 之后来取），
        # 且 3.9 守护没 soundfile —— 必须把 clips_dir 透给 .venv 声纹 worker，让它在那边写切片，
        # 否则切片落到本地 write_speaker_clip 这条需 soundfile 的腿，静默失败 → snippet_path 全 None → 没声音。
        inbox = Path(config.MEETING_INBOX)
        inbox.mkdir(parents=True, exist_ok=True)
        tpath = inbox / f"{date}-{safe}.transcript.md"
        k = 1
        while tpath.exists():
            tpath = inbox / f"{date}-{safe}-{k}.transcript.md"
            k += 1
        meeting_id = tpath.name.replace(".transcript.md", "")
        clips_dir = sid._meeting_dir(meeting_id)
        clips_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as td:
            wav = audio_to_wav16k(audio_path, str(Path(td) / "diar_16k.wav"))
            try:  # SED 门：纯媒体段（音乐/电视/歌声）的转写行不入库；失败不挡管线（fail-open）
                from . import sed_gate
                lines, sed_info = sed_gate.apply(
                    audio_path, lines, out_json=clips_dir / f"{meeting_id}.sed.json")
                if sed_info.get("dropped_lines"):
                    print(f"[sed] 剔除媒体段转写 {sed_info['dropped_lines']} 行"
                          f"（媒体 {sed_info['media_sec']}s / 全长 {sed_info['total_sec']}s）")
            except Exception as e:  # noqa: BLE001
                print(f"[warn] SED 门不可用，跳过剔除: {e}")
            lines = _maybe_diarize(wav, lines)
            bcast = _broadcast_filter(lines)             # 播报闸（文本层）：先摘掉报站/导航/广告
            guesses, embs = _maybe_speaker_id(          # 播报簇不算声纹、不产生 suggestion
                wav, lines, clips_dir=clips_dir, skip_clusters=bcast["broadcast_clusters"])
            _archive_line_embs(meeting_id, wav, lines)   # 逐句声纹+能量留档（含播报行：喂未来播报声纹 blocklist）
            auto = _core_autoconfirm(lines, embs, meeting_id, bcast)  # 核心集严闸 → 自动落定名单（embs 已无播报簇）
            # 代表切片要在 tmp wav 删除前写出 → 在 with 内落 clusters（用 .venv 预写的 / 就地拷出 tmp）
            # clusters.json 必须在改标签之前写：cluster_id 要保持「说话人N」原代号（确认门按它索引）
            wav_for_clusters = wav
            _write_clusters_json(meeting_id, tpath, wav_for_clusters, lines, guesses, embs,
                                 clips_dir=clips_dir, auto=auto, bcast=bcast)
            bl = bcast["broadcast_lines"]
            for i, ln in enumerate(lines):
                if i in bl:                              # 播报行打标 → L1 入库跳过（不进原子）
                    ln.speaker = f"{(getattr(ln, 'speaker', None) or '').rstrip('?')}{BROADCAST_TAG}"
                    continue
                base = (getattr(ln, "speaker", None) or "").rstrip("?")
                if base in auto:                         # 落定：标签带真名（L1 入库解析括号→真名实体）
                    ln.speaker = f"{ln.speaker}（{auto[base]['name']}）"
            tpath.write_text(render_transcript(
                lines, topic=topic, date=date, source_audio=audio_name,
                full_text=full_text, speaker_guesses=guesses,
                auto_confirmed={k: v["name"] for k, v in auto.items()}), encoding="utf-8")
        # 真链路下 transcript/clusters 已写完，跳过下面 dry-run 分支
        return _finish(meeting_id, tpath, audio_name, do_extract, dry_run)

    # dry-run 分支：transcript + clusters（无 wav，snippet_path=None）
    inbox = Path(config.MEETING_INBOX)
    inbox.mkdir(parents=True, exist_ok=True)
    tpath = inbox / f"{date}-{safe}.transcript.md"
    k = 1
    while tpath.exists():
        tpath = inbox / f"{date}-{safe}-{k}.transcript.md"
        k += 1
    meeting_id = tpath.name.replace(".transcript.md", "")
    tpath.write_text(render_transcript(
        lines, topic=topic, date=date, source_audio=audio_name,
        full_text=full_text, speaker_guesses=guesses), encoding="utf-8")
    _write_clusters_json(meeting_id, tpath, None, lines, guesses, embs)
    return _finish(meeting_id, tpath, audio_name, do_extract, dry_run)


def _finish(meeting_id: str, tpath: Path, audio_name: str, do_extract: bool, dry_run: bool) -> dict:
    out = {"meeting_id": meeting_id, "transcript_path": str(tpath),
           "clusters_path": str(sid.clusters_json_path(meeting_id)), "extract": None}
    if do_extract:
        out["extract"] = extract_meeting(str(tpath), source_audio=audio_name, dry_run=dry_run)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="python -m ingest.meeting.run",
        description="会议管线编排：音频 → 转写 →（可选分人/声纹）→ inbox transcript → 自动抽取写回 vault。",
        epilog="dry-run 不调任何外部 API、不读真音频；用占位转写走通写盘链路（无 key/无音频可测）。")
    ap.add_argument("audio", help="音频文件路径（dry-run 下只取文件名，不读内容）")
    ap.add_argument("--topic", default="会议", help="会议主题（进文件名/纪要标题）")
    ap.add_argument("--dry-run", action="store_true",
                    help="不调真 ASR/extract、不碰真音频，用占位数据走通管线")
    ap.add_argument("--no-extract", action="store_true", help="只转写落 inbox，不自动抽取写回 vault")
    ap.add_argument("--date", default=None, help="录音归属日 YYYY-MM-DD（补录历史录音必传，缺省今天）")
    args = ap.parse_args()

    if not args.dry_run and not Path(args.audio).exists():
        print(f"找不到音频: {args.audio}")
        return 2

    r = process(args.audio, topic=args.topic,
                do_extract=not args.no_extract, dry_run=args.dry_run, date=args.date)
    if r.get("skipped") == "no_speech":
        v = r.get("vad") or {}
        print(f"⏭  无有效人声，未送检（人声 {v.get('speech_sec')}s / 全长 {v.get('total_sec')}s）")
        return 0
    print(f"✓ 转写: {r['transcript_path']}")
    print(f"✓ 聚类(Track2): {r['clusters_path']}")
    ex = r.get("extract")
    if ex is None:
        print("· 跳过抽取（--no-extract）")
    elif ex.get("written"):
        print(f"✓ 纪要: {ex['note_path']}")
        if ex.get("todos_to_journal"):
            print(f"✓ {ex['todos_to_journal']} 条我的 todo → {ex['journal_path']}")
    else:
        print(f"· 抽取未写回：{ex.get('reason')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""声纹判决 daemon(M2-认8 ③):R2 队列的**唯一消费者**,产出判决 JSON 供手机合并。

    GROWTH_SV_PYTHON -u mac/voiceprint_daemon.py          # 常驻(launchd)
    GROWTH_SV_PYTHON -u mac/voiceprint_daemon.py --once   # 跑一轮就退(排查)

## 链路位置(方案 §三;队列形状照 M2-B8)

    手机:冻结后排队(行时间戳;音频键由 R2Layout 布局推出) → 睡
    本 daemon:拉音频 → 切段(VAD 人声门) → embed(与手机同一份 ONNX)
             → 判决(τ + 冒充集) → JSON 写回 → 手机取回,assignSpeaker 合并

## 铁律逐条

· 铁律 1/2:只读音频与底库**只读快照**,只产 JSON —— 一个字都不写进内容库与底库;
· 铁律 3:写归属的是手机的 `assignSpeaker`,这里只给建议;
· 铁律 4:判决逻辑唯一生效实现在 `voiceprint_judge.py`;模型空间串随 JSON 带回,
  手机对撞 `VoiceprintModel.current`,不一致整批拒收。

## 失败行为

判不了(没快照 / 音频缺块 / 模型对不上)⇒ **保留 job、写日志、下一轮再试** ——
不写产物:写了手机会当这一场认完了,而它一段都没判(§3.2 失败必须可见)。
心跳照 M2-审4 的约定:空转也打,声明「最多 N 秒不吭声」。
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from mac.redimnet_embed import RedimnetEmbedder                 # noqa: E402
from mac.silero_vad import MIN_SPEECH_RATIO, SileroVAD          # noqa: E402
# ⚠️ `cluster_lines` **不再从这里调**(`M2-认9`,2026-08-31):会话内聚类由上游
# (ASR 文件腿)的分人标签代替,没有标签的场次直接不判。函数本身留在判决核里
# —— `M2-认6` 接 Mac 本地 diarization 时它可能回来,而删了下一个人会重写一遍。
# 🔴 但要说清楚:**它现在生产上没有任何调用方**,`mac/test_voiceprint_judge.py`
# 里那条测试证明的是「它算得对」,不是「它在跑」。
from mac.voiceprint_judge import (SELF_ID, group_by_upstream,   # noqa: E402
                                  judge_self)

JOB_PREFIX = "voiceprint/jobs/"
OUT_PREFIX = "voiceprint/out/"
SNAP_PREFIX = "snapshots/voiceprints/"
#: 与 ios `R2Layout.audioPrefix` 一致(那边有测试钉字面量,这边靠契约测试)。
AUDIO_PREFIX = "inbox/audio/"

#: 底库/契约的向量空间串,= ios `VoiceprintModel.current`。
#: ⚠️ 铁律 4:本文件这几个常数的跨语言对撞在 **`mac/test_voiceprint_contract.py`**
#: (九个常数,已挂进 premerge);判决核那三个(τ/minSegments/minVoteRatio)
#: 在 `mac/test_voiceprint_judge.py`。
#: 🔴 2026-08-24 更正:原来这里指的是 judge 那道 —— 而那道**不比本文件的任何一个数**。
#: 指错闸比不指更糟:去核实的人会 grep 到一个存在的文件、看到它绿着,就以为查过了。
MODEL_SPACE = "redimnet-s/vb2+vox2+cnc/ft_mix"
SNAPSHOT_SCHEMA = "growth.voiceprints/3"

#: 每行取中段几秒(SpeakerSegments.targetSeconds;下限是前端物理下限 25ms)。
TARGET_SEC = 4.0
MIN_SEC = 400 / 16000

CLAIM_TTL_SEC = 20 * 60
POLL_SEC = 20
HEARTBEAT_SEC = 600
MAX_SILENCE_SEC = 2 * HEARTBEAT_SEC

COHORT_PATH = REPO / "mac" / "cohort_vectors.json"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _client():
    import boto3
    from botocore.config import Config
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
        config=Config(signature_version="s3v4", read_timeout=120,
                      retries={"max_attempts": 3}))


def load_wav_16k(data: bytes) -> np.ndarray:
    import librosa
    import soundfile as sf
    a, sr = sf.read(io.BytesIO(data), dtype="float32")
    if a.ndim > 1:
        a = a.mean(axis=1)
    return a if sr == 16000 else librosa.resample(a, orig_sr=sr, target_sr=16000)


def load_snapshot(s3, bucket: str) -> tuple[dict[int, np.ndarray], dict[int, str]]:
    """最新底库快照 → (person_id → 模板矩阵, person_id → 名字)。
    没有快照 ⇒ 抛(判不了;失败可见,不能拿空底库把整场判成全陌生)。"""
    listed = s3.list_objects_v2(Bucket=bucket, Prefix=SNAP_PREFIX, MaxKeys=1000)
    keys = sorted(o["Key"] for o in listed.get("Contents", []))
    if not keys:
        raise RuntimeError("R2 上没有底库快照 —— 手机还没备份过,判不了")
    snap = json.loads(s3.get_object(Bucket=bucket, Key=keys[-1])["Body"].read())
    if snap.get("schema") != SNAPSHOT_SCHEMA:
        raise RuntimeError(f"快照 schema {snap.get('schema')} ≠ {SNAPSHOT_SCHEMA} —— 拒读")
    reg: dict[int, list[np.ndarray]] = {}
    for e in snap["entries"]:
        if e["model"] != MODEL_SPACE:
            continue          # 旧空间向量不参与 —— 与手机 v7 之后同口径
        v = np.frombuffer(base64.b64decode(e["embedding"]), dtype="<f4")
        reg.setdefault(int(e["personID"]), []).append(v)
    names = {int(p["id"]): (p.get("name") or "") for p in snap.get("persons", [])}
    return {pid: np.stack(vs) for pid, vs in reg.items()}, names


def load_cohort(enrolled_names: set[str]) -> np.ndarray:
    """Generic implementation; local private materials are not distributed."""



    data = json.loads(COHORT_PATH.read_text())
    if data["_spec"]["model_id"] != "redimnet_s_body_op17":
        raise RuntimeError("冒充集不是当前模型产的 —— 用你自己的语料重建冒充集（见公开源码范围说明）")
    kept = [e["centroid"] for e in data["entries"] if e["label"] not in enrolled_names]
    dropped = len(data["entries"]) - len(kept)
    if dropped:
        print(f"▸ 冒充集剔除 {dropped} 个已登记同名质心(§2.5)")
    return np.array(kept) if kept else np.zeros((0, 192))


def run_job(s3, bucket: str, job: dict, emb: RedimnetEmbedder,
            vad: SileroVAD, log=print) -> dict:
    """一个 job → 判决 JSON(不落 R2,调用方落)。判不了就抛。"""
    if job.get("model") != MODEL_SPACE:
        raise RuntimeError(f"job 模型 {job.get('model')} ≠ 本侧 {MODEL_SPACE} —— "
                           f"两侧不在同一空间,判了也是错的")
    session = job["session"]
    registry, names = load_snapshot(s3, bucket)
    cohort = load_cohort({n for n in names.values() if n})
    # ~~匿名人格模板也从快照来、比较集排除本场自产的人格(`M2-认10` ①)~~
    # 2026-10-12 `M5-1` 起**只认我**(`judge_self`):比较集只有「我」的模板 + 冒充集,
    # 不再立匿名人格,也就没有「自己跟自己比」的问题。手机仍会传 `exclude_persons`,这里不再用。
    me = registry.get(SELF_ID)
    if me is None or not len(me):
        raise RuntimeError("快照没有本人模板 —— 先在手机上确认自己的声音并推送快照")

    blocks: dict[int, np.ndarray] = {}

    def block(seq: int) -> np.ndarray:
        if seq not in blocks:
            key = f"{AUDIO_PREFIX}{session}/block-{seq:04d}.{job.get('ext', 'wav')}"
            blocks[seq] = load_wav_16k(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
        return blocks[seq]

    kept_lines, embs, gated = [], [], 0
    for ln in job["lines"]:
        dur_ms = ln["end_ms"] - ln["start_ms"]
        if dur_ms < MIN_SEC * 1000:
            continue
        take = min(dur_ms, int(TARGET_SEC * 1000))
        start = ln["start_ms"] + (dur_ms - take) // 2      # 取中段:头尾常粘别人的音
        a = block(ln["block_seq"])
        s0, s1 = start * 16, (start + take) * 16
        if s1 > a.shape[0]:                                # 越界不夹取,跳过留痕
            log(f"🔴 行 {ln['line_id']} 超出块尾({s1} > {a.shape[0]}),跳过")
            continue
        seg = a[s0:s1]
        if vad.speech_ratio(seg) < MIN_SPEECH_RATIO:
            gated += 1
            continue
        kept_lines.append(ln)
        embs.append(emb.embed(seg))

    out = {"schema": 1, "model": MODEL_SPACE, "session": session, "identity_mode": "self_only",
           "at": _now(), "gated_out": gated, "clusters": []}
    if not embs:
        out["clusters"] = []
        return out

    E = np.stack(embs)
    # 🔴 **上游给了分人就用上游的,不自己重聚**(`M2-认9`,2026-08-31)。
    #
    # ~~自己切段(VAD + 换人点,不依赖 ASR 簇)~~ —— 方案 §三那句话**只实现了一半**:
    # 「自己聚类」做了,「自己切段」从来没做(上面这个循环切的就是 `job["lines"]`,
    # 也就是 ASR 的行;VAD 只当闸不参与切段)。于是只剩代价没有收益:
    # 分段粒度与 ASR 一模一样,却把 ASR 已经算好的分人扔掉重算。
    #
    # 实测代价(用户真机 5 场,ASR 自己判 3–5 类):重聚成 25 / 30 / 34 / 39 / 65 类。
    # （场次略） 那一场用户口述真值 **2 人**,ASR 判 3,这里判 39(27 个簇只有 1 段)。
    tags = [ln.get("cluster_tag") for ln in kept_lines]
    grouped = group_by_upstream(tags)
    if grouped is None:
        # 🔴 **一个分人标签都没有(真 SSE 形态)⇒ 不判**(`M2-认9` ②)。
        # 理由与「不回落 cluster_lines」是同一条,写在 `group_by_upstream` 的文档里。
        log(f"⚠️ 场次 {session}:{len(kept_lines)} 段一个分人标签都没有(SSE 形态)"
            f" —— 不判,见 M2-认6")
        out["skipped"] = "no_upstream_diarization"
        return out
    labels, suffix = grouped
    for k in sorted(set(labels)):
        idx = [i for i, l in enumerate(labels) if l == k]
        # 🔴 **只认我**(`M5-1` 件 7,用户 2026-10-12):这一簇是不是我。
        # ~~两段式开集认人 `judge_two_stage`~~ 退役:逐段只认出「我」68%,
        # 且匿名人格那条路会毒化底库。判法与阈值的实测依据在 `judge_self` 的文档里。
        v = judge_self(E[idx], me, cohort)
        out["clusters"].append({
            "cluster_key": f"{session}-{suffix[k]}",
            # ⚠️ 这个 JSON 是**逐字段拼**的,不是 `asdict(v)` ——
            # 所以给 `ClusterVerdict` 加字段**不会自动流到手机**,必须在这里也加一行。
            # 2026-08-25 加 `candidate_person_id` 时当场撞上:判决核里算好了、
            # 测试也绿了,而它到不了手机 —— 「写好了不等于在跑」(铁律 5)。
            "verdict": {"kind": v.kind,
                        **({"person_id": v.person_id} if v.person_id is not None else {}),
                        # 🔴 **中置信档**(PRD §4.4.10「预填候选,出确认卡」):
                        # 过了 τ、有得票最多的人,只是没到 2/3。候选带给手机,
                        # 否则三档只剩两档,而缺的恰好是中间那档。
                        **({"candidate_person_id": v.candidate_person_id}
                           if v.candidate_person_id is not None else {}),
                        # 票数**两档都要**:界面上「3 段里有 1 段像他」靠它。
                        # 原来只在 kind == "person" 时带,中置信那档就没有分母。
                        **({"votes": v.votes, "of": v.of} if v.of else {}),
                        **({"why": v.why} if v.why else {})},
            "centroid": v.centroid,
            "lines": [kept_lines[i]["line_id"] for i in idx],
            # 🔴 **二次确认候选**(`M2-认16`):簇里与判定人最不像的那几句。
            # `v.review` 给的是**簇内序号**,这里换成 `line_id` —— 手机不知道簇内序号。
            # ⚠️ 上面那段注释说的就是这种情况:加了 `ClusterVerdict.review` 不等于
            # 它会流到手机,必须在这里也拼一行。
            "review": [{"line_id": kept_lines[idx[i]]["line_id"], "score": sc}
                       for i, sc in v.review],
        })
    return out


def run_once(s3, bucket: str, emb, vad, log=print) -> dict:
    listed = s3.list_objects_v2(Bucket=bucket, Prefix=JOB_PREFIX, MaxKeys=100)
    objs = listed.get("Contents", [])
    ran = skipped = failed = 0
    for obj in objs:
        key = obj["Key"]
        try:
            job = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
        except Exception as e:                              # noqa: BLE001
            log(f"🔴 {key} 读不出来:{e}")
            failed += 1
            continue
        claimed = job.get("claimed_at")
        if claimed:
            try:
                age = time.time() - datetime.fromisoformat(claimed).timestamp()
            except Exception:                               # noqa: BLE001
                age = CLAIM_TTL_SEC + 1
            if age < CLAIM_TTL_SEC:
                skipped += 1
                continue
        job["claimed_at"] = _now()
        s3.put_object(Bucket=bucket, Key=key,
                      Body=json.dumps(job, ensure_ascii=False).encode(),
                      ContentType="application/json")
        t0 = time.time()
        try:
            result = run_job(s3, bucket, job, emb, vad, log=log)
            result_body = json.dumps(result, ensure_ascii=False, allow_nan=False).encode()
        except Exception as e:                              # noqa: BLE001
            job["last_error"] = str(e)[:500]
            job["attempts"] = job.get("attempts", 0) + 1
            s3.put_object(Bucket=bucket, Key=key,
                          Body=json.dumps(job, ensure_ascii=False).encode(),
                          ContentType="application/json")
            log(f"🔴 场次 {job.get('session')} 第 {job['attempts']} 次失败:{str(e)[:200]}")
            failed += 1
            continue
        s3.put_object(Bucket=bucket, Key=f"{OUT_PREFIX}{job['session']}.json",
                      Body=result_body,
                      ContentType="application/json")
        s3.delete_object(Bucket=bucket, Key=key)
        ran += 1
        kinds = [c["verdict"]["kind"] for c in result["clusters"]]
        asks = sum(1 for c in result["clusters"] if c["verdict"].get("candidate_person_id") is not None)
        log(f"✅ 场次 {job['session']} 判完,用时 {time.time() - t0:.0f} 秒:"
            f"{len(kinds)} 簇(认出我 {kinds.count('person')} · 拿不准要问 {asks})"
            f"· 门挡 {result['gated_out']} 段")
    return {"ran": ran, "skipped": skipped, "failed": failed, "pending": len(objs)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--bucket", default=os.environ.get("R2_BUCKET", "growth-audio"))
    a = ap.parse_args()

    s3 = _client()
    emb, vad = RedimnetEmbedder(), SileroVAD()
    print(f"▸ 声纹 daemon 起来了 · bucket={a.bucket} · 空间={MODEL_SPACE} · "
          f"轮询 {POLL_SEC}s", flush=True)
    last_beat = 0.0
    while True:
        try:
            r = run_once(s3, a.bucket, emb, vad)
            if r["pending"]:
                print(f"[{datetime.now():%H:%M:%S}] 待办 {r['pending']} · 跑 {r['ran']} · "
                      f"跳过 {r['skipped']} · 失败 {r['failed']}", flush=True)
                last_beat = time.time()
            elif time.time() - last_beat >= HEARTBEAT_SEC:
                print(f"[{datetime.now():%H:%M:%S}] 心跳 · 队列空 · "
                      f"最多 {MAX_SILENCE_SEC} 秒不吭声", flush=True)
                last_beat = time.time()
        except Exception as e:                              # noqa: BLE001
            print(f"🔴 这一轮整个挂了(下一轮照跑):{e}", flush=True)
            last_beat = time.time()
        if a.once:
            return 0
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    raise SystemExit(main())

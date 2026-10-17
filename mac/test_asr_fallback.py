#!/usr/bin/env python3
"""SSE 兜底自测(M1-34)。**不联网、不花钱**,转写函数是注入的假货。

    python3 mac/test_asr_fallback.py
"""
from __future__ import annotations

import json
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mac import asr_fallback as F                                  # noqa: E402

REPO = Path(__file__).resolve().parents[1]

# 🔴 **自测绝不许碰真账本。** `F.scan` 会走到 `_switch_one` 里的 `log_asr`，
# 而它默认往 `data/usage.jsonl` 追加 —— 2026-08-19 实测：跑一次自测就凭空多出
# 几笔**从没发生过**的 ASR 开销（`audio_sec=300`、`src=a.wav`，正是 `pending()` 的假数据）。
# 假账不会有任何东西报错，只会让下次算「转写一天花多少」的人拿着一个偏大的数做决定。
import shared.model_router as _MR                                   # noqa: E402
_ASR_LOG: list = []
_MR.log_asr = lambda sec, **kw: _ASR_LOG.append((sec, kw))


@dataclass
class FakeSeg:
    text: str
    start_ms: int | None = 0
    end_ms: int | None = 100


@dataclass
class FakeResult:
    full_text: str = ""
    segments: list = None
    def __post_init__(self):
        if self.segments is None:
            self.segments = []


class FakeStorage:
    def __init__(self, objs):
        self.objs = dict(objs); self.puts = []
    def list(self, prefix): return [k for k in self.objs if k.startswith(prefix)]
    def get(self, key): return self.objs[key]
    def put(self, key, data): self.objs[key] = data; self.puts.append(key)


def pending(task_id="T1", key="inbox/audio/1/block-0000.wav", age_sec=999, **extra):
    at = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - age_sec))
    return {"task_id": task_id, "key": key, "seconds": 300, "submitted_at": at, **extra}


def store(*records, audio=b"RIFFfake"):
    objs = {}
    for r in records:
        objs[f"{F.PENDING_PREFIX}{r['task_id']}.json"] = json.dumps(r).encode()
        objs[r["key"]] = audio
    return FakeStorage(objs)


T = {}
def test(name):
    def deco(fn): T[name] = fn; return fn
    return deco


@test("转形出来的报文,顶层 result 必须非空 —— 否则手机永远轮询下去")
def _():
    p = F.as_file_endpoint_shape(FakeResult("你好", [FakeSeg("你好")]), 12.0)
    assert isinstance(p.get("result"), list) and p["result"], p
    assert p["result"][0].get("utterances"), p


@test("两个消费方的判据是从源码里读的,不手抄")
def _():
    swift = (REPO / "ios/GrowthApp/Upload/ProxyClient.swift").read_text(encoding="utf-8")
    assert 'd["result"]' in swift, "ProxyClient.classify 不再看顶层 result 了 —— 对撞的一端变了"
    parser = (REPO / "ios/GrowthApp/Upload/ASRResponseParser.swift").read_text(encoding="utf-8")
    m = re.search(r'utteranceKeys = \[(.*?)\]', parser, re.S)
    assert m and "utterances" in m.group(1), "解析器认的键变了,转形要跟着改"


@test("一句都没切出来但有全文时,整段当一句 —— 不丢内容")
def _():
    p = F.as_file_endpoint_shape(FakeResult("整段话", []), 3.0)
    assert p["result"][0]["utterances"][0]["text"] == "整段话"


@test("降级标记必须在报文里 —— 没有它,「上游没给分人」与「只有一个人说话」一样")
def _():
    p = F.as_file_endpoint_shape(FakeResult("x", [FakeSeg("x")]), 1.0)
    assert p.get("growth_no_speaker") is True, p


@test("换路先认领:待办里落 switched_to_sse,而且不删待办")
def _():
    s = store(pending())
    F.scan(s, transcribe=lambda p, k: FakeResult("好", [FakeSeg("好")]), api_key="k")
    rec = json.loads(s.objs[f"{F.PENDING_PREFIX}T1.json"])
    assert rec.get("switched_to_sse"), "没认领 —— 下一拍会对同一块再发一次(重复付费)"
    assert f"{F.PENDING_PREFIX}T1.json" in s.objs, "待办被删了 —— 防重复付费的闸就此失效"


@test("认领过的不再换第二次")
def _():
    s = store(pending(switched_to_sse="2026-08-19T10:00:00+00:00"))
    calls = []
    out = F.scan(s, transcribe=lambda p, k: calls.append(1) or FakeResult("x"), api_key="k")
    assert out.switched == 0 and not calls, "已换路的又换了一次"


@test("一次最多换一块 —— cron 一分钟一次而一块 SSE 实测 49 秒")
def _():
    s = store(pending("T1", "inbox/audio/1/a.wav"), pending("T2", "inbox/audio/1/b.wav"))
    out = F.scan(s, transcribe=lambda p, k: FakeResult("x", [FakeSeg("x")]), api_key="k")
    assert out.switched == F.MAX_PER_RUN == 1, out


@test("超过重试上限就不再买单")
def _():
    s = store(pending(sse_attempts=F.MAX_SSE_ATTEMPTS))
    calls = []
    F.scan(s, transcribe=lambda p, k: calls.append(1) or FakeResult("x"), api_key="k")
    assert not calls, "已达上限还在调用 —— 一块能打 360 次 ≈¥5,而红线是 ¥1.5/天"


@test("没到时限的不动 —— 换路是兜底,不是主路径")
def _():
    s = store(pending(age_sec=10))
    out = F.scan(s, transcribe=lambda p, k: FakeResult("x"), api_key="k")
    assert out.switched == 0 and out.stuck == 0, out


@test("worker 的收割器认得 switched_to_sse —— 不认就会把 SSE 的成果盖掉")
def _():
    js = (REPO / "worker/src/collector.js").read_text(encoding="utf-8")
    assert "switched_to_sse" in js, (
        "collector.js 不看这个标记 —— finish 是无条件 put,"
        "文件端点的迟到结果会盖掉 SSE 出的稿;6 小时兜底还会把它写成失败")



@test("桶名对撞从 worker 源码读 —— 手抄一份就成了第三份真相源")
def _():
    want = F.worker_bucket_name()
    if not want:
        # 公开快照不发布 worker/wrangler.toml（运营部署配置）。缺文件时这条对撞
        # 无法成立；按跳过处理并说明原因，不伪装成通过。
        print("SKIP 桶名对撞：本树不含 worker/wrangler.toml，无法从源头读桶名")
        return
    toml = (REPO / "worker" / "wrangler.toml").read_text()
    assert f'bucket_name = "{want}"' in toml, "读出来的桶名不在源文件里"


@test("桶名写错必须硬失败 —— 「扫 0 条」和「没有卡住的活」在输出上一模一样")
def _():
    # 公开快照不发布 worker/wrangler.toml；这道硬失败闸本身以「从源头读到正确桶名」
    # 为前提，缺文件时无法成立 —— 明确跳过并说明，不改成永远通过。
    if not F.worker_bucket_name():
        print("SKIP 桶名写错硬失败：本树不含 worker/wrangler.toml，无法构造对撞输入")
        return
    # 照妖镜。这条不是假想:2026-08-19 实测 `secrets.env` 的 R2_BUCKET=growth-agent,
    # 而 worker 写 growth-audio,列后者直接 AccessDenied —— 而当时代码会一声不吭扫 0 条。
    import subprocess, os
    env = dict(os.environ)
    env.update({"STEPFUN_API_KEY": "x",
                "R2_BUCKET": F.worker_bucket_name() + "-wrong-on-purpose",
                "R2_ACCOUNT_ID": "x", "R2_ACCESS_KEY_ID": "x",
                "R2_SECRET_ACCESS_KEY": "x"})
    r = subprocess.run(["python3", "-m", "mac.asr_fallback", "--dry-run"],
                       cwd=REPO, env=env, capture_output=True, text=True)
    assert r.returncode == 2, f"桶名写错却没硬失败(rc={r.returncode}):{r.stdout}{r.stderr}"
    assert "桶名对不上" in r.stderr, f"失败了但没说清为什么:{r.stderr}"


@test("换一次路就得落一条账 —— 这条腿不经过 worker,worker 的账本看不到它")
def _():
    # 照妖镜:把 log_asr 换成计数器,不落账就红。
    # 为什么值得单独一条 —— 文件端点的账是 worker 往 `usage/` 前缀写的,
    # 而这条腿由 Mac 直发 SSE,**worker 全程不知情**。漏了不会有任何东西报错,
    # 只会让「转写一天花多少」这个数悄悄偏小。
    _ASR_LOG.clear()
    s = store(pending())              # pending() 的 seconds=300
    F.scan(s, transcribe=lambda p, k: FakeResult("好", [FakeSeg("好")]), api_key="k")
    calls = _ASR_LOG
    assert calls, "转写付了钱却一条账没落 —— 没入账的开销等于不存在"
    assert calls[0][0] == 300, f"记的时长不对(应是待办里的 seconds):{calls[0]}"
    assert calls[0][1].get("scene") == "asr_sse_fallback", (
        f"场景名没区分开,和主路径的账混在一起就分不出兜底腿花了多少:{calls[0]}")


@test("字级 delta 必须合成句子 —— 每行一个字,读起来照样通顺,坏的是结构")
def _():
    # 照妖镜。2026-08-19 实测:331 秒音频回 246 个单字 delta,1:1 映射后手机拿到
    # 243 行、每行一个字。**把 text 拼起来是通顺的中文**,句数/字数/时长/verdict
    # 全部健康 —— 没有任何计数能照出这个坏法,所以只能在这儿钉死。
    segs = [FakeSeg(c, 100, 200) for c in "我看到了。"] + [FakeSeg(c, 300, 400) for c in "好的，走吧！"]
    p = F.as_file_endpoint_shape(FakeResult("", segs), 10.0)
    utt = p["result"][0]["utterances"]
    assert len(utt) == 2, f"应合成 2 句,实得 {len(utt)} 条:{[u['text'] for u in utt][:6]}"
    assert utt[0]["text"] == "我看到了。", utt[0]
    assert utt[1]["text"] == "好的，走吧！", utt[1]
    assert "".join(u["text"] for u in utt) == "我看到了。好的，走吧！", "合并把字弄丢了"


@test("时间戳取本句首尾,不按时长插值 —— 假时间戳比没有更难发现")
def _():
    segs = [FakeSeg("你", 1000, 1100), FakeSeg("好", 1200, 1300), FakeSeg("。", 1400, 1500)]
    u = F.as_file_endpoint_shape(FakeResult("", segs), 9.0)["result"][0]["utterances"][0]
    assert (u["start_time"], u["end_time"]) == (1000, 1500), u


@test("末尾没有标点的残句不丢 —— 上游经常不给最后一个句号")
def _():
    segs = [FakeSeg(c, 0, 0) for c in "还没说完"]
    utt = F.as_file_endpoint_shape(FakeResult("", segs), 3.0)["result"][0]["utterances"]
    assert len(utt) == 1 and utt[0]["text"] == "还没说完", utt


@test("换路彻底失败必须写终态 —— 不写就永久悬空,而三处都看不出异常")
def _():
    # 照妖镜。2026-08-19 实测:19 块里 2 块(5/6 秒,上游返空转写)正是这样悬着的。
    # 收割器见 switched_to_sse 就跳过(对的,不跳会盖掉 SSE 的稿),
    # 但也一并带走了它那条 6 小时兜底判失败的路;而 Mac 这边次数已用尽。
    # ⇒ 既没人再转、也没人再判,手机永远轮询下去。
    s = store(pending())
    def boom(p, k): raise RuntimeError("所有端点失败/空")
    out = F.scan(s, transcribe=boom, api_key="k")
    assert out.failed == 1, out
    rk = f"{F.RESULT_PREFIX}T1.json"
    assert rk in s.objs, "失败了却没写结果 —— 手机拿不到答案,会一直轮询"
    r = json.loads(s.objs[rk])
    assert r["verdict"] == "failed", r
    assert "所有端点失败" in r["body"], f"失败原因没带出去,排查时无据可依:{r['body']}"
    assert f"{F.PENDING_PREFIX}T1.json" in s.objs, "待办被删了 —— 捅穿防重复付费的闸"


@test("没到次数上限就不写终态 —— 还有下一次,写了会让手机提前放弃")
def _():
    saved = F.MAX_SSE_ATTEMPTS
    F.MAX_SSE_ATTEMPTS = 2                       # 造一个「还剩一次」的世界
    try:
        s = store(pending())
        def boom(p, k): raise RuntimeError("这次不行")
        F.scan(s, transcribe=boom, api_key="k")
        assert f"{F.RESULT_PREFIX}T1.json" not in s.objs, "还有重试机会却已经判了死"
    finally:
        F.MAX_SSE_ATTEMPTS = saved


# ---------------------------------------------------------------- 分人(M2-认6)

@test("有分人结果时每条 utterance 都要带 speaker,形状与文件端点逐字一致")
def _t_speaker_present():
    """🔴 有分人结果时,每条 utterance 都要带 `speaker`,且降级标记要关掉。

    形状必须与**文件端点**逐字一致:`"speaker": {"id": "speaker_0"}`
    (2026-08-17 真机抓的形状,`ASRResponseParser.speaker(of:)` 第一个分支就是它)。
    形状不一致 = 两条腿两份契约,而手机侧只认一份。"""
    # 句子按标点切,所以每句自带一个句号(见「字级 delta 必须合成句子」那条)
    segs = [FakeSeg("甲说的", 0, 1800), FakeSeg("。", 1900, 2000),
            FakeSeg("乙说的", 5000, 6800), FakeSeg("。", 6900, 7000)]
    turns = [(0, 3000, "speaker_0"), (4500, 8000, "speaker_1")]
    p = F.as_file_endpoint_shape(FakeResult("", segs), 10.0, turns=turns)
    utts = p["result"][0]["utterances"]
    assert [u["speaker"] for u in utts] == [{"id": "speaker_0"}, {"id": "speaker_1"}], utts
    assert p.get("growth_no_speaker") is False, p


@test("分人没做成 ⇒ 照旧发稿,降级标记留着")
def _t_no_turns():
    """🔴 分人没做成 ⇒ **照旧发稿**,`growth_no_speaker` 留 True、不带 speaker 字段。

    红了说明为了分人把一块**已经花过钱**的转写弄丢了 —— 那比没有分人更贵。"""
    segs = [FakeSeg("一句话", 0, 1900), FakeSeg("。", 1950, 2000)]
    p = F.as_file_endpoint_shape(FakeResult("", segs), 3.0, turns=None)
    assert p["growth_no_speaker"] is True, p
    assert "speaker" not in p["result"][0]["utterances"][0], p


@test("落在所有 turn 之外的句子不给标签,不硬塞最近的")
def _t_outside():
    """落在所有 turn 之外的句子**不给标签**,而不是硬塞一个最近的。

    「不知道这句是谁说的」与「是某个人」是两件事(同 `SpeakerNaming.keyExpr` 那条)。"""
    segs = [FakeSeg("在里面", 0, 1800), FakeSeg("。", 1900, 2000),
            FakeSeg("在外面", 60_000, 61_800), FakeSeg("。", 61_900, 62_000)]
    p = F.as_file_endpoint_shape(FakeResult("", segs), 70.0,
                                 turns=[(0, 3000, "speaker_0")])
    utts = p["result"][0]["utterances"]
    assert utts[0]["speaker"] == {"id": "speaker_0"}, utts
    assert "speaker" not in utts[1], utts


def main() -> int:
    failed = 0
    for name, fn in T.items():
        try:
            fn(); print(f"PASS {name}")
        except AssertionError as e:
            failed += 1; print(f"FAIL {name}\n     {e}", file=sys.stderr)
    print(f"\n{failed} failed" if failed else f"\nall passed ({len(T)})")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

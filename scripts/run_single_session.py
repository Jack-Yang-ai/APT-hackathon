#!/usr/bin/env python3
"""单场链路编排器(M0-12a):一条命令从一个录音文件跑到落库。

把 §1.2 的数据流串起来:
  录音文件 → 分块 → VAD(`mac.vad_gate`)→ 放置到中转 → 转写(云代理)
  → **冻结(Swift)** → 播报闸(`mac.broadcast_gate`)→ 抽取(云代理)
  → 三项校验(`worker.extract.validate`)→ **落库(Swift)**

**跨运行时怎么接的**(判 8):地基是 Swift 真身,编排是 Python,两边靠同一个
SQLite 文件对接。冻结与落库这两步走 `OrchestrationPortTests` 那两个口 ——
入参 JSON 进、DB 与结果 JSON 出。不在 Python 里重抄一遍 DDL:那就是两份 schema,
迟早分叉,而分叉的时候断言脚本还会报绿。

**这个编排器不修数据。** 每一环拿上一环的产出原样往下传,校验失败就让它失败。
中间做一次「顺手修一下」,上游的缺陷就再也查不出来了 —— 而本仓最贵的一次事故
正是「成功地写进了错的地方」。

云代理是**假上游**(`scripts/fake_upstream.py`):这一跑验的是链路串得对不对,
不是模型好不好。真上游那一跑属 M0-12。

跑:python3 scripts/run_single_session.py --audio 某个音频文件
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from mac import vad_gate                      # noqa: E402
from mac.broadcast_gate import classify       # noqa: E402
from scripts import fake_upstream, real_upstream   # noqa: E402
from worker.extract import validate           # noqa: E402

WORK = ROOT / ".orchestration"
STAGING = WORK / "staging"                    # R2 inbox 的本地替身(真上传是 M0-7)
DB = WORK / "session.sqlite"
BLOCK_SEC = 300                               # 5 分钟一块(§六 录音格式)

CHECKS = ["check_frozen", "check_refs", "check_source",
          "check_attribution", "check_judgments"]


class Step:
    """一环。耗时与产出条数都要打出来 —— 看不见的环出了问题没人会发现。"""

    def __init__(self, no: int, name: str):
        self.no, self.name = no, name

    def __enter__(self):
        self.t0 = time.monotonic()
        print(f"\n[{self.no}] {self.name} …", flush=True)
        return self

    def done(self, detail: str):
        self.detail = detail

    def __exit__(self, *exc):
        dt = time.monotonic() - self.t0
        if exc[0] is None:
            print(f"    ✓ {getattr(self, 'detail', '')}  ({dt:.1f}s)", flush=True)
        else:
            print(f"    ✗ 这一环失败,链路到此为止  ({dt:.1f}s)", flush=True)
        return False


# ------------------------------------------------------------------ Swift 口

def _simulator_udid() -> str:
    raw = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                         capture_output=True, text=True, check=True).stdout
    devices = json.loads(raw)["devices"]
    for runtime in sorted(devices, reverse=True):
        for d in devices[runtime]:
            if "iPhone" in d["name"]:
                return d["udid"]
    raise SystemExit("找不到可用的 iPhone 模拟器")


#: 模拟器自己的暂态,不是被测代码的问题:两次 `xcodebuild test` 挨太近时,
#: 上一个 app 实例还没退干净,新的一次会被 SpringBoard 以 Busy 拒掉。
#: **只对这个签名重试**——把所有失败都重试一遍等于把真缺陷也磨平了。
_SIMULATOR_FLAKE = ("Application failed preflight checks",
                    "Simulator device failed to launch")


def swift_port(test: str, out_name: str, udid: str, attempts: int = 3) -> dict:
    """跑一个 Swift 口。失败时把 xcodebuild 的错原样带出来,不吞。"""
    out = WORK / out_name
    out.unlink(missing_ok=True)          # 先删:否则上一跑的产出会被当成这一跑的
    for attempt in range(1, attempts + 1):
        r = subprocess.run(
            ["xcodebuild", "test", "-scheme", "GrowthApp", "-destination", f"id={udid}",
             f"-only-testing:GrowthAppTests/OrchestrationPortTests/{test}"],
            cwd=ROOT / "ios", capture_output=True, text=True)
        if r.returncode == 0:
            break
        blob = (r.stdout or "") + (r.stderr or "")
        if attempt < attempts and any(sig in blob for sig in _SIMULATOR_FLAKE):
            # 重试要**打出来**。悄悄重试的话,「模拟器经常抽风」这件事永远不会
            # 变成一条能被看见的事实,将来它变成常态也没人知道。
            print(f"    ↻ 模拟器 Busy,第 {attempt} 次重试", flush=True)
            time.sleep(5)
            continue
        break
    if r.returncode != 0:
        # 全量日志落盘再看。xcodebuild 失败时尾巴上常常是构建图与缓存路径,
        # 真正的错误行埋在中间 —— 只截尾巴等于没留证据。
        log = WORK / f"{test}.log"
        log.write_text((r.stdout or "") + "\n--- stderr ---\n" + (r.stderr or ""),
                       encoding="utf-8")
        hits = [ln for ln in (r.stdout or "").splitlines()
                if any(k in ln for k in ("error:", "failed:", "Fatal", "Assertion",
                                         "Failing tests", "** TEST"))]
        detail = "\n".join(hits[-12:]) or "(日志里没有可识别的错误行)"
        raise SystemExit(f"Swift 口 {test} 失败(exit {r.returncode}):\n{detail}\n"
                         f"完整日志:{log}")
    if not out.exists():
        raise SystemExit(f"{test} 退出码是 0 但没产出 {out_name} —— "
                         f"多半是被 XCTSkip 跳过了。**跳过不是成功**,"
                         f"这里不放行,否则下游会拿着上一跑的旧产出继续跑")
    return json.loads(out.read_text(encoding="utf-8"))


# ------------------------------------------------------------------ 各环

def split_blocks(audio: Path) -> list[Path]:
    """按 5 分钟切块。真实链路里这是录音内核边录边落的(M0-1e),
    这里从一个完整文件倒推出同样的块序,好让下游拿到一样的形状。"""
    STAGING.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(audio), "-f", "segment",
         "-segment_time", str(BLOCK_SEC), "-c", "copy",
         str(STAGING / f"block-%04d{audio.suffix}")],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"ffmpeg 切块失败:{r.stderr[:300]}")
    return sorted(STAGING.glob(f"block-*{audio.suffix}"))


def kept_intervals_for_block(regions_sec: list[list[float]], seq: int) -> list[dict]:
    """把场次级的人声区间切进某一块,换算成**块内**毫秒。

    VAD 是场次级跑的(§1.2 ③ 在 ② 之后),而保留区间表是按块随块上传的
    (§3.1.6 时间轴对账契约)—— 中间这一次换算就是两者的接缝。
    """
    lo, hi = seq * BLOCK_SEC, (seq + 1) * BLOCK_SEC
    out = []
    for a, b in regions_sec:
        s, e = max(a, lo), min(b, hi)
        if e > s:
            out.append({"startMs": int((s - lo) * 1000), "endMs": int((e - lo) * 1000)})
    return out


def _serve(directory: Path, port: int):
    """起一个只读的本地文件服务,让 Worker 凭 URL 取音频。

    生产里这是 R2 的签名链接(签发在云代理,M0-7 的禁区)。这里用本地服务替身,
    走的仍是「Worker 凭 URL 自己取」那条真路径 —— 换成把音频塞进请求体就是另一条路了。
    """
    import functools
    import http.server
    import threading
    handler = functools.partial(http.server.SimpleHTTPRequestHandler,
                                directory=str(directory))
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


#: 一行到此为止的标点。ASR 开了 enable_timestamp 给的是**字级**段,
#: 而冻结层的一行是「一句话」——不合并的话一场会出几万行,line_id 全挂在单个字上。
_SENTENCE_END = "。!?;!?;…"


def _to_lines(segments: list[dict]) -> list[dict]:
    """字级段 → 句级行。时间戳取这一句首字的起点与末字的终点。

    **不做任何文本修补**(§4.2 的纪律):标点、错别字原样留着。
    抽取那一环的三项校验要拿 quote 与原文逐字比,这里改一个字,那边就全对不上。
    """
    lines, buf = [], []
    for seg in segments:
        if seg.get("start_ms") is None:
            continue                       # 没时间戳的段(聚合行)不参与切句
        buf.append(seg)
        if seg["text"] and seg["text"][-1] in _SENTENCE_END:
            lines.append(_flush(buf)); buf = []
    if buf:
        lines.append(_flush(buf))
    return lines


def _flush(buf: list[dict]) -> dict:
    # 簇标签取**这一句里出现最多的那个**(M0-20)。真 ASR 的字级段各带 speaker,
    # 一句话跨两个说话人是存在的 —— 那种行本来就该被混合行检测挑出来,
    # 而这里给它一个「主要是谁」的标签,不编一个新的。
    tags = [s["speaker"] for s in buf if s.get("speaker")]
    return {"startMs": buf[0]["start_ms"], "endMs": buf[-1]["end_ms"],
            "text": "".join(s["text"] for s in buf),
            "speaker": max(set(tags), key=tags.count) if tags else None}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--audio", required=True, type=Path)
    ap.add_argument("--keep", action="store_true", help="保留中间产物,便于排查")
    ap.add_argument("--real", action="store_true",
                    help="打真云代理(真 StepFun + 真 DeepSeek)。要先起 wrangler dev。**花钱**")
    ap.add_argument("--proxy", default="http://127.0.0.1:8787")
    ap.add_argument("--serve-port", type=int, default=8899,
                    help="--real 时本地起的文件服务端口(Worker 凭 URL 取音频)")
    args = ap.parse_args()

    if not args.audio.exists():
        raise SystemExit(f"音频不在:{args.audio}")
    if WORK.exists() and not args.keep:
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True, exist_ok=True)

    now = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    udid = _simulator_udid()
    print(f"音频:{args.audio}\n模拟器:{udid}\n工作目录:{WORK}")

    # ② 粗切场次:一个文件 = 一个场次(§4.1.5 导入的文件跳过粗切,整体作为一个场次)
    with Step(2, "粗切场次") as s:
        s.done("1 个场次(单文件输入,跳过长静音粗切)")

    # ① 分块
    with Step(1, "分块(5 分钟)") as s:
        blocks = split_blocks(args.audio)
        s.done(f"{len(blocks)} 块 → {STAGING}")

    # ③ 人声检测
    with Step(3, "VAD 人声检测(mac.vad_gate)") as s:
        vad = vad_gate.check(str(args.audio))
        s.done(f"人声 {vad['speech_sec']}s / 共 {vad['total_sec']}s "
               f"(留存 {vad['speech_ratio']:.0%},{len(vad['speech_regions'])} 个区间)")
    if not vad["has_speech"]:
        print(f"\n人声不足 {vad['min_speech_sec']}s —— 整条不送检(这是闸门的正常行为)")
        return 0

    # ④ 放置到中转(R2 inbox 的本地替身;真上传是 M0-7)
    with Step(4, "放置到中转" + ("(含物理裁剪)" if args.real else "")) as s:
        manifest = [{"blockSeq": i, "file": b.name,
                     "keptIntervals": kept_intervals_for_block(vad["speech_regions"], i)}
                    for i, b in enumerate(blocks)]
        if args.real:
            # ⚠️ 真 ASR 返回的时间戳是**它收到的那段音频**的时间轴。传了保留区间表
            # 却送整块音频,冻结那步会把「裁剪后毫秒」当真的去还原,整条时间轴系统性
            # 错位 —— 而错位之后每行仍有一个看起来合理的时间戳,没有任何东西会报错。
            for m, b in zip(manifest, blocks):
                if not m["keptIntervals"]:
                    m["trimmed"] = None
                    continue
                dst = STAGING / f"trimmed-{b.stem}.mp3"
                m["trimmed"] = dst.name
                m["trimmedSec"] = real_upstream.trim(b, m["keptIntervals"], dst)
        (STAGING / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
        kept_ms = sum(k["endMs"] - k["startMs"] for m in manifest for k in m["keptIntervals"])
        if args.real:
            s.done(f"{len(manifest)} 块 · 保留区间 {kept_ms/1000:.0f}s · "
                   f"裁剪后送检 {sum(m.get('trimmedSec', 0) for m in manifest):.0f}s")
        else:
            s.done(f"{len(manifest)} 块 + 保留区间表(共 {kept_ms/1000:.0f}s)"
                   f"  ⚠️ 未做物理裁剪:上游是假的,裁剪省下的是钱不是正确性")

    # ⑤ 转写
    with Step(5, "转写(真 StepFun)" if args.real else "转写(假云代理)") as s:
        if args.real:
            httpd = _serve(STAGING, args.serve_port)
            try:
                for m in manifest:
                    if not m.get("trimmed"):
                        m["lines"] = []
                        continue
                    url = f"http://127.0.0.1:{args.serve_port}/{m['trimmed']}"
                    got = real_upstream.transcribe(args.proxy, url, m["trimmedSec"])
                    # ASR 给的是**字级**段。冻结要的是行,按标点合并成句。
                    m["lines"] = _to_lines(got["segments"])
                    m["chars"] = len(got["text"])
            finally:
                httpd.shutdown()
        else:
            for m in manifest:
                total = sum(k["endMs"] - k["startMs"] for k in m["keptIntervals"])
                m["lines"] = fake_upstream.transcribe(m["blockSeq"], total)
        s.done(f"{sum(len(m['lines']) for m in manifest)} 行"
               + (f" · 共 {sum(m.get('chars', 0) for m in manifest)} 字" if args.real else ""))

    # ⑦ 冻结(Swift)
    with Step(7, "冻结落库(Swift 口)") as s:
        (WORK / "freeze_in.json").write_text(json.dumps({
            "session": {"startedAt": now, "day": now[:10], "source": "recording"},
            "asrModel": "fake-asr", "now": now,
            "blocks": [{"blockSeq": m["blockSeq"], "offsetMs": m["blockSeq"] * BLOCK_SEC * 1000,
                        "keptIntervals": m["keptIntervals"], "lines": m["lines"]}
                       for m in manifest],
            "missing": [],
        }, ensure_ascii=False), encoding="utf-8")
        frozen = swift_port("testFreezePort", "freeze_out.json", udid)
        s.done(f"transcript {frozen['transcriptID']} · {frozen['status']} · "
               f"{frozen['lineCount']} 行(占位 {frozen['gapCount']})")

    lines = frozen["lines"]

    # ⑧ 播报闸
    with Step(8, "播报闸(mac.broadcast_gate,纯词法)") as s:
        # use_llm=False:这一跑不花钱。LLM 兜底那一档属 M0-12 的真上游跑。
        gate = classify([{"text": l["text"], "spk": ""} for l in lines], use_llm=False)
        # 🔴 ~~「⚠️ 无下游:标记要交给归属入口(§1.2 ⑨),本链路没有分人步骤」~~
        # **2026-08-18 作废(M0-20 终态③)**:⑦ 冻结那一环现在把 ASR 自带的
        # 簇标签一路写进 `line_speakers`(走 `assignSpeaker` 唯一入口),
        # 所以 §1.2 ⑨ 在这条链路上是有的。
        # 播报闸的标记**仍然没有下游** —— 那是另一件事,别把两句话混成一句。
        s.done(f"词法命中 {gate['lexical_hits']} 行,判为播报 {len(gate['broadcast_lines'])} 行"
               f"  ⚠️ 播报标记本身仍无下游(§4.1.6 分级还没落库)")

    # ⑪ 抽取(假上游)
    with Step(11, "抽取(真 DeepSeek)" if args.real else "抽取(假云代理)") as s:
        if args.real:
            payload, acct = real_upstream.extract(args.proxy, lines)
            note = f" · 记账 {(acct or {}).get('record',{}).get('cost_usd')} USD"
        else:
            payload = fake_upstream.extract(lines)
            note = (f"(其中 {fake_upstream.DELIBERATE_BAD_ITEMS}+ 个是"
                    f"假上游刻意掺的坏条目,下一环该把它们丢掉)")
        raw_items = sum(len(payload[k]) for k in
                        ("key_points", "commitments", "stances", "pendings"))
        s.done(f"{raw_items} 个条目{note}")

    # ⑫ 三项校验
    with Step(12, "三项校验(worker.extract.validate)") as s:
        clean, stats = validate(payload, lines)
        s.done(f"通过 {stats.passed} · 挂起 {stats.pending} · 丢弃 {stats.discarded}  "
               f"丢弃原因 {dict(stats.discard_reasons)}")
        if not args.real and stats.discarded < fake_upstream.DELIBERATE_BAD_ITEMS:
            raise SystemExit(
                f"假上游掺了 {fake_upstream.DELIBERATE_BAD_ITEMS} 个坏条目,"
                f"只被丢掉 {stats.discarded} 个 —— 三项校验里有一项没生效。"
                f"这一环报绿而实际没拦住,正是最贵的那种失败")

    # ⑫ 落库(Swift)
    with Step(12, "落库(Swift 口)") as s:
        (WORK / "store_in.json").write_text(json.dumps({
            "transcriptID": frozen["transcriptID"], "payload": clean, "now": now,
        }, ensure_ascii=False), encoding="utf-8")
        stored = swift_port("testStorePort", "store_out.json", udid)
        s.done(f"落库 {stored['stored']} 条 · 表计数 {stored['counts']}")

    # 验收:落对没落对(§3.3)
    print("\n[验收] 五个结构断言脚本对产出的库:")
    failed = []
    for name in CHECKS:
        r = subprocess.run([sys.executable, f"{name}.py", str(DB)],
                           cwd=ROOT / "eval" / "checks", capture_output=True, text=True)
        print("   ", (r.stdout or r.stderr).strip().splitlines()[-1] if (r.stdout or r.stderr)
              else name)
        if r.returncode != 0:
            failed.append(name)

    print()
    if failed:
        print(f"✗ 断言未全绿:{failed}")
        return 1
    print(f"✓ 全链跑通,五个断言全绿。库在 {DB}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

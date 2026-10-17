#!/usr/bin/env python3
"""声纹链**跨语言常数**的对撞(M2-认8;2026-08-24 夜班照复核清单 §五抓的)。

    python3 mac/test_voiceprint_contract.py

## 🔴 为什么补这一道

`mac/voiceprint_daemon.py:55` 写着「⚠️ 铁律 4:跨语言对撞在
`mac/test_voiceprint_judge.py`,从 Swift 源码抠出来比」——
去核实的时候发现:**那道对撞只比 `voiceprint_judge.py` 的三个判决常数
(τ / minSegments / minVoteRatio),daemon 自己那五个一个都没比。**

这正是复核清单 §五点名的形状:

> 「与 XXX 必须一致」就写在注释里 —— **把要求写下来不等于守住了它。
> 写得越清楚,越容易让人以为已经处理了。**

⚠️ **今天它们全对得上** —— 所以这道对撞不是「修一个 bug」,是把「今天碰巧对」
变成「漂了会红」。而漂了的表现全都是**沉默的**:

| 常数 | 漂了会怎样 |
|---|---|
| `MODEL_SPACE` | 快照里每一条向量都被判「不是当前空间」⇒ 底库读成空 ⇒ **每一场全拒识**,而日志只说「判完了 0 认出」 |
| `SNAPSHOT_SCHEMA` | `load_snapshot` 拒读 ⇒ 抛「没有底库快照」⇒ 与「手机还没推过」**一模一样** |
| `AUDIO_PREFIX` | 拉音频 404 ⇒ 整场判不了,而 R2 里音频好好躺着(`R2Layout.swift` 那条注释早就写过这个坑) |
| `TARGET_SEC` | Mac 取 4 秒、手机模板是别的长度 ⇒ **查询侧与模板侧不同域**,分数整体偏低而不报错 |
| `MIN_SPEECH_RATIO` / VAD 三个数 | 人声门松紧不一致 ⇒ 两侧挡下的段不是同一批,而「挡下几段」这个数没人对得上 |
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

import mac.silero_vad as vad                       # noqa: E402
import mac.voiceprint_daemon as d                  # noqa: E402

FAILS: list[str] = []


def swift(rel: str) -> str:
    p = REPO / "ios" / "GrowthApp" / rel
    if not p.exists():
        raise SystemExit(f"🔴 {p} 不在 —— 这道对撞的一端没了")
    return p.read_text(encoding="utf-8")


def pull(rel: str, pattern: str, what: str):
    """从 Swift 源码里抠一个字面量。抠不到就红 —— **不静默跳过**:
    静默跳过之后这道对撞就只是个装饰,而「没查」与「查过都对」长得一样。"""
    m = re.search(pattern, swift(rel))
    if not m:
        FAILS.append(f"{rel} 里抠不到「{what}」(`{pattern}`)—— "
                     f"常量改名或换了写法,这个脚本要跟着改,别让它悄悄不查")
        return None
    return m.group(1)


def check(what: str, py, sw, why: str) -> None:
    ok = py is not None and sw is not None and str(py) == str(sw)
    print(("✅" if ok else "🔴"), f"{what}: python={py!r} swift={sw!r}")
    if not ok:
        FAILS.append(f"{what} 两侧对不上(python={py!r} / swift={sw!r})—— {why}")


def main() -> int:
    check("向量空间串 MODEL_SPACE", d.MODEL_SPACE,
          pull("Voiceprint/VoiceprintRegistry.swift",
               r'static let current = "([^"]+)"', "VoiceprintModel.current"),
          "快照里每条向量都被判「不是当前空间」⇒ 底库读成空 ⇒ 每一场全拒识,"
          "而日志只说「判完了 0 认出」")

    check("快照 schema", d.SNAPSHOT_SCHEMA,
          pull("Voiceprint/RegistrySnapshot.swift",
               r'static let schemaVersion = "([^"]+)"', "RegistrySnapshot.schemaVersion"),
          "load_snapshot 拒读 ⇒ 抛「没有底库快照」⇒ 与「手机还没推过」一模一样")

    # 只认我(M5-1 件 7):Mac 判给 SELF_ID,手机按 mePersonID 认「我」。
    # 两边对不上 ⇒ 判出来的「我」写进一个不存在的人名下,界面上照旧显示「说话人 N」,什么都不红。
    from mac.voiceprint_judge import SELF_ID
    check("「我」的 person_id SELF_ID", SELF_ID,
          (lambda v: int(v) if v else None)(
              pull("Presentation/SpeakerNaming.swift",
                   r"static let mePersonID: Int64 = (-?\d+)", "SpeakerNaming.mePersonID")),
          "判成我的簇写到一个不存在的人名下 ⇒ 你的话全显示成「说话人 N」,而判决日志说认出了")
    # 模型串相同不代表判决语义相同;旧开集产物必须重排。
    check("只认我判决模式", "self_only",
          pull("Voiceprint/VoiceprintRemote.swift", r'identity_mode == "([^"]+)"', "identity_mode"),
          "手机收下旧开集结果继续给别人姓名")
    check("Mac产物确实带模式", "self_only",
          (lambda m: m.group(1) if m else None)(re.search(r'"identity_mode": "([^"]+)"', (REPO / "mac/voiceprint_daemon.py").read_text())),
          "只在手机写校验而生产不带字段会一直重排")

    check("音频前缀 AUDIO_PREFIX", d.AUDIO_PREFIX,
          pull("Upload/R2Layout.swift",
               r'static let audioPrefix = "([^"]+)"', "R2Layout.audioPrefix"),
          "拉音频 404 ⇒ 整场判不了,而 R2 里音频好好躺着")

    check("取段目标秒数 TARGET_SEC", d.TARGET_SEC,
          (lambda v: float(v) if v else None)(
              pull("Voiceprint/SpeakerSegments.swift",
                   r"static let targetSeconds: Double = ([0-9.]+)",
                   "SpeakerSegments.targetSeconds")),
          "Mac 取的段长与手机模板不同域 ⇒ 分数整体偏低而不报错")

    check("人声门 MIN_SPEECH_RATIO", vad.MIN_SPEECH_RATIO,
          (lambda v: float(v) if v else None)(
              pull("Voiceprint/SpeechGate.swift",
                   r"static let minSpeechRatio: Double = ([0-9.]+)",
                   "SpeechGate.minSpeechRatio")),
          "两侧挡下的段不是同一批,而「挡下几段」这个数没人对得上")

    for name, py, pat in [
        ("VAD 阈值", vad.SPEECH_THRESHOLD, r"static let speechThreshold: Float = ([0-9.]+)"),
        ("VAD 帧长", vad.FRAME, r"static let frameSamples = (\d+)"),
        ("VAD 上下文", vad.CONTEXT, r"static let contextSamples = (\d+)"),
    ]:
        raw = pull("Recording/SileroVAD.swift", pat, name)
        check(name, py, (type(py)(raw) if raw else None),
              "人声门在两侧松紧不同 —— 同一段音频,一边过一边不过")

    # 🔴 段长下限:手机是**推出来的**(前端窗长 ÷ 采样率),不是写死的数。
    # 两侧各写一个字面量就是第二个出处;这里比的是**推导结果**。
    win = pull("Voiceprint/MelFrontend.swift", r"static let winLength = (\d+)", "winLength")
    sr = pull("Voiceprint/MelFrontend.swift", r"static let sampleRate = (\d+)", "sampleRate")
    check("段长下限 MIN_SEC(= winLength / sampleRate)", round(d.MIN_SEC, 6),
          (round(int(win) / int(sr), 6) if win and sr else None),
          "短于一帧的段两侧处置不同 —— 一边跳过、一边抛,而抛出来会整场判不了")

    # ── 单执行方(方案 §3.1,铁律 3 的姊妹):端侧判决链不许悄悄接回来 ──
    #
    # 🔴 这不是杞人忧天,**它已经发生过一次**:2026-08-24 合并
    # `code-review-feedback` 分支时,git 报零冲突地把 `matchSpeakers`
    # (端侧判决的泵入口)带了回来 —— 那支基于「断开之前」的 main,
    # git 只看行不看语义。当时靠人眼抓住;这道闸把它变成机器的活。
    # 两份判决并行经 `assignSpeaker` 写库,漂了不会有任何报错。
    # ⚠️ 匹配要挡住一个已经踩过的误报:`rematchSpeakers(`(合法,内部走 Mac 队列)
    # 含 `matchSpeakers(` 子串 —— 第一跑就红了 2 处,全是它。前面不能是字母。
    hostile = re.compile(r"(?<![A-Za-z])(VoiceprintChain\.run|matchSpeakers)\(")
    callers = []
    for f in (REPO / "ios" / "GrowthApp").rglob("*.swift"):
        for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if hostile.search(line.split("//")[0]):     # 注释里提到不算调用
                callers.append(f"{f.relative_to(REPO)}:{i}")
    ok = not callers
    print(("✅" if ok else "🔴"), f"单执行方:端侧判决链生产调用点 = {len(callers)}")
    if not ok:
        FAILS.append(f"端侧判决链被接回来了:{callers} —— 判决只在 Mac(方案 §3.1);"
                     f"上次是 2026-08-24 合并零冲突带回来的,git 只看行不看语义")

    if FAILS:
        print()
        for f in FAILS:
            print(f"🔴 {f}", file=sys.stderr)
        print("\n⚠️ 这些常数**漂了不会有任何运行时报错** —— 表现全是沉默的"
              "(全拒识 / 判不了 / 分数偏低),离真因隔着好几跳。", file=sys.stderr)
        return 1
    print("\n✅ 声纹链跨语言常数两侧一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

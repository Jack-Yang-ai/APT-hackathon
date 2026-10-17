#!/usr/bin/env python3
"""growth-agent 的**路径与来源纪律**单一真相源（仿 health 的 model_config「别写死」原则）。

为什么独立一层：growth 是「消费管线 artifacts 的大脑」，松耦合靠的就是
**配置化路径**——管线在哪、读哪几个产物、健康薄片在哪、时区是什么，全收敛到这里。
管线搬家 / 换数据日 / 接别的采集源，只动这一处，核心逻辑不碰（设计方案 §1/§5）。

来源纪律（方案 §5）：
- 只收**脚本真实产物**的白名单（transcript_clean / events_episodes / overview / speech_regions）。
- 三份手工合成 md（叙事 / 融合 / 洞察）**绝不进 build_context**（=用答案考模型），
  它们当 S1 合成引擎的黄金对照样本。
- `events_timeline.csv`（130MB）**永不进 context、永不整读**——只有 S1 选择器按需切片。
"""
from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# ── 管线 artifacts 来源（配置化；管线留在用户 Desktop，growth 只读不改）─────────
# 方案锁定决策：先用现成录音数据做通后半截，采集形态先不定。
PIPELINE_OUT = Path(os.environ.get(
    "GROWTH_PIPELINE_OUT",
    str(Path.home() / "Desktop" / "录音文件" / "_pipeline" / "out_full")))
PIPELINE_DIR = PIPELINE_OUT.parent  # run_all.sh / 散脚本所在（S1 可选 subprocess 触发）

# 白名单：进 build_context 的输入必须能指到产它的脚本（方案 §5 来源纪律）。
# value = 产它的脚本（provenance：每个输入指到脚本，便于追溯/排查）。
ARTIFACT_WHITELIST = {
    "transcript_clean": {"file": "transcript_clean.md", "producer": "clean_transcript.py"},
    "events_episodes":  {"file": "events_episodes.csv",  "producer": "build_episodes.py"},
    "overview":         {"file": "overview.json",        "producer": "build_episodes.py"},
    "speech_regions":   {"file": "speech_regions.json",  "producer": "sed_scan.py"},
}
# 显式黑名单（人读用、防止误进 context 的「答案」与不可整读的巨表）。
ARTIFACT_BLACKLIST_SUBSTR = ("叙事", "融合", "洞察", "events_timeline")

# ── 健康薄片（方案 §1：直接读 health-agent 的 daily json，同机共存）─────────────
HEALTH_DAILY_DIR = Path(os.environ.get(
    "GROWTH_HEALTH_DAILY", str(Path.home() / "health-agent" / "daily")))

# ── 时区（方案 §5：音频 artifacts naive、health 带 +08:00 → 读入即 localize）──────
TZ = os.environ.get("GROWTH_TZ", "Asia/Shanghai")

# ── 数据目录（growth 自己的产物，仿 health 三层存储）──────────────────────────
DATA_DIR = ROOT / "data"
DAILY_DIR = Path(os.environ.get("GROWTH_DAILY_DIR") or (ROOT / "daily"))  # env=竞品语料隔离评测用

# ── Obsidian（S2 外接大脑：读 + 建议写回）。缺省 None = 关闭；用户配置后开。──────
OBSIDIAN_VAULT = os.environ.get("GROWTH_OBSIDIAN_VAULT")  # vault 根目录绝对路径

# ── 会议管线（ingest.meeting：录音 → 转写 → 抽取 → 写回 vault）─────────────────
# 录音/转写 artifact 落地（growth 自己的产物，仿上面 data 三层）。可 env 覆盖搬家。
# MEETING_INBOX：每场会的 *.transcript.md 落这里（extract 的输入；上传后端/CLI 写）。
# MEETING_ARTIFACTS：每场会的边车（声纹 emb / clusters.json / 代表音频切片）按 meeting_id 分目录。
# MEETING_VOICEPRINTS：声纹底库 registry.json（越用越准；随仓走，不进 vault）。
MEETING_INBOX = Path(os.environ.get(
    "GROWTH_MEETING_INBOX", str(DATA_DIR / "meeting_inbox")))
MEETING_ARTIFACTS = Path(os.environ.get(
    "GROWTH_MEETING_ARTIFACTS", str(DATA_DIR / "meeting_artifacts")))
# 🔴 **默认值必须落在被 .gitignore 覆盖的路径上。**
# ~~`ROOT/"ingest"/"meeting"/"voiceprints"`~~ **2026-08-18 改**:那是**旧仓的目录布局**
# (旧仓里 `mac/` 就叫 `ingest/meeting/`),搬过来之后 `ROOT` 指向新仓根,
# 于是这个默认值会在仓库根下造一个 **`.gitignore` 没覆盖**的 `ingest/meeting/voiceprints/`。
# 而隔壁那行注释写的是「声纹底库(**生物特征隐私,绝不进库**)」——
# 保护写在 `.gitignore` 上,真实写入路径却从它旁边绕了过去。
# 本仓有 `git add -A` 把别人的文件卷进提交的事故史(CLAUDE.md 四·补二),
# 这不是理论风险。
MEETING_VOICEPRINTS = Path(os.environ.get(
    "GROWTH_MEETING_VOICEPRINTS", str(ROOT / "mac" / "voiceprints")))
# vault 里会议纪要 / 工作日记子目录（写回位置；与 vault_notes.py 扫描的目录一致）。
MEETING_VAULT_DIR = os.environ.get("GROWTH_MEETING_VAULT_DIR", "30-agent-notes/meeting-notes")
MEETING_JOURNAL_DIR = os.environ.get("GROWTH_MEETING_JOURNAL_DIR", "40-journal")

# ── 上下文预算（方案 §5：默认只放摘要层；transcript 切片走 recall）──────────────
# 中文按 ~1.5 字符/token 估。单日 transcript ≈7-9万 token → 永不整放，按问句检索。
CONTEXT_MAX_EPISODES_CHARS = int(os.environ.get("GROWTH_CTX_EPISODES_CHARS", "16000"))
TRANSCRIPT_NEVER_WHOLE = True  # 守门：build_context 永不整读 transcript（只摘要 + recall 切片）


def artifact_path(key, out_dir=None):
    """白名单 key → 该产物的绝对路径（out_dir 默认当前管线 out）。"""
    meta = ARTIFACT_WHITELIST.get(key)
    if not meta:
        raise KeyError(f"非白名单 artifact: {key!r}（白名单见 config.ARTIFACT_WHITELIST）")
    return Path(out_dir or PIPELINE_OUT) / meta["file"]


def is_blacklisted(name):
    """文件名是否命中黑名单（手工合成 md / 巨表）——绝不进 context。"""
    return any(sub in str(name) for sub in ARTIFACT_BLACKLIST_SUBSTR)

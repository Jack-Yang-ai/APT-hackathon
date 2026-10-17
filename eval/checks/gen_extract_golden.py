#!/usr/bin/env python3
"""生成抽取口径的**金标向量**,给 Python 与 Swift 两侧测试共读。

## 为什么要这个文件

抽取的校验口径(归一 / 逐字 / 三项校验)现在有两份实现:
`worker/extract.py` + `shared/text_normalize.py`(Python,判分尺子也用它),
和 `ios/GrowthApp/Extraction/`(Swift,手机上真正跑的那份)。

两份实现会漂,而漂移**不报错** —— 它只是让尺子量的和生产跑的悄悄变成两回事,
账面上看不出来。所以两侧测试读同一个文件:**谁先漂谁先红**。

## 这不是「Swift 抄 Python」的证明

金标是**从 Python 生成的**,所以它证明的是「Swift 与生成那一刻的 Python 一致」。
Python 自己改了口径而没重新生成,这个文件就会同时让两边都红 —— 那正是要的:
改口径必须是一个显式动作(判 4:改规则就升 NORMALIZER_VERSION)。

跑:python3 eval/checks/gen_extract_golden.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from shared.text_normalize import NORMALIZER_VERSION, is_verbatim, normalize  # noqa: E402
from worker.extract import PROMPT_VERSION, render_prompt, validate  # noqa: E402

OUT = ROOT / "eval/checks/golden/extract_golden.json"
PROMPT_OUT = ROOT / "eval/checks/golden/extract_prompt_v1.txt"

# ── 归一:挑的全是「两个运行时可能给不同答案」的字 ──────────────
NORMALIZE_CASES = [
    "周三之前把文档给老王。",
    "ＡＢＣ, 你好！",
    "abc你好",
    "Hello　World",           # 全角空格
    "Straße",                 # casefold 把 ß 展成 ss,lowercased 不会
    "ΣΟΦΟΣ", "σοφος",         # 词尾 ς → σ,同上
    "İstanbul",
    "ﬁle", "ﬅ", "ﬄ",         # 连字,NFKC 拆开
    "①②③", "Ⅷ", "㈱", "㋿", "℡", "㎡", "１２３",
    "áé", "naïve",            # 组合字符
    "emoji😀里",              # So,要被去掉
    "tab\there", "nl\nhere", "nbsp here",
    "＋－×÷", "~+=°", "¥100", "＄5", "№7", "♪♫", "→←",
    "《书名》", "「引号」", "…省略", "——破折",
    "ｱｲｳ", "アイウ", "ｶﾞ", "ガ",
    "",                       # 空串进空串出
]

# ── 逐字:打的是「什么时候该判不通过」 ─────────────────────────
VERBATIM_CASES = [
    ("把文档给老王", "我周三之前把文档给老王,行吧", True),
    ("把 文档 给 老王", "我周三之前把文档给老王,行吧", True),   # 空格不影响
    ("把文档给老王。", "我周三之前把文档给老王,行吧", True),     # 标点不影响
    ("把文档给小李", "我周三之前把文档给老王,行吧", False),     # 换了人,必须挂
    ("", "随便什么原文", False),                                # 空 quote 一律 False
    ("原文", "", False),
    ("", "", False),
    # ⚠️ 归一后才变空的也算空。原来这里会返回 True —— 标点被全部去掉后
    # 剩空串,又落回「空串是任何串的子串」那个洞(2026-08-14 修)。
    ("。", "随便什么原文", False),
    ("  ", "随便什么原文", False),
    ("……!?", "随便什么原文", False),
    ("~+=°", "他说 ~+=° 这几个符号", False),
    ("ＡＢＣ", "他说 abc 就行", True),                          # 全半角
    ("周三前", "我周三之前把文档给老王", False),                # 少一个字就是改写
]


def line(line_id, text, *, gap=False, person=None, cluster=None):
    return {"line_id": line_id, "text": text, "is_gap": 1 if gap else 0,
            "person_id": person, "cluster_tag": cluster}


LINES = [
    line(10, "我周三之前把文档给老王,行吧", person=1, cluster="说话人1"),
    line(11, "我觉得这个方案不行", person=2, cluster="说话人2"),
    line(12, "先把首页定下来", cluster="说话人2"),          # 归属未定 → 挂起
    line(13, "这段没听清", gap=True, person=1, cluster="说话人1"),  # 占位行 → 丢弃
]


def payload(**over):
    base = {"one_liner": "把首页定下来", "key_points": [], "commitments": [],
            "stances": [], "pendings": [], "topic_keys": []}
    base.update(over)
    return base


VALIDATE_CASES = [
    ("全过", payload(commitments=[
        {"what": "给老王文档", "quote": "把文档给老王", "line_id": 10,
         "to_whom_text": "老王", "speaker_hint": "说话人1"}])),

    ("行号不存在 → 丢弃", payload(key_points=[
        {"point": "编的", "quote": "随便", "line_id": 999}])),

    ("指向占位行 → 丢弃", payload(key_points=[
        {"point": "听不清那段", "quote": "这段没听清", "line_id": 13}])),

    ("quote 非原文子串 → 丢弃", payload(stances=[
        {"stance": "反对", "quote": "我觉得这个方案很好", "line_id": 11,
         "premise": None, "premise_line_id": None}])),

    ("归属未定 → 挂起,不丢", payload(key_points=[
        {"point": "先定首页", "quote": "先把首页定下来", "line_id": 12,
         "speaker_hint": "说话人2"}])),

    ("speaker_hint 与簇标签不一致 → 挂起", payload(key_points=[
        {"point": "先定首页", "quote": "我觉得这个方案不行", "line_id": 11,
         "speaker_hint": "说话人7"}])),

    ("speaker_hint 缺失不算不一致", payload(key_points=[
        {"point": "先定首页", "quote": "我觉得这个方案不行", "line_id": 11}])),

    ("topic_keys 只留存在的行号", payload(topic_keys=[
        {"key": "首页", "line_ids": [10, 999, 12]}])),

    ("四类混在一起,计数要对得上", payload(
        key_points=[{"point": "a", "quote": "先把首页定下来", "line_id": 12},
                    {"point": "b", "quote": "编的引文", "line_id": 10}],
        commitments=[{"what": "c", "quote": "把文档给老王", "line_id": 10,
                      "speaker_hint": "说话人1"}],
        stances=[{"stance": "d", "quote": "这个方案不行", "line_id": 11,
                  "speaker_hint": "说话人2", "premise": None, "premise_line_id": None}],
        pendings=[{"issue": "e", "quote": "随便", "line_id": 999,
                   "parties_text": ["老王"]}])),

    ("一条都没有时不该炸", payload()),
]

# ── schema 校验:该抛的必须抛 ────────────────────────────────
SCHEMA_REJECT_CASES = [
    ("缺 one_liner", {k: [] for k in
                      ("key_points", "commitments", "stances", "pendings", "topic_keys")}),
    ("one_liner 不是字符串", payload(one_liner=42)),
    ("整类省略了(该给空数组)", {k: v for k, v in payload().items() if k != "stances"}),
    ("某类不是数组", payload(key_points={})),
    ("条目不是对象", payload(key_points=["字符串"])),
    ("条目缺必填字段", payload(key_points=[{"point": "a", "quote": "b"}])),
    ("出现了 who —— 归属只能有一个真相源", payload(key_points=[
        {"point": "a", "quote": "先把首页定下来", "line_id": 12, "who": "老王"}])),
]


def main():
    cases = []
    for name, p in VALIDATE_CASES:
        clean, stats = validate(json.loads(json.dumps(p)), LINES)
        cases.append({"name": name, "payload": p, "clean": clean,
                      "stats": stats.as_dict()})

    rejects = []
    for name, p in SCHEMA_REJECT_CASES:
        try:
            validate(json.loads(json.dumps(p)), LINES)
        except Exception as e:                      # noqa: BLE001 —— 就是要收所有
            rejects.append({"name": name, "payload": p, "error": type(e).__name__})
        else:
            raise SystemExit(f"金标生成失败:「{name}」本该被拒,却过了 schema 校验")

    doc = {
        "_": "由 eval/checks/gen_extract_golden.py 生成,勿手改。两侧测试共读。",
        "normalizer_version": NORMALIZER_VERSION,
        "prompt_version": PROMPT_VERSION,
        "normalize": [{"in": s, "out": normalize(s)} for s in NORMALIZE_CASES],
        "verbatim": [{"quote": q, "source": s, "ok": is_verbatim(q, s),
                      "_expected": e} for q, s, e in VERBATIM_CASES],
        "lines": LINES,
        "validate": cases,
        "schema_rejects": rejects,
    }

    # 生成时自查:VERBATIM_CASES 里手写的期望值和实现对不上就别写文件 ——
    # 金标一旦写错,两侧会一起绿着跑偏。
    for v in doc["verbatim"]:
        if v["ok"] != v["_expected"]:
            raise SystemExit(f"金标生成失败:逐字用例期望 {v['_expected']},实现给 {v['ok']}:{v}")
        del v["_expected"]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
    PROMPT_OUT.write_text(render_prompt(LINES))
    print(f"写好 {OUT.relative_to(ROOT)}:归一 {len(doc['normalize'])} · "
          f"逐字 {len(doc['verbatim'])} · 校验 {len(cases)} · 拒收 {len(rejects)}")
    print(f"写好 {PROMPT_OUT.relative_to(ROOT)}:{len(PROMPT_OUT.read_text())} 字符")


if __name__ == "__main__":
    main()

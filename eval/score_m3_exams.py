#!/usr/bin/env python3
"""M3 三张卷的判分(`M3-J1`)。

    python3 eval/score_m3_exams.py <判卷结果.jsonl>

## 🔴 尺子在**看到结果之前**定死

这个脚本先于任何 M3 产出落盘。改它就是改尺子 —— 而改过的尺子量出来的数
与之前的**不可比**(全局原则 5:判官换了历史分数全部不可比)。

## 达标线**在运行时从板上读**,这里一个数都不抄

`M3-0a` 定稿那一节自己写着「这一节是 M3 达标线的唯一出处」。
抄一份进来就是**第三个出处**(板上定稿 / `eval/checks/test_m2_exit.py` 的对撞表 / 这里),
而第三份没有任何东西守着。

## 卷一**复用 M2 的判分函数,不另写**

`M3-J1` 终态原文:「合规率卷复用 `M2-J2` 的(**同一出处,不另起**)」。
所以这里 `from score_m2_exams import score_findings` —— 两份实现迟早分叉,
而分叉时两个数都会自称「合规率」。

## 判分的逐条清单也不在这里

**唯一出处是 `docs/技术方案.md` §4.7.6**(它把 §4.7.2 的 4 必须 + 4 禁止、
§4.7.3 方向/策略分界、§4.7.4 证据门槛收在一处,并给了两类严重违规的判据)。
这个脚本只负责**数**,不负责**判**:判是人按 §4.7.6 判完写进 JSONL 的。

## 观察零容忍的三类,各给正反例(`M3-J1` 终态 ③)

判的是**这句话说的是「他做过什么」还是「他是什么人」**(§4.4.7 一句话判据)。

| 类 | ❌ 违规 | ✅ 合规 |
|---|---|---|
| 性格标签 | 「你是个成本导向的人」 | 「你在 5 件事上都是先问成本再看方案」 |
| 能力评价 | 「你很有前瞻性」 | 「这件事的转机是你 6 月那句判断,当时没人接」 |
| 动机推测 | 「你可能不够自信」 | 「有 3 件事你都是最后一个表态的」 |

三组的差别只有一个:**左边说他是什么人,右边说他做过什么、并给得出出处。**

## 输入格式(JSONL,一行一条)

    {"exam":"发现","id":"f-12","reviewer":"用户","verdict":"合规"}
    {"exam":"发现","id":"f-12","reviewer":"主模型","verdict":"违规","severity":"严重"}
    {"exam":"盲测","id":"p-01","kind":"原则","judged":"我的原则","exclusive":true}
    {"exam":"盲测","id":"g-01","kind":"通用话术","judged":"通用话术"}
    {"exam":"观察","id":"o-03","verdict":"违规","category":"性格标签"}
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "eval"))

from score_m2_exams import Result, score_findings, section_of   # noqa: E402


def pick(src: str, what: str, pattern: str) -> int:
    """从 `M3-0a` 定稿里抠一个数。**抠不到就退出,不给默认值。**

    默认值会让这个脚本在板改过之后继续拿旧线打分,而输出看起来一切正常 ——
    那正是「静默地用了过期结论」。
    """
    m = re.search(pattern, src)
    if not m:
        sys.exit(f"🔴 M3-0a 定稿里抠不到「{what}」(`{pattern}`)—— "
                 f"达标线的唯一出处改了写法,这个脚本要跟着改,别让它拿旧线判分")
    return int(m.group(1))


class Lines:
    """M3 的达标线。**全部现读,一个都不抄。**"""

    def __init__(self) -> None:
        src = section_of("M3-0a")
        self.severe_max = pick(src, "严重违规上限", r"严重违规两类 (\d+) 例")
        self.blind_principles = pick(src, "盲测抽几条原则", r"抽 \*\*(\d+) 条\*\*原则")
        self.blind_generic = pick(src, "盲测混几条话术", r"混 \*\*(\d+) 条\*\*")
        self.blind_recognized = pick(src, "至少认出几条", r"\*\*≥(\d+) 条\*\*原则被认出")
        self.blind_false = pick(src, "编造话术误判率", r"编造话术误判率 \*\*(\d+)\*\*")
        self.obs_sample = pick(src, "观察抽几条", r"抽 \*\*(\d+) 条\*\*观察")
        self.obs_max = pick(src, "观察违规上限", r"\*\*(\d+) 条\*\*含性格标签")


def score_blind(rows: list[dict], L: Lines) -> Result:
    """卷二 · 原则层盲测(协议照 PRD §4.4.13,**不照 §4.4.6 自造**)。

    🔴 **这一卷判的不是「原则对不对」,是「它是不是只属于你」。**
    达不到即判定该层**在产出正确的废话** —— 那种东西每条单看都对,
    合起来毫无价值,而任何按「对不对」设计的卷子都会给它满分。
    """
    r = Result("卷二 原则层盲测", f"编造误判 {L.blind_false} · 认出 ≥{L.blind_recognized}")
    principles = [x for x in rows if x.get("kind") == "原则"]
    generics = [x for x in rows if x.get("kind") == "通用话术"]

    # 🔴 **卷面组成本身就是协议的一部分** —— 5 真 + 3 假。
    # 少放几条假的,「编造误判 0」就变得毫无难度,而分数照样漂亮。
    if len(principles) != L.blind_principles or len(generics) != L.blind_generic:
        r.notes.append(f"⚠️ 卷面是 {len(principles)} 真 + {len(generics)} 假,"
                       f"协议要 {L.blind_principles} 真 + {L.blind_generic} 假 —— "
                       f"卷面不对,这一卷的分不能用")

    false_positive = sum(1 for x in generics if x.get("judged") == "我的原则")
    # 「≥N 条原则被认出**且排他性达标**」:两个条件都要,不是认出来就算。
    recognized = sum(1 for x in principles
                     if x.get("judged") == "我的原则" and x.get("exclusive") is True)
    r.value = (f"编造话术误判 {false_positive}/{len(generics)} · "
               f"认出且排他 {recognized}/{len(principles)}")
    r.passed = (false_positive <= L.blind_false
                and recognized >= L.blind_recognized
                and len(principles) == L.blind_principles
                and len(generics) == L.blind_generic)
    if false_positive > L.blind_false:
        r.notes.append("把通用话术认成了自己的原则 ⇒ **这一层在产出正确的废话,不上线**")
    if recognized < L.blind_recognized:
        r.notes.append("认出且排他的条数不够 —— 注意「认出来」与「只属于我」是两件事,"
                       "只满足前者的条目不计入")
    return r


def score_observations(rows: list[dict], L: Lines) -> Result:
    """卷三 · 观察零容忍(PRD §4.4.7 验收)。**零容忍就是零** —— 不看比例。"""
    r = Result("卷三 观察零容忍", f"{L.obs_max} 条违规")
    bad = [x for x in rows if x.get("verdict") == "违规"]
    by_cat: dict[str, int] = {}
    for x in bad:
        by_cat[x.get("category", "未分类")] = by_cat.get(x.get("category", "未分类"), 0) + 1
    r.value = f"{len(bad)}/{len(rows)} 违规" + (f" · {by_cat}" if by_cat else "")
    r.passed = len(bad) <= L.obs_max and len(rows) >= L.obs_sample
    if len(rows) < L.obs_sample:
        r.notes.append(f"⚠️ 只有 {len(rows)} 条,规格要抽 {L.obs_sample} 条 —— "
                       f"抽得不够时「0 条违规」说明不了什么")
    if bad:
        r.notes.append("零容忍不是比例:**一条都不许有**。"
                       "判据见 `docs/技术方案.md` §4.7.2 —— 说他做过什么,不说他是什么人")
    if any(x.get("verdict") == "违规" and not x.get("category") for x in rows):
        r.notes.append("⚠️ 有违规条目没写 category —— 三类要分开数,否则改不动 prompt")
    return r


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    path = Path(argv[0])
    if not path.exists():
        sys.exit(f"🔴 {path} 不在")
    rows = [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]
    L = Lines()

    def of(exam: str) -> list[dict]:
        return [x for x in rows if x.get("exam") == exam]

    results = [
        # 卷一**复用 M2 的函数**。达标线那句从 M2-0a 读(发现合规率的唯一出处在那边,
        # `M3-0a` 定稿里明写「引用不抄」)。
        # ⚠️ 复用的是 M2 的**判分**,不是它的**编号** —— 在 M2 它是卷三,在 M3 它是卷一。
        # 不改名的话输出里会出现两个「卷三」,而读的人分不出哪个是哪个。
        _renamed(score_findings(of("发现"), _findings_line()), "卷一 发现合规"),
        score_blind(of("盲测"), L),
        score_observations(of("观察"), L),
    ]
    for r in results:
        print(r)          # `Result.__str__` 自己会把 notes 带出来,别再打一遍
    bad = [r for r in results if not r.passed]
    print()
    if bad:
        print(f"🔴 {len(bad)} 张卷没过 —— M3 出口不通过")
        return 1
    print("✅ 三张卷都过")
    return 0


def _renamed(r: Result, name: str) -> Result:
    r.name = name
    return r


def _findings_line() -> str:
    """发现合规率的达标线**在 `M2-0a`**,不在 M3 那边(`M3-0a` 定稿明写引用不抄)。"""
    from score_m2_exams import find_line, thresholds
    return find_line(thresholds(), "发现合规率")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

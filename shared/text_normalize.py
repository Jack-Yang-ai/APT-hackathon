"""quote 逐字比对用的归一函数。**全仓唯一一份。**

判 4 写死了规则:NFKC + 去全部标点空白 + 全半角/大小写归一,并且**要版本化**——
改规则就升版本号,历史校验结果不重新解释。

之所以放在 shared 而不是各处各写一份:抽取链路(worker/extract.py)用它跑三项校验,
判分尺子(eval/extract_quality.py)也用它算一次通过率。两边一旦是两份实现,
尺子和被量的东西就会悄悄对不上——而尺子量的正是这条链路,那种漂移在账面上看不出来。
"""
from __future__ import annotations

import unicodedata

NORMALIZER_VERSION = "v1"

# 要去掉的 Unicode 大类:标点 P、分隔符 Z(含各种空格)、控制符 C、符号 S。
# 去 S 是因为转写里常有 ~ + = ° 之类,模型改写时会顺手吞掉。
_DROP_CATEGORIES = ("P", "Z", "C", "S")


def normalize(s: str) -> str:
    """归一到可比对的形态。空串进、空串出。"""
    s = unicodedata.normalize("NFKC", s).casefold()
    return "".join(ch for ch in s if unicodedata.category(ch)[0] not in _DROP_CATEGORIES)


def is_verbatim(quote: str, source_text: str) -> bool:
    """quote 归一后是否为原文归一后的子串。

    空 quote 一律判 False:「没给引文」不该当成「逐字通过」——
    空串是任何串的子串,不挡住的话所有漏写引文的条目都会静默过关。

    ⚠️ **归一后才变空的也算空**(2026-08-14 补)。原来只挡 `if not quote`,
    于是 `is_verbatim("。", "任意原文")` 返回 True —— 标点被归一规则全部去掉,
    剩下空串,又落回「空串是任何串的子串」那个洞。这是同一个错法的另一半:
    挡住了「没给引文」,没挡住「给的引文里一个可比对的字都没有」。
    后果和漏挡空 quote 一样 —— 一条编造的条目静默通过逐字校验,
    而逐字通过率正是 R4 用来决定「要不要先修抽取」的那个数。
    """
    if not quote:
        return False
    q = normalize(quote)
    if not q:
        return False
    return q in normalize(source_text)

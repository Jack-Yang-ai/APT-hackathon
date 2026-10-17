#!/usr/bin/env python3
"""已有处理模块的验收线对撞。读取 eval/contracts/acceptance.md，错数或缺少消费锚点必须失败；可传变异副本做自检。"""
from __future__ import annotations

import re
import sys
from pathlib import Path

TASKS = Path(__file__).resolve().parents[2] / "eval/contracts/acceptance.md"

#: 出口判据的**唯一出处**:每个里程碑一份 (定稿标题, 达标线表, 要扫的锚点)。
#:
#: 🔴 **2026-08-25 从「只盖 M2」扩到「M2 + M3」。**
#: 原来这个脚本只扫 M2 三处,而 `M3-0a` 的验收原文写着
#: 「M3 的数字副本全在射程外,『18 行』漂移就是现行证据」——
#: 那句话当时是真的:板上顺延表里躺着「§5.2 **十八**行演示」,
#: 而正文写的是 17,**没有任何东西会红**。本次一并改成 17 并把 M3 纳入射程。
#:
#: ⚠️ **锚点只写任务号,不写状态标记**。`[ ]`/`[!]`/`[x]` 会随进度变,
#: 写进锚点等于给这道对撞装了个定时失效开关(第三版栽过一次,见下面 `locate`)。
MILESTONES = {
    "M2": {
        "src": "### [x] M2-0a",
        "lines": {
            "提名判准率": "40%–70%",
            "静默档判准率": "≥90%",
            "发现合规率": "≥95%",
            "搜索": "<100ms",
        },
        "anchors": ["**M2 出口**", "M2-J2", "M2-L4"],
    },
    "M3": {
        "src": "### [x] M3-0a",
        "lines": {
            # 🔴 **「发现合规率」故意不在这里。**
            # 它已经是 M2 那份的一条(`M2-L4` 判卷用同一个数)。
            # 在这里再列一次,这个脚本自己就成了「同一个数两个唯一出处」——
            # 而它存在的全部理由就是不许有第二份。
            "严重违规": "0 例",
            # ⚠️ 键写「§5.2」不写「联动表」:**别处未必用同一个词**。
            # 顺延表里那行写的是「L2 §5.2 十八行演示」—— 一个「联动表」都没有,
            # 于是按「联动表」找会整行跳过,而那正是这个数唯一漂过的地方。
            # ⇒ 键要选**引用方真的会写的那个词**,不是我们自己的叫法。
            "§5.2": "17 行",
            "盲测": "5 条",
            "通用话术": "3 条",
            "观察零容忍": "10 条",
        },
        # ⚠️ 最后那个不是任务号,是**顺延表里那一行**。那个数错的
        # 「§5.2 十八行演示」当时正躺在那儿,而它不在任何任务号底下 ——
        # 验收原文说的「M3 的数字副本全在射程外」,指的就是这种地方。
        #
        # 🔴 **不能用 `### 本冲刺砍掉 / 顺延的` 当锚点:M2-S1 与 M3-S1 各有一个,
        # 一模一样。** `find` 命中的是 M2 那个,于是这道闸安静地扫了错的段落
        # (照妖镜第一次没红就是因为它)。⇒ 用那一行独有的串。
        # 这一行哪天被改写,锚点就找不到 ⇒ **红**,而不是悄悄少扫一处。
        "anchors": ["**M3 出口**", "M3-J1", "M3-J3", "M3-L2",
                    "| M3-F5 采集 UI"],
    },
}


def locate(text: str, anchor: str) -> tuple[int, int]:
    """找锚点起点。任务号形式的锚点按「### [任意状态] 任务号」匹配。"""
    # 🔴 **判据是「像不像任务号」,不是「是不是 M2 开头」。**
    #
    # 2026-08-25 扩到 M3 时栽在这儿:这里原来写死 `startswith("M2-")`,
    # 于是 `M3-J1` 走了下面的裸 `find` —— 而它命中的是
    # **`M3-0a` 定稿表格里那句「`M3-J1` 抽检」**,不是那一节的标题。
    # ⇒ 闸在拿定稿当锚点扫**自己**,两条照妖镜都安静地绿了。
    # 扩配置而不扩机制,机制会**默默接受**新配置并给出绿色。
    if re.match(r"^M\d+-", anchor):
        m = re.search(rf"^### \[.\] {re.escape(anchor)}\b", text, re.M)
        return (m.start(), len(m.group(0))) if m else (-1, 0)
    i = text.find(anchor)
    return (i, len(anchor)) if i >= 0 else (-1, 0)


def shape_of(value: str) -> str:
    """按**这条达标线自己的单位**造正则,不是一把大网捞所有数字。

    🔴 **2026-08-25 第三次调这个脚本的射程,理由与前两次同一条。**
    把 M3 纳进来时我图省事,在原正则后面加了 `|\\d+\\s?[条行例]` ——
    当场多出两条**误报**:`M2-J2` 里那句「抽 **50 条**」是**样本量**,
    与「静默档判准率 ≥90%」这条达标线毫无关系,而它离关键词够近就被捞了进去。

    这个脚本自己的注释里早写过这条教训:
    **扫太宽的代价不是多报几条,是这道对撞会被当成噪音关掉。**
    ⇒ 判据改成:只找**与声明值同一种单位**的数。
    `≥90%` 只找百分数,`17 行` 只找「N 行」—— `50 条` 再也不会去撞百分数那条。
    """
    if "%" in value:
        return r"[≥≤<>]?\s?\d+(?:\.\d+)?%(?:–\d+%)?"
    if "ms" in value:
        return r"[≥≤<>]?\s?\d+\s?ms"
    m = re.search(r"([\u4e00-\u9fff]+)$", value.strip())
    if m:                                   # 条 / 行 / 例 这类中文量词
        # ⚠️ **「第 N 行」是行号,不是行数** —— `M3-L2` 里那句
        # 「第 **8 行**『这不是我说的→触发说话人纠正』」当场被捞成了误报。
        # 同一个形状的数在同一段话里可以是**完全不同的东西**,而这个脚本
        # 只会看形状。⇒ 把「第」挡掉。
        #
        # 🔴 这是这道射程第四次被收窄(前三次:扫全文 → 扫三处 → 按单位分形状)。
        # 记在这里是因为**每一次收窄都是在真误报出现之后**,而不是提前想到的:
        # 「在正文里找散落的数」这件事本身就是启发式的,它挡得住真漂移
        # (`18 行`那次),代价是每加一种单位就要再喂它一次反例。
        # 两个定宽后顾:「第8行」与「第 8 行」都要挡住。
        # (只写一个的话空格那种写法照样漏 —— 第一版就是这么漏的。)
        return rf"(?<!第)(?<!第\s)\d+\s?{re.escape(m.group(1))}"
    return r"[≥≤<>]\s?\d+(?:\.\d+)?"


def section(text: str, heading: str) -> str:
    """取从某个 heading 到下一个同级 heading 之间的正文。"""
    i = text.find(heading)
    if i < 0:
        sys.exit(f"🔴 板上找不到 `{heading}` —— 对撞的一端没了,这个脚本在空转")
    j = text.find("\n### ", i + len(heading))
    return text[i: j if j > 0 else len(text)]


def main(argv: list[str] | None = None) -> int:
    # 可传一份**改坏的** TASKS.md 副本进来 —— 照妖镜要的就是这个:
    # 一条没法被造脏打红的断言,等于「今天这份数据碰巧干净」(复核清单 §八)。
    argv = argv if argv is not None else sys.argv[1:]
    if argv:
        text = Path(argv[0]).read_text(encoding="utf-8")
    else:
        text = TASKS.read_text(encoding="utf-8")
    problems: list[str] = []

    for milestone, cfg in MILESTONES.items():
        src = section(text, cfg["src"])
        lines, anchors = cfg["lines"], cfg["anchors"]

        # ① 每条达标线都必须出现在 0a 定稿里
        for key, value in lines.items():
            if value not in src:
                problems.append(f"{milestone}:0a 定稿里找不到「{key} = {value}」"
                                f"—— 唯一出处缺了这一条")

        # ② **只扫验收点名的那几处**,不扫全文。
        #
        # ⚠️ 第一版扫的是「全文里所有含关键词的行」,当场报了 8 条**全是误报** ——
        # 「提名判准率被污染的方式」这种叙述句里的数与达标线无关。
        # 而验收原文写死了范围:**是我扫宽了**。
        # 扫太宽的代价不是多报几条,是这道对撞会被当成噪音关掉。
        for anchor in anchors:
            i, length = locate(text, anchor)
            if i < 0:
                # 🔴 **锚点找不到 = 红,不是跳过。**
                #
                # 第三版栽在这儿:锚点原本写成 `### [ ] M2-J2`,**含状态标记** ——
                # 而状态标记必然随干活而变。我在写这个脚本的同一天把那个标题改成
                # `### [!] M2-J2`,于是这一段**再也没被扫过,脚本照打 ✅**。
                # 那正是这个脚本存在的理由的形状:对不上而不报错。
                problems.append(f"{milestone}:锚点「{anchor}」在板上找不到 —— "
                                f"这道对撞的一端掉了,它现在扫的比声明的少")
                continue
            j = text.find("\n### ", i + length)
            body = text[i: j if j > 0 else i + 2000]
            for key, value in lines.items():
                if key not in body:
                    continue
                # 🔴 **只在「抄了而且抄错」时红,不在「没抄」时红。**
                #
                # 第二版栽在这儿:J2 与 L4 只提到概念、没抄数 —— 而那**正是我们要的**
                # (别处一律引用不抄数)。把「没抄」判成冲突,等于逼所有人到处抄数,
                # 恰好与这道对撞要达成的目的相反。
                near = body[max(0, body.find(key) - 120): body.find(key) + 160]
                nums = re.findall(shape_of(value), near)
                if not nums:
                    continue                      # 没抄数 —— 合规,跳过
                if value.replace(" ", "") not in near.replace(" ", ""):
                    problems.append(
                        f"{milestone}:「{anchor}」抄了「{key}」的数 {nums} "
                        f"而与定稿({value})对不上")

    if problems:
        print("🔴 出口达标线对不上:")
        for p in problems:
            print("  -", p)
        return 1
    total = sum(len(c["lines"]) for c in MILESTONES.values())
    print(f"✅ 出口达标线一致({total} 条,唯一出处 = 各里程碑的 0a 定稿)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

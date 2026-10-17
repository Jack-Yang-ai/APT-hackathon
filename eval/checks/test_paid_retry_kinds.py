#!/usr/bin/env python3
"""付费重试集合的源码对撞(铁律 4 的一个特例)。

    python3 eval/checks/test_paid_retry_kinds.py

## 为什么要这道脚本

`TaskQueue.paidRetryKinds` 决定一条任务失败后**最多重试几次**:
在集合里是 5 次,不在是 **290 次 / 6 天**。

判据是「失败会不会再买一次」:提交/轮询那条链失败时连上游都没碰到,
重试不花钱;而**先 `call`(花钱)、再解析/校验**的腿,解析一抛就等于原价再买一次
—— 而模型输出不合法是**确定性**失败,同一份输入每次都触发,重试永远救不了。

🔴 **漏加不会有任何东西报错。** 这不是假设:

· `paidRetryKinds` 头上原本就写着「将来再加一条花钱的腿,加进这个集合即可,
  **而漏加的后果是它悄悄吃到 290 次的额度**」;
· 而 `progress` 就是照着这句话漏的 —— 写下要求的人和漏掉要求的是同一处代码;
· 代价见 `M2-认7`:某场次 的 progress 任务 `attempts = 58`、**连崩 6 天**,
  期间每一拍都占一次 pump,而界面上只是「还在处理」。

⇒ **把要求写进注释不等于守住了它**(CLAUDE.md 铁律 4 原话)。这道脚本是那道会红的闸。

## 判据

`ios/GrowthApp/Extraction/` 下每个 `*Runner.swift`:
若它的 `run` 收 `call:`(= 先花钱再解析的腿),则

  ① 它必须声明 `static let taskKind = ProcessingOrchestrator.Kind.<x>`
  ② 那个 `<x>` 对应的字面量必须出现在 `TaskQueue.paidRetryKinds` 里

任一条不满足 ⇒ 红,并打出文件名与缺的那一项。

⚠️ **比的是源码不是数据**(铁律 4 的附注):数据断言只能证明「今天没跑满 290 次」,
挡不住下一条新加的付费腿。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNNERS = ROOT / "ios/GrowthApp/Extraction"
# 可用 argv[1] 换掉 —— 只为让 `test_checks.py` 能拿一份改坏的副本验「这道闸真会红」。
# 与 `test_task_ids.py` 同一个约定。
TASK_QUEUE = (Path(sys.argv[1]) if len(sys.argv) > 1
              else ROOT / "ios/GrowthApp/Database/TaskQueue.swift")
ORCHESTRATOR = ROOT / "ios/GrowthApp/Upload/ProcessingOrchestrator.swift"


def paid_retry_kinds(text: str) -> set[str]:
    """`static let paidRetryKinds: Set<String> = ["extract", "progress"]` → {...}"""
    m = re.search(r"paidRetryKinds\s*:\s*Set<String>\s*=\s*\[([^\]]*)\]", text)
    if not m:
        raise SystemExit("🔴 在 TaskQueue.swift 里找不到 paidRetryKinds —— 它被改名或删了?")
    return set(re.findall(r'"([^"]+)"', m.group(1)))


def kind_literals(text: str) -> dict[str, str]:
    """`ProcessingOrchestrator.Kind` 里 `static let progress = "progress"` → {"progress": "progress"}

    `upload` 那条是 `= BlockUploader.taskKind`(不是字面量),取不到就不收 ——
    它本来也不是付费腿。
    """
    block = re.search(r"enum Kind \{(.*?)\n    \}", text, re.S)
    if not block:
        raise SystemExit("🔴 在 ProcessingOrchestrator.swift 里找不到 enum Kind")
    return dict(re.findall(r'static let (\w+)\s*=\s*"([^"]+)"', block.group(1)))


def main() -> int:
    kinds = kind_literals(ORCHESTRATOR.read_text(encoding="utf-8"))
    paid = paid_retry_kinds(TASK_QUEUE.read_text(encoding="utf-8"))

    problems: list[str] = []
    checked = 0
    for path in sorted(RUNNERS.glob("*Runner.swift")):
        text = path.read_text(encoding="utf-8")
        # 「先花钱再解析」的判据:`run` 的签名里收一个注入的模型调用。
        if not re.search(r"func run\b[^{]*\bcall:", text, re.S):
            continue
        checked += 1
        m = re.search(r"static let taskKind\s*=\s*ProcessingOrchestrator\.Kind\.(\w+)", text)
        if not m:
            problems.append(
                f"{path.name}:它的 run 收 call:(先花钱再解析),"
                f"却没声明 `static let taskKind = ProcessingOrchestrator.Kind.<x>` —— "
                f"没有这一行,就没人能机器检查它有没有落进 paidRetryKinds")
            continue
        name = m.group(1)
        literal = kinds.get(name)
        if literal is None:
            problems.append(f"{path.name}:taskKind 指向 Kind.{name},而 Kind 里没有这个字面量")
        elif literal not in paid:
            problems.append(
                f"{path.name}:kind「{literal}」不在 TaskQueue.paidRetryKinds 里 —— "
                f"它先花钱再解析,确定性坏输出会按 290 次 / 6 天重试,每一次都真花钱")

    if problems:
        print("🔴 付费重试集合对不上:")
        for p in problems:
            print(f"  · {p}")
        return 1
    if checked == 0:
        print("🔴 一个收 call: 的 runner 都没扫到 —— 判据失效了(目录挪了?签名改了?),"
              "这道闸现在什么都挡不住")
        return 1
    print(f"✅ 付费重试集合一致({checked} 条先花钱再解析的腿,都在 paidRetryKinds 里)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

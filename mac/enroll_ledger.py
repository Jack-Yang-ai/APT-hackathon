"""Generic implementation; local private materials are not distributed."""













from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path


class LedgerCorrupt(RuntimeError):
    """账本读不出来。**不要当成空账继续跑** —— 那等于把所有指令重放一遍。"""


@dataclass
class Decision:
    execute: bool
    reason: str


class EnrollLedger:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.processed: set[str] = set()
        self.revoked: set[str] = set()
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            self.processed = set(data["processed"])
            self.revoked = set(data["revoked"])
        except Exception as e:
            raise LedgerCorrupt(
                f"enroll 账本读不出来({self.path}):{e}。"
                "**不要当空账跑** —— 那会把历史指令全部重放一遍,包括已经撤销的。"
            ) from e

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(
            {"processed": sorted(self.processed), "revoked": sorted(self.revoked)},
            ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, self.path)   # 原子替换,不留半截文件

    @staticmethod
    def instruction_id(cmd: dict) -> str:
        """指令的幂等键。

        §1.3 给 enroll 定的幂等键是 `person_id + 嵌入哈希`——同一个人同一段嵌入
        再投一次就是同一条指令。指令自带 id 时以它为准(手机侧生成的更稳)。
        """
        if cmd.get("id"):
            return str(cmd["id"])
        return f"{cmd.get('person_id')}::{cmd.get('embedding_sha256')}"

    def decide(self, cmd: dict) -> Decision:
        """这条指令该不该执行。**只判断,不改账** —— 执行成功了才记。"""
        action = cmd.get("action")
        if action not in ("enroll", "unenroll"):
            return Decision(False, f"未知指令 {action!r},不执行也不记账")

        key = self.instruction_id(cmd)

        if action == "unenroll":
            if key in self.revoked:
                return Decision(False, "这条撤销已经执行过")
            return Decision(True, "撤销")

        # enroll
        if key in self.revoked:
            # tombstone:撤销之后再被重放的 enroll,一律不执行
            return Decision(False, "这条 enroll 已被撤销,重放不执行(tombstone)")
        if key in self.processed:
            return Decision(False, "这条 enroll 已经执行过")
        return Decision(True, "首次执行")

    def record(self, cmd: dict) -> None:
        """执行成功之后记账。失败就别记 —— 记了下次不会重试。"""
        key = self.instruction_id(cmd)
        if cmd.get("action") == "unenroll":
            self.revoked.add(key)
            self.processed.discard(key)
        else:
            self.processed.add(key)
        self._save()

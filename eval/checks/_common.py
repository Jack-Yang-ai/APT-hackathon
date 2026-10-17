"""断言脚本共用的壳。

判 8:地基是 Swift 真身,验收脚本是 Python,两边靠同一个 SQLite 文件对接。
所以这些脚本**只读 DB 文件**,不认识 Swift,也不重抄 schema。

三条纪律:
  · **表不在 ≠ 断言通过。** 缺表一律记成 SKIP 并在输出里显眼列出,
    绝不当成绿。M0 的 schema 里没有 person/thing 这些表,那些断言现在查不了,
    但「查不了」和「查过了没问题」必须能分清。
  · 退出码非 0 即失败(§3.5.3)。
  · 每条断言打印它**实际查到的数**,不只打勾 —— 光看 ✓ 分不出「查了 0 条违规」
    和「压根没查」。
"""
from __future__ import annotations

import argparse
import sqlite3
import sys
from dataclasses import dataclass, field


@dataclass
class Report:
    name: str
    failures: list[str] = field(default_factory=list)
    skips: list[str] = field(default_factory=list)
    passes: list[str] = field(default_factory=list)

    def ok(self, code: str, detail: str) -> None:
        self.passes.append(f"{code}: {detail}")

    def fail(self, code: str, detail: str) -> None:
        self.failures.append(f"{code}: {detail}")

    def skip(self, code: str, why: str) -> None:
        self.skips.append(f"{code}: {why}")

    def finish(self) -> int:
        print(f"── {self.name} ──")
        for line in self.passes:
            print(f"  ✓ {line}")
        for line in self.skips:
            print(f"  – 跳过 {line}")
        for line in self.failures:
            print(f"  ✗ {line}")
        if self.skips:
            print(f"  ({len(self.skips)} 条查不了 —— 不算通过)")
        if self.failures:
            print(f"  {self.name} 失败 {len(self.failures)} 条")
            return 1
        print(f"  {self.name} 全绿({len(self.passes)} 条)")
        return 0


def open_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def table_exists(conn: sqlite3.Connection, name: str) -> bool:
    return conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ).fetchone() is not None


def trigger_sql(conn: sqlite3.Connection, name: str) -> str | None:
    row = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", (name,)
    ).fetchone()
    return row["sql"] if row else None


def count(conn: sqlite3.Connection, sql: str, args: tuple = ()) -> int:
    return conn.execute(sql, args).fetchone()[0]


def line_id_tables(conn: sqlite3.Connection) -> list[str]:
    """所有带 line_id 列的表(除冻结层自己)。

    **动态发现而不是写死清单**:新建一张带 line_id 的表却忘了把它加进断言,
    正是 A3 要防的事;写死清单等于把这个漏洞留给「记得改」。
    """
    out = []
    for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'"):
        name = row["name"]
        if name == "transcript_lines" or name.startswith("sqlite_"):
            continue
        cols = [c[1] for c in conn.execute(f"PRAGMA table_info({name})")]
        if "line_id" in cols:
            out.append(name)
    return out



def person_id_tables(conn: sqlite3.Connection) -> list[str]:
    """Generic implementation; local private materials are not distributed."""








    out = []
    for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'"):
        name = row["name"]
        if name == "persons" or name.startswith("sqlite_"):
            continue
        cols = [c[1] for c in conn.execute(f"PRAGMA table_info({name})")]
        if "person_id" in cols:
            out.append(name)
    return sorted(out)

def main(check_fn, name: str) -> int:
    ap = argparse.ArgumentParser(description=name)
    ap.add_argument("db", help="主库 SQLite 文件路径")
    args = ap.parse_args()
    conn = open_db(args.db)
    report = Report(name)
    try:
        check_fn(conn, report)
    finally:
        conn.close()
    return report.finish()


def run(check_fn, name: str) -> None:
    sys.exit(main(check_fn, name))

#!/usr/bin/env python3
"""日期在真实口语里长什么样 —— 决定「相对时间怎么用」的那个数。

    python3 eval/date_surface_freq.py            # 用默认语料(旧仓 memory.sqlite)
    python3 eval/date_surface_freq.py --db <路径>

## 为什么要量这个

`M2-检2` §1.2 原本照 VoiceMem 的做法设计:把问句里的「下周」展开成七个绝对日期,
拿去检索。**那套在它那里成立,是因为它检索的是抽取产物**(事实文本已被归一成
「2026年8月26日」);而我们的 L1 检索的是**转写原文**,原文里写的是人怎么说的。

所以先量:真实口语里,绝对日期与相对时间词各出现多少次。

## 🔴 语料不进版本库

旧仓 `~/growth-agent/data/memory.sqlite` 是真实录音的产物,只在 Mac 上。
这个脚本只输出**计数**,不打印也不落盘任何原话(与 U-检索1 的语料标定同一条纪律)。
"""
from __future__ import annotations

import argparse
import os
import re
import sqlite3
import sys

DEFAULT_DB = os.path.expanduser("~/growth-agent/data/memory.sqlite")

#: 从哪几张表取文本。取不到的表跳过(旧仓不同备份的 schema 不完全一样)。
SOURCES = (("episode_quotes", "quote"), ("episodes", "summary"), ("atoms", "text"))

#: 要数的两族。**绝对日期**是「展开成日期去搜」能命中的形状,
#: **相对时间词**是人实际会说的形状。两者的比值就是那个设计成不成立的判据。
PATTERNS = {
    "绝对·M月D日": r"\d{1,2}月\d{1,2}日",
    "绝对·M月D号": r"\d{1,2}月\d{1,2}号",
    "绝对·D日": r"(?<!月)\d{1,2}日(?![期])",
    "绝对·D号": r"(?<!月)\d{1,2}号",
    "相对·今天": r"今天|今日",
    "相对·明天": r"明天|明日",
    "相对·昨天": r"昨天",
    "相对·下周": r"下周|下个星期|下星期",
    "相对·上周": r"上周|上个星期",
    "相对·本周": r"这周|本周|这个星期",
    "相对·后天": r"后天",
    "相对·前天": r"前天",
}


def load_corpus(db_path: str) -> tuple[str, dict[str, int]]:
    """→ (全部文本, 每张表贡献的行数)。表不存在就跳过,不报错。"""
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    chunks: list[str] = []
    per_table: dict[str, int] = {}
    for table, column in SOURCES:
        try:
            rows = conn.execute(
                f"SELECT {column} FROM {table} WHERE {column} IS NOT NULL"  # noqa: S608
            ).fetchall()
        except sqlite3.Error:
            continue
        per_table[f"{table}.{column}"] = len(rows)
        chunks.extend(str(r[0]) for r in rows)
    conn.close()
    return "\n".join(chunks), per_table


def count(blob: str) -> dict[str, int]:
    return {name: len(re.findall(pattern, blob)) for name, pattern in PATTERNS.items()}


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=DEFAULT_DB)
    args = ap.parse_args(argv)

    if not os.path.exists(args.db):
        # 语料不在版本库里,别人的机器上没有是正常的 —— 说清楚,不假装量过。
        print(f"语料不在:{args.db}(它只在 Mac 上,不进版本库)", file=sys.stderr)
        return 2

    blob, per_table = load_corpus(args.db)
    if not blob:
        print("语料是空的 —— 表名或列名对不上,不是「没有日期」", file=sys.stderr)
        return 2

    counts = count(blob)
    absolute = sum(v for k, v in counts.items() if k.startswith("绝对"))
    relative = sum(v for k, v in counts.items() if k.startswith("相对"))

    print(f"语料:{args.db}")
    for k, v in per_table.items():
        print(f"  {k}: {v} 行")
    print(f"  合计 {len(blob)} 字\n")
    for name, n in counts.items():
        print(f"  {name:12s} {n:5d}")
    print(f"\n绝对日期合计 {absolute} · 相对时间词合计 {relative}", end="")
    if absolute:
        print(f" · 相对是绝对的 {relative / absolute:.0f} 倍")
    else:
        print(" · 绝对为零")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

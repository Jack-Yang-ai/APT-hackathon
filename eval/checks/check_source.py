#!/usr/bin/env python3
"""A5 来源标记非空且在闭集内(§3.5.1)。"""
from __future__ import annotations

from _common import count, run, table_exists

CLOSED_SET = {"系统整理", "声纹识别", "平台标注", "系统交叉验证", "用户确认"}


def check(conn, r):
    if not table_exists(conn, "line_speakers"):
        r.skip("A5", "line_speakers 表不在")
        return

    # DDL 上的 CHECK 必须在 —— 靠数据碰巧干净不算数
    ddl = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='line_speakers'"
    ).fetchone()["sql"]
    if "CHECK" not in ddl.upper() or "source" not in ddl:
        r.fail("A5", "line_speakers.source 上没有 CHECK 约束")
    else:
        r.ok("A5", "source 上有 CHECK 闭集约束")
    if "source" in ddl and "NOT NULL" not in ddl.split("source")[1].split(",")[0].upper():
        r.fail("A5", "line_speakers.source 没有 NOT NULL")
    else:
        r.ok("A5", "source 是 NOT NULL")

    nulls = count(conn, "SELECT COUNT(*) FROM line_speakers WHERE source IS NULL")
    if nulls:
        r.fail("A5", f"{nulls} 行 source 为 NULL")

    # NULL 单独报(上面那条),这里只比非空取值 —— 混在一起排序会拿 str 跟 None 比,
    # 脚本自己先崩,报出来的就成了栈回溯而不是断言结论。
    rows = conn.execute(
        "SELECT DISTINCT source FROM line_speakers WHERE source IS NOT NULL"
    ).fetchall()
    outside = {row[0] for row in rows} - CLOSED_SET
    total = count(conn, "SELECT COUNT(*) FROM line_speakers")
    if outside:
        r.fail("A5", f"闭集外的取值:{sorted(outside)}")
    else:
        r.ok("A5", f"{total} 行的 source 全在闭集内(实际用到 {len(rows)} 种)")


run(check, "check_source")

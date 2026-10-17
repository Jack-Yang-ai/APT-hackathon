#!/usr/bin/env python3
"""A3 内容引用零悬空 · A4 归属引用零悬空 · E4 判断依据可解析(含已脱敏)。

§3.5.3 的停止线之一:**这个脚本不为 0 就不许进判卷**——
拿一份引用错乱的库去打分,打出来的分是假的。
"""
from __future__ import annotations

from _common import count, line_id_tables, run, table_exists


def check(conn, r):
    # ── A3 / A4:每张带 line_id 的表左连冻结层,右边为空的必须为 0
    for table in line_id_tables(conn):
        dangling = count(conn, f"""
            SELECT COUNT(*) FROM {table} t
              LEFT JOIN transcript_lines l ON l.line_id = t.line_id
             WHERE l.line_id IS NULL
        """)
        code = "A4" if table == "line_speakers" else "A3"
        total = count(conn, f"SELECT COUNT(*) FROM {table}")
        if dangling:
            r.fail(code, f"{table} 有 {dangling} 条悬空引用(共 {total} 条)")
        else:
            r.ok(code, f"{table} 零悬空({total} 条)")

    # stances 的前提行号也是引用,一并查
    if table_exists(conn, "summary_stances"):
        dangling = count(conn, """
            SELECT COUNT(*) FROM summary_stances s
              LEFT JOIN transcript_lines l ON l.line_id = s.premise_line_id
             WHERE s.premise_line_id IS NOT NULL AND l.line_id IS NULL
        """)
        if dangling:
            r.fail("A3", f"summary_stances.premise_line_id 有 {dangling} 条悬空")
        else:
            r.ok("A3", "summary_stances.premise_line_id 零悬空")

    # ── E4:basis_line_ids 每个 id 都能在 transcript_lines 找到。
    #        redacted=1 的行**算可解析**(§3.1.7:墓碑行仍能被定位到,只是读不出内容)
    if not table_exists(conn, "judgments"):
        r.skip("E4", "judgments 表不在")
        return
    unresolvable = count(conn, """
        SELECT COUNT(*) FROM judgments j
          JOIN json_each(j.basis_line_ids) b
          LEFT JOIN transcript_lines l ON l.line_id = b.value
         WHERE l.line_id IS NULL
    """)
    total = count(conn, """
        SELECT COUNT(*) FROM judgments j JOIN json_each(j.basis_line_ids) b
    """)
    if unresolvable:
        r.fail("E4", f"{unresolvable} 个依据行号解析不出来(共 {total} 个)")
    else:
        redacted = count(conn, """
            SELECT COUNT(*) FROM judgments j
              JOIN json_each(j.basis_line_ids) b
              JOIN transcript_lines l ON l.line_id = b.value
             WHERE l.redacted = 1
        """)
        r.ok("E4", f"{total} 个依据行号全部可解析(其中 {redacted} 个指向已脱敏行,按 §3.1.7 算可解析)")


run(check, "check_refs")

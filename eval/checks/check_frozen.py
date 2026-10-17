#!/usr/bin/env python3
"""A1 转写不可变 · A2 行序无洞 · A6 占位行不被引用(§3.5.1)。"""
from __future__ import annotations

from _common import count, line_id_tables, run, table_exists, trigger_sql


def check(conn, r):
    # ── A1:冻结层的 BEFORE UPDATE / DELETE 触发器必须在,且 RAISE(ABORT)
    for name, kind in [("transcript_lines_no_update", "UPDATE"),
                       ("transcript_lines_no_delete", "DELETE")]:
        sql = trigger_sql(conn, name)
        if sql is None:
            r.fail("A1", f"触发器 {name} 不存在 —— 冻结层没有物理防线")
        elif "RAISE(ABORT" not in sql.replace(" ", ""):
            r.fail("A1", f"触发器 {name} 没有 RAISE(ABORT)")
        else:
            r.ok("A1", f"{name}({kind})在位且 RAISE(ABORT)")

    # A1 的例外只能是 redact 通道:UPDATE 触发器必须带 WHEN 条件把它收窄,
    # 不能是「无条件放行」。无条件的 BEFORE UPDATE 触发器等于没有例外控制。
    sql = trigger_sql(conn, "transcript_lines_no_update") or ""
    if "WHEN" not in sql.upper():
        r.fail("A1", "UPDATE 触发器没有 WHEN 条件 —— redact 例外要么没开、要么开成了后门")
    else:
        r.ok("A1", "UPDATE 触发器带 WHEN 条件(redact 通道是被收窄的例外,不是开关)")

    # ── A2:行序连续无洞(§3.5.1 给的就是这条 SQL)
    holes = conn.execute("""
        SELECT transcript_id FROM transcript_lines
         GROUP BY transcript_id HAVING MAX(seq) + 1 != COUNT(*)
    """).fetchall()
    if holes:
        r.fail("A2", f"这些 transcript 的行序有洞:{[h[0] for h in holes]}")
    else:
        r.ok("A2", f"行序无洞(查了 {count(conn, 'SELECT COUNT(DISTINCT transcript_id) FROM transcript_lines')} 个 transcript)")

    # seq 必须从 0 开始 —— MAX+1==COUNT 在「从 1 开始且缺一条」时也成立
    bad_start = conn.execute("""
        SELECT transcript_id FROM transcript_lines
         GROUP BY transcript_id HAVING MIN(seq) != 0
    """).fetchall()
    if bad_start:
        r.fail("A2", f"这些 transcript 的 seq 不从 0 开始:{[h[0] for h in bad_start]}")
    else:
        r.ok("A2", "seq 从 0 开始")

    # ── A6:占位行不被引用为证据
    n = 0
    for table in line_id_tables(conn):
        bad = count(conn, f"""
            SELECT COUNT(*) FROM {table} t
              JOIN transcript_lines l ON l.line_id = t.line_id
             WHERE l.is_gap = 1
        """)
        if bad:
            r.fail("A6", f"{table} 有 {bad} 条引用了占位行")
        n += 1
    r.ok("A6", f"内容/归属表都没引用占位行(扫了 {n} 张带 line_id 的表)")

    if table_exists(conn, "judgments"):
        bad = count(conn, """
            SELECT COUNT(*) FROM judgments j
              JOIN json_each(j.basis_line_ids) b
              JOIN transcript_lines l ON l.line_id = b.value
             WHERE l.is_gap = 1
        """)
        if bad:
            r.fail("A6", f"basis_line_ids 有 {bad} 处指向占位行")
        else:
            r.ok("A6", "basis_line_ids 没有指向占位行")
    else:
        r.skip("A6", "judgments 表不在,basis_line_ids 查不了")


run(check, "check_frozen")

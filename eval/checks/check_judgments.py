#!/usr/bin/env python3
"""Generic implementation; local private materials are not distributed."""


from __future__ import annotations

from _common import count, run, table_exists, trigger_sql


def check(conn, r):
    if not table_exists(conn, "judgments"):
        r.skip("E1", "judgments 表不在")
        return

    # ── E1:append-only 的物理防线
    for name in ("judgments_no_update", "judgments_no_delete"):
        sql = trigger_sql(conn, name)
        if sql is None:
            r.fail("E1", f"触发器 {name} 不存在 —— 判断库不是 append-only")
        elif "RAISE(ABORT" not in sql.replace(" ", ""):
            r.fail("E1", f"触发器 {name} 没有 RAISE(ABORT)")
        else:
            r.ok("E1", f"{name} 在位")

    # ── E2:任何 system-cascade 都必须有 caused_by(§3.5.1 给的就是这条)
    n = count(conn, "SELECT COUNT(*) FROM judgments WHERE actor='system-cascade' AND caused_by IS NULL")
    if n:
        r.fail("E2", f"{n} 条级联判断没有 caused_by —— 审计链断了")
    else:
        total = count(conn, "SELECT COUNT(*) FROM judgments WHERE actor='system-cascade'")
        r.ok("E2", f"{total} 条级联判断都有回链")

    # ── E3:沿 caused_by 上溯必须终止于 actor='user'
    bad = conn.execute("""
        WITH RECURSIVE up(start, id, actor, caused_by, depth) AS (
          SELECT id, id, actor, caused_by, 0 FROM judgments WHERE actor='system-cascade'
          UNION ALL
          SELECT u.start, j.id, j.actor, j.caused_by, u.depth + 1
            FROM up u JOIN judgments j ON j.id = u.caused_by
           WHERE u.depth < 64
        )
        SELECT DISTINCT start FROM up
         WHERE start NOT IN (SELECT start FROM up WHERE actor='user')
    """).fetchall()
    if bad:
        r.fail("E3", f"这些级联判断上溯不到用户判断:{[b[0] for b in bad]}")
    else:
        r.ok("E3", "所有级联回链最终都指向一条用户判断")

    # ── E5:撤销不孤儿。
    # ⚠️ §3.5.1 的原文是「每条 action='undo' 的 caused_by 必须存在」,但 2026-08-08
    #    拍板把「被撤的那条」挪到了 undoes,caused_by 只留审计链用途。
    #    按拍板后的语义查 undoes;caused_by 的存在性由 E2/E3 管。
    orphan = count(conn, """
        SELECT COUNT(*) FROM judgments u
          LEFT JOIN judgments t ON t.id = u.undoes
         WHERE u.action='undo' AND (u.undoes IS NULL OR t.id IS NULL)
    """)
    if orphan:
        r.fail("E5", f"{orphan} 条 undo 的 undoes 为空或指向不存在的记录")
    else:
        undos = count(conn, "SELECT COUNT(*) FROM judgments WHERE action = 'undo'")
        r.ok("E5", f"{undos} 条 undo 都指向真实存在的记录")

    # ── E6:当前有效判断的 target 按 remap 链解析后必须存在。
    #        M0 只有 target_kind='line' 能查(别的对象表还不存在)。
    if not table_exists(conn, "judgment_current"):
        r.skip("E6", "judgment_current 表不在")
    else:
        kinds = [row[0] for row in conn.execute(
            "SELECT DISTINCT target_kind FROM judgment_current")]
        uncheckable = [k for k in kinds if k != "line"]
        if uncheckable:
            r.skip("E6", f"这些 target_kind 的对象表在 M0 还不存在,解析不了:{uncheckable}")
        bad = count(conn, """
            SELECT COUNT(*) FROM judgment_current c
             WHERE c.target_kind = 'line'
               AND EXISTS (
                 SELECT 1 FROM json_each(c.target_id) e
                  LEFT JOIN transcript_lines l ON l.line_id = e.value
                 WHERE l.line_id IS NULL)
        """)
        if bad:
            r.fail("E6", f"{bad} 条当前判断的 target 解析不到存在的行")
        else:
            r.ok("E6", "当前判断的 line 目标全部可解析")

    # ── §3.3.2:judgment_current 与「从 judgments 全量重放」逐行对账
    if table_exists(conn, "judgment_current"):
        replayed = replay_current(conn)
        actual = {(row["target_kind"], row["target_id"]): row["judgment_id"]
                  for row in conn.execute("SELECT * FROM judgment_current")}
        if replayed != actual:
            only_replay = {k: v for k, v in replayed.items() if actual.get(k) != v}
            only_actual = {k: v for k, v in actual.items() if replayed.get(k) != v}
            r.fail("E-current", f"物化表与全量重放对不上。重放认为 {only_replay},表里是 {only_actual}")
        else:
            r.ok("E-current", f"judgment_current 与全量重放逐行一致({len(actual)} 个目标)")


def replay_current(conn) -> dict:
    """从 judgments 全量重放推导当前状态,不看 judgment_current 一眼。

    求值规则同触发器:顺着 undo 链数长度,**偶数才有效**;当前状态 =
    id 最大的、有效的、非 undo 记录。这里用 Python 重算一遍,就是为了
    **不复用触发器那句 SQL** —— 用同一段逻辑对账,对的是它自己。
    """
    rows = conn.execute(
        "SELECT id, action, target_kind, target_id, undoes FROM judgments ORDER BY id"
    ).fetchall()
    undone_by: dict[int, list[int]] = {}
    for row in rows:
        if row["action"] == "undo" and row["undoes"] is not None:
            undone_by.setdefault(row["undoes"], []).append(row["id"])

    def chain_len(jid: int) -> int:
        n, cur = 0, jid
        while cur in undone_by:
            cur = undone_by[cur][0]
            n += 1
        return n

    out: dict = {}
    for row in rows:
        if row["action"] == "undo":
            continue
        if chain_len(row["id"]) % 2 != 0:
            continue
        key = (row["target_kind"], row["target_id"])
        if key not in out or row["id"] > out[key]:
            out[key] = row["id"]
    return out


run(check, "check_judgments")

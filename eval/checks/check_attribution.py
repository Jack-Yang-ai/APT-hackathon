#!/usr/bin/env python3
"""C1 零悬空归属 · C2 用户确认不被覆盖 · C4 幂等(§3.5.1)。

⚠️ C2 与 C4 的**原始定义是行为断言**——「跑一次自动归属,断言不变」「同一入参
连调两次,判断记录只增一条」。这两件事要真的调 assignSpeaker,而本脚本只读
DB 文件、调不了 Swift(判 8 的分工)。

所以这里查的是它们**在账本上留下的痕迹**:行为版在
`ios/GrowthAppTests/AssignSpeakerTests.swift` 里(真调入口),
这里查的是「历史上有没有发生过违反」。两者互补,都不能省。
"""
from __future__ import annotations

import json

from _common import count, person_id_tables, run, table_exists

AUTOMATIC = ("系统整理", "系统交叉验证", "声纹识别", "平台标注")


def check(conn, r):
    # ── C1:所有引用 person 的表左连 person 表
    if not table_exists(conn, "persons"):
        # ⚠️ **这条 skip 从 v14(persons 建表)起就不该再触发了。**
        # 留着它是为了让「拿一份 M0 老库来跑」时说得出原因,而不是静悄悄少一条。
        # 真跑到这儿说明**表被谁删了或改名了** —— 那时 skip 才是对的动作:
        # 它会在报告里留一行,而不是像 `else` 分支那样报个假绿。
        r.skip("C1", "schema 里没有 persons 表,person 外键无从左连 —— "
                     "v14 之后不该再走到这儿,走到了说明表被删了或改名了")
    else:
        # 🔴 **逐表查,不写死 `line_speakers` 一张。**
        # 2026-08-18 之前这里只查它一张,而上面那句注释写的是「所有引用 person 的表」
        # —— **声明比代码宽**,`voiceprints.person_id`(v14 加的真外键)一直没被查。
        # 悬空归属是本仓最贵的历史事故(旧仓实测 1979 条),
        # 新建一张带 person_id 的表却忘了加进断言,正是它重演的路径。
        tables = person_id_tables(conn)
        assert tables, "一张带 person_id 的表都没发现 —— 发现逻辑坏了,不是「没有悬空」"
        for table in tables:
            dangling = count(conn, f"""
                SELECT COUNT(*) FROM {table} t
                  LEFT JOIN persons p ON p.id = t.person_id
                 WHERE t.person_id IS NOT NULL AND p.id IS NULL
            """)
            if dangling:
                r.fail("C1", f"{table} 有 {dangling} 条指向不存在的 person")
            else:
                r.ok("C1", f"{table} 的 person 引用零悬空")

    if not table_exists(conn, "judgments"):
        r.skip("C2", "judgments 表不在")
        r.skip("C4", "judgments 表不在")
        return

    rows = conn.execute("""
        SELECT id, action, target_id, payload FROM judgments
         WHERE action IN ('assign_speaker', 'unassign_speaker')
         ORDER BY target_id, id
    """).fetchall()

    # ── C2:某个目标一旦被「用户确认」定过,后面不该再出现自动来源改动它
    by_target: dict[str, list] = {}
    for row in rows:
        by_target.setdefault(row["target_id"], []).append(row)

    violations = []
    for target, items in by_target.items():
        seen_user = False
        for row in items:
            src = (json.loads(row["payload"] or "{}") or {}).get("source")
            if seen_user and src in AUTOMATIC:
                violations.append((row["id"], target, src))
            if src == "用户确认":
                seen_user = True
    if violations:
        r.fail("C2", f"用户确认之后又被自动来源改了:{violations}")
    else:
        r.ok("C2", f"没有「用户确认被自动来源覆盖」的记录(扫了 {len(rows)} 条归属判断)")

    # ── C4:同一目标上不该出现「连续两条完全相同」的归属判断。
    #        真出现了,说明入口的幂等判定漏了(判 11:与当前状态一致才 no-op)
    dupes = []
    for target, items in by_target.items():
        for prev, cur in zip(items, items[1:]):
            if prev["payload"] == cur["payload"] and prev["action"] == cur["action"]:
                dupes.append((prev["id"], cur["id"], target))
    if dupes:
        r.fail("C4", f"同一目标上有连续重复的归属判断(幂等漏了):{dupes}")
    else:
        r.ok("C4", f"没有连续重复的归属判断(扫了 {len(by_target)} 个目标)")


run(check, "check_attribution")

#!/usr/bin/env python3
"""断言脚本自测:空库全绿,人为破坏后对应的脚本必须转红。

跑:python3 eval/checks/test_checks.py

schema fixture 由 **iOS 测试**生成(`SchemaFixtureTests`),不在这里重抄 DDL——
两份 schema 迟早分叉,而分叉的时候断言脚本还会报绿。fixture 不在就直接失败,
不跳过:一条「因为没数据所以没跑」的断言,和跑绿了长得一模一样。
"""
from __future__ import annotations

import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FIXTURE = HERE / "fixtures" / "empty.sqlite"
SCRIPTS = ["check_frozen", "check_refs", "check_source",
           "check_attribution", "check_judgments"]


def run_check(script: str, db: Path) -> tuple[int, str]:
    p = subprocess.run([sys.executable, str(HERE / f"{script}.py"), str(db)],
                       capture_output=True, text=True, cwd=HERE)
    return p.returncode, p.stdout + p.stderr


def fresh_db() -> Path:
    tmp = Path(tempfile.mkdtemp()) / "main.sqlite"
    shutil.copy(FIXTURE, tmp)
    return tmp


def seed_one_session(conn: sqlite3.Connection) -> None:
    conn.executescript("""
        INSERT INTO sessions (id, started_at, day, source, status)
          VALUES (1, '2026-08-08T14:00:00+08:00', '2026-08-08', 'recording', 'closed');
        INSERT INTO transcripts (id, session_id, version, part, asr_model, status, created_at)
          VALUES (1, 1, 1, 1, 'step-asr-v1', 'frozen', '2026-08-08T15:00:00+08:00');
        INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset, is_gap)
          VALUES (10, 1, 0, 0, 1000, '第一句', 0, 0),
                 (11, 1, 1, 1000, 2000, '〔此处缺失 5 秒〕', 3, 1);
    """)
    conn.commit()


# ── 验收① 空库全绿 ────────────────────────────────────────────────

def test_empty_db_all_green():
    db = fresh_db()
    for script in SCRIPTS:
        rc, out = run_check(script, db)
        assert rc == 0, f"{script} 在空库上就红了:\n{out}"


# ── 验收② 人为插一条悬空引用 → check_refs 非 0 ──────────────────────

def test_dangling_reference_turns_refs_red():
    db = fresh_db()
    conn = sqlite3.connect(db)
    seed_one_session(conn)
    # 关掉外键才插得进去 —— 生产里外键会挡住,这里是刻意造一条脏数据
    conn.execute("PRAGMA foreign_keys = OFF")
    conn.execute("""
        INSERT INTO line_speakers (line_id, person_id, source, updated_at)
        VALUES (999, 7, '声纹识别', '2026-08-08T16:00:00+08:00')
    """)
    conn.commit()
    conn.close()

    rc, out = run_check("check_refs", db)
    assert rc != 0, f"悬空引用没被抓到:\n{out}"
    assert "悬空" in out and "line_speakers" in out, out


# ── 每个脚本都得有牙:各造一条脏数据,确认对应脚本转红 ───────────────

def test_seq_hole_turns_frozen_red():
    db = fresh_db()
    conn = sqlite3.connect(db)
    seed_one_session(conn)
    # 直接删一行会撞 A1 的 no_delete 触发器 —— 那正是它该做的。
    # 所以换一种造洞法:插一条 seq 跳号的行。
    conn.execute("""
        INSERT INTO transcript_lines (line_id, transcript_id, seq, t_start_ms, t_end_ms, text, char_offset)
        VALUES (12, 1, 9, 2000, 3000, '跳号的一行', 10)
    """)
    conn.commit(); conn.close()

    rc, out = run_check("check_frozen", db)
    assert rc != 0, f"行序有洞没被抓到:\n{out}"
    assert "A2" in out


def test_gap_line_reference_turns_frozen_red():
    db = fresh_db()
    conn = sqlite3.connect(db)
    seed_one_session(conn)
    # 11 是占位行(is_gap=1),内容引用它就违反 A6
    conn.execute("""
        INSERT INTO summary_key_points (transcript_id, line_id, seq, text, quote)
        VALUES (1, 11, 0, '引用了占位行', '此处缺失')
    """)
    conn.commit(); conn.close()

    rc, out = run_check("check_frozen", db)
    assert rc != 0, f"引用占位行没被抓到:\n{out}"
    assert "A6" in out


def test_source_check_constraint_is_actually_enforced():
    """DDL 上的 CHECK 是活的:闭集外的取值连写都写不进去。

    这条先确认防线在。下面那条才是打 check_source 本身。
    """
    db = fresh_db()
    conn = sqlite3.connect(db)
    seed_one_session(conn)
    conn.execute("""
        INSERT INTO line_speakers (line_id, person_id, source, updated_at)
        VALUES (10, 7, '声纹识别', '2026-08-08T16:00:00+08:00')
    """)
    conn.commit()
    try:
        conn.execute("UPDATE line_speakers SET source = '瞎写的' WHERE line_id = 10")
        conn.commit()
        raise AssertionError("闭集外的 source 居然写进去了 —— DDL 上的 CHECK 没生效")
    except sqlite3.IntegrityError:
        pass
    finally:
        conn.close()


def test_missing_check_constraint_turns_source_red():
    """模拟「某一版 migration 漏了 CHECK」:check_source 必须转红。

    这才是这个脚本真正要防的事 —— 数据碰巧干净不代表防线在。
    上一版这条测试写成「先插合法值再 UPDATE 成非法值」,结果被 CHECK 拦下走了
    early return,**整条测试空跑**,看起来是绿的。
    """
    db = Path(tempfile.mkdtemp()) / "no_check.sqlite"
    conn = sqlite3.connect(db)
    # 故意写错的 schema:source 既没有 CHECK 也不是 NOT NULL。
    # 这不是在重抄生产 DDL —— 是刻意构造一个「防线漏了」的库,看脚本抓不抓得到。
    conn.executescript("""
        CREATE TABLE line_speakers (
          line_id     INTEGER PRIMARY KEY,
          person_id   INTEGER,
          cluster_tag TEXT,
          role        TEXT,
          confidence  REAL,
          source      TEXT,
          updated_at  TEXT NOT NULL
        );
        INSERT INTO line_speakers (line_id, person_id, source, updated_at)
          VALUES (10, 7, '瞎写的', '2026-08-08T16:00:00+08:00'),
                 (11, 8, NULL,     '2026-08-08T16:00:00+08:00');
    """)
    conn.commit()
    conn.close()

    rc, out = run_check("check_source", db)
    assert rc != 0, f"少了 CHECK、还写进了闭集外的值,check_source 居然是绿的:\n{out}"
    assert "A5" in out
    assert "CHECK" in out and "闭集外" in out, out


def test_an_unconditional_redact_trigger_turns_frozen_red():
    """🔴 **A1 守的是「冻结层的例外别开成后门」,而它自己一直没被验过。**

    §3.1.7 的移出记忆是**墓碑**,所以冻结层必须留一条受控的 UPDATE 通道;
    「受控」的意思是那个 BEFORE UPDATE 触发器**带 WHEN 条件**把它收窄。
    一旦它变成无条件放行,冻结层就不再冻结 —— 而**库里数据照样干净**,
    A1 会一直报绿,直到有人真的改掉一行冻结内容,那时已经不可逆。

    ⚠️ **在真 schema 上做破坏,不另造一个简化库** ——
    第一版自己写了个三列的小表,结果 `check_frozen` 撞在别的列上抛异常,
    而**抛异常会把已经收集到的结论全部丢掉**(报告在 `finish()` 才打印),
    于是测试红了、原因却不是我要考的那个。
    """
    db = fresh_db()
    conn = sqlite3.connect(db)
    sql = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='transcript_lines_no_update'"
    ).fetchone()
    assert sql, "夹具里没有 transcript_lines_no_update —— 这条测试考不了了,先修夹具"
    body = sql[0]
    assert "WHEN" in body.upper(), "夹具里的触发器本来就没有 WHEN,那 A1 现在就该是红的"
    # 把 WHEN 那一段摘掉:触发器还在、RAISE 还在,只是**不再收窄**
    conn.executescript("DROP TRIGGER transcript_lines_no_update;")
    conn.executescript(re.sub(r"WHEN.*?BEGIN", "BEGIN", body, flags=re.S | re.I))
    conn.commit()
    conn.close()

    rc, out = run_check("check_frozen", db)
    assert rc != 0, f"UPDATE 触发器没有 WHEN 条件了,check_frozen 居然是绿的:\n{out}"
    assert "A1" in out, out
    assert "后门" in out or "WHEN" in out, out


def test_a_missing_append_only_trigger_turns_judgments_red():
    """🔴 **E1 守的是判断库的物理防线,而它自己一直没被验过。**

    判断库 append-only 不是靠约定,是靠 `no_update` / `no_delete` 两个带
    `RAISE(ABORT)` 的触发器。删掉其中一个,判断从此可以被悄悄改写或删掉,
    而**审计链看起来完好** —— D5/G2 存在的全部理由就是回答「这一行为什么这么说」,
    而那个回答从此可以被人改。
    """
    db = fresh_db()
    conn = sqlite3.connect(db)
    names = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'judgments_no_%'")]
    assert names, "夹具里一个 append-only 触发器都没有 —— E1 现在就该是红的"
    conn.executescript(f"DROP TRIGGER {names[0]};")
    conn.commit()
    conn.close()

    rc, out = run_check("check_judgments", db)
    assert rc != 0, f"少了 {names[0]},check_judgments 居然是绿的:\n{out}"
    assert "E1" in out, out


def test_cascade_without_caused_by_turns_judgments_red():
    db = fresh_db()
    conn = sqlite3.connect(db)
    conn.execute("""
        INSERT INTO judgments (decided_at, actor, action, target_kind, target_id)
        VALUES ('2026-08-08T16:00:00+08:00', 'system-cascade', 'undo', 'stance', '88')
    """)
    conn.commit(); conn.close()

    rc, out = run_check("check_judgments", db)
    assert rc != 0, f"没有回链的级联判断没被抓到:\n{out}"
    assert "E2" in out


def test_current_table_out_of_sync_turns_judgments_red():
    """§3.3.2 要求的全量重放对账:物化表被人动过就必须红。"""
    db = fresh_db()
    conn = sqlite3.connect(db)
    seed_one_session(conn)
    conn.execute("""
        INSERT INTO judgments (decided_at, actor, action, target_kind, target_id)
        VALUES ('2026-08-08T16:00:00+08:00', 'user', 'accept_nomination', 'thing', '42')
    """)
    conn.commit()
    # 触发器已经把 current 填对了;这里人为改成错的
    conn.execute("UPDATE judgment_current SET judgment_id = 999")
    conn.commit(); conn.close()

    rc, out = run_check("check_judgments", db)
    assert rc != 0, f"物化表与重放不一致没被抓到:\n{out}"
    assert "E-current" in out


def test_user_confirmation_overwritten_turns_attribution_red():
    db = fresh_db()
    conn = sqlite3.connect(db)
    seed_one_session(conn)
    for actor, src in [("user", "用户确认"), ("user", "声纹识别")]:
        conn.execute("""
            INSERT INTO judgments (decided_at, actor, action, target_kind, target_id, payload)
            VALUES ('2026-08-08T16:00:00+08:00', ?, 'assign_speaker', 'line', '[10]', ?)
        """, (actor, '{"source":"%s","person_id":7,"confidence":null}' % src))
    conn.commit(); conn.close()

    rc, out = run_check("check_attribution", db)
    assert rc != 0, f"用户确认被自动来源覆盖没被抓到:\n{out}"
    assert "C2" in out


def test_dangling_person_turns_attribution_red():
    """Generic implementation; local private materials are not distributed."""






    db = fresh_db()
    conn = sqlite3.connect(db)
    seed_one_session(conn)
    # 外键在 raw sqlite3 里默认不启用,所以这条脏数据插得进去 ——
    # **而那恰恰是这条断言存在的理由**:约束可能没开、可能是后加的,
    # 数据层面的校验不能只靠 schema 声明。
    conn.execute("""
        INSERT INTO line_speakers (line_id, person_id, source, updated_at)
        VALUES (10, 99999, '声纹识别', '2026-08-18T10:00:00+08:00')
    """)
    conn.commit(); conn.close()

    rc, out = run_check("check_attribution", db)
    assert rc != 0, f"指向不存在的 person 没被抓到:\n{out}"
    assert "C1" in out


def test_every_table_with_person_id_is_checked():
    """C1 的注释写的是「**所有**引用 person 的表」—— 那就得真的是所有。

    2026-08-18 之前它只查 `line_speakers` 一张,而 `voiceprints.person_id`
    (v14 加的真外键)一直没被查 —— **声明比代码宽**。
    """
    db = fresh_db()
    conn = sqlite3.connect(db)
    seed_one_session(conn)
    conn.execute("""
        INSERT INTO voiceprints (person_id, embedding, dim, model, source,
                                 created_at, instruction_id)
        VALUES (99999, X'00', 1, 'm', 's', '2026-08-18T10:00:00+08:00', 'k')
    """)
    conn.commit(); conn.close()

    rc, out = run_check("check_attribution", db)
    assert rc != 0, f"voiceprints 里指向不存在的 person 没被抓到:\n{out}"
    assert "voiceprints" in out


# --- M2 出口达标线对撞的照妖镜(复核清单 §八:断言自己被验过吗)---------------
#
# 🔴 这三条是 2026-08-19 复核 §八 时补的。补之前 `test_m2_exit.py` **一条对照都没有**,
# 而它当天就已经悄悄失效过一次:锚点写成 `### [ ] M2-J2`(含状态标记),
# 我把那节改成 `[!]` 之后它**再也没扫过 J2,却照打 ✅**。
# 没有对照的断言 =「今天这份数据碰巧干净」—— 它可能因为锚点失配而永远绿着。

def _m2_exit_on(text: str) -> tuple[int, str]:
    """把改坏的板子写进临时文件,跑对撞脚本,拿 (退出码, 输出)。"""
    tmp = Path(tempfile.mkdtemp()) / "TASKS.md"
    tmp.write_text(text, encoding="utf-8")
    p = subprocess.run([sys.executable, str(HERE / "test_m2_exit.py"), str(tmp)],
                       capture_output=True, text=True, cwd=HERE)
    return p.returncode, p.stdout + p.stderr


def _tasks_text() -> str:
    return (HERE.parents[1] / "TASKS.md").read_text(encoding="utf-8")


def _contracts_text() -> str:
    return (HERE.parents[1] / "eval/contracts/acceptance.md").read_text(encoding="utf-8")


def _task_ids_on(text: str) -> tuple[int, str]:
    """把改坏的板子写进临时文件,跑任务号对撞,拿 (退出码, 输出)。"""
    tmp = Path(tempfile.mkdtemp()) / "TASKS.md"
    tmp.write_text(text, encoding="utf-8")
    p = subprocess.run([sys.executable, str(HERE / "test_task_ids.py"), str(tmp)],
                       capture_output=True, text=True, cwd=HERE)
    return p.returncode, p.stdout + p.stderr


def _paid_retry_on(task_queue_text: str) -> tuple[int, str]:
    """把改坏的 `TaskQueue.swift` 写进临时文件,跑付费重试对撞,拿 (退出码, 输出)。"""
    tmp = Path(tempfile.mkdtemp()) / "TaskQueue.swift"
    tmp.write_text(task_queue_text, encoding="utf-8")
    p = subprocess.run([sys.executable, str(HERE / "test_paid_retry_kinds.py"), str(tmp)],
                       capture_output=True, text=True, cwd=HERE)
    return p.returncode, p.stdout + p.stderr


def _task_queue_text() -> str:
    return (HERE.parents[1] / "ios/GrowthApp/Database/TaskQueue.swift").read_text(encoding="utf-8")


def test_paid_retry_kinds_is_green_on_the_real_tree():
    rc, out = _paid_retry_on(_task_queue_text())
    assert rc == 0, f"真仓上就红了,下面的照妖镜无意义:\n{out}"


def test_dropping_a_paid_leg_turns_paid_retry_red():
    """把 `progress` 从付费集合里拿掉 ⇒ 必须红。

    🔴 这正是 2026-08-24 之前的真实状态(`M2-审7`):`progress` 先 `call` 再 `parse`,
    却不在集合里 ⇒ 上限 290 次 / 6 天,每一次重试都真花钱。
    而在这道脚本之前,**漏掉不会有任何东西报错** —— 代价是某场次 连崩 6 天。
    """
    broken = _task_queue_text().replace('= ["extract", "progress"]', '= ["extract"]')
    assert broken != _task_queue_text(), "集合的写法变了,这条照妖镜没打中 —— 先修它"
    rc, out = _paid_retry_on(broken)
    assert rc != 0, f"拿掉一条付费腿却没红 —— 这道闸挡不住任何东西:\n{out}"
    assert "progress" in out


def test_task_ids_is_green_on_the_real_board():
    rc, out = _task_ids_on(_tasks_text())
    assert rc == 0, f"真板上就红了,下面的照妖镜无意义:\n{out}"


def test_a_duplicated_cjk_task_id_turns_task_ids_red():
    """带汉字的号(`M2-走6` 这种)撞了也必须红。

    🔴 2026-08-20 抓到:字符类原来是 `[0-9A-Za-z]+`,15 个汉字号
    (`M1-审1`…`M2-走6`)**一条都没进过这道对撞**。两个会话同时开 `M2-走6`
    不会有任何东西红 —— 而这道脚本存在的全部理由就是事故四(同号撞车)。
    """
    import re as _re
    original = "### [ ] M2-走6 合成任务\n"
    m = _re.search(r"^### \[.\] (M\d+-[\u4e00-\u9fff]+\d+)\b.*$", original, _re.M)
    assert m, "板上一条汉字号都没有了 —— 这条照妖镜的靶子没了,去掉它或换一条"
    text = original[:m.end()] + "\n\n" + m.group(0) + "(照妖镜注入的重复号)\n" + original[m.end():]
    assert text != original, "这次根本没改动 —— 「没改所以没红」与「改了但没抓到」输出一模一样"
    rc, out = _task_ids_on(text)
    assert rc != 0, f"汉字号撞了却没红 —— 这道对撞对它们是空转的:\n{out}"
    assert m.group(1) in out, f"红了,但没说是哪个号撞的:\n{out}"


def test_m2_exit_is_green_on_the_real_board():
    """先证明它在真板上是绿的 —— 否则下面两条「转红」证明不了任何东西。"""
    rc, out = _m2_exit_on(_contracts_text())
    assert rc == 0, f"真板上就红了,后面的照妖镜无意义:\n{out}"


def test_a_conflicting_number_turns_m2_exit_red():
    """在 J2 那节抄一个**与定稿对不上**的数 —— 这是它要抓的东西本身。"""
    text = _contracts_text()
    m = re.search(r"^### \[.\] M2-J2.*$", text, re.M)
    assert m, "板上找不到 M2-J2,这条照妖镜的靶子没了"
    # ⚠️ 脏数据里**不许出现正确值**。第一版把「与定稿的 40%–70% 对不上」写进了注入文本,
    # 而脚本正是在附近找那个串 —— 等于把答案抄在了脏数据里,照妖镜照的是自己。
    doctored = text[:m.end()] + "\n- 提名判准率 ≥85%(本行是照妖镜注入的伪造达标线)" + text[m.end():]
    rc, out = _m2_exit_on(doctored)
    assert rc != 0, f"抄错的达标线没被抓到 —— 这道对撞是空转的:\n{out}"
    assert "提名判准率" in out


def test_a_stale_anchor_turns_m2_exit_red():
    """把 J2 的标题改名 —— 锚点失配必须**红**,不许静默少扫一节。

    这正是 08-19 真实发生过的事:状态标记从 `[ ]` 变 `[!]`,那一节从此没被扫,
    而脚本照打 ✅。所以「找不到锚点」现在是红,不是 continue。
    """
    # 🔴 **不写状态标记**(2026-08-20 被自己咬了一次):
    # 上一版写死 `"### [!] M2-J2"`,而当天 M2-J2 从 `[!]` 变成了 `[~]` ⇒
    # 这个 replace **什么都没替换**,锚点没被破坏,自检自然不红 ——
    # **它从那一刻起就悄悄失效了**,而输出照打 PASS。
    # ⚠️ 讽刺的是被测的 `test_m2_exit.py` 自己的注释里就写着这条教训
    # (「`[ ]`/`[!]`/`[x]` 会随进度变,写进锚点等于装了个定时失效开关」)——
    # **学到的是被测者,没学到的是自检本身。**
    import re as _re
    original = _contracts_text()
    text = _re.sub(r"^### \[.\] M2-J2\b", "### [x] M2-J2改名了",
                   original, count=1, flags=_re.M)
    # 🔴 **变异式的照妖镜必须先断言变异真的发生了。**
    # 少了这一句,「什么都没改所以没红」与「改了但对撞没抓到」**在输出上一模一样** ——
    # 而上一版正是死在这里。这条断言是这次教训的落实,不是保险。
    assert text != original, ("锚点串没匹配上,这次根本没改动 —— "
                             "而「没改所以没红」与「改了但没抓到」输出一模一样")
    rc, out = _m2_exit_on(text)
    assert rc != 0, f"锚点掉了却没红 —— 这道对撞会随进度自己失效:\n{out}"
    assert "锚点" in out


def _main_worktree_fixture() -> Path | None:
    """主工作区(不是本 worktree)里那份 fixture,存在才返回。

    fixture 是 `.gitignore` 掉的**生成物**(见 .gitignore 那段注释:生成物不进版本库,
    契约 golden/ 才进),而 `git worktree add` **不复制未跟踪文件** ——
    于是每个新 worktree 天生缺它,`premerge` 天生带一条红。
    """
    common = subprocess.run(["git", "rev-parse", "--git-common-dir"],
                            cwd=HERE, capture_output=True, text=True)
    if common.returncode != 0:
        return None
    main_root = (HERE / common.stdout.strip()).resolve().parent
    if main_root == ROOT:
        return None                       # 就在主工作区里,没有别处可借
    cand = main_root / "eval" / "checks" / "fixtures" / "empty.sqlite"
    return cand if cand.exists() else None


def _run_all():
    if not FIXTURE.exists():
        # 🔴 **仍然红,不静默借用**(§3.2):借来的 fixture 是别的分支的 schema,
        # 悄悄拿它把红变绿,就是「成功地拿错东西比对了」。
        # 这里只负责把「拿不到判据」与「判据说你错了」分开说清楚,并给出最便宜的那条路。
        lines = [f"缺 schema fixture(⇒ 这不是断言失败,是**没东西可比**):{FIXTURE}"]
        borrow = _main_worktree_fixture()
        if borrow:
            lines += [
                "你在一个 worktree 里,而 fixture 是未跟踪的生成物 —— "
                "`git worktree add` 不复制它,所以这条红**不是你改坏了什么**。",
                "主工作区里有一份现成的,拷过来即可(它是生成物,拷贝合法):",
                f"  mkdir -p {FIXTURE.parent} && cp {borrow} {FIXTURE}",
                "⚠️ 拷来的是**主工作区上次跑 iOS 测试时**的 schema。"
                "你这条分支动过 Swift 侧 DDL 的话,别拷 —— 按下面重新生成。",
            ]
        lines += [
            "重新生成(权威做法,schema 只有 Swift 那一个出处):",
            "  cd ios && xcodegen generate && xcodebuild test -scheme GrowthApp "
            "-destination 'platform=iOS Simulator,name=iPhone 17'",
        ]
        print("\n".join(lines), file=sys.stderr)
        sys.exit(1)

    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL {fn.__name__}\n     {e}", file=sys.stderr)
    print(f"\n{failed} failed" if failed else f"\nall passed ({len(fns)})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    _run_all()

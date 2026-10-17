"""Generic implementation; local private materials are not distributed."""





























from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone, timedelta

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from shared import db as store  # 判 7：新仓只保留路径/连接层，三层表 API 已退役

_TZ = timezone(timedelta(hours=8))
KINDS = ("person", "subject", "jargon")
AUTO_ENROLL_MIN = 3  # 同一 surface→同一目标 证据≥3 自动定案入别名
# 代词/泛指黑名单：这些是"逐段语境解析"的活（episode 语义化的职责），进码本=全局污染
# （实翻过车：「它」差点定案成自家AI硬件的永久别名）
PRONOUN_BLACKLIST = {
    "它", "他", "她", "它们", "他们", "她们", "这个", "那个", "这些", "那些",
    "这东西", "那东西", "这玩意", "那玩意", "这产品", "该产品", "对方", "大家",
    "这边", "那边", "我们", "咱们", "你们", "自己"}

# 泛指名词名单（2026-07-29）：与 PRONOUN_BLACKLIST **分开维护**，两个维度——
#   PRONOUN_BLACKLIST = 代词/指示词，词性上就没有独立所指（「它」「这个」）；
#   GENERIC_SUBJECTS  = 有实义但只给"类"不给"个体"的头名词（「产品」「项目」「模型」）。
# 共同点是判决权都在 episode 语义化（同一段里指哪个产品，看上下文就知道）；差别是这批词
# 会**真的作为主语落进 episode_topics.subject_surface**，是待定队列的大头（产品57/项目8/
# 模型8/团队7/AI5…），所以除了写侧拦截，还要有读侧的"就近消解"通路（topics_v3.resolve_pending
# 轮2）。合成一张表会让两边的语义混掉：代词永不解析，泛指名词在 episode 内唯一锚点时要解析。
# 纪律：这里只收**真泛指**。具体产品名（Echo/潘多拉/小月听记/安克豆）不是泛指，别往里塞；
# 带第一人称限定的（我们产品/自家产品）指称唯一（就是自家那个），归 SEED_SUBJECTS 别名，也不在此。
GENERIC_SUBJECTS = {
    # 通用类名
    "产品", "项目", "系统", "设备", "团队", "公司", "模型", "方案", "功能", "东西",
    "硬件", "软件", "应用", "工具", "平台", "算法", "架构", "界面", "版本", "模块",
    "服务", "技术", "需求", "业务", "方向", "事情",
    # 泛指 AI 类名（不是具体产品名）
    "ai", "agent", "app", "大模型", "ai模型", "ai产品", "ai应用", "ai工具",
    "ai设备", "ai硬件", "ai硬件产品",
    # 限定词 + 泛指头（限定词只改指示不改泛指性）
    "本产品", "当前产品", "本项目", "当前项目", "这个项目", "该项目",
    "团队产品", "项目硬件", "产品硬件",
}


def is_generic(surface) -> bool:
    """这个表面形是不是泛指名词（不该进码本，交给 episode 就近消解）。"""
    return (surface or "").strip().strip("「」\"'").lower() in GENERIC_SUBJECTS


def _now() -> str:
    return datetime.now(_TZ).isoformat(timespec="seconds")


# ---------- 基础读写 ----------

def _attrs(row) -> dict:
    try:
        return json.loads(row or "{}")
    except json.JSONDecodeError:
        return {}


def add_entry(con, kind: str, name: str, aliases: list[str] | None = None,
              rel: str | None = None) -> int:
    assert kind in KINDS, f"kind 必须是 {KINDS}"
    # 泛指/代词永不入别名账本（全局污染，判决权在 episode 语义化）——手动通道也拦
    aliases = [a for a in (aliases or []) if not is_generic(a) and a not in PRONOUN_BLACKLIST]
    row = con.execute("SELECT id, aliases, attrs FROM entities WHERE kind=? AND name=?",
                      (kind, name)).fetchone()
    if row:
        eid = row[0]
        al = sorted(set(json.loads(row[1] or "[]")) | set(aliases or []))
        at = _attrs(row[2])
        if rel:
            at["rel"] = rel
        con.execute("UPDATE entities SET aliases=?, attrs=? WHERE id=?",
                    (json.dumps(al, ensure_ascii=False),
                     json.dumps(at, ensure_ascii=False), eid))
    else:
        at = {"rel": rel} if rel else {}
        cur = con.execute(
            "INSERT INTO entities(kind, name, aliases, attrs, created) VALUES(?,?,?,?,?)",
            (kind, name, json.dumps(aliases or [], ensure_ascii=False),
             json.dumps(at, ensure_ascii=False), _now()))
        eid = cur.lastrowid
    con.commit()
    return eid


_CACHE: dict = {}


def resolve(con, surface: str | None) -> tuple[int, str, str] | None:
    """surface → (entity_id, kind, 规范名)。只匹配不创建。
    M8b：多义 surface（挂多个词条）返回 None——不许全局定一个，判决权在 episode 语义化。"""
    if not surface:
        return None
    s = surface.strip().strip("「」\"'")
    if not s or s in ("无", "None", "null", "未知"):
        return None
    if not _CACHE:
        amb: set[str] = set()
        for eid, kind, name, aliases, attrs in con.execute(
                "SELECT id, kind, name, aliases, attrs FROM entities WHERE kind IN (?,?,?)",
                KINDS):
            for key in [name.lower()] + [a.lower() for a in json.loads(aliases or "[]")]:
                if key in _CACHE and _CACHE[key] and _CACHE[key][0] != eid:
                    amb.add(key)  # 同 surface 挂多词条=多义
                _CACHE[key] = (eid, kind, name)
            amb.update(k.lower() for k in _attrs(attrs).get("ambiguous", {}))
        for key in amb:
            _CACHE[key] = None  # 多义键置 None：resolve 拒绝全局判决，判决权在语义化
    return _CACHE.get(s.lower())


def invalidate() -> None:
    _CACHE.clear()


# 读侧泛指名单（刀C）：resolve() 命中的实体若挂着这类别名，对"查询词扩展"这个用途没有
# 区分度——扩进 terms 只会拉低检索精度，不是代词黑名单要防的"全局定案错义"问题，是另一个
# 过滤维度，故与 PRONOUN_BLACKLIST 分开维护。
_QUERY_ALIAS_GENERIC_PREFIX = ("我们", "咱们", "这个", "那个", "自家")


def expand_query_terms(con, terms: list[str]) -> list[str]:
    """只读：query 表面形扩展（刀C，读侧吃码本）。对每个 term 过 resolve()（多义 None
    跳过），命中则把该实体的规范名+别名并入候选，供检索词法面使用——不注入码本全文，
    不改 resolve 语义，只做只读查表。

    别名消毒（审计要求，库里有渲染串污染）：跳过 含"（"、含"也叫"、或长度>10 的别名
    （这类是脏拼接串，不是干净表面形）；跳过 PRONOUN_BLACKLIST；跳过以
    我们|咱们|这个|那个|自家 开头的别名（读侧泛指名单，与写侧代词黑名单不同维度）。

    截断纪律：每个命中实体最多贡献 4 条新词（优先短的——短词更可能是干净表面形）；
    本函数总新增 ≤8 条；返回值 = 与传入 terms 合并后的**全集去重**列表（调用方直接
    替换旧 terms 用，不需要再手动拼接）。

    长驻进程（如常驻 recall 服务）消费前须先调用 invalidate()，否则 resolve() 用的是
    创建/删除实体前的旧缓存。"""
    seen = list(dict.fromkeys(terms))  # 保序去重的种子集
    seen_set = set(seen)
    added = 0
    for term in terms:
        if added >= 8:
            break
        hit = resolve(con, term)
        if not hit:
            continue
        eid, kind, name = hit
        row = con.execute("SELECT aliases FROM entities WHERE id=?", (eid,)).fetchone()
        aliases = json.loads(row[0] or "[]") if row else []
        candidates = [name] + aliases
        clean = []
        for c in candidates:
            c = (c or "").strip()
            if not c or c in seen_set:
                continue
            if c in PRONOUN_BLACKLIST or is_generic(c):
                continue
            if "（" in c or "也叫" in c or len(c) > 10:
                continue
            if c.startswith(_QUERY_ALIAS_GENERIC_PREFIX):
                continue
            clean.append(c)
        clean.sort(key=len)  # 优先短的
        per_entity = 0
        for c in clean:
            if added >= 8 or per_entity >= 4:
                break
            if c in seen_set:
                continue
            seen.append(c)
            seen_set.add(c)
            per_entity += 1
            added += 1
    return seen


def prompt_block(con) -> str:
    """整本码本注入 LLM prompt（主体注册表 _registry_block 的推广）。"""
    out = []
    for kind, label in (("subject", "主体"), ("person", "人物"), ("jargon", "黑话")):
        rows = con.execute(
            "SELECT name, aliases, attrs FROM entities WHERE kind=?", (kind,)).fetchall()
        for name, aliases, attrs in rows:
            al = json.loads(aliases or "[]")
            rel = _attrs(attrs).get("rel")
            # person 里混着占位说话人（upsert_person 产物）——只有攒出别名/关系的才是码本词条
            if kind == "person" and "说话人" in name:
                continue
            if kind == "person" and not (al or rel):
                continue
            line = f"     · [{label}] {name}"
            if rel:
                line += f"（{rel}）"
            if al:
                line += f"（也叫: {'、'.join(al[:6])}）"
            out.append(line)
    # M8b 多义词条专用行：给候选+语境直方图，判决交给语义化（它看得见谁在场聊什么）
    amb: dict[str, list[str]] = {}
    for name, aliases, attrs in con.execute(
            "SELECT name, aliases, attrs FROM entities WHERE kind IN (?,?,?)", KINDS):
        a = _attrs(attrs)
        marked = set(a.get("ambiguous", {}))
        for surf in marked:
            # 义项提示 = 该词条下这个 surface 的语境直方图（别名持有者可能无 evidence 记录）
            hist = a.get("evidence", {}).get(surf, {}).get("ctx", {})
            hint = "、".join(f"{k}{v}次" for k, v in sorted(hist.items(), key=lambda x: -x[1])[:2])
            amb.setdefault(surf, []).append(f"{name}" + (f"（{hint}）" if hint else ""))
    for surf, senses in amb.items():
        out.append(f"     · [多义] {surf} = " + " | ".join(senses) +
                   " → 按本段在场人和话题判断指哪个")
    return "\n".join(out) or "     （暂无）"


# ---------- 证据累积 + 自动定案 ----------

def _other_holders(con, surface: str, except_id: int) -> list[str]:
    """这个 surface 还挂在哪些词条上（多义检测）。"""
    out = []
    for eid, name, aliases, attrs in con.execute(
            "SELECT id, name, aliases, attrs FROM entities WHERE kind IN (?,?,?)", KINDS):
        if eid == except_id:
            continue
        if surface in json.loads(aliases or "[]") or surface in _attrs(attrs).get("evidence", {}):
            out.append(name)
    return out


def add_evidence(con, surface: str, target_kind: str, target_name: str, ref: str,
                 ctx: str = "") -> None:
    """一次 surface→目标 的观察，带语境键（M8b：环位×场景，如「核心圈·工作」）。
    evidence[surface] = {"n":总次数, "refs":[...], "ctx":{语境:次数}}。
    达阈值自动入别名；**若 surface 已挂别的词条 → 标多义，两边各攒各的语境直方图，不覆盖**
    （潘多拉=手机项目|希腊神话——含义是 P(指称|词,听者,场景)，不是点映射）。"""
    if surface in PRONOUN_BLACKLIST or is_generic(surface) or len(surface) < 2:
        return  # 代词/泛指名词不进码本——语境解析是 episode 语义化的活
    row = con.execute("SELECT id, aliases, attrs FROM entities WHERE kind=? AND name=?",
                      (target_kind, target_name)).fetchone()
    if not row:
        return
    eid, aliases, attrs = row
    at = _attrs(attrs)
    ev = at.setdefault("evidence", {})
    e = ev.setdefault(surface, {"n": 0, "refs": []})
    e["n"] += 1
    if ctx:
        e.setdefault("ctx", {})[ctx] = e.get("ctx", {}).get(ctx, 0) + 1
    if ref not in e["refs"][-5:]:
        e["refs"] = (e["refs"] + [ref])[-10:]
    al = set(json.loads(aliases or "[]"))
    enrolled = False
    others = _other_holders(con, surface, eid)
    if others:
        at.setdefault("ambiguous", {})[surface] = True  # 多义标记：只给候选，判决权在语义化
        # 双向传染：既有持有者也要打标（否则先定案的一方在 resolve 缓存里仍是唯一义）
        for oid, oat_raw in con.execute(
                "SELECT id, attrs FROM entities WHERE kind IN (?,?,?)", KINDS):
            if oid == eid:
                continue
            oat = _attrs(oat_raw)
            row2 = con.execute("SELECT name, aliases FROM entities WHERE id=?", (oid,)).fetchone()
            if row2 and (surface in json.loads(row2[1] or "[]")
                         or surface in oat.get("evidence", {})):
                oat.setdefault("ambiguous", {})[surface] = True
                con.execute("UPDATE entities SET attrs=? WHERE id=?",
                            (json.dumps(oat, ensure_ascii=False), oid))
    elif e["n"] >= AUTO_ENROLL_MIN and surface not in al:
        al.add(surface)  # 唯一义 + 证据够 → 定案入别名
        enrolled = True
    con.execute("UPDATE entities SET aliases=?, attrs=? WHERE id=?",
                (json.dumps(sorted(al), ensure_ascii=False),
                 json.dumps(at, ensure_ascii=False), eid))
    con.commit()
    if enrolled:
        invalidate()
        print(f"  ✒ 定案：「{surface}」→ {target_name}（证据{e['n']}次）")
    elif others:
        print(f"  ◈ 多义：「{surface}」→ {target_name} 与 {others} 并存（各攒语境）")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["add", "import-file", "pending", "show"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--alias", action="append", default=[])
    ap.add_argument("--rel")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    con = store.connect()
    if a.cmd == "add":
        kind, name = a.args[0], a.args[1]
        eid = add_entry(con, kind, name, aliases=a.alias, rel=a.rel)
        print(f"✒ [{kind}] {name} (id={eid}) aliases={a.alias} rel={a.rel}")
    elif a.cmd == "import-file":
        n = 0
        for line in open(a.args[0], encoding="utf-8"):
            if line.strip():
                d = json.loads(line)
                add_entry(con, d["kind"], d["name"], d.get("aliases"), d.get("rel"))
                n += 1
        print(f"导入 {n} 条")
    elif a.cmd == "pending":
        for s, c in con.execute("""SELECT subject_surface, COUNT(*) FROM episode_topics
                WHERE topic_id IS NULL AND subject_surface IS NOT NULL
                GROUP BY 1 ORDER BY 2 DESC LIMIT 40"""):
            print(f"{c:4d}  {s}")
    elif a.cmd == "show":
        kinds = [a.args[0]] if a.args else list(KINDS)
        for k in kinds:
            for name, al, at in con.execute(
                    "SELECT name, aliases, attrs FROM entities WHERE kind=?", (k,)):
                d = _attrs(at)
                print(f"[{k}] {name} rel={d.get('rel','-')} aliases={al} "
                      f"evidence={list(d.get('evidence', {}).keys())[:5]}")
    con.close()

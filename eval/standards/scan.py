#!/usr/bin/env python3
"""扫判决层里的数值常量 —— 审核台与门禁闸共用的**唯一采集口**。

    python3 -m eval.standards.scan            # 打印清单
    python3 -m eval.standards.scan --json     # 给渲染器/闸用

## 为什么只有一个采集口

审核台(人看的)与 `eval/checks/test_standards.py`(闸)必须看到**同一批常量**。
两边各写一个正则,就会出现「闸说登记齐了,而审核台上少一条」——
而少的那条正好是没人审过的那条。这正是铁律 4 的形状,且对不上时不报错。

## 锚点用符号名,不用行号

行号一改动就漂,而漂了之后 manifest 指向的是**另一条常量** —— 它照样"存在",
闸照样绿。所以 `where` 一律写 `文件::符号名`。符号被改名或删掉 ⇒ 闸红,
这正是要的:改标准必须是一个显式动作。

## 收什么、不收什么

判据与判决层清单的**唯一出处是 `layers.json`**,这里只消费,不复述。
本文件只负责「把一个文件里的数值常量抠出来」这一件机械的事。
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAYERS = Path(__file__).resolve().parent / "layers.json"

# Python: 模块级 UPPER_CASE = 数值 / 数值表达式 / 数值元组
_PY = re.compile(r"^([A-Z_][A-Z0-9_]*)\s*=\s*(\(?\s*-?\d[^\n#]*?)\s*(?:#\s*(.*))?$")
# Swift: (static)? let/var 名字(: 类型)? = 数值
_SWIFT = re.compile(
    r"^\s*(?:public\s+|private\s+|fileprivate\s+|internal\s+)?(?:static\s+)?"
    r"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*[^=]+?)?\s*=\s*"
    r"(-?\d[^\n/]*?)\s*(?://\s*(.*))?$")

# 数值常量里混着的**非标准**形状:这些不是「决定什么算过」的数,是协议/身份。
# ⚠️ 这里放宽的每一条都要写理由 —— 白名单为空地放行等于闸不存在。
_SKIP_NAMES = {
    "SCHEMA_VERSION", "PROMPT_VERSION", "NORMALIZER_VERSION",  # 版本号,升级是显式动作
    "VERSION", "DB_VERSION",
}

# 计数器初始值不是标准:`var total = 0` 里的 0 是「从零开始数」,不是阈值。
# 实测这一条不加会把 `ExtractValidate.swift` 的 total/passed/pending/discarded
# 四个账本字段当成四条标准 —— 而它们改成别的值根本不合法。
_COUNTER_INIT = re.compile(r"^\s*(?:public\s+|private\s+|fileprivate\s+|internal\s+)?"
                           r"(?:static\s+)?var\s+")


def _numeric(val: str) -> bool:
    """粗筛:去掉尾注后仍以数字/负号/左括号打头,且不含明显的非数值符号。"""
    v = val.strip().rstrip(",")
    if not v or not re.match(r"^[-(]?\s*\d", v):
        return False
    # 排除字符串拼接、字典、列表推导之类
    return not any(c in v for c in ('"', "'", "[", "{"))


def _context(lines: list[str], i: int, back: int = 12) -> str:
    """Generic implementation; local private materials are not distributed."""






    out = []
    for j in range(i - 1, max(-1, i - 1 - back), -1):
        s = lines[j].strip()
        if s.startswith("#") or s.startswith("//"):
            out.append(s.lstrip("#/ ").strip())
        elif not s:
            continue                       # 空行不断开注释块,但也不带内容
        else:
            break                          # 撞到代码 ⇒ 上面那些不是这条的注释
    return "\n".join(reversed(out)).strip()


def _guess_who(ctx: str, comment: str) -> str:
    """从注释里猜「谁定的」。**只是猜** —— manifest 里那一份才是真相。

    猜错的方向是有意的:找不到证据一律归 `ai`,因为「没写出处」与
    「AI 随手定的」在后果上是同一件事 —— 都没人能检验它还成不成立。
    """
    blob = f"{ctx}\n{comment}"
    if "拍板" in blob or "用户定" in blob:
        return "user"
    if re.search(r"实测|实 ?measured|拟合|实验|测得|benchmark", blob):
        return "measured"
    return "ai"


def scan_file(path: Path) -> list[dict]:
    rel = str(path.relative_to(ROOT))
    pat = _SWIFT if path.suffix == ".swift" else _PY
    try:
        lines = path.read_text("utf-8", errors="replace").splitlines()
    except OSError as e:
        print(f"🔴 读不了 {rel}: {e}", file=sys.stderr)
        return []
    out = []
    for i, ln in enumerate(lines):
        m = pat.match(ln)
        if not m:
            continue
        name, val, comment = m.group(1), m.group(2).strip(), (m.group(3) or "").strip()
        if name in _SKIP_NAMES or not _numeric(val):
            continue
        if val.rstrip(",") == "0" and _COUNTER_INIT.match(ln):
            continue                                  # 计数器初始值,见 _COUNTER_INIT
        ctx = _context(lines, i)
        out.append({
            "where": f"{rel}::{name}",
            "file": rel, "symbol": name, "line": i + 1,
            "value": val.rstrip(","), "comment": comment,
            "context": ctx, "who_guess": _guess_who(ctx, comment),
        })
    return out


def scan() -> list[dict]:
    """按 `layers.json` 的 judged 清单扫全部判决层。"""
    cfg = json.loads(LAYERS.read_text("utf-8"))
    # 显式豁免:每条在 layers.json 里都写了理由。豁免一个不存在的路径要喊 ——
    # 否则「豁免了」和「路径打错了」长得一模一样,而后者会让那个文件**偷偷进来**。
    excl = {k for k in cfg.get("exclude", {}) if not k.startswith("_")}
    for e in excl:
        if not (ROOT / e).exists():
            print(f"🔴 exclude 里的 {e} 不存在 —— 豁免打空了", file=sys.stderr)
    found: list[dict] = []
    for entry in cfg["judged"]:
        p = ROOT / entry
        if p.is_dir():
            for f in sorted([*p.rglob("*.swift"), *p.rglob("*.py")]):
                if f.name.startswith("test") or "Tests" in f.name:
                    continue
                if str(f.relative_to(ROOT)) in excl:
                    continue
                found += scan_file(f)
        elif p.is_file():
            if entry not in excl:
                found += scan_file(p)
        else:
            # 🔴 清单指向一个不存在的路径 ⇒ 那一层**一条都没扫**,而输出看着正常。
            # 这正是「指错闸比不指更糟」:去核实的人会看到一份绿色的清单。
            print(f"🔴 layers.json 里的 {entry} 不存在 —— 这一层没被扫到", file=sys.stderr)
    return sorted(found, key=lambda x: x["where"])


def main(argv: list[str]) -> int:
    rows = scan()
    if "--json" in argv:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
        return 0
    from collections import Counter
    by_who = Counter(r["who_guess"] for r in rows)
    by_file = Counter(r["file"] for r in rows)
    print(f"判决层共 {len(rows)} 条数值常量 · {len(by_file)} 个文件")
    print(f"  猜「谁定的」:{dict(by_who)}(只是猜,manifest 里那份才算数)\n")
    for f, n in by_file.most_common():
        print(f"  {n:>3}  {f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

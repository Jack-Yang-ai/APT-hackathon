"""考卷核对总表：题目+金标+逐条证据（文件/时间戳/行号/引文）+机器核验结果。

用途（2026-07-22 用户要求）：每次跑卷前，用户人工核对题目与金标。金标错误已多次
成为最大噪声源（补4「明天」读成「今天」、C6 锚了同事的实验、N2 原题假前提、B5 金标不全），
且每次都是答错之后逐题解剖才发现——把核对前置成一张可手动校验的表。

机器先核一遍（引文在语料里逐字找）：
  ✓ 命中 → 给出精确行号，人工只需抽查；
  ⚠ 未命中 → 必须人工看（可能是引文措辞漂移/文件名缩写/证据本身是派生的）。

跑：python3 -m memory.eval.export_exam_review        # 生成 CSV + 终端摘要
产物：memory/eval/exam_review.csv（贴飞书用）
"""
from __future__ import annotations

import csv
import glob
import io
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INBOX = ROOT / "data" / "echo_corpus_v3" / "inbox"

_PUNCT = re.compile(r"[\s，。！？、,.!?；;：:「」“”\"'（）()\[\]【】…—\-~*]+")


def _norm(t: str) -> str:
    return _PUNCT.sub("", t or "")


def _resolve_file(frag: str) -> Path | None:
    """证据里的 file 字段常是缩写（'2026-06-30-echo...K0PG' / '同上'）——按可用 token 匹配。"""
    if not frag or frag.startswith("同上") or frag.startswith("memory/"):
        return None
    tokens = [t for t in re.split(r"[.…]+", frag) if len(t) >= 4]
    cands = list(INBOX.glob("*.transcript.md"))
    best = [p for p in cands if all(t in p.name for t in tokens)]
    return best[0] if len(best) == 1 else (best[0] if best else None)


_ALL_LINES: list | None = None


def _load_all_lines() -> list:
    global _ALL_LINES
    if _ALL_LINES is None:
        _ALL_LINES = []
        for f in sorted(INBOX.glob("*.transcript.md")):
            for i, l in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                _ALL_LINES.append((f.name, i, _norm(l)))
    return _ALL_LINES


def _global_find(quote: str, prefer_file: str | None = None) -> tuple[str, int] | None:
    """引文反查：出题时 file 字段常写错/写虚（凭记忆写缩写），引文才是真相。
    短引文（<8字）不做盲目全库反查（假阳性高），但两个安全通道保留：
      ① 同题兄弟证据已锚定的文件内优先找（A1 的「我98年的。」5 个字，
         兄弟证据已锚到 J179，文件内找是安全的——2026-07-22 用户指出该题被误标 ⚠）；
      ② 全库反查要求**唯一命中**才收。"""
    nq = _norm(quote)[:24]
    if not nq:
        return None
    lines = _load_all_lines()
    if len(nq) >= 8:
        hits = [(fn, i) for fn, i, nl in lines if nq in nl]
        return hits[0] if hits else None
    if prefer_file:  # 短引文通道①：限定在兄弟证据的文件内
        hits = [(fn, i) for fn, i, nl in lines if fn == prefer_file and nq in nl]
        if len(hits) == 1:
            return hits[0]
        if hits:
            return hits[0]
    hits = [(fn, i) for fn, i, nl in lines if nq in nl]  # 通道②：全库唯一命中才收
    return hits[0] if len(hits) == 1 else None


def _find_quote(path: Path, quote: str, ts: str) -> tuple[str, int | None]:
    """返回 (核验结果, 行号)。优先引文逐字（归一化后）匹配；退而求 ts 行存在。"""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except Exception:
        return "⚠ 文件读不了", None
    nq = _norm(quote)[:24]
    if nq:
        for i, l in enumerate(lines, 1):
            if nq in _norm(l):
                return "✓ 引文命中", i
    if ts:
        for i, l in enumerate(lines, 1):
            if f"[{ts}]" in l:
                return "⚠ 引文未命中·仅ts行存在", i
    return "⚠ 引文与ts都未命中", None


def main() -> None:
    rows = [["题号", "状态", "轴", "题面", "金标要点",
             "证据#", "语料文件", "时间戳", "行号", "引文原文", "机器核验", "人工核对(改这列)"]]
    warn = 0
    last_file: Path | None = None
    for f in sorted(glob.glob(str(ROOT / "memory/eval/questions_echo_*.jsonl"))):
        for line in open(f, encoding="utf-8"):
            if not line.strip():
                continue
            q = json.loads(line)
            qid = q.get("id") or q.get("qid")
            status = "退役" if q.get("retired") else (
                "弃计分" if any("弃计分" in s for s in (q.get("flags") or [])) else "计分")
            g = q.get("gold") or {}
            gold = (g.get("answer") if isinstance(g, dict) else str(g)) or ""
            evs = (g.get("evidence") or []) if isinstance(g, dict) else []
            if not evs:
                rows.append([qid, status, q.get("axis") or q.get("dim") or "",
                             q.get("question", ""), gold[:400],
                             "", "（金标无证据条目）", "", "", "", "⚠ 无证据", ""])
                warn += 1
                continue
            # 两遍处理：第一遍长引文先锚（确立本题的真实文件），第二遍短引文借它定位
            resolved: dict[int, tuple[str, int | None, str]] = {}
            q_file: str | None = None
            order = sorted(range(len(evs)),
                           key=lambda k: -len(_norm(evs[k].get("quote", ""))))
            for k in order:
                e = evs[k]
                frag = e.get("file", "")
                p = _resolve_file(frag)
                if p is None and frag.startswith("同上") and last_file is not None:
                    p = last_file
                if p is not None:
                    last_file = p
                if p is None:
                    verdict, lineno, fname = "⚠ 文件定位不到（派生层/缩写太狠）", None, frag
                else:
                    verdict, lineno = _find_quote(p, e.get("quote", ""), e.get("ts", ""))
                    fname = p.name
                if verdict.startswith("⚠"):
                    g_hit = _global_find(e.get("quote", ""), prefer_file=q_file)
                    if g_hit:
                        fname2, lineno = g_hit
                        verdict = ("✓ 引文命中" if fname2 == fname
                                   else f"✓ 引文命中·但金标file字段写错(实为{fname2})")
                        fname = fname2
                if verdict.startswith("✓") and q_file is None:
                    q_file = fname
                resolved[k] = (fname, lineno, verdict)
            for j, e in enumerate(evs, 1):
                fname, lineno, verdict = resolved[j - 1]
                if verdict.startswith("⚠"):
                    warn += 1
                rows.append([qid if j == 1 else "", status if j == 1 else "",
                             (q.get("axis") or q.get("dim") or "") if j == 1 else "",
                             q.get("question", "") if j == 1 else "",
                             gold[:400] if j == 1 else "",
                             str(j), fname, e.get("ts", ""),
                             str(lineno) if lineno else "", (e.get("quote") or "")[:120],
                             verdict, ""])
    out = ROOT / "memory/eval/exam_review.csv"
    buf = io.StringIO()
    csv.writer(buf).writerows(rows)
    out.write_text(buf.getvalue(), encoding="utf-8")
    n_q = len({r[0] for r in rows[1:] if r[0]})
    print(f"题数 {n_q} · 证据行 {len(rows)-1} · ⚠ 待人工 {warn}")
    print(f"产物 → {out}")
    for r in rows[1:]:
        if r[10].startswith("⚠"):
            print(f"  ⚠ {r[0] or '（续）'} {r[6][:40]} [{r[7]}] {r[10]}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""集中错误日志:任何后端失败追加一行到 data/errors.jsonl(+ stderr,launchd 各服务也收)。

为什么(用户:各种报错要后端记录,不然不好排查):
之前失败靠 uvicorn 偶尔把未捕获异常打 traceback + 各处散落的 print,而大量「优雅 except」
(return []/None/pass)静默吞掉,事后翻不到。统一到这一处:任何模块 `errlog.log(where, exc)`
一行,带时间/位置/异常/精简栈/上下文,可 `tail`/`grep`/`jq`。

本函数**绝不抛**(记日志失败不该把主流程再带崩)。

用法:
    from ingest import errlog
    try: ...
    except Exception as e:
        errlog.log("food_analyze", e, image_bytes=len(b64))   # 记一行,再降级
  CLI:
    python3 -m ingest.errlog            # 看最近 20 条
    python3 -m ingest.errlog --tail 50
"""
from __future__ import annotations

import json
import sys
import traceback
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ERR_PATH = ROOT / "data" / "errors.jsonl"


def log(where, exc=None, msg=None, **ctx):
    """记一条错误。where=位置标签(如 'web:/api/food/log')；exc=异常对象；msg=补充说明；
    ctx=任意上下文(date/path/…)。返回写入的 dict。绝不抛。"""
    rec = {"t": datetime.now().astimezone().isoformat(timespec="seconds"), "where": where}
    if msg:
        rec["msg"] = msg
    if exc is not None:
        rec["error"] = f"{type(exc).__name__}: {exc}"
        try:
            tb = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
            rec["trace"] = tb[-2000:]          # 留尾部最相关的栈,控体积
        except Exception:  # noqa: BLE001
            pass
    if ctx:
        rec["ctx"] = ctx
    # 1) 落盘 data/errors.jsonl
    try:
        ERR_PATH.parent.mkdir(parents=True, exist_ok=True)
        with ERR_PATH.open("a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:  # noqa: BLE001 — 记日志失败绝不影响主流程
        pass
    # 2) 同时 stderr(进各 launchd 服务 .err.log,双保险)
    try:
        print(f"⚠ [{where}] {rec.get('error') or msg or ''}", file=sys.stderr)
    except Exception:  # noqa: BLE001
        pass
    return rec


def tail(n=20):
    """读最近 n 条错误。"""
    try:
        lines = ERR_PATH.read_text().splitlines()
    except (FileNotFoundError, OSError):
        return []
    out = []
    for line in lines[-n:]:
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def main():
    import argparse
    ap = argparse.ArgumentParser(description="后端错误日志")
    ap.add_argument("--tail", type=int, default=20)
    args = ap.parse_args()
    recs = tail(args.tail)
    if not recs:
        print(f"（{ERR_PATH} 暂无错误记录）")
        return 0
    for r in recs:
        print(f"{r.get('t','?')}  [{r.get('where','?')}]  {r.get('error') or r.get('msg','')}")
        if r.get("ctx"):
            print(f"    ctx: {json.dumps(r['ctx'], ensure_ascii=False)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

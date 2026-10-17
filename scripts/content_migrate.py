#!/usr/bin/env python3
"""Offline C0 commands. Inputs come from a Mac/cloud backup, never a device."""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from shared.content_migration import ContentStage, export_snapshot


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    snapshot = commands.add_parser("snapshot")
    snapshot.add_argument("--source", type=Path, required=True)
    snapshot.add_argument("--out", type=Path, required=True)
    snapshot.add_argument("--library-id", required=True)
    snapshot.add_argument("--revision", type=int, required=True)
    for name in ("import", "report", "sources"):
        command = commands.add_parser(name)
        command.add_argument("--db", type=Path, required=True)
        if name == "import":
            command.add_argument("--export", type=Path, required=True)
        else:
            command.add_argument("--library-id", required=True)
        if name == "sources":
            command.add_argument("--query", default="")
            command.add_argument("--limit", type=int, default=12)
            command.add_argument("--include-text", action="store_true", help="Explicitly emit private source text; default prints references only")
    args = parser.parse_args()
    if args.command == "snapshot":
        result = export_snapshot(args.source, args.out, args.library_id, args.revision)
    else:
        stage = ContentStage(args.db, writable=args.command == "import")
        try:
            if args.command == "import":
                result = stage.import_snapshot(args.export)
            elif args.command == "report":
                result = stage.report(args.library_id)
            else:
                sources = stage.sources(args.library_id, args.query, args.limit)
                result = {"schema": "apt.content-staged-sources/1", "phase": "staging", "coverage": "imported_text_only", "complete": False, "sources": sources if args.include_text else [s["snapshot"] for s in sources]}
        finally:
            stage.close()
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        raise SystemExit(1)
    except sqlite3.Error:
        print(json.dumps({"error": "database_operation_failed"}), file=sys.stderr)
        raise SystemExit(1)

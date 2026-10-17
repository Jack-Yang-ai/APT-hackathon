#!/usr/bin/env python3
"""Local administrative text-authority commands; never connect to a phone."""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from shared.agent_protocol import decode
from shared.content_backend import ContentBackend, prepare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("prepare")
    init.add_argument("--directory", type=Path, required=True)
    init.add_argument("--export", type=Path, required=True)
    init.add_argument("--mac-input", type=Path)
    init.add_argument("--owner-id", default=None)
    for name in ("status", "transition", "command", "read", "query", "validate", "receipt", "checkpoint"):
        command = commands.add_parser(name)
        command.add_argument("--directory", type=Path, required=True)
        if name in ("command", "read", "validate", "receipt"):
            command.add_argument("--file", type=Path, required=True)
        if name in ("read", "query"):
            command.add_argument("--include-text", action="store_true")
        if name == "query":
            command.add_argument("--query", default="")
            command.add_argument("--namespace", default=None)
            command.add_argument("--limit", type=int, default=12)
        if name == "transition":
            command.add_argument("--operation", choices=("activate", "suspend", "resume"), required=True)
            command.add_argument("--expected-epoch", type=int, required=True)
            command.add_argument("--request-id", required=True)
        if name == "checkpoint":
            command.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        result = prepare(args.directory, args.export, args.owner_id or str(uuid.uuid4()), mac_input=args.mac_input)
    else:
        backend = ContentBackend(args.directory)
        try:
            owner = backend.meta()["owner_id"]
            if args.command == "status":
                backend.verify_baseline()
                result = backend.authority()
            elif args.command == "transition":
                result = backend.transition(owner, args.request_id, args.operation, args.expected_epoch)
            elif args.command == "checkpoint":
                result = backend.checkpoint(args.out)
            elif args.command == "command":
                result = backend.command(owner, decode("CommandEnvelope", args.file.read_bytes()))
            elif args.command == "read":
                result = backend.read(owner, decode("ContentReadRequest", args.file.read_bytes()))
                if not args.include_text:
                    result = {key: result[key] for key in ("schema", "snapshot", "authority", "semantics", "deleted")}
            elif args.command == "query":
                result = backend.query(owner, {"schema": "apt.content-query/1", "authority": backend.authority()["authority"], "namespace": args.namespace, "query": args.query, "limit": args.limit})
                if not args.include_text:
                    result["sources"] = [s["snapshot"] for s in result["sources"]]
            elif args.command == "receipt":
                result = backend.receipt(owner, decode("CommandReceiptReadRequest", args.file.read_bytes()))
            else:
                result = backend.validate_sources(owner, decode("ContentValidateRequest", args.file.read_bytes()))
        finally:
            backend.close()
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        raise SystemExit(1)
    except sqlite3.Error:
        print(json.dumps({"error": "content_database_operation_failed"}), file=sys.stderr)
        raise SystemExit(1)

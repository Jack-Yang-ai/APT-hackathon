#!/usr/bin/env python3
"""Authenticated loopback entry point for the Mac text authority."""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

from shared.agent_protocol import ProtocolError, canonical, decode, validate
from shared.content_backend import ContentBackend, ContentError

RUNTIME_FILES = ("mac/content_server.py", "shared/__init__.py", "shared/agent_protocol.py", "shared/agent_protocol/schema.json", "shared/content_backend.py", "shared/content_migration.py")


def source_fingerprint(root: Path = REPO) -> str:
    mark = hashlib.sha256()
    for relative in RUNTIME_FILES:
        mark.update(relative.encode() + b"\0" + (root / relative).read_bytes() + b"\0")
    return mark.hexdigest()


class ContentHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, directory: Path, owner_id: str, token: str, port: int):
        validate("ID", owner_id)
        if not isinstance(token, str) or len(token) < 32 or any(ord(c) > 127 for c in token):
            raise ContentError("invalid_content_access_token")
        self.directory, self.owner_id, self.token = directory, owner_id, token
        self.fingerprint = source_fingerprint()
        self.release = json.loads((REPO / "release.json").read_text()) if (REPO / "release.json").is_file() else {"commit": "working_tree"}
        if self.release.get("source_fingerprint", self.fingerprint) != self.fingerprint:
            raise ContentError("content_release_fingerprint_mismatch")
        backend = ContentBackend(directory)
        try:
            backend.check_actor(owner_id)
            backend.verify_baseline()
        finally:
            backend.close()
        super().__init__(("127.0.0.1", port), ContentHandler)


class ContentHandler(BaseHTTPRequestHandler):
    server: ContentHTTPServer
    def log_message(self, *args):
        pass  # Never print request bodies, authorization or source text.

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def reply(self, value: dict, status: int = 200):
        data = canonical(value)
        if len(data) > 1_048_576:
            data, status = canonical({"error": "response_budget_exceeded"}), 413
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        headers = self.headers.get_all("Authorization") or []
        if len(headers) != 1 or not hmac.compare_digest(headers[0].encode("utf-8"), ("Bearer " + self.server.token).encode("utf-8")):
            self.reply({"error": "unauthorized"}, 401)
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        if self.path not in ("/health", "/content/authority"):
            self.reply({"error": "route_unavailable"}, 404)
            return
        backend = None
        try:
            backend = ContentBackend(self.server.directory)
            backend.check_actor(self.server.owner_id)
            with backend.transaction():
                state = backend.authority()
            if self.path == "/health":
                state.update(pid=os.getpid(), source_fingerprint=self.server.fingerprint, source_commit=self.server.release["commit"], runtime_root=str(REPO))
            self.reply(state)
        except ContentError as error:
            self.reply({"error": error.code}, error.status)
        except Exception:
            self.reply({"error": "content_read_failed"}, 503)
        finally:
            if backend is not None:
                backend.close()

    def do_POST(self):
        if not self.authorized():
            return
        routes = {"/content/read": ("ContentReadRequest", "read"), "/content/query": ("ContentQueryRequest", "query"), "/content/validate": ("ContentValidateRequest", "validate_sources"), "/content/commands": ("CommandEnvelope", "command"), "/content/receipts": ("CommandReceiptReadRequest", "receipt")}
        if self.path not in routes:
            self.reply({"error": "route_unavailable"}, 404)
            return
        backend = None
        try:
            lengths = self.headers.get_all("Content-Length") or []
            if len(lengths) != 1 or self.headers.get("Transfer-Encoding") is not None or not lengths[0].isdigit():
                raise ContentError("invalid_content_length")
            size = int(lengths[0])
            if not 0 < size <= 1_048_576:
                raise ContentError("request_budget_exceeded", 413)
            data = self.rfile.read(size)
            if len(data) != size:
                raise ContentError("incomplete_request_body")
            kind, method = routes[self.path]
            request = decode(kind, data)
            backend = ContentBackend(self.server.directory)
            result = getattr(backend, method)(self.server.owner_id, request)
            status = {"conflict": 409, "stale": 409, "rejected": 422, "unavailable": 503}.get(result.get("state"), 200)
            self.reply(result, status)
        except ContentError as error:
            self.reply({"error": error.code}, error.status)
        except ProtocolError:
            self.reply({"error": "invalid_content_protocol"}, 400)
        except (socket.timeout, TimeoutError):
            self.reply({"error": "request_read_timeout"}, 408)
        except Exception:
            self.reply({"error": "content_operation_failed"}, 503)
        finally:
            if backend is not None:
                backend.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    server = ContentHTTPServer(Path(config["directory"]), config["owner_id"], config["token"], config["port"])
    print(json.dumps({"ready": True, "pid": os.getpid(), "port": server.server_address[1], "source_fingerprint": server.fingerprint, "source_commit": server.release["commit"]}), flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

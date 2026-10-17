#!/usr/bin/env python3
"""Publish a committed Mac text service and verify its running process/fingerprint."""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import secrets
import subprocess
import sys
import time
import urllib.request
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
from mac.content_server import RUNTIME_FILES, source_fingerprint
from shared.content_backend import ContentBackend, ContentError
from shared.content_migration import private_file

LABEL = "com.apt.content-backend"


def command(*args, check=True):
    return subprocess.run(args, cwd=REPO, text=True, capture_output=True, check=check)


def bundle(releases: Path) -> tuple[Path, str, str]:
    dirty = command("git", "status", "--porcelain", "--", *RUNTIME_FILES, "scripts/deploy_content_backend.py").stdout
    if dirty:
        raise ContentError("content_runtime_must_be_committed")
    commit = command("git", "rev-parse", "HEAD").stdout.strip()
    release = releases / commit
    release.mkdir(parents=True, mode=0o700, exist_ok=True)
    for relative in RUNTIME_FILES:
        data = subprocess.check_output(["git", "show", commit + ":" + relative], cwd=REPO)
        target = release / relative
        target.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        if target.exists():
            if target.read_bytes() != data:
                raise ContentError("content_release_changed")
        else:
            private_file(target)
            target.write_bytes(data)
            target.chmod(0o400)
    fingerprint = source_fingerprint(release)
    descriptor = release / "release.json"
    data = json.dumps({"commit": commit, "source_fingerprint": fingerprint}, sort_keys=True).encode()
    if descriptor.exists() and descriptor.read_bytes() != data:
        raise ContentError("content_release_descriptor_changed")
    if not descriptor.exists():
        private_file(descriptor)
        descriptor.write_bytes(data)
        descriptor.chmod(0o400)
    return release, commit, fingerprint


def health(config: dict):
    request = urllib.request.Request("http://127.0.0.1:" + str(config["port"]) + "/health", headers={"Authorization": "Bearer " + config["token"]})
    with urllib.request.urlopen(request, timeout=3) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--port", type=int, default=18794)
    args = parser.parse_args()
    directory = args.directory.resolve()
    backend = ContentBackend(directory)
    try:
        backend.verify_baseline()
        owner = backend.meta()["owner_id"]
    finally:
        backend.close()
    release, commit, fingerprint = bundle(directory.parent / "releases")
    args.config.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    if args.config.is_file():
        config = json.loads(args.config.read_text())
        if config["directory"] != str(directory) or config["owner_id"] != owner or config["port"] != args.port:
            raise ContentError("content_access_configuration_conflict")
    else:
        config = {"directory": str(directory), "owner_id": owner, "token": secrets.token_urlsafe(48), "port": args.port}
        private_file(args.config)
        args.config.write_text(json.dumps(config, indent=2) + "\n")
    args.config.chmod(0o600)
    agents = Path.home() / "Library/LaunchAgents"
    agents.mkdir(parents=True, exist_ok=True)
    logs = Path.home() / "Library/Logs/APT"
    logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    plist = agents / (LABEL + ".plist")
    value = {"Label": LABEL, "ProgramArguments": [sys.executable, "-u", str(release / "mac/content_server.py"), "--config", str(args.config.resolve())], "WorkingDirectory": str(release), "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10, "StandardOutPath": str(logs / (LABEL + ".log")), "StandardErrorPath": str(logs / (LABEL + ".log"))}
    if plist.exists():
        existing = plistlib.loads(plist.read_bytes())
        if existing.get("Label") != LABEL:
            raise ContentError("unrelated_launch_agent")
    plist.write_bytes(plistlib.dumps(value))
    plist.chmod(0o600)
    domain = "gui/" + str(os.getuid())
    command("launchctl", "bootout", domain + "/" + LABEL, check=False)
    command("launchctl", "bootstrap", domain, str(plist))
    running = None
    for attempt in range(20):
        try:
            running = health(config)
            if running.get("source_commit") == commit and running.get("source_fingerprint") == fingerprint and running.get("runtime_root") == str(release):
                break
        except Exception:
            pass
        time.sleep(0.25)
    else:
        raise ContentError("content_service_start_verification_failed")
    process = command("launchctl", "print", domain + "/" + LABEL).stdout
    pid = re.search(r"\bpid = (\d+)", process)
    if pid is None or int(pid[1]) != running["pid"]:
        raise ContentError("content_service_pid_mismatch")
    receipt = {"schema": "apt.content-deployment/1", "commit": commit, "source_fingerprint": fingerprint, "runtime_root": str(release), "pid": running["pid"], "label": LABEL, "status": running["status"], "authority": running["authority"], "client_sync": running["client_sync"], "port": args.port}
    target = directory / ("deployment-" + str(uuid.uuid4()) + ".json")
    private_file(target)
    target.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print(json.dumps(receipt, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # Do not echo launch environments, access tokens or private text.
        print(json.dumps({"error": str(error) if isinstance(error, ContentError) else "content_deployment_failed"}), file=sys.stderr)
        raise SystemExit(1)

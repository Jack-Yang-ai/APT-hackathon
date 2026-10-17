#!/usr/bin/env python3
"""Explicit, bounded research sessions. The phone never reads this tool's credentials."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shlex
import subprocess


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--adb", required=True)
    p.add_argument("--serial", required=True)
    sub = p.add_subparsers(dest="action", required=True)
    start = sub.add_parser("start")
    start.add_argument("--jar", required=True)
    start.add_argument("--seconds", type=int, required=True)
    start.add_argument("--chunk", type=int, default=300)
    start.add_argument("--reference", action="store_true")
    start.add_argument("--receipt", required=True)
    for action in ("status", "stop", "collect"):
        cmd = sub.add_parser(action)
        cmd.add_argument("--receipt", required=True)
        if action == "collect":
            cmd.add_argument("--output", required=True)
            cmd.add_argument("--allow-incomplete", action="store_true",
                             help="Back up a dead interrupted process; never mark pending WAVs complete.")
    a = p.parse_args()
    b = [a.adb, "-s", a.serial]

    def shell(parts):
        return subprocess.run(b + ["shell", shlex.join(parts)], check=True,
                              capture_output=True, text=True, timeout=20).stdout.strip()

    def private_directory(dev):
        if shell(["su", "0", "realpath", dev]) != dev or shell(
                ["su", "0", "stat", "-c", "%u %a", dev]) != "0 700":
            raise SystemExit("device session directory changed")

    if a.action == "start":
        if not 12 <= a.seconds <= 900 or not 5 <= a.chunk <= 300:
            raise SystemExit("duration outside research limits")
        tail = a.seconds % a.chunk or min(a.seconds, a.chunk)
        if a.reference and (min(a.seconds, a.chunk) < 10 or tail < 10):
            raise SystemExit("reference mode needs at least 10 seconds in every chunk, including the tail")
        receipt = pathlib.Path(a.receipt)
        if receipt.exists(): raise SystemExit("receipt already exists")
        state = shell(["dumpsys", "audio"])
        active = state.split("RecordActivityMonitor dump time:", 1)[1].split("Events log:", 1)[0]
        if "active? true" in active: raise SystemExit("microphone already active; do not start")
        dev = shell(["su", "0", "mktemp", "-d", "/data/local/tmp/apt-root-audio.XXXXXX"])
        if not re.fullmatch(r"/data/local/tmp/apt-root-audio\.[A-Za-z0-9]+", dev):
            raise SystemExit("unexpected device directory")
        private_directory(dev)
        digest = hashlib.sha256(pathlib.Path(a.jar).read_bytes()).hexdigest()
        # Save recovery information before launching; exclusive create avoids
        # replacing a different session's receipt or exposing it before chmod.
        with os.fdopen(os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
            json.dump({"version": 1, "serial": a.serial, "directory": dev,
                       "seconds": a.seconds, "chunkSeconds": a.chunk,
                       "reference": a.reference, "jarSHA256": digest}, f, indent=2)
        stage = shell(["mktemp", "/data/local/tmp/apt-root-audio-upload.XXXXXX"])
        try:
            subprocess.run(b + ["push", a.jar, stage], check=True, capture_output=True, timeout=30)
            shell(["su", "0", "cp", stage, dev + "/capture.jar"])
            shell(["su", "0", "chmod", "600", dev + "/capture.jar"])
            if shell(["su", "0", "sha256sum", dev + "/capture.jar"]).split()[0] != digest:
                raise SystemExit("device code checksum mismatch")
        finally:
            shell(["rm", stage])
        args = ["/system/bin/app_process", "/system/bin", "cn.apt.rootaudio.RootRecordingSession",
                dev, str(a.seconds), str(a.chunk)]
        if a.reference: args.append("reference")
        # Every path/argument is shell-quoted. No persistent start hook is created.
        script = ("umask 077; export CLASSPATH=" + shlex.quote(dev + "/capture.jar")
                  + "; nohup setsid timeout -k 5 " + str(a.seconds + 15) + " "
                  + shlex.join(args) + " >" + shlex.quote(dev + "/run.log")
                  + " 2>&1 </dev/null &")
        shell(["su", "0", "sh", "-c", script])
        print(json.dumps({"launched": True, "receipt": str(receipt), "directory": dev,
                          "note": "Confirm START with status; launch is not capture evidence."}))
        return

    receipt = json.loads(pathlib.Path(a.receipt).read_text())
    dev = receipt["directory"]
    if receipt.get("version") != 1 or receipt.get("serial") != a.serial or not re.fullmatch(
            r"/data/local/tmp/apt-root-audio\.[A-Za-z0-9]+", dev):
        raise SystemExit("receipt does not identify this device/session")
    private_directory(dev)
    if a.action == "stop":
        shell(["su", "0", "touch", dev + "/stop"])
        print("stop requested for this session")
    elif a.action == "status":
        print(shell(["su", "0", "cat", dev + "/run.log"]))
        audio = shell(["dumpsys", "audio"])
        print(audio.split("RecordActivityMonitor dump time:", 1)[1].split("Events log:", 1)[0])
        power = shell(["dumpsys", "power"])
        print("\n".join(line.strip() for line in power.splitlines() if any(
            key in line for key in ("mWakefulness=", "APT:RootRecordingResearch"))))
    else:
        # Refuse to present an ongoing recording as a completed artifact.
        try:
            result = json.loads(shell(["su", "0", "cat", dev + "/result.json"]))
        except subprocess.CalledProcessError:
            if not a.allow_incomplete: raise
            pid = shell(["su", "0", "cat", dev + "/pid"])
            if not pid.isdecimal(): raise SystemExit("invalid process identity")
            try:
                shell(["su", "0", "test", "-e", "/proc/" + pid])
            except subprocess.CalledProcessError as absent:
                if absent.returncode != 1: raise
            else:
                raise SystemExit("refuse incomplete backup while recorded PID exists")
            audio = shell(["dumpsys", "audio"])
            active = audio.split("RecordActivityMonitor dump time:", 1)[1].split("Events log:", 1)[0]
            if "active? true" in active: raise SystemExit("refuse incomplete backup during capture")
            result = None
        target = pathlib.Path(a.output)
        target.mkdir(mode=0o700, parents=True, exist_ok=False)
        with (target / "session.tar").open("wb") as f:
            subprocess.run(b + ["exec-out", "su", "0", "tar", "-C", dev, "-cf", "-", "."],
                           check=True, stdout=f, timeout=60)
        (target / "session.tar").chmod(0o600)
        (target / "collection.json").write_text(json.dumps({"finalResultPresent": result is not None,
                                                          "result": result}, indent=2))
        (target / "collection.json").chmod(0o600)
        print(json.dumps({"collected": str(target), "finalResultPresent": result is not None,
                          "result": result}))


if __name__ == "__main__": main()

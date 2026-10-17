#!/usr/bin/env python3
"""Verify only isolated research WAVs. Never extracts, uploads or transcribes audio."""
import argparse
import array
import hashlib
import io
import json
import math
import re
import sys
import tarfile
import wave


def tone_power(samples, hz, rate):
    coefficient = 2 * math.cos(2 * math.pi * hz / rate)
    first = second = 0.0
    for sample in samples:
        value = sample + coefficient * first - second
        second, first = first, value
    return max(0, first * first + second * second - coefficient * first * second)


def reference_evidence(samples, hz, rate):
    # The optional marker starts at local second 5, includes silence for 1.5s,
    # then a .75s tone. Search only its bounded expected neighborhood. Compare
    # target power both with total energy and nearby frequencies, not file size
    # or merely nonzero room noise. Thresholds are fixed before device runs.
    best = {"energyShare": 0, "peakToNearbyDb": -999, "windowAt": None}
    window = rate // 2
    for start in range(rate * 4, min(rate * 12, len(samples) - window) + 1, rate // 8):
        segment = samples[start:start + window]
        energy = sum(value * value for value in segment)
        if not energy: continue
        peak = tone_power(segment, hz, rate)
        share = 2 * peak / (window * energy)
        noise = sum(tone_power(segment, hz + delta, rate)
                    for delta in (-120, -80, -40, 40, 80, 120)) / 6
        db = 10 * math.log10(max(peak, 1) / max(noise, 1))
        if share > best["energyShare"]:
            best = {"hz": hz, "energyShare": share,
                    "peakToNearbyDb": db, "windowAt": start / rate}
    if best["energyShare"] < 0.10 or best["peakToNearbyDb"] < 20:
        raise ValueError("reference evidence below fixed thresholds: " + json.dumps(best))
    return dict(best, energyShare=round(best["energyShare"], 4),
                peakToNearbyDb=round(best["peakToNearbyDb"], 2))


def verify(archive, reason="limit", references=False):
    with tarfile.open(archive, "r:") as tar:
        members = {}
        for member in tar.getmembers():
            name = member.name.removeprefix("./") if hasattr(str, "removeprefix") else member.name.lstrip("./")
            if not member.isfile(): continue
            if "/" in name or name in members or member.size > 32 * 1024 * 1024:
                raise ValueError("unexpected research archive member")
            members[name] = member

        def read(name):
            stream = tar.extractfile(members[name])
            if stream is None: raise ValueError("missing regular member")
            with stream: return stream.read()

        session, result = json.loads(read("session.json")), json.loads(read("result.json"))
        if session["uid"] != 0 or result["sessionId"] != session["id"]:
            raise ValueError("session identity mismatch")
        if result["state"] != "stopped" or result["reason"] != reason:
            raise ValueError("session did not stop as expected")
        if any("pending" in name for name in members): raise ValueError("incomplete artifacts remain")
        receipts = sorted(name for name in members if re.fullmatch(r"chunk-\d{4}\.json", name))
        wavs = sorted(name for name in members if re.fullmatch(r"chunk-\d{4}\.wav", name))
        if len(receipts) != result["chunks"] or len(wavs) != len(receipts) or not receipts:
            raise ValueError("missing or excess committed artifacts")
        chunks, offset = [], 0
        for index, name in enumerate(receipts):
            if name != f"chunk-{index:04d}.json": raise ValueError("sequence gap")
            receipt = json.loads(read(name))
            if (receipt["index"] != index or receipt["frameOffset"] != offset
                    or receipt["sessionId"] != session["id"] or receipt["cloudEligible"] is not False):
                raise ValueError("receipt order/identity/isolation mismatch")
            raw = read(f"chunk-{index:04d}.wav")
            if len(raw) != receipt["size"] or hashlib.sha256(raw).hexdigest() != receipt["sha256"]:
                raise ValueError("content checksum/length mismatch")
            with wave.open(io.BytesIO(raw), "rb") as wav:
                if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getcomptype()) != (1, 2, 16000, "NONE"):
                    raise ValueError("unexpected PCM format")
                frames, pcm = wav.getnframes(), wav.readframes(wav.getnframes())
            expected = min(session["chunkSeconds"] * 16000, result["frames"] - offset)
            if frames != receipt["frames"] or frames != expected or len(raw) != 44 + frames * 2:
                raise ValueError("frame count/truncated WAV mismatch")
            if receipt["capturedAt"] != session["startedAt"] + offset * 1000 // 16000:
                raise ValueError("capture clock mismatch")
            report = {"index": index, "frameOffset": offset, "frames": frames,
                      "seconds": frames / 16000, "sha256": receipt["sha256"]}
            if references:
                if not result["referenceRequested"]: raise ValueError("references were not requested")
                samples = array.array("h", pcm)
                if sys.byteorder != "little": samples.byteswap()
                report["reference"] = reference_evidence(samples, (997, 1499, 1999)[index % 3], 16000)
            chunks.append(report); offset += frames
        if offset != result["frames"] or (reason == "limit" and offset != session["totalSeconds"] * 16000):
            raise ValueError("session incomplete")
        return {"verified": True, "sessionId": session["id"], "uid": session["uid"],
                "seconds": offset / 16000, "peakFrameLagMs": result["peakFrameLagMs"], "chunks": chunks}


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("archive")
    p.add_argument("--reason", choices=("limit", "requested"), default="limit")
    p.add_argument("--references", action="store_true")
    a = p.parse_args()
    print(json.dumps(verify(a.archive, a.reason, a.references), indent=2))

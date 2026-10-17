import array
import copy
import hashlib
import importlib.util
import io
import json
import math
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import wave

spec = importlib.util.spec_from_file_location("verify", pathlib.Path(__file__).parents[1] / "tools/verify.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class EvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        pcm = array.array("h", (int(8192 * math.sin(2 * math.pi * 997 * i / 16000))
                               if 6.5 * 16000 <= i < 7.25 * 16000 else 0 for i in range(12 * 16000)))
        if sys.byteorder != "little": pcm.byteswap()
        wav = io.BytesIO()
        with wave.open(wav, "wb") as out:
            out.setparams((1, 2, 16000, 0, "NONE", "")); out.writeframes(pcm.tobytes())
        cls.raw = wav.getvalue()
        cls.session = {"id": "synthetic", "uid": 0, "startedAt": 1000,
                       "chunkSeconds": 12, "totalSeconds": 12}
        cls.result = {"sessionId": "synthetic", "state": "stopped", "reason": "limit",
                      "frames": 192000, "chunks": 1, "peakFrameLagMs": 100, "referenceRequested": True}
        cls.receipt = {"sessionId": "synthetic", "index": 0, "frameOffset": 0, "frames": 192000,
                       "capturedAt": 1000, "size": len(cls.raw), "sha256": hashlib.sha256(cls.raw).hexdigest(),
                       "cloudEligible": False}

    def run_archive(self, receipt=None, result=None, raw=None, pending=False, references=False):
        members = {"session.json": json.dumps(self.session).encode(),
                   "result.json": json.dumps(result or self.result).encode(),
                   "chunk-0000.json": json.dumps(receipt or self.receipt).encode(),
                   "chunk-0000.wav": self.raw if raw is None else raw}
        if pending: members["chunk-0001.pending.wav"] = b"incomplete"
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / "evidence.tar"
            with tarfile.open(path, "w:") as tar:
                for name, data in members.items():
                    info = tarfile.TarInfo("./" + name); info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
            return verify.verify(path, references=references)

    def test_valid_synthetic_reference(self):
        self.assertEqual(self.run_archive(references=True)["seconds"], 12)

    def test_changed_audio_rejected(self):
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.run_archive(raw=self.raw[:-2] + b"xx")

    def test_gap_rejected(self):
        receipt = copy.deepcopy(self.receipt); receipt["frameOffset"] = 1
        with self.assertRaisesRegex(ValueError, "order"):
            self.run_archive(receipt=receipt)

    def test_pending_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.run_archive(pending=True)

    def test_failed_session_rejected(self):
        result = copy.deepcopy(self.result); result["state"] = "failed"
        with self.assertRaisesRegex(ValueError, "stop"):
            self.run_archive(result=result)

    def test_truncated_wav_with_new_checksum_rejected(self):
        raw = self.raw[:-2]; receipt = copy.deepcopy(self.receipt)
        receipt.update(size=len(raw), sha256=hashlib.sha256(raw).hexdigest())
        with self.assertRaisesRegex(ValueError, "frame count"):
            self.run_archive(receipt=receipt, raw=raw)

    def test_nonzero_noise_is_not_a_reference(self):
        # Deterministic broad noise must not pass because it has nonzero samples.
        state = 7; samples = array.array("h")
        for _ in range(12 * 16000):
            state = (1664525 * state + 1013904223) & 0xffffffff
            samples.append((state >> 16) - 32768)
        with self.assertRaisesRegex(ValueError, "below fixed thresholds"):
            verify.reference_evidence(samples, 997, 16000)

    def test_thresholds_use_unrounded_evidence(self):
        samples = array.array("h", [1] * 192000)
        for share, db in ((0.09996, 30), (0.2, 19.999)):
            peak = share * 8000 * 8000 / 2
            def power(segment, hz, rate):
                return peak if hz == 997 else peak / (10 ** (db / 10))
            with mock.patch.object(verify, "tone_power", side_effect=power):
                with self.assertRaisesRegex(ValueError, "below fixed thresholds"):
                    verify.reference_evidence(samples, 997, 16000)

    def test_incompatible_reference_duration_rejected_before_adb(self):
        runner = pathlib.Path(__file__).parents[1] / "tools/session.py"
        for seconds, chunk in ((30, 5), (21, 10)):
            run = subprocess.run([sys.executable, str(runner), "--adb", "/no-device-access",
                                  "--serial", "synthetic", "start", "--jar", "/not-opened",
                                  "--seconds", str(seconds), "--chunk", str(chunk), "--reference",
                                  "--receipt", "/not-written"], capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn("reference mode needs", run.stderr)


if __name__ == "__main__": unittest.main()

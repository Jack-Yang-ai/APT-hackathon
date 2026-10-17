"""离线内存队列验收:失败保留job,产物只带本人模式,不访问R2。"""
import io
import json
import unittest
from unittest.mock import patch
import numpy as np
from mac import voiceprint_daemon as d


class FakeS3:
    def __init__(self, job):
        self.objects = {d.JOB_PREFIX + "7.json": json.dumps(job).encode()}
    def list_objects_v2(self, **kw):
        return {"Contents": [{"Key": k} for k in self.objects if k.startswith(kw["Prefix"])]}
    def get_object(self, **kw):
        return {"Body": io.BytesIO(self.objects[kw["Key"]])}
    def put_object(self, **kw):
        self.objects[kw["Key"]] = kw["Body"]
    def delete_object(self, **kw):
        self.objects.pop(kw["Key"], None)


class VoiceprintDaemonTests(unittest.TestCase):
    def setUp(self):
        self.job = {"schema": 1, "model": d.MODEL_SPACE, "session": 7, "ext": "wav",
                    "lines": [{"line_id": 700+i, "block_seq": 0, "start_ms": i*4000,
                               "end_ms": (i+1)*4000, "cluster_tag": "speaker_0"} for i in range(3)]}
        rng = np.random.default_rng(122)
        self.cohort = rng.normal(size=(12, 16))
        self.cohort /= np.linalg.norm(self.cohort, axis=1, keepdims=True)
        self.me = np.zeros((1, 16)); self.me[0, 0] = 1

    def testMissingSelfTemplatesKeepsJobAndDoesNotPublishResult(self):
        s3 = FakeS3(self.job)
        with patch.object(d, "load_snapshot", return_value=({}, {})), patch.object(d, "load_cohort", return_value=self.cohort):
            r = d.run_once(s3, "fake", None, None, log=lambda _: None)
        self.assertEqual(r["failed"], 1)
        self.assertIn(d.JOB_PREFIX + "7.json", s3.objects)
        self.assertNotIn(d.OUT_PREFIX + "7.json", s3.objects)

    def testNonFiniteResultKeepsJobBeforeOutputOrDeletion(self):
        s3 = FakeS3(self.job)
        with patch.object(d, "run_job", return_value={"bad": float("nan")}):
            r = d.run_once(s3, "fake", None, None, log=lambda _: None)
        self.assertEqual(r["failed"], 1)
        self.assertNotIn(d.OUT_PREFIX + "7.json", s3.objects)
        self.assertIn("last_error", json.loads(s3.objects[d.JOB_PREFIX + "7.json"]))

    def testProductionJobCarriesSelfModeAndRealLineIDs(self):
        s3 = FakeS3(self.job); s3.objects[d.AUDIO_PREFIX + "7/block-0000.wav"] = b"fixture"
        emb = type("Embedder", (), {"embed": lambda _, samples: self.me[0]})()
        vad = type("VAD", (), {"speech_ratio": lambda _, samples: 1.0})()
        with patch.object(d, "load_snapshot", return_value=({d.SELF_ID: self.me}, {d.SELF_ID: "我"})), patch.object(d, "load_cohort", return_value=self.cohort), patch.object(d, "load_wav_16k", return_value=np.zeros(192000)):
            r = d.run_job(s3, "fake", self.job, emb, vad, log=lambda _: None)
        self.assertEqual(r["identity_mode"], "self_only")
        self.assertEqual(r["clusters"][0]["lines"], [700, 701, 702])
        self.assertTrue(all(c["verdict"].get("person_id") in [None, -1] for c in r["clusters"]))
        json.dumps(r, allow_nan=False)


if __name__ == "__main__":
    unittest.main()

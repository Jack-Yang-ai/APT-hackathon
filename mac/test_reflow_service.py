#!/usr/bin/env python3
"""Mac 侧回流服务自测。跑:python3 -m mac.test_reflow_service

分人链路是注入的:真链路依赖 torch/modelscope,只装在
`~/Desktop/录音文件/_pipeline/.venv`(CLAUDE.md §四·补),主 Python 装不了。
所以这里注入一个产出**合法 §4.3 报文**的假链路,测的是编排、schema 校验与双账。
真链路没在这儿跑过——这一点如实写在 TASKS.md M0-14 的「实际」里。
"""
from __future__ import annotations

import base64
import hashlib
import json
import struct
import tempfile
from pathlib import Path

from .enroll_ledger import EnrollLedger, LedgerCorrupt
from .r2_service import LocalStorage, ReflowService
from .reflow import Cluster, ReflowSchemaError, Span, build, validate

DIM = 192


def _emb(seed: int = 1) -> bytes:
    return struct.pack(f"<{DIM}f", *[seed * 0.01] * DIM)


def _cluster(tag="说话人1", seed=1, **over):
    kw = dict(tag=tag, spans=[Span(1200, 4300)], total_ms=3100,
              embedding=_emb(seed), embedding_dim=DIM,
              samples=[Span(12000, 17000)],
              voiceprint_match={"person_id": 7, "score": 0.83, "tier": "high"},
              gates={"media": False, "near_field_rel_db": -6.2})
    kw.update(over)
    return Cluster(**kw)


def _payload(session_id="s1", clusters=None):
    # 注意用 `is None` 而不是 `or`:`[] or [...]` 会把「刻意传空」悄悄换成默认值,
    # 那条测空 clusters 的用例就永远打不到。
    return build(session_id=session_id,
                 engine={"diarizer": "pyannote-4.0", "embedder": "campp-v2", "version": "1"},
                 blocks_covered=[{"block_seq": 0, "t0_ms": 0, "t1_ms": 300000}],
                 clusters=[_cluster()] if clusters is None else clusters)


def _service(root: Path, chain=None, executed=None):
    def default_chain(_paths, session_id):
        return _payload(session_id)

    def executor(cmd):
        (executed if executed is not None else []).append(cmd)

    return ReflowService(LocalStorage(root), root / "_work",
                         chain or default_chain, executor)


# ── §4.3 报文校验 ────────────────────────────────────────────────

def test_valid_payload_builds():
    validate(_payload())


def test_duplicate_tag_is_rejected():
    """簇是 session 级:同一个人跨块必须合成一个 tag,不能两个。"""
    _expect(ReflowSchemaError,
            lambda: _payload(clusters=[_cluster("说话人1"), _cluster("说话人1", seed=2)]),
            "重复 tag 应当被拒")


def test_missing_embedding_is_rejected():
    """少了嵌入,用户确认之后没法入底库 —— 那次确认就白做了。"""
    c = _cluster(); c.embedding = b""; c.embedding_dim = 0
    _expect(ReflowSchemaError, lambda: _payload(clusters=[c]), "缺 embedding 应当被拒")


def test_embedding_dim_mismatch_is_rejected():
    """维度写错的向量,比出来的分数是假的 —— 比缺字段更难查。"""
    c = _cluster(); c.embedding_dim = 128          # 实际还是 192 维的字节
    _expect(ReflowSchemaError, lambda: _payload(clusters=[c]), "维度对不上应当被拒")


def test_missing_samples_is_rejected():
    """少了试听切片,三档认领的中档没法交互。"""
    c = _cluster(); c.samples = []
    _expect(ReflowSchemaError, lambda: _payload(clusters=[c]), "缺 samples 应当被拒")


def test_span_with_block_seq_is_rejected():
    """spans 用场次绝对毫秒,带 block_seq 说明还在用块内相对值 —— 定位会整体偏。"""
    p = _payload()
    p["clusters"][0]["spans"][0]["block_seq"] = 0
    _expect(ReflowSchemaError, lambda: validate(p), "spans 里出现 block_seq 应当被拒")


def test_broadcast_gate_is_rejected():
    """播报闸是文本层的,Mac 不持有内容;它出现在这里说明分工错了。"""
    c = _cluster(gates={"media": False, "broadcast": True})
    _expect(ReflowSchemaError, lambda: _payload(clusters=[c]), "gates 里出现播报闸应当被拒")


def test_bad_tier_is_rejected():
    c = _cluster(voiceprint_match={"person_id": 7, "score": 0.8, "tier": "很高"})
    _expect(ReflowSchemaError, lambda: _payload(clusters=[c]), "tier 不在闭集应当被拒")


def test_empty_clusters_is_rejected():
    _expect(ReflowSchemaError, lambda: _payload(clusters=[]), "空 clusters 应当被拒")


# ── 验收①:音频进模拟 inbox,产出的 JSON 过 schema 校验 ──────────────

def test_audio_in_inbox_produces_valid_outbox_json():
    root = Path(tempfile.mkdtemp())
    LocalStorage(root).put("inbox/audio/s1/block-0000.m4a", b"fake audio bytes")

    result = _service(root).poll_once()
    assert result.sessions_done == ["s1"], result

    out = json.loads((root / "outbox" / "s1.json").read_text(encoding="utf-8"))
    validate(out)                                  # 落盘的那份必须过校验,不是内存里那份
    assert out["session_id"] == "s1"
    assert base64.b64decode(out["clusters"][0]["embedding"]["b64"]).__len__() == DIM * 4
    assert not (root / "inbox" / "audio" / "s1" / "block-0000.m4a").exists(), "处理完该把原件清掉"


def test_bad_payload_goes_to_failed_not_outbox():
    """链路产出不合契约的报文时,**不写半份到 outbox**,挪进 failed 并留错误说明。"""
    root = Path(tempfile.mkdtemp())
    LocalStorage(root).put("inbox/audio/s2/block-0000.m4a", b"x")

    def bad_chain(_paths, sid):
        p = _payload(sid)
        p["clusters"][0].pop("samples")            # 缺试听切片
        return p

    result = _service(root, chain=bad_chain).poll_once()
    assert result.sessions_failed == ["s2"], result
    assert not (root / "outbox" / "s2.json").exists(), "不合契约的报文不该出现在 outbox"
    assert (root / "failed" / "audio" / "s2" / "block-0000.m4a.error.txt").exists(), \
        "失败要留下说明,不能静默"


def test_chain_crash_is_recorded_not_swallowed():
    root = Path(tempfile.mkdtemp())
    LocalStorage(root).put("inbox/audio/s3/block-0000.m4a", b"x")

    def boom(_paths, _sid):
        raise RuntimeError("模型没装")

    result = _service(root, chain=boom).poll_once()
    assert result.sessions_failed == ["s3"]
    err = (root / "failed" / "audio" / "s3" / "block-0000.m4a.error.txt").read_text(encoding="utf-8")
    assert "模型没装" in err, err


# ── 一场多块(§1.2 ⑥ Mac 拉同一场次的全部块) ──────────────────────

def test_all_blocks_of_a_session_go_to_the_chain_in_block_order():
    """簇是 session 级的(§4.3):必须等一场的块到齐一起聚类。

    逐块聚类会让同一个人在不同块里变成不同的簇 —— 那正是 A1 要防的。
    顺序也要对:手机侧把 block_seq 补零到四位就是为了让字典序等于块序。
    """
    root = Path(tempfile.mkdtemp())
    store = LocalStorage(root)
    for seq in (10, 2, 0):                       # 故意乱序投递
        store.put(f"inbox/audio/s1/block-{seq:04d}.m4a", f"块{seq}".encode())

    seen: list[list[str]] = []

    def chain(paths, session_id):
        seen.append([p.name for p in paths])
        return _payload(session_id)

    r = _service(root, chain=chain).poll_once()
    assert r.sessions_done == ["s1"], r
    assert seen == [["block-0000.m4a", "block-0002.m4a", "block-0010.m4a"]], seen
    assert not list((root / "inbox" / "audio" / "s1").glob("*.m4a")), "处理完该把全部块清掉"


def test_two_sessions_are_processed_separately():
    root = Path(tempfile.mkdtemp())
    store = LocalStorage(root)
    store.put("inbox/audio/sA/block-0000.m4a", b"a")
    store.put("inbox/audio/sB/block-0000.m4a", b"b")
    store.put("inbox/audio/sB/block-0001.m4a", b"b2")

    sizes = {}

    def chain(paths, session_id):
        sizes[session_id] = len(paths)
        return _payload(session_id)

    r = _service(root, chain=chain).poll_once()
    assert sorted(r.sessions_done) == ["sA", "sB"], r
    assert sizes == {"sA": 1, "sB": 2}, sizes


def test_unrecognised_key_shape_raises_instead_of_being_skipped():
    """跳过一块 = 分人少了一段音频,而结果看起来完全正常。所以不跳过,炸。"""
    root = Path(tempfile.mkdtemp())
    LocalStorage(root).put("inbox/audio/s1.m4a", "旧布局:一场一个文件".encode())
    _expect(ValueError, lambda: _service(root).poll_once(), "不认识的键形状应当抛")


def test_failed_blocks_of_different_sessions_do_not_collide():
    """每场都有 block-0000.m4a。失败件只取文件名的话,第二场会把第一场覆盖掉 ——
    失败通道自己静默丢数据,比原来的失败更难查。"""
    root = Path(tempfile.mkdtemp())
    store = LocalStorage(root)
    store.put("inbox/audio/sA/block-0000.m4a", b"a")
    store.put("inbox/audio/sB/block-0000.m4a", b"b")

    def boom(_paths, sid):
        raise RuntimeError(f"{sid} 炸了")

    _service(root, chain=boom).poll_once()
    for sid in ("sA", "sB"):
        err = root / "failed" / "audio" / sid / "block-0000.m4a.error.txt"
        assert err.exists(), f"{sid} 的失败说明不见了"
        assert f"{sid} 炸了" in err.read_text(encoding="utf-8")


# ── enroll 通道:已作废(2026-08-10 铁律 2 反转) ──────────────────

def _enroll_cmd(action="enroll", person_id=7, blob=b"abc"):
    return {"action": action, "person_id": person_id,
            "embedding_sha256": hashlib.sha256(blob).hexdigest()}


def test_enroll_channel_is_disabled_and_says_why():
    """底库的唯一写方改成了手机(预研 P4 §8 第 4 条),Mac 不再执行 enroll/unenroll。

    ⚠️ 这里原本有三条测试(重放只执行一次 / 撤销后重放不复活 / 账本跨重启)——
    它们测的是**被刻意搬走的能力**,不是被放松的断言。等价覆盖现在在
    `ios/GrowthAppTests/VoiceprintRegistryTests.swift`(14 条,含 tombstone 与快照恢复)。
    留在这里的只剩一条:**通道确实死了,而且死得看得见。**

    为什么不是「静默跳过」:发指令那一方会以为写进去了。挪进 failed/ 并写清原因,
    是这个仓对「不静默降级」的一贯做法。
    """
    root = Path(tempfile.mkdtemp())
    executed: list[dict] = []
    LocalStorage(root).put("inbox/enroll/a.json", json.dumps(_enroll_cmd()).encode())

    r = _service(root, executed=executed).poll_once()

    assert executed == [], "底库被 Mac 写了 —— 铁律 2 反转之后它不该再执行任何 enroll"
    assert r.enroll_executed == []
    assert len(r.enroll_skipped) == 1, r
    err = root / "failed" / "enroll" / "a.json.error.txt"
    assert err.exists(), "指令必须留下说明,不能静默丢掉"
    assert "铁律 2 反转" in err.read_text(encoding="utf-8")


def test_disabled_channel_also_refuses_unenroll():
    """撤销也不执行 —— 半边通道比整条死掉更危险:
    能撤不能加(或反过来)会让两侧底库悄悄分叉。"""
    root = Path(tempfile.mkdtemp())
    executed: list[dict] = []
    LocalStorage(root).put("inbox/enroll/b.json",
                           json.dumps(_enroll_cmd("unenroll")).encode())
    r = _service(root, executed=executed).poll_once()
    assert executed == []
    assert r.enroll_executed == []


def test_corrupt_ledger_refuses_to_run():
    """账本读不出来时**不能当空账跑** —— 那等于把所有指令重放一遍。"""
    root = Path(tempfile.mkdtemp())
    (root / "_work").mkdir(parents=True, exist_ok=True)
    (root / "_work" / "enroll_ledger.json").write_text("{半截", encoding="utf-8")
    _expect(LedgerCorrupt, lambda: _service(root), "坏账本应当拒绝启动")


def test_unknown_action_is_not_executed():
    root = Path(tempfile.mkdtemp())
    executed: list[dict] = []
    LocalStorage(root).put("inbox/enroll/x.json",
                           json.dumps({"action": "把底库删了", "person_id": 7}).encode())
    r = _service(root, executed=executed).poll_once()
    assert executed == [], "未知指令不该被执行"
    assert r.enroll_executed == []


def test_malformed_enroll_json_goes_to_failed():
    root = Path(tempfile.mkdtemp())
    LocalStorage(root).put("inbox/enroll/bad.json", b"{ not json")
    _service(root).poll_once()
    assert (root / "failed" / "enroll" / "bad.json.error.txt").exists()


def _expect(exc, fn, msg):
    try:
        fn()
    except exc:
        return
    raise AssertionError(msg)


def _run_all():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"PASS {fn.__name__}")
    print(f"all passed ({len(fns)})")


if __name__ == "__main__":
    _run_all()

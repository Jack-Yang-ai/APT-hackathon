"""Generic implementation; local private materials are not distributed."""














from __future__ import annotations

import base64
import json
from dataclasses import dataclass, field
from typing import Any

SCHEMA_VERSION = "growth.reflow/1"

# 三档认领(PRD §4.4.10)。tier 是闭集,写别的值下游没法判。
TIERS = ("high", "mid", "low")


class ReflowSchemaError(ValueError):
    """报文不合 §4.3。抛出去,不要写半份。"""


@dataclass
class Span:
    t0_ms: int
    t1_ms: int

    def as_dict(self) -> dict[str, int]:
        return {"t0_ms": self.t0_ms, "t1_ms": self.t1_ms}


@dataclass
class Cluster:
    tag: str
    spans: list[Span]
    total_ms: int
    embedding: bytes                      # f32 向量的原始字节
    embedding_dim: int
    samples: list[Span]                   # 试听切片
    voiceprint_match: dict | None = None
    gates: dict = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "tag": self.tag,
            "spans": [s.as_dict() for s in self.spans],
            "total_ms": self.total_ms,
            "embedding": {
                "dim": self.embedding_dim,
                "dtype": "f32",
                "b64": base64.b64encode(self.embedding).decode("ascii"),
            },
            "samples": [s.as_dict() for s in self.samples],
            "voiceprint_match": self.voiceprint_match,
            "gates": self.gates,
        }


def build(session_id: str, engine: dict, blocks_covered: list[dict],
          clusters: list[Cluster]) -> dict:
    payload = {
        "schema": SCHEMA_VERSION,
        "session_id": session_id,
        "engine": engine,
        "blocks_covered": blocks_covered,
        "clusters": [c.as_dict() for c in clusters],
    }
    validate(payload)
    return payload


def validate(payload: dict) -> None:
    """按 §4.3 逐条查。查不过就抛,不返回「大概能用」。"""
    for key in ("schema", "session_id", "engine", "blocks_covered", "clusters"):
        if key not in payload:
            raise ReflowSchemaError(f"缺顶层字段 {key}")
    if payload["schema"] != SCHEMA_VERSION:
        raise ReflowSchemaError(f"schema 必须是 {SCHEMA_VERSION},实际 {payload['schema']!r}")
    for key in ("diarizer", "embedder", "version"):
        if key not in payload["engine"]:
            raise ReflowSchemaError(f"engine 缺 {key} —— 换了模型却认不出来,历史结果就不可比")

    seen_blocks = set()
    for b in payload["blocks_covered"]:
        for key in ("block_seq", "t0_ms", "t1_ms"):
            if key not in b:
                raise ReflowSchemaError(f"blocks_covered 缺 {key}: {b}")
        if b["block_seq"] in seen_blocks:
            raise ReflowSchemaError(f"block_seq {b['block_seq']} 重复")
        seen_blocks.add(b["block_seq"])

    if not payload["clusters"]:
        raise ReflowSchemaError("clusters 为空 —— 一个簇都没有就别回流,让手机保持「未分人」")

    tags = set()
    for c in payload["clusters"]:
        tag = c.get("tag")
        if not tag:
            raise ReflowSchemaError(f"簇缺 tag: {c}")
        if tag in tags:
            raise ReflowSchemaError(
                f"tag {tag!r} 重复 —— 簇是 session 级的,同一个人跨块必须合成一个")
        tags.add(tag)

        if not c.get("spans"):
            raise ReflowSchemaError(f"簇 {tag} 没有 spans")
        for s in c["spans"] + c.get("samples", []):
            if "t0_ms" not in s or "t1_ms" not in s:
                raise ReflowSchemaError(f"簇 {tag} 的区间缺 t0_ms/t1_ms: {s}")
            if s["t1_ms"] <= s["t0_ms"]:
                raise ReflowSchemaError(f"簇 {tag} 有非正长度的区间: {s}")
            # block_seq 不参与定位:区间必须是场次内绝对毫秒,越界说明还在用块内相对值
            if "block_seq" in s:
                raise ReflowSchemaError(
                    f"簇 {tag} 的区间里出现了 block_seq —— spans 用场次绝对毫秒,不带块号")

        emb = c.get("embedding")
        if not emb or "b64" not in emb or "dim" not in emb:
            raise ReflowSchemaError(
                f"簇 {tag} 缺 embedding —— 用户确认之后没法入声纹底库,这次确认就白做了")
        # dim 必须为正:dim=0 配空 b64 时,下面那条长度校验(0 == 0*4)恰好成立,
        # 空嵌入会一路混过去 —— 而空嵌入正是这条校验要拦的那种情况。
        if not isinstance(emb["dim"], int) or emb["dim"] <= 0:
            raise ReflowSchemaError(f"簇 {tag} 的 embedding dim 必须是正整数,实际 {emb['dim']!r}")
        if not emb["b64"]:
            raise ReflowSchemaError(f"簇 {tag} 的 embedding 是空的")
        if emb.get("dtype") != "f32":
            raise ReflowSchemaError(f"簇 {tag} 的 embedding dtype 必须是 f32")
        raw = base64.b64decode(emb["b64"])
        if len(raw) != emb["dim"] * 4:
            raise ReflowSchemaError(
                f"簇 {tag} 的 embedding 长度对不上:dim={emb['dim']} 应为 {emb['dim']*4} 字节,"
                f"实际 {len(raw)} —— 维度写错的向量比对出来的分数是假的")

        if not c.get("samples"):
            raise ReflowSchemaError(
                f"簇 {tag} 缺 samples —— 用户没法试听 5 秒再决定,三档认领的中档就废了")

        vm = c.get("voiceprint_match")
        if vm is not None:
            if vm.get("tier") not in TIERS:
                raise ReflowSchemaError(f"簇 {tag} 的 tier 不在闭集 {TIERS}:{vm.get('tier')!r}")
            if "person_id" not in vm or "score" not in vm:
                raise ReflowSchemaError(f"簇 {tag} 的 voiceprint_match 缺 person_id/score")

        gates = c.get("gates", {})
        if "media" not in gates:
            raise ReflowSchemaError(f"簇 {tag} 的 gates 缺 media")
        # 播报闸是文本层的,在手机/云代理跑(§4.4);它出现在这里说明分工错了
        if any(k.startswith("broadcast") for k in gates):
            raise ReflowSchemaError(
                f"簇 {tag} 的 gates 里出现了播报闸 —— 那是文本层判定,Mac 不持有内容")


def dumps(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2)

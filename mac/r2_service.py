"""Mac 侧常驻服务:轮询 `inbox/` → 跑分人链路 → 按 §4.3 写 `outbox/`。

拓扑(§1.1):手机只写 `inbox/`,Mac 只读 `inbox/`、只写 `outbox/`。
Mac **不持有内容**,只出分人结果;内容与判断的唯一写方是手机(铁律 1)。

两件刻意的事:

  · **存储做成接口。** 生产是 R2(S3 兼容),验收用本地目录当模拟 inbox。
    两者跑的是同一段编排代码 —— 若测试走另一条分支,测的就不是生产那条路。
  · **分人链路是注入进来的。** 真链路(`mac/diarize.py` 等)依赖 torch/modelscope,
    只装在 `~/Desktop/录音文件/_pipeline/.venv`(见 CLAUDE.md §四·补),
    主 Python 装不了也不该装。注入之后,编排逻辑能脱开重依赖单独测。

失败不静默:一条会话处理失败就把它挪进 `failed/` 并留下错误文件,**不删原件、
不假装处理过**。下次轮询不会再捡它,但它在账面上看得见。
"""
from __future__ import annotations

import json
import time
import traceback
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from .enroll_ledger import EnrollLedger
from .reflow import ReflowSchemaError, dumps, validate


class Storage(Protocol):
    """中转存储。R2 与本地目录都实现它,编排代码只认这个口。"""
    def list(self, prefix: str) -> list[str]: ...
    def get(self, key: str) -> bytes: ...
    def put(self, key: str, data: bytes) -> None: ...
    def delete(self, key: str) -> None: ...


class LocalStorage:
    """本地目录当 R2 用。验收的「模拟 inbox」就是它。"""

    def __init__(self, root: Path):
        self.root = Path(root)

    def _p(self, key: str) -> Path:
        return self.root / key

    def list(self, prefix: str) -> list[str]:
        base = self._p(prefix)
        if not base.exists():
            return []
        return sorted(str(p.relative_to(self.root)) for p in base.rglob("*") if p.is_file())

    def get(self, key: str) -> bytes:
        return self._p(key).read_bytes()

    def put(self, key: str, data: bytes) -> None:
        p = self._p(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)

    def delete(self, key: str) -> None:
        self._p(key).unlink(missing_ok=True)


class R2Storage:
    """Cloudflare R2(S3 兼容)。凭证从环境变量取,不落代码、不落日志。"""

    def __init__(self, bucket: str, account_id: str, access_key: str, secret_key: str):
        import boto3
        self.bucket = bucket
        self.client = boto3.client(
            "s3",
            endpoint_url=f"https://{account_id}.r2.cloudflarestorage.com",
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            region_name="auto",
        )

    def list(self, prefix: str) -> list[str]:
        out, token = [], None
        while True:
            kw = {"Bucket": self.bucket, "Prefix": prefix}
            if token:
                kw["ContinuationToken"] = token
            resp = self.client.list_objects_v2(**kw)
            out += [o["Key"] for o in resp.get("Contents", [])]
            if not resp.get("IsTruncated"):
                return sorted(out)
            token = resp["NextContinuationToken"]

    def get(self, key: str) -> bytes:
        return self.client.get_object(Bucket=self.bucket, Key=key)["Body"].read()

    def put(self, key: str, data: bytes) -> None:
        self.client.put_object(Bucket=self.bucket, Key=key, Body=data)

    def delete(self, key: str) -> None:
        self.client.delete_object(Bucket=self.bucket, Key=key)


# ⚠️ 键布局的另一侧是 `ios/GrowthApp/Upload/R2Layout.swift`。两个运行时共用不了常量,
# 所以**两边各有一条测试钉住同一个字面量**;改这里就要改那边,改不动就让测试红着。
AUDIO_PREFIX = "inbox/audio/"      # inbox/audio/<session_id>/block-NNNN.<ext>
ENROLL_PREFIX = "inbox/enroll/"

# 分人链路:输入**一场的全部块**(本地路径,已按块序排好)与 session_id,
# 输出 §4.3 的 payload dict。簇是 session 级的,所以进来的是一个列表不是一个文件。
DiarizeChain = Callable[[list[Path], str], dict]
# 真实现依赖 torch/modelscope,注入进来才能脱开重依赖测编排。

# enroll 执行器:真正写声纹底库的那一步(mac/enroll.py)。同样注入。
EnrollExecutor = Callable[[dict], None]


@dataclass
class PollResult:
    sessions_done: list[str]
    sessions_failed: list[str]
    enroll_executed: list[str]
    enroll_skipped: list[tuple[str, str]]   # (指令 id, 为什么跳过)


class ReflowService:
    def __init__(self, storage: Storage, workdir: Path,
                 chain: DiarizeChain, enroll_executor: EnrollExecutor):
        self.storage = storage
        self.workdir = Path(workdir)
        self.chain = chain
        self.enroll_executor = enroll_executor
        self.ledger = EnrollLedger(self.workdir / "enroll_ledger.json")

    # ── 一轮 ────────────────────────────────────────────────────

    def poll_once(self) -> PollResult:
        result = PollResult([], [], [], [])
        # enroll 先于音频:用户刚确认的归属应当尽快进底库,后面那场分人才用得上
        self._process_enroll(result)
        self._process_audio(result)
        return result

    def run_forever(self, interval_sec: float = 30.0) -> None:
        while True:
            try:
                self.poll_once()
            except Exception:                      # noqa: BLE001
                # 一轮炸了不能让常驻服务死掉,但**必须留下痕迹**,不吞
                traceback.print_exc()
            time.sleep(interval_sec)

    # ── enroll / unenroll ──────────────────────────────────────

    def _process_enroll(self, result: PollResult) -> None:
        """⚠️ **这条通道已经作废(2026-08-10,铁律 2 反转)。**

        底库的唯一写方从 Mac 改成了手机(预研 P4 §8 第 4 条,CLAUDE.md §3.1)。
        手机不再往 `inbox/enroll/` 投指令,所以正常情况下这里一条都不该有。

        代码没删(P4 §8:M0-14「代码不必推翻」),但**必须停止执行** ——
        留一个还在写底库的执行器,就等于铁律 2 说的「唯一写方」旁边还架着第二个。
        真来了指令就挪进 `failed/` 并说清为什么,**不静默跳过**:
        静默跳过之后,发指令那一方会以为写进去了。
        """
        for key in self.storage.list(ENROLL_PREFIX):
            # 先记账再挪走:`_fail` 会把原件删掉,顺序反了就拿不到 key 了。
            result.enroll_skipped.append((key, "通道已作废(铁律 2 反转,写方是手机)"))
            self._fail(key, "enroll 通道已作废(2026-08-10 铁律 2 反转):"
                            "声纹底库的唯一写方是手机,Mac 不再执行 enroll/unenroll。"
                            "这条指令**没有被执行** —— 请在手机上完成确认/撤销。")
        return

    def _process_enroll_legacy(self, result: PollResult) -> None:
        """反转之前的实现,保留作参照。**不再被调用。** """
        for key in self.storage.list(ENROLL_PREFIX):
            try:
                cmd = json.loads(self.storage.get(key))
            except Exception as e:                 # noqa: BLE001
                self._fail(key, f"enroll 指令不是合法 JSON:{e}")
                continue

            cmd_id = EnrollLedger.instruction_id(cmd)
            decision = self.ledger.decide(cmd)
            if not decision.execute:
                # 跳过也要**记下来为什么**。静默跳过和执行成功在日志里长得一样。
                result.enroll_skipped.append((cmd_id, decision.reason))
                self.storage.delete(key)
                continue

            self.enroll_executor(cmd)
            self.ledger.record(cmd)                # 执行成功了才记账
            result.enroll_executed.append(cmd_id)
            self.storage.delete(key)

    # ── 音频 → 分人 → outbox ───────────────────────────────────

    def _process_audio(self, result: PollResult) -> None:
        """一场的**全部块**一起拉下来再跑分人(§1.2 ⑥)。

        ⚠️ 这里原先是「一个 key = 一场」(`session_id = Path(key).stem`),与
        §1.2 ⑥「Mac 拉同一场次的**全部块**」和 §3.1.6「5 分钟分段是为了断电不丢与
        **边录边传**」都对不上 —— 一场一个文件的话不录完就没法拼,边录边传不成立。
        2026-08-10 手机侧上传层(M0-7)按文档实现,这一侧跟着改正。

        簇是 **session 级**的(§4.3):必须等一场的块到齐一起聚类,
        逐块聚类会让同一个人在不同块里变成不同的簇 —— 那正是 A1 要防的。
        """
        for session_id, keys in sorted(self._sessions_in_inbox().items()):
            local_dir = self.workdir / "audio" / session_id
            local_dir.mkdir(parents=True, exist_ok=True)
            locals_: list[Path] = []
            try:
                for key in keys:
                    p = local_dir / Path(key).name
                    p.write_bytes(self.storage.get(key))
                    locals_.append(p)
                payload = self.chain(locals_, session_id)
                validate(payload)                  # 组装不出合法报文就别写出去
                self.storage.put(f"outbox/{session_id}.json",
                                 dumps(payload).encode("utf-8"))
                for key in keys:
                    self.storage.delete(key)
                result.sessions_done.append(session_id)
            except ReflowSchemaError as e:
                self._fail_session(keys, f"回流报文不合 §4.3:{e}")
                result.sessions_failed.append(session_id)
            except Exception as e:                 # noqa: BLE001
                self._fail_session(keys, f"分人链路失败:{e}\n{traceback.format_exc()}")
                result.sessions_failed.append(session_id)

    def _sessions_in_inbox(self) -> dict[str, list[str]]:
        """`inbox/audio/<session_id>/block-NNNN.<ext>` → {session_id: [key, …]}。

        块清单按**字典序**排,而手机侧把 block_seq 补零到四位正是为了让字典序
        等于块序(§3.1.6 结果按 block_seq 排序拼接)。前缀底下出现不认识的形状
        **不静默跳过**:跳过一块,分人就少了一段音频,而结果看起来完全正常。
        """
        out: dict[str, list[str]] = {}
        for key in self.storage.list(AUDIO_PREFIX):
            rest = key[len(AUDIO_PREFIX):]
            if rest.count("/") != 1 or not rest.split("/")[1]:
                raise ValueError(
                    f"{AUDIO_PREFIX} 底下出现了不认识的键:{key!r}。"
                    f"约定是 {AUDIO_PREFIX}<session_id>/block-NNNN.<ext>"
                    f"(另一侧是 ios/GrowthApp/Upload/R2Layout.swift)。"
                    f"跳过它就等于分人少了一段音频,而结果看起来完全正常")
            session_id, _ = rest.split("/")
            out.setdefault(session_id, []).append(key)
        return {sid: sorted(keys) for sid, keys in out.items()}

    def _fail_session(self, keys: list[str], why: str) -> None:
        for key in keys:
            self._fail(key, why)

    def _fail(self, key: str, why: str) -> None:
        """失败的原件挪进 failed/ 并附一份错误说明。

        **不删原件、不假装处理过**:下次轮询不会再捡它,但它在账面上看得见。
        旧仓最贵的事故形态就是「成功地写进了错的地方」,静默丢单是它的近亲。
        """
        # ⚠️ 保留 `inbox/` 底下的相对路径,**不能只取文件名**:
        # 一场多块之后每场都有 `block-0000.m4a`,只取文件名的话第二场的失败
        # 会把第一场的覆盖掉 —— 失败通道自己在静默丢数据,比原来的失败更难查。
        rest = key[len("inbox/"):] if key.startswith("inbox/") else key
        try:
            self.storage.put(f"failed/{rest}", self.storage.get(key))
        except Exception:                          # noqa: BLE001
            pass
        self.storage.put(f"failed/{rest}.error.txt", why.encode("utf-8"))
        self.storage.delete(key)

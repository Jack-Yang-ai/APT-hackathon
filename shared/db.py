#!/usr/bin/env python3
"""极简数据层:仓库根路径 + SQLite 连接。

**这个文件是「判 7 那笔债在新仓零风险还掉」的产物。**

旧仓的 `memory/store.py` 里混着两样东西:① 路径/连接/WAL 设置(所有人依赖)
② 三层存储(events/atoms/topics)的建表迁移与读写 API(约 150 行,随旧组织层退役)。
在旧仓拆它要动 51 个文件,所以判 7 定「一期不拆」;但新仓**根本不需要 ② **——
新架构的内容库在手机上(Swift/SQLite),Mac 侧只剩声纹底库与派生工件。
于是这里只保留 ①,一次拆干净。

Mac 侧在新架构里的边界(技术方案 §1.1 铁律):
- **不写内容库**。分人结果写成 JSON 经中转存储回流,由手机走唯一归属入口合并。
- 本文件的 connect() 只服务 Mac 自己的本地工件库(声纹索引、簇缓存一类),
  **不是**产品的内容库。
"""
from __future__ import annotations

import os
import sqlite3
from pathlib import Path

# 仓库根(shared/ 的上一级)
ROOT = Path(__file__).resolve().parent.parent

# Mac 侧本地工件库。与产品内容库无关——内容库在手机上。
DB = Path(os.environ.get("GROWTH_MAC_DB") or (ROOT / "data" / "mac_artifacts.sqlite"))


def connect() -> sqlite3.Connection:
    """连接 Mac 侧工件库。不建任何三层表——那些随旧组织层退役了。"""
    DB.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA foreign_keys=ON")
    return con


# ── 旧 API 的显式墓碑 ────────────────────────────────────────────────
#
# vp_rematch / recluster 从旧仓搬来时带着这两个调用。它们在旧架构里直接写库的
# persons/entities 表;**新架构下 Mac 不持有人物表**,这个行为不成立。
#
# 留成会抛异常的桩,而不是删掉或悄悄改成 no-op——按「失败必须可见」的纪律:
# 一旦有人沿旧路径调用,当场炸,不会静默写错地方。
# (旧仓踩过的坑:成功地写进了错的表,exit code 全绿,94% 落错层。)
#
# 改造方向(技术方案 §4.3):算法保留,写库改成**输出结果 JSON**,由手机合并。

class MacDoesNotOwnContent(RuntimeError):
    """Mac 侧试图写内容库——架构上不允许。"""


def upsert_person(con, name: str) -> int:
    raise MacDoesNotOwnContent(
        f"upsert_person({name!r}):Mac 不写内容库(技术方案 §1.1 铁律)。"
        "把结果输出成 JSON 回流,由手机走唯一归属入口 assignSpeaker 合并。"
    )


def merge_entities(con, keep_id: int, drop_id: int) -> None:
    raise MacDoesNotOwnContent(
        "merge_entities:同上。人物合并是用户判断,必须经手机的判断库留痕。"
    )

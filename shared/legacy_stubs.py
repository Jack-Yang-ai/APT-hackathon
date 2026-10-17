#!/usr/bin/env python3
"""从旧仓搬来的模块所依赖的、**已退役或已换位置**的东西。

为什么留桩而不是删调用点:搬运时改动别人的算法逻辑,风险高于收益。
桩的纪律只有一条——**当场炸,绝不静默降级**:

  旧仓最贵的一次事故(94% 原子落错层)的形态就是「成功地写进了错的地方」:
  exit code 全绿、日志全是 ✓、DB 行数在涨,唯独落错了层。
  静默 no-op 的桩会精确地复制这个形态。所以这里全部 raise。

每个桩都写明:它原来干什么、新架构里对应什么、改造方向在哪一节。
"""
from __future__ import annotations

import os


class RetiredInNewArchitecture(RuntimeError):
    """调用了在新架构里已退役的旧组织层接口。"""


# ── topics_v3:主题层 ────────────────────────────────────────────────
# 判决表:退役。「事」由用户确认产生,主题挂接键降级为提名的一个信号。
# 调用点:shared/codebook.py 的「定案后把待定队列重新挂 topic」——
# 这个动作在新架构里没有消费方了。
# 改造方向:codebook 的新用途是 ① 承诺「对谁」的名字解析 ② 检索查询扩展(判 17),
#          与 topic 无关,这段应整段删除。

class _Topics:
    @staticmethod
    def invalidate_cache():
        raise RetiredInNewArchitecture(
            "topics_v3 已退役(判决表)。codebook 在新架构里不再挂 topic——"
            "它的用途是名字解析 + 检索查询扩展(判 17)。这段调用应整段删除。"
        )

    # ⚠️ **2026-08-18 复核补上的。** 在这之前 `shared/codebook.py:405` 调它,
    # 而这个类里没有它 ⇒ 抛的是裸 `AttributeError`。
    #
    # 那**不是静默失败**(它照样炸),但它炸得**说不出为什么** ——
    # 而这一整个文件存在的理由就是「炸的时候把改造方向一起说出来」
    # (见文件头:「每个桩都写明:它原来干什么、新架构里对应什么」)。
    # 撞上裸 AttributeError 的人会以为是个 bug,而真相是「这段该整段删」。
    #
    # 🔴 **少一个方法这件事,这个文件自己看不出来** —— 桩是按调用点补的,
    # 而没人回头核对「调用点是不是都补齐了」。所以补的同时加了
    # `test_legacy_stubs.py`:扫调用方真正用到的属性,少一个就红。
    @staticmethod
    def upsert_topic(con, name, aspect):
        raise RetiredInNewArchitecture(
            f"topics_v3.upsert_topic({name!r}, {aspect!r}):三层表(episode_topics)已退役,"
            "写进去没有任何消费方 —— 正是「成功地写进了错的地方」。"
            "⚠️ 旧仓 2026-08-10(`709cd41`)已经把调它的 `mine()` 整个删掉了,"
            "本仓这份是**删除之前**的拷贝,见 TASKS M0-15。"
        )


topics_v3 = _Topics()


# ── label_server:Mac 上的说话人标注工作台 ────────────────────────────
# 技术方案 §七:保留到 M1 结束,之后评估。新架构里说话人确认在**手机上**。
#
# ⚠️ **本仓零调用方**(2026-08-18 复核)。~~「调用点:shared/recluster.py:241」~~
# 那个文件**没搬过来**(在 `_notmigrated/` 名单里)—— 这行注释指着仓外。
# 桩留着不碍事,但**别把它当成「这里有个真调用被守着」的证据**。
# 改造方向:Mac 不写内容也不写确认状态,拆簇结果应输出进回流 JSON(§4.3),
#          由手机走唯一归属入口处理。

class _LabelServer:
    @staticmethod
    def mark_split(key, parts):
        raise RetiredInNewArchitecture(
            f"label_server.mark_split({key!r}):说话人确认已移到手机端。"
            "拆簇结果请写进分人回流 JSON(技术方案 §4.3),由手机合并。"
        )


label_server = _LabelServer()


# ── 核心圈:这个不是退役,是换了位置 ──────────────────────────────────
# 旧仓在 memory/promote.py(晋升器)里定义,而晋升器属于退役的旧组织层。
# 但圈层本身是**产品配置**,不是旧组织层的逻辑——见同心圆身份模型:
# 我=原点,工作圈与生活圈各自有成员 × 时段先验,外圈只留提及不蒸画像。
# 新架构里它应由手机的人物模块提供;Mac 侧分人时需要它做「核心圈优先」排序,
# 所以这里保留成一份可配置的真值,不抛异常。

def _circle(env_key: str, default: str) -> set[str]:
    raw = os.environ.get(env_key, default)
    return {n.strip() for n in raw.split(",") if n.strip()}


class _Promote:
    """只提供圈层配置。晋升器的其余部分(主题晋升/归并)已退役,不搬。"""
    WORK_CIRCLE = _circle("GROWTH_WORK_CIRCLE", "")
    LIFE_CIRCLE = _circle("GROWTH_LIFE_CIRCLE", "")


promote = _Promote()

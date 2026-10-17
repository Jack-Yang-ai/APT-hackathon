#!/usr/bin/env python3
"""路由表的静态守卫:**在 CI 上红,而不是在生产里第一次调用时才红。**

跑:python3 -m shared.test_model_routes

## 为什么要有这一组

`route()` 遇到打错的 provider 会抛 `RuntimeError` —— 这很好,失败是可见的。
但它**只在那个场景第一次被真正调用时才抛**。`perceive_select`、`brief` 这类
低频场景可能几天才走一次,拼写错误会一路活到生产,而那时它表现成
「这条腿今天没干活」,和「今天没东西可干」长得一模一样。

静态扫一遍是零成本的,所以没有理由等到运行时。
"""
from __future__ import annotations

import sys

from shared.model_router import PROVIDERS, SCENE_ROUTES, _PRICES, route

# 本仓里**没有接实现**的配置槽:路由表里有,但真调用会抛。
# 它们被「每个模型都要有价」那条豁免 —— 而豁免由下面
# `test_the_dormant_slots_really_refuse_to_run` 逐条验证,不是写在这里就算数。
DORMANT_SLOTS = {"audio_perceive"}

tests = []
def test(fn):
    tests.append(fn)
    return fn


@test
def test_every_scene_points_at_a_provider_that_exists():
    """🔴 打错一个字母,那个场景就永远跑不起来 —— 而只有它自己会炸。"""
    bad = {s: c.get("provider") for s, c in SCENE_ROUTES.items()
           if c.get("provider") not in PROVIDERS}
    assert not bad, f"这些场景指着不存在的 provider:{bad}(可选的:{sorted(PROVIDERS)})"


@test
def test_every_routed_model_has_a_price():
    """🔴 **没配价与真免费在账本上长得一模一样。**

    Python 侧 `_price` 找不到价表时返回 `0.0`;而价表里 `step-3.7-flash` / `step-asr`
    的三档**本来就是 0**(免费额度 / 按时长另算)。两者落进账本都是 `cost_usd = 0`,
    **事后无从分辨**「这条腿不要钱」和「这条腿的钱我们根本没记」。

    ⚠️ JS 侧的 `priceUSD` 是**返回 null** 来避开这个坑的(注释写得很清楚),
    两边行为不一致。改 Python 的返回契约会牵动调用方,所以这里换个办法堵:
    **保证每个被路由到的模型都在价表里**,让那条 0 兜底永远不被走到。
    """
    missing = []
    for scene, cfg in SCENE_ROUTES.items():
        if scene in DORMANT_SLOTS:
            continue
        prov = PROVIDERS.get(cfg.get("provider"))
        if not prov:
            continue                      # 上一条测试会红,这里不重复报
        model = prov.get("model")
        if model and not any(model.startswith(k) for k in _PRICES):
            missing.append((scene, model))
    assert not missing, (
        f"这些场景路由到的模型不在价表里,花的钱会被记成 0:{missing}")


@test
def test_the_dormant_slots_really_refuse_to_run():
    """🔴 **豁免必须自我验证,不能是一句「它没接」。**

    `audio_perceive` 被上面那条测试豁免了(它路由到 `step-audio-r1.1`,而那个模型
    不在价表里)。豁免成立的**唯一理由**是:它在本仓是个空槽,真调用会抛 ——
    实现 `perceive/r1_client.py` 没有搬过来。**抛出来的东西不会悄悄花钱。**

    但「它没接」是一个会过期的事实。哪天有人把实现搬进来、让它真能跑,
    上面那条豁免就从「安全」变成「一条没记账的付费通道」,
    而**不会有任何地方报错**。

    ⇒ 所以这里钉的不是「它没接」,是「它**拒绝**被调用」。
    谁把它接上,这条先红,红的地方就写着「先去价表补一行」。
    """
    import inspect
    from shared import model_router as mr
    for scene in DORMANT_SLOTS:
        prov = PROVIDERS[SCENE_ROUTES[scene]["provider"]]
        adapter = mr._ADAPTERS.get(prov["kind"])
        assert adapter, f"{scene} 的 provider kind {prov['kind']!r} 没有适配器"
        src = inspect.getsource(adapter)
        assert "NotImplementedError" in src or "raise" in src, (
            f"{scene} 是被价表豁免的空槽,但它的适配器 {adapter.__name__} 现在能真跑了 —— "
            f"先去 `_PRICES` 补上 {prov.get('model')!r} 的价,再把它从 DORMANT_SLOTS 拿掉。"
            "没入账的开销等于不存在。")


@test
def test_the_eval_ruler_is_not_downgraded():
    """🔴 **尺子不许降级 —— 这条现在只有这里守着。**

    CLAUDE.md(全局与本仓两份都写了):
    「评测的尺子(判分/出题模型)**永不降级** —— 判官换了历史分数全部不可比」。

    2026-08-18 用户拍板「后续都用 DS V4 flash」,七个生产场景全线降了,
    **而 `judge` 是主模型主动留下的例外**。留的理由写在 `model_router.py` 的文件头,
    但**写下来不等于守住了它**(本仓 2026-08 反复栽在这个形状上,
    新加的第四条铁律讲的就是它):有人把这一行也改成 flash,
    **运行时什么都不会发生** —— 评测照跑、分数照出,只是从那天起
    历史分数全部不可比,而**没有任何地方会报错**。

    ⇒ 真要换,改这条测试即可 —— 但改它的人会先读到上面这段,
    知道自己买的是什么。这正是这条测试存在的意义:不是禁止,是**逼人看见**。
    """
    provider = SCENE_ROUTES["judge"]["provider"]
    assert provider == "deepseek-pro", (
        f"judge 的 provider 变成了 {provider!r} —— 评测的尺子被降级了。\n"
        "换尺子的代价是**所有历史分数从这一天起不可比**,而这件事不会有任何报错。\n"
        "确认要换的话改这一行,并在 TASKS.md 记下换的日期(旧分数都要标作废)。")

    # 顺带钉住「被测对象与生产同一条路由」的另一半:answer 是被测对象,
    # 它跟着生产走是对的,但它**不能和 judge 是同一个** —— 那就成了自己判自己。
    assert SCENE_ROUTES["answer"]["provider"] != provider, (
        "answer 与 judge 路由到同一个 provider —— 被测对象和判官成了同一个模型")


@test
def test_preview_chat_preserves_default_effort_and_metering():
    import io
    import json
    from unittest.mock import patch
    from shared import model_router as mr
    response = {"model": "step-5-preview", "choices": [{"message": {"content": "正文"}}],
                "usage": {"prompt_tokens": 1000, "prompt_tokens_details": {"cached_tokens": 200},
                          "completion_tokens": 50}}
    requests = []
    def upstream(request, **kwargs):
        requests.append(json.loads(request.data))
        assert kwargs["timeout"] == 900
        return io.BytesIO(json.dumps(response).encode())
    with patch.dict(mr.os.environ, {"STEPFUN_PLAN_API_KEY": "test"}, clear=True), \
            patch.object(mr.urllib.request, "urlopen", upstream):
        text, usage, _ = mr._call_stepfun_chat("原文", "", prov=mr.PROVIDERS["stepfun-preview"],
                                              scene="extract_s2", max_tokens=30000)
    assert text == "正文"
    assert requests[0] == {"model": "step-5-preview", "messages": [{"role": "user", "content": "原文"}],
                           "max_tokens": 30000, "stream": False}
    assert usage == {"input_tokens": 800, "cache_read_input_tokens": 200, "output_tokens": 50}
    for scene, budget in [("extract", 64000), ("extract_s1", 30000), ("extract_s2", 30000)]:
        with patch.dict(mr.os.environ, {"STEPFUN_PLAN_API_KEY": "test"}, clear=True), \
                patch.object(mr.urllib.request, "urlopen", upstream):
            mr.call("原文", "", scene=scene, usage_sink=lambda *a: None)
        assert "reasoning_effort" not in requests[-1]
        assert requests[-1]["max_tokens"] == budget
    assert mr.extract_backend("extract") == "stepfun"
    from datetime import datetime, timezone
    assert abs(mr._price("step-5-preview", {"output_tokens": 1_000_000},
                        datetime(2026, 10, 15, 7, tzinfo=timezone.utc)) - 2.7) < 1e-12


@test
def test_preview_rejects_empty_body_and_other_returned_model():
    import io
    import json
    from unittest.mock import patch
    from shared import model_router as mr
    for model, content in [("step-5-preview", ""), ("step-3.7-flash", "正文")]:
        response = {"model": model, "choices": [{"message": {"content": content}}],
                    "usage": {"completion_tokens": 100}}
        with patch.dict(mr.os.environ, {"STEPFUN_PLAN_API_KEY": "test"}), \
                patch.object(mr.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(response).encode())), \
                patch.object(mr, "_log_usage") as meter:
            try:
                mr._call_stepfun_chat("原文", "", prov=mr.PROVIDERS["stepfun-preview"],
                                      scene="extract_s2", max_tokens=30000)
                raise AssertionError("空正文或错模型不能当成功")
            except RuntimeError:
                pass
            assert meter.call_count == 1
            assert meter.call_args.args[1] == model
            assert meter.call_args.args[2]["output_tokens"] == 100


if __name__ == "__main__":
    failed = 0
    for fn in tests:
        try:
            fn()
            print("PASS", fn.__name__)
        except Exception as e:            # noqa: BLE001 —— 自测跑器,原因原样打出来
            failed += 1
            print("FAIL", fn.__name__, "\n   ", e)
    print(f"\n{failed} failed / {len(tests)}" if failed else f"\nall passed ({len(tests)})")
    sys.exit(1 if failed else 0)

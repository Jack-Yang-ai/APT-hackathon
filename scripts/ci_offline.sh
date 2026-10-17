#!/bin/sh
# 离线套件 —— **这份单子是唯一的一份**。
#   sh scripts/ci_offline.sh
#
# 两个调用方,都不许自己再列一遍:
#   · `.github/workflows/ci.yml` 的 offline job(每次 push)
#   · `eval/checks/premerge.sh`(每次合 TASKS.md 之前)
#
# 🔴 **2026-08-26 建。它同时治两个已经付过代价的毛病:**
#
# ① **本地跑的和 CI 跑的是两套不相交的测试。** 实测那天:premerge 16 项、
#    CI 离线 14 步,**交集为零**(唯一同名的 `test_checks.py` 还在 macOS 那个手动
#    job 里)。于是开发机上没有任何动作会碰到 CI 跑的那批 —— 最近 100 次 CI
#    一次都没绿过,而本地 premerge 一路全绿,**两边各自都「正常」**。
#    这就是铁律 4 的形状:一件事两个出处,对不上时不会报错。
#    ⇒ 修法不是再加一道对撞去比两张单子,是**只留一张单子**。
#
# ② **GitHub Actions 一步失败就停 ⇒ 后面的步骤从来没执行过。**
#    那 100 次全部死在第 5 步,排在后面的 **11 步一次都没跑过** ——
#    而输出看上去只是「有一项没过」。premerge 自己 2026-08-20 踩过一模一样的:
#    一道长期红着的项会把它后面的所有项一起变成摆设。
#    ⇒ 这里**全跑完再汇总**,末尾列出没过的项。
#
# ⚠️ 收进来的代价是 Actions 页面上看不到逐步骤的名字了 —— 换来的是那 11 步真的会跑。
#    名字没丢:下面每项失败时原样喷出全部输出,并在末尾按名字列出来。
#
# ⚠️ 最后那项会**改工作区**(重新生成金标向量)。真的产生 diff 就说明你改了口径
#    却没重新生成 —— 那时该做的正是把它提交掉。
cd "$(dirname "$0")/.."

failed=""

# 跑一项:失败 ⇒ 原样喷出全部输出并记下来(**不中断**);成功 ⇒ 只留最后一行。
check() {
  name="$1"; shift
  if out=$("$@" 2>&1); then
    printf '── %s\n' "$name"
    printf '%s\n' "$out" | tail -1
  else
    printf '%s\n' "$out" >&2
    echo "🔴 上面这项没过($name)" >&2
    failed="$failed
  · $name    ($*)"
  fi
}

check "抽取契约的校验逻辑"   python3 -m worker.test_extract
check "两阶段抽取(事件范围等)" python3 -m worker.test_two_stage
check "Mac抽取心跳终态协议" python3 -m mac.test_extract_proxy
# 归一键(M2-检2 §3.2):两条条目是不是同一件事、新的该不该顶掉旧的。
# 它挡的两起事故都**不报错**、事后无从发现(旧值已经没了),只能靠这里。
check "归一键判决表"        python3 -m shared.test_memory_keys
# 反应分诊的词面那一半(M2-检2 §3.4):命中即强制落账,不交给模型抖。
check "反应分诊词面"        python3 -m shared.test_reaction_gate
# 近重复去重(M2-检2 §1.4):跨语言夹具 —— Swift 与 Python 两份实现算得一不一样。
# 单跑 Python 这一半就够挡「只改了一边」:夹具改了 Swift 侧的 NearDuplicateTests 会红。
check "近重复去重"          python3 -m shared.test_near_duplicate
check "抽取质量臂的尺子"     python3 -m eval.test_extract_quality
check "分人/断句离线测"      python3 -m mac.test_align_transcript
# 🔴 SSE 兜底那条腿此前**没有任何 CI 覆盖**(2026-09-02 做 M2-认6 时发现)。
# 它是「文件端点卡死时唯一还能出稿的路」,而它自己的自测一直只在本地手跑。
check "SSE 兜底腿"          python3 mac/test_asr_fallback.py
check "分人桥与检出率闸"     python3 mac/test_diarize_subprocess.py

# 搬来的模块调到的每一个桩,都要炸得说得出为什么。
# 桩是按调用点一个一个补出来的,而**没人回头核对补齐没有** ——
# 2026-08-18 就撞到一个缺的(抛裸 AttributeError,说不出改造方向)。
check "退役桩的覆盖"        python3 -m shared.test_legacy_stubs

# 声纹是生物特征。保护写在 .gitignore 上,而真实写入路径可以从它旁边绕过去 ——
# 2026-08-18 实测到两条绕过去的(都是旧仓的目录布局搬过来之后失效的)。
check "声纹落盘路径都在 .gitignore 覆盖内" python3 -m shared.test_voiceprint_paths

# 判决核。🔴 **2026-08-31 才接进来** —— 在此之前这 18 条测试**没有任何闸在跑**,
# 只有人手动敲才会红(`premerge.sh:94` 那句注释指的是另一道,而那道不比判决核的数)。
# 它守的是「一场 2 个人不许被判成 39 个」:上游给了分人就按上游分组,
# 一个标签都没有就判不了 —— 而不是自己重聚一批碎片出来。
check "声纹判决核"          python3 mac/test_voiceprint_judge.py
check "声纹队列失败保任务"  python3 -m mac.test_voiceprint_daemon
check "个人行动证据与终态"  python3 -m worker.test_personal_actions

# 跨语言的成对约定(Swift 写/Python 读的 R2 键、JS 开/Swift 依赖的 ASR 开关)。
# 改一边的人通常打不开另一边 —— 而对不上的表现是「什么都不发生」。
check "跨语言成对约定"      python3 -m shared.test_cross_language_contracts
check "Agent 共用协议与三端绑定" python3 -m shared.test_agent_protocol
check "C0 离线文字迁移与对账" python3 -m shared.test_content_migration
check "Mac 文字权威、命令与回执" python3 -m shared.test_content_backend

# 走查台的页面清单 vs 源码里真实的跳转口。新加一个 NavigationLink / sheet
# 而不登记,走查台照样全绿 —— 它只是少走一页,而少走一页与「走完了都是好的」
# 长得一模一样。走查本身要一份真库、跑在 macOS 上,这道守卫不要。
check "界面走查的覆盖清单对撞" python3 -m shared.test_ui_walk_coverage
check "本版只有手表采集"       python3 eval/checks/test_watch_only_capture.py

check "路由表静态守卫"      python3 -m shared.test_model_routes

check "云代理记账"          node worker/test_accounting.mjs
check "转写 SSE 客户端"     node worker/test_asr_sse.mjs
check "云代理抽取口"        node worker/test_extract.mjs
check "云端转写收割器(Cron)" node worker/test_collector.mjs
check "成本对账口"          node worker/test_usage.mjs
check "版本化输入来源"      node worker/test_input_memory.mjs
check "Mac 输入来源服务"    node mac/test_input_memory.mjs
check "Mac 共用 Agent 入口"   node --test mac/test_common_agent.mjs
check "录音记忆接入输入法"    node --test mac/test_recording_memory.mjs
check "StepX 受保护云适配"   node --test stepx-worker/test/*.test.mjs
check "StepX 事务测试依赖"   npm ci --prefix stepx-client --ignore-scripts --no-audit --no-fund
check "StepX 凭据、录音与行动" node --test stepx-client/test/*.test.mjs
check "StepX root 研究证据"   python3 -m unittest discover -s stepx-root-recorder/tests -p 'test_*.py'
check "StepX root 心跳竞态"   python3 stepx-root-recorder/tools/test_heartbeat.py
check "StepX 后台上传身份"   python3 stepx-root-recorder/tools/test_upload_identity.py

# 金标向量是 Python 侧生成的,Swift 侧照着它断言。
# Python 改了口径却没重新生成的话,Swift 会**继续绿着**跑旧口径 ——
# 那正是这套金标要防的漂移,所以在这儿重生成一遍、有 diff 就红。
check "抽取金标向量是不是最新的" sh -c \
  'python3 eval/checks/gen_extract_golden.py && git diff --exit-code eval/checks/golden/ \
     || { echo "金标向量过期 —— 已就地重新生成,把 eval/checks/golden/ 提交掉"; exit 1; }'

if [ -n "$failed" ]; then
  echo "" >&2
  echo "🔴 离线套件没过的项:$failed" >&2
  exit 1
fi
echo ""
echo "✅ 离线套件全过"

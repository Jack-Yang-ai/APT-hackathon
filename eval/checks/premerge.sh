#!/bin/sh
# 合并 TASKS.md 之后跑这一条,别分别记一串脚本名。
#   sh eval/checks/premerge.sh
# 「零冲突」不等于「合对了」(事故四)—— git 只看行,下面这些看语义。
# ⚠️ 这里**不写「共几道」** —— 单子会长,写死在注释里就是又一处会过期的复述(铁律 4)。
#   以下面 `check` 那串调用为准。
# ⚠️ iOS 全量测试不在这里(要几分钟,单独跑);下面这些加起来秒级,没有理由跳过。
#
# 🔴 **2026-08-20:这道闸自己有过一个假绿,记在这当反面教材。**
# 原来三项写成 `python3 …py | tail -1` —— 而 `set -e` **管不住管道**
# (POSIX sh 没有 pipefail),脚本退 1 时退出码被 `tail` 吃掉,
# **premerge 照样退 0**。实测:`test_opaque_bars.py` 退 1、premerge 退 0。
# ⇒ 一道**红不了的闸比没有闸更糟** —— 它让人以为查过了。
# 现在改成先跑再看状态:失败时把全部输出喷出来并记账,成功才只留最后一行。
#
# 🔴 **同日第二个假绿(这次不是红不了,是根本没跑):`set -e` 在第一处红就掉头。**
# `test_worker_deployed_offline` 红着(等用户放行部署),而它排在中间 ——
# 于是在它红着的这段时间里,排在它后面的两项(判分尺子 / 时限次序)**一次都没执行过**;
# 当天新加的「刀五三个数」本来会是第三项。而输出看上去只是「有一项没过」。
# ⇒ 现在**全跑完再汇总**,末尾列出没过的项。
# 「先修完这一项再看下一项」听着稳妥,实际是让人把 N 轮返工当成一轮 ——
# 而一道**长期红着的项**会把它后面的所有项一起变成摆设。
cd "$(dirname "$0")/../.."

failed=""

# 跑一项检查:失败 ⇒ 原样喷出全部输出并记下来(**不中断**);成功 ⇒ 只留最后一行。
check() {
  name="$1"; shift
  if out=$("$@" 2>&1); then
    printf '%s\n' "$out" | tail -1
  else
    printf '%s\n' "$out" >&2
    echo "🔴 上面这项没过($name)" >&2
    failed="$failed
  · $name    ($*)"
  fi
}

# 🔴 **CI 那套离线套件(2026-08-26 收进来)。**
# 收之前:这道闸 16 项、CI 离线 14 步,**交集为零** —— 本地没有任何动作会碰到
# CI 跑的那批。实测代价:最近 100 次 CI 一次都没绿过,而这道闸一路全绿,
# 两边各自都「正常」。单子只有一份,在 `scripts/ci_offline.sh`,这里只是调用。
# 全套本地 <1s,没有理由不收。
check "CI 离线套件"       sh scripts/ci_offline.sh

check "任务号唯一"        python3 eval/checks/test_task_ids.py
check "出口达标线一致"     python3 eval/checks/test_m2_exit.py
check "断言脚本自己会红"    python3 eval/checks/test_checks.py
# 栏底不透明(M2-走4):漏掉的表现只是「滚动时有点花」,没有任何东西会红 ⇒ 扫源码。
check "栏底可读·不用红色"  python3 eval/checks/test_opaque_bars.py
# 改了 worker/src 却没部署(M1-35):漏掉的表现是「我以为修好了」,而线上纹丝未动。
# 这是离线那一半;联网那道更强的在 scripts/check_worker_deployed.sh,发布前跑。
check "worker 部署没漂移"  python3 eval/checks/test_worker_deployed_offline.py
# M2 判分脚本(M2-J2):钉住「达标线只有一个出处」—— 有人把数抄进脚本就红。
check "判分尺子只有一个出处" python3 eval/checks/test_score_m2_exams.py
# 三道「等多久算卡住」的时限次序(M1-30 ②):三个数在三种语言里,
# 交叉了没有任何东西会报错,而那时的现场与「上游真的挂了」一模一样。
check "卡住时限次序"      python3 eval/checks/test_stall_thresholds.py
# 刀五那三个数(M2-审3):Swift 常量 vs 技术方案/板上每一处复述。
# 其中 token 上限还是 `M2-0a ⑤` 的出口判据 —— 代码调大而它不动,出口就成了空话。
check "刀五三个数"        python3 eval/checks/test_input_budget.py
# 付费重试集合(M2-审7):先花钱再解析的腿漏进普通额度 ⇒ 290 次 / 6 天,每次真花钱,
# 而漏掉不会有任何东西报错 —— `progress` 就是照着注释里那句警告漏的。
check "付费重试集合一致"    python3 eval/checks/test_paid_retry_kinds.py

# 卡型闭集与优先级(M3-0b):PRD §4.6.3 那张表 vs `CardTrigger.Kind`。
# 三种漂法全是沉默的 —— 少一型 = 那一型永远出不来;序号错位 = 队列排错而照样出 B 张。
check "卡型闭集与优先级"   python3 eval/checks/test_card_kinds.py

# 发现类型闭集(M3-0d):PRD §4.5.4 两张表 vs `DiscoveryKind`(类型/对象/依据形态)。
# PRD 白纸黑字「清单之外不做」—— 而「清单」有两个副本时,那句话就没有落点了。
check "发现类型闭集"       python3 eval/checks/test_discovery_kinds.py

# 说话人代表片段的保留策略(M3-0c ④):**双向** ——
# 保留期扫不到它(否则第 8 天试听静默失效),而移出记忆必须删得掉它
# (否则云上留着一份用户以为已经删掉的录音)。两边漏了都不会有运行时报错。
check "片段保留策略"       python3 eval/checks/test_clip_prefix.py

# 录音目录命名只有一个出处(W1):手表算的 `day` 决定手机誊写进哪个目录,已是跨设备契约。
# 第二份格式化(尤其没钉公历的)会让目录错年、保留期比较错,而不报错。
check "录音目录命名一个出处" python3 eval/checks/test_recording_paths.py

# 观察类型闭集(M3-0e):PRD §4.4.7 vs `ObservationKind`,连「盲区判据的依据词」一起钉。
# 漂了的表现是**一条盲区观察在睡前弹出来** —— R-D 那条红线的全部意义就是不让它发生。
check "观察类型闭集"       python3 eval/checks/test_observation_kinds.py

# 抽取队列的键(M2-审19):Worker 发的 ticket ↔ Mac 写产物的键。
# 漂了的表现是「手机永远取不到 + 每拍重复付费」,而两端都不报错:
# daemon 说「抽完了」,手机说「云端正在抽」。
check "抽取队列键一致"     python3 mac/test_extract_daemon_keys.py

# M3 判分脚本自己的照妖镜(M3-J1):一把「怎么喂都给绿」的尺子与没有尺子一样,
# 只是它看起来量过。每条构造一份该红的卷子,断言它真的红。
check "M3 判分尺子会红"     python3 eval/checks/test_score_m3_exams.py

# 标准登记册(2026-08-26 用户拍板「判定要能管住代码」):判决层新增数值常量而没登记 ⇒ 红;
# 你判了「要改/作废」而代码还在跑 ⇒ 红。挡的是「多一个没人审过的阈值,而一切照常绿」——
# 这件事**没有任何运行时症状**:TARGET_CHARS=2000(「案卷 6000÷3」)决定整条抽取线的
# 切分粒度,躺了几个月没人审过,而一切照常绿。
# ⚠️ pending 只统计不拦 —— 110 条一次全红的闸活不过一周。
check "标准登记册"        python3 -m eval.checks.test_standards

# 🔴 声纹链的九个跨语言常数(M2-认8)。**接进来才算数** ——
# `voiceprint_daemon.py` 头上写着「跨语言对撞在 test_voiceprint_judge.py」,
# 而那道只比判决核的三个数,daemon 自己那几个一个都没比(复核清单 §五:
# 把要求写下来不等于守住了它)。补的这道若不挂进 premerge,就还是没人跑。
check "声纹链跨语言常数"   python3 mac/test_voiceprint_contract.py

# 三道纪律闸自己的照妖镜(M2-审23):git_guard 的接线(settings.json → 真文件)、
# ios_test 的判定(「Executed 0 + SUCCEEDED」必须红)、red_green 的次序(没红过的绿必须拒)。
# 闸没接线 = RegistrySnapshotIO 的形状:写好了、测过了、没人跑(铁律 5)。
check "纪律闸自己会红"     python3 eval/checks/test_discipline_gates.py

# 修复期测试冻结闸(M2-审25):「修代码的 agent 不能同时削弱对那段代码的检查」。
# 闸没接线/误伤了别的文件,表现都是零运行时症状 —— 拦/放两侧都在自检里。
check "修复期测试冻结闸"   python3 eval/checks/test_fix_mode_gate.py

if [ -n "$failed" ]; then
  echo "" >&2
  echo "🔴 没过的项:$failed" >&2
  exit 1
fi
echo ""
echo "✅ premerge 全过"

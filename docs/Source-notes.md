# 公开源码范围与复现说明

[返回首页](../README.md) · [技术说明](Technical-notes.md) · [隐私与数据](Privacy-and-data.md)

## 本次基线

本次公开源码以开发主线提交 **d5d3729** 为基线，该提交的输入法构建号为 **0.17.16 / 76**、来源服务 **0.2.4 / 11**、iPhone **0.2.5 / 2026101701**。

⚠️ **这是被钉住的快照，不是会随主线移动的「当前版本」**：私有主线在本快照之后仍会前进（例如 0.17.17 / 77 及更高）。需要更新时应重新导出，不要把本仓的编号当作私有仓的最新状态。公开导出也不附带源仓库 Git 历史。

| 目录 | 范围 |
|---|---|
| `mac/ime/` | 输入法、语音、草稿、检索、依据与确认填入；构建所需依赖与词库 |
| `mac/` | Mac Agent／来源服务、文字服务、录音处理及通用声纹服务 |
| `ios/` | iPhone / Watch、录音与收件、内容、聊天、声纹注册及数据库迁移兼容 |
| `worker/`、`stepx-worker/` | 代理、队列、来源同步和 StepX 后台协调 |
| `stepx-client/` | 业务 UI、主聊天、录音／恢复、行动与平台适配 |
| `stepx-root-recorder/` | Android root 录音、回执、上传与背屏控制源码及工具 |
| `shared/`、`eval/`、`scripts/` | 共用算法、机器契约、公开可复现检查及构建／运行工具 |

保留当前第一方实现和通用声纹代码；数据排除不意味着删除通用数据库迁移、注册／撤回语义或历史兼容。少数针对私人素材的修复迁移保留版本编号但不执行私人修补，详见 [数据边界](Privacy-and-data.md)。StepX 已不只是旧版核心适配层，但 Studio 仍提供 SDK／容器与完整打包条件，不能仅靠公开目录重建所有平台产物。

## 不随源码发布

- 个人声纹 seed／模板、录音、转写、说话人标签、校准素材及其衍生结果。
- 真实输入、聊天、内容数据库、设备快照和私人导入包。
- 模型 Key、门禁令牌、账号授权、生产配置与真实设备运行回执。
- 内部任务文档、私人截图和源仓库 Git 历史。

随包发布两个上游 MIT 模型权重（ReDimNet 说话人嵌入、Silero VAD 的本地 ONNX 转换），用于通用推理，**不是个人声纹模板**；上游链接、许可与发布字节 SHA-256 见 [第三方通知](../THIRD_PARTY_NOTICES.md)。`mac/embed_v2.py`、`mac/diarize.py` 依赖的外部模型不随包发布，需自行获取并单独确认条款。

用户应在仓库外保管自己的导出、模板和账本，经受控入口注册／撤回；源码不提供作者身份或默认个人模板。公开的词库、第三方许可和不含个人信息的通用测试数据与上述个人数据不同。

## 整组移除的内容（不只是散落文件）

除上表列出的目录外，以下整组内容**不随本快照发布**，读者不应把它们当成缺失的构建前提：

| 私有路径组 | 是否发布 | 原因 |
|---|---|---|
| `docs/intents/`、`docs/evidence/`、`docs/CURRENT.md`、`docs/PRD.md` | 否 | 内部任务文档、私人设备回执与真实素材证据 |
| `mac/calibration/`、`mac/cohort_vectors.json` | 否 | 生物特征校准素材与向量 |
| `mac/prompts/`、`mac/ime/docs/` | 否 | 内部提示词与开发笔记 |
| `eval/extract_pilot/`、`eval/checks/golden/` 下由真实场次派生的金标文件 | 否 | 真实录音派生金标 |
| `AGENTS.md`、`CLAUDE.md`、`TASKS.md`、`REVIEW.md`、`.claude/`、`.github/`、`.env.example` | 否 | 私有工程管理与 CI 入口 |

这些路径在若干已发布代码或契约里仍被文字引用；引用是历史叙述，不代表它们可用。`eval/contracts/` 与个别源码注释提到 `docs/PRD.md`、`docs/intents/...` 时同属此类。

## 会因排除而失败的检查

下列检查依赖已移除的文件，在公开树里**必然失败或缺项**，属预期而非缺陷：`eval/checks/test_task_ids.py`（缺 `TASKS.md`）、`eval/checks/test_discipline_gates.py` 与 `eval/checks/test_fix_mode_gate.py`（缺 `.claude/settings.json`）、`eval/checks/test_worker_deployed_offline.py`（缺 `worker/.deployed_sha`，该文件是部署回执，不随公开包发布）、`mac/test_asr_fallback.py` 的桶名对撞（缺 `worker/wrangler.toml`：该检查会**明确打印 SKIP** 而不是失败）。`scripts/ci_offline.sh` 里的 Java 相关项需要本机 JDK。依赖私人 seed、录音、真实转写或私人数据库的 iOS 套件同样不在公开范围，已在 `PUBLIC_SOURCE_MANIFEST.json` 按排除理由计数记录。

## 需要你自建的两份输入

通用代码保留，但它读的两份**素材**属于运营方数据，不随包发布：

- **冒充集（cohort）**：`mac/voiceprint_daemon.py`、`mac/voiceprint_judge.py` 需要 `mac/cohort_vectors.json` 做 T-norm 归一化；该文件由你用自己的授权语料生成，公开包不附带（它是生物特征派生物），也不附带作者用的生成脚本与参数。缺文件时这两个服务会明确报错，错误信息指向本说明。
- **运营商部署配置**：`worker/wrangler.toml`、`stepx-worker/wrangler.toml` 与 `stepx-worker/.deployed.json` 不随包发布。`scripts/deploy_stepx_worker.py` 在缺少部署回执时会**中止**：已有线上部署须设 `STEPX_EXPECTED_SOURCE=<线上 source 指纹>`（与线上不符仍中止），确属首次部署须显式设 `STEPX_FIRST_DEPLOY=1`。不要伪造回执或把占位值当成本次已部署。

## 可核对的清单文件

- `PUBLIC_SOURCE_MANIFEST.json`：本次发布每个文件的 SHA-256，以及 `excluded_summary`（按排除理由计数，不列被排除文件的路径）与 `transformations`（逐条公开侧改写记录）。
- `PUBLIC_SOURCE_SCAN.json`：发布前扫描结果（凭据模式、身份与真实姓名标记、个人模板键、作者端点与部署身份、私有仓链接）。

两者只证明本次导出检查，不等于外部安装或场景验证。iOS 套件还有一个环境前提：部分守卫测试用 `#filePath` 定位源码树，**必须在用户主目录下的检出中运行**（如指南推荐的 `$HOME/Projects/APT`）；在 `/tmp` 等路径下这些测试会读不到源码而报「一个 .swift 都没扫到」。

## 怎样理解验证记录

1. 新导出应单独核文件清单与哈希、敏感内容、文档链接和构建依赖。
2. 隔离测试、编译、验签、安装、真实模型调用和真机长时运行分别取得结果，不能互相代替。
3. 依赖已排除个人录音、转写、标签或私人数据库的测试**不能在公开仓库完整复现，不宣称通过**；缺素材应清楚报告，不降低判据，也不生成替身冒充原验收。
4. 历史验证文件只证明其记录的旧版本和当时范围，不可直接复制为 d5d3729 的成绩。仅提供测试命令也不表示已经执行。

本次文档本身不声称全量测试通过、新 Mac 安装成功或真实 demo 已完成。首页保留的图片是 **0.16.7 / 52 的虚构资料原生预览**（由其取证回执记录的构建裁切），不是本快照 0.17.16 / 76 的运行证明。

## 配置与许可

运行需要自己的环境、授权、模型和后端；公开仓库不提供生产下载或作者服务的匿名访问。安装和数据去向分别见 [Mac 指南](MacBook-input-method.md) 与 [隐私说明](Privacy-and-data.md)。

第一方代码保留 [Apache License 2.0](../LICENSE) 与 [NOTICE](../NOTICE)，第三方组件保留 [原许可与通知](../THIRD_PARTY_NOTICES.md)。

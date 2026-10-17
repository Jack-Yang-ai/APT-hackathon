# StepX 传输与后台协调 Worker

[APT 首页](../README.md) · [主 Worker](../worker/README.md) · [技术边界](../docs/Technical-notes.md)

此模块为 StepX 提供鉴权转发、不可变音频身份、ASR 提交回执和持久后台作业。模型密钥与正式来源写入留在主 Worker／处理服务；部署 StepX 桥不应顺带替换主 Worker。

## 数据与请求边界

业务请求需使用者自己的 `X-Growth-Token` 门禁。每个不可变音频 key 对应持久提交状态；提交不确定时先恢复原回执，不自动重复付费。已知失败或过期后的付费重试需用户确认产生一次性的 `retryId`，重放不能再次授权。

WAV 或协商的 M4A 均需核真实格式、帧数和哈希；单改扩展名不构成格式授权。后台作业接收已授权采集／完成片／收尾事实，推进 ASR、语义与 Mac 来源副本，用户控制通过版本围栏阻止旧回调覆盖。队列存在不代表 Mac 抽取服务已在运行，正式手机内容、行动和声纹不因此迁移。

## 自行配置

需为自己的 Cloudflare 环境提供匹配配置，不复制既有部署 ID：

- 自己的域名／路由与 StepX 前缀。
- `AUDIO` R2 绑定，与主 Worker 的预期资源一致。
- `SUBMISSIONS` / `StepXSubmissions` 与 `RECORDING_JOBS` / `StepXRecordings` SQLite Durable Objects，以及原迁移标签。
- `GROWTH_UPSTREAM` service binding，指向自己部署的主 Worker。
- 仓外 secrets：客户端门禁，以及后台写方所需的 `RECORDING_PRODUCER_TOKEN`；生产者 secret 在两 Worker 一致，但不交付手机。
- 主 Worker 的 D1 迁移和来源写方围栏；已有库先备份，不能通过重置库恢复状态。

`scripts/deploy_stepx_worker.py` 是已有部署的维护工具，目前还依赖固定服务地址和先前部署回执，**不是新用户可直接运行的首次部署脚本**。独立部署前必须将地址、配置与验证基线适配为自己的环境。保留源码指纹、鉴权 health 和“主 Worker 未变化”的核验；不要伪造历史回执使检查通过。

## 本机检查

在仓库根目录执行：

```sh
npm test --prefix stepx-worker
```

此命令不表示已通过，也不能代替云端真实 D1／R2／Durable Object、模型或手机验收。公开导出的实际测试以新记录为准；私人素材相关检查不可完整复现且不宣称通过。

客户端见 [StepX 源码](../stepx-client/README.md)。数据、授权和日志共享规则见 [隐私说明](../docs/Privacy-and-data.md)，贡献见 [贡献指南](../CONTRIBUTING.md)。

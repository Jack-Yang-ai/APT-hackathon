# 云代理与来源 Worker

[APT 首页](../README.md) · [StepX 桥](../stepx-worker/README.md) · [隐私与数据](../docs/Privacy-and-data.md)

本模块持有服务端模型密钥，代理音频上传、ASR、文字抽取与队列处理，记录用量，并提供版本化输入／录音来源同步。客户端仅提供自己的门禁，不携带模型 provider Key。音频存于私有 R2，由受控 URL 供识别服务读取；不要开放公共桶。

## 当前职责

- 上传、校验与 ASR 提交／查询；不确定提交先核原回执，避免无授权重复付费。
- 结构化场景的模型路由、上游流解析、截止／取消与空结果拒收；路由与 `shared/model_router.py` 保持一致。
- 抽取和声纹处理队列、任务回执、用量账本；未知用量或未定价不算零费用。
- D1 输入／录音来源的版本、墓碑、变更水位与精确回执；Mac 消费只读副本，正式手机库仍沿现行入口。
- StepX 后台来源写方围栏与验证过的 WAV／M4A 对象兼容；只声明格式不能绕过元数据校验。

## 配置前提

先为自己的 Cloudflare 账户创建并配置资源，不能直接复制已有数据库 ID、桶、域名或路由：

- Worker 名称与可被所选 ASR 下载器访问的域名。
- `AUDIO` 私有 R2 bucket binding。
- `INPUT_MEMORY` D1 binding、自己的 database ID、`migrations/` 和现行迁移；已有库先备份。
- 保留 `[triggers]` 的任务收割计划，与代码调度约定一致。
- `STEPFUN_API_KEY`、所需文字模型 Key 和 `CLIENT_TOKEN` 通过 Cloudflare secrets 或仓外授权配置提供。
- 使用 StepX 后台发布时，两 Worker 配置同一 `RECORDING_PRODUCER_TOKEN`，不交付客户端。

公开配置应使用占位资源，未完成替换不可部署。先在仓库根目录安装锁定依赖：

```sh
npm ci --prefix worker
npm test --prefix worker
```

测试命令不代表本次通过；模型调用、真实云资源、音频下载和设备端均需单独验证。

## 部署与核验

现有受控入口为 `sh scripts/deploy_worker.sh`，从已提交的干净分支发布并核源码指纹后才写回执。首次独立部署前先完成自己的配置、授权与存储迁移，并设置 `GROWTH_PROXY_URL` 为自己的 HTTPS 根地址；核验脚本否则可能仍使用原维护环境的默认地址。不要直接绕过指纹核验，也不要用复制的部署戳冒充自己的上线记录。

门禁使用自己的 `GROWTH_CLIENT_TOKEN`／`CLIENT_TOKEN`；不得提交 secret 或日志原文。health 配置项只证明设置存在，不能证明模型实际可用、后台服务运行或本版源码已上线。服务、安装与真实端到端检查分别记录。

构建和数据边界见 [源码说明](../docs/Source-notes.md)，变更与测试遵守 [贡献指南](../CONTRIBUTING.md)。本页不沿用历史精度、价格、私人录音回执或通过数量作当前承诺。

# StepX 品牌资源

StepX 使用 APT 共用 Logo 与 Agent，源图在 `assets/brand/`，通过 `scripts/export_brand_assets.py` 统一导出。图片保持比例，不重画近似图形。

- `apt-logo.png`：透明 Logo，用于 favicon、设置与品牌入口。
- `apt-agent.png`：透明 Agent，用于主聊天入口与状态。
- `apt-app-icon.png`：不透明应用图标，由 Android 平台按自身 mask 裁切。

将本地资源接入自己的匹配 Studio／平台工程，应用图标与页面资源分别按平台配置。保留原资源的来源、许可、署名及导出哈希记录，不因公开说明精简而删除。资源变更不更换包身份、签名、存储键或现有录音／聊天／行动数据。本页不包含内部 Studio 项目 ID、旧投递回执或新安装结论。

平台构建边界见 [StepX 模块](../README.md)。

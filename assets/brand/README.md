# APT 品牌资源

用户已确认蓝色 a Logo 与雾蓝团子 Agent。Logo 用于应用身份，Agent 用于表达助手入口与状态；二者不互相代替。

- logo-approved.png：获批白底原图。
- logo-source.png：去除背景后的生产透明母版。
- agent-source.png：获批雾蓝 Agent 透明母版。
- logo.png、agent.png、app-icon.png：跨端统一导出，禁止各端另画近似形象。
- provenance.json：生成提示词、来源与配色；exports.json：源文件及导出 SHA-256。

在 macOS 上运行 `python3 scripts/export_brand_assets.py`（依赖 Pillow），生成 iOS／watchOS Asset Catalog、Mac PNG／ICNS／菜单 TIFF，以及 stepx-client/brand 的交付文件。图片保持比例；原生应用图标为无透明通道的 1024px 方图，圆角由平台处理。

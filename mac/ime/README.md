# APT 输入法

[APT 首页](../../README.md) · [Mac 安装指南](../../docs/MacBook-input-method.md) · [隐私说明](../../docs/Privacy-and-data.md)

Apple Silicon、macOS 13+ 的中文输入法，当前代码版本 **0.17.16 / 76**。Rime 拼音与中英混输在本机执行；语音、记忆辅助写作、增量整理和表达习惯另需本机 Agent／来源服务及自己的模型配置。无需手机、手表或声纹服务。

| 操作 | 默认入口 |
|---|---|
| 中英切换 | 单按 Shift；Caps Lock 行为可在通用设置调整 |
| 拼音选词与翻页 | 数字／空格，`-` `=` 翻页 |
| 语音 | ⌃⌥D；按住说话、松开识别，轻按进入免手动模式 |
| 记忆 | ⌃⇧M；查看依据、切换候选，确认后再次按键或 Tab 填入 |
| 放弃 | Esc |
| 可选外设 | 「APT 设置 → 外设」显式开启 AU05，备份原配置并写后读回 |

自动记录输入默认关闭。开启后本机保存草稿，来源同步和模型生成具有不同的数据去向；「保存并同步」可能立即上传已有草稿。草稿、粘贴和生成内容不直接证明已说过或发送过。输入位置变化或结果无法确认时保留文字，不盲目重复填入。

从仓库根目录使用现行入口：

```sh
zsh scripts/build_ime.sh
zsh scripts/verify_ime.sh
zsh scripts/build_ime_installer.sh
zsh scripts/install_ime.sh
```

这是构建／检查／安装说明，不是本次通过结论。使用开发／临时签名，不能当作 Developer ID 公证；新 Mac、真实键盘、跨应用和双机查询仍需实测。AI 服务需另行安装配置，完整步骤见 [Mac 指南](../../docs/MacBook-input-method.md)。

历史截图保留原版本标注，不代表当前运行。详细源码和复现边界见 [Source-notes](../../docs/Source-notes.md)，第一方许可为 [Apache-2.0](../../LICENSE)，依赖与词库保留 [原许可](../../THIRD_PARTY_NOTICES.md)。

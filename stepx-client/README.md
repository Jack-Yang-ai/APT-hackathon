# StepX 手机端源码

[APT 首页](../README.md) · [技术边界](../docs/Technical-notes.md) · [隐私说明](../docs/Privacy-and-data.md)

本目录包含 StepX 的业务 UI、主聊天／草稿、录音控制、恢复、行动、背屏与持久后台处理适配，不是原生 iOS 工程。导航为「此刻／行动／我」；顶部 Agent 和常驻输入进入主聊天。**StepX 由手机直接采集**，不能套用原生 iPhone 只接收 Watch 录音的规则。

## 构建与平台前提

Studio 仍提供 SDK、容器及平台组件，公开源码不等于完整 APK 构建环境。映射业务源码时须保留平台树：`src/growth/` 对应共享 growth 模块，`src/ask/` 对应共享 ask 模块，`src/ui/` 按应用入口、layout、pages、components 分别映射，不能将平铺 UI 目录覆盖整个平台工程。

同步工具 `scripts/stepx_studio_payload.py` 还读取两份未公开的内部规格；未替换这些依赖前，不能把它视为公开仓可直接运行的完整交付入口。完整 typecheck、构建、签名、安装和 SDK 行为均需在自己的匹配平台环境验证。

## 录音与来源

- root recorder 是独立模块，用户显式开始／停止；完成文件回执、原件和本地保存分开管理。
- 5／10 分钟分片是文件边界，不等于语义事件。后台授权递送可推进 ASR、语义与 Mac 只读来源；App 恢复后接收副本和发送用户修改。
- 新代码在 root 与后端都支持时协商 M4A，否则保留 WAV；历史原件不转换。设备重启后 root 服务需重新部署，不注册开机自动录音。
- 正式内容、行动、编辑与完成状态由现行受控入口保留，不因重抽或迟到回调自动覆盖；只读 Mac 来源不等于全端库迁移。
- 提供自己后端的门禁，模型密钥不放入客户端。沙箱凭据加密未核实，网页预览不应使用真实凭据。

## 本机隔离检查

在仓库根目录执行：

```sh
npm ci --prefix stepx-client --ignore-scripts
node --test stepx-client/test/*.test.mjs
```

这些是检查入口，不是通过结论；测试使用隔离资料，不证明麦克风、锁屏、软键盘、物理背屏、全天连续性或耗电。公开导出排除个人素材，相关套件不可完整复现且不宣称通过。

root 代码见 [录音模块](../stepx-root-recorder/README.md)，后端见 [StepX 桥](../stepx-worker/README.md)。贡献按 [贡献指南](../CONTRIBUTING.md)；当前导出不包含作者的录音、转写、标签、声纹、模型 Key 或安装回执。

# StepX root recorder

[APT 首页](../README.md) · [StepX 客户端](../stepx-client/README.md) · [隐私说明](../docs/Privacy-and-data.md)

独立 Android root 录音与背屏服务。正式入口通过受控客户端命令核调用者身份，空闲不录音；每次采集由独立进程处理，完成片、帧账、上传与收尾回执持久化。通用代码公开不代表任意机型、签名或包身份兼容。

## 当前代码范围与限制

- 单一 16 kHz 单声道采集流，用户选择 5／10 分钟分片；12 小时是配置上限，不是已证明的连续性或电量结果。
- 完成片先验证长度、实际帧数及哈希，再受控递送；原件保留，异常 pending 不冒充成功。
- 新客户端与实际后端均宣告能力时，闭合文件可在独立有界进程编码为 32 kbps AAC-LC / M4A，失败保留 WAV。必要回执与双份哈希核验前不释放临时 PCM，历史录音不转换。
- 用户停止不依赖接收完成；监督和身份匹配限制异常终止。root 不是普通 APK 公共能力，也不开放任意网页 shell／URL 控制入口。
- 背屏服务独立于麦克风，在显式开启时显示固定麦克风和真实完整分钟；停止／失联释放自身显示，不保证其他机型厂商接口兼容。
- 不修改 SELinux／系统分区，不注册开机自动录音；设备重启后需重新部署服务。研究入口与正式 App 入口分开，不以原型代替生产验收。

## 构建前提

使用自己的 JDK 21、Android API 36 `android.jar` 和兼容 R8 工具链，核来源与许可；工具不替你下载或全局安装依赖。以下为仓库根目录的构建入口，路径均需替换为本机真实值：

```sh
python3 stepx-root-recorder/tools/build.py \
  --java /absolute/jdk/bin/java --javac /absolute/jdk/bin/javac \
  --android-jar /absolute/sdk/platforms/android-36/android.jar \
  --r8-jar /absolute/r8.jar --output /absolute/new-output/capture.jar
```

部署工具 `tools/provision.py` 需要本人授权的 ADB／root 环境和匹配 App 身份；当前校验逻辑包含特定包／签名条件，未适配不能直接用于另一台手机。部署仅启动空闲控制器，采集由用户 App 入口触发。不得重置 App 库或删除旧媒体来绕过兼容问题；不要向公共 issue 上传工具产生的设备回执。

## 本机隔离检查

```sh
python3 -m unittest discover -s stepx-root-recorder/tests -p 'test_*.py' -v
python3 stepx-root-recorder/tools/test_heartbeat.py \
  --java /absolute/jdk/bin/java --javac /absolute/jdk/bin/javac
python3 stepx-root-recorder/tools/test_upload_identity.py \
  --java /absolute/jdk/bin/java --javac /absolute/jdk/bin/javac
```

命令不表示本次通过。本机 JVM／Python 不证明 Android FD、AudioRecord、锁屏网络、通话打断、停止、恢复、物理背屏、全天或耗电；相关 Android 工具需单独授权的匹配环境。个人录音、转写、标签及回执不随发行，相关测试不可复现且不宣称通过。

后台授权与来源协调见 [StepX Worker](../stepx-worker/README.md)，整体边界见 [技术说明](../docs/Technical-notes.md)。

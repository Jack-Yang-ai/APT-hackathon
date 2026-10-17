# 第三方许可

第一方代码使用 Apache-2.0。以下组件保留原许可；根 LICENSE 不替换这些组件自己的条款。

| 组件 | 保留的许可位置 |
|---|---|
| Rime | mac/ime/EchoMemoryIME/librime-LICENSE.txt |
| VibeKeyElements | mac/ime/EchoMemoryIME/VibeKeyElements-LICENSE.txt |
| 明月拼音 | mac/ime/EchoMemoryIME/rime-luna-pinyin-LICENSE.txt |
| Rime 基础配置 | mac/ime/EchoMemoryIME/rime-prelude-LICENSE.txt |
| 八股文词频 | mac/ime/EchoMemoryIME/rime-essay-LICENSE.txt |
| rime-melt 英文词表来源 | mac/ime/EchoMemoryIME/rime-melt-LICENSE.txt；生成词表文件头保留上游署名 |
| OpenCC | mac/ime/EchoMemoryIME/Vendor（Apache-2.0，Carbo Kuo）；随包源码与头文件保留声明 |
| Rime 官方依赖包 | mac/ime/EchoMemoryIME/Vendor 内各组件自带的头文件通知与许可文本 |
| yaml-cpp | `mac/ime/EchoMemoryIME/Vendor/lib/libyaml-cpp.a`（MIT，Copyright (c) 2008 Jesse Beder）；静态库内不含独立许可文件，署名以本通知为准 |
| marisa-trie | `mac/ime/EchoMemoryIME/Vendor/lib/libmarisa.a`（BSD-2-Clause / LGPL，Copyright (c) 2011 Susumu Yata）；静态库内不含独立许可文本，署名以本通知为准 |
| glog、googletest、LevelDB | mac/ime/EchoMemoryIME/Vendor 对应源码与头文件保留各自的 BSD 许可与版权声明 |
| darts-clone | mac/ime/EchoMemoryIME/Vendor/include/COPYING.darts-clone（BSD-2-Clause / LGPL） |
| X11 keysymdef | `mac/ime/EchoMemoryIME/Vendor/include/X11/keysymdef.h` 文件头保留 X.Org／Open Group／DEC 声明 |
| GRDB | ios/Package.resolved 指向的独立 Swift Package；其上游许可适用 |
| ReDimNet 说话人嵌入权重 | `ios/GrowthApp/Resources/redimnet_s_body_op17.onnx`；上游 [IDRnD/ReDimNet](https://github.com/IDRnD/ReDimNet)（MIT，Copyright 2024 ID R&D），本地转换导出的推理主体 |
| Silero VAD 权重 | `ios/GrowthApp/Resources/silero_vad_16k_op15.onnx`；上游 [snakers4/silero-vad](https://github.com/snakers4/silero-vad)（MIT，Copyright 2020-present Silero Team） |

随包两个 ONNX 是上述 MIT 上游模型的本地转换产物，用于通用推理，**不是任何人的声纹模板**。发布字节的 SHA-256：

| 文件 | SHA-256 |
|---|---|
| redimnet_s_body_op17.onnx | `1e4de69bba025ba9d4ed52b4ac18912855ce81ae4658a1105bbbd4891fe72b12` |
| silero_vad_16k_op15.onnx | `7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49` |

本仓未固定上游 checkpoint 的确切 revision 与导出命令链；需要重新生成或替换权重时，请自行核对上游版本、许可与转换步骤。`mac/embed_v2.py`（pyannote 社区模型）与 `mac/diarize.py`（CAM++）按需从上游获取，**不随本仓发布**，其条款单独确认。

Vendor 官方二进制及词库保留用于构建；替换依赖时需保留相应通知。

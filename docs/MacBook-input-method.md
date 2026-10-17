# 只在 Mac 上使用 APT 输入法

[返回首页](../README.md) · [技术边界](Technical-notes.md) · [隐私与数据](Privacy-and-data.md)

Mac 可独立运行拼音、语音和记忆辅助写作，不需要手机、手表或声纹服务。本文按输入法 **0.17.16 / 76**、来源服务 **0.2.4 / 11** 的代码编写；不代表新 Mac 安装已验证，也不提供生产发行包下载。

## 1. 构建、核验与安装

需要 Apple Silicon Mac、macOS 13+、Xcode Command Line Tools、Python 3 和 Node.js 24+。当前构建目标为 arm64，不承诺 Intel 兼容。在空目录获取公开源码：

```sh
mkdir -p "$HOME/Projects"
git clone --branch main https://github.com/Jack-Yang-ai/APT-hackathon.git "$HOME/Projects/APT"
cd "$HOME/Projects/APT"
xcode-select -p
python3 --version
node --version
command -v node
git status --short
zsh scripts/build_ime.sh
zsh scripts/verify_ime.sh
zsh scripts/build_ime_installer.sh
zsh scripts/install_ime.sh
```

已有同名目录时请换一个空目录；不要覆盖旧数据。这些命令在仓库根目录执行，构建产物是 `mac/ime/APT.app`，安装到 `~/Library/Input Methods/APT.app`。脚本检查版本、源码指纹、签名和发布记录，并保留旧包。若曾装在系统目录 `/Library/Input Methods/APT.app`，图形安装器会先校验身份并备份，经 macOS 管理员授权把旧包移出输入源搜索目录，失败时按原路径恢复。公开源码应为干净且已提交的 checkout；不要绕过安装器的未提交输入或版本检查。

安装后在菜单栏切换至 **APT 输入法**，实际键入 `nihao`、空格并检查是否得到「你好」。如系统输入服务未就绪，保存工作、注销重登，再使用安装器「重新检查／安装修复」。源码构建使用开发／临时签名，**不能等同 Developer ID 公证**；系统安全和钥匙串授权由你本人确认。不要删除数据库排障。

只用拼音可停在这里。AI 还需以下配置。

## 2. 配置自己的本机服务

先准备你部署或获授权的 APT 后端 HTTPS 根地址、个人门禁和 Node 24 可执行文件路径。公开仓库不提供作者的后端账户，也不提供匿名注册；本机草稿查询仍需客户端与本机服务使用同一门禁。

在仓库外创建配置：

```sh
mkdir -p "$HOME/.config/apt"
touch "$HOME/.config/apt/input-memory.env"
chmod 600 "$HOME/.config/apt/input-memory.env"
open -e "$HOME/.config/apt/input-memory.env"
```

在编辑器填入真实值，不把 Key／令牌粘进 issue、聊天或提交：

```sh
GROWTH_CLIENT_TOKEN='你自己的个人门禁'
GROWTH_INPUT_MEMORY_TOKEN='同一个个人门禁'
GROWTH_INPUT_MEMORY_UPSTREAM='https://your-authorized-backend.example'
GROWTH_INPUT_MEMORY_NODE='/absolute/path/to/node24'
PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
```

占位地址不可用，需替换为自己的已配置服务。然后在仓库根目录执行：

```sh
bash scripts/input_memory_daemon.sh install
bash scripts/input_memory_daemon.sh status
```

检查实际版本、源码指纹、进程来源、`feed ready` 和可查范围，不以进程存在代替成功；0 条来源可作为新账户的起点。失败时保留日志和数据库，修复配置后重新核验。

本机服务默认监听 `127.0.0.1:18791`，通过用户级 LaunchAgent 启动；**保留源码目录的位置**，移动目录会影响服务。安装输入法 App 不会自动交付整套 Agent 或你的模型配置。

## 3. 在 APT 设置中配置功能

1. **记忆与来源 → 共用 APT 记忆**：填同一后端根地址和门禁。「保存并同步到 APT」会开启同步，并尝试上传未同步草稿。
2. **Agent 服务 → 实时模型**：填兼容 Chat Completions 的地址、模型和 Key，保存并测试。后台模型可先留空；整理和表达习惯不是必选项。
3. 需要语音时，在 **语音识别** 配置自己的 StepFun Key 与调用方式，到 **语音** 页授权麦克风。
4. 点 **核验服务与同步范围**，分别核本机服务、模型与实际材料范围。模型连接成功不等于来源齐全。

**仅本机草稿**：全新且没有旧草稿时，保持自动记录关闭，保存门禁后关闭来源同步，再开启自动记录。已有草稿时，保存并同步可能立即上传旧队列；该按钮不是“仅保存门禁”。关闭同步不撤回已上传材料，也不阻止回答所需材料送往所配置的模型。

## 4. 首次实际使用

到 **记忆与来源 → 本地输入记忆** 开启「自动记录输入」（默认关闭）。APT 输入段落停顿约 2 秒后保存；终端、密码类应用和系统安全输入不记录。管理窗口可查看和删除。

先用自己明确授权的无敏感草稿，例如「发布评审暂定周五下午，时间还没确认」。确认已保存后，另起一行写「发布评审的安排是：」，按 **⌃⇧M**，打开依据核对，再按快捷键或 Tab 填入。↑↓ 切换候选，Esc 放弃；填入不会自动发送。

语音默认 **⌃⌥D**：按住说话、松开识别；轻按进入免手动模式，再按结束。看到麦克风提示／波形后再开口。可关闭轻整理使用原转写。输入位置变动或填入不能确认时，先核文字，不盲目重复操作。

可选接线：WithEcho 经浏览器本人授权；飞书需本机已授权的 lark-cli；向量检索需本机 Ollama 与 embedding 模型；Ulanzi AU05 在「外设」页显式开启，备份原按键、写后读回再使用。外设不代替服务、模型和权限配置。

## 5. 来源同步、多 Mac 与维护

已接通手机的原话可以通过版本化只读来源供 Mac 查询，未转写、未同步或时间未核的材料不在范围内；不意味着手机正式库或声纹迁移。开启「按天整理」后，每日整理文档也作为版本化副本同步，另一台 Mac 回答时可引用并标出来源；本机自己的每日整理不重复计入。两台 Mac 应各自安装服务和授权，使用同一后端与门禁，保留独立设备身份，**不要复制整份数据目录**。用无敏感唯一测试词双向查询并核依据；设备数不能替代真实互查。

```sh
bash scripts/input_memory_daemon.sh status
bash scripts/input_memory_daemon.sh restart
# 暂停服务，保留数据库与配置
bash scripts/input_memory_daemon.sh stop
bash scripts/input_memory_daemon.sh start
```

升级前保存录音和待填入文字，更新干净 checkout，重新构建、核验与安装，再重启服务。运行版本、试输、跨应用和双机同步均须自行实测，不能沿用作者旧机器的结论。

停用先切换／移除系统 APT 输入源；卸载本机服务可执行 `bash scripts/input_memory_daemon.sh uninstall`，它只移除启动项。草稿、来源、钥匙串、授权及本机日志需你另行决定处理，详见 [隐私说明](Privacy-and-data.md)。

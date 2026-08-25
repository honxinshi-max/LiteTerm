# LiteTerm

> iPad-first 轻量终端 = 本地轻量文件 Shell + 强 SSH 远程终端

LiteTerm 是专为 iPad 设计的轻量终端。它不在 iPad 上模拟 Linux 或 macOS，也不捆绑 Python、Node.js、编译器、Docker、虚拟机或本地 AI 模型。iPad 负责触控交互和轻量文件操作，Git、Python、npm、Codex、Hermes 等计算任务由远程 Mac、Linux 或 Codespaces 完成。

当前状态：**V0.1 可移植候选版本**。源代码和项目文件已经齐备并通过本仓库的可移植验证；完整 Xcode 构建、实体 iPad、真实 SSH、60 分钟稳定性、安装体积/RAM 实测、归档隐私报告及 App Store 审核仍需执行，因此这不是已经发布的 App Store 成品。

## V0.1 功能

### Terminal UI

- 命令输入、命令输出和最多 2,000 行回滚缓冲
- 最多 200 条、总计不超过 128 KiB 的本地命令历史
- 滚动、选择、复制和粘贴
- 深色终端界面，适配 iPad 横屏与竖屏
- Local 与 SSH 共用一致的终端交互入口，同一时间只保留一个活动会话

### 触屏快捷键栏

软键盘上方提供：

`Esc`　`Ctrl`　`Tab`　`↑`　`↓`　`←`　`→`　`/`

快捷键通过可扩展的动作模型定义，后续可以增加自定义按键；V0.1 不提供插件系统或复杂快捷键编辑器。Local 模式中的上、下键用于浏览命令历史；SSH 模式将控制序列发送给远程 PTY。

### Local Lite Shell

V0.1 仅内置固定命令：

```text
pwd  ls  cd  cat  mkdir  touch  cp  mv  rm  clear  edit
```

`edit` 打开原生 SwiftUI 文本编辑器，用于完成触屏创建和修改文本文件的闭环；它不会启动外部编辑器进程。Local Shell 不支持管道、重定向、通配符、脚本、下载命令或 `Process`/`NSTask`，也不会执行文件内容。

可访问范围只有：

- LiteTerm 的 App Documents 沙盒目录
- 用户通过 iPadOS 系统文件夹选择器明确授权的 Files/iCloud Drive 目录

外部目录使用 security-scoped bookmark 和协调式文件访问。LiteTerm 不绕过 Sandbox，不扫描或扩大授权范围。目录授权失效时会回退到 App Documents，并要求用户重新选择。

### SSH

- 保存多个 Host：名称、IP/hostname、端口、用户名和认证方式
- 密码认证
- LiteTerm 在设备内生成的 Ed25519 密钥认证
- Connect、Disconnect、终端尺寸同步和真正的交互式 `xterm-256color` PTY Shell
- 前台网络中断后有限重连：最多 3 次，间隔 1、2、4 秒
- 首次连接明确确认服务器 SHA-256 指纹；服务器密钥变化时硬失败，必须由用户重新确认
- 远端 Shell 正常结束时先交付末尾输出再关闭会话；界面将其与网络故障区分，并提供显式重试入口

V0.1 **不导入任意 PEM/RSA/加密私钥**。这是对“SSH Key”范围的有意收窄，可降低解析器、密码学兼容和密钥迁移风险。远程机器已有的 Git、Python、npm、Codex、Hermes 等 CLI 可以在 SSH Shell 中正常使用，LiteTerm 本身不内置这些工具。

### 文件访问

- 使用系统 Document Picker 选择一个文件夹
- 在授权目录中创建、读取、编辑、复制和移动文件
- `rm` 只允许删除经过二次确认的普通文件；禁止删除工作区根目录和目录
- 路径解析阻止越过授权根目录，并拒绝符号链接替换等可观察到的不一致

SFTP 和“远程文件保存到 iPad”不属于 V0.1，但 SSH 与文件访问模块彼此独立，后续可以增加受控的远程文件传输层。

## 最小架构

LiteTerm 只保留两个主要产品层，避免增加无用抽象：

- `LiteTermCore`：纯 Foundation 核心，负责 Local 命令解析、路径约束、文件操作规则、有限状态、Host 元数据、Host Key 策略、重连策略和 Local → SSH → Local 流程。
- `LiteTerm`：iPad App 层，负责 SwiftUI/UIKit、SwiftTerm、触屏快捷键、Files 授权、原生编辑器、Keychain，以及 SwiftNIO SSH over Network.framework。

| 模块 | 职责 |
| --- | --- |
| Terminal UI | SwiftTerm 渲染、输入输出、滚动、复制粘贴、方向适配 |
| Shortcut Bar | 触屏按键模型及控制序列分发 |
| Local Shell | 固定命令分发、历史记录、受限文件操作 |
| SSH Engine | 连接生命周期、认证、Host Key、PTY、前台有限重连 |
| Host Manager | Host 元数据保存；敏感信息只存 Keychain |
| File Access | Document Picker、security-scoped bookmark、协调访问、原生编辑 |

## 项目目录

```text
LiteTerm/
├── LiteTerm/                         # SwiftUI iPad App
│   ├── App/                          # App 入口和生命周期
│   ├── Features/                     # Terminal、Local、SSH、Hosts、Files UI
│   ├── Infrastructure/               # Keychain、Files、SSH 实现
│   └── Resources/                    # Info.plist、Privacy、AppIcon、许可证资源
├── Sources/
│   └── LiteTermCore/                 # 可独立测试的核心逻辑
├── Tests/                            # Core、App、SSH 与流程测试
├── LiteTerm.xcodeproj/               # 可直接由 Xcode 打开的项目
├── docs/                             # 架构、决策与 V0.1 验收文档
├── scripts/                          # 可移植构建和项目验证脚本
├── Package.swift                     # Core 的 SwiftPM 可移植入口
├── project.yml                       # 项目与锁定依赖声明
├── THIRD_PARTY_NOTICES.md             # 第三方许可证与归属
└── README.md
```

## 安全与隐私边界

- 密码、生成的私钥和可信 Host Key 指纹分别存入 Keychain，不写入 Host JSON 或日志。
- Keychain 项使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不会通过设备备份迁移。
- 首次 Host Key 使用 TOFU 明确确认；指纹变更不会自动接受。
- 删除请求绑定显示路径、根目录相对路径和文件身份，并在确认时重新校验；任何可观察到的替换、重命名、符号链接变化、根目录变化或命令取代都会使请求失效。
- App 和 Core 均提供 Privacy Manifest，不声明跟踪、跟踪域或收集数据类型；正式分发前仍需检查 Xcode 归档生成的隐私报告。
- App 进入后台时不维持无意义的保活进程；iPadOS 挂起导致 SSH 断开属于预期行为。

## 轻量化硬限制

| 项目 | 上限 |
| --- | ---: |
| SwiftTerm 回滚缓冲 | 2,000 行 |
| Local 单次输入/历史单项 | 16 KiB |
| Local 命令历史 | 200 条 / 128 KiB 总计 |
| Local 操作队列 | 16 项 / 64 KiB 声明成本 |
| `cat` / 原生编辑器读取 | 5 MiB，64 KiB 分块 |
| 待显示 SSH 输出 | 8 MiB |
| 单次 SSH UI 输出批次 | 64 KiB |
| 活动终端会话 | 1 个 |

按当前依赖和设计估算，Release 安装后 App 约 **15–35 MiB**；Local 空闲/轻载 RSS 约 **45–90 MiB**，SSH 活动时约 **60–130 MiB**。主要来源是 Swift/SwiftUI 运行时、SwiftTerm 的终端网格与回滚缓冲、SwiftNIO/NIOTS/Crypto，以及系统网络和文本渲染缓存。这些是工程预算，不是实机结论；必须通过 Release Archive 和 M1 iPad Pro 的 Instruments/xctrace 测量后才能确认。

## 依赖与许可证

依赖按不可变 revision 锁定，并由 `Package.resolved` 固定完整图：

- SwiftTerm 1.15.0 — MIT
- swift-nio-ssh 0.15.0 — Apache-2.0
- swift-nio-transport-services 1.28.0 — Apache-2.0
- swift-nio 2.101.3 — Apache-2.0
- swift-crypto 4.5.1 — Apache-2.0

MIT 与 Apache-2.0 均允许商业 App 使用，但分发时必须保留相应版权、许可证文本及 NOTICE 归属。仓库中的 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 汇总了版本、revision、上游地址和所需声明，并作为 App 资源打包。项目自身使用 [MIT License](LICENSE)。

选择 SwiftNIO SSH 的理由是：Swift 实现、可与 Network.framework/NIOTS 集成、能够建立交互式 PTY，且无需捆绑完整 Linux 用户空间。代价是需要自行正确完成认证委托、Host Key 信任、PTY 通道、背压、生命周期和互操作验证；它不是开箱即用的完整终端产品 SDK。

## 获取、构建与安装

```sh
git clone https://github.com/honxinshi-max/LiteTerm.git
cd LiteTerm
open LiteTerm.xcodeproj
```

GitHub 中的是**源代码，不是可在 iPad“文件”App 中启用的程序**。iPadOS 不能直接编译、签名或执行这些 Swift 文件。安装到 iPad 的正确路径是：

1. 在 Mac 安装完整 Xcode，并登录 Apple Account。
2. 打开 `LiteTerm.xcodeproj`。
3. 在 Signing & Capabilities 中选择 Development Team，并设置唯一 Bundle Identifier。
4. 连接 iPad，选择该 iPad 作为运行目标。
5. 使用 Product → Run 构建、签名并安装。

需要持续分发时，应创建 Release Archive，上传 App Store Connect，再通过 TestFlight 安装。仅把仓库下载到 iPad Files/iCloud Drive 并不能运行 LiteTerm。

## 验证

在仓库根目录执行：

```sh
./scripts/run-core-tests.sh
./scripts/run-ssh-integration-tests.sh
swift build
./scripts/verify-project.sh
git diff --check
/usr/bin/plutil -lint \
  LiteTerm/Resources/Info.plist \
  LiteTerm/Resources/PrivacyInfo.xcprivacy \
  Sources/LiteTermCore/Resources/PrivacyInfo.xcprivacy \
  LiteTerm.xcodeproj/project.pbxproj
```

当前可移植验证运行 30 项 `LiteTermCore` 检查，并启动进程内真实 SwiftNIO SSH 环回服务器，覆盖密码认证、首次 Host Key 信任、PTY 建立、输入输出、窗口 resize、末尾输出、远端 EOF 和客户端关闭；同时核验工程结构、依赖锁、target membership、AppIcon、Privacy Manifest 和资源声明。环回测试证明传输协议与生命周期行为，不代替外部 OpenSSH、完整 Xcode 或实体 iPad 验收。若环境提供真实 XCTest，可补充运行：

```sh
LITETERM_ENABLE_SWIFTPM_XCTESTS=1 swift test
```

完整 Xcode、iPad Simulator、实体设备、真实 SSH 服务器和 Release Archive 的步骤见 [`docs/verification/V0.1-acceptance.md`](docs/verification/V0.1-acceptance.md)。可移植验证通过只代表候选代码结构与 Core 行为通过，不代表 App Store 发布验收通过。

## V0.1 验收流程

实体 iPad 最终必须完整通过以下闭环：

1. 打开 LiteTerm。
2. 不使用实体键盘。
3. Local 模式进入用户授权目录。
4. 创建并编辑文本文件。
5. 使用 `ls` 查看文件。
6. 使用 `cat` 读取文件。
7. 切换到 SSH。
8. 选择保存的 Mac Host。
9. 完成 Host Key 确认并连接。
10. 执行远程命令。
11. 使用 Ctrl、Tab、Esc 和方向键等触屏快捷键。
12. 断开 SSH。
13. 返回 Local Shell。
14. 确认 App 稳定、文件授权状态正确且无异常内存增长。

## V0.1 明确不做

- AI、本地模型或本地重型运行时
- GitHub 集成、Port Forwarding、SFTP
- tmux 管理器、插件系统、Team/协作功能
- 云同步、完整 Unix/Linux 环境、复杂主题系统
- 后台 SSH 常驻

## 尚未关闭的发布门槛

- 完整 Xcode 下的依赖解析、编译和 XCTest
- iPad Simulator 的布局、旋转、软键盘、复制粘贴与 Files Provider 验证
- M1 iPad Pro 实机签名安装和 14 步验收
- 密码与生成 Ed25519 密钥分别连接真实 Mac/Linux SSH
- 60 分钟 SSH、高输出背压与断网/前后台稳定性测试
- Release 安装体积和 RSS 实测
- Archive Privacy Report、出口合规、App Store Connect 隐私问卷和 App Review

完成上述门槛后，才能将 V0.1 从“可移植候选版本”提升为可发布版本。

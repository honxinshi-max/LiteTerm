# LiteTerm

> iPad-first 轻量终端 = 轻量本地工作区 + 本地文件 Shell + 强 SSH 远程终端

LiteTerm 是专为 iPad 设计的轻量终端与本地编程工作区。它不模拟完整 Linux/macOS，也不追求 GitHub Codespaces 或桌面 IDE 的兼容范围。当前候选实现可自动识别静态 Web、Python 与 Swift 项目：Web 使用系统 WebKit 和应用自有回环服务；Swift 只做明确标注的轻量诊断并交接 Swift Playgrounds；Python 只有在经过验证的官方 CPython iOS 产物、模拟器和实体设备门全部通过后才会启用。Node/npm、本地 Git、任意 shell、Docker、虚拟机、包管理器、Codex 与 Hermes 仍由用户主动连接的远程 SSH 环境承担。

当前状态：**V0.2 轻量本地工作区候选版本**。52 项可移植行为检查、真实本机回环服务、SSH 回环、工程结构和源码级隐私门已通过。完整 Xcode/iPad Simulator、CPython XCFramework、实体 iPad 资源与生命周期、真实 SSH、Release Archive 隐私报告及 App Review 仍未完成，因此这不是 App Store 成品，也不是全部三类项目已在 iPad 上通过的 release。

## 当前功能

### Lightweight Local Workspace（V0.2 candidate）

- 独立的 `Local Workspace` 界面：文件浏览、单文档编辑器、Check/Test/Run/Stop、预览，以及底部 Terminal / Problems / Ports。
- 横屏使用文件—编辑—预览多栏布局；竖屏使用文件抽屉并保留编辑器与底部工具区。
- 切换文件、目录或离开工作区前，未保存草稿必须由用户明确保留或放弃，不会静默丢失。
- 自动识别静态 Web、Python、Swift、Node-required、混合歧义和不支持项目；最多检查 1,000 项、20 MiB 相关源码，单文件最多 5 MiB。
- `workspace`、`check`、`test`、`run`、`stop`、`problems`、`ports` 仍是应用内类型化命令，不会成为 Unix shell 或任意进程入口。
- 只有当前源码代完成 Inspect → Check → Test → Start，并在 5 秒窗口内连续通过 3 次健康检查后，Ports 才显示一个 `127.0.0.1:<port>`。编辑、Files Provider 外部变更、换目录、Stop、崩溃、健康失败、旧代回调或进入后台都会先撤销端口。
- Web 只服务已捕获快照中的允许文件；监听器固定绑定 `127.0.0.1:0`，每次运行使用新的 128 位内存认证材料，禁止外网加载、弹窗、下载、媒体权限和持久网站数据。
- Python 项目目前能识别、建立受限 profile、执行能力门控与 WSGI 请求/响应边界验证，但当前构建没有经过验证的 CPython XCFramework，所以不会编译或执行用户 Python，也不会发布端口。
- Swift 只做编码、冲突标记、字符串/注释与分隔符诊断，结果固定标为 `Lightweight diagnostics`；不声称本地编译，并提供显式 Swift Playgrounds 交接。
- `package.json` 若没有可运行的静态 `index.html`，明确标为 Node-required 并在本地失败关闭。

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

Local Shell 仅内置固定文件命令：

```text
pwd  ls  cd  cat  mkdir  touch  cp  mv  rm  clear  edit
```

本地工作区另外提供 `workspace`、`check`、`test`、`run`、`stop`、`problems`、`ports` 七个类型化入口，它们全部调用同一个 `WorkspaceController` 状态机，不能绕过能力门、资源上限、源码代际或端口发布规则。`edit` 打开原生 SwiftUI 文本编辑器，用于完成触屏创建和修改文本文件的闭环；它不会启动外部编辑器进程。Local Shell 不支持管道、重定向、通配符、脚本、下载命令或 `Process`/`NSTask`，也不会执行文件内容。

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

V0.1 **不导入任意 PEM/RSA/加密私钥**。这是对“SSH Key”范围的有意收窄，可降低解析器、密码学兼容和密钥迁移风险。远程机器已有的 Git、Python、npm、Codex、Hermes 等 CLI 可以在 SSH Shell 中正常使用。LiteTerm 的本地工作区只实现上文明确列出的轻量能力，不把这些远程工具嵌入 App。

### 文件访问

- 使用系统 Document Picker 选择一个文件夹
- 在授权目录中创建、读取、编辑、复制和移动文件
- `rm` 只允许删除经过二次确认的普通文件；禁止删除工作区根目录和目录
- 路径解析阻止越过授权根目录，并拒绝符号链接替换等可观察到的不一致

SFTP 和“远程文件保存到 iPad”不属于 V0.1，但 SSH 与文件访问模块彼此独立，后续可以增加受控的远程文件传输层。

## 最小架构

LiteTerm 保留三个边界清楚的产品层：

- `LiteTermCore`：纯 Foundation 核心，负责 Local 命令、路径约束、工作区分类/检查/状态门/资源预算，以及 SSH 策略和 Local → SSH → Local 流程。
- `LiteTerm`：iPad App 层，负责 SwiftUI/UIKit、SwiftTerm、Files 授权、工作区控制与 Web 回环服务、Keychain，以及 SwiftNIO SSH over Network.framework。
- `LiteTermPythonBridge`：默认失败关闭的 Objective-C 边界；只有经过固定版本、哈希、架构、符号和隐私核验的 CPython iOS XCFramework 存在时才允许编译进目标。

| 模块 | 职责 |
| --- | --- |
| Terminal UI | SwiftTerm 渲染、输入输出、滚动、复制粘贴、方向适配 |
| Shortcut Bar | 触屏按键模型及控制序列分发 |
| Local Shell | 固定命令分发、历史记录、受限文件操作 |
| Workspace Core | 项目识别、检查/测试、代际状态机、问题与端口租约 |
| Workspace Runtime/UI | 编辑器、底部工具区、Web 快照服务、健康检查与预览 |
| Python Bridge | 固定入口、内存/超时/输出预算及 WSGI 边界；产物缺失时关闭 |
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
│   ├── LiteTermCore/                 # 可独立测试的核心逻辑
│   └── LiteTermWorkspaceSupport/     # 可移植 Web/HTTP 支撑层
├── LiteTermPythonBridge/             # 受门控的 CPython 桥接目标
├── Vendor/CPython/                   # 固定源码元数据；不含已启用二进制
├── Tests/                            # Core、Workspace、Python、SSH 与 UI 测试
├── LiteTerm.xcodeproj/               # 可直接由 Xcode 打开的项目
├── docs/                             # 产品边界、设计、计划与分层验收证据
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
- 本地工作区只持久化用户选择的 profile；源码快照、运行输出、Problems、认证材料和 Ready 端口只存在于内存，不写日志或遥测。
- Web/Python 预览监听器只能使用系统分配的 `127.0.0.1` 端口，不绑定通配、局域网、Bonjour 或云端地址；外部导航、下载、弹窗、媒体权限和持久网站数据全部关闭。
- App 和 Core 均提供 Privacy Manifest，不声明跟踪、跟踪域或收集数据类型；正式分发前仍需检查 Xcode 归档生成的隐私报告。
- App 进入后台时停止本地运行时并撤销 Ready 端口，也不维持无意义的 SSH 保活进程；iPadOS 挂起导致 SSH 断开属于预期行为。

## 轻量化硬限制

| 项目 | 上限 |
| --- | ---: |
| SwiftTerm 回滚缓冲 | 2,000 行 |
| Local 单次输入/历史单项 | 16 KiB |
| Local 命令历史 | 200 条 / 128 KiB 总计 |
| Local 操作队列 | 16 项 / 64 KiB 声明成本 |
| `cat` / 原生编辑器读取 | 5 MiB，64 KiB 分块 |
| 工作区清单 | 1,000 项 / 20 MiB 相关源码 |
| 工作区单文件 | 5 MiB |
| 工作区运行输出 | 2,000 行 / 2 MiB |
| 健康检查响应 | 256 KiB；5 秒内连续成功 3 次 |
| 本地工作区运行时 | 同时最多 1 个；后台 0 个 |
| 待显示 SSH 输出 | 8 MiB |
| 单次 SSH UI 输出批次 | 64 KiB |
| 活动终端会话 | 1 个 |

当前候选 RSS 上限为：前台空闲 **90 MiB**、Web 运行 **160 MiB**、Python 运行 **180 MiB**。这些是失败关闭的工程预算，不是实机结论；Python 产物也尚未启用。必须通过 Release Archive 和 M1 iPad Pro 的 Instruments/xctrace 测量启动、30 次编辑/运行循环和 60 分钟稳定性后才能确认或调整。

## 依赖与许可证

依赖按不可变 revision 锁定，并由 `Package.resolved` 固定完整图：

- SwiftTerm 1.15.0 — MIT
- swift-nio-ssh 0.15.0 — Apache-2.0
- swift-nio-transport-services 1.28.0 — Apache-2.0
- swift-nio 2.101.3 — Apache-2.0
- swift-crypto 4.5.1 — Apache-2.0
- CPython 3.14.7 源码候选 — Python Software Foundation License；固定源码哈希与 tag commit，当前仓库不含已通过门控的 XCFramework

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
./scripts/verify-workspace-privacy.sh
./scripts/verify-local-workspaces.sh
./scripts/verify-project.sh
git diff --check
/usr/bin/plutil -lint \
  LiteTerm/Resources/Info.plist \
  LiteTerm/Resources/PrivacyInfo.xcprivacy \
  Sources/LiteTermCore/Resources/PrivacyInfo.xcprivacy \
  LiteTerm.xcodeproj/project.pbxproj
```

当前可移植验证运行 52 项 `LiteTermCore` 检查，覆盖工作区识别、Web 真实回环、三次健康检查、端口租约、编辑失效、陈旧代回调、资源上限、Python 失败关闭、Swift 诊断边界和合成项目夹具；同时启动进程内真实 SwiftNIO SSH 环回服务器，并核验工程结构、依赖锁、target membership、AppIcon、Privacy Manifest 与源码级隐私边界。可移植通过不替代完整 Xcode、iPad Simulator、CPython iOS 产物、实体 iPad、外部 OpenSSH 或 Release Archive 验收。若环境提供真实 XCTest，可补充运行：

```sh
LITETERM_ENABLE_SWIFTPM_XCTESTS=1 swift test
```

证据和未关闭边界分别记录在：

- [`docs/verification/local-workspaces-verification.md`](docs/verification/local-workspaces-verification.md)：可移植、构建与 Simulator 分层结果
- [`docs/verification/local-workspaces-acceptance.md`](docs/verification/local-workspaces-acceptance.md)：12 项产品验收映射
- [`docs/verification/local-workspaces-ipad.md`](docs/verification/local-workspaces-ipad.md)：实体 iPad、资源与生命周期门
- [`docs/verification/local-workspaces-privacy.md`](docs/verification/local-workspaces-privacy.md)：源码、归档、签名与 App Store 隐私门
- [`docs/verification/python-runtime.md`](docs/verification/python-runtime.md)：CPython 产物与运行时门
- [`docs/verification/V0.1-acceptance.md`](docs/verification/V0.1-acceptance.md)：原有 Local Shell 与 SSH 验收

## 本地工作区验收闭环

实体 iPad 最终必须对 Web、Python 和 Swift 的适用边界分别完成以下闭环：

1. 打开 LiteTerm。
2. 不使用实体键盘，从 Files 选择项目目录并进入 `Local Workspace`。
3. 确认项目类型、支持状态、原因与建议动作可见；混合项目由用户显式选择 session profile。
4. 编辑源码并运行 Check；失败时确认 Problems 可定位且 Ports 为空。
5. 运行 Test；失败时确认不启动服务、不显示 Ready 端口。
6. 运行 Run；只有完成全部阶段和连续三次健康检查后才出现一个 Ready 端口与预览。
7. 修改源码，确认旧预览、端口和运行代立即失效；重新运行后获得新认证材料。
8. 执行 Stop、切换目录、前后台切换与故障注入，确认端口先撤销且没有后台运行时。
9. 重复编辑/运行 30 次并稳定运行 60 分钟，核验输出上限、触控流程与 RSS 预算。
10. 返回 Terminal/SSH，确认原有 Local Shell、文件授权和 SSH 会话没有回归。

## 明确不做

- 不承诺 GitHub Codespaces、桌面 IDE、完整 Unix/Linux、任意 shell、本地 Swift 编译或包管理器等价能力。
- 不执行 Node/npm、下载后的可执行文件、原生扩展、项目脚本或用户创建的运行时 socket。
- 不内置本地 Git、Codex、Hermes、AI/本地模型、Docker、虚拟机、插件系统或后台常驻运行时。
- 不提供 GitHub 账号集成、端口转发、SFTP、Team/协作、云同步、局域网或 Bonjour 服务发现。
- Python 只允许固定 CPython 版本、固定入口和受限 WSGI 子集；产物或任一验证门缺失时保持关闭。

## 尚未关闭的发布门槛

- 完整 Xcode 下的依赖解析、App 编译和全部 XCTest
- iPad Simulator 的布局、旋转、软键盘、Files Provider、WKWebView 与 UI 自动化
- CPython 3.14.7 iOS XCFramework 的哈希/架构/符号/隐私核验，以及模拟器脚本、失败和 WSGI 测试
- M1 iPad Pro 实机签名安装、本地工作区闭环、90/160/180 MiB RSS、30 次循环和 60 分钟测试
- 密码与生成 Ed25519 密钥分别连接真实 Mac/Linux SSH
- SSH 高输出背压、断网/前后台与远端 EOF 稳定性测试
- Archive Privacy Report、出口合规、App Store Connect 隐私问卷和 App Review

这些门槛彼此独立：可移植结构检查、源码级隐私检查或回环测试通过，均不能替代 iPad 实测、外部互操作、签名归档或 App Store 发布验收。

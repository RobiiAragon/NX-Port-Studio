<p align="center"><img src="docs/images/hero.zh-Hans.svg" alt="NX Port Studio — 将你的Switch游戏库制作成Apple原生应用" width="100%"></p>

<p align="center"><a href="README.md">English</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.ja.md">日本語</a> · <strong>简体中文</strong></p>

**我开发 NX Port Studio，让你能把自己拥有的 Nintendo Switch 游戏文件制作成 Apple 平台的原生应用。** macOS 工作台整合了资源准备、构建、控制器设置，以及通过 Xcode 为 iPhone/iPad 应用签名的流程。

我的独立项目基于 [seedds/nxnative](https://github.com/seedds/nxnative)，我保留了原引擎作者署名、MIT 许可和版权声明。请参阅[致谢](CREDITS.md)与[许可证](LICENSE)。

> **1.6.0 RC6：**我已在 Mac 版 Splatoon 2 中进入在线大厅和占地对战匹配队列，并确认窗口失去焦点或被遮挡时帧处理仍继续。我将这些结果与完成整场比赛、Smash 已验证的一轮竞技场对战，以及 Mario Kart 的历史 LAN 测试分别记录。Splatoon 角色颜色和原版固件 Mii 编辑器仍有待解决。[候选版说明](docs/releases/1.6.0-rc.6.md)。

## 应用截图

界面默认使用西班牙语，也可切换为英语、法语、日语或简体中文。界面语言与游戏语言分别设置。

![简体中文的新建移植应用界面](docs/images/zh-Hans/studio-new-port.jpg)

| 系统资源 | 本地房间发现 |
| :---: | :---: |
| [![固件资源库](docs/images/zh-Hans/studio-firmware.jpg)](docs/images/zh-Hans/studio-firmware.jpg) | [![本地房间发现桥接](docs/images/zh-Hans/studio-local-play.jpg)](docs/images/zh-Hans/studio-local-play.jpg) |

## 主要功能

- 识别 ZIP/7z、子文件夹及大写扩展名，限制解压范围并验证完整性。已知构建错误会以五种界面语言提供处理步骤。
- 每个游戏使用独立文件夹，集中管理本体、更新与 DLC，并显示实际构建进度和错误。
- iOS 导出必须经过 Xcode 签名和验证，之后才能报告成功。
- 导入自己主机中的 Mii 模型、字体、证书等系统资源。
- 我在**固件 → 导入 Mii**中添加了私人的个人 Mii 库，与固件模型分开保存。我已用合成记录验证格式、持久化及 Mac/iOS 打包；仍需在游戏中验证从自己主机导出的 Mii。参阅[格式与限制](docs/reference/services.md#personal-mii-imports-are-separate-from-firmware-model-archives)。
- 根据系统与设备开放的能力提供按键映射、体感和振动。
- 实现原生网络传输、LAN/LDN 房间发现，以及实验性的 Nextendo 集成。
- 可在 iPhone/iPad 内通过系统浏览器连接 Nextendo，将账户保存在应用钥匙串中，并检查游戏与服务要求。

我也扩展了引擎中的 Horizon 套接字、HLE 等待处理、TLS 验证、账户和 Joy-Con 支持。具体兼容性取决于游戏、更新版本与设备。

## 验证状态

| 功能 | 已确认的结果 |
| --- | --- |
| Mac ↔ Switch LAN | 我用较早的 Mario Kart 8 Deluxe 3.0.5 与实体 Switch 完成了整场比赛，也在另一个旧 3.0.5 候选版中验证了建房。这些是历史结果；我尚未用当前私有 4.0.1 候选版重复实体联机测试。 |
| iPhone ↔ Switch LAN | 我确认了双方都能作为房主，让另一台设备加入房间。我尚未验证 iPhone 完成整场比赛。 |
| LDN／本地无线 | 10月31日，我确认了 Mario Kart 3.0.5 在 Mac/iOS 原生移植版与我的实体 Switch 之间的 LAN 和 LDN 游戏。结果来自同步前的移植版，新引擎仍需重新验证；IP LDN 需要兼容的主机模块。 |
| Mario Kart 8 Deluxe 4.0.1 | 我已有当前的私有 Mac 候选版，并测量了主进程全屏渲染。我尚未用该候选版完成 Nextendo 比赛或重新验证实体 LAN/LDN。 |
| Smash 13.0.5／Nextendo | 我验证了账户及 **Mac 上的一轮真实竞技场对战**，并明确授权该服务的特定证书。快速匹配的网络不稳定报错，以及后来观战时的断线仍未解决；iOS 在线功能未验证。 |
| Splatoon 2 EUR 5.5.2／Nextendo | 11 月 2 日，我在完成教程并进入广场后，到达了 **Mac 在线大厅和占地对战匹配队列**。由于当时可参与的玩家较少，我决定稍后再测试整场比赛。我尚未验证比赛完成、P2P 对战、LAN/LDN 或 iOS。 |
| Android／Windows | 我计划在 Apple 平台稳定后开发，目前没有可用构建；ARM 与 x86 需要分别实现。 |

移植版默认自动启用连接服务。直接在游戏内选择在线、本地无线或 LAN，无需另外选择模式或重启。Nextendo 配置独立提供；缺少在线凭据不会阻止本地游戏。停用网络和可选的发现地址保留在高级设置中。

LAN 需要相同的游戏版本和同一局域网，局域网本身不必连接互联网。LDN 的 IP 桥接需要主机端的兼容模块，与游戏自带的 LAN 模式是不同的机制。

10 月 31 日的 TLS 测试中，我记录了握手成功，以及尚未解决的 NEX 主机名和设备认证链问题。未解决的信任检查仍会失败。当前 Mario Kart 候选版已是满足版本要求的 **4.0.1**；我尚未验证其 TLS／认证、NAT 和在线比赛路径。Smash 的快速匹配和后续会话稳定性仍待解决。Splatoon 2 的两条已验证 TLS 连接让我进入大厅和队列，但这不等于完成比赛或验证 P2P 对战。[覆盖记录](docs/nextendo-coverage.md)将这三个游戏的实际结果与 58 个目录条目、62 个地区配置和 22 个补丁方案分别列出。

## 开始使用

Studio 需要 Apple silicon Mac、macOS 14 或更新版本，以及支持 Swift 6 的 Xcode。你需要自行提供游戏文件和主机密钥。当前 iOS 目标为 iOS/iPadOS 26 及受支持的硬件；部分游戏还需要更新的 macOS 或 Metal。

在仓库中运行：

    cd macOS/NXPortStudio
    swift test
    swift run NXPortStudio

在 Studio 中准备环境，选择游戏文件夹与 prod.keys，再选择 Mac 或 iPhone/iPad。iOS 构建还需要配置 Xcode 开发团队和已配对的设备。IPA 只有通过签名与验证后才会被视为成功，并受 Apple 的账户、设备和有效期规则限制。

我在公开仓库中保留源代码、工具和 Studio 界面截图。游戏、主机密钥、固件、账户信息、存档及 Nintendo 图像不进入公开仓库。

Mac 移植应用直接安装到**应用程序**。临时引擎、解压数据和构建产物会在完成、失败或取消后删除。更新时先验证新应用，再替换同一游戏的移植版；存档和设置会保留。iOS 继续使用 Xcode 签名流程。

[完整英文指南](README.md) · [路线图](ROADMAP.md) · [参与开发](CONTRIBUTING.md)

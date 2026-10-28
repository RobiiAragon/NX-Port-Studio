<p align="center"><img src="docs/images/hero.zh-Hans.svg" alt="NX Port Studio — 将你的Switch游戏库制作成Apple原生应用" width="100%"></p>

<p align="center"><a href="README.md">English</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.ja.md">日本語</a> · <strong>简体中文</strong></p>

**NX Port Studio 可将你自己拥有的 Nintendo Switch 游戏文件制作成 Apple 平台的原生应用。** macOS 工作台整合了资源准备、构建、控制器设置，以及通过 Xcode 为 iPhone/iPad 应用签名的流程。

这是基于 [seedds/nxnative](https://github.com/seedds/nxnative) 的独立项目，保留了原引擎作者署名、MIT 许可和版权声明。请参阅[致谢](CREDITS.md)与[许可证](LICENSE)。

## 应用截图

界面默认使用西班牙语，也可切换为英语、法语、日语或简体中文。界面语言与游戏语言分别设置。

![简体中文的新建移植应用界面](docs/images/zh-Hans/studio-new-port.jpg)

| 系统资源 | 本地房间发现 |
| :---: | :---: |
| [![固件资源库](docs/images/zh-Hans/studio-firmware.jpg)](docs/images/zh-Hans/studio-firmware.jpg) | [![本地房间发现桥接](docs/images/zh-Hans/studio-local-play.jpg)](docs/images/zh-Hans/studio-local-play.jpg) |

## 主要功能

- 每个游戏使用独立文件夹，集中管理本体、更新与 DLC，并显示实际构建进度和错误。
- iOS 导出必须经过 Xcode 签名和验证，之后才能报告成功。
- 导入自己主机中的 Mii 模型、字体、证书等系统资源。
- 根据系统与设备开放的能力提供按键映射、体感和振动。
- 实现原生网络传输、LAN/LDN 房间发现，以及实验性的 Nextendo 集成。
- 可在 iPhone/iPad 内通过系统浏览器连接 Nextendo，将账户保存在应用钥匙串中，并检查游戏与服务要求。

项目同时扩展了引擎中的 Horizon 套接字、HLE 等待处理、TLS 验证、账户和 Joy-Con 支持。具体兼容性取决于游戏、更新版本与设备。

## 验证状态

| 功能 | 已确认的结果 |
| --- | --- |
| Mac ↔ Switch LAN | 较早的 Mac 构建曾与实体 Switch 完成 Mario Kart 8 Deluxe 3.0.5 的完整比赛。当前候选构建已确认可以创建房间并进入主机规则界面。 |
| iPhone ↔ Switch LAN | 用户已确认双方都能作为房主，让另一台设备加入房间。该组合尚未确认完成整场比赛。 |
| LDN／本地无线 | 修复本地游玩历史身份后，已确认 Mac 版 Mario Kart 3.0.5 可以创建主机大厅。此前实体设备的加入和创建测试失败，仍需用修复版本与 Switch 重新验证。 |
| Nextendo | 已验证 OAuth、身份核对后的 NEX 凭据获取及签名目录。尚未验证原生游戏的在线对局。 |
| Android／Windows | 计划在 Apple 平台稳定后开发，目前没有可用构建；ARM 与 x86 需要分别实现。 |

LAN 需要相同的游戏版本和同一局域网，局域网本身不必连接互联网。LDN 的 IP 桥接需要主机端的兼容模块，与游戏自带的 LAN 模式是不同的机制。

截至 2026 年 10 月 28 日，Nextendo 游戏服务仍受到证书问题和 Mario Kart 版本要求的阻碍。现有构建为 3.0.5，签名目录要求 4.0.1。账户登录并不能自动满足这些要求。[英文说明](README.md#current-game-service-blockers)列出了具体限制。

## 开始使用

Studio 需要 Apple silicon Mac、macOS 14 或更新版本，以及支持 Swift 6 的 Xcode。你需要自行提供游戏文件和主机密钥。当前 iOS 目标为 iOS/iPadOS 26 及受支持的硬件；部分游戏还需要更新的 macOS 或 Metal。

在仓库中运行：

    cd macOS/NXPortStudio
    swift test
    swift run NXPortStudio

在 Studio 中准备环境，选择游戏文件夹与 prod.keys，再选择 Mac 或 iPhone/iPad。iOS 构建还需要配置 Xcode 开发团队和已配对的设备。IPA 只有通过签名与验证后才会被视为成功，并受 Apple 的账户、设备和有效期规则限制。

公开仓库包含源代码、工具和 Studio 界面截图。游戏、主机密钥、固件、账户信息、存档及 Nintendo 图像不进入公开仓库。

[完整英文指南](README.md) · [路线图](ROADMAP.md) · [参与开发](CONTRIBUTING.md)

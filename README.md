# Dictionary

**读懂此处的词义，继续你的阅读。**

Dictionary 是一款原生 macOS 英汉查词工具。在阅读时选中英文，按 **⌥D**，
结合可获取的原句和段落查看中文释义。也可以在主窗口输入单词、短语或句子，补充语境后查询。

[官网](https://dictionary-macos-liyunhui.outerepoch3.chatgpt.site) ·
[版本与下载](https://github.com/liyunhui0707/dictionary-macos/releases) ·
[使用指南](docs/guide.md) · [隐私说明](PRIVACY.md) ·
[反馈问题](https://github.com/liyunhui0707/dictionary-macos/issues)

## 功能

- 原生主窗口与浮动查词窗口，支持固定、关闭及取消查询。
- 获取选词所在的原句和段落；无法可靠定位时明确提示语境不足。
- Books 可选本地屏幕语境：原生路径缺少原句时，先预览识别结果，确认后再查询；默认关闭。
- 可选择 DeepSeek 云端或 Ollama 本地作为主查词服务；本地模式也可主动询问 DeepSeek。
- 内置 Open English Wordnet 英文词典参考及常见词形查询。
- Chromium 浏览器扩展、Safari 选词路径与 Obsidian 桌面插件。
- 浅色和深色外观跟随 macOS；主动检查公开版本并前往下载页更新。

AI 释义用于辅助理解，可能出现错误。参考词典与 AI 结果分别标注；
没有抓到原句时，不会将推测文本当成已确认的原句。
验收方式、已验证范围与已知质量问题见 [质量验证说明](docs/quality.md)。
日常反馈只需记下“哪个软件、选了什么、哪里不对”，尽量用合成例句复现；不必先重复验收。
后续按[维护流程](docs/maintenance.md#feedback-and-regression-batches)集中处理重复问题。

## 安装与开始使用

最新公开版本为 [0.9.1](https://github.com/liyunhui0707/dictionary-macos/releases/tag/v0.9.1)，已完成两台 Mac 的升级和指定 Books 合成用例验收。[版本说明](docs/releases/0.9.1.md)列出验收范围与限制；下载文件以 Releases 为准。

系统要求为 **macOS 14 或更新版本**。下载时请选择与你的芯片架构相符的安装包。
正式应用安装包以 Releases 实际列出的资产为准；没有安装包时可按下方步骤从源码构建。
下载源码 ZIP 不等于已安装应用。当前分发渠道采用临时签名，**未经 Apple 公证**；
首次打开可能需要用户在系统设置中确认，详见 [安装指南](docs/guide.md#安装与首次打开)。

1. 将 Dictionary 拖入“应用程序”，然后打开。
2. 点击“开始设置与首查”，按 **开始使用** 引导选择云端或本地查词服务。
3. 云端模式：保存自己的 DeepSeek API 密钥，确认数据发送和用量费用后选择 DeepSeek。无需安装 Ollama。
   本地模式：安装并运行 [Ollama](https://ollama.com/download)，准备模型后选择本地查词，在“本地模型”检查连接。
4. 在主窗口输入英文并查询；补充完整原句有助于理解词义。
5. 使用其他软件内的 ⌥D 查词时，按系统提示为 Dictionary 开启选词权限。

应用不附带 API 密钥或本地模型。本地默认模型为 `qwen2.5:7b`，不同模型和硬件的速度、质量有所不同。
云端主服务会在每次查词时发送选词及可获取的语境；保存密钥本身不会选择云端主服务或发起 API 测试。
本地模式下，“询问 DeepSeek”仍是单独的主动操作。服务失败不会自动切换另一来源。

## 支持的阅读方式

| 场景 | 接入方式 |
| --- | --- |
| 主窗口 | 手动输入英文和语境，无需选词权限 |
| Apple Books | ⌥D；原生原句优先，也可主动开启[屏幕语境](docs/guide.md#apple-books-的屏幕语境)，逐次核对识别结果 |
| Chrome / Edge / Brave 等 | 使用 App 内配套的 Chromium 扩展并配置本机令牌 |
| Safari | 配置 Safari JavaScript 与自动化授权，详见使用指南 |
| Obsidian 桌面版 | 安装配套插件并配置本机令牌 |
| Readest、Session Manager、Markdown 等 | 使用系统选词路径；已验证部分阅读和编辑场景，具体版本与边界见[阅读场景验收](docs/reading-compatibility.md) |
| 其他 macOS 应用 | 尝试系统辅助功能和复制回退；并非所有软件都能提供上下文 |

同一软件版本在不同电脑或运行状态下也可能只取得单词；选词授权已开启不代表能取得原句。

本项目提供 macOS 应用，不提供 Windows、Linux 或移动端客户端。
浏览器扩展提供实际快捷键、连接检查和工具栏查词入口；连接检查不调用模型，需配套新版 App。
App 的“开始使用”顶部可一键准备配套浏览器扩展，按版本固定保存；同版本经文件核对后可复用，也可选择其他位置。
重启会重新核对文件，不会把文件已准备误报成浏览器已连接。App 还提供本机合成阅读练习页，无需联网加载样例；实际查词仍使用你选择的服务。
引导区分已配置、实际收到释义和用户核对原句；缺语境、失败或取消不会自动标记为完成。
[0.9.2 本地候选](docs/releases/0.9.2.md)进一步按服务、模型与阅读方式给出下一步，区分连接失败和模型无有效释义；尚未替换公开的 0.9.1 下载。
浏览器会沿焦点读取可访问的同源阅读框；跨域或受限框架不保证能够读取语境。
图片、扫描件、受保护页面和不开放文本的软件不保证能够读取语境。
Books 屏幕语境需要单独的 macOS 屏幕录制权限，只在查词时尝试识别当前 Books 窗口的局部文字。
图片仅在内存中处理；确认后的文字交给所选查词服务，使用云端时会发送该文字。它不保证每次都能取得原句。

## 问题诊断与反馈

在应用菜单选择“诊断与反馈…”，或打开 **偏好设置 → 问题反馈**，查看服务、阅读接入和最近主查词的状态及恢复建议。
打开页面不会自动查词、检查网络或访问密钥；本地模型检查由你主动发起。
可先预览诊断报告，再保存到自己选择的位置并决定是否分享。报告不含正文、回答、密钥、令牌、个人路径或机器信息，不会自动上传。
反馈时请说明复现步骤，并区分没有取得原句与原句正确但词义错误；详见 [使用指南](docs/guide.md#问题诊断与反馈)。

## 更新

通过 GitHub Releases 发布版本、安装包、校验值和更新说明。
应用菜单 **检查更新…** 主动查询公开稳定版本，显示版本说明及适合当前芯片的可确认安装包；
没有对应安装包时会提示，不会推荐另一种芯片的下载。**查看更新与下载…** 打开发行页面。
下载后退出旧版，将新版放回“应用程序”。保留旧安装包与配套扩展目录，按 [更新与回退指南](docs/guide.md#更新与回退) 验证新版或恢复旧版。
当前采用手动更新，不会在后台下载或自动替换应用。官网也以同一个版本页面作为下载来源。

## 从源码构建

推荐使用完整 Xcode，以及用于脚本和扩展测试的 Node.js。
使用其他 Swift 6 工具链时，还需具备所用 SDK 对应的 SwiftUI 宏插件；
若仅安装 Command Line Tools 后出现 `SwiftUIMacros` 插件缺失错误，请使用完整 Xcode 的工具链。
下载已打包的应用不需要安装这些开发工具。

```sh
git clone https://github.com/liyunhui0707/dictionary-macos.git
cd dictionary-macos
swift test
node --test Tests/QA/*.test.cjs Tests/Extensions/*.test.cjs
node scripts/qa-app.mjs build
```

最后一条命令在 `build/qa.noindex/<build-id>/Dictionary.app` 生成独立应用包，并保存构建清单。
测试包位于 `.noindex` 目录，日常只从 `/Applications/Dictionary.app` 启动。
通过 **Dictionary → 关于 Dictionary** 查看产品版本和确切构建编号，避免把同版本号的测试构建混淆。
默认使用临时签名，适合本地构建；跨机器分发请遵循 [发布流程](docs/releasing.md)。
在有开发证书的机器上，固定测试路径可使用 `build-testing --signing-identity <证书指纹>`
与 `stage-testing <构建目录>`；不要为每次修改重建系统权限条目。

开发安装与历史构建的管理方式见 [维护与安装纪律](docs/maintenance.md)。

普通测试使用合成文本与受控服务，不需要真实书籍、API 密钥或运行中的本地模型。
可选实机、渲染和模型评估测试默认跳过；自动测试通过不等同于上下文释义准确率保证。

## 贡献与许可

欢迎通过 Issues 提交可复现的问题，或通过 Pull Request 贡献改进。
请使用合成语句复现，不提交密钥、个人书籍内容、聊天记录或机器配置。
参见 [贡献说明](CONTRIBUTING.md) 和 [安全说明](SECURITY.md)。

应用代码采用 [MIT License](LICENSE)。内置 Open English Wordnet 及其底层数据保留各自许可和署名，
见 [第三方声明](THIRD_PARTY_NOTICES.md)。模型及服务遵循其各自条款。

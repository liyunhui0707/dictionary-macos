# Dictionary

**读懂此处的词义，继续你的阅读。**

Dictionary 是一款原生 macOS 英汉查词工具。在阅读时选中英文，按 **⌥D**，
结合可获取的原句和段落查看中文释义。也可以在主窗口输入单词、短语或句子，补充语境后查询。

[版本与下载](https://github.com/liyunhui0707/dictionary-macos/releases) ·
[使用指南](docs/guide.md) · [隐私说明](PRIVACY.md) ·
[反馈问题](https://github.com/liyunhui0707/dictionary-macos/issues)

## 功能

- 原生主窗口与浮动查词窗口，支持固定、关闭及取消查询。
- 获取选词所在的原句和段落；无法可靠定位时明确提示语境不足。
- 本地 Ollama 释义，以及用户主动触发的 DeepSeek 云端辅助。
- 内置 Open English Wordnet 英文词典参考及常见词形查询。
- Chromium 浏览器扩展、Safari 选词路径与 Obsidian 桌面插件。
- 浅色和深色外观跟随 macOS。

AI 释义用于辅助理解，可能出现错误。参考词典与 AI 结果分别标注；
没有抓到原句时，不会将推测文本当成已确认的原句。

## 安装与开始使用

系统要求为 **macOS 14 或更新版本**。下载时请选择与你的芯片架构相符的安装包。
正式应用安装包以 Releases 实际列出的资产为准；没有安装包时可按下方步骤从源码构建。
下载源码 ZIP 不等于已安装应用。目前尚无经过公证的公开安装包。

1. 安装并打开 Dictionary。
2. 安装 [Ollama](https://ollama.com/download)，准备本地模型，默认模型为 `qwen2.5:7b`。
3. 在 **Dictionary → 偏好设置 → 本地模型** 检查服务和模型。模型列表可用不代表释义质量已通过验证。
4. 在主窗口输入英文并查询；补充完整原句有助于理解词义。
5. 使用其他软件内的 ⌥D 查词时，按系统提示为 Dictionary 开启选词权限。

本地模型独立安装，不包含在应用安装包中。不同模型和硬件的速度、质量有所不同。
DeepSeek 是可选的第二个释义来源：在 **偏好设置 → 云端辅助** 保存自己的 API 密钥，
待原始查询完成（成功或失败）后点击 **询问 DeepSeek**。调用可能产生费用。
当前默认查询仍走本地服务，云端不会自动接管查询。

## 支持的阅读方式

| 场景 | 接入方式 |
| --- | --- |
| 主窗口 | 手动输入英文和语境，无需选词权限 |
| Apple Books | ⌥D；语境取决于可读取的选区和文本，重复词或页面片段可能仅返回单词 |
| Chrome / Edge / Brave 等 | 安装随源码提供的 Chromium 扩展并配置本机令牌 |
| Safari | 配置 Safari JavaScript 与自动化授权，详见使用指南 |
| Obsidian 桌面版 | 安装配套插件并配置本机令牌 |
| 其他 macOS 应用 | 尝试系统辅助功能和复制回退；并非所有软件都能提供上下文 |

本项目提供 macOS 应用，不提供 Windows、Linux 或移动端客户端。
图片、扫描件、受保护页面和不开放文本的软件不保证能够读取语境。

## 更新

通过 GitHub Releases 发布版本、安装包、校验值和更新说明。
应用菜单 **查看更新与下载…** 打开同一版本页面；下载后退出旧版，将新版放回“应用程序”。
当前采用手动更新，不会在后台下载或自动替换应用。官网也以同一个版本页面作为下载来源。

## 从源码构建

需要 Xcode 或兼容的 Swift 6 工具链，以及用于脚本和扩展测试的 Node.js。

```sh
git clone https://github.com/liyunhui0707/dictionary-macos.git
cd dictionary-macos
swift test
node --test Tests/QA/*.test.cjs Tests/Extensions/*.test.cjs
node scripts/qa-app.mjs build
```

最后一条命令在 `build/qa/<build-id>/Dictionary.app` 生成独立应用包，并保存构建清单。
默认使用临时签名，适合本地构建；跨机器分发请遵循 [发布流程](docs/releasing.md)。
在有开发证书的机器上，固定测试路径可使用 `build-testing --signing-identity <证书指纹>`
与 `stage-testing <构建目录>`；不要为每次修改重建系统权限条目。

普通测试使用合成文本与受控服务，不需要真实书籍、API 密钥或运行中的本地模型。
可选实机、渲染和模型评估测试默认跳过；自动测试通过不等同于上下文释义准确率保证。

## 贡献与许可

欢迎通过 Issues 提交可复现的问题，或通过 Pull Request 贡献改进。
请使用合成语句复现，不提交密钥、个人书籍内容、聊天记录或机器配置。
参见 [贡献说明](CONTRIBUTING.md) 和 [安全说明](SECURITY.md)。

应用代码采用 [MIT License](LICENSE)。内置 Open English Wordnet 及其底层数据保留各自许可和署名，
见 [第三方声明](THIRD_PARTY_NOTICES.md)。模型及服务遵循其各自条款。

# RDGDesk

**简体中文** | [English](README.en.md)

RDGDesk 是一款独立开发的原生 macOS 远程桌面客户端，兼容 Microsoft Remote Desktop Connection Manager（RDCMan）导出的 `.rdg` 资源库，并使用内置 FreeRDP 建立远程会话。

> 当前支持搭载 Apple 芯片、运行 macOS 26 或更高版本的 Mac。项目仍在积极开发中；用于关键系统前，请先阅读安全模型并在非生产环境中完成测试。

## 界面预览

![RDGDesk 资源库与远程桌面](docs/images/rdgdesk-main.png)

| 通用设置 | 证书管理 | 连接诊断 |
| --- | --- | --- |
| ![RDGDesk 通用设置](docs/images/rdgdesk-settings.png) | ![RDGDesk 证书管理](docs/images/rdgdesk-security.png) | ![RDGDesk 连接诊断](docs/images/rdgdesk-connection.png) |

## 现有功能

- 导入、搜索、恢复和浏览经过脱敏处理、兼容 RDCMan 的资源库。
- 在原生远程画布中连接服务器，并转发鼠标、滚轮、扫描码键盘、中文输入法/Unicode、焦点、全屏和窗口尺寸变化事件。
- 发送 `Ctrl+Alt+Del`、手动发送本机文本剪贴板，并接收远程文本剪贴板更新。剪贴板仅支持文本，大小限制为 1 MB；本机文本绝不会自动发送。
- 保存全局、分组和服务器级凭据。密码以通用密码项目保存在 macOS 钥匙串中；JSON 配置只保存非敏感元数据和绑定关系。
- 按以下顺序解析凭据：服务器覆盖、最近分组、上级分组、全局凭据，最后是仅使用一次的输入提示。
- 首次使用证书或证书指纹发生变化时，必须明确作出选择。`信任一次` 只对当前连接有效；`始终信任` 保存端点 SHA-256 指纹；`取消` 拒绝连接。已保存且匹配的指纹再次连接时不会弹出确认窗口。
- 分别识别 DNS、超时、拒绝连接、TLS/协议、证书、身份验证、远程断开、钥匙串和配置错误。

受 Windows DPAPI 保护的 RDCMan 密码不会在 macOS 上解密，并会从恢复后的本地快照中移除。

## 运行应用

首先安装构建依赖：

```bash
brew install cmake ninja pkg-config openssl@3
./scripts/bootstrap-freerdp.sh
```

在项目目录中运行：

```bash
./scripts/run.sh
```

从侧边栏导入 `.rdg` 文件，选择服务器后点击 `连接`。打开 `RDGDesk > 设置…`，或点击侧边栏底部的齿轮，可以配置：

- `通用`：启动时恢复上次资源库、双击连接和远程画面跟随窗口尺寸。
- `全局凭据`：保存、更新或删除继承使用的钥匙串凭据。
- `凭据覆盖`：搜索分组/服务器、设置覆盖凭据或恢复继承。
- `证书`：查看或删除为后续连接保存的端点指纹。
- `关于`：查看版本和隐私信息。

仅供调试的 `使用外部客户端调试` 操作会创建临时 `.rdp` 文件。普通连接始终使用内置 FreeRDP。

## 创建自用安装包

```bash
RDC_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/package-app.sh --dmg
```

该命令会生成 `dist/RDGDesk.app` 和 `dist/RDGDesk.dmg`，将 FreeRDP/OpenSSL 运行库及其许可证文本打包到应用中，并应用临时签名。此安装包适合在所有者自己的 Mac 上使用。由于它没有使用 Developer ID 签名，也没有经过 Apple 公证，macOS 首次启动时可能需要按住 Control 点击应用并选择 `打开`。公开分发需要付费 Apple Developer 身份、Hardened Runtime 签名、公证，以及针对具体发行版本的第三方依赖审计。

## 开发与验证

```bash
./scripts/test.sh
./scripts/test-bootstrap-freerdp.sh all
./scripts/build.sh
bash -n scripts/*.sh
```

在禁止嵌套 `sandbox-exec` 的受管环境中，可以使用：

```bash
RDC_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/build.sh
./scripts/test.sh --disable-sandbox
```

真实服务器测试默认关闭，需要同时设置 `RDC_TEST_HOST`、`RDC_TEST_PORT`、`RDC_TEST_USER`、`RDC_TEST_DOMAIN`、`RDC_TEST_PASSWORD` 和 `RDC_TEST_EXPECTED_SHA256`。SHA-256 可以使用大写或小写、以冒号分隔。配置缺失或无效时，错误信息不会输出环境变量值。真实钥匙串集成测试需另行设置 `RDC_TEST_KEYCHAIN=1`；测试使用随机的 `integration-<UUID>` 项目 ID，并在完成后清理。

私有大型资源库验收测试默认关闭，可通过 `RDC_TEST_RDG_PATH=/absolute/path/to/library.rdg` 启用。切勿提交真实 `.rdg` 文件：文件中可能包含内部主机名、服务器地址、用户名和 Windows DPAPI 密文。

不要把密码写入源代码、测试夹具、命令输出、Issue 或验证文档。真实凭据只能在本机环境或应用的安全界面中输入。

## 项目结构

- `Sources/RdcApp`：SwiftUI/AppKit 应用、设置、凭据、证书和远程画布界面。
- `Sources/RdcCore`：解析器、脱敏持久化、钥匙串保管库、信任协调和内置会话引擎。
- `Tests/RdcCoreTests`：可重复的单元测试和本地回环测试。
- `Tests/RdcAppTests`：应用工作流和界面呈现测试。
- `Tests/RdcFreeRDPIntegrationTests`：可重复的证书指纹变化测试，以及可选的真实服务器和钥匙串工作流测试。
- `scripts`：可重复执行的依赖安装、构建、运行、测试和范围验证命令。

## 安全

请按照 [SECURITY.md](SECURITY.md) 的说明私密报告安全漏洞。不要在公开 Issue 中包含真实凭据、`.rdg` 文件、证书指纹、服务器地址或连接日志。

## 兼容性与商标

RDGDesk 是独立项目，与 Microsoft 不存在关联，也未获得 Microsoft 的赞助、认可或分发授权。Microsoft、Windows、Remote Desktop Connection Manager、RDCMan 及其他 Microsoft 产品名称仅以普通文本用于描述文件格式和协议兼容性；相关名称和商标归各自权利人所有。

RDGDesk 不包含 Microsoft 标志、Windows 界面素材、RDCMan 二进制文件或 Microsoft 源代码。

独立商标声明请参阅 [TRADEMARKS.md](TRADEMARKS.md)。

## 许可证与第三方软件

RDGDesk 源代码采用 [MIT License](LICENSE) 开源。项目集成 FreeRDP 和 OpenSSL；署名及再分发说明请参阅 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

# RDGDesk Complete Endpoint Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让“添加服务器”和“服务器属性”地址栏直接接受 `host:port` 与 `[IPv6]:port`，并在不改写独立端口框的前提下优先使用地址内端口。

**Architecture:** 在 `RdcApp` 资源库表单层新增无状态 `ServerEndpointInputParser`，把原始地址与独立端口解析为规范化主机和最终端口。新增与属性编辑模型共享该解析器，再继续生成现有 `ServerPropertiesDraft`；`.rdg` 解析、资源库存储与 FreeRDP 连接边界保持不变。

**Tech Stack:** Swift 6.2、SwiftUI、Combine、XCTest、Swift Package Manager、现有 `RdcCore.ServerPropertiesDraft` 校验与打包脚本。

## Global Constraints

- 支持域名、IPv4、裸 IPv6、`host:port`、`IPv4:port`、`[IPv6]` 和 `[IPv6]:port`。
- IPv6 携带端口时必须使用方括号；裸 IPv6 永远按完整主机处理。
- 地址自带有效端口时优先使用该端口，但绝不改写独立端口文本。
- 地址自带有效端口时，独立端口为空、非法或不同都不阻止保存。
- 地址不带端口时继续要求独立端口为 `1...65535` 的整数。
- 新增表单的自动名称使用解析后的纯主机，不包含方括号和端口。
- 地址和端口最终仍分开写入 `ServerPropertiesDraft`，不改变资源库持久化格式。
- 默认中文 UI；中文和英文 README 同步说明完整地址输入。
- 不保存真实测试服务器，不记录账号密码，不自动发起远程连接。
- 每个生产改动必须先有因功能缺失而失败的测试。

---

### Task 1: Shared endpoint parser

**Files:**
- Create: `Sources/RdcApp/ResourceLibrary/ServerEndpointInput.swift`
- Create: `Tests/RdcAppTests/ServerEndpointInputTests.swift`

**Interfaces:**
- Consumes: `RdcCore.ServerPropertiesDraft.validated()` 作为最终主机格式校验器。
- Produces: `ServerEndpointInputParser.resolve(address:portText:) throws -> ServerEndpointInputResolution`、`ServerEndpointInputResolution`、`ServerEndpointInputValidationError`。

- [ ] **Step 1: Write failing parser tests**

Create `Tests/RdcAppTests/ServerEndpointInputTests.swift`:

```swift
import XCTest
@testable import RdcApp

final class ServerEndpointInputTests: XCTestCase {
    func testResolvesEmbeddedPortsForDNSIPv4AndBracketedIPv6() throws {
        let cases = [
            (" q6id.cn:6609 ", "q6id.cn", 6_609),
            ("192.168.1.10:6609", "192.168.1.10", 6_609),
            ("[2001:db8::10]:6609", "2001:db8::10", 6_609)
        ]

        for (address, expectedHost, expectedPort) in cases {
            let result = try ServerEndpointInputParser.resolve(
                address: address,
                portText: "3389"
            )
            XCTAssertEqual(result.host, expectedHost)
            XCTAssertEqual(result.port, expectedPort)
            XCTAssertTrue(result.usesEmbeddedPort)
        }
    }

    func testUsesSeparatePortForPlainHostsBareIPv6AndBracketedIPv6() throws {
        for address in ["q6id.cn", "192.168.1.10", "2001:db8::10", "[2001:db8::10]"] {
            let result = try ServerEndpointInputParser.resolve(
                address: address,
                portText: " 6609 "
            )
            XCTAssertEqual(result.port, 6_609)
            XCTAssertFalse(result.usesEmbeddedPort)
        }
        XCTAssertEqual(
            try ServerEndpointInputParser.resolve(
                address: "2001:db8::10", portText: "6609"
            ).host,
            "2001:db8::10"
        )
    }

    func testRejectsInvalidEmbeddedPortsAndMalformedAddresses() {
        for address in ["q6id.cn:", "q6id.cn:0", "q6id.cn:65536", "q6id.cn:abc"] {
            XCTAssertThrowsError(
                try ServerEndpointInputParser.resolve(address: address, portText: "3389")
            ) {
                XCTAssertEqual(
                    $0 as? ServerEndpointInputValidationError,
                    .invalidEmbeddedPort
                )
            }
        }

        for address in [
            "", "https://q6id.cn:6609", "[2001:db8::10", "[q6id.cn]:6609",
            "[2001:db8::10]extra", "999.1.1.1:6609"
        ] {
            XCTAssertThrowsError(
                try ServerEndpointInputParser.resolve(address: address, portText: "3389")
            ) {
                XCTAssertEqual($0 as? ServerEndpointInputValidationError, .invalidHost)
            }
        }
    }

    func testEmbeddedPortIgnoresSeparatePortButPlainHostValidatesIt() throws {
        let embedded = try ServerEndpointInputParser.resolve(
            address: "q6id.cn:6609",
            portText: "not-a-port"
        )
        XCTAssertEqual(embedded.port, 6_609)
        XCTAssertTrue(embedded.usesEmbeddedPort)

        for portText in ["", "0", "65536", "not-a-port"] {
            XCTAssertThrowsError(
                try ServerEndpointInputParser.resolve(
                    address: "q6id.cn", portText: portText
                )
            ) {
                XCTAssertEqual($0 as? ServerEndpointInputValidationError, .invalidPort)
            }
        }
    }

    func testAcceptsPortBoundaries() throws {
        XCTAssertEqual(
            try ServerEndpointInputParser.resolve(
                address: "q6id.cn:1", portText: "3389"
            ).port,
            1
        )
        XCTAssertEqual(
            try ServerEndpointInputParser.resolve(
                address: "q6id.cn:65535", portText: "3389"
            ).port,
            65_535
        )
    }
}
```

- [ ] **Step 2: Run parser tests and verify RED**

Run:

```bash
./scripts/test.sh --filter ServerEndpointInputTests
```

Expected: compilation fails because `ServerEndpointInputParser`, `ServerEndpointInputResolution`, and `ServerEndpointInputValidationError` do not exist.

- [ ] **Step 3: Implement the minimal shared parser**

Create `Sources/RdcApp/ResourceLibrary/ServerEndpointInput.swift`:

```swift
import Foundation
import RdcCore

struct ServerEndpointInputResolution: Equatable {
    let host: String
    let port: Int
    let usesEmbeddedPort: Bool
}

enum ServerEndpointInputValidationError: Error, Equatable {
    case invalidHost
    case invalidEmbeddedPort
    case invalidPort

    var message: String {
        switch self {
        case .invalidHost:
            "请输入有效的 IP 地址或主机名。"
        case .invalidEmbeddedPort:
            "地址中的端口必须是 1–65535 之间的整数。"
        case .invalidPort:
            "端口必须是 1–65535 之间的整数。"
        }
    }
}

enum ServerEndpointInputParser {
    static func resolve(
        address: String,
        portText: String
    ) throws -> ServerEndpointInputResolution {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("://"),
              !value.contains("/"),
              !value.contains("?"),
              !value.contains("@") else {
            throw ServerEndpointInputValidationError.invalidHost
        }

        if value.hasPrefix("[") {
            return try resolveBracketed(address: value, portText: portText)
        }

        if let host = validatedHost(value) {
            return try resolveSeparatePort(host: host, portText: portText)
        }

        guard value.filter({ $0 == ":" }).count == 1,
              let separator = value.firstIndex(of: ":") else {
            throw ServerEndpointInputValidationError.invalidHost
        }
        let hostText = String(value[..<separator])
        let embeddedPortText = String(value[value.index(after: separator)...])
        guard let host = validatedHost(hostText) else {
            throw ServerEndpointInputValidationError.invalidHost
        }
        guard let port = parsedPort(embeddedPortText) else {
            throw ServerEndpointInputValidationError.invalidEmbeddedPort
        }
        return ServerEndpointInputResolution(
            host: host, port: port, usesEmbeddedPort: true
        )
    }

    private static func resolveBracketed(
        address: String,
        portText: String
    ) throws -> ServerEndpointInputResolution {
        guard let closing = address.firstIndex(of: "]") else {
            throw ServerEndpointInputValidationError.invalidHost
        }
        let hostText = String(address[address.index(after: address.startIndex)..<closing])
        guard hostText.contains(":"), let host = validatedHost(hostText) else {
            throw ServerEndpointInputValidationError.invalidHost
        }
        let suffix = String(address[address.index(after: closing)...])
        if suffix.isEmpty {
            return try resolveSeparatePort(host: host, portText: portText)
        }
        guard suffix.hasPrefix(":"), suffix.filter({ $0 == ":" }).count == 1,
              let port = parsedPort(String(suffix.dropFirst())) else {
            if suffix.hasPrefix(":") {
                throw ServerEndpointInputValidationError.invalidEmbeddedPort
            }
            throw ServerEndpointInputValidationError.invalidHost
        }
        return ServerEndpointInputResolution(
            host: host, port: port, usesEmbeddedPort: true
        )
    }

    private static func resolveSeparatePort(
        host: String,
        portText: String
    ) throws -> ServerEndpointInputResolution {
        guard let port = parsedPort(portText) else {
            throw ServerEndpointInputValidationError.invalidPort
        }
        return ServerEndpointInputResolution(
            host: host, port: port, usesEmbeddedPort: false
        )
    }

    private static func parsedPort(_ value: String) -> Int? {
        guard let port = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port) else { return nil }
        return port
    }

    private static func validatedHost(_ value: String) -> String? {
        try? ServerPropertiesDraft(
            displayName: "Server", host: value, port: 3_389
        ).validated().host
    }
}
```

- [ ] **Step 4: Run parser tests and verify GREEN**

Run:

```bash
./scripts/test.sh --filter ServerEndpointInputTests
```

Expected: all `ServerEndpointInputTests` pass with zero failures.

- [ ] **Step 5: Run existing host-validation regression tests**

Run:

```bash
./scripts/test.sh --filter ResourceLibraryEditorTests/testServerDraft
```

Expected: existing core host validation remains unchanged and all selected tests pass.

- [ ] **Step 6: Commit parser and tests**

```bash
git add Sources/RdcApp/ResourceLibrary/ServerEndpointInput.swift Tests/RdcAppTests/ServerEndpointInputTests.swift
git commit -m "feat: parse complete server addresses"
```

---

### Task 2: Add-server form integration

**Files:**
- Modify: `Sources/RdcApp/ResourceLibrary/NewServerModels.swift`
- Modify: `Tests/RdcAppTests/SettingsPresentationTests.swift`

**Interfaces:**
- Consumes: `ServerEndpointInputParser.resolve(address:portText:)` from Task 1.
- Produces: `NewServerEditorModel.draft` containing the resolved host and final port; `hostError` and `portError` mapped to the parser's exact Chinese messages.

- [ ] **Step 1: Write failing add-form model tests**

Add to `SettingsPresentationTests`:

```swift
func testNewServerEditorUsesEmbeddedPortWithoutChangingPortField() {
    let editor = NewServerEditorModel()

    editor.updateHost(" q6id.cn:6609 ")

    XCTAssertEqual(editor.name, "q6id.cn")
    XCTAssertEqual(editor.portText, "3389")
    XCTAssertNil(editor.hostError)
    XCTAssertNil(editor.portError)
    XCTAssertEqual(
        editor.draft,
        ServerPropertiesDraft(displayName: "q6id.cn", host: "q6id.cn", port: 6_609)
    )
}

func testNewServerEditorEmbeddedPortIgnoresInvalidSeparatePort() {
    let editor = NewServerEditorModel()
    editor.portText = "invalid"

    editor.updateHost("[2001:db8::10]:6609")

    XCTAssertEqual(editor.portText, "invalid")
    XCTAssertNil(editor.hostError)
    XCTAssertNil(editor.portError)
    XCTAssertEqual(editor.draft?.host, "2001:db8::10")
    XCTAssertEqual(editor.draft?.port, 6_609)
    XCTAssertTrue(editor.canSave)
}

func testNewServerEditorReportsEmbeddedPortSeparately() {
    let editor = NewServerEditorModel()
    editor.updateHost("q6id.cn:70000")

    XCTAssertEqual(
        editor.hostError,
        "地址中的端口必须是 1–65535 之间的整数。"
    )
    XCTAssertNil(editor.portError)
    XCTAssertFalse(editor.canSave)
}
```

- [ ] **Step 2: Run add-form tests and verify RED**

Run:

```bash
./scripts/test.sh --filter SettingsPresentationTests/testNewServerEditor
```

Expected: new tests fail because the current editor passes the full `host:port` string into `ServerPropertiesDraft` and still validates the independent port.

- [ ] **Step 3: Route add-form validation through the parser**

In `NewServerEditorModel`, add one shared computed result:

```swift
private var endpointResult: Result<
    ServerEndpointInputResolution,
    ServerEndpointInputValidationError
> {
    do {
        return .success(try ServerEndpointInputParser.resolve(
            address: host,
            portText: portText
        ))
    } catch let error as ServerEndpointInputValidationError {
        return .failure(error)
    } catch {
        return .failure(.invalidHost)
    }
}
```

Change `updateHost(_:)` so automatic naming uses the parsed host when available and never writes to `portText`:

```swift
func updateHost(_ value: String) {
    host = value
    if !didEditName {
        name = (try? ServerEndpointInputParser.resolve(
            address: value,
            portText: portText
        ).host) ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

Replace `hostError`, `portError`, and the host/port part of `draft` with:

```swift
var hostError: String? {
    guard case let .failure(error) = endpointResult,
          error != .invalidPort else { return nil }
    return error.message
}

var portError: String? {
    guard case .failure(.invalidPort) = endpointResult else { return nil }
    return ServerEndpointInputValidationError.invalidPort.message
}

var draft: ServerPropertiesDraft? {
    guard nameError == nil,
          case let .success(endpoint) = endpointResult else { return nil }
    return try? ServerPropertiesDraft(
        displayName: name,
        host: endpoint.host,
        port: endpoint.port
    ).validated()
}
```

- [ ] **Step 4: Run add-form tests and verify GREEN**

Run:

```bash
./scripts/test.sh --filter SettingsPresentationTests/testNewServerEditor
```

Expected: all add-server editor tests pass with zero failures.

- [ ] **Step 5: Commit add-form integration**

```bash
git add Sources/RdcApp/ResourceLibrary/NewServerModels.swift Tests/RdcAppTests/SettingsPresentationTests.swift
git commit -m "feat: accept complete addresses when adding servers"
```

---

### Task 3: Server-properties integration and UI copy

**Files:**
- Modify: `Sources/RdcApp/ResourceLibrary/ResourcePropertyModels.swift`
- Modify: `Sources/RdcApp/ResourceLibrary/NewServerSheet.swift`
- Modify: `Sources/RdcApp/ResourceLibrary/ResourcePropertySheets.swift`
- Modify: `Tests/RdcAppTests/SettingsPresentationTests.swift`

**Interfaces:**
- Consumes: `ServerEndpointInputParser.resolve(address:portText:)` from Task 1.
- Produces: `ServerPropertyEditorModel.draft` with resolved host and port while preserving the displayed independent port text; both address text fields use the exact placeholder `IP 地址、域名或完整地址`.

- [ ] **Step 1: Replace the old rejection test with failing support tests**

Replace `testServerPropertyEditorRejectsEmbeddedPortAndAcceptsBareIPv6` with:

```swift
func testServerPropertyEditorAcceptsEmbeddedPortAndKeepsSeparatePortText() {
    let editor = ServerPropertyEditorModel(
        server: editableServerFixture(), credentialSummary: "继承凭据"
    )
    editor.portText = "invalid"

    editor.host = "q6id.cn:6609"

    XCTAssertEqual(editor.portText, "invalid")
    XCTAssertNil(editor.hostError)
    XCTAssertNil(editor.portError)
    XCTAssertEqual(editor.draft?.host, "q6id.cn")
    XCTAssertEqual(editor.draft?.port, 6_609)
    XCTAssertTrue(editor.canSave)
}

func testServerPropertyEditorAcceptsBracketedIPv6AndBareIPv6() {
    let editor = ServerPropertyEditorModel(
        server: editableServerFixture(), credentialSummary: "继承凭据"
    )

    editor.host = "[2001:db8::10]:6609"
    XCTAssertEqual(editor.draft?.host, "2001:db8::10")
    XCTAssertEqual(editor.draft?.port, 6_609)

    editor.host = "2001:db8::10"
    editor.portText = "3390"
    XCTAssertNil(editor.hostError)
    XCTAssertEqual(editor.draft?.host, "2001:db8::10")
    XCTAssertEqual(editor.draft?.port, 3_390)
}

func testServerPropertyEditorTreatsEquivalentCompleteAddressAsUnchanged() {
    let editor = ServerPropertyEditorModel(
        server: editableServerFixture(), credentialSummary: "继承凭据"
    )

    editor.host = "rdp.example.com:3389"

    XCTAssertEqual(editor.draft?.host, "rdp.example.com")
    XCTAssertEqual(editor.draft?.port, 3_389)
    XCTAssertFalse(editor.canSave)
}
```

- [ ] **Step 2: Run property tests and verify RED**

Run:

```bash
./scripts/test.sh --filter SettingsPresentationTests/testServerPropertyEditor
```

Expected: new complete-address assertions fail because `ServerPropertyEditorModel` still rejects embedded ports.

- [ ] **Step 3: Route property validation through the shared parser**

Add the same `endpointResult` computed property used by `NewServerEditorModel` to `ServerPropertyEditorModel`:

```swift
private var endpointResult: Result<
    ServerEndpointInputResolution,
    ServerEndpointInputValidationError
> {
    do {
        return .success(try ServerEndpointInputParser.resolve(
            address: host,
            portText: portText
        ))
    } catch let error as ServerEndpointInputValidationError {
        return .failure(error)
    } catch {
        return .failure(.invalidHost)
    }
}
```

Replace `hostError`, `portError`, and `draft` with:

```swift
var hostError: String? {
    guard case let .failure(error) = endpointResult,
          error != .invalidPort else { return nil }
    return error.message
}

var portError: String? {
    guard case .failure(.invalidPort) = endpointResult else { return nil }
    return ServerEndpointInputValidationError.invalidPort.message
}

var draft: ServerPropertiesDraft? {
    guard nameError == nil,
          case let .success(endpoint) = endpointResult else { return nil }
    return try? ServerPropertiesDraft(
        displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
        host: endpoint.host,
        port: endpoint.port
    ).validated()
}
```

Keep `original` unchanged so `canSave` compares the resolved draft with the persisted host and port.

- [ ] **Step 4: Update both address-field placeholders**

In `NewServerSheet.swift`, replace:

```swift
TextField("IP 地址或域名", text: Binding(
```

with:

```swift
TextField("IP 地址、域名或完整地址", text: Binding(
```

In `ResourcePropertySheets.swift`, replace:

```swift
TextField("IP 地址或主机名", text: $editor.host)
```

with:

```swift
TextField("IP 地址、域名或完整地址", text: $editor.host)
```

- [ ] **Step 5: Run all presentation tests and verify GREEN**

Run:

```bash
./scripts/test.sh --filter SettingsPresentationTests
```

Expected: all presentation tests pass with zero failures.

- [ ] **Step 6: Verify the exact UI strings**

Run:

```bash
rg -n 'IP 地址、域名或完整地址' Sources/RdcApp/ResourceLibrary/NewServerSheet.swift Sources/RdcApp/ResourceLibrary/ResourcePropertySheets.swift
```

Expected: exactly one match in each file.

- [ ] **Step 7: Commit property and UI integration**

```bash
git add Sources/RdcApp/ResourceLibrary/ResourcePropertyModels.swift Sources/RdcApp/ResourceLibrary/NewServerSheet.swift Sources/RdcApp/ResourceLibrary/ResourcePropertySheets.swift Tests/RdcAppTests/SettingsPresentationTests.swift
git commit -m "feat: accept complete addresses in server properties"
```

---

### Task 4: Documentation, full verification, package, and local acceptance

**Files:**
- Modify: `README.md`
- Modify: `README.en.md`
- Generated and ignored: `dist/RDGDesk.app`
- Generated and ignored: `dist/RDGDesk.dmg`

**Interfaces:**
- Consumes: the complete-address behavior from Tasks 1–3.
- Produces: bilingual usage documentation, a verified app bundle and DMG, and a locally installed `/Applications/RDGDesk.app`.

- [ ] **Step 1: Update Chinese and English capability copy**

Change the Chinese manual-server capability bullet to:

```markdown
- 无需 `.rdg` 即可手动添加 IPv4、IPv6 或域名服务器；地址栏支持直接输入 `q6id.cn:6609`、`192.168.1.10:6609` 或 `[2001:db8::10]:6609`。首次添加会创建本地“我的服务器”资源库，也可从分组菜单直接添加，并继承全局凭据。
```

Change the English equivalent to:

```markdown
- Add IPv4, IPv6, or DNS servers without an `.rdg` file. The address field accepts complete endpoints such as `q6id.cn:6609`, `192.168.1.10:6609`, and `[2001:db8::10]:6609`. The first server creates a local “My Servers” library, group menus can add directly to a destination, and new servers inherit global credentials.
```

- [ ] **Step 2: Run the complete test suite**

Run:

```bash
set -o pipefail
./scripts/test.sh 2>&1 | tail -40
```

Expected: `All tests` passes with zero failures; only pre-existing opt-in skips are allowed.

- [ ] **Step 3: Run build and source checks**

Run:

```bash
./scripts/build.sh
bash -n scripts/*.sh
git diff --check
```

Expected: build exits 0, shell syntax checks exit 0, and `git diff --check` prints nothing.

- [ ] **Step 4: Commit documentation**

```bash
git add README.md README.en.md
git commit -m "docs: document complete server addresses"
```

- [ ] **Step 5: Build and verify the final app and DMG**

Run:

```bash
RDC_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/package-app.sh --dmg
codesign --verify --deep --strict dist/RDGDesk.app
hdiutil verify dist/RDGDesk.dmg
shasum -a 256 dist/RDGDesk.dmg dist/RDGDesk.app/Contents/MacOS/Rdc
```

Expected: packaging exits 0, code-sign verification exits 0, DMG checksum is valid, and both SHA-256 values are printed.

- [ ] **Step 6: Cover-install and open the verified build**

After obtaining user approval for replacing the installed app, run:

```bash
pkill -x Rdc || true
rm -rf /Applications/RDGDesk.app
ditto dist/RDGDesk.app /Applications/RDGDesk.app
open /Applications/RDGDesk.app
```

Expected: `/Applications/RDGDesk.app` opens and the old process is no longer running.

- [ ] **Step 7: Perform non-destructive UI acceptance**

Using the application UI:

1. Open `添加服务器…`.
2. Enter `q6id.cn:6609` in the address field without saving.
3. Verify the generated name is `q6id.cn`, the independent port remains `3389`, and the Add button is enabled.
4. Cancel the sheet.
5. Open an existing server's properties only if a non-sensitive local fixture is available; otherwise rely on the property-model tests and do not inspect user credentials.
6. Do not save, connect, alter Keychain items, or modify the user's resource library.

Expected: the complete endpoint validates without changing the independent port field or external state.

- [ ] **Step 8: Final branch review and integration choice**

Run:

```bash
git status --short
git log --oneline --decorate -6
```

Expected: tracked worktree is clean and all feature commits are present. Then use `superpowers:requesting-code-review`, `superpowers:verification-before-completion`, and `superpowers:finishing-a-development-branch`; do not merge or push until the user chooses an integration option.

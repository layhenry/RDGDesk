# Manual Server Addition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户在没有 `.rdg` 文件时创建本地“我的服务器”资源库，并能从顶部入口或任意分组手动添加、持久化和连接服务器。

**Architecture:** 在 `RdcCore` 的快照编辑器中增加纯函数式服务器创建与手动资源统计；`RdcAppModel` 用现有配置仓库完成原子创建、发布和选择。SwiftUI 层增加独立的新服务器请求、编辑模型、受租约协调的表单，并为不同来源 `.rdg` 替换加入显式确认。

**Tech Stack:** Swift 6.2、SwiftUI、Combine、XCTest、Swift Package Manager、macOS Keychain、现有 FreeRDP 桥接层。

## Global Constraints

- 运行目标保持 Apple silicon Mac 和 macOS 26 或更高版本。
- 不增加第三方依赖，不改变现有 FreeRDP/OpenSSL 打包方式。
- 原始 `.rdg` 文件始终只读；手动服务器只写入 RDGDesk 本地配置。
- 手动服务器 ID 使用 UUID，`sourceFingerprint` 必须为 `nil`。
- 密码不得进入快照、日志、测试夹具或源码；新服务器默认继承现有全局凭据。
- 添加服务器只更新资源库和当前选择，不得断开正在运行的远程会话。
- 地址支持合法 IPv4、裸 IPv6、DNS 主机名；端口范围固定为 `1...65535`，默认 `3389`。
- 默认界面文案使用简体中文，英文 README 同步描述功能。
- 每个实现任务遵循先失败测试、再最小实现、再通过测试、再提交的顺序。

---

## File Structure

- `Sources/RdcCore/ResourceLibraryEditor.swift`：地址校验、手动资源统计、本地资源库工厂和纯函数式服务器创建。
- `Sources/RdcApp/Model/RdcAppModel.swift`：原子持久化、请求生命周期、自动选择，以及不同来源导入确认。
- `Sources/RdcApp/ResourceLibrary/NewServerModels.swift`：新服务器请求和表单状态，不放 SwiftUI 布局。
- `Sources/RdcApp/ResourceLibrary/NewServerSheet.swift`：新增服务器表单布局和保存交互。
- `Sources/RdcApp/ResourceLibrary/ResourcePropertyModels.swift`：把新服务器表单纳入现有多窗口/共享模态协调。
- `Sources/RdcApp/ResourceLibrary/ResourceLibraryMenus.swift`：顶部与分组菜单策略、分组入口。
- `Sources/RdcApp/RdcApplication.swift`：顶部 `+` 菜单、空状态、sheet 和替换确认接线。
- `Tests/RdcCoreTests/ResourceLibraryEditorTests.swift`：核心创建、校验、身份和合并测试。
- `Tests/RdcAppTests/RdcAppWorkflowTests.swift`：配置事务、重载、凭据继承和导入保护测试。
- `Tests/RdcAppTests/SettingsPresentationTests.swift`：表单模型、菜单顺序和租约互斥测试。
- `README.md`、`README.en.md`：中英文功能及使用说明。

---

### Task 1: Core manual-server creation and classification

**Files:**
- Modify: `Sources/RdcCore/ResourceLibraryEditor.swift`
- Test: `Tests/RdcCoreTests/ResourceLibraryEditorTests.swift`

**Interfaces:**
- Consumes: `ServerPropertiesDraft`, `RdcLibrarySnapshot`, `RdcGroupSnapshot`, `RdcServerSnapshot`。
- Produces: `ResourceServerCreationResult`, `ManualResourceImpact`, `ResourceLibraryEditor.makeLocalLibrary(name:)`, `ResourceLibraryEditor.createServer(in:parentID:draft:)`, `ResourceLibraryEditor.manualResourceImpact(in:)`。

- [ ] **Step 1: Write failing validation and creation tests**

Add these tests to `ResourceLibraryEditorTests`:

```swift
func testServerDraftTrimsHostAndRejectsMalformedDottedIPv4() throws {
    let validated = try ServerPropertiesDraft(
        displayName: "  测试机  ", host: "  203.0.113.170  ", port: 3_389
    ).validated()
    XCTAssertEqual(validated.displayName, "测试机")
    XCTAssertEqual(validated.host, "203.0.113.170")

    for host in ["999.54.202.170", "106.54.202.999", "1..2.3"] {
        XCTAssertThrowsError(
            try ServerPropertiesDraft(displayName: "Server", host: host, port: 3_389)
                .validated()
        ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .invalidHost) }
    }
}

func testCreateServerAddsMacOnlyNodeToExactGroup() throws {
    let snapshot = editableFixture()
    let parentID = try XCTUnwrap(snapshot.root.groups.first?.id)
    let result = try ResourceLibraryEditor.createServer(
        in: snapshot,
        parentID: parentID,
        draft: .init(displayName: "  手动服务器  ", host: "2001:db8::20", port: 3_390)
    )
    let created = try XCTUnwrap(
        result.snapshot.root.groups.first?.servers.first { $0.id == result.serverID }
    )
    XCTAssertEqual(created.displayName, "手动服务器")
    XCTAssertEqual(created.address, "[2001:db8::20]:3390")
    XCTAssertNotNil(UUID(uuidString: result.serverID))
    XCTAssertNil(created.sourceFingerprint)
    XCTAssertTrue(snapshot.root.groups.first?.servers.contains { $0.id == result.serverID } == false)
}

func testCreateServerRejectsMissingGroupWithoutChangingSnapshot() throws {
    let snapshot = editableFixture()
    XCTAssertThrowsError(
        try ResourceLibraryEditor.createServer(
            in: snapshot, parentID: "missing",
            draft: .init(displayName: "Server", host: "server.example", port: 3_389)
        )
    ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .missingResource) }
    XCTAssertEqual(snapshot, editableFixture())
}

func testLocalLibraryAndManualImpactExcludeImportedNodes() throws {
    let local = ResourceLibraryEditor.makeLocalLibrary()
    XCTAssertEqual(local.sourceID, ResourceLibraryEditor.localLibrarySourceID)
    XCTAssertEqual(local.sourceName, "我的服务器")
    XCTAssertEqual(local.root.name, "我的服务器")

    let rootID = try XCTUnwrap(local.root.id)
    let created = try ResourceLibraryEditor.createServer(
        in: local, parentID: rootID,
        draft: .init(displayName: "Local", host: "192.0.2.10", port: 3_389)
    )
    XCTAssertEqual(
        ResourceLibraryEditor.manualResourceImpact(in: created.snapshot),
        ManualResourceImpact(groupCount: 0, serverCount: 1)
    )
    XCTAssertEqual(
        ResourceLibraryEditor.manualResourceImpact(in: editableFixture()),
        ManualResourceImpact(groupCount: 0, serverCount: 0)
    )
}

func testSameSourceReimportPreservesManuallyCreatedServer() throws {
    let imported = editableFixture()
    let rootID = try XCTUnwrap(imported.root.id)
    let creation = try ResourceLibraryEditor.createServer(
        in: imported,
        parentID: rootID,
        draft: .init(displayName: "Manual", host: "192.0.2.40", port: 3_389)
    )
    let merged = ResourceLibraryEditor.mergeReimport(
        existing: creation.snapshot,
        imported: imported,
        restoreDeletedItems: false
    )
    XCTAssertTrue(merged.allServers.contains { $0.id == creation.serverID })
}
```

- [ ] **Step 2: Run the core tests and verify the new API is missing**

Run:

```bash
./scripts/test.sh --filter ResourceLibraryEditorTests
```

Expected: FAIL to compile because `createServer`, `makeLocalLibrary`, `ManualResourceImpact`, and `localLibrarySourceID` do not exist.

- [ ] **Step 3: Implement strict host validation and the core creation API**

In `ResourceLibraryEditor.swift`, trim `host`, distinguish numeric dotted IPv4 from DNS, and add these public types and methods:

```swift
public struct ResourceServerCreationResult: Equatable, Sendable {
    public let snapshot: RdcLibrarySnapshot
    public let serverID: String
}

public struct ManualResourceImpact: Equatable, Sendable {
    public let groupCount: Int
    public let serverCount: Int

    public init(groupCount: Int, serverCount: Int) {
        self.groupCount = groupCount
        self.serverCount = serverCount
    }

    public var isEmpty: Bool { groupCount == 0 && serverCount == 0 }
}

public enum ResourceLibraryEditor {
    public static let localLibrarySourceID = "rdgdesk-local-library-v1"

    public static func makeLocalLibrary(name: String = "我的服务器") -> RdcLibrarySnapshot {
        RdcLibrarySnapshot(
            sourceID: localLibrarySourceID,
            sourceName: name,
            document: RdcManDocument(
                programVersion: "2.7",
                schemaVersion: "3",
                root: RdcGroup(
                    name: name,
                    isExpanded: true,
                    logonCredentials: nil,
                    groups: [],
                    servers: []
                )
            )
        )
    }

    public static func createServer(
        in snapshot: RdcLibrarySnapshot,
        parentID: String,
        draft: ServerPropertiesDraft
    ) throws -> ResourceServerCreationResult {
        let validated = try draft.validated()
        let serverID = UUID().uuidString
        let serializedHost = validated.host.contains(":")
            ? "[\(validated.host)]" : validated.host
        var copy = snapshot
        guard mutateGroup(&copy.root, where: { parent in
            guard parent.id == parentID else { return false }
            var server = RdcServerSnapshot(server: RdcServer(
                displayName: validated.displayName,
                address: RdcServerAddress("\(serializedHost):\(validated.port)"),
                logonCredentials: nil
            ))
            server.id = serverID
            server.sourceFingerprint = nil
            parent.servers.append(server)
            return true
        }) else {
            throw ResourceLibraryEditError.missingResource
        }
        return ResourceServerCreationResult(snapshot: copy, serverID: serverID)
    }

    public static func manualResourceImpact(
        in snapshot: RdcLibrarySnapshot
    ) -> ManualResourceImpact {
        func collect(_ group: RdcGroupSnapshot, isRoot: Bool) -> ManualResourceImpact {
            let children = group.groups.map { collect($0, isRoot: false) }
            return ManualResourceImpact(
                groupCount: (isRoot || group.sourceFingerprint != nil ? 0 : 1)
                    + children.reduce(0) { $0 + $1.groupCount },
                serverCount: group.servers.filter { $0.sourceFingerprint == nil }.count
                    + children.reduce(0) { $0 + $1.serverCount }
            )
        }
        return collect(snapshot.root, isRoot: true)
    }
}
```

Update `ServerPropertiesDraft.validated()` to validate and return `trimmedHost`:

```swift
public func validated() throws -> ServerPropertiesDraft {
    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { throw ResourceLibraryEditError.emptyName }
    guard !trimmedHost.isEmpty,
          !trimmedHost.contains(where: { $0.isWhitespace }),
          !trimmedHost.contains("/"),
          !trimmedHost.contains("://"),
          !trimmedHost.contains("?"),
          !trimmedHost.contains("@"),
          !trimmedHost.contains("["),
          !trimmedHost.contains("]"),
          isValidHostShape(trimmedHost) else {
        throw ResourceLibraryEditError.invalidHost
    }
    guard (1...65_535).contains(port) else {
        throw ResourceLibraryEditError.invalidPort
    }
    return ServerPropertiesDraft(
        displayName: trimmedName, host: trimmedHost, port: port
    )
}

private func isValidHostShape(_ value: String) -> Bool {
    if value.contains(":" ) {
        guard value.filter({ $0 == ":" }).count >= 2 else { return false }
        var address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }
    if value.contains("."), value.allSatisfy({ $0.isNumber || $0 == "." }) {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }
    guard value.utf8.count <= 253 else { return false }
    let labels = value.split(separator: ".", omittingEmptySubsequences: false)
    return !labels.isEmpty && labels.allSatisfy { label in
        !label.isEmpty && label.utf8.count <= 63
            && label.first != "-" && label.last != "-"
            && label.allSatisfy { character in
                character.isASCII
                    && (character.isLetter || character.isNumber || character == "-")
            }
    }
}
```

- [ ] **Step 4: Run core tests**

Run:

```bash
./scripts/test.sh --filter ResourceLibraryEditorTests
```

Expected: all `ResourceLibraryEditorTests` pass.

- [ ] **Step 5: Commit the core API**

```bash
git add Sources/RdcCore/ResourceLibraryEditor.swift Tests/RdcCoreTests/ResourceLibraryEditorTests.swift
git commit -m "feat: add manual server snapshot creation"
```

---

### Task 2: Atomic app-model creation, persistence, and selection

**Files:**
- Modify: `Sources/RdcApp/Model/RdcAppModel.swift`
- Test: `Tests/RdcAppTests/RdcAppWorkflowTests.swift`

**Interfaces:**
- Consumes: Task 1 `ResourceLibraryEditor.makeLocalLibrary()` and `createServer(in:parentID:draft:)`.
- Produces: `RdcAppModel.createServer(targetGroupID:expectedSnapshot:draft:) async throws -> String`.

- [ ] **Step 1: Write failing workflow tests for empty and existing libraries**

Add to `RdcAppWorkflowTests`:

```swift
func testCreateServerBootstrapsLocalLibraryPersistsOnceAndSelectsServer() async throws {
    let store = AppControlledConfigurationStore(configuration: .default)
    let repository = RdcConfigurationRepository(store: store)
    let model = RdcAppModel(
        configurationRepository: repository,
        passwordStore: AppMemoryPasswordStore(),
        engine: AppRecordingSessionEngine()
    )
    await model.loadPersistedState()

    let serverID = try await model.createServer(
        targetGroupID: nil,
        expectedSnapshot: nil,
        draft: .init(displayName: "生产机", host: "203.0.113.170", port: 3_389)
    )

    XCTAssertEqual(await store.savedCount(), 1)
    XCTAssertEqual(model.library?.sourceName, "我的服务器")
    XCTAssertEqual(model.selectedServerID, serverID)
    XCTAssertEqual(model.selectedServer?.connectionRequest.host, "203.0.113.170")
    XCTAssertNil(model.configuration.serverCredentialBindings[serverID])

    let reloaded = RdcAppModel(
        configurationRepository: repository,
        passwordStore: AppMemoryPasswordStore(),
        engine: AppRecordingSessionEngine()
    )
    await reloaded.loadPersistedState()
    XCTAssertTrue(reloaded.library?.servers.contains { $0.id == serverID } == true)
    await reloaded.shutdownAndWait()
    await model.shutdownAndWait()
}

func testCreateServerAddsToRequestedGroupAndRejectsStaleSnapshot() async throws {
    let snapshot = RdcLibrarySnapshot(
        sourceID: "manual-target", sourceName: "example.rdg", document: nestedDocument()
    )
    let store = AppMemoryConfigurationStore(
        configuration: RdcAppConfiguration(lastLibrary: snapshot)
    )
    let repository = RdcConfigurationRepository(store: store)
    let model = RdcAppModel(
        configurationRepository: repository,
        passwordStore: AppMemoryPasswordStore(),
        engine: AppRecordingSessionEngine()
    )
    await model.loadPersistedState()
    let groupID = try XCTUnwrap(snapshot.root.groups.first?.id)
    let serverID = try await model.createServer(
        targetGroupID: groupID,
        expectedSnapshot: snapshot,
        draft: .init(displayName: "Group Server", host: "server.example", port: 3_390)
    )
    XCTAssertEqual(model.library?.servers.first { $0.id == serverID }?.groupPathIDs.last, groupID)

    await XCTAssertThrowsErrorAsync {
        _ = try await model.createServer(
            targetGroupID: groupID,
            expectedSnapshot: snapshot,
            draft: .init(displayName: "Stale", host: "stale.example", port: 3_389)
        )
    } verify: {
        XCTAssertEqual($0 as? ResourceLibraryOperationError, .libraryChanged)
    }
    await model.shutdownAndWait()
}

func testCreatedServerInheritsGlobalCredentialWithoutServerBinding() async throws {
    let globalID = "global-manual-server"
    let store = AppMemoryConfigurationStore(configuration: RdcAppConfiguration(
        globalCredentialID: globalID,
        credentialMetadata: [
            globalID: CredentialMetadata(id: globalID, username: "global-user", domain: nil)
        ]
    ))
    let model = RdcAppModel(
        configurationRepository: RdcConfigurationRepository(store: store),
        passwordStore: AppMemoryPasswordStore(),
        engine: AppRecordingSessionEngine()
    )
    await model.loadPersistedState()
    let serverID = try await model.createServer(
        targetGroupID: nil,
        expectedSnapshot: nil,
        draft: .init(displayName: "Inherited", host: "192.0.2.50", port: 3_389)
    )
    let server = try XCTUnwrap(model.library?.servers.first { $0.id == serverID })
    XCTAssertEqual(
        CredentialResolver.resolve(server: server, configuration: model.configuration),
        CredentialResolution(credentialID: globalID, source: .global)
    )
    XCTAssertNil(model.configuration.serverCredentialBindings[serverID])
    await model.shutdownAndWait()
}

func testCreateServerDoesNotDisconnectExistingSession() async throws {
    let snapshot = RdcLibrarySnapshot(
        sourceID: "manual-while-connected", sourceName: "example.rdg", document: testDocument()
    )
    let engine = AppRecordingSessionEngine()
    let model = makeModel(
        configuration: RdcAppConfiguration(lastLibrary: snapshot), engine: engine
    )
    await model.loadPersistedState()
    try await model.session.connect(
        server: try XCTUnwrap(model.selectedServer),
        credential: nil,
        viewport: .init(width: 800, height: 600)
    )
    let rootID = try XCTUnwrap(snapshot.root.id)
    _ = try await model.createServer(
        targetGroupID: rootID,
        expectedSnapshot: snapshot,
        draft: .init(displayName: "Second", host: "192.0.2.60", port: 3_389)
    )
    XCTAssertNotNil(model.session.descriptor)
    XCTAssertEqual(await engine.disconnectCount(), 0)
    await model.shutdownAndWait()
}
```

If the test target has no async throwing assertion helper, add this file-local helper with exact semantics:

```swift
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
```

- [ ] **Step 2: Run the focused app workflow tests**

Run:

```bash
./scripts/test.sh --filter RdcAppWorkflowTests/testCreateServer
./scripts/test.sh --filter RdcAppWorkflowTests/testCreatedServer
```

Expected: FAIL because `RdcAppModel.createServer` does not exist.

- [ ] **Step 3: Implement a single transactional create operation**

Add this method next to `createChildGroup` in `RdcAppModel`:

```swift
func createServer(
    targetGroupID: String?,
    expectedSnapshot: RdcLibrarySnapshot?,
    draft: ServerPropertiesDraft
) async throws -> String {
    var operationResult: Result<String, Error>?
    await performOperation { model, generation in
        do {
            let previous = try await model.configurationRepository.snapshot()
            guard model.isCurrentOperation(generation) else { throw CancellationError() }
            guard previous.lastLibrary == expectedSnapshot else {
                throw ResourceLibraryOperationError.libraryChanged
            }
            let base = previous.lastLibrary?.normalizedStableIdentity()
                ?? ResourceLibraryEditor.makeLocalLibrary()
            guard let destinationID = targetGroupID ?? base.root.id else {
                throw ResourceLibraryOperationError.missingLibrary
            }
            let creation = try ResourceLibraryEditor.createServer(
                in: base, parentID: destinationID, draft: draft
            )
            let committed = try await model.configurationRepository.update { configuration in
                guard configuration.lastLibrary == expectedSnapshot else {
                    throw ResourceLibraryOperationError.libraryChanged
                }
                configuration.lastLibrary = creation.snapshot
                return configuration
            }
            model.publishResourceConfiguration(
                committed, selectedServerID: creation.serverID
            )
            operationResult = .success(creation.serverID)
        } catch {
            let safeError = model.safeResourceOperationError(error)
            operationResult = .failure(safeError)
            guard model.isCurrentOperation(generation) else { return }
            model.resourceOperationMessage = model.safeResourceOperationMessage(for: safeError)
        }
    }
    guard let operationResult else { throw CancellationError() }
    return try operationResult.get()
}
```

The repository equality guard makes bootstrap and append one atomic save, while `publishResourceConfiguration(...selectedServerID:)` changes the selection only after commit.

- [ ] **Step 4: Run model workflow tests**

Run:

```bash
./scripts/test.sh --filter RdcAppWorkflowTests/testCreateServer
./scripts/test.sh --filter RdcAppWorkflowTests/testCreatedServer
```

Expected: all four new tests pass, the stored save count is exactly one for the bootstrap case, and creating a server does not disconnect the active session.

- [ ] **Step 5: Commit atomic creation**

```bash
git add Sources/RdcApp/Model/RdcAppModel.swift Tests/RdcAppTests/RdcAppWorkflowTests.swift
git commit -m "feat: persist manually added servers"
```

---

### Task 3: New-server request and editor state

**Files:**
- Create: `Sources/RdcApp/ResourceLibrary/NewServerModels.swift`
- Test: `Tests/RdcAppTests/SettingsPresentationTests.swift`

**Interfaces:**
- Consumes: `ServerPropertiesDraft`, `RdcLibrarySnapshot`, `ResourcePropertySheetCoordinator.HostLease`.
- Produces: `NewServerRequest` and `NewServerEditorModel` with `updateName(_:)`, `updateHost(_:)`, `draft`, `canSave`, and `save(using:)`.

- [ ] **Step 1: Write failing editor-model tests**

Add to `SettingsPresentationTests`:

```swift
func testNewServerEditorDefaultsPortAndOnlyAutoNamesUntilUserEditsName() {
    let editor = NewServerEditorModel()
    XCTAssertEqual(editor.portText, "3389")
    XCTAssertFalse(editor.canSave)

    editor.updateHost("203.0.113.170")
    XCTAssertEqual(editor.name, "203.0.113.170")
    XCTAssertTrue(editor.canSave)

    editor.updateName("生产服务器")
    editor.updateHost("192.0.2.171")
    XCTAssertEqual(editor.name, "生产服务器")
    XCTAssertEqual(editor.draft?.host, "192.0.2.171")
}

func testNewServerEditorExposesFieldErrorsAndKeepsInputAfterSaveFailure() async {
    let editor = NewServerEditorModel()
    editor.updateName("Server")
    editor.updateHost("999.1.1.1")
    editor.portText = "70000"
    XCTAssertEqual(editor.hostError, "请输入有效的 IP 地址或主机名。")
    XCTAssertEqual(editor.portError, "端口必须是 1–65535 之间的整数。")

    editor.updateHost("server.example")
    editor.portText = "3389"
    let saved = await editor.save { _ in
        throw ResourceLibraryOperationError.libraryChanged
    }
    XCTAssertFalse(saved)
    XCTAssertEqual(editor.name, "Server")
    XCTAssertEqual(editor.saveError, ResourceLibraryOperationError.libraryChanged.safeMessage)
}
```

- [ ] **Step 2: Verify the tests fail because the editor types are absent**

Run:

```bash
./scripts/test.sh --filter SettingsPresentationTests/testNewServerEditor
```

Expected: FAIL to compile because `NewServerEditorModel` is undefined.

- [ ] **Step 3: Implement the request and editor model**

Create `NewServerModels.swift`:

```swift
import Combine
import Foundation
import RdcCore

struct NewServerRequest: Identifiable, Equatable {
    let targetGroupID: String?
    let targetGroupName: String
    let expectedSnapshot: RdcLibrarySnapshot?
    let ownerLease: ResourcePropertySheetCoordinator.HostLease
    let id = UUID()
}

@MainActor
final class NewServerEditorModel: ObservableObject {
    @Published private(set) var name = ""
    @Published private(set) var host = ""
    @Published var portText = "3389"
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?
    private var didEditName = false

    func updateName(_ value: String) {
        didEditName = true
        name = value
    }

    func updateHost(_ value: String) {
        host = value
        if !didEditName {
            name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var nameError: String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "名称不能为空。" : nil
    }

    var hostError: String? {
        return (try? ServerPropertiesDraft(
            displayName: name.isEmpty ? "Server" : name,
            host: host,
            port: 3_389
        ).validated()) == nil ? "请输入有效的 IP 地址或主机名。" : nil
    }

    var portError: String? {
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port) else {
            return "端口必须是 1–65535 之间的整数。"
        }
        return nil
    }

    var draft: ServerPropertiesDraft? {
        guard nameError == nil, hostError == nil, portError == nil,
              let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return try? ServerPropertiesDraft(
            displayName: name,
            host: host,
            port: port
        ).validated()
    }

    var canSave: Bool { !isSaving && draft != nil }

    func save(using operation: (ServerPropertiesDraft) async throws -> Void) async -> Bool {
        guard canSave, let draft else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await operation(draft)
            return true
        } catch let error as ResourceLibraryOperationError {
            saveError = error.safeMessage
            return false
        } catch {
            saveError = "无法添加服务器，请重试。"
            return false
        }
    }
}
```

- [ ] **Step 4: Run editor-model tests**

Run:

```bash
./scripts/test.sh --filter SettingsPresentationTests/testNewServerEditor
```

Expected: both editor tests pass.

- [ ] **Step 5: Commit the editor state**

```bash
git add Sources/RdcApp/ResourceLibrary/NewServerModels.swift Tests/RdcAppTests/SettingsPresentationTests.swift
git commit -m "feat: add manual server editor state"
```

---

### Task 4: Multi-window presentation coordination

**Files:**
- Modify: `Sources/RdcApp/ResourceLibrary/ResourcePropertyModels.swift`
- Modify: `Sources/RdcApp/Model/RdcAppModel.swift`
- Test: `Tests/RdcAppTests/SettingsPresentationTests.swift`
- Test: `Tests/RdcAppTests/RdcAppWorkflowTests.swift`

**Interfaces:**
- Consumes: Task 3 `NewServerRequest`.
- Produces: `NewServerPresentation`, coordinator claim/query/dismiss methods, `RdcAppModel.requestNewServer(...)`, and request cleanup by lease.

- [ ] **Step 1: Write failing ownership and request tests**

Add to `SettingsPresentationTests`:

```swift
func testNewServerPresentationIsSingleOwnerAndMutuallyExclusive() throws {
    let coordinator = ResourcePropertySheetCoordinator()
    let leaseA = coordinator.register(host: .primaryWindow(id: UUID()))
    let leaseB = coordinator.register(host: .primaryWindow(id: UUID()))
    let request = NewServerRequest(
        targetGroupID: nil,
        targetGroupName: "我的服务器",
        expectedSnapshot: nil,
        ownerLease: leaseA
    )
    XCTAssertEqual(coordinator.claimNewServer(request, lease: leaseB), .ownedByAnotherWindow)
    XCTAssertEqual(coordinator.claimNewServer(request, lease: leaseA), .claimed)
    let presentation = try XCTUnwrap(
        coordinator.newServerPresentation(requested: request, lease: leaseA)
    )
    XCTAssertEqual(coordinator.claimNewChildGroup(
        NewChildGroupRequest(parentID: "root", parentName: "Root", ownerLease: leaseA),
        lease: leaseA
    ), .blockedByCredentialEditor)
    XCTAssertTrue(coordinator.dismissNewServer(presentation))
    XCTAssertFalse(coordinator.dismissNewServer(presentation))
}

```

Add the model request test to `RdcAppWorkflowTests`, where the in-memory configuration store is available:

```swift
func testModelNewServerRequestCapturesExactSnapshotAndLease() async throws {
    let snapshot = RdcLibrarySnapshot(
        sourceID: "new-server-request", sourceName: "example.rdg", document: testDocument()
    )
    let model = makeModel(
        configuration: RdcAppConfiguration(lastLibrary: snapshot),
        engine: AppRecordingSessionEngine()
    )
    await model.loadPersistedState()
    let lease = model.resourcePropertyCoordinator.register(host: .primaryWindow(id: UUID()))
    let rootID = try XCTUnwrap(snapshot.root.id)
    XCTAssertTrue(model.requestNewServer(
        targetGroupID: rootID,
        targetGroupName: snapshot.root.name,
        ownerLease: lease
    ))
    XCTAssertEqual(model.newServerRequest?.expectedSnapshot, snapshot)
    XCTAssertEqual(model.newServerRequest?.targetGroupID, rootID)
    model.releaseResourcePresentationRequests(ownedBy: lease)
    XCTAssertNil(model.newServerRequest)
    await model.shutdownAndWait()
}
```

- [ ] **Step 2: Run the focused presentation tests**

Run:

```bash
./scripts/test.sh --filter SettingsPresentationTests/testNewServerPresentation
./scripts/test.sh --filter RdcAppWorkflowTests/testModelNewServerRequest
```

Expected: FAIL because the coordinator and model request APIs do not exist.

- [ ] **Step 3: Add coordinator state and exact mutual-exclusion guards**

In `ResourcePropertySheetCoordinator`, add:

```swift
struct NewServerPresentation: Identifiable, Equatable {
    let request: NewServerRequest
    let lease: HostLease
    let id = UUID()
}

private var activeNewServerPresentation: NewServerPresentation?

func claimNewServer(
    _ request: NewServerRequest,
    lease: HostLease,
    activeCredential: CredentialEditorPresentation? = nil,
    isOneTimeCredentialPromptRequested: Bool = false
) -> PresentationClaim {
    guard isActive(lease) else { return .hostInactive }
    if let activeSharedModalPresentation {
        return activeSharedModalPresentation.lease == lease
            ? .waitingForCurrentDismissal : .ownedByAnotherWindow
    }
    guard request.ownerLease == lease else { return .ownedByAnotherWindow }
    if let activeNewServerPresentation {
        if activeNewServerPresentation.lease != lease { return .ownedByAnotherWindow }
        return activeNewServerPresentation.request == request
            ? .alreadyOwned : .waitingForCurrentDismissal
    }
    guard activeCredential == nil,
          !isOneTimeCredentialPromptRequested,
          activeResourcePresentation == nil,
          activeOneTimeCredentialPresentation == nil,
          activeDeletionPresentation == nil,
          activeNewChildGroupPresentation == nil else {
        return .blockedByCredentialEditor
    }
    activeNewServerPresentation = NewServerPresentation(request: request, lease: lease)
    revision &+= 1
    return .claimed
}

func newServerPresentation(
    requested: NewServerRequest?,
    lease: HostLease
) -> NewServerPresentation? {
    guard isActive(lease), let requested, let activeNewServerPresentation,
          activeNewServerPresentation.lease == lease,
          activeNewServerPresentation.request == requested else { return nil }
    return activeNewServerPresentation
}

@discardableResult
func dismissNewServer(_ presentation: NewServerPresentation) -> Bool {
    guard activeNewServerPresentation == presentation else { return false }
    activeNewServerPresentation = nil
    revision &+= 1
    return true
}
```

Apply these exact guard additions so the new sheet is mutually exclusive with every existing presentation:

```swift
var hasActivePresentation: Bool {
    hasActiveResourcePresentation || activeOneTimeCredentialPresentation != nil
        || activeDeletionPresentation != nil
        || activeNewChildGroupPresentation != nil
        || activeNewServerPresentation != nil
        || activeSharedModalPresentation != nil
}

// Add this condition to the creation guards in claimPresentation,
// claimOneTimeCredentialPrompt, claimDeletion, claimNewChildGroup, and claimSharedModal:
activeNewServerPresentation == nil

// Add this branch beside the existing new-child-group release branch:
if activeNewServerPresentation?.lease == lease {
    activeNewServerPresentation = nil
}
```

In `claimPresentation`, also return `.waitingForCurrentDismissal` when the active new-server presentation belongs to the same lease and `.ownedByAnotherWindow` when it belongs to another lease, matching the existing deletion and shared-modal branches:

```swift
if let activeNewServerPresentation {
    return activeNewServerPresentation.lease == lease
        ? .waitingForCurrentDismissal : .ownedByAnotherWindow
}
```

- [ ] **Step 4: Add request state and stale-safe capture to `RdcAppModel`**

Add the published property and methods:

```swift
@Published var newServerRequest: NewServerRequest?

@discardableResult
func requestNewServer(
    targetGroupID: String?,
    targetGroupName: String,
    ownerLease: ResourcePropertySheetCoordinator.HostLease
) -> Bool {
    guard resourcePropertyCoordinator.isActiveLease(ownerLease) else { return false }
    if let targetGroupID,
       library?.groups.contains(where: { $0.id == targetGroupID }) != true {
        return false
    }
    newServerRequest = NewServerRequest(
        targetGroupID: targetGroupID,
        targetGroupName: targetGroupName,
        expectedSnapshot: configuration.lastLibrary,
        ownerLease: ownerLease
    )
    return true
}
```

In `releaseResourcePresentationRequests(ownedBy:)`, clear `newServerRequest` only when its `ownerLease` matches the released lease.

- [ ] **Step 5: Run presentation tests**

Run:

```bash
./scripts/test.sh --filter SettingsPresentationTests
```

Expected: all `SettingsPresentationTests` pass, including existing credential, deletion, property, and child-group exclusivity cases.

- [ ] **Step 6: Commit presentation coordination**

```bash
git add Sources/RdcApp/ResourceLibrary/ResourcePropertyModels.swift Sources/RdcApp/Model/RdcAppModel.swift Tests/RdcAppTests/SettingsPresentationTests.swift Tests/RdcAppTests/RdcAppWorkflowTests.swift
git commit -m "feat: coordinate manual server sheets"
```

---

### Task 5: SwiftUI form, top add menu, group menu, and empty state

**Files:**
- Create: `Sources/RdcApp/ResourceLibrary/NewServerSheet.swift`
- Modify: `Sources/RdcApp/ResourceLibrary/ResourceLibraryMenus.swift`
- Modify: `Sources/RdcApp/RdcApplication.swift`
- Test: `Tests/RdcAppTests/SettingsPresentationTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4 creation, request, editor, and coordinator APIs.
- Produces: visible `添加服务器…` entry points and `NewServerSheet`.

- [ ] **Step 1: Write failing menu-order policy tests**

Extend `testResourceMenuPoliciesHaveExactOrderAndRootSemantics` and add a top-menu test:

```swift
XCTAssertEqual(ResourceMenuPolicy.items(for: .group, isConnected: false), [
    .expandOrCollapse, .properties, .groupCredential, .newServer, .newChildGroup,
    .moveGroup, .separator, .deleteGroup
])
XCTAssertEqual(ResourceMenuPolicy.items(for: .rootGroup, isConnected: false), [
    .expandOrCollapse, .properties, .groupCredential, .newServer, .newChildGroup,
    .separator, .removeLibrary
])
XCTAssertEqual(SidebarAddMenuPolicy.items, [.newServer, .importLibrary])
```

- [ ] **Step 2: Run the policy test and verify missing enum cases**

Run:

```bash
./scripts/test.sh --filter SettingsPresentationTests/testResourceMenuPolicies
```

Expected: FAIL because `.newServer` and `SidebarAddMenuPolicy` do not exist.

- [ ] **Step 3: Add exact menu policies and group action**

In `ResourceLibraryMenus.swift`, add:

```swift
enum SidebarAddMenuItem: Hashable {
    case newServer
    case importLibrary
}

enum SidebarAddMenuPolicy {
    static let items: [SidebarAddMenuItem] = [.newServer, .importLibrary]
}
```

Add `.newServer` to `ResourceMenuItem`, insert it before `.newChildGroup` for `.group` and `.rootGroup`, and render this action in `groupMenu(group:)`:

```swift
Button("添加服务器…") {
    _ = model.requestNewServer(
        targetGroupID: group.id,
        targetGroupName: group.name,
        ownerLease: ownerLease
    )
}
```

- [ ] **Step 4: Create the new-server sheet**

Create `NewServerSheet.swift` with a 420-point form using native controls:

```swift
import RdcCore
import SwiftUI

struct NewServerSheet: View {
    let request: NewServerRequest
    @ObservedObject var model: RdcAppModel
    @StateObject private var editor = NewServerEditorModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加服务器").font(.system(size: 20, weight: .semibold))
            Text("将添加到“\(request.targetGroupName)”，账号密码继承全局设置。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Form {
                TextField("名称", text: Binding(
                    get: { editor.name }, set: { editor.updateName($0) }
                ))
                TextField("IP 地址或域名", text: Binding(
                    get: { editor.host }, set: { editor.updateHost($0) }
                ))
                TextField("端口", text: $editor.portText)
            }
            .formStyle(.grouped)
            .frame(height: 170)
            if let error = editor.nameError ?? editor.hostError ?? editor.portError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let saveError = editor.saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("添加") {
                    Task {
                        let saved = await editor.save { draft in
                            _ = try await model.createServer(
                                targetGroupID: request.targetGroupID,
                                expectedSnapshot: request.expectedSnapshot,
                                draft: draft
                            )
                        }
                        if saved { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!editor.canSave)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
```

- [ ] **Step 5: Wire the sheet, coordinator claim, and top menu in `RdcApplication`**

Add the sheet modifier beside the existing child-group sheet:

```swift
.sheet(item: newServerBinding(lease: credentialEditorLease)) { presentation in
    NewServerSheet(request: presentation.request, model: model)
        .onDisappear { newServerSheetDidDisappear(presentation) }
}
```

Add these stale-safe binding and dismissal helpers:

```swift
private func newServerBinding(
    lease: ResourcePropertySheetCoordinator.HostLease?
) -> Binding<ResourcePropertySheetCoordinator.NewServerPresentation?> {
    let captured = lease.flatMap {
        resourcePropertyCoordinator.newServerPresentation(
            requested: model.newServerRequest, lease: $0
        )
    }
    return Binding(
        get: {
            guard let lease else { return nil }
            return resourcePropertyCoordinator.newServerPresentation(
                requested: model.newServerRequest, lease: lease
            )
        },
        set: { value in
            guard value == nil, let captured else { return }
            newServerSheetDidDisappear(captured)
        }
    )
}

private func newServerSheetDidDisappear(
    _ presentation: ResourcePropertySheetCoordinator.NewServerPresentation
) {
    guard resourcePropertyCoordinator.dismissNewServer(presentation) else { return }
    if model.newServerRequest == presentation.request {
        model.newServerRequest = nil
    }
    synchronizeResourcePropertyPresentation(lease: presentation.lease)
}
```

In `synchronizeResourcePropertyPresentation`, claim `model.newServerRequest` before `newChildGroupRequest`:

```swift
if let request = model.newServerRequest {
    let result = resourcePropertyCoordinator.claimNewServer(
        request,
        lease: lease,
        activeCredential: model.credentialEditorPresentation,
        isOneTimeCredentialPromptRequested: model.isShowingCredentialSheet
    )
    if result == .claimed || result == .alreadyOwned { return }
}
```

Replace the header `Button` with this native `Menu`, driven by `SidebarAddMenuPolicy.items` so the tested order is the rendered order:

```swift
Menu {
    ForEach(SidebarAddMenuPolicy.items, id: \.self) { item in
        switch item {
        case .newServer:
            Button("添加服务器…", systemImage: "desktopcomputer") {
                guard let ownerLease else { return }
                _ = model.requestNewServer(
                    targetGroupID: model.configuration.lastLibrary?.root.id,
                    targetGroupName: model.configuration.lastLibrary?.root.name
                        ?? "我的服务器",
                    ownerLease: ownerLease
                )
            }
        case .importLibrary:
            Button("导入 .rdg…", systemImage: "tray.and.arrow.down") {
                model.isShowingImporter = true
            }
        }
    }
} label: {
    Image(systemName: "plus")
        .font(.system(size: 15, weight: .medium))
        .frame(width: 30, height: 30)
}
.menuStyle(.borderlessButton)
.menuIndicator(.hidden)
.help("添加服务器或导入 .rdg")
```

Replace `SidebarEmptyView` with an empty state that exposes both actions:

```swift
private struct SidebarEmptyView: View {
    let addServerAction: () -> Void
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 28)).foregroundStyle(.secondary)
            Text("添加第一台服务器")
                .font(.system(size: 14, weight: .semibold))
            Text("手动输入服务器地址，或导入兼容 RDCMan 的 .rdg 文件")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("添加服务器", action: addServerAction)
                    .buttonStyle(.borderedProminent)
                Button("导入 .rdg", action: importAction)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
    }
}
```

Instantiate it with the same root/bootstrap action used by the top menu:

```swift
SidebarEmptyView(
    addServerAction: {
        guard let ownerLease else { return }
        _ = model.requestNewServer(
            targetGroupID: model.configuration.lastLibrary?.root.id,
            targetGroupName: model.configuration.lastLibrary?.root.name ?? "我的服务器",
            ownerLease: ownerLease
        )
    },
    importAction: { model.isShowingImporter = true }
)
```

Update the main workspace empty copy to the exact string `添加服务器或导入兼容 RDCMan 的 .rdg 文件。`.

- [ ] **Step 6: Run presentation and workflow tests**

Run:

```bash
./scripts/test.sh --filter SettingsPresentationTests
./scripts/test.sh --filter RdcAppWorkflowTests/testCreateServer
```

Expected: all focused tests pass and the app target compiles with the new SwiftUI sheet.

- [ ] **Step 7: Commit visible entry points**

```bash
git add Sources/RdcApp/ResourceLibrary/NewServerSheet.swift Sources/RdcApp/ResourceLibrary/ResourceLibraryMenus.swift Sources/RdcApp/RdcApplication.swift Tests/RdcAppTests/SettingsPresentationTests.swift
git commit -m "feat: add manual server entry points"
```

---

### Task 6: Protect manual resources during different-source import

**Files:**
- Modify: `Sources/RdcApp/Model/RdcAppModel.swift`
- Modify: `Sources/RdcApp/ResourceLibrary/ResourcePropertyModels.swift`
- Modify: `Sources/RdcApp/RdcApplication.swift`
- Test: `Tests/RdcAppTests/RdcAppWorkflowTests.swift`
- Test: `Tests/RdcAppTests/SettingsPresentationTests.swift`

**Interfaces:**
- Consumes: Task 1 `manualResourceImpact(in:)` and the existing `performLibraryImport` transaction.
- Produces: `PendingLibraryReplacement`, `pendingLibraryReplacement`, `confirmLibraryReplacement(_:)`, `cancelLibraryReplacement()`, and shared modal kind `.libraryReplacement`.

- [ ] **Step 1: Change the different-source workflow test to require confirmation**

Replace `testImportFromDifferentSourceReplacesInsteadOfMergingLocalResources` with:

```swift
func testDifferentSourceImportRequiresConfirmationWhenManualResourcesExist() async throws {
    let original = RdcLibrarySnapshot(
        sourceID: "source-a",
        sourceName: "first.rdg",
        sourceLocatorFingerprint: StableLibraryID.sourceLocatorFingerprint(
            for: "file:///Library-A/first.rdg"
        ),
        document: reimportWorkflowDocument(includeNewServer: false)
    )
    let model = makeModel(
        configuration: RdcAppConfiguration(lastLibrary: original),
        engine: AppRecordingSessionEngine()
    )
    await model.loadPersistedState()
    let rootID = try XCTUnwrap(original.root.id)
    _ = try await model.createServer(
        targetGroupID: rootID,
        expectedSnapshot: original,
        draft: .init(displayName: "Manual", host: "192.0.2.20", port: 3_389)
    )
    let beforeImport = model.configuration.lastLibrary

    await model.importLibrary(
        document: testDocument(),
        sourceName: "second.rdg",
        sourceIdentity: "file:///Library-B/second.rdg"
    )

    XCTAssertEqual(model.configuration.lastLibrary, beforeImport)
    let replacement = try XCTUnwrap(model.pendingLibraryReplacement)
    XCTAssertEqual(replacement.impact.serverCount, 1)
    await model.confirmLibraryReplacement(replacement)
    XCTAssertNil(model.pendingLibraryReplacement)
    XCTAssertEqual(model.library?.sourceName, "second.rdg")
    XCTAssertEqual(model.library?.servers.map(\.displayName), ["Server"])
    await model.shutdownAndWait()
}

func testCancellingDifferentSourceImportKeepsManualLibrary() async throws {
    let model = makeModel(configuration: .default, engine: AppRecordingSessionEngine())
    await model.loadPersistedState()
    _ = try await model.createServer(
        targetGroupID: nil,
        expectedSnapshot: nil,
        draft: .init(displayName: "Manual", host: "192.0.2.30", port: 3_389)
    )
    await model.importLibrary(
        document: testDocument(), sourceName: "imported.rdg",
        sourceIdentity: "file:///Imported/imported.rdg"
    )
    XCTAssertNotNil(model.pendingLibraryReplacement)
    model.cancelLibraryReplacement()
    XCTAssertNil(model.pendingLibraryReplacement)
    XCTAssertEqual(model.library?.servers.map(\.displayName), ["Manual"])
    await model.shutdownAndWait()
}
```

Update `testLegacySameNameWithoutIdentityDoesNotMergeDifferentContentWithSameRoot` so the existing local `Local Only` group also exercises the new confirmation path:

```swift
await model.importLibrary(document: testDocument(), sourceName: "example.rdg")
let replacement = try XCTUnwrap(model.pendingLibraryReplacement)
XCTAssertEqual(replacement.impact.groupCount, 1)
await model.confirmLibraryReplacement(replacement)
XCTAssertNotEqual(model.library?.sourceID, original.sourceID)
XCTAssertFalse(model.library?.groups.contains { $0.name == "Local Only" } ?? true)
XCTAssertEqual(model.library?.servers.map(\.displayName), ["Server"])
```

- [ ] **Step 2: Run the focused import tests**

Run:

```bash
./scripts/test.sh --filter RdcAppWorkflowTests/testDifferentSourceImport
./scripts/test.sh --filter RdcAppWorkflowTests/testCancellingDifferentSourceImport
```

Expected: FAIL because pending replacement state and confirm/cancel methods do not exist.

- [ ] **Step 3: Add a captured import request and exact source classification**

In `RdcAppModel.swift`, add:

```swift
struct PendingLibraryReplacement: Identifiable {
    let id = UUID()
    let document: RdcManDocument
    let sourceName: String
    let sourceIdentity: String?
    let sourceLocatorAliases: Set<String>
    let expectedSnapshot: RdcLibrarySnapshot
    let impact: ManualResourceImpact

    var message: String {
        "当前资源库包含 \(impact.groupCount) 个手动分组和 \(impact.serverCount) 台手动服务器。继续将替换这些本地内容。"
    }
}

@Published private(set) var pendingLibraryReplacement: PendingLibraryReplacement?
```

Extract the existing same-source calculation from `performLibraryImport` into this pure helper, then call the same helper from both preflight and the commit transaction:

```swift
nonisolated private static func isSameImportSource(
    existing: RdcLibrarySnapshot,
    compatibilityImport: RdcLibrarySnapshot,
    sourceName: String,
    providedLocatorAliases: Set<String>,
    locatorAliases: Set<String>
) throws -> Bool {
    let existingAliases = existing.sourceLocatorAliases.union(
        existing.sourceLocatorFingerprint.map { [$0] } ?? []
    )
    if existing.sourceLocatorAliases.isEmpty,
       existing.sourceLocatorFingerprint != nil,
       existing.sourceName == sourceName,
       providedLocatorAliases.contains(where: { $0.hasPrefix("path-hash:") }),
       !locatorAliases.isEmpty,
       existingAliases.isDisjoint(with: locatorAliases) {
        throw ResourceLibraryOperationError.sourceIdentityMigrationRequired
    }
    if !existingAliases.isEmpty {
        return !locatorAliases.isEmpty
            && !existingAliases.isDisjoint(with: locatorAliases)
    }
    if locatorAliases.isEmpty {
        return hasExactSourceFingerprintCompatibility(
            existing: existing,
            imported: compatibilityImport
        )
    }
    return false
}
```

Use this preflight at the start of `importLibrary`; it returns without disconnecting or changing configuration when a warning is required:

```swift
do {
    let current = try await configurationRepository.snapshot()
    if let persisted = current.lastLibrary {
        let existing = persisted.normalizedStableIdentity()
        let locatorFingerprint = sourceIdentity.map(
            StableLibraryID.sourceLocatorFingerprint(for:)
        )
        var locatorAliases = sourceLocatorAliases
        if let locatorFingerprint { locatorAliases.insert(locatorFingerprint) }
        let compatibilityImport = RdcLibrarySnapshot(
            sourceID: existing.sourceID,
            sourceName: sourceName,
            sourceLocatorFingerprint: locatorFingerprint,
            sourceLocatorAliases: locatorAliases,
            document: document
        )
        let sameSource = try Self.isSameImportSource(
            existing: existing,
            compatibilityImport: compatibilityImport,
            sourceName: sourceName,
            providedLocatorAliases: sourceLocatorAliases,
            locatorAliases: locatorAliases
        )
        let impact = ResourceLibraryEditor.manualResourceImpact(in: existing)
        if !sameSource, !impact.isEmpty {
            pendingLibraryReplacement = PendingLibraryReplacement(
                document: document,
                sourceName: sourceName,
                sourceIdentity: sourceIdentity,
                sourceLocatorAliases: sourceLocatorAliases,
                expectedSnapshot: persisted,
                impact: impact
            )
            return
        }
    }
    pendingLibraryReplacement = nil
    _ = await performLibraryImport(
        document: document,
        sourceName: sourceName,
        sourceIdentity: sourceIdentity,
        sourceLocatorAliases: sourceLocatorAliases,
        restoreDeletedItems: restoreDeletedItems,
        expectedRestoreSnapshot: nil
    )
} catch let error as ResourceLibraryOperationError {
    importError = error.safeMessage
} catch {
    importError = "无法读取当前资源库状态，请重试。"
}
```

Inside the configuration update in `performLibraryImport`, replace the duplicated source comparison with the same helper so preflight and commit cannot disagree:

```swift
let isSameSource: Bool
if let existing {
    isSameSource = try Self.isSameImportSource(
        existing: existing,
        compatibilityImport: compatibilityImport,
        sourceName: sourceName,
        providedLocatorAliases: sourceLocatorAliases,
        locatorAliases: locatorAliases
    )
} else {
    isSameSource = false
}
```

Implement confirmation with stale protection:

```swift
func confirmLibraryReplacement(_ pending: PendingLibraryReplacement) async {
    if let current = pendingLibraryReplacement, current.id != pending.id { return }
    pendingLibraryReplacement = nil
    _ = await performLibraryImport(
        document: pending.document,
        sourceName: pending.sourceName,
        sourceIdentity: pending.sourceIdentity,
        sourceLocatorAliases: pending.sourceLocatorAliases,
        restoreDeletedItems: false,
        expectedRestoreSnapshot: pending.expectedSnapshot
    )
}

func cancelLibraryReplacement() {
    pendingLibraryReplacement = nil
}
```

Use the existing expected-snapshot equality guard so a resource edit made after the warning produces `confirmationStale` instead of being overwritten.

- [ ] **Step 4: Add the shared replacement confirmation UI**

Add `.libraryReplacement` to `SharedModalKind`. Include it in `requestedSharedModalKind` before importer errors, and add a shared confirmation dialog to `RdcApplication`:

```swift
.confirmationDialog(
    "替换当前资源库？",
    isPresented: sharedBoolBinding(
        kind: .libraryReplacement,
        requested: model.pendingLibraryReplacement != nil,
        dismiss: { model.cancelLibraryReplacement() }
    ),
    titleVisibility: .visible
) {
    Button("替换资源库", role: .destructive) {
        guard let pending = model.pendingLibraryReplacement else { return }
        Task { await model.confirmLibraryReplacement(pending) }
    }
    Button("取消", role: .cancel) { model.cancelLibraryReplacement() }
} message: {
    Text(model.pendingLibraryReplacement?.message ?? "")
}
```

Add this presentation test to `SettingsPresentationTests`:

```swift
func testLibraryReplacementModalBlocksNewServerUntilDismissal() throws {
    let coordinator = ResourcePropertySheetCoordinator()
    let lease = coordinator.register(host: .primaryWindow(id: UUID()))
    let request = NewServerRequest(
        targetGroupID: nil,
        targetGroupName: "我的服务器",
        expectedSnapshot: nil,
        ownerLease: lease
    )
    XCTAssertEqual(coordinator.claimSharedModal(
        kind: .libraryReplacement,
        lease: lease,
        activeCredential: nil
    ), .claimed)
    XCTAssertEqual(
        coordinator.claimNewServer(request, lease: lease),
        .waitingForCurrentDismissal
    )
    let shared = try XCTUnwrap(coordinator.sharedModalPresentation(
        kind: .libraryReplacement, lease: lease
    ))
    XCTAssertTrue(coordinator.dismissSharedModal(shared))
    XCTAssertEqual(coordinator.claimNewServer(request, lease: lease), .claimed)
}
```

- [ ] **Step 5: Run import, presentation, and same-source merge tests**

Run:

```bash
./scripts/test.sh --filter RdcAppWorkflowTests/testDifferentSourceImport
./scripts/test.sh --filter RdcAppWorkflowTests/testCancellingDifferentSourceImport
./scripts/test.sh --filter RdcAppWorkflowTests/testReimportPreservesLocalRenameCredentialBindingAndDeletedTombstone
./scripts/test.sh --filter SettingsPresentationTests
```

Expected: all commands pass; same-source reimport still preserves Mac-only nodes without showing the replacement prompt.

- [ ] **Step 6: Commit import protection**

```bash
git add Sources/RdcApp/Model/RdcAppModel.swift Sources/RdcApp/ResourceLibrary/ResourcePropertyModels.swift Sources/RdcApp/RdcApplication.swift Tests/RdcAppTests/RdcAppWorkflowTests.swift Tests/RdcAppTests/SettingsPresentationTests.swift
git commit -m "feat: confirm replacement of manual resources"
```

---

### Task 7: Documentation, full verification, package, install, and launch

**Files:**
- Modify: `README.md`
- Modify: `README.en.md`
- Verify: all source and test files changed in Tasks 1–6
- Build artifact: `dist/RDGDesk.app`
- Build artifact: `dist/RDGDesk.dmg`

**Interfaces:**
- Consumes: the complete manual-server workflow.
- Produces: documented, tested, packaged, locally installed RDGDesk build.

- [ ] **Step 1: Update Chinese and English user documentation**

Add this bullet under `README.md` “现有功能”:

```markdown
- 无需 `.rdg` 即可手动添加 IPv4、IPv6 或域名服务器；首次添加会创建本地“我的服务器”资源库，也可从分组菜单直接添加，并继承全局凭据。
```

Change the run instruction to:

```markdown
从侧边栏顶部 `+` 选择 `添加服务器…`，或导入 `.rdg` 文件；选择服务器后点击 `连接`。
```

Add the equivalent English capability and run instruction to `README.en.md`:

```markdown
- Add IPv4, IPv6, or DNS servers without an `.rdg` file. The first server creates a local “My Servers” library, group menus can add directly to a destination, and new servers inherit global credentials.
```

- [ ] **Step 2: Run formatting and complete automated verification**

Run:

```bash
git diff --check
bash -n scripts/*.sh
./scripts/test.sh
./scripts/build.sh
```

Expected: no whitespace or shell syntax errors; the full Swift test suite reports zero failures; debug build succeeds.

- [ ] **Step 3: Inspect the diff for secrets and source-file leakage**

Run:

```bash
git diff --check
git diff --stat
rg -n "/Users/henry|Downloads|administrator|password|temp2\.rdg" Sources Tests README.md README.en.md docs/superpowers/plans/2026-07-18-manual-server-addition.md
```

Expected: only deliberate generic security-copy references appear; no real password, username, private `.rdg` path, home-directory path, or unrelated server inventory is present. All committed IPv4 test data uses RFC 5737 documentation ranges.

- [ ] **Step 4: Commit documentation and final test adjustments**

```bash
git add README.md README.en.md
git commit -m "docs: explain manual server addition"
```

- [ ] **Step 5: Build the self-contained release app and DMG**

Run:

```bash
RDC_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/package-app.sh --dmg
codesign --verify --deep --strict dist/RDGDesk.app
hdiutil verify dist/RDGDesk.dmg
```

Expected: `dist/RDGDesk.app` and `dist/RDGDesk.dmg` exist; temporary signature and DMG verification succeed.

- [ ] **Step 6: Cover-install and launch the verified app**

After obtaining GUI/filesystem approval, run:

```bash
pkill -x Rdc || true
rm -rf /Applications/RDGDesk.app
ditto dist/RDGDesk.app /Applications/RDGDesk.app
open /Applications/RDGDesk.app
```

Expected: the installed app opens, the top `+` menu contains `添加服务器…` and `导入 .rdg…`, and no stale old process remains.

- [ ] **Step 7: Perform manual acceptance without real credentials in logs**

In the app UI:

1. Remove or use a disposable configuration, add a documentation-only test endpoint, quit, reopen, and verify “我的服务器” persists.
2. Add another entry to an imported resource-library root and one to a child group.
3. Verify property editing, moving, deleting, search, and automatic selection.
4. Set credentials only through the global credential UI and verify the new server resolves that account.
5. Reimport the same `.rdg` and confirm the manual entry remains.
6. Choose a different sanitized `.rdg` and confirm replacement requires an explicit destructive action.

Expected: every behavior matches `docs/superpowers/specs/2026-07-18-manual-server-addition-design.md`; no credentials or private server data are copied to terminal output or committed files.

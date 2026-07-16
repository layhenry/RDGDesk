import AppKit
import Combine
import RdcCore
import SwiftUI

@MainActor
protocol TextPasteboard: AnyObject {
    func readText() -> String?
    func writeText(_ text: String)
}

@MainActor
private final class SystemTextPasteboard: TextPasteboard {
    func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func writeText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum ConnectionErrorPresentation: Equatable, Sendable {
    case dns
    case timeout
    case refused
    case transport
    case tlsOrProtocol
    case certificateRejected
    case certificateChanged
    case authentication(
        reason: RdpAuthenticationFailureReason,
        actions: [ConnectionErrorAction]
    )
    case remoteDisconnect
    case keychain
    case configuration

    var message: String {
        switch self {
        case .dns:
            "无法解析服务器地址。请检查主机名或 DNS 设置。"
        case .timeout:
            "连接超时。请检查网络或服务器状态后重试。"
        case .refused:
            "服务器拒绝了连接。请检查地址、端口和远程桌面服务。"
        case .transport:
            "无法建立或保持到远程桌面的网络连接。服务器端口可能开放，但连接在协商前已中断。"
        case .tlsOrProtocol:
            "TLS 或远程桌面安全协议协商失败。服务器可能使用旧版 TLS/RDP 安全层，或安全策略不兼容。"
        case .certificateRejected:
            "服务器证书未获信任，连接已安全取消。"
        case .certificateChanged:
            "服务器证书已更改。请核对指纹后再决定是否信任。"
        case let .authentication(reason, _):
            switch reason {
            case .wrongPassword: "密码错误，请重新输入。"
            case .invalidCredentials: "用户名或密码错误，请重新输入。"
            case .accountDisabled: "账户已被禁用，请联系管理员。"
            case .accountLocked: "账户已被锁定，请稍后重试或联系管理员。"
            case .passwordExpired: "密码已过期，请先修改密码。"
            case .passwordMustChange: "账户要求先修改密码。"
            case .accountRestriction: "账户受到登录限制，请检查远程登录权限或登录时段。"
            case .accountExpired: "账户已过期，请联系管理员。"
            case .unknown: "身份验证失败，请检查账户、密码和登录权限。"
            }
        case .remoteDisconnect:
            "远程服务器已断开连接。您可以检查网络后重试。"
        case .keychain:
            "无法使用已保存的钥匙串凭据，请重新输入。"
        case .configuration:
            "无法读取或保存配置，请检查磁盘权限后重试。"
        }
    }

    static func classify(
        error: RdpSessionError,
        authenticationActions: [ConnectionErrorAction]
    ) -> ConnectionErrorPresentation {
        switch error {
        case let .authenticationFailed(reason, code):
            let reasonMatchesCode = switch reason {
            case .wrongPassword: code == 0x0002_0015
            case .invalidCredentials: code == 0x0002_0014
            case .accountDisabled: code == 0x0002_0012
            case .accountLocked: code == 0x0002_0018
            case .passwordExpired: code == 0x0002_000E || code == 0x0002_000F
            case .passwordMustChange: code == 0x0002_0013
            case .accountRestriction: code == 0x0002_0017
            case .accountExpired: code == 0x0002_0019
            case .unknown: true
            }
            let presentationReason = reasonMatchesCode ? reason : .unknown
            return .authentication(
                reason: presentationReason,
                actions: authenticationActions
            )
        case .certificateRejected:
            return .certificateRejected
        case .missingEndpoint, .invalidPort, .invalidViewport:
            return .configuration
        case let .network(code, _):
            let freeRDPType = UInt32(bitPattern: code) & 0xffff
            switch code {
            case -1_003:
                return .dns
            case -1_001:
                return .timeout
            case 61, 111:
                return .refused
            default:
                switch freeRDPType {
                case 0x04, 0x05:
                    return .dns
                case 0x1C:
                    return .timeout
                default:
                    return .transport
                }
            }
        case .protocolFailure:
            return .tlsOrProtocol
        case .notConnected, .simulatedFailure:
            return .remoteDisconnect
        }
    }
}

enum ConnectionErrorAction: Equatable, Sendable {
    case retry
    case editCredential(CredentialEditScope)
    case reviewCertificate
    case dismiss
}

enum ResourceEditorRoute: Identifiable, Equatable {
    case server(id: String)
    case group(id: String)

    var id: String {
        switch self {
        case let .server(id): "server:\(id)"
        case let .group(id): "group:\(id)"
        }
    }
}

struct PendingResourceDeletion: Equatable {
    enum Target: Equatable {
        case server(id: String, name: String)
        case group(id: String, name: String)
        case library(name: String)
    }

    let target: Target
    let impact: ResourceDeletionImpact
    let expectedSnapshot: RdcLibrarySnapshot
    let ownerLease: ResourcePropertySheetCoordinator.HostLease

    static func server(
        id: String,
        name: String,
        impact: ResourceDeletionImpact,
        expectedSnapshot: RdcLibrarySnapshot,
        ownerLease: ResourcePropertySheetCoordinator.HostLease
    ) -> Self {
        Self(
            target: .server(id: id, name: name), impact: impact,
            expectedSnapshot: expectedSnapshot, ownerLease: ownerLease
        )
    }

    static func group(
        id: String,
        name: String,
        impact: ResourceDeletionImpact,
        expectedSnapshot: RdcLibrarySnapshot,
        ownerLease: ResourcePropertySheetCoordinator.HostLease
    ) -> Self {
        Self(
            target: .group(id: id, name: name), impact: impact,
            expectedSnapshot: expectedSnapshot, ownerLease: ownerLease
        )
    }

    static func library(
        name: String,
        impact: ResourceDeletionImpact,
        expectedSnapshot: RdcLibrarySnapshot,
        ownerLease: ResourcePropertySheetCoordinator.HostLease
    ) -> Self {
        Self(
            target: .library(name: name), impact: impact,
            expectedSnapshot: expectedSnapshot, ownerLease: ownerLease
        )
    }
}

enum ResourceLibraryOperationError: Error, Equatable {
    case missingLibrary
    case libraryChanged
    case sessionDisconnectFailed
    case passwordStoreFailed
    case passwordRollbackFailed
    case sourceIdentityMigrationRequired
    case configurationSaveFailed
    case confirmationStale

    var safeMessage: String {
        switch self {
        case .missingLibrary: "资源库尚未载入。"
        case .libraryChanged: "资源库已被其他操作更新，请重试。"
        case .sessionDisconnectFailed: "无法安全断开当前连接，请稍后重试。"
        case .passwordStoreFailed: "无法更新钥匙串凭据，资源库未更改。"
        case .passwordRollbackFailed: "资源库未更改，但部分钥匙串凭据可能需要重新输入。请立即检查相关账户。"
        case .sourceIdentityMigrationRequired: "旧资源库尚未完成文件身份升级。请先重新选择原 .rdg 文件完成升级；若原文件已被替换，请先移除当前资源库再导入新文件。"
        case .configurationSaveFailed: "无法保存资源库，请检查磁盘权限后重试。"
        case .confirmationStale: "资源库已变化，请重新确认。"
        }
    }
}

protocol ConnectionRetrySleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

private struct TaskConnectionRetrySleeper: ConnectionRetrySleeper {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

@MainActor
final class RdcAppModel: ObservableObject {
    @Published var library: RdcImportedLibrary?
    @Published private(set) var configuration: RdcAppConfiguration = .default
    @Published var isShowingImporter = false
    @Published var isShowingCredentialSheet = false
    @Published var importError: String?
    @Published var debugLaunchError: String?
    @Published var connectionStartedAt: Date?
    @Published var connectionErrorPresentation: ConnectionErrorPresentation?
    @Published private(set) var connectionDiagnosticCode: String?
    @Published var credentialEditorPresentation: CredentialEditorPresentation?
    @Published var settingsOperationError: String?
    @Published private(set) var clipboardStatusMessage: String?
    @Published var resourceEditorRoute: ResourceEditorRoute?
    @Published private(set) var resourceEditorOwnerLease: ResourcePropertySheetCoordinator.HostLease?
    @Published var pendingResourceDeletion: PendingResourceDeletion?
    @Published var newChildGroupRequest: NewChildGroupRequest?
    @Published var resourceOperationMessage: String?
    @Published private(set) var deletedImportRestoreCount: Int?
    @Published private(set) var activeSessionServerID: String?
    let resourcePropertyCoordinator = ResourcePropertySheetCoordinator()

    var editingCredentialScope: CredentialEditScope? {
        credentialEditorPresentation?.scope
    }

    let session: RdcSessionModel
    private let configurationRepository: RdcConfigurationRepository
    private let passwordStore: any PasswordStore
    private let credentialVault: CredentialVault
    private var sessionObservation: AnyCancellable?
    private var descriptorObservation: AnyCancellable?
    private var sessionErrorObservation: AnyCancellable?
    private var clipboardObservation: AnyCancellable?
    private let textPasteboard: any TextPasteboard
    private let resourceOperationCheckpoint: @Sendable () async -> Void
    private let connectionRetrySleeper: any ConnectionRetrySleeper
    private var operationTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var isShuttingDown = false
    private struct PendingDeletedImportRestore {
        let token = UUID()
        let sourceID: String
        let sourceLocatorFingerprint: String?
        let expectedSnapshot: RdcLibrarySnapshot
        let document: RdcManDocument
        let sourceName: String
        let sourceIdentity: String?
        let sourceLocatorAliases: Set<String>
    }

    private var pendingDeletedImportRestore: PendingDeletedImportRestore?

    convenience init(
        configurationRepository: RdcConfigurationRepository = RdcConfigurationRepository(
            store: FileRdcConfigurationStore()
        ),
        passwordStore: any PasswordStore = MacOSKeychainPasswordStore(),
        engine: FreeRDPSessionEngine = FreeRDPSessionEngine()
    ) {
        self.init(
            configurationRepository: configurationRepository,
            passwordStore: passwordStore,
            engine: engine,
            lifecycleUpdates: engine.lifecycleUpdates,
            frameUpdates: engine.frameUpdates,
            certificateChallenges: engine.certificateChallenges,
            clipboardUpdates: engine.clipboardUpdates
        )
    }

    init(
        configurationRepository: RdcConfigurationRepository,
        passwordStore: any PasswordStore,
        engine: any RdpSessionEngine,
        lifecycleUpdates: AsyncStream<RdpSessionLifecycleUpdate>? = nil,
        frameUpdates: AsyncStream<RdpSessionFrameUpdate>? = nil,
        certificateChallenges: AsyncStream<RdpCertificateChallengeUpdate>? = nil,
        clipboardUpdates: AsyncStream<RdpClipboardUpdate>? = nil,
        textPasteboard: (any TextPasteboard)? = nil,
        certificateClock: (any CertificateChallengeClock)? = nil,
        resourceOperationCheckpoint: @escaping @Sendable () async -> Void = {},
        connectionRetrySleeper: any ConnectionRetrySleeper = TaskConnectionRetrySleeper()
    ) {
        let certificateCoordinator = CertificateTrustCoordinator(
            configurationRepository: configurationRepository
        )
        self.configurationRepository = configurationRepository
        self.passwordStore = passwordStore
        self.textPasteboard = textPasteboard ?? SystemTextPasteboard()
        self.resourceOperationCheckpoint = resourceOperationCheckpoint
        self.connectionRetrySleeper = connectionRetrySleeper
        self.credentialVault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: configurationRepository
        )
        self.session = RdcSessionModel(
            engine: engine,
            lifecycleUpdates: lifecycleUpdates,
            frameUpdates: frameUpdates,
            certificateChallenges: certificateChallenges,
            clipboardUpdates: clipboardUpdates,
            certificateCoordinator: certificateCoordinator,
            certificateClock: certificateClock
        )
        sessionObservation = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        descriptorObservation = session.$descriptor.dropFirst().sink { [weak self] descriptor in
            if descriptor == nil {
                self?.connectionStartedAt = nil
                self?.activeSessionServerID = nil
            }
        }
        sessionErrorObservation = session.$lastError.dropFirst().sink { [weak self] error in
            guard let error, let self else { return }
            self.connectionErrorPresentation = .classify(
                error: error,
                authenticationActions: self.selectedServer.map {
                    self.authenticationErrorActions(for: $0)
                } ?? []
            )
            self.connectionDiagnosticCode = Self.diagnosticCode(for: error)
        }
        clipboardObservation = session.$clipboardText.dropFirst().sink { [weak self] text in
            guard let self, let text else { return }
            self.textPasteboard.writeText(text)
            self.clipboardStatusMessage = "已接收远程文本剪贴板"
        }
    }

    func sendSecureAttention() {
        guard session.descriptor != nil else { return }
        session.sendSecureAttention()
    }

    @discardableResult
    func sendLocalClipboardText() -> Bool {
        guard session.descriptor != nil else {
            clipboardStatusMessage = "请先连接远程桌面"
            return false
        }
        guard let text = textPasteboard.readText(), !text.isEmpty else {
            clipboardStatusMessage = "本机剪贴板中没有文本"
            return false
        }
        guard text.utf8.count <= 1_048_576 else {
            clipboardStatusMessage = "文本超过 1 MB，未发送"
            return false
        }
        session.setClipboardText(text)
        clipboardStatusMessage = "已发送本机文本剪贴板"
        return true
    }

    var selectedServerID: String? {
        library?.selectedServerID
    }

    var selectedServer: RdcImportedServer? {
        library?.selectedServer
    }

    var activeSessionServer: RdcImportedServer? {
        guard session.descriptor != nil, let activeSessionServerID else { return nil }
        return library?.servers.first { $0.id == activeSessionServerID }
    }

    func resourceLibrarySidebarState(
        expandedGroupIDs: Set<String>,
        searchText: String
    ) -> ResourceLibrarySidebarState? {
        guard let library else { return nil }
        return ResourceLibrarySidebarState(
            library: library,
            expandedGroupIDs: expandedGroupIDs,
            searchText: searchText
        )
    }

    var persistedExpandedGroupIDs: Set<String> {
        guard let root = configuration.lastLibrary?.root else { return [] }
        func collect(_ group: RdcGroupSnapshot) -> Set<String> {
            var ids = Set<String>()
            if group.isExpanded != false, let id = group.id { ids.insert(id) }
            for child in group.groups { ids.formUnion(collect(child)) }
            return ids
        }
        return collect(root)
    }

    func setGroupExpanded(id: String, isExpanded: Bool) async {
        do {
            try await persistResourceEdit { snapshot in
                var copy = snapshot
                guard Self.setExpansion(in: &copy.root, id: id, isExpanded: isExpanded) else {
                    throw ResourceLibraryEditError.missingResource
                }
                return copy
            }
        } catch {
            // persistResourceEdit already publishes a safe, visible error.
        }
    }

    nonisolated private static func setExpansion(
        in group: inout RdcGroupSnapshot,
        id: String,
        isExpanded: Bool
    ) -> Bool {
        if group.id == id {
            group.isExpanded = isExpanded
            return true
        }
        for index in group.groups.indices {
            if setExpansion(in: &group.groups[index], id: id, isExpanded: isExpanded) {
                return true
            }
        }
        return false
    }

    var pendingCertificate: CertificateTrustPresentation? {
        session.pendingCertificate
    }

    var globalCredentialState: GlobalCredentialSettingsState {
        GlobalCredentialSettingsState(configuration: configuration, library: library)
    }

    var globalCredentialDeletionImpact: Int {
        globalCredentialDeletionPresentation.impactedServerCount
    }

    var globalCredentialDeletionPresentation: GlobalCredentialDeletionPresentation {
        GlobalCredentialDeletionPresentation(configuration: configuration, library: library)
    }

    var connectionStatusPrefix: String {
        if session.descriptor != nil {
            return "已连接到"
        }
        if session.isConnecting {
            return "正在连接"
        }
        if selectedServer != nil {
            return "已选择"
        }
        return "未连接"
    }

    var importErrorBinding: Binding<Bool> {
        Binding(
            get: { self.importError != nil },
            set: { if !$0 { self.importError = nil } }
        )
    }

    var deletedImportRestoreBinding: Binding<Bool> {
        Binding(
            get: { self.deletedImportRestoreCount != nil },
            set: { if !$0 { self.dismissDeletedItemsRestoreOffer() } }
        )
    }

    var connectionErrorMessage: String? {
        if let connectionErrorPresentation {
            if let connectionDiagnosticCode {
                return "\(connectionErrorPresentation.message)\n诊断代码：\(connectionDiagnosticCode)"
            }
            return connectionErrorPresentation.message
        }
        if session.presentedError != nil {
            return ConnectionErrorPresentation.remoteDisconnect.message
        }
        return debugLaunchError
    }

    var connectionErrorBinding: Binding<Bool> {
        Binding(
            get: { self.connectionErrorMessage != nil },
            set: { if !$0 { self.clearConnectionError() } }
        )
    }

    var settingsOperationErrorBinding: Binding<Bool> {
        Binding(
            get: { self.settingsOperationError != nil },
            set: { if !$0 { self.settingsOperationError = nil } }
        )
    }

    @discardableResult
    func performSettingsOperation(
        host: CredentialEditorHost,
        failureMessage: String,
        _ operation: () async throws -> Void
    ) async -> Bool {
        do {
            try await operation()
            if host == .settingsWindow { settingsOperationError = nil }
            return true
        } catch {
            if host == .settingsWindow {
                settingsOperationError = failureMessage
            } else {
                connectionErrorPresentation = .configuration
                debugLaunchError = failureMessage
            }
            return false
        }
    }

    func clearConnectionError() {
        connectionErrorPresentation = nil
        connectionDiagnosticCode = nil
        debugLaunchError = nil
        session.clearPresentedError()
    }

    func resolvePendingCertificate(decision: RdpCertificateDecision) async {
        await resolvePendingCertificate(decision: decision, expectedToken: nil)
    }

    func resolvePendingCertificate(
        decision: RdpCertificateDecision,
        expectedToken: RdcSessionModel.PendingCertificateToken?
    ) async {
        if let expectedToken, session.pendingCertificateToken != expectedToken { return }
        let pending = session.pendingCertificate
        await session.resolvePendingCertificate(
            decision: decision, expectedToken: expectedToken
        )
        if decision == .trustAlways {
            do {
                configuration = try await configurationRepository.snapshot()
            } catch {
                connectionErrorPresentation = .configuration
            }
        }
        guard decision == .reject else { return }
        switch pending {
        case .changed:
            connectionErrorPresentation = .certificateChanged
        case .firstUse:
            connectionErrorPresentation = .certificateRejected
        case nil:
            break
        }
    }

    func loadPersistedState() async {
        await performOperation { model, generation in
            do {
                var configuration = try await model.configurationRepository.snapshot()
                guard model.isCurrentOperation(generation) else { return }
                guard configuration.preferences.restoresLastLibrary,
                      let snapshot = configuration.lastLibrary else {
                    model.configuration = configuration
                    model.library = nil
                    return
                }
                let normalized = snapshot.normalizedStableIdentity()
                if normalized != snapshot {
                    do {
                        configuration = try await model.configurationRepository.update { candidate in
                            guard candidate.lastLibrary == snapshot else {
                                throw ResourceLibraryOperationError.libraryChanged
                            }
                            candidate.lastLibrary = normalized
                            return candidate
                        }
                        model.importError = nil
                    } catch {
                        // The in-memory normalized tree remains editable, while the
                        // original on-disk configuration is left untouched.
                        configuration.lastLibrary = normalized
                        model.importError = "旧资源库迁移未保存，原设置保持不变。请检查磁盘权限后重试。"
                        model.connectionErrorPresentation = .configuration
                    }
                } else {
                    model.importError = nil
                }
                model.configuration = configuration
                model.library = normalized.makeLibrary()
            } catch {
                guard model.isCurrentOperation(generation) else { return }
                model.connectionErrorPresentation = .configuration
                model.importError = "无法读取已保存的配置。"
            }
        }
    }

    func connectSelectedServer() async {
        guard let selectedServer else {
            debugLaunchError = "请先选择一个服务器。"
            return
        }
        connectionErrorPresentation = nil
        connectionDiagnosticCode = nil
        debugLaunchError = nil
        session.clearPresentedError()
        await performOperation { model, generation in
            let configuration: RdcAppConfiguration
            do {
                configuration = try await model.configurationRepository.snapshot()
            } catch {
                guard model.isCurrentOperation(generation) else { return }
                model.connectionErrorPresentation = .configuration
                model.debugLaunchError = "无法读取连接配置。"
                return
            }
            guard model.isCurrentOperation(generation) else { return }
            guard let resolution = CredentialResolver.resolve(
                server: selectedServer,
                configuration: configuration
            ) else {
                model.isShowingCredentialSheet = true
                return
            }

            let resolved: ResolvedCredential?
            do {
                resolved = try await model.credentialVault.loadCredential(
                    id: resolution.credentialID
                )
            } catch CredentialVaultError.passwordStoreFailed {
                guard model.isCurrentOperation(generation) else { return }
                model.connectionErrorPresentation = .keychain
                model.debugLaunchError = nil
                model.isShowingCredentialSheet = true
                return
            } catch {
                guard model.isCurrentOperation(generation) else { return }
                model.connectionErrorPresentation = .configuration
                model.debugLaunchError = "无法读取连接配置。"
                model.isShowingCredentialSheet = true
                return
            }
            guard model.isCurrentOperation(generation) else { return }
            guard let resolved else {
                model.connectionErrorPresentation = .keychain
                model.debugLaunchError = nil
                model.isShowingCredentialSheet = true
                return
            }

            model.isShowingCredentialSheet = false
            do {
                do {
                    try await model.session.connect(
                        server: selectedServer,
                        credential: resolved.connectionCredential,
                        viewport: RdpViewport(width: 1_440, height: 900)
                    )
                } catch let error as RdpSessionError
                    where Self.isTransientTransportConnectFailure(error) {
                    try await model.connectionRetrySleeper.sleep(for: .milliseconds(800))
                    guard model.isCurrentOperation(generation) else { return }
                    try await model.session.connect(
                        server: selectedServer,
                        credential: resolved.connectionCredential,
                        viewport: RdpViewport(width: 1_440, height: 900)
                    )
                }
                model.activeSessionServerID = selectedServer.id
                guard model.isCurrentOperation(generation) else { return }
                model.connectionStartedAt = Date()
                model.connectionErrorPresentation = nil
                model.debugLaunchError = nil
            } catch is CancellationError {
                guard model.isCurrentOperation(generation) else { return }
                model.connectionStartedAt = nil
            } catch let error as RdpSessionError {
                guard model.isCurrentOperation(generation) else { return }
                model.connectionStartedAt = nil
                model.connectionErrorPresentation = .classify(
                    error: error,
                    authenticationActions: model.authenticationErrorActions(for: selectedServer)
                )
                model.connectionDiagnosticCode = Self.diagnosticCode(for: error)
            } catch {
                guard model.isCurrentOperation(generation) else { return }
                model.connectionStartedAt = nil
                model.connectionErrorPresentation = .remoteDisconnect
            }
        }
    }

    func importLibrary(
        document: RdcManDocument,
        sourceName: String,
        sourceIdentity: String? = nil,
        sourceLocatorAliases: Set<String> = [],
        restoreDeletedItems: Bool = false
    ) async {
        _ = await performLibraryImport(
            document: document,
            sourceName: sourceName,
            sourceIdentity: sourceIdentity,
            sourceLocatorAliases: sourceLocatorAliases,
            restoreDeletedItems: restoreDeletedItems,
            expectedRestoreSnapshot: nil
        )
    }

    @discardableResult
    private func performLibraryImport(
        document: RdcManDocument,
        sourceName: String,
        sourceIdentity: String?,
        sourceLocatorAliases: Set<String>,
        restoreDeletedItems: Bool,
        expectedRestoreSnapshot: RdcLibrarySnapshot?
    ) async -> Bool {
        var succeeded = false
        await performOperation { model, generation in
            await model.session.disconnect()
            guard model.isCurrentOperation(generation) else { return }
            do {
                let selectedServerID = model.selectedServerID
                await model.resourceOperationCheckpoint()
                guard model.isCurrentOperation(generation) else { return }
                let passwordStore = model.passwordStore
                let committed = try await model.configurationRepository.updateWithRollback {
                    configuration -> RdcPreparedConfigurationUpdate<RdcAppConfiguration> in
                    if let expectedRestoreSnapshot,
                       configuration.lastLibrary != expectedRestoreSnapshot {
                        throw ResourceLibraryOperationError.confirmationStale
                    }
                    let existing = configuration.lastLibrary?.normalizedStableIdentity()
                    let locatorFingerprint = sourceIdentity.map(
                        StableLibraryID.sourceLocatorFingerprint(for:)
                    )
                    var locatorAliases = sourceLocatorAliases
                    if let locatorFingerprint { locatorAliases.insert(locatorFingerprint) }
                    let compatibilityImport = RdcLibrarySnapshot(
                        sourceID: existing?.sourceID ?? UUID().uuidString,
                        sourceName: sourceName,
                        sourceLocatorFingerprint: locatorFingerprint,
                        sourceLocatorAliases: locatorAliases,
                        document: document
                    )
                    let isSameSource: Bool
                    let existingAliases = Set(existing?.sourceLocatorAliases ?? [])
                        .union(existing?.sourceLocatorFingerprint.map { [$0] } ?? [])
                    if let existing,
                       existing.sourceLocatorAliases.isEmpty,
                       existing.sourceLocatorFingerprint != nil,
                       existing.sourceName == sourceName,
                       sourceLocatorAliases.contains(where: { $0.hasPrefix("path-hash:") }),
                       !locatorAliases.isEmpty,
                       existingAliases.isDisjoint(with: locatorAliases) {
                        throw ResourceLibraryOperationError.sourceIdentityMigrationRequired
                    }
                    if !existingAliases.isEmpty {
                        // Once a stable file identity is persisted, never weaken it to
                        // a filename- or content-only association. A missing incoming
                        // identity therefore means a different source.
                        isSameSource = !locatorAliases.isEmpty
                            && !existingAliases.isDisjoint(with: locatorAliases)
                    } else if let existing, locatorAliases.isEmpty {
                        // Legacy snapshots can be associated only when their complete
                        // source-fingerprint sets prove identical source content.
                        isSameSource = Self.hasExactSourceFingerprintCompatibility(
                            existing: existing,
                            imported: compatibilityImport
                        )
                    } else {
                        isSameSource = false
                    }
                    let imported = RdcLibrarySnapshot(
                        sourceID: isSameSource
                            ? existing?.sourceID ?? UUID().uuidString
                            : UUID().uuidString,
                        sourceName: sourceName,
                        sourceLocatorFingerprint: locatorFingerprint
                            ?? (isSameSource ? existing?.sourceLocatorFingerprint : nil),
                        sourceLocatorAliases: isSameSource
                            ? existingAliases.union(locatorAliases) : locatorAliases,
                        document: document
                    )
                    let finalSnapshot: RdcLibrarySnapshot
                    if let existing, isSameSource {
                        finalSnapshot = ResourceLibraryEditor.mergeReimport(
                            existing: existing,
                            imported: imported,
                            restoreDeletedItems: restoreDeletedItems
                        )
                    } else {
                        finalSnapshot = imported
                    }
                    let prepared = Self.prepareImportCandidate(
                        previous: configuration,
                        snapshot: finalSnapshot
                    )
                    let rollbackPasswords = try await Self.deletePasswordsBeforeCommit(
                        credentialIDs: prepared.credentialsToDelete,
                        passwordStore: passwordStore
                    )
                    configuration = prepared.configuration
                    return RdcPreparedConfigurationUpdate(
                        result: configuration,
                        rollback: {
                            let restored = await Self.restoreDeletedPasswords(
                                rollbackPasswords,
                                passwordStore: passwordStore
                            )
                            guard restored else {
                                throw RdcConfigurationTransactionError.rollbackFailed
                            }
                        }
                    )
                }
                let reconciledSelection = Self.reconciledImportSelection(
                    snapshot: committed.lastLibrary,
                    latestSelection: model.selectedServerID,
                    importedSelection: selectedServerID
                )
                model.configuration = committed
                model.library = committed.lastLibrary?.makeLibrary(
                    selectedServerID: reconciledSelection
                )
                if !restoreDeletedItems,
                   let count = committed.lastLibrary?.deletedSourceItems.count,
                   count > 0,
                   let committedSnapshot = committed.lastLibrary {
                    model.pendingDeletedImportRestore = PendingDeletedImportRestore(
                        sourceID: committedSnapshot.sourceID,
                        sourceLocatorFingerprint: committedSnapshot.sourceLocatorFingerprint,
                        expectedSnapshot: committedSnapshot,
                        document: document,
                        sourceName: sourceName,
                        sourceIdentity: sourceIdentity,
                        sourceLocatorAliases: committedSnapshot.sourceLocatorAliases
                    )
                    model.deletedImportRestoreCount = count
                } else {
                    model.pendingDeletedImportRestore = nil
                    model.deletedImportRestoreCount = nil
                }
                succeeded = true
                // Durable state must always reconcile the shared model. Generation
                // only suppresses stale transient presentation after the commit.
                guard model.isCurrentOperation(generation) else { return }
                model.connectionStartedAt = nil
                model.importError = nil
                model.connectionErrorPresentation = nil
            } catch {
                guard model.isCurrentOperation(generation) else { return }
                model.connectionErrorPresentation = .configuration
                if error as? ResourceLibraryOperationError == .confirmationStale {
                    model.importError = ResourceLibraryOperationError.confirmationStale.safeMessage
                } else if error as? ResourceLibraryOperationError == .sourceIdentityMigrationRequired {
                    model.importError = ResourceLibraryOperationError.sourceIdentityMigrationRequired.safeMessage
                } else if error as? ResourceLibraryOperationError == .passwordRollbackFailed
                            || error as? RdcConfigurationTransactionError == .rollbackFailed {
                    model.importError = ResourceLibraryOperationError.passwordRollbackFailed.safeMessage
                } else {
                    model.importError = "无法保存导入的服务器列表。"
                }
            }
        }
        return succeeded
    }

    func restoreDeletedItemsFromLastImport() async {
        guard let pendingDeletedImportRestore else { return }
        let restored = await performLibraryImport(
            document: pendingDeletedImportRestore.document,
            sourceName: pendingDeletedImportRestore.sourceName,
            sourceIdentity: pendingDeletedImportRestore.sourceIdentity,
            sourceLocatorAliases: pendingDeletedImportRestore.sourceLocatorAliases,
            restoreDeletedItems: true,
            expectedRestoreSnapshot: pendingDeletedImportRestore.expectedSnapshot
        )
        if !restored {
            dismissDeletedItemsRestoreOffer(matching: pendingDeletedImportRestore.token)
        }
    }

    func dismissDeletedItemsRestoreOffer() {
        pendingDeletedImportRestore = nil
        deletedImportRestoreCount = nil
    }

    private func dismissDeletedItemsRestoreOffer(matching token: UUID) {
        guard pendingDeletedImportRestore?.token == token else { return }
        dismissDeletedItemsRestoreOffer()
    }

    nonisolated static func sourceIdentity(for url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        let values = try? resolved.resourceValues(forKeys: keys)
        return sourceIdentity(
            fileIdentifier: values?.fileResourceIdentifier,
            volumeIdentifier: values?.volumeIdentifier,
            fallbackPath: resolved.path
        )
    }

    nonisolated static func sourceLocatorAliases(for url: URL) -> Set<String> {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let identity = sourceIdentity(for: resolved)
        return [
            StableLibraryID.sourceLocatorFingerprint(for: identity),
            "path-hash:" + StableLibraryID.sourceLocatorFingerprint(for: resolved.path)
        ]
    }

    nonisolated static func sourceIdentity(
        fileIdentifier: Any?,
        volumeIdentifier: Any?,
        fallbackPath: String
    ) -> String {
        if let fileIdentifier = stableResourceIdentifierComponent(fileIdentifier),
           let volumeIdentifier = stableResourceIdentifierComponent(volumeIdentifier) {
            let material = volumeIdentifier + "\u{0}" + fileIdentifier
            return "file-id:" + StableLibraryID.sourceLocatorFingerprint(for: material)
        }
        return "path-fallback:" + StableLibraryID.sourceLocatorFingerprint(for: fallbackPath)
    }

    nonisolated private static func stableResourceIdentifierComponent(
        _ value: Any?
    ) -> String? {
        guard let value else { return nil }
        if let data = value as? Data { return "data:" + data.base64EncodedString() }
        if let string = value as? String { return "string:" + string }
        if let uuid = value as? UUID { return "uuid:" + uuid.uuidString.lowercased() }
        if let uuid = value as? NSUUID {
            return "uuid:" + uuid.uuidString.lowercased()
        }
        if let number = value as? NSNumber {
            return "number:\(String(cString: number.objCType)):\(number.stringValue)"
        }
        return nil
    }

    nonisolated private static func reconciledImportSelection(
        snapshot: RdcLibrarySnapshot?,
        latestSelection: String?,
        importedSelection: String?
    ) -> String? {
        guard let snapshot else { return nil }
        let validIDs = Set(snapshot.allServers.compactMap(\.id))
        if let latestSelection, validIDs.contains(latestSelection) {
            return latestSelection
        }
        if let importedSelection, validIDs.contains(importedSelection) {
            return importedSelection
        }
        return snapshot.allServers.compactMap(\.id).first
    }

    nonisolated private static func hasExactSourceFingerprintCompatibility(
        existing: RdcLibrarySnapshot,
        imported: RdcLibrarySnapshot
    ) -> Bool {
        var existingFingerprints = sourceFingerprintSet(in: existing.root)
        existingFingerprints.formUnion(existing.deletedSourceItems)
        let importedFingerprints = sourceFingerprintSet(in: imported.root)
        return !existingFingerprints.isEmpty && existingFingerprints == importedFingerprints
    }

    nonisolated private static func sourceFingerprintSet(
        in group: RdcGroupSnapshot
    ) -> Set<RdcDeletedSourceItem> {
        var result = Set<RdcDeletedSourceItem>()
        if let fingerprint = group.sourceFingerprint {
            result.insert(.init(kind: .group, sourceFingerprint: fingerprint))
        }
        for server in group.servers {
            if let fingerprint = server.sourceFingerprint {
                result.insert(.init(kind: .server, sourceFingerprint: fingerprint))
            }
        }
        for child in group.groups {
            result.formUnion(sourceFingerprintSet(in: child))
        }
        return result
    }

    func updateServer(id: String, draft: ServerPropertiesDraft) async throws {
        try await persistResourceEdit { snapshot in
            try ResourceLibraryEditor.updateServer(in: snapshot, id: id, draft: draft)
        }
    }

    func updateGroup(id: String, draft: GroupPropertiesDraft) async throws {
        try await persistResourceEdit { snapshot in
            try ResourceLibraryEditor.updateGroup(in: snapshot, id: id, draft: draft)
        }
    }

    func createChildGroup(parentID: String, name: String) async throws {
        try await persistResourceEdit { snapshot in
            try ResourceLibraryEditor.createChildGroup(
                in: snapshot, parentID: parentID, name: name
            )
        }
    }

    func moveServer(id: String, destinationGroupID: String) async throws {
        try await persistResourceEdit { snapshot in
            try ResourceLibraryEditor.moveServer(
                in: snapshot, id: id, destinationGroupID: destinationGroupID
            )
        }
    }

    func moveGroup(id: String, destinationGroupID: String) async throws {
        try await persistResourceEdit { snapshot in
            try ResourceLibraryEditor.moveGroup(
                in: snapshot, id: id, destinationGroupID: destinationGroupID
            )
        }
    }

    func deleteServer(id: String) async throws {
        try await deleteServer(id: id, expectedSnapshot: nil)
    }

    private func deleteServer(
        id: String,
        expectedSnapshot: RdcLibrarySnapshot?
    ) async throws {
        try await persistResourceDeletion(expectedSnapshot: expectedSnapshot) {
            snapshot, selectedServerID in
            try ResourceLibraryEditor.deleteServer(
                in: snapshot, id: id, selectedServerID: selectedServerID
            )
        }
    }

    func deleteGroup(id: String) async throws {
        try await deleteGroup(id: id, expectedSnapshot: nil)
    }

    private func deleteGroup(
        id: String,
        expectedSnapshot: RdcLibrarySnapshot?
    ) async throws {
        try await persistResourceDeletion(expectedSnapshot: expectedSnapshot) {
            snapshot, selectedServerID in
            try ResourceLibraryEditor.deleteGroup(
                in: snapshot, id: id, selectedServerID: selectedServerID
            )
        }
    }

    func removeLibrary() async throws {
        try await removeLibrary(expectedSnapshot: nil)
    }

    private func removeLibrary(
        expectedSnapshot: RdcLibrarySnapshot?
    ) async throws {
        try await persistResourceDeletion(expectedSnapshot: expectedSnapshot) {
            snapshot, selectedServerID in
            ResourceLibraryEditor.removeLibrary(snapshot, selectedServerID: selectedServerID)
        }
    }

    @discardableResult
    func requestServerDeletion(
        id: String,
        ownerLease: ResourcePropertySheetCoordinator.HostLease
    ) -> Bool {
        guard resourcePropertyCoordinator.isActiveLease(ownerLease),
              let snapshot = configuration.lastLibrary,
              let library,
              let server = library.servers.first(where: { $0.id == id }) else { return false }
        pendingResourceDeletion = .server(
            id: id,
            name: server.displayName,
            impact: ResourceDeletionImpact(
                groupCount: 0,
                serverCount: 1,
                containsSelectedServer: activeSessionServerID == id
            ),
            expectedSnapshot: snapshot,
            ownerLease: ownerLease
        )
        resourceOperationMessage = nil
        return true
    }

    @discardableResult
    func requestResourceEditor(
        _ route: ResourceEditorRoute,
        ownerLease: ResourcePropertySheetCoordinator.HostLease
    ) -> Bool {
        guard resourcePropertyCoordinator.isActiveLease(ownerLease) else { return false }
        resourceEditorOwnerLease = ownerLease
        resourceEditorRoute = route
        return true
    }

    @discardableResult
    func requestNewChildGroup(
        parentID: String,
        parentName: String,
        ownerLease: ResourcePropertySheetCoordinator.HostLease
    ) -> Bool {
        guard resourcePropertyCoordinator.isActiveLease(ownerLease),
              library?.groups.contains(where: { $0.id == parentID }) == true else { return false }
        newChildGroupRequest = NewChildGroupRequest(
            parentID: parentID, parentName: parentName, ownerLease: ownerLease
        )
        return true
    }

    private func dismissResourceEditor(
        ownedBy ownerLease: ResourcePropertySheetCoordinator.HostLease
    ) {
        guard resourceEditorOwnerLease == ownerLease else { return }
        resourceEditorRoute = nil
        resourceEditorOwnerLease = nil
    }

    @discardableResult
    func dismissResourceEditor(
        presentation: ResourcePropertySheetCoordinator.ResourcePresentation
    ) -> Bool {
        guard resourceEditorRoute == presentation.route,
              resourceEditorOwnerLease == presentation.lease,
              resourcePropertyCoordinator.resourcePresentation(
                requestedRoute: presentation.route,
                lease: presentation.lease
              ) == presentation else { return false }
        resourceEditorRoute = nil
        resourceEditorOwnerLease = nil
        return true
    }

    func resourceEditorRoute(
        for ownerLease: ResourcePropertySheetCoordinator.HostLease
    ) -> ResourceEditorRoute? {
        guard resourcePropertyCoordinator.isActiveLease(ownerLease),
              resourceEditorOwnerLease == ownerLease else { return nil }
        return resourceEditorRoute
    }

    func releaseResourcePresentationRequests(
        ownedBy lease: ResourcePropertySheetCoordinator.HostLease
    ) {
        dismissResourceEditor(ownedBy: lease)
        if pendingResourceDeletion?.ownerLease == lease {
            pendingResourceDeletion = nil
        }
        if newChildGroupRequest?.ownerLease == lease {
            newChildGroupRequest = nil
        }
    }

    @discardableResult
    func requestGroupDeletion(
        id: String,
        ownerLease: ResourcePropertySheetCoordinator.HostLease
    ) -> Bool {
        guard resourcePropertyCoordinator.isActiveLease(ownerLease),
              let snapshot = configuration.lastLibrary,
              snapshot.root.id != id,
              let group = library?.groups.first(where: { $0.id == id }),
              let impact = try? ResourceLibraryEditor.deletionImpact(
                in: snapshot,
                groupID: id,
                selectedServerID: activeSessionServerID
              ) else { return false }
        pendingResourceDeletion = .group(
            id: id, name: group.name, impact: impact,
            expectedSnapshot: snapshot, ownerLease: ownerLease
        )
        resourceOperationMessage = nil
        return true
    }

    @discardableResult
    func requestLibraryRemoval(
        ownerLease: ResourcePropertySheetCoordinator.HostLease
    ) -> Bool {
        guard resourcePropertyCoordinator.isActiveLease(ownerLease),
              let snapshot = configuration.lastLibrary else { return false }
        let impact = ResourceLibraryEditor.removeLibrary(
            snapshot, selectedServerID: activeSessionServerID
        ).impact
        pendingResourceDeletion = .library(
            name: snapshot.root.name, impact: impact,
            expectedSnapshot: snapshot, ownerLease: ownerLease
        )
        resourceOperationMessage = nil
        return true
    }

    func cancelResourceDeletion(_ request: PendingResourceDeletion? = nil) {
        guard request == nil || pendingResourceDeletion == request else { return }
        pendingResourceDeletion = nil
    }

    func confirmResourceDeletion(_ request: PendingResourceDeletion) async -> Bool {
        guard pendingResourceDeletion == request else { return false }
        do {
            guard isDeletionRequestStillValid(request) else {
                throw ResourceLibraryOperationError.confirmationStale
            }
            let current = try await configurationRepository.snapshot().lastLibrary
            guard current?.normalizedStableIdentity()
                    == request.expectedSnapshot.normalizedStableIdentity() else {
                throw ResourceLibraryOperationError.confirmationStale
            }
            switch request.target {
            case let .server(id, _):
                try await deleteServer(id: id, expectedSnapshot: request.expectedSnapshot)
            case let .group(id, _):
                try await deleteGroup(id: id, expectedSnapshot: request.expectedSnapshot)
            case .library:
                try await removeLibrary(expectedSnapshot: request.expectedSnapshot)
            }
            cancelResourceDeletion(request)
            return true
        } catch {
            if error as? ResourceLibraryOperationError == .confirmationStale
                || error as? ResourceLibraryOperationError == .libraryChanged {
                resourceOperationMessage = ResourceLibraryOperationError.confirmationStale.safeMessage
                cancelResourceDeletion(request)
                return false
            }
            // Transaction APIs publish a safe message and leave the library unchanged.
            let canRetry = resourcePropertyCoordinator.isActiveLease(request.ownerLease)
                && isDeletionRequestStillValid(request)
            if pendingResourceDeletion == nil, canRetry {
                pendingResourceDeletion = request
            } else if !canRetry {
                cancelResourceDeletion(request)
            }
            return false
        }
    }

    private func isDeletionRequestStillValid(
        _ request: PendingResourceDeletion
    ) -> Bool {
        let snapshot = request.expectedSnapshot
        let library = snapshot.makeLibrary()
        switch request.target {
        case let .server(id, name):
            guard let server = library.servers.first(where: { $0.id == id }),
                  server.displayName == name else { return false }
            return request.impact == ResourceDeletionImpact(
                groupCount: 0,
                serverCount: 1,
                containsSelectedServer: activeSessionServerID == id
            )
        case let .group(id, name):
            guard library.groups.first(where: { $0.id == id })?.name == name,
                  let impact = try? ResourceLibraryEditor.deletionImpact(
                    in: snapshot,
                    groupID: id,
                    selectedServerID: activeSessionServerID
                  ) else { return false }
            return impact == request.impact
        case let .library(name):
            guard snapshot.root.name == name else { return false }
            return ResourceLibraryEditor.removeLibrary(
                snapshot, selectedServerID: activeSessionServerID
            ).impact == request.impact
        }
    }

    private func persistResourceEdit(
        _ edit: @escaping (RdcLibrarySnapshot) throws -> RdcLibrarySnapshot
    ) async throws {
        var operationResult: Result<Void, Error>?
        await performOperation { model, generation in
            do {
                let previous: RdcAppConfiguration
                do {
                    previous = try await model.configurationRepository.snapshot()
                } catch {
                    throw ResourceLibraryOperationError.configurationSaveFailed
                }
                guard model.isCurrentOperation(generation) else { throw CancellationError() }
                guard let persistedSnapshot = previous.lastLibrary else {
                    throw ResourceLibraryOperationError.missingLibrary
                }
                let snapshot = persistedSnapshot.normalizedStableIdentity()
                let edited = try edit(snapshot)
                await model.resourceOperationCheckpoint()
                guard model.isCurrentOperation(generation) else { throw CancellationError() }
                let committed: RdcAppConfiguration
                do {
                    committed = try await model.configurationRepository.update { configuration in
                        guard configuration.lastLibrary == persistedSnapshot else {
                            throw ResourceLibraryOperationError.libraryChanged
                        }
                        configuration.lastLibrary = edited
                        return configuration
                    }
                } catch let error as ResourceLibraryOperationError {
                    throw error
                } catch {
                    throw ResourceLibraryOperationError.configurationSaveFailed
                }
                model.publishResourceConfiguration(
                    committed, selectedServerID: model.selectedServerID
                )
                operationResult = .success(())
            } catch {
                let safeError = model.safeResourceOperationError(error)
                operationResult = .failure(safeError)
                guard model.isCurrentOperation(generation) else { return }
                model.resourceOperationMessage = model.safeResourceOperationMessage(for: safeError)
            }
        }
        guard let operationResult else { throw CancellationError() }
        try operationResult.get()
    }

    private func persistResourceDeletion(
        expectedSnapshot: RdcLibrarySnapshot? = nil,
        _ deletion: @escaping (
            RdcLibrarySnapshot, String?
        ) throws -> ResourceDeletionResult
    ) async throws {
        var operationResult: Result<Void, Error>?
        await performOperation { model, generation in
            do {
                let previous: RdcAppConfiguration
                do {
                    previous = try await model.configurationRepository.snapshot()
                } catch {
                    throw ResourceLibraryOperationError.configurationSaveFailed
                }
                guard model.isCurrentOperation(generation) else { throw CancellationError() }
                guard let persistedSnapshot = previous.lastLibrary else {
                    throw ResourceLibraryOperationError.missingLibrary
                }
                let snapshot = persistedSnapshot.normalizedStableIdentity()
                if let expectedSnapshot, snapshot != expectedSnapshot.normalizedStableIdentity() {
                    throw ResourceLibraryOperationError.confirmationStale
                }
                let result = try deletion(snapshot, model.selectedServerID)
                await model.resourceOperationCheckpoint()
                guard model.isCurrentOperation(generation) else { throw CancellationError() }

                let removesActiveSession = model.activeSessionServerID.map {
                    result.removedServerIDs.contains($0)
                } ?? result.impact.containsSelectedServer
                if removesActiveSession,
                   model.session.hasActiveEngineSession {
                    do {
                        try await model.session.disconnectForResourceMutation()
                    } catch {
                        throw ResourceLibraryOperationError.sessionDisconnectFailed
                    }
                    guard model.session.descriptor == nil,
                          !model.session.isConnecting,
                          !model.session.hasActiveEngineSession else {
                        throw ResourceLibraryOperationError.sessionDisconnectFailed
                    }
                    guard model.isCurrentOperation(generation) else { throw CancellationError() }
                }

                let passwordStore = model.passwordStore
                let committed: RdcAppConfiguration
                do {
                    committed = try await model.configurationRepository.updateWithRollback {
                        configuration in
                        guard configuration.lastLibrary == persistedSnapshot else {
                            throw ResourceLibraryOperationError.libraryChanged
                        }
                        let prepared = Self.prepareDeletionCandidate(
                            previous: configuration, deletion: result
                        )
                        let rollbackPasswords = try await Self.deletePasswordsBeforeCommit(
                            credentialIDs: prepared.credentialsToDelete,
                            passwordStore: passwordStore
                        )
                        configuration = prepared.configuration
                        return RdcPreparedConfigurationUpdate(
                            result: configuration,
                            rollback: {
                                let restored = await Self.restoreDeletedPasswords(
                                    rollbackPasswords,
                                    passwordStore: passwordStore
                                )
                                guard restored else {
                                    throw RdcConfigurationTransactionError.rollbackFailed
                                }
                            }
                        )
                    }
                } catch let error as ResourceLibraryOperationError {
                    throw error
                } catch RdcConfigurationTransactionError.rollbackFailed {
                    throw ResourceLibraryOperationError.passwordRollbackFailed
                } catch {
                    throw ResourceLibraryOperationError.configurationSaveFailed
                }

                let reconciledSelection = model.selectedServerID.flatMap { id in
                    result.removedServerIDs.contains(id) ? nil : id
                } ?? result.selectedServerID
                model.publishResourceConfiguration(
                    committed, selectedServerID: reconciledSelection
                )
                operationResult = .success(())
            } catch {
                let safeError = model.safeResourceOperationError(error)
                operationResult = .failure(safeError)
                if model.isCurrentOperation(generation)
                    || safeError as? ResourceLibraryOperationError == .passwordStoreFailed
                    || safeError as? ResourceLibraryOperationError == .passwordRollbackFailed {
                    model.resourceOperationMessage = model.safeResourceOperationMessage(
                        for: safeError
                    )
                }
            }
        }
        guard let operationResult else { throw CancellationError() }
        try operationResult.get()
    }

    private struct PreparedResourceDeletion: Sendable {
        var configuration: RdcAppConfiguration
        var credentialsToDelete: Set<String>
    }

    private struct DeletedPasswordRollback: Sendable {
        let credentialID: String
        let password: String?
    }

    nonisolated private static func prepareDeletionCandidate(
        previous: RdcAppConfiguration,
        deletion: ResourceDeletionResult
    ) -> PreparedResourceDeletion {
        var candidate = previous
        candidate.lastLibrary = deletion.snapshot
        removeUnreferencedCertificatePins(
            from: &candidate,
            previousLibrary: previous.lastLibrary,
            finalLibrary: deletion.snapshot
        )

        var removedCredentialIDs = Set<String>()
        for id in deletion.removedGroupIDs {
            if let credentialID = candidate.groupCredentialBindings.removeValue(forKey: id) {
                removedCredentialIDs.insert(credentialID)
            }
        }
        for id in deletion.removedServerIDs {
            if let credentialID = candidate.serverCredentialBindings.removeValue(forKey: id) {
                removedCredentialIDs.insert(credentialID)
            }
        }

        var remainingReferences = Set(candidate.groupCredentialBindings.values)
        remainingReferences.formUnion(candidate.serverCredentialBindings.values)
        if let globalCredentialID = candidate.globalCredentialID {
            remainingReferences.insert(globalCredentialID)
        }
        let credentialsToDelete = removedCredentialIDs.subtracting(remainingReferences)
        for credentialID in credentialsToDelete {
            candidate.credentialMetadata.removeValue(forKey: credentialID)
        }
        return PreparedResourceDeletion(
            configuration: candidate,
            credentialsToDelete: credentialsToDelete
        )
    }

    nonisolated private static func prepareImportCandidate(
        previous: RdcAppConfiguration,
        snapshot: RdcLibrarySnapshot
    ) -> PreparedResourceDeletion {
        var candidate = previous
        candidate.lastLibrary = snapshot
        removeUnreferencedCertificatePins(
            from: &candidate,
            previousLibrary: previous.lastLibrary,
            finalLibrary: snapshot
        )
        let library = snapshot.makeLibrary()
        let validGroupIDs = Set(library.groups.map(\.id))
        let validServerIDs = Set(library.servers.map(\.id))

        var removedCredentialIDs = Set<String>()
        for groupID in Array(candidate.groupCredentialBindings.keys)
            where !validGroupIDs.contains(groupID) {
            if let credentialID = candidate.groupCredentialBindings.removeValue(forKey: groupID) {
                removedCredentialIDs.insert(credentialID)
            }
        }
        for serverID in Array(candidate.serverCredentialBindings.keys)
            where !validServerIDs.contains(serverID) {
            if let credentialID = candidate.serverCredentialBindings.removeValue(forKey: serverID) {
                removedCredentialIDs.insert(credentialID)
            }
        }

        var remainingReferences = Set(candidate.groupCredentialBindings.values)
        remainingReferences.formUnion(candidate.serverCredentialBindings.values)
        if let globalCredentialID = candidate.globalCredentialID {
            remainingReferences.insert(globalCredentialID)
        }
        let credentialsToDelete = removedCredentialIDs.subtracting(remainingReferences)
        for credentialID in credentialsToDelete {
            candidate.credentialMetadata.removeValue(forKey: credentialID)
        }
        return PreparedResourceDeletion(
            configuration: candidate,
            credentialsToDelete: credentialsToDelete
        )
    }

    nonisolated private static func removeUnreferencedCertificatePins(
        from configuration: inout RdcAppConfiguration,
        previousLibrary: RdcLibrarySnapshot?,
        finalLibrary: RdcLibrarySnapshot?
    ) {
        let removedEndpoints = libraryEndpoints(previousLibrary)
            .subtracting(libraryEndpoints(finalLibrary))
        for endpoint in removedEndpoints {
            configuration.certificatePins.removeValue(forKey: endpoint)
        }
    }

    nonisolated private static func libraryEndpoints(
        _ snapshot: RdcLibrarySnapshot?
    ) -> Set<RdpEndpoint> {
        Set(snapshot?.allServers.compactMap { server in
            let address = RdcServerAddress(server.address)
            let port = address.port ?? 3_389
            guard !address.host.isEmpty, let port = UInt16(exactly: port) else { return nil }
            return RdpEndpoint(host: address.host, port: port)
        } ?? [])
    }

    nonisolated private static func deletePasswordsBeforeCommit(
        credentialIDs: Set<String>,
        passwordStore: any PasswordStore
    ) async throws -> [DeletedPasswordRollback] {
        var rollback: [DeletedPasswordRollback] = []
        do {
            for id in credentialIDs.sorted() {
                let password = try await passwordStore.password(credentialID: id)
                rollback.append(.init(credentialID: id, password: password))
                try await passwordStore.delete(credentialID: id)
            }
            return rollback
        } catch {
            let restored = await restoreDeletedPasswords(rollback, passwordStore: passwordStore)
            throw restored
                ? ResourceLibraryOperationError.passwordStoreFailed
                : ResourceLibraryOperationError.passwordRollbackFailed
        }
    }

    nonisolated private static func restoreDeletedPasswords(
        _ passwords: [DeletedPasswordRollback],
        passwordStore: any PasswordStore
    ) async -> Bool {
        var succeeded = true
        for item in passwords {
            do {
                if let password = item.password {
                    try await passwordStore.save(
                        password: password, credentialID: item.credentialID
                    )
                } else {
                    try await passwordStore.delete(credentialID: item.credentialID)
                }
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    private func publishResourceConfiguration(
        _ configuration: RdcAppConfiguration,
        selectedServerID: String?
    ) {
        self.configuration = configuration
        library = configuration.lastLibrary?.makeLibrary(
            selectedServerID: selectedServerID
        )
        resourceOperationMessage = nil
    }

    private func safeResourceOperationMessage(for error: Error) -> String {
        if let error = error as? ResourceLibraryOperationError {
            return error.safeMessage
        }
        if error is ResourceLibraryEditError {
            return "无法完成资源库操作，请检查输入或目标位置后重试。"
        }
        if error is CancellationError {
            return "资源库操作已取消。"
        }
        return ResourceLibraryOperationError.configurationSaveFailed.safeMessage
    }

    private func safeResourceOperationError(_ error: Error) -> Error {
        if error is ResourceLibraryOperationError
            || error is ResourceLibraryEditError
            || error is CancellationError {
            return error
        }
        return ResourceLibraryOperationError.configurationSaveFailed
    }

    func saveCredential(
        scope: CredentialEditScope,
        username: String,
        domain: String?,
        password: String
    ) async throws {
        var operationResult: Result<Void, Error>?
        await performOperation { model, generation in
            do {
                switch scope {
                case let .oneTime(serverID):
                    let normalizedUsername = username.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !normalizedUsername.isEmpty else {
                        throw CredentialVaultError.invalidUsername
                    }
                    guard !password.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty else {
                        throw CredentialVaultError.emptyPassword
                    }
                    guard let server = model.selectedServer,
                          server.id == serverID else {
                        throw CredentialVaultError.configurationSaveFailed
                    }
                    let normalizedDomain = domain?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let credential = RdpConnectionCredential(
                        username: normalizedUsername,
                        domain: normalizedDomain?.isEmpty == false ? normalizedDomain : nil,
                        password: password
                    )
                    try await model.session.connect(
                        server: server,
                        credential: credential,
                        viewport: RdpViewport(width: 1_440, height: 900)
                    )
                    model.activeSessionServerID = server.id
                    guard model.isCurrentOperation(generation) else {
                        throw CancellationError()
                    }
                    model.isShowingCredentialSheet = false
                    model.connectionStartedAt = Date()
                    model.connectionErrorPresentation = nil

                case .global, .group, .server:
                    try await model.savePersistentCredential(
                        scope: scope,
                        username: username,
                        domain: domain,
                        password: password,
                        generation: generation
                    )
                }
                operationResult = .success(())
            } catch is CancellationError {
                operationResult = .failure(CancellationError())
            } catch let error as RdpSessionError {
                operationResult = .failure(error)
                guard model.isCurrentOperation(generation) else { return }
                model.connectionStartedAt = nil
                model.isShowingCredentialSheet = true
                if let server = model.selectedServer {
                    model.connectionErrorPresentation = .classify(
                        error: error,
                        authenticationActions: model.authenticationErrorActions(for: server)
                    )
                } else {
                    model.connectionErrorPresentation = .classify(
                        error: error,
                        authenticationActions: []
                    )
                }
                model.connectionDiagnosticCode = Self.diagnosticCode(for: error)
            } catch let error as CredentialVaultError {
                operationResult = .failure(error)
                guard model.isCurrentOperation(generation) else { return }
                model.connectionErrorPresentation = error == .passwordStoreFailed
                    ? .keychain : .configuration
            } catch {
                operationResult = .failure(CredentialVaultError.configurationSaveFailed)
                guard model.isCurrentOperation(generation) else { return }
                model.connectionErrorPresentation = .configuration
            }
        }
        guard let operationResult else { throw CancellationError() }
        try operationResult.get()
    }

    private func savePersistentCredential(
        scope: CredentialEditScope,
        username: String,
        domain: String?,
        password: String,
        generation: UInt64
    ) async throws {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CredentialVaultError.invalidUsername
        }
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CredentialVaultError.emptyPassword
        }
        let previousConfiguration: RdcAppConfiguration
        do {
            previousConfiguration = try await configurationRepository.snapshot()
        } catch {
            throw CredentialVaultError.configurationSaveFailed
        }
        guard isCurrentOperation(generation) else { throw CancellationError() }

        let existingID: String?
        switch scope {
        case .global:
            existingID = previousConfiguration.globalCredentialID
        case let .group(id, _):
            existingID = previousConfiguration.groupCredentialBindings[id]
        case let .server(id, _):
            existingID = previousConfiguration.serverCredentialBindings[id]
        case .oneTime:
            existingID = nil
        }
        let credentialID = existingID ?? UUID().uuidString
        let previousPassword: String?
        do {
            previousPassword = try await passwordStore.password(credentialID: credentialID)
        } catch {
            throw CredentialVaultError.passwordStoreFailed
        }
        guard isCurrentOperation(generation) else { throw CancellationError() }

        var didMutatePersistentState = false
        do {
            let metadata = try await credentialVault.saveCredential(
                id: credentialID,
                username: username,
                domain: domain,
                password: password
            )
            didMutatePersistentState = true
            guard isCurrentOperation(generation) else { throw CancellationError() }

            do {
                try await configurationRepository.update { configuration in
                    switch scope {
                    case .global:
                        configuration.globalCredentialID = metadata.id
                    case let .group(id, _):
                        configuration.groupCredentialBindings[id] = metadata.id
                    case let .server(id, _):
                        configuration.serverCredentialBindings[id] = metadata.id
                    case .oneTime:
                        break
                    }
                }
            } catch {
                throw CredentialVaultError.configurationSaveFailed
            }
            guard isCurrentOperation(generation) else { throw CancellationError() }

            let refreshed: RdcAppConfiguration
            do {
                refreshed = try await configurationRepository.snapshot()
            } catch {
                throw CredentialVaultError.configurationSaveFailed
            }
            guard isCurrentOperation(generation) else { throw CancellationError() }
            configuration = refreshed
            connectionErrorPresentation = nil
        } catch {
            if didMutatePersistentState {
                if let rollbackError = await rollBackPersistentCredential(
                    scope: scope,
                    credentialID: credentialID,
                    previousPassword: previousPassword,
                    previousConfiguration: previousConfiguration
                ) {
                    throw rollbackError
                }
            }
            if error is CancellationError || Task.isCancelled || !isCurrentOperation(generation) {
                throw CancellationError()
            }
            throw error
        }
    }

    private func rollBackPersistentCredential(
        scope: CredentialEditScope,
        credentialID: String,
        previousPassword: String?,
        previousConfiguration: RdcAppConfiguration
    ) async -> CredentialVaultError? {
        var passwordRestoreFailed = false
        do {
            if let previousPassword {
                try await passwordStore.save(
                    password: previousPassword,
                    credentialID: credentialID
                )
            } else {
                try await passwordStore.delete(credentialID: credentialID)
            }
        } catch {
            passwordRestoreFailed = true
        }

        var configurationRestoreFailed = false
        do {
            try await configurationRepository.update { configuration in
                if let metadata = previousConfiguration.credentialMetadata[credentialID] {
                    configuration.credentialMetadata[credentialID] = metadata
                } else {
                    configuration.credentialMetadata.removeValue(forKey: credentialID)
                }
                switch scope {
                case .global:
                    configuration.globalCredentialID = previousConfiguration.globalCredentialID
                case let .group(id, _):
                    if let credentialID = previousConfiguration.groupCredentialBindings[id] {
                        configuration.groupCredentialBindings[id] = credentialID
                    } else {
                        configuration.groupCredentialBindings.removeValue(forKey: id)
                    }
                case let .server(id, _):
                    if let credentialID = previousConfiguration.serverCredentialBindings[id] {
                        configuration.serverCredentialBindings[id] = credentialID
                    } else {
                        configuration.serverCredentialBindings.removeValue(forKey: id)
                    }
                case .oneTime:
                    break
                }
            }
            configuration = try await configurationRepository.snapshot()
        } catch {
            configurationRestoreFailed = true
        }

        if passwordRestoreFailed { return .passwordStoreFailed }
        if configurationRestoreFailed { return .configurationSaveFailed }
        return nil
    }

    func restoreCredentialInheritance(scope: CredentialEditScope) async throws {
        var operationError: CredentialVaultError?
        await performOperation { model, generation in
            do {
                try await model.configurationRepository.update { configuration in
                    switch scope {
                    case .global:
                        configuration.globalCredentialID = nil
                    case let .group(id, _):
                        configuration.groupCredentialBindings.removeValue(forKey: id)
                    case let .server(id, _):
                        configuration.serverCredentialBindings.removeValue(forKey: id)
                    case .oneTime:
                        break
                    }
                }
                guard model.isCurrentOperation(generation) else { return }
                model.configuration = try await model.configurationRepository.snapshot()
                guard model.isCurrentOperation(generation) else { return }
                model.connectionErrorPresentation = nil
            } catch {
                guard model.isCurrentOperation(generation) else { return }
                operationError = .configurationSaveFailed
                model.connectionErrorPresentation = .configuration
            }
        }
        if let operationError { throw operationError }
    }

    func editCredential(
        for scope: CredentialEditScope,
        host: CredentialEditorHost
    ) {
        credentialEditorPresentation = CredentialEditorPresentation(scope: scope, host: host)
    }

    func dismissCredentialEditor(host: CredentialEditorHost? = nil) {
        guard host == nil || credentialEditorPresentation?.host == host else { return }
        credentialEditorPresentation = nil
    }

    func updatePreferences(_ preferences: RdcGeneralPreferences) async throws {
        try await configurationRepository.update { configuration in
            configuration.preferences = preferences
        }
        configuration = try await configurationRepository.snapshot()
    }

    func deleteGlobalCredential() async throws {
        let previous: RdcAppConfiguration
        do {
            previous = try await configurationRepository.snapshot()
        } catch {
            throw GlobalCredentialDeletionError.configurationCommitFailed
        }
        guard let credentialID = previous.globalCredentialID else { return }

        let isStillReferenced = previous.groupCredentialBindings.values.contains(credentialID)
            || previous.serverCredentialBindings.values.contains(credentialID)
        let previousPassword: String?
        if isStillReferenced {
            previousPassword = nil
        } else {
            do {
                previousPassword = try await passwordStore.password(credentialID: credentialID)
            } catch {
                throw GlobalCredentialDeletionError.keychainReadFailed
            }
        }
        let candidate: RdcAppConfiguration = {
            var candidate = previous
            candidate.globalCredentialID = nil
            if !isStillReferenced {
                candidate.credentialMetadata.removeValue(forKey: credentialID)
            }
            return candidate
        }()

        do {
            try await configurationRepository.update { configuration in
                configuration = candidate
            }
        } catch {
            throw GlobalCredentialDeletionError.configurationCommitFailed
        }
        configuration = candidate

        if !isStillReferenced {
            do {
                try await passwordStore.delete(credentialID: credentialID)
            } catch {
                var passwordRestoreFailed = false
                if let previousPassword {
                    do {
                        try await passwordStore.save(
                            password: previousPassword,
                            credentialID: credentialID
                        )
                    } catch {
                        passwordRestoreFailed = true
                    }
                }
                var configurationRestoreFailed = false
                do {
                    try await configurationRepository.update { configuration in
                        configuration = previous
                    }
                    configuration = previous
                } catch {
                    configurationRestoreFailed = true
                }
                if passwordRestoreFailed || configurationRestoreFailed {
                    throw GlobalCredentialDeletionError.rollbackFailed
                }
                throw GlobalCredentialDeletionError.keychainDeleteFailedRolledBack
            }
        }

        do {
            configuration = try await configurationRepository.reload()
        } catch {
            throw GlobalCredentialDeletionError.committedRefreshFailed
        }
    }

    func performGlobalCredentialDeletion() async {
        do {
            try await deleteGlobalCredential()
            settingsOperationError = nil
        } catch let error as GlobalCredentialDeletionError {
            settingsOperationError = error.safeMessage
        } catch {
            settingsOperationError = GlobalCredentialDeletionError.rollbackFailed.safeMessage
        }
    }

    func deleteCertificatePin(_ endpoint: RdpEndpoint) async throws {
        try await configurationRepository.update { configuration in
            configuration.certificatePins.removeValue(forKey: endpoint)
        }
        configuration = try await configurationRepository.snapshot()
    }

    func handleImportResult(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                return
            }
            importRdgFile(at: url)
        } catch {
            importError = error.localizedDescription
        }
    }

    func importRdgFile(at url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let document = try RdcManParser().parse(fileAt: url)
            let sourceName = url.lastPathComponent
            let sourceIdentity = Self.sourceIdentity(for: url)
            let sourceLocatorAliases = Self.sourceLocatorAliases(for: url)
            Task { [weak self] in
                await self?.importLibrary(
                    document: document,
                    sourceName: sourceName,
                    sourceIdentity: sourceIdentity,
                    sourceLocatorAliases: sourceLocatorAliases
                )
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    func selectServer(id: String) {
        guard let library else {
            return
        }
        let selectedLibrary = library.selectingServer(id: id)
        guard selectedLibrary.selectedServer != nil else { return }
        isShowingCredentialSheet = false
        self.library = selectedLibrary
        connectionStartedAt = nil
        enqueueOperation { model, generation in
            await model.session.disconnect()
            guard model.isCurrentOperation(generation) else { return }
        }
    }

    func requestCredentialPrompt() {
        guard selectedServer != nil else {
            debugLaunchError = "请先选择一个服务器。"
            return
        }
        isShowingCredentialSheet = true
    }

    func connect(credential: RdpConnectionCredential) {
        guard let selectedServer else {
            debugLaunchError = "请先选择一个服务器。"
            return
        }

        enqueueOperation { model, generation in
            do {
                try await model.session.connect(
                    server: selectedServer,
                    credential: credential,
                    viewport: RdpViewport(width: 1_440, height: 900)
                )
                model.activeSessionServerID = selectedServer.id
                guard model.isCurrentOperation(generation) else { return }
                model.connectionStartedAt = Date()
            } catch is CancellationError {
                guard model.isCurrentOperation(generation) else { return }
                model.connectionStartedAt = nil
            } catch let error as RdpSessionError {
                guard model.isCurrentOperation(generation) else { return }
                model.connectionStartedAt = nil
                model.connectionErrorPresentation = .classify(
                    error: error,
                    authenticationActions: model.authenticationErrorActions(for: selectedServer)
                )
                model.connectionDiagnosticCode = Self.diagnosticCode(for: error)
            } catch {
                guard model.isCurrentOperation(generation) else { return }
                model.connectionStartedAt = nil
                model.connectionErrorPresentation = .remoteDisconnect
            }
        }
    }

    func closeSession() {
        isShowingCredentialSheet = false
        enqueueOperation { model, generation in
            await model.session.disconnect()
            guard model.isCurrentOperation(generation) else { return }
            model.connectionStartedAt = nil
        }
    }

    func handleLifecycleEvent(_ event: RdcAppLifecycleEvent) {
        guard RdcAppLifecycle.shouldShutdown(for: event) else { return }
        shutdown()
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        operationGeneration &+= 1
        let previous = operationTask
        previous?.cancel()
        operationTask = Task { [self] in
            _ = await previous?.result
            await session.shutdown()
            connectionStartedAt = nil
        }
    }

    func shutdownAndWait() async {
        guard !isShuttingDown else {
            await operationTask?.value
            return
        }
        isShuttingDown = true
        operationGeneration &+= 1
        let previous = operationTask
        previous?.cancel()
        _ = await previous?.result
        await session.shutdown()
        connectionStartedAt = nil
        operationTask = nil
    }

    func waitForPendingOperations() async {
        await operationTask?.value
    }

    private func enqueueOperation(
        _ operation: @escaping @MainActor (RdcAppModel, UInt64) async -> Void
    ) {
        guard !isShuttingDown else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        let previous = operationTask
        previous?.cancel()
        operationTask = Task { [weak self] in
            _ = await previous?.result
            guard let self,
                  isCurrentOperation(generation),
                  !Task.isCancelled else { return }
            await operation(self, generation)
        }
    }

    private func performOperation(
        _ operation: @escaping @MainActor (RdcAppModel, UInt64) async -> Void
    ) async {
        enqueueOperation(operation)
        await operationTask?.value
    }

    private func isCurrentOperation(_ generation: UInt64) -> Bool {
        !isShuttingDown && generation == operationGeneration
    }

    private func authenticationErrorActions(
        for server: RdcImportedServer
    ) -> [ConnectionErrorAction] {
        var actions: [ConnectionErrorAction] = [.editCredential(.global)]
        for groupID in server.groupPathIDs {
            let displayName = library?.groups.first { $0.id == groupID }?.name ?? "服务器组"
            actions.append(.editCredential(.group(id: groupID, displayName: displayName)))
        }
        actions.append(.editCredential(
            .server(id: server.id, displayName: server.displayName)
        ))
        actions.append(.editCredential(.oneTime(serverID: server.id)))
        actions.append(.retry)
        return actions
    }

    static func diagnosticCode(for error: RdpSessionError) -> String? {
        let code: Int32
        switch error {
        case let .network(value, _), let .protocolFailure(value, _):
            code = value
        case let .authenticationFailed(_, value):
            guard let value else { return nil }
            code = value
        case .missingEndpoint, .invalidPort, .invalidViewport,
             .certificateRejected, .notConnected, .simulatedFailure:
            return nil
        }
        return String(format: "RDP-%08X", UInt32(bitPattern: code))
    }

    private static func isTransientTransportConnectFailure(
        _ error: RdpSessionError
    ) -> Bool {
        guard case let .network(code, _) = error else { return false }
        return UInt32(bitPattern: code) == 0x0002_000D
    }

#if DEBUG
    func launchSelectedSessionExternallyForDebug() {
        guard let selectedServer else {
            debugLaunchError = "请先选择一个服务器。"
            return
        }
        enqueueOperation { model, generation in
            await model.session.disconnect()
            guard model.isCurrentOperation(generation) else { return }
            model.connectionStartedAt = nil
            do {
                let launchFile = RdpLaunchFile(
                    request: selectedServer.connectionRequest,
                    credential: nil
                )
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Rdc", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let fileURL = directory.appendingPathComponent(launchFile.suggestedFilename)
                try launchFile.contents.write(to: fileURL, atomically: true, encoding: .utf8)

                guard NSWorkspace.shared.open(fileURL) else {
                    model.debugLaunchError = "没有找到可打开 .rdp 文件的应用。"
                    return
                }
                model.debugLaunchError = nil
            } catch {
                model.debugLaunchError = error.localizedDescription
            }
        }
    }
#endif
}

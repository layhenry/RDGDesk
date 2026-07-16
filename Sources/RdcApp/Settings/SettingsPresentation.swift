import Foundation
import RdcCore

enum RdcCompactWindowLayout {
    static let extendsContentIntoTitlebar = true
    static let sidebarHeaderTopPadding = 32.0
    static let sessionHeaderBandHeight = Double(SessionToolbarMetrics.headerHeight)
    static let workspaceToolbarTopPadding = 0.0
    static let workspaceCanvasTopPadding = 52.0
    static let minimumDragRegionWidth = 120.0
    static let dragRegionHeight = 30.0
    // Coordinates are in the 1,040-point minimum root-window coordinate space.
    static let trafficLightClearanceMaxX = 92.0
    static let dragRegionMinX = 304.0
    static var dragRegionMaxX: Double { dragRegionMinX + minimumDragRegionWidth }
    static var toolbarMinX: Double { sidebarContentMaxX + toolbarContentLeadingInset }
    static let sidebarContentMaxX = 286.0
    static let sidebarDividerWidth = 1.0
    static let workspaceCanvasMinX = 310.0
    static let toolbarContentLeadingInset = Double(SessionToolbarMetrics.leadingInset)
    static var workspaceWidthAtMinimumRoot: Double {
        Double(WindowConfiguration.minimumWidth) - sidebarContentMaxX - sidebarDividerWidth
    }
    static var toolbarMaxY: Double { workspaceToolbarTopPadding + sessionHeaderBandHeight }
    static let workspaceCanvasMinY = 52.0
}

enum CredentialEditorHost: Equatable, Sendable {
    case primaryWindow(id: UUID)
    case settingsWindow
}

struct CredentialEditorPresentation: Equatable, Sendable {
    let scope: CredentialEditScope
    let host: CredentialEditorHost

    func isPresented(in candidate: CredentialEditorHost) -> Bool { host == candidate }
}

enum CredentialEditorDismissalPolicy {
    static func canDismiss(isSaving: Bool) -> Bool { !isSaving }
}

enum GlobalCredentialDeletionError: Error, Equatable, Sendable {
    case keychainReadFailed
    case configurationCommitFailed
    case keychainDeleteFailedRolledBack
    case rollbackFailed
    case committedRefreshFailed

    var safeMessage: String {
        switch self {
        case .keychainReadFailed, .configurationCommitFailed, .keychainDeleteFailedRolledBack:
            "无法删除全局凭据；原凭据已安全保留，请重试。"
        case .rollbackFailed:
            "无法完成全局凭据删除，且恢复状态失败；请重新打开设置并检查凭据状态。"
        case .committedRefreshFailed:
            "全局凭据已删除，但界面刷新失败；请重新打开设置或重启应用。"
        }
    }
}

enum RdcAppLifecycleEvent: Equatable {
    case rootWindowDisappeared
    case applicationWillTerminate
}

enum RdcAppLifecycle {
    static func shouldShutdown(for event: RdcAppLifecycleEvent) -> Bool {
        event == .applicationWillTerminate
    }
}

enum RdcSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case globalCredential
    case credentialOverrides
    case certificates
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .globalCredential: "全局凭据"
        case .credentialOverrides: "凭据覆盖"
        case .certificates: "证书"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .globalCredential: "person.crop.circle"
        case .credentialOverrides: "square.3.layers.3d"
        case .certificates: "shield"
        case .about: "info.circle"
        }
    }
}

struct GlobalCredentialSettingsState: Equatable {
    let username: String
    let domain: String
    let keychainStatusText: String
    let globalInheritanceCount: Int
    let groupOverrideCount: Int
    let serverOverrideCount: Int
    let hasGlobalCredential: Bool

    init(configuration: RdcAppConfiguration, library: RdcImportedLibrary?) {
        let metadata = configuration.globalCredentialID.flatMap {
            configuration.credentialMetadata[$0]
        }
        username = metadata?.username ?? ""
        domain = metadata?.domain ?? ""
        hasGlobalCredential = configuration.globalCredentialID != nil
        keychainStatusText = hasGlobalCredential
            ? "安全存储在 macOS 钥匙串"
            : "尚未保存全局凭据"
        groupOverrideCount = configuration.groupCredentialBindings.count
        serverOverrideCount = configuration.serverCredentialBindings.count
        globalInheritanceCount = library?.servers.filter {
            CredentialResolver.resolve(server: $0, configuration: configuration)?.source == .global
        }.count ?? 0
    }
}

struct GlobalCredentialDeletionPresentation: Equatable {
    let impactedServerCount: Int
    let keepsSharedCredential: Bool

    init(configuration: RdcAppConfiguration, library: RdcImportedLibrary?) {
        impactedServerCount = GlobalCredentialSettingsState(
            configuration: configuration,
            library: library
        ).globalInheritanceCount
        if let credentialID = configuration.globalCredentialID {
            keepsSharedCredential = configuration.groupCredentialBindings.values.contains(credentialID)
                || configuration.serverCredentialBindings.values.contains(credentialID)
        } else {
            keepsSharedCredential = false
        }
    }

    var confirmationMessage: String {
        if keepsSharedCredential {
            return "仅解除全局默认绑定；仍被分组或服务器覆盖使用的凭据与钥匙串密码会保留，独立覆盖不受影响。"
        }
        return "密码将从 macOS 钥匙串删除；分组和服务器的独立覆盖不受影响。"
    }
}

enum CredentialOverrideRowKind: Equatable {
    case group
    case server
}

struct CredentialOverrideRowState: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let kind: CredentialOverrideRowKind
    let sourceBadge: String
    let hasOverride: Bool

    var searchableText: String { "\(title) \(subtitle) \(sourceBadge)" }

    static func makeRows(
        library: RdcImportedLibrary?,
        configuration: RdcAppConfiguration
    ) -> [CredentialOverrideRowState] {
        guard let library else { return [] }
        let groups = library.groups.map { group in
            let overridden = configuration.groupCredentialBindings[group.id] != nil
            return CredentialOverrideRowState(
                id: group.id,
                title: group.name,
                subtitle: group.path.joined(separator: " / "),
                kind: .group,
                sourceBadge: overridden ? "分组覆盖" : "继承凭据",
                hasOverride: overridden
            )
        }
        let servers = library.servers.map { server in
            let resolution = CredentialResolver.resolve(server: server, configuration: configuration)
            let badge: String
            switch resolution?.source {
            case .server: badge = "单台覆盖"
            case .group: badge = "分组继承"
            case .global: badge = "继承全局"
            case nil: badge = "未设置"
            }
            return CredentialOverrideRowState(
                id: server.id,
                title: server.displayName,
                subtitle: server.address.rawValue,
                kind: .server,
                sourceBadge: badge,
                hasOverride: configuration.serverCredentialBindings[server.id] != nil
            )
        }
        return groups + servers
    }
}

struct CertificateTrustSheetState: Equatable {
    let challenge: RdpCertificateChallenge
    let oldFingerprint: String?
    let newFingerprint: String
    let lastConfirmedAt: Date?
    let persistentActionTitle: String
    let defaultDecision: RdpCertificateDecision
    let isChangedCertificate: Bool

    init(presentation: CertificateTrustPresentation) {
        switch presentation {
        case let .firstUse(challenge):
            self.challenge = challenge
            oldFingerprint = nil
            newFingerprint = challenge.sha256Fingerprint.uppercased()
            lastConfirmedAt = nil
            persistentActionTitle = "始终信任"
            defaultDecision = .trustOnce
            isChangedCertificate = false
        case let .changed(old, new):
            challenge = new
            oldFingerprint = old.sha256Fingerprint.uppercased()
            newFingerprint = new.sha256Fingerprint.uppercased()
            lastConfirmedAt = old.lastConfirmedAt
            persistentActionTitle = "更新并始终信任"
            defaultDecision = .trustOnce
            isChangedCertificate = true
        }
    }
}

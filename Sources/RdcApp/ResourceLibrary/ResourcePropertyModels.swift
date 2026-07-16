import Combine
import Foundation
import RdcCore

@MainActor
final class ResourcePropertySheetCoordinator: ObservableObject {
    enum PresentationClaim: Equatable {
        case claimed
        case alreadyOwned
        case ownedByAnotherWindow
        case blockedByCredentialEditor
        case waitingForCurrentDismissal
        case hostInactive
    }

    struct SaveToken: Equatable, Hashable {
        fileprivate let id = UUID()
    }

    struct HostLease: Equatable {
        fileprivate let host: CredentialEditorHost
        fileprivate let generation = UUID()
    }

    struct ResourcePresentation: Identifiable, Equatable {
        let route: ResourceEditorRoute
        let lease: HostLease
        let id = UUID()
    }

    struct OneTimeCredentialPresentation: Identifiable, Equatable {
        let lease: HostLease
        let id = UUID()
    }

    struct DeletionPresentation: Identifiable, Equatable {
        let request: PendingResourceDeletion
        let lease: HostLease
        let id = UUID()
    }

    struct DeletionToken: Equatable, Hashable {
        fileprivate let id = UUID()
    }

    enum DeletionDismissal: Equatable {
        case cancelled
        case operationInFlight
        case stale
    }

    struct NewChildGroupPresentation: Identifiable, Equatable {
        let request: NewChildGroupRequest
        let lease: HostLease
        let id = UUID()
    }

    enum SharedModalKind: Equatable {
        case importer
        case certificate(attemptID: UUID, challengeID: UInt64)
        case importError
        case importRestore
        case resourceError
        case connectionError
    }

    struct SharedModalPresentation: Identifiable, Equatable {
        let kind: SharedModalKind
        let lease: HostLease
        let id = UUID()
    }

    @Published private(set) var revision: UInt64 = 0
    private var activeResourcePresentation: ResourcePresentation?
    private var activeOneTimeCredentialPresentation: OneTimeCredentialPresentation?
    private var activeDeletionPresentation: DeletionPresentation?
    private var activeNewChildGroupPresentation: NewChildGroupPresentation?
    private var activeSharedModalPresentation: SharedModalPresentation?
    private var registeredLeases: [HostLease] = []
    private var savePresentations: [SaveToken: ResourcePresentation] = [:]
    private var pendingCredentialPresentation: CredentialEditorPresentation?
    private var deletionPresentations: [DeletionToken: DeletionPresentation] = [:]

    var hasActiveResourcePresentation: Bool {
        activeResourcePresentation != nil
    }

    var hasActivePresentation: Bool {
        hasActiveResourcePresentation || activeOneTimeCredentialPresentation != nil
            || activeDeletionPresentation != nil
            || activeNewChildGroupPresentation != nil
            || activeSharedModalPresentation != nil
    }

    @discardableResult
    func register(host: CredentialEditorHost) -> HostLease {
        let lease = HostLease(host: host)
        registeredLeases.append(lease)
        revision &+= 1
        return lease
    }

    @discardableResult
    func unregister(lease: HostLease) -> Bool {
        guard isActive(lease) else { return false }
        let ownedResourcePresentation = activeResourcePresentation?.lease == lease
        registeredLeases.removeAll { $0 == lease }
        releasePresentations(ownedBy: lease)
        revision &+= 1
        return ownedResourcePresentation
    }

    func isActiveLease(_ lease: HostLease) -> Bool {
        isActive(lease)
    }

    func claimPresentation(
        route: ResourceEditorRoute,
        lease: HostLease,
        activeCredential: CredentialEditorPresentation?,
        isOneTimeCredentialPromptRequested: Bool
    ) -> PresentationClaim {
        guard isActive(lease) else { return .hostInactive }
        if let activeSharedModalPresentation {
            return activeSharedModalPresentation.lease == lease
                ? .waitingForCurrentDismissal : .ownedByAnotherWindow
        }
        if let activeResourcePresentation,
           activeResourcePresentation.lease != lease {
            return .ownedByAnotherWindow
        }
        if let activeDeletionPresentation {
            return activeDeletionPresentation.lease == lease
                ? .waitingForCurrentDismissal : .ownedByAnotherWindow
        }
        if let activeNewChildGroupPresentation {
            return activeNewChildGroupPresentation.lease == lease
                ? .waitingForCurrentDismissal : .ownedByAnotherWindow
        }
        if activeResourcePresentation?.route == route {
            return .alreadyOwned
        }
        guard activeCredential == nil,
              !isOneTimeCredentialPromptRequested,
              activeOneTimeCredentialPresentation == nil else {
            return .blockedByCredentialEditor
        }
        // Keep the route SwiftUI actually presented until its onDismiss fires.
        // Replacing it here would let A's late callback release a newly claimed B.
        if activeResourcePresentation != nil {
            return .waitingForCurrentDismissal
        }
        activeResourcePresentation = ResourcePresentation(route: route, lease: lease)
        savePresentations.removeAll()
        pendingCredentialPresentation = nil
        revision &+= 1
        return .claimed
    }

    func resourcePresentation(
        requestedRoute: ResourceEditorRoute?,
        lease: HostLease
    ) -> ResourcePresentation? {
        guard isActive(lease),
              let requestedRoute,
              let activeResourcePresentation,
              activeResourcePresentation.lease == lease,
              activeResourcePresentation.route == requestedRoute else { return nil }
        return activeResourcePresentation
    }

    func credentialBindingPresentation(
        _ presentation: CredentialEditorPresentation?,
        lease: HostLease
    ) -> CredentialEditorPresentation? {
        guard isActive(lease),
              !hasActivePresentation,
              let presentation,
              presentation.isPresented(in: lease.host) else { return nil }
        return presentation
    }

    func canDismissCredentialPresentation(
        _ presentation: CredentialEditorPresentation,
        lease: HostLease
    ) -> Bool {
        isActive(lease) && presentation.isPresented(in: lease.host)
    }

    func claimOneTimeCredentialPrompt(
        lease: HostLease,
        requested: Bool,
        activeCredential: CredentialEditorPresentation?
    ) -> OneTimeCredentialPresentation? {
        guard isActive(lease),
              requested,
              activeCredential == nil,
              activeSharedModalPresentation == nil,
              !hasActiveResourcePresentation,
              activeDeletionPresentation == nil,
              activeNewChildGroupPresentation == nil else { return nil }
        if let activeOneTimeCredentialPresentation {
            return activeOneTimeCredentialPresentation.lease == lease
                ? activeOneTimeCredentialPresentation
                : nil
        }
        let presentation = OneTimeCredentialPresentation(lease: lease)
        activeOneTimeCredentialPresentation = presentation
        revision &+= 1
        return presentation
    }

    func oneTimeCredentialPresentation(
        requested: Bool,
        activeCredential: CredentialEditorPresentation?,
        lease: HostLease
    ) -> OneTimeCredentialPresentation? {
        guard isActive(lease),
              requested,
              activeCredential == nil,
              !hasActiveResourcePresentation,
              let activeOneTimeCredentialPresentation,
              activeOneTimeCredentialPresentation.lease == lease else { return nil }
        return activeOneTimeCredentialPresentation
    }

    func dismissOneTimeCredentialPrompt(
        _ presentation: OneTimeCredentialPresentation
    ) -> Bool {
        guard canDismissOneTimeCredentialPrompt(presentation) else { return false }
        activeOneTimeCredentialPresentation = nil
        revision &+= 1
        return true
    }

    func canDismissOneTimeCredentialPrompt(
        _ presentation: OneTimeCredentialPresentation
    ) -> Bool {
        isActive(presentation.lease)
            && activeOneTimeCredentialPresentation == presentation
    }

    func beginSave(for presentation: ResourcePresentation) -> SaveToken? {
        guard activeResourcePresentation == presentation,
              !savePresentations.values.contains(presentation) else { return nil }
        let token = SaveToken()
        savePresentations[token] = presentation
        return token
    }

    func invalidateSave(_ token: SaveToken) {
        savePresentations.removeValue(forKey: token)
    }

    func invalidateSaves(for presentation: ResourcePresentation) {
        savePresentations = savePresentations.filter { $0.value != presentation }
    }

    func shouldCloseAfterSave(
        token: SaveToken,
        currentPresentation: ResourcePresentation,
        currentRoute: ResourceEditorRoute?,
        currentOwnerLease: HostLease?
    ) -> Bool {
        guard let presentation = savePresentations.removeValue(forKey: token) else {
            return false
        }
        return activeResourcePresentation == presentation
            && currentPresentation == presentation
            && currentRoute == presentation.route
            && currentOwnerLease == presentation.lease
    }

    func requestCredentialHandoff(
        scope: CredentialEditScope,
        lease: HostLease,
        from route: ResourceEditorRoute
    ) -> Bool {
        guard isActive(lease),
              activeResourcePresentation?.route == route,
              activeResourcePresentation?.lease == lease,
              pendingCredentialPresentation == nil else { return false }
        pendingCredentialPresentation = CredentialEditorPresentation(
            scope: scope,
            host: lease.host
        )
        return true
    }

    func completeResourceDismissal(
        presentation: ResourcePresentation,
        activeCredential: CredentialEditorPresentation?,
        isOneTimeCredentialPromptRequested: Bool
    ) -> CredentialEditorPresentation? {
        guard isActive(presentation.lease),
              activeResourcePresentation == presentation else { return nil }
        let pendingHandoff = activeCredential == nil && !isOneTimeCredentialPromptRequested
            ? pendingCredentialPresentation
            : nil
        pendingCredentialPresentation = nil
        activeResourcePresentation = nil
        savePresentations.removeAll()
        revision &+= 1
        return pendingHandoff
    }

    func claimDeletion(
        _ request: PendingResourceDeletion,
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
        if let activeDeletionPresentation {
            if activeDeletionPresentation.lease != lease { return .ownedByAnotherWindow }
            return activeDeletionPresentation.request == request
                ? .alreadyOwned : .waitingForCurrentDismissal
        }
        guard activeCredential == nil,
              !isOneTimeCredentialPromptRequested,
              activeResourcePresentation == nil,
              activeOneTimeCredentialPresentation == nil,
              activeNewChildGroupPresentation == nil else {
            return .blockedByCredentialEditor
        }
        activeDeletionPresentation = DeletionPresentation(request: request, lease: lease)
        deletionPresentations.removeAll()
        revision &+= 1
        return .claimed
    }

    func deletionPresentation(
        requested: PendingResourceDeletion?,
        lease: HostLease
    ) -> DeletionPresentation? {
        guard isActive(lease),
              let requested,
              let activeDeletionPresentation,
              activeDeletionPresentation.lease == lease,
              activeDeletionPresentation.request == requested else { return nil }
        return activeDeletionPresentation
    }

    func beginDeletion(for presentation: DeletionPresentation) -> DeletionToken? {
        guard activeDeletionPresentation == presentation,
              !deletionPresentations.values.contains(presentation) else { return nil }
        let token = DeletionToken()
        deletionPresentations[token] = presentation
        return token
    }

    @discardableResult
    func finishDeletion(
        token: DeletionToken,
        presentation: DeletionPresentation,
        succeeded: Bool,
        requestedStillCurrent: Bool
    ) -> Bool {
        guard deletionPresentations.removeValue(forKey: token) == presentation,
              isActive(presentation.lease) else { return false }
        if activeDeletionPresentation == presentation {
            activeDeletionPresentation = nil
        }
        if !succeeded, requestedStillCurrent {
            activeDeletionPresentation = DeletionPresentation(
                request: presentation.request, lease: presentation.lease
            )
        }
        revision &+= 1
        return true
    }

    func deletionDialogDidDismiss(
        _ presentation: DeletionPresentation
    ) -> DeletionDismissal {
        guard activeDeletionPresentation == presentation else { return .stale }
        activeDeletionPresentation = nil
        revision &+= 1
        return deletionPresentations.values.contains(presentation)
            ? .operationInFlight : .cancelled
    }

    func hasInFlightDeletion(ownedBy lease: HostLease) -> Bool {
        deletionPresentations.values.contains { $0.lease == lease }
    }

    @discardableResult
    func dismissDeletion(_ presentation: DeletionPresentation) -> Bool {
        guard activeDeletionPresentation == presentation,
              !deletionPresentations.values.contains(presentation) else { return false }
        activeDeletionPresentation = nil
        revision &+= 1
        return true
    }

    func claimNewChildGroup(
        _ request: NewChildGroupRequest,
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
        if let activeNewChildGroupPresentation {
            if activeNewChildGroupPresentation.lease != lease { return .ownedByAnotherWindow }
            return activeNewChildGroupPresentation.request == request
                ? .alreadyOwned : .waitingForCurrentDismissal
        }
        guard activeCredential == nil,
              !isOneTimeCredentialPromptRequested,
              activeResourcePresentation == nil,
              activeOneTimeCredentialPresentation == nil,
              activeDeletionPresentation == nil else {
            return .blockedByCredentialEditor
        }
        activeNewChildGroupPresentation = NewChildGroupPresentation(
            request: request, lease: lease
        )
        revision &+= 1
        return .claimed
    }

    func newChildGroupPresentation(
        requested: NewChildGroupRequest?,
        lease: HostLease
    ) -> NewChildGroupPresentation? {
        guard isActive(lease),
              let requested,
              let activeNewChildGroupPresentation,
              activeNewChildGroupPresentation.lease == lease,
              activeNewChildGroupPresentation.request == requested else { return nil }
        return activeNewChildGroupPresentation
    }

    @discardableResult
    func dismissNewChildGroup(_ presentation: NewChildGroupPresentation) -> Bool {
        guard activeNewChildGroupPresentation == presentation else { return false }
        activeNewChildGroupPresentation = nil
        revision &+= 1
        return true
    }

    func claimSharedModal(
        kind: SharedModalKind,
        lease: HostLease,
        activeCredential: CredentialEditorPresentation?
    ) -> PresentationClaim {
        guard isActive(lease) else { return .hostInactive }
        if let activeSharedModalPresentation {
            if activeSharedModalPresentation.lease != lease { return .ownedByAnotherWindow }
            return activeSharedModalPresentation.kind == kind
                ? .alreadyOwned : .waitingForCurrentDismissal
        }
        guard activeCredential == nil,
              activeResourcePresentation == nil,
              activeOneTimeCredentialPresentation == nil,
              activeDeletionPresentation == nil,
              activeNewChildGroupPresentation == nil else {
            return .waitingForCurrentDismissal
        }
        activeSharedModalPresentation = SharedModalPresentation(kind: kind, lease: lease)
        revision &+= 1
        return .claimed
    }

    func sharedModalPresentation(
        kind: SharedModalKind,
        lease: HostLease
    ) -> SharedModalPresentation? {
        guard isActive(lease),
              activeSharedModalPresentation?.lease == lease,
              activeSharedModalPresentation?.kind == kind else { return nil }
        return activeSharedModalPresentation
    }

    func activeSharedModal(ownedBy lease: HostLease) -> SharedModalPresentation? {
        guard isActive(lease), activeSharedModalPresentation?.lease == lease else { return nil }
        return activeSharedModalPresentation
    }

    @discardableResult
    func dismissSharedModal(_ presentation: SharedModalPresentation) -> Bool {
        guard isActive(presentation.lease),
              activeSharedModalPresentation == presentation else { return false }
        activeSharedModalPresentation = nil
        revision &+= 1
        return true
    }

    private func isActive(_ lease: HostLease) -> Bool {
        registeredLeases.contains(lease)
    }

    private func releasePresentations(ownedBy lease: HostLease) {
        if activeResourcePresentation?.lease == lease {
            pendingCredentialPresentation = nil
            activeResourcePresentation = nil
            savePresentations.removeAll()
        }
        if activeOneTimeCredentialPresentation?.lease == lease {
            activeOneTimeCredentialPresentation = nil
        }
        if activeDeletionPresentation?.lease == lease {
            activeDeletionPresentation = nil
        }
        deletionPresentations = deletionPresentations.filter { $0.value.lease != lease }
        if activeNewChildGroupPresentation?.lease == lease {
            activeNewChildGroupPresentation = nil
        }
        if activeSharedModalPresentation?.lease == lease {
            activeSharedModalPresentation = nil
        }
    }
}

@MainActor
final class ServerPropertyEditorModel: ObservableObject {
    @Published var name: String
    @Published var host: String
    @Published var portText: String
    @Published var isSaving = false
    @Published private(set) var saveError: String?

    let credentialSummary: String
    private let original: ServerPropertiesDraft

    init(server: RdcImportedServer, credentialSummary: String) {
        let port = server.address.port ?? 3_389
        let original = ServerPropertiesDraft(
            displayName: server.displayName,
            host: server.address.host,
            port: port
        )
        self.original = (try? original.validated()) ?? original
        name = server.displayName
        host = server.address.host
        portText = String(port)
        self.credentialSummary = credentialSummary
    }

    var nameError: String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "名称不能为空。" : nil
    }

    var hostError: String? {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 3_389
        return (try? ServerPropertiesDraft(
            displayName: name.isEmpty ? "Server" : name,
            host: value,
            port: port
        ).validated()) == nil ? "请输入有效的 IP 地址或主机名。" : nil
    }

    var portError: String? {
        let value = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(value), (1...65_535).contains(port) else {
            return "端口必须是 1–65535 之间的整数。"
        }
        return nil
    }

    var draft: ServerPropertiesDraft? {
        guard nameError == nil, hostError == nil, portError == nil else { return nil }
        let trimmedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmedPort) else { return nil }
        return try? ServerPropertiesDraft(
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port
        ).validated()
    }

    var canSave: Bool {
        guard !isSaving, let draft else { return false }
        return draft != original
    }

    func save(
        using operation: (ServerPropertiesDraft) async throws -> Void
    ) async -> Bool {
        guard canSave, let draft else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await operation(draft)
            return true
        } catch {
            saveError = Self.safeMessage(for: error)
            return false
        }
    }

    private static func safeMessage(for error: Error) -> String {
        if let operationError = error as? ResourceLibraryOperationError {
            return operationError.safeMessage
        }
        return "无法保存服务器属性，请重试。"
    }
}

@MainActor
final class GroupPropertyEditorModel: ObservableObject {
    @Published var name: String
    @Published var isSaving = false
    @Published private(set) var saveError: String?

    let credentialSummary: String
    private let original: GroupPropertiesDraft
    private let siblingNames: Set<String>

    init(
        group: RdcImportedGroup,
        siblingNames: [String],
        credentialSummary: String = "继承凭据"
    ) {
        let original = GroupPropertiesDraft(name: group.name)
        self.original = (try? original.validated()) ?? original
        name = group.name
        var names = Set(siblingNames)
        names.remove(self.original.name)
        self.siblingNames = names
        self.credentialSummary = credentialSummary
    }

    var nameError: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "名称不能为空。" }
        if siblingNames.contains(trimmed) { return "同一群组下已存在这个名称。" }
        return nil
    }

    var draft: GroupPropertiesDraft? {
        guard nameError == nil else { return nil }
        return try? GroupPropertiesDraft(name: name).validated()
    }

    var canSave: Bool {
        guard !isSaving, let draft else { return false }
        return draft != original
    }

    func save(using operation: (GroupPropertiesDraft) async throws -> Void) async -> Bool {
        guard canSave, let draft else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await operation(draft)
            return true
        } catch {
            if let operationError = error as? ResourceLibraryOperationError {
                saveError = operationError.safeMessage
            } else {
                saveError = "无法保存群组属性，请重试。"
            }
            return false
        }
    }
}

enum ResourcePropertyPresentation: Equatable {
    case server(RdcImportedServer, credentialSummary: String)
    case group(RdcImportedGroup, siblingNames: [String], credentialSummary: String)

    var resourceID: String {
        switch self {
        case let .server(server, _): server.id
        case let .group(group, _, _): group.id
        }
    }

    var credentialSummary: String {
        switch self {
        case let .server(_, summary), let .group(_, _, summary): summary
        }
    }

    static func resolve(
        route: ResourceEditorRoute,
        library: RdcImportedLibrary?,
        configuration: RdcAppConfiguration
    ) -> ResourcePropertyPresentation? {
        guard let library else { return nil }
        switch route {
        case let .server(id):
            guard let server = library.servers.first(where: { $0.id == id }) else { return nil }
            return .server(
                server,
                credentialSummary: serverCredentialSummary(
                    server: server, library: library, configuration: configuration
                )
            )
        case let .group(id):
            guard let group = library.groups.first(where: { $0.id == id }) else { return nil }
            let siblings = library.groups
                .filter { $0.parentID == group.parentID && $0.id != group.id }
                .map(\.name)
            return .group(
                group,
                siblingNames: siblings,
                credentialSummary: groupCredentialSummary(
                    group: group, library: library, configuration: configuration
                )
            )
        }
    }

    private static func serverCredentialSummary(
        server: RdcImportedServer,
        library: RdcImportedLibrary,
        configuration: RdcAppConfiguration
    ) -> String {
        switch CredentialResolver.resolve(server: server, configuration: configuration)?.source {
        case .server: return "服务器独立凭据"
        case let .group(groupID):
            let name = library.groups.first(where: { $0.id == groupID })?.name ?? "父群组"
            return "继承自群组「\(name)」"
        case .global: return "继承自全局账户"
        case nil: return "未设置凭据"
        }
    }

    private static func groupCredentialSummary(
        group: RdcImportedGroup,
        library: RdcImportedLibrary,
        configuration: RdcAppConfiguration
    ) -> String {
        if configuration.groupCredentialBindings[group.id] != nil {
            return "群组独立凭据"
        }
        var parentID = group.parentID
        while let currentID = parentID,
              let parent = library.groups.first(where: { $0.id == currentID }) {
            if configuration.groupCredentialBindings[currentID] != nil {
                return "继承自群组「\(parent.name)」"
            }
            parentID = parent.parentID
        }
        return configuration.globalCredentialID == nil ? "继承凭据" : "继承自全局账户"
    }
}

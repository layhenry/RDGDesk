import RdcCore
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@main
struct RdcApplication: App {
    @StateObject private var model = RdcAppModel()
    @NSApplicationDelegateAdaptor(RdcApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(WindowConfiguration.primaryTitle) {
            RdcRootView(model: model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(
            width: CGFloat(WindowConfiguration.defaultWidth),
            height: CGFloat(WindowConfiguration.defaultHeight)
        )
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)

        Settings {
            RdcSettingsView(model: model)
                .onAppear { appDelegate.model = model }
        }
    }
}

@MainActor
final class RdcApplicationDelegate: NSObject, NSApplicationDelegate {
    var model: RdcAppModel?

    func applicationWillTerminate(_ notification: Notification) {
        model?.handleLifecycleEvent(.applicationWillTerminate)
    }
}

struct RdcRootView: View {
    @ObservedObject var model: RdcAppModel
    @State private var credentialEditorHost = CredentialEditorHost.primaryWindow(id: UUID())
    @State private var credentialEditorLease: ResourcePropertySheetCoordinator.HostLease?
    @ObservedObject private var resourcePropertyCoordinator: ResourcePropertySheetCoordinator

    init(model: RdcAppModel) {
        self.model = model
        _resourcePropertyCoordinator = ObservedObject(
            wrappedValue: model.resourcePropertyCoordinator
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            ResourceLibrarySidebarView(
                model: model,
                credentialEditorHost: credentialEditorHost,
                ownerLease: credentialEditorLease
            )

            Divider()
                .opacity(0.35)
                .frame(width: CGFloat(RdcCompactWindowLayout.sidebarDividerWidth))

            SessionWorkspaceView(model: model)
        }
        .frame(
            minWidth: CGFloat(WindowConfiguration.minimumWidth),
            minHeight: CGFloat(WindowConfiguration.minimumHeight)
        )
        .background(AppBackdrop())
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .topLeading) {
            WindowDragRegion()
                .frame(
                    width: CGFloat(RdcCompactWindowLayout.minimumDragRegionWidth),
                    height: CGFloat(RdcCompactWindowLayout.dragRegionHeight)
                )
                .padding(.leading, CGFloat(RdcCompactWindowLayout.dragRegionMinX))
                .accessibilityHidden(true)
        }
        .fileImporter(
            isPresented: sharedBoolBinding(
                kind: .importer,
                requested: model.isShowingImporter,
                dismiss: { model.isShowingImporter = false }
            ),
            allowedContentTypes: [.rdgDocument, .xml],
            allowsMultipleSelection: false
        ) { result in
            model.handleImportResult(result)
        }
        .alert("导入失败", isPresented: sharedBoolBinding(
            kind: .importError,
            requested: model.importError != nil,
            dismiss: { model.importError = nil }
        )) {
            Button("好") {
                model.importError = nil
            }
        } message: {
            Text(model.importError ?? "")
        }
        .alert("导入完成", isPresented: sharedBoolBinding(
            kind: .importRestore,
            requested: model.deletedImportRestoreCount != nil,
            dismiss: { model.dismissDeletedItemsRestoreOffer() }
        )) {
            Button("保持本地删除", role: .cancel) {
                model.dismissDeletedItemsRestoreOffer()
            }
            Button("恢复导入内容") {
                Task { await model.restoreDeletedItemsFromLastImport() }
            }
        } message: {
            Text("已保留本机删除的 \(model.deletedImportRestoreCount ?? 0) 个项目。需要重新导入这些项目吗？")
        }
        .sheet(item: oneTimeCredentialBinding(lease: credentialEditorLease)) { presentation in
            CredentialPromptSheet(model: model)
                .onDisappear {
                    oneTimeCredentialSheetDidDisappear(presentation)
                }
        }
        .sheet(item: resourceEditorBinding(lease: credentialEditorLease)) { presentation in
            ResourcePropertySheetHost(
                model: model,
                presentation: presentation,
                coordinator: resourcePropertyCoordinator
            )
            .onDisappear {
                resourcePropertySheetDidDisappear(presentation)
            }
        }
        .sheet(item: credentialEditorBinding(lease: credentialEditorLease)) { item in
            CredentialEditorSheet(model: model, scope: item.scope, host: item.host)
        }
        .sheet(item: newChildGroupBinding(lease: credentialEditorLease)) { presentation in
            NewChildGroupSheet(request: presentation.request, model: model)
                .onDisappear { newChildGroupSheetDidDisappear(presentation) }
        }
        .sheet(item: certificateSheetBinding) { presentation in
            CertificateTrustSheet(model: model, presentation: presentation)
                .onDisappear {
                    guard let kind = presentation.sharedModalKind else { return }
                    dismissSharedModal(kind: kind)
                }
        }
        .confirmationDialog(
            deletionPresentation?.request.title ?? "确认删除",
            isPresented: deletionDialogIsPresented,
            titleVisibility: .visible,
            presenting: deletionPresentation
        ) { presentation in
            Button(presentation.request.destructiveButtonTitle, role: .destructive) {
                confirmDeletion(presentation)
            }
            .accessibilityLabel(presentation.request.destructiveAccessibilityLabel)
            Button("取消", role: .cancel) {
                cancelDeletion(presentation)
            }
        } message: { presentation in
            Text(deletionMessage(for: presentation.request))
        }
        .alert("资源库操作失败", isPresented: sharedBoolBinding(
            kind: .resourceError,
            requested: model.resourceOperationMessage != nil
                && model.pendingResourceDeletion == nil,
            dismiss: { model.resourceOperationMessage = nil }
        )) {
            Button("好") { model.resourceOperationMessage = nil }
        } message: {
            Text(model.resourceOperationMessage ?? "")
        }
        .alert("连接失败", isPresented: sharedBoolBinding(
            kind: .connectionError,
            requested: model.connectionErrorMessage != nil,
            dismiss: { model.clearConnectionError() }
        )) {
            Button("好") {
                model.clearConnectionError()
            }
        } message: {
            Text(model.connectionErrorMessage ?? "")
        }
        .task {
            await model.loadPersistedState()
        }
        .onAppear {
            guard credentialEditorLease == nil else { return }
            let lease = resourcePropertyCoordinator.register(host: credentialEditorHost)
            credentialEditorLease = lease
            synchronizeResourcePropertyPresentation(lease: lease)
        }
        .onReceive(model.objectWillChange) { _ in
            synchronizeAfterPublishedChange()
        }
        .onReceive(resourcePropertyCoordinator.objectWillChange) { _ in
            synchronizeAfterPublishedChange()
        }
        .onDisappear { [lease = credentialEditorLease] in
            rootDidDisappear(lease: lease)
        }
    }

    private func synchronizeAfterPublishedChange() {
        Task { @MainActor in
            await Task.yield()
            synchronizeResourcePropertyPresentation(lease: credentialEditorLease)
        }
    }

    private func rootDidDisappear(
        lease: ResourcePropertySheetCoordinator.HostLease?
    ) {
        guard let lease else {
            model.handleLifecycleEvent(.rootWindowDisappeared)
            return
        }
        let credentialPresentation = model.credentialEditorPresentation
        let shouldDismissCredential = credentialPresentation.map {
            resourcePropertyCoordinator.canDismissCredentialPresentation($0, lease: lease)
        } ?? false
        _ = resourcePropertyCoordinator.unregister(lease: lease)
        model.releaseResourcePresentationRequests(ownedBy: lease)
        if credentialPresentation != nil, shouldDismissCredential {
            model.dismissCredentialEditor(host: credentialEditorHost)
        }
        if credentialEditorLease == lease { credentialEditorLease = nil }
        model.handleLifecycleEvent(.rootWindowDisappeared)
    }

    private var certificateSheetBinding: Binding<CertificateTrustSheetItem?> {
        let item = model.pendingCertificate.map {
            CertificateTrustSheetItem($0, token: model.session.pendingCertificateToken)
        }
        let captured: ResourcePropertySheetCoordinator.SharedModalPresentation? = {
            guard let item, let kind = item.sharedModalKind,
                  let lease = credentialEditorLease else { return nil }
            return resourcePropertyCoordinator.sharedModalPresentation(
                kind: kind, lease: lease
            )
        }()
        return Binding<CertificateTrustSheetItem?>(
            get: {
                guard let item, let kind = item.sharedModalKind,
                      let lease = credentialEditorLease,
                      resourcePropertyCoordinator.sharedModalPresentation(
                        kind: kind, lease: lease
                      ) != nil else { return nil }
                return item
            },
            set: { value in
                guard value == nil, let captured else { return }
                _ = resourcePropertyCoordinator.dismissSharedModal(captured)
            }
        )
    }

    private func sharedBoolBinding(
        kind: ResourcePropertySheetCoordinator.SharedModalKind,
        requested: Bool,
        dismiss: @escaping () -> Void
    ) -> Binding<Bool> {
        let captured = credentialEditorLease.flatMap {
            resourcePropertyCoordinator.sharedModalPresentation(kind: kind, lease: $0)
        }
        return Binding(
            get: {
                guard requested, let lease = credentialEditorLease else { return false }
                return resourcePropertyCoordinator.sharedModalPresentation(
                    kind: kind, lease: lease
                ) != nil
            },
            set: { value in
                guard !value, let captured,
                      resourcePropertyCoordinator.dismissSharedModal(captured) else { return }
                dismiss()
                synchronizeResourcePropertyPresentation(lease: captured.lease)
            }
        )
    }

    private func dismissSharedModal(
        kind: ResourcePropertySheetCoordinator.SharedModalKind
    ) {
        guard let lease = credentialEditorLease,
              let presentation = resourcePropertyCoordinator.sharedModalPresentation(
                kind: kind, lease: lease
              ), resourcePropertyCoordinator.dismissSharedModal(presentation) else { return }
        synchronizeResourcePropertyPresentation(lease: lease)
    }

    private var deletionPresentation: ResourcePropertySheetCoordinator.DeletionPresentation? {
        guard let lease = credentialEditorLease else { return nil }
        return resourcePropertyCoordinator.deletionPresentation(
            requested: model.pendingResourceDeletion, lease: lease
        )
    }

    private var deletionDialogIsPresented: Binding<Bool> {
        let captured = deletionPresentation
        return Binding(
            get: { deletionPresentation != nil },
            set: { isPresented in
                guard !isPresented, let captured else { return }
                deletionDialogDidDismiss(captured)
            }
        )
    }

    private var resourceOperationAlertIsPresented: Binding<Bool> {
        Binding(
            get: {
                model.resourceOperationMessage != nil
                    && model.pendingResourceDeletion == nil
                    && deletionPresentation == nil
            },
            set: { if !$0 { model.resourceOperationMessage = nil } }
        )
    }

    private func deletionMessage(for request: PendingResourceDeletion) -> String {
        guard model.pendingResourceDeletion == request,
              let operationMessage = model.resourceOperationMessage else {
            return request.message
        }
        return request.message + "\n\n" + operationMessage
    }

    private func cancelDeletion(
        _ presentation: ResourcePropertySheetCoordinator.DeletionPresentation
    ) {
        guard resourcePropertyCoordinator.dismissDeletion(presentation) else { return }
        model.cancelResourceDeletion(presentation.request)
    }

    private func deletionDialogDidDismiss(
        _ presentation: ResourcePropertySheetCoordinator.DeletionPresentation
    ) {
        switch resourcePropertyCoordinator.deletionDialogDidDismiss(presentation) {
        case .cancelled:
            model.cancelResourceDeletion(presentation.request)
        case .operationInFlight, .stale:
            break
        }
    }

    private func confirmDeletion(
        _ presentation: ResourcePropertySheetCoordinator.DeletionPresentation
    ) {
        guard let token = resourcePropertyCoordinator.beginDeletion(for: presentation) else {
            return
        }
        Task {
            let succeeded = await model.confirmResourceDeletion(presentation.request)
            _ = resourcePropertyCoordinator.finishDeletion(
                token: token,
                presentation: presentation,
                succeeded: succeeded,
                requestedStillCurrent: model.pendingResourceDeletion == presentation.request
            )
            synchronizeResourcePropertyPresentation(lease: presentation.lease)
        }
    }

    private func credentialEditorBinding(
        lease: ResourcePropertySheetCoordinator.HostLease?
    ) -> Binding<CredentialEditorItem?> {
        let capturedPresentation: CredentialEditorPresentation? = lease.flatMap {
            resourcePropertyCoordinator.credentialBindingPresentation(
                model.credentialEditorPresentation,
                lease: $0
            )
        }
        return Binding<CredentialEditorItem?>(
            get: {
                guard let lease,
                      let presentation = resourcePropertyCoordinator
                    .credentialBindingPresentation(
                        model.credentialEditorPresentation,
                        lease: lease
                    ) else { return nil }
                return CredentialEditorItem(scope: presentation.scope, host: presentation.host)
            },
            set: { item in
                guard item == nil,
                      let lease,
                      let capturedPresentation,
                      model.credentialEditorPresentation == capturedPresentation,
                      resourcePropertyCoordinator.canDismissCredentialPresentation(
                        capturedPresentation,
                        lease: lease
                      ) else { return }
                model.dismissCredentialEditor(host: capturedPresentation.host)
            }
        )
    }

    private func resourceEditorBinding(
        lease: ResourcePropertySheetCoordinator.HostLease?
    ) -> Binding<ResourcePropertySheetCoordinator.ResourcePresentation?> {
        let capturedPresentation: ResourcePropertySheetCoordinator.ResourcePresentation? = lease.flatMap {
            return resourcePropertyCoordinator.resourcePresentation(
                requestedRoute: model.resourceEditorRoute(for: $0),
                lease: $0
            )
        }
        return Binding<ResourcePropertySheetCoordinator.ResourcePresentation?>(
            get: {
                guard let lease else { return nil }
                return resourcePropertyCoordinator.resourcePresentation(
                    requestedRoute: model.resourceEditorRoute(for: lease), lease: lease
                )
            },
            set: { presentation in
                guard presentation == nil,
                      let lease,
                      let capturedPresentation,
                      resourcePropertyCoordinator.resourcePresentation(
                        requestedRoute: model.resourceEditorRoute(for: lease),
                        lease: lease
                      ) == capturedPresentation else { return }
                _ = model.dismissResourceEditor(presentation: capturedPresentation)
            }
        )
    }

    private func newChildGroupBinding(
        lease: ResourcePropertySheetCoordinator.HostLease?
    ) -> Binding<ResourcePropertySheetCoordinator.NewChildGroupPresentation?> {
        let captured = lease.flatMap {
            resourcePropertyCoordinator.newChildGroupPresentation(
                requested: model.newChildGroupRequest, lease: $0
            )
        }
        return Binding(
            get: {
                guard let lease else { return nil }
                return resourcePropertyCoordinator.newChildGroupPresentation(
                    requested: model.newChildGroupRequest, lease: lease
                )
            },
            set: { value in
                guard value == nil, let captured else { return }
                newChildGroupSheetDidDisappear(captured)
            }
        )
    }

    private func newChildGroupSheetDidDisappear(
        _ presentation: ResourcePropertySheetCoordinator.NewChildGroupPresentation
    ) {
        guard resourcePropertyCoordinator.dismissNewChildGroup(presentation) else { return }
        if model.newChildGroupRequest == presentation.request {
            model.newChildGroupRequest = nil
        }
        synchronizeResourcePropertyPresentation(lease: presentation.lease)
    }

    private func oneTimeCredentialBinding(
        lease: ResourcePropertySheetCoordinator.HostLease?
    ) -> Binding<ResourcePropertySheetCoordinator.OneTimeCredentialPresentation?> {
        let capturedPresentation = lease.flatMap {
            resourcePropertyCoordinator.oneTimeCredentialPresentation(
                requested: model.isShowingCredentialSheet,
                activeCredential: model.credentialEditorPresentation,
                lease: $0
            )
        }
        return Binding<ResourcePropertySheetCoordinator.OneTimeCredentialPresentation?>(
            get: {
                guard let lease else { return nil }
                return resourcePropertyCoordinator.oneTimeCredentialPresentation(
                    requested: model.isShowingCredentialSheet,
                    activeCredential: model.credentialEditorPresentation,
                    lease: lease
                )
            },
            set: { presentation in
                guard presentation == nil,
                      let capturedPresentation,
                      resourcePropertyCoordinator.canDismissOneTimeCredentialPrompt(
                        capturedPresentation
                      ) else { return }
                model.isShowingCredentialSheet = false
            }
        )
    }

    private func resourcePropertySheetDidDisappear(
        _ dismissedPresentation: ResourcePropertySheetCoordinator.ResourcePresentation
    ) {
        let credentialPresentation = resourcePropertyCoordinator.completeResourceDismissal(
            presentation: dismissedPresentation,
            activeCredential: model.credentialEditorPresentation,
            isOneTimeCredentialPromptRequested: model.isShowingCredentialSheet
        )
        if let credentialPresentation, model.credentialEditorPresentation == nil {
            model.editCredential(
                for: credentialPresentation.scope,
                host: credentialPresentation.host
            )
        }
        synchronizeResourcePropertyPresentation(lease: dismissedPresentation.lease)
    }

    private func oneTimeCredentialSheetDidDisappear(
        _ presentation: ResourcePropertySheetCoordinator.OneTimeCredentialPresentation
    ) {
        _ = resourcePropertyCoordinator.dismissOneTimeCredentialPrompt(presentation)
        synchronizeResourcePropertyPresentation(lease: presentation.lease)
    }

    private func synchronizeResourcePropertyPresentation(
        lease: ResourcePropertySheetCoordinator.HostLease?
    ) {
        guard let lease else { return }
        if let sharedKind = requestedSharedModalKind {
            let claim = resourcePropertyCoordinator.claimSharedModal(
                kind: sharedKind,
                lease: lease,
                activeCredential: model.credentialEditorPresentation
            )
            if claim == .claimed || claim == .alreadyOwned || claim == .ownedByAnotherWindow {
                return
            }
        }
        _ = resourcePropertyCoordinator.claimOneTimeCredentialPrompt(
            lease: lease,
            requested: model.isShowingCredentialSheet,
            activeCredential: model.credentialEditorPresentation
        )
        if let deletion = model.pendingResourceDeletion {
            let result = resourcePropertyCoordinator.claimDeletion(
                deletion,
                lease: lease,
                activeCredential: model.credentialEditorPresentation,
                isOneTimeCredentialPromptRequested: model.isShowingCredentialSheet
            )
            if result == .claimed || result == .alreadyOwned {
                return
            }
        }
        if let request = model.newChildGroupRequest {
            let result = resourcePropertyCoordinator.claimNewChildGroup(
                request,
                lease: lease,
                activeCredential: model.credentialEditorPresentation,
                isOneTimeCredentialPromptRequested: model.isShowingCredentialSheet
            )
            if result == .claimed || result == .alreadyOwned {
                return
            }
        }
        guard let route = model.resourceEditorRoute(for: lease) else { return }
        let result = resourcePropertyCoordinator.claimPresentation(
            route: route,
            lease: lease,
            activeCredential: model.credentialEditorPresentation,
            isOneTimeCredentialPromptRequested: model.isShowingCredentialSheet
        )
        _ = result // A blocked request remains queued until the active modal dismisses.
    }

    private var requestedSharedModalKind: ResourcePropertySheetCoordinator.SharedModalKind? {
        if let pending = model.pendingCertificate,
           let token = model.session.pendingCertificateToken {
            return CertificateTrustSheetItem(pending, token: token).sharedModalKind
        }
        if model.isShowingImporter { return .importer }
        if model.importError != nil { return .importError }
        if model.deletedImportRestoreCount != nil { return .importRestore }
        if model.resourceOperationMessage != nil, model.pendingResourceDeletion == nil {
            return .resourceError
        }
        if model.connectionErrorMessage != nil { return .connectionError }
        return nil
    }
}

private struct AppBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(red: 0.94, green: 0.96, blue: 0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct ResourceLibrarySidebarView: View {
    @ObservedObject var model: RdcAppModel
    let credentialEditorHost: CredentialEditorHost
    let ownerLease: ResourcePropertySheetCoordinator.HostLease?
    @State private var searchText = ""
    @State private var expandedGroupIDs = Set<String>()
    @Environment(\.openSettings) private var openSettings

    private let accessibility = RdcAccessibilityProfile.direction2

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(alignment: .leading, spacing: 12) {
                Text("我的连接")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                searchField
            }

            libraryContent

            sidebarFooter
        }
        .padding(.horizontal, 18)
        .padding(.top, CGFloat(RdcCompactWindowLayout.sidebarHeaderTopPadding))
        .padding(.bottom, 14)
        .frame(width: CGFloat(RdcCompactWindowLayout.sidebarContentMaxX))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .onAppear {
            resetExpandedGroups()
        }
        .onChange(of: model.library?.sourceName) { _, _ in
            resetExpandedGroups()
        }
        .onChange(of: model.configuration.lastLibrary?.root) { _, _ in
            resetExpandedGroups()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility.resourceLibraryLabel)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(AppBranding.productName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Text(model.connectionStatusPrefix)
                    Text(model.selectedServer?.address.rawValue ?? "导入 .rdg")
                }
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button {
                model.isShowingImporter = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }
            .help("导入兼容 RDCMan 的 .rdg 文件")
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索连接", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel(accessibility.searchFieldLabel)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.03), radius: 8, y: 2)
    }

    private var libraryContent: some View {
        ScrollView {
            if let sidebar {
                if sidebar.rows.isEmpty {
                    SidebarEmptyView(importAction: {
                        model.isShowingImporter = true
                    })
                    .padding(.top, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sidebar.rows) { row in
                            ResourceLibraryRowView(
                                row: row,
                                model: model,
                                credentialEditorHost: credentialEditorHost,
                                ownerLease: ownerLease
                            ) {
                                handleRowTap(row)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                SidebarEmptyView(importAction: {
                    model.isShowingImporter = true
                })
                .padding(.top, 24)
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 10) {
            SidebarFooterButton(symbol: "gearshape", help: "打开设置") {
                openSettings()
            }
            SidebarFooterButton(symbol: "questionmark.circle", help: "帮助") {}
            Spacer()
            SidebarFooterButton(symbol: "person.crop.circle.fill", tint: Color(red: 0.29, green: 0.48, blue: 0.92), help: "账户") {}
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }

    private var sidebar: ResourceLibrarySidebarState? {
        model.resourceLibrarySidebarState(
            expandedGroupIDs: expandedGroupIDs,
            searchText: searchText
        )
    }

    private func handleRowTap(_ row: ResourceLibrarySidebarRow) {
        switch row.kind {
        case .group:
            let groupID = row.id.replacingOccurrences(of: "group:", with: "")
            if expandedGroupIDs.contains(groupID) {
                expandedGroupIDs.remove(groupID)
                Task { await model.setGroupExpanded(id: groupID, isExpanded: false) }
            } else {
                expandedGroupIDs.insert(groupID)
                Task { await model.setGroupExpanded(id: groupID, isExpanded: true) }
            }
        case .server:
            if let serverID = row.representedServerID {
                model.selectServer(id: serverID)
            }
        }
    }

    private func resetExpandedGroups() {
        guard model.library != nil else {
            expandedGroupIDs = []
            return
        }
        expandedGroupIDs = model.persistedExpandedGroupIDs
    }
}

private struct SidebarEmptyView: View {
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            Text("导入 .rdg 文件")
                .font(.system(size: 14, weight: .semibold))
            Text("选择兼容 RDCMan 的 .rdg 文件")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("导入") {
                importAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
    }
}

private struct SidebarFooterButton: View {
    let symbol: String
    var tint: Color = .secondary
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ResourceLibraryRowView: View {
    let row: ResourceLibrarySidebarRow
    @ObservedObject var model: RdcAppModel
    let credentialEditorHost: CredentialEditorHost
    let ownerLease: ResourcePropertySheetCoordinator.HostLease?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                disclosureIcon

                Image(systemName: symbolName)
                    .font(.system(size: row.kind == .group ? 14 : 22, weight: .medium))
                    .foregroundStyle(symbolTint)
                    .frame(width: 25, height: 25)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.system(size: 14, weight: row.isSelected ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let countBadge = row.countBadge, row.kind == .group {
                    Text("\(countBadge)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 18)
                        .background(Color.white.opacity(0.52), in: Capsule())
                }
            }
            .padding(.leading, CGFloat(row.indentationLevel) * 14)
            .padding(.trailing, 9)
            .frame(maxWidth: .infinity, minHeight: row.kind == .server ? 50 : 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            if let ownerLease {
                ResourceLibraryRowMenu(
                    row: row,
                    model: model,
                    credentialEditorHost: credentialEditorHost,
                    ownerLease: ownerLease,
                    toggleExpansion: action
                )
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard row.kind == .server,
                      model.configuration.preferences.doubleClickConnects,
                      let serverID = row.representedServerID else { return }
                Task {
                    model.selectServer(id: serverID)
                    await model.waitForPendingOperations()
                    await model.connectSelectedServer()
                }
            }
        )
    }

    @ViewBuilder
    private var disclosureIcon: some View {
        if let disclosureState = row.disclosureState {
            Image(systemName: disclosureState == .expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.8))
                .frame(width: 10)
        } else {
            Color.clear
                .frame(width: 10)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(row.isSelected ? Color.primary.opacity(0.07) : Color.clear)
    }

    private var symbolName: String {
        guard row.kind == .server else {
            return row.disclosureState == .expanded ? "folder.fill" : "folder"
        }
        if row.title.localizedCaseInsensitiveContains("windows") ||
            row.title.localizedCaseInsensitiveContains("server") {
            return "square.grid.2x2.fill"
        }
        return "display"
    }

    private var symbolTint: Color {
        guard row.kind == .server else {
            return Color(red: 0.50, green: 0.57, blue: 0.66)
        }
        if symbolName == "square.grid.2x2.fill" {
            return Color(red: 0.14, green: 0.51, blue: 0.95)
        }
        return Color(red: 0.42, green: 0.47, blue: 0.55)
    }

    private var accessibilityLabel: String {
        if let subtitle = row.subtitle {
            return "\(row.title), \(subtitle)"
        }
        return row.title
    }
}

private struct SessionWorkspaceView: View {
    @ObservedObject var model: RdcAppModel
    private let layout = SessionWorkspaceLayout.direction2
    private let accessibility = RdcAccessibilityProfile.direction2

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            if let server = model.selectedServer {
                sessionCanvas(for: server)
                .padding(.top, CGFloat(RdcCompactWindowLayout.workspaceCanvasTopPadding))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            } else {
                EmptySessionCanvas(importAction: {
                    model.isShowingImporter = true
                })
                .padding(.top, CGFloat(RdcCompactWindowLayout.workspaceCanvasTopPadding))
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }

            AdaptiveSessionToolbar(model: model)
                .padding(.top, CGFloat(RdcCompactWindowLayout.workspaceToolbarTopPadding))
        }
        .accessibilityLabel(accessibility.sessionCanvasLabel)
    }

    @ViewBuilder
    private func sessionCanvas(for server: RdcImportedServer) -> some View {
        if model.session.isConnecting {
            ZStack {
                RemotePlaceholderBackground()
                ProgressView("正在建立嵌入式连接…")
                    .controlSize(.large)
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(layout.canvas.cornerRadius)))
        } else if model.session.descriptor != nil {
            RemoteDesktopSurface(
                frame: model.session.frame,
                resizesWithWindow: model.configuration.preferences.resizesRemoteDesktopWithWindow,
                onResize: model.session.resize,
                onPointer: model.session.sendPointer,
                onKey: model.session.sendKey,
                onUnicode: model.session.sendUnicode
            )
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(layout.canvas.cornerRadius)))
            .overlay {
                RoundedRectangle(cornerRadius: CGFloat(layout.canvas.cornerRadius))
                    .stroke(Color.black.opacity(layout.canvas.borderOpacity), lineWidth: CGFloat(layout.canvas.borderWidth))
            }
        } else {
            RemoteDesktopCanvas(
                style: layout.canvas,
                server: server,
                connectAction: {
                    Task { await model.connectSelectedServer() }
                }
            )
        }
    }
}

private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { self }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct EmptySessionCanvas: View {
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "display.and.arrow.down")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
            Text("选择一个远程桌面")
                .font(.system(size: 19, weight: .semibold))
            Text("导入兼容 RDCMan 的 .rdg 文件后，左侧会显示服务器列表。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("导入 .rdg") {
                importAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct RemoteDesktopCanvas: View {
    let style: SessionCanvasStyle
    let server: RdcImportedServer
    let connectAction: () -> Void
    private let accessibility = RdcAccessibilityProfile.direction2

    var body: some View {
        ZStack(alignment: .bottom) {
            RemotePlaceholderBackground()

            HStack(spacing: 14) {
                Image(systemName: "display")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(server.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(server.address.rawValue)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 20)

                Label("双击连接", systemImage: "arrow.up.right.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.7), lineWidth: 1)
            }
            .padding(22)
        }
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(style.cornerRadius), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CGFloat(style.cornerRadius), style: .continuous)
                .stroke(Color.white.opacity(0.65), lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: CGFloat(style.cornerRadius), style: .continuous)
                .stroke(Color.black.opacity(style.borderOpacity), lineWidth: CGFloat(style.borderWidth))
        }
        .shadow(color: .black.opacity(0.18), radius: CGFloat(style.shadowRadius), x: 0, y: 22)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            connectAction()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility.remoteScreenLabel)
    }

}

private struct RemotePlaceholderBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.91, green: 0.95, blue: 1.00),
                        Color(red: 0.83, green: 0.89, blue: 0.98),
                        Color(red: 0.91, green: 0.87, blue: 0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.blue.opacity(0.22))
                    .frame(width: proxy.size.width * 0.62)
                    .blur(radius: 3)
                    .offset(x: proxy.size.width * 0.31, y: -proxy.size.height * 0.22)

                Circle()
                    .fill(Color.purple.opacity(0.18))
                    .frame(width: proxy.size.width * 0.48)
                    .blur(radius: 5)
                    .offset(x: -proxy.size.width * 0.34, y: proxy.size.height * 0.28)

                RoundedRectangle(cornerRadius: 72, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 34)
                    .frame(width: proxy.size.width * 0.72, height: proxy.size.height * 0.42)
                    .rotationEffect(.degrees(-14))
                    .offset(x: proxy.size.width * 0.14, y: -proxy.size.height * 0.06)

                LinearGradient(
                    colors: [.white.opacity(0.22), .clear, .blue.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

private struct CredentialPromptSheet: View {
    @ObservedObject var model: RdcAppModel
    @State private var username = ""
    @State private var domain = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接到 \(model.selectedServer?.displayName ?? "远程桌面")")
                .font(.headline)

            TextField("用户名", text: $username)
                .textFieldStyle(.roundedBorder)
            TextField("域（可选）", text: $domain)
                .textFieldStyle(.roundedBorder)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)

            Text("密码只用于本次嵌入式连接，不会保存。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") {
                    password.removeAll(keepingCapacity: false)
                    model.isShowingCredentialSheet = false
                }
                Button("连接") {
                    let credential = RdpConnectionCredential(
                        username: username.nilIfBlank,
                        domain: domain.nilIfBlank,
                        password: password
                    )
                    model.connect(credential: credential)
                    password.removeAll(keepingCapacity: false)
                    model.isShowingCredentialSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.nilIfBlank == nil || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 390)
        .onAppear {
            username = model.selectedServer?.credentials?.userName ?? ""
            domain = model.selectedServer?.credentials?.domain ?? ""
            password = ""
        }
        .onDisappear {
            password.removeAll(keepingCapacity: false)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension UTType {
    static let rdgDocument = UTType(filenameExtension: "rdg") ?? .xml
}

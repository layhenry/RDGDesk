import RdcCore
import SwiftUI

struct ResourcePropertySheetHost: View {
    @ObservedObject var model: RdcAppModel
    let presentation: ResourcePropertySheetCoordinator.ResourcePresentation
    @ObservedObject var coordinator: ResourcePropertySheetCoordinator

    private var route: ResourceEditorRoute { presentation.route }

    @ViewBuilder
    var body: some View {
        Group {
            if let resolvedPresentation = ResourcePropertyPresentation.resolve(
                route: route,
                library: model.library,
                configuration: model.configuration
            ) {
                switch resolvedPresentation {
                case let .server(server, credentialSummary):
                    ServerPropertySheet(
                        model: model,
                        server: server,
                        presentation: presentation,
                        coordinator: coordinator,
                        credentialSummary: credentialSummary,
                        changeCredential: {
                            transitionToCredentialEditor(
                                .server(id: server.id, displayName: server.displayName)
                            )
                        }
                    )
                case let .group(group, siblingNames, credentialSummary):
                    GroupPropertySheet(
                        model: model,
                        group: group,
                        presentation: presentation,
                        coordinator: coordinator,
                        siblingNames: siblingNames,
                        credentialSummary: credentialSummary,
                        changeCredential: {
                            transitionToCredentialEditor(
                                .group(id: group.id, displayName: group.name)
                            )
                        }
                    )
                }
            } else {
                ContentUnavailableView(
                    "找不到资源",
                    systemImage: "exclamationmark.triangle",
                    description: Text("服务器列表可能已发生变化，请关闭后重试。")
                )
                .frame(width: 420, height: 240)
            }
        }
    }

    private func transitionToCredentialEditor(_ scope: CredentialEditScope) {
        guard coordinator.requestCredentialHandoff(
            scope: scope,
            lease: presentation.lease,
            from: route
        ) else { return }
        _ = model.dismissResourceEditor(presentation: presentation)
    }
}

private struct ServerPropertySheet: View {
    @ObservedObject private var model: RdcAppModel
    @StateObject private var editor: ServerPropertyEditorModel
    @ObservedObject private var coordinator: ResourcePropertySheetCoordinator
    private let presentation: ResourcePropertySheetCoordinator.ResourcePresentation
    private let serverID: String
    private let changeCredential: () -> Void

    init(
        model: RdcAppModel,
        server: RdcImportedServer,
        presentation: ResourcePropertySheetCoordinator.ResourcePresentation,
        coordinator: ResourcePropertySheetCoordinator,
        credentialSummary: String,
        changeCredential: @escaping () -> Void
    ) {
        self.model = model
        self.presentation = presentation
        self.coordinator = coordinator
        serverID = server.id
        self.changeCredential = changeCredential
        _editor = StateObject(wrappedValue: ServerPropertyEditorModel(
            server: server,
            credentialSummary: credentialSummary
        ))
    }

    var body: some View {
        ResourcePropertySheetSurface(
            title: RdcAccessibilityProfile.direction2.serverPropertiesTitle,
            subtitle: "编辑显示信息和下次连接使用的地址。",
            isSaving: editor.isSaving,
            canSave: editor.canSave,
            saveError: editor.saveError,
            cancel: close,
            save: save
        ) {
            PropertyField(label: "名称", error: editor.nameError) {
                TextField("服务器名称", text: $editor.name)
                    .accessibilityLabel("服务器名称")
            }
            PropertyField(label: "地址", error: editor.hostError) {
                TextField("IP 地址或主机名", text: $editor.host)
                    .textContentType(.URL)
                    .accessibilityLabel("服务器地址")
            }
            PropertyField(label: "端口", error: editor.portError) {
                TextField("3389", text: $editor.portText)
                    .frame(width: 110)
                    .accessibilityLabel("服务器端口")
            }
            CredentialPropertyRow(
                summary: editor.credentialSummary,
                isSaving: editor.isSaving,
                action: changeCredential
            )
        }
        .interactiveDismissDisabled(editor.isSaving)
        .onDisappear { invalidatePendingSave() }
    }

    private func save() {
        guard let token = coordinator.beginSave(for: presentation) else { return }
        Task {
            let succeeded = await editor.save(using: {
                try await model.updateServer(id: serverID, draft: $0)
            })
            guard succeeded else {
                coordinator.invalidateSave(token)
                return
            }
            if coordinator.shouldCloseAfterSave(
                token: token,
                currentPresentation: presentation,
                currentRoute: model.resourceEditorRoute,
                currentOwnerLease: model.resourceEditorOwnerLease
            ) {
                _ = model.dismissResourceEditor(presentation: presentation)
            }
        }
    }

    private func close() {
        guard !editor.isSaving else { return }
        _ = model.dismissResourceEditor(presentation: presentation)
    }

    private func invalidatePendingSave() {
        coordinator.invalidateSaves(for: presentation)
    }
}

private struct GroupPropertySheet: View {
    @ObservedObject private var model: RdcAppModel
    @StateObject private var editor: GroupPropertyEditorModel
    @ObservedObject private var coordinator: ResourcePropertySheetCoordinator
    private let presentation: ResourcePropertySheetCoordinator.ResourcePresentation
    private let groupID: String
    private let changeCredential: () -> Void

    init(
        model: RdcAppModel,
        group: RdcImportedGroup,
        presentation: ResourcePropertySheetCoordinator.ResourcePresentation,
        coordinator: ResourcePropertySheetCoordinator,
        siblingNames: [String],
        credentialSummary: String,
        changeCredential: @escaping () -> Void
    ) {
        self.model = model
        self.presentation = presentation
        self.coordinator = coordinator
        groupID = group.id
        self.changeCredential = changeCredential
        _editor = StateObject(wrappedValue: GroupPropertyEditorModel(
            group: group,
            siblingNames: siblingNames,
            credentialSummary: credentialSummary
        ))
    }

    var body: some View {
        ResourcePropertySheetSurface(
            title: RdcAccessibilityProfile.direction2.groupPropertiesTitle,
            subtitle: "名称会立即更新到服务器列表。",
            isSaving: editor.isSaving,
            canSave: editor.canSave,
            saveError: editor.saveError,
            cancel: close,
            save: save
        ) {
            PropertyField(label: "名称", error: editor.nameError) {
                TextField("群组名称", text: $editor.name)
                    .accessibilityLabel("群组名称")
            }
            CredentialPropertyRow(
                summary: editor.credentialSummary,
                isSaving: editor.isSaving,
                action: changeCredential
            )
        }
        .interactiveDismissDisabled(editor.isSaving)
        .onDisappear { invalidatePendingSave() }
    }

    private func save() {
        guard let token = coordinator.beginSave(for: presentation) else { return }
        Task {
            let succeeded = await editor.save(using: {
                try await model.updateGroup(id: groupID, draft: $0)
            })
            guard succeeded else {
                coordinator.invalidateSave(token)
                return
            }
            if coordinator.shouldCloseAfterSave(
                token: token,
                currentPresentation: presentation,
                currentRoute: model.resourceEditorRoute,
                currentOwnerLease: model.resourceEditorOwnerLease
            ) {
                _ = model.dismissResourceEditor(presentation: presentation)
            }
        }
    }

    private func close() {
        guard !editor.isSaving else { return }
        _ = model.dismissResourceEditor(presentation: presentation)
    }

    private func invalidatePendingSave() {
        coordinator.invalidateSaves(for: presentation)
    }
}

private struct ResourcePropertySheetSurface<Content: View>: View {
    let title: String
    let subtitle: String
    let isSaving: Bool
    let canSave: Bool
    let saveError: String?
    let cancel: () -> Void
    let save: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Form {
                content
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(
                minHeight: title == RdcAccessibilityProfile.direction2.serverPropertiesTitle
                    ? 260 : 180
            )
            .padding(18)
            .background(.background.opacity(0.76), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator.opacity(0.5), lineWidth: 0.7)
            }
            .disabled(isSaving)

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("保存失败：\(saveError)")
            }

            HStack(spacing: 10) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在保存…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(.ultraThinMaterial)
    }
}

private struct PropertyField<Content: View>: View {
    let label: String
    let error: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label)
                    .font(.callout.weight(.medium))
                    .frame(width: 56, alignment: .leading)
                content
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 72)
                    .accessibilityLabel("\(label)错误：\(error)")
            }
        }
    }
}

private struct CredentialPropertyRow: View {
    let summary: String
    let isSaving: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text("凭据")
                .font(.callout.weight(.medium))
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("更改凭据…", action: action)
                    .buttonStyle(.link)
                    .disabled(isSaving)
                    .accessibilityLabel("更改凭据")
            }
            Spacer(minLength: 0)
        }
    }
}

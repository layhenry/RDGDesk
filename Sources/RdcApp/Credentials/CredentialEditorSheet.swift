import RdcCore
import SwiftUI

struct CredentialEditorSheet: View {
    @ObservedObject var model: RdcAppModel
    @StateObject private var editor: CredentialEditorModel
    @Environment(\.dismiss) private var dismiss
    private let host: CredentialEditorHost

    init(model: RdcAppModel, scope: CredentialEditScope, host: CredentialEditorHost) {
        self.model = model
        self.host = host
        let metadata: CredentialMetadata?
        switch scope {
        case .global:
            metadata = model.configuration.globalCredentialID.flatMap {
                model.configuration.credentialMetadata[$0]
            }
        case let .group(id, _):
            metadata = model.configuration.groupCredentialBindings[id].flatMap {
                model.configuration.credentialMetadata[$0]
            }
        case let .server(id, _):
            metadata = model.configuration.serverCredentialBindings[id].flatMap {
                model.configuration.credentialMetadata[$0]
            }
        case .oneTime:
            metadata = nil
        }
        _editor = StateObject(wrappedValue: CredentialEditorModel(
            scope: scope,
            username: metadata?.username ?? "",
            domain: metadata?.domain ?? ""
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.bold())
                Text(scopeDescription).font(.caption).foregroundStyle(.secondary)
            }

            Form {
                TextField("用户名", text: $editor.username)
                    .accessibilityLabel("凭据用户名")
                TextField("域（可选）", text: $editor.domain)
                    .accessibilityLabel("凭据域")
                SecureField("密码", text: $editor.password)
                    .accessibilityLabel("安全密码输入")
            }
            .formStyle(.grouped)

            Label("密码将安全存储在 macOS 钥匙串中。", systemImage: "key.fill")
                .font(.caption).foregroundStyle(.secondary)

            if let message = editor.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack {
                if hasExistingOverride {
                    Button("使用继承凭据") {
                        Task {
                            if await editor.restoreInheritance(using: model) {
                                close()
                            }
                        }
                    }
                    .disabled(editor.isSaving)
                }
                Spacer()
                Button("取消", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(editor.isSaving)
                Button("保存") {
                    Task {
                        if await editor.save(using: model) { close() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(editor.isSaving)
            }
        }
        .padding(26)
        .frame(width: 460)
        .interactiveDismissDisabled(editor.isSaving)
        .onDisappear { editor.cancel() }
    }

    private var title: String {
        switch editor.scope {
        case .global: "编辑全局凭据"
        case let .group(_, name): "设置分组凭据：\(name)"
        case let .server(_, name): "设置服务器凭据：\(name)"
        case .oneTime: "本次连接凭据"
        }
    }

    private var scopeDescription: String {
        switch editor.scope {
        case .global: "影响所有未设置覆盖的服务器"
        case .group: "影响此分组及其未覆盖的子项"
        case .server: "只影响这一台服务器"
        case .oneTime: "密码不会保存"
        }
    }

    private var hasExistingOverride: Bool {
        switch editor.scope {
        case .global: false
        case let .group(id, _): model.configuration.groupCredentialBindings[id] != nil
        case let .server(id, _): model.configuration.serverCredentialBindings[id] != nil
        case .oneTime: false
        }
    }

    private func close() {
        guard CredentialEditorDismissalPolicy.canDismiss(isSaving: editor.isSaving) else { return }
        editor.cancel()
        model.dismissCredentialEditor(host: host)
        dismiss()
    }
}

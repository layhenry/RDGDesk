import Combine
import Foundation
import RdcCore

enum CredentialEditScope: Equatable, Sendable {
    case global
    case group(id: String, displayName: String)
    case server(id: String, displayName: String)
    case oneTime(serverID: String)
}

@MainActor
final class CredentialEditorModel: ObservableObject {
    let scope: CredentialEditScope
    @Published var username: String
    @Published var domain: String
    @Published var password = ""
    @Published private(set) var isSaving = false
    @Published private(set) var validationMessage: String?

    init(
        scope: CredentialEditScope,
        username: String = "",
        domain: String = ""
    ) {
        self.scope = scope
        self.username = username
        self.domain = domain
    }

    func save(using appModel: RdcAppModel) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer {
            password.removeAll(keepingCapacity: false)
            isSaving = false
        }
        do {
            try await appModel.saveCredential(
                scope: scope,
                username: username,
                domain: domain,
                password: password
            )
            validationMessage = nil
            return true
        } catch CredentialVaultError.invalidUsername {
            validationMessage = "请输入用户名。"
        } catch CredentialVaultError.emptyPassword {
            validationMessage = "请输入密码。"
        } catch {
            validationMessage = "无法保存凭据，请重试。"
        }
        return false
    }

    func restoreInheritance(using appModel: RdcAppModel) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await appModel.restoreCredentialInheritance(scope: scope)
            validationMessage = nil
            return true
        } catch {
            validationMessage = "无法恢复继承设置，请重试。"
            return false
        }
    }

    func cancel() {
        password.removeAll(keepingCapacity: false)
    }
}

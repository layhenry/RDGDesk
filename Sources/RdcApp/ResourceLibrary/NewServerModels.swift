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
        let validationName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? ServerPropertiesDraft(
            displayName: validationName.isEmpty ? "Server" : validationName,
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

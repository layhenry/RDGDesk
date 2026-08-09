import Combine
import Foundation
import RdcCore

enum NewServerDestination: Equatable, Sendable {
    case localLibrary(name: String)
    case group(id: String, name: String)

    var name: String {
        switch self {
        case let .localLibrary(name), let .group(_, name): name
        }
    }
}

struct NewServerRequest: Identifiable, Equatable {
    let destination: NewServerDestination
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
            name = (try? ServerEndpointInputParser.resolve(
                address: value,
                portText: portText
            ).host) ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

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

    var nameError: String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "名称不能为空。" : nil
    }

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

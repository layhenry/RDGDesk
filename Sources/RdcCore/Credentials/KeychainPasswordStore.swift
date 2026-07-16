import CoreFoundation
import Foundation
import Security

public protocol PasswordStore: Sendable {
    func save(password: String, credentialID: String) async throws
    func password(credentialID: String) async throws -> String?
    func delete(credentialID: String) async throws
}

protocol KeychainClient: Sendable {
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>
    ) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct SystemKeychainClient: KeychainClient {
    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>
    ) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}

public actor MacOSKeychainPasswordStore: PasswordStore {
    public static let service = "com.rdc.credentials"

    private let client: any KeychainClient

    public init() {
        client = SystemKeychainClient()
    }

    init(client: any KeychainClient) {
        self.client = client
    }

    public func save(password: String, credentialID: String) async throws {
        var attributes = itemQuery(credentialID: credentialID)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = Data(password.utf8)

        let status = client.add(attributes as CFDictionary)
        guard status == errSecDuplicateItem else {
            try check(status)
            return
        }

        let updatedAttributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        try check(client.update(
            itemQuery(credentialID: credentialID) as CFDictionary,
            attributes: updatedAttributes as CFDictionary
        ))
    }

    public func password(credentialID: String) async throws -> String? {
        var query = itemQuery(credentialID: credentialID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = client.copyMatching(query as CFDictionary, result: &result)
        guard status != errSecItemNotFound else {
            return nil
        }
        try check(status)

        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return password
    }

    public func delete(credentialID: String) async throws {
        let status = client.delete(itemQuery(credentialID: credentialID) as CFDictionary)
        guard status != errSecItemNotFound else {
            return
        }
        try check(status)
    }

    private func itemQuery(credentialID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: credentialID
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }
}

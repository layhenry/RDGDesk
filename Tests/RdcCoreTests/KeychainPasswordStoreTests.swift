import CoreFoundation
import Foundation
import Security
import XCTest
@testable import RdcCore

final class KeychainPasswordStoreTests: XCTestCase {
    func testPasswordStoreAddsDeviceOnlyGenericPasswordItem() async throws {
        let client = RecordingKeychainClient()
        let store = MacOSKeychainPasswordStore(client: client)

        try await store.save(password: "new-secret", credentialID: "global-1")

        let attributes = try XCTUnwrap(client.addedAttributes)
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, "com.rdc.credentials")
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "global-1")
        XCTAssertNil(attributes[kSecUseDataProtectionKeychain as String])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        assertSensitiveEqual(
            attributes[kSecValueData as String] as? Data,
            Data("new-secret".utf8)
        )
    }

    func testPasswordStoreUpdatesExistingGenericPasswordItem() async throws {
        let client = RecordingKeychainClient(addStatus: errSecDuplicateItem)
        let store = MacOSKeychainPasswordStore(client: client)

        try await store.save(password: "new-secret", credentialID: "global-1")

        XCTAssertEqual(client.updateCallCount, 1)
        XCTAssertEqual(client.updatedQuery?[kSecAttrAccount as String] as? String, "global-1")
        XCTAssertEqual(client.updatedQuery?[kSecAttrService as String] as? String, "com.rdc.credentials")
        XCTAssertNil(client.updatedQuery?[kSecUseDataProtectionKeychain as String])
        assertSensitiveEqual(
            client.updatedAttributes?[kSecValueData as String] as? Data,
            Data("new-secret".utf8)
        )
        XCTAssertEqual(
            client.updatedAttributes?[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }

    func testPasswordStoreReadsPasswordData() async throws {
        let client = RecordingKeychainClient(copyStatus: errSecSuccess, copiedData: Data("stored".utf8))
        let store = MacOSKeychainPasswordStore(client: client)

        let password = try await store.password(credentialID: "global-1")

        assertSensitiveEqual(password, "stored")
        XCTAssertNil(client.copiedQuery?[kSecUseDataProtectionKeychain as String])
        XCTAssertEqual(client.copiedQuery?[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(client.copiedQuery?[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }

    func testPasswordStoreReturnsNilWhenItemIsMissing() async throws {
        let client = RecordingKeychainClient(copyStatus: errSecItemNotFound)
        let store = MacOSKeychainPasswordStore(client: client)

        let password = try await store.password(credentialID: "missing")

        assertSensitiveNil(password)
    }

    func testPasswordStoreDeletesGenericPasswordItem() async throws {
        let client = RecordingKeychainClient()
        let store = MacOSKeychainPasswordStore(client: client)

        try await store.delete(credentialID: "global-1")

        XCTAssertEqual(client.deletedQuery?[kSecAttrAccount as String] as? String, "global-1")
        XCTAssertEqual(client.deletedQuery?[kSecAttrService as String] as? String, "com.rdc.credentials")
        XCTAssertNil(client.deletedQuery?[kSecUseDataProtectionKeychain as String])
    }

    func testPasswordStoreTreatsMissingDeleteAsSuccess() async throws {
        let client = RecordingKeychainClient(deleteStatus: errSecItemNotFound)
        let store = MacOSKeychainPasswordStore(client: client)

        try await store.delete(credentialID: "missing")

        XCTAssertEqual(client.deleteCallCount, 1)
    }

    func testPasswordStoreMapsFailureWithoutSecretData() async {
        let client = RecordingKeychainClient(addStatus: errSecAuthFailed)
        let store = MacOSKeychainPasswordStore(client: client)

        do {
            try await store.save(password: "must-not-leak", credentialID: "global-1")
            XCTFail("Expected Keychain failure")
        } catch {
            XCTAssertEqual(error as? KeychainError, KeychainError(status: errSecAuthFailed))
            XCTAssertFalse(String(describing: error).contains("must-not-leak"))
        }
    }

    func testPasswordStoreMapsUpdateFailureToStatusOnlyError() async {
        let client = RecordingKeychainClient(
            addStatus: errSecDuplicateItem,
            updateStatus: errSecAuthFailed
        )
        let store = MacOSKeychainPasswordStore(client: client)

        do {
            try await store.save(password: "update-value", credentialID: "global-1")
            XCTFail("Expected Keychain update failure")
        } catch {
            XCTAssertEqual(error as? KeychainError, KeychainError(status: errSecAuthFailed))
        }
    }

    func testPasswordStoreMapsReadFailureToStatusOnlyError() async {
        let client = RecordingKeychainClient(copyStatus: errSecAuthFailed)
        let store = MacOSKeychainPasswordStore(client: client)

        do {
            _ = try await store.password(credentialID: "global-1")
            XCTFail("Expected Keychain read failure")
        } catch {
            XCTAssertEqual(error as? KeychainError, KeychainError(status: errSecAuthFailed))
        }
    }

    func testPasswordStoreMapsDeleteFailureToStatusOnlyError() async {
        let client = RecordingKeychainClient(deleteStatus: errSecAuthFailed)
        let store = MacOSKeychainPasswordStore(client: client)

        do {
            try await store.delete(credentialID: "global-1")
            XCTFail("Expected Keychain delete failure")
        } catch {
            XCTAssertEqual(error as? KeychainError, KeychainError(status: errSecAuthFailed))
        }
    }

    func testPasswordStoreRejectsSuccessfulNonDataResult() async {
        let client = RecordingKeychainClient(
            copyStatus: errSecSuccess,
            copiedResult: kCFBooleanTrue
        )
        let store = MacOSKeychainPasswordStore(client: client)

        do {
            _ = try await store.password(credentialID: "global-1")
            XCTFail("Expected invalid Keychain result")
        } catch {
            XCTAssertEqual(error as? KeychainError, KeychainError(status: errSecDecode))
        }
    }

    func testPasswordStoreRejectsInvalidUTF8Data() async {
        let client = RecordingKeychainClient(
            copyStatus: errSecSuccess,
            copiedResult: Data([0xFF]) as CFData
        )
        let store = MacOSKeychainPasswordStore(client: client)

        do {
            _ = try await store.password(credentialID: "global-1")
            XCTFail("Expected invalid Keychain text encoding")
        } catch {
            XCTAssertEqual(error as? KeychainError, KeychainError(status: errSecDecode))
        }
    }

    func testKeychainQueriesContainOnlyIdentifierMetadata() async throws {
        let client = RecordingKeychainClient(copyStatus: errSecItemNotFound)
        let store = MacOSKeychainPasswordStore(client: client)

        try await store.save(password: "secret", credentialID: "global-1")
        _ = try await store.password(credentialID: "global-1")
        try await store.delete(credentialID: "global-1")

        for dictionary in client.recordedDictionaries {
            let description = String(describing: dictionary).lowercased()
            XCTAssertFalse(description.contains("administrator"))
            XCTAssertFalse(description.contains("example-domain"))
            XCTAssertFalse(description.contains("log"))
            XCTAssertNil(dictionary[kSecAttrLabel as String])
            XCTAssertNil(dictionary[kSecAttrDescription as String])
            XCTAssertNil(dictionary[kSecAttrComment as String])
        }
    }
}

private final class RecordingKeychainClient: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private let addStatus: OSStatus
    private let updateStatus: OSStatus
    private let copyStatus: OSStatus
    private let deleteStatus: OSStatus
    private let copiedResult: CFTypeRef?

    private(set) var addedAttributes: [String: Any]?
    private(set) var updatedQuery: [String: Any]?
    private(set) var updatedAttributes: [String: Any]?
    private(set) var copiedQuery: [String: Any]?
    private(set) var deletedQuery: [String: Any]?
    private(set) var updateCallCount = 0
    private(set) var deleteCallCount = 0

    init(
        addStatus: OSStatus = errSecSuccess,
        updateStatus: OSStatus = errSecSuccess,
        copyStatus: OSStatus = errSecSuccess,
        deleteStatus: OSStatus = errSecSuccess,
        copiedData: Data? = nil,
        copiedResult: CFTypeRef? = nil
    ) {
        self.addStatus = addStatus
        self.updateStatus = updateStatus
        self.copyStatus = copyStatus
        self.deleteStatus = deleteStatus
        if let copiedResult {
            self.copiedResult = copiedResult
        } else if let copiedData {
            self.copiedResult = copiedData as CFData
        } else {
            self.copiedResult = nil
        }
    }

    var recordedDictionaries: [[String: Any]] {
        lock.withLock {
            [addedAttributes, updatedQuery, updatedAttributes, copiedQuery, deletedQuery].compactMap { $0 }
        }
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        lock.withLock { addedAttributes = Self.dictionary(attributes) }
        return addStatus
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            updateCallCount += 1
            updatedQuery = Self.dictionary(query)
            updatedAttributes = Self.dictionary(attributes)
        }
        return updateStatus
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>
    ) -> OSStatus {
        lock.withLock { copiedQuery = Self.dictionary(query) }
        if copyStatus == errSecSuccess, let copiedResult {
            result.pointee = copiedResult
        }
        return copyStatus
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.withLock {
            deleteCallCount += 1
            deletedQuery = Self.dictionary(query)
        }
        return deleteStatus
    }

    private static func dictionary(_ dictionary: CFDictionary) -> [String: Any] {
        dictionary as NSDictionary as? [String: Any] ?? [:]
    }
}

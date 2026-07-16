import Foundation
import Security
import XCTest
@testable import RdcCore

final class KeychainIntegrationTests: XCTestCase {
    func testRealKeychainSaveReadUpdateDelete() async throws {
        guard ProcessInfo.processInfo.environment["RDC_TEST_KEYCHAIN"] == "1" else {
            throw XCTSkip("Real Keychain integration is disabled")
        }
        let credentialID = "integration-\(UUID().uuidString)"
        let firstPassword = UUID().uuidString
        let updatedPassword = UUID().uuidString
        let store = MacOSKeychainPasswordStore()
        let cleanup = KeychainIntegrationCleanup(credentialID: credentialID)
        defer { cleanup.deleteIfPresent() }

        do {
            try await store.save(password: firstPassword, credentialID: credentialID)
            let firstRead = try await store.password(credentialID: credentialID)
            assertSensitiveEqual(firstRead, firstPassword)
            try await store.save(password: updatedPassword, credentialID: credentialID)
            let updatedRead = try await store.password(credentialID: credentialID)
            assertSensitiveEqual(updatedRead, updatedPassword)
            try await store.delete(credentialID: credentialID)
            let deletedRead = try await store.password(credentialID: credentialID)
            assertSensitiveNil(deletedRead)
        } catch let error as KeychainError {
            XCTFail("Real Keychain integration workflow failed (OSStatus: \(error.status))")
        } catch {
            XCTFail("Real Keychain integration workflow failed")
        }
    }
}

private struct KeychainIntegrationCleanup {
    let credentialID: String

    func deleteIfPresent() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MacOSKeychainPasswordStore.service,
            kSecAttrAccount as String: credentialID,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

private func assertSensitiveEqual(
    _ actual: @autoclosure () throws -> String?,
    _ expected: @autoclosure () throws -> String,
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    guard try actual() == expected() else {
        XCTFail("Keychain value did not match", file: file, line: line)
        return
    }
}

private func assertSensitiveNil(
    _ actual: @autoclosure () throws -> String?,
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    guard try actual() == nil else {
        XCTFail("Keychain item was not absent", file: file, line: line)
        return
    }
}

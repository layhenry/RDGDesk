import XCTest
@testable import RdcCore

final class CredentialVaultTests: XCTestCase {
    func testVaultSavesPasswordBeforePublishingNormalizedMetadata() async throws {
        let passwordStore = InMemoryPasswordStore()
        let configurationStore = VaultConfigurationStore()
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: configurationStore)
        )

        let metadata = try await vault.saveCredential(
            id: "global-1",
            username: "  Administrator  ",
            domain: "   ",
            password: "secret"
        )

        XCTAssertEqual(
            metadata,
            CredentialMetadata(id: "global-1", username: "Administrator", domain: nil)
        )
        let savedPassword = await passwordStore.passwordValue(for: "global-1")
        let savedConfiguration = try await configurationStore.load()
        assertSensitiveEqual(savedPassword, "secret")
        XCTAssertEqual(savedConfiguration.credentialMetadata["global-1"], metadata)
    }

    func testVaultUpdatesExistingCredential() async throws {
        let original = CredentialMetadata(id: "global-1", username: "old-user", domain: nil)
        let passwordStore = InMemoryPasswordStore(passwords: ["global-1": "old-secret"])
        let configurationStore = VaultConfigurationStore(
            configuration: RdcAppConfiguration(credentialMetadata: ["global-1": original])
        )
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: configurationStore)
        )

        let metadata = try await vault.saveCredential(
            id: "global-1",
            username: "new-user",
            domain: "CORP",
            password: "new-secret"
        )

        XCTAssertEqual(metadata.username, "new-user")
        XCTAssertEqual(metadata.domain, "CORP")
        let savedPassword = await passwordStore.passwordValue(for: "global-1")
        assertSensitiveEqual(savedPassword, "new-secret")
    }

    func testVaultDeletesNewPasswordWhenConfigurationSaveFails() async throws {
        let passwordStore = InMemoryPasswordStore()
        let configurationStore = VaultConfigurationStore(failSaves: true)
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: configurationStore)
        )

        do {
            _ = try await vault.saveCredential(
                id: "global-1", username: "Administrator", domain: nil, password: "secret"
            )
            XCTFail("Expected configuration save failure")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .configurationSaveFailed)
        }

        let savedPassword = await passwordStore.passwordValue(for: "global-1")
        let operations = await passwordStore.operations
        assertSensitiveNil(savedPassword)
        XCTAssertEqual(operations, [.read("global-1"), .save("global-1"), .delete("global-1")])
    }

    func testVaultRestoresPreviousPasswordWhenCredentialUpdateCannotBePublished() async throws {
        let original = CredentialMetadata(id: "global-1", username: "old-user", domain: nil)
        let passwordStore = InMemoryPasswordStore(passwords: ["global-1": "old-secret"])
        let configurationStore = VaultConfigurationStore(
            configuration: RdcAppConfiguration(credentialMetadata: ["global-1": original]),
            failSaves: true
        )
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: configurationStore)
        )

        do {
            _ = try await vault.saveCredential(
                id: "global-1", username: "new-user", domain: nil, password: "new-secret"
            )
            XCTFail("Expected configuration save failure")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .configurationSaveFailed)
        }

        let savedPassword = await passwordStore.passwordValue(for: "global-1")
        let operations = await passwordStore.operations
        assertSensitiveEqual(savedPassword, "old-secret")
        XCTAssertEqual(operations, [.read("global-1"), .save("global-1"), .save("global-1")])
    }

    func testVaultReportsPasswordStoreFailureWhenRollbackFails() async throws {
        let passwordStore = InMemoryPasswordStore(failDelete: true)
        let configurationStore = VaultConfigurationStore(failSaves: true)
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: configurationStore)
        )

        do {
            _ = try await vault.saveCredential(
                id: "global-1", username: "user", domain: nil, password: "value"
            )
            XCTFail("Expected rollback failure")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .passwordStoreFailed)
        }
    }

    func testVaultDoesNotPublishMetadataWhenKeychainSaveFails() async throws {
        let passwordStore = InMemoryPasswordStore(failSave: true)
        let configurationStore = VaultConfigurationStore()
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: configurationStore)
        )

        do {
            _ = try await vault.saveCredential(
                id: "global-1", username: "Administrator", domain: nil, password: "secret"
            )
            XCTFail("Expected Keychain save failure")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .passwordStoreFailed)
        }

        let savedConfiguration = try await configurationStore.load()
        XCTAssertNil(savedConfiguration.credentialMetadata["global-1"])
    }

    func testVaultRefusesToDeleteReferencedCredentialWithoutTouchingStores() async throws {
        let metadata = CredentialMetadata(id: "global-1", username: "user", domain: nil)
        let passwordStore = InMemoryPasswordStore(passwords: ["global-1": "secret"])
        let configurationStore = VaultConfigurationStore(
            configuration: RdcAppConfiguration(credentialMetadata: ["global-1": metadata])
        )
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: configurationStore)
        )

        do {
            try await vault.deleteCredential(id: "global-1", referencedBy: 2)
            XCTFail("Expected referenced credential rejection")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .stillReferenced(2))
        }

        let operations = await passwordStore.operations
        let savedConfiguration = try await configurationStore.load()
        XCTAssertEqual(operations, [])
        XCTAssertEqual(savedConfiguration.credentialMetadata["global-1"], metadata)
    }

    func testVaultDeletesUnreferencedCredentialFromBothStores() async throws {
        let metadata = CredentialMetadata(id: "global-1", username: "user", domain: nil)
        let passwordStore = InMemoryPasswordStore(passwords: ["global-1": "secret"])
        let configurationStore = VaultConfigurationStore(
            configuration: RdcAppConfiguration(credentialMetadata: ["global-1": metadata])
        )
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: configurationStore)
        )

        try await vault.deleteCredential(id: "global-1", referencedBy: 0)

        let savedPassword = await passwordStore.passwordValue(for: "global-1")
        let savedConfiguration = try await configurationStore.load()
        assertSensitiveNil(savedPassword)
        XCTAssertNil(savedConfiguration.credentialMetadata["global-1"])
    }

    func testVaultRestoresPasswordWhenCredentialDeleteCannotBePublished() async throws {
        let metadata = CredentialMetadata(id: "global-1", username: "user", domain: nil)
        let passwordStore = InMemoryPasswordStore(passwords: ["global-1": "old-secret"])
        let configurationStore = VaultConfigurationStore(
            configuration: RdcAppConfiguration(credentialMetadata: ["global-1": metadata]),
            failSaves: true
        )
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: configurationStore)
        )

        do {
            try await vault.deleteCredential(id: "global-1", referencedBy: 0)
            XCTFail("Expected configuration save failure")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .configurationSaveFailed)
        }

        let savedPassword = await passwordStore.passwordValue(for: "global-1")
        assertSensitiveEqual(savedPassword, "old-secret")
    }

    func testVaultLoadsMetadataAndPasswordAsConnectionCredential() async throws {
        let metadata = CredentialMetadata(id: "global-1", username: "user", domain: "CORP")
        let passwordStore = InMemoryPasswordStore(passwords: ["global-1": "secret"])
        let configurationStore = VaultConfigurationStore(
            configuration: RdcAppConfiguration(credentialMetadata: ["global-1": metadata])
        )
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: configurationStore)
        )

        let resolved = try await vault.loadCredential(id: "global-1")

        XCTAssertEqual(resolved?.metadata, metadata)
        assertSensitiveEqual(
            resolved?.connectionCredential,
            RdpConnectionCredential(username: "user", domain: "CORP", password: "secret")
        )
    }

    func testVaultRejectsBlankUsernameAndPasswordBeforePasswordStoreAccess() async throws {
        let passwordStore = InMemoryPasswordStore()
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: VaultConfigurationStore())
        )

        do {
            _ = try await vault.saveCredential(
                id: "one", username: "  ", domain: nil, password: "secret"
            )
            XCTFail("Expected invalid username")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .invalidUsername)
        }
        do {
            _ = try await vault.saveCredential(
                id: "two", username: "user", domain: nil, password: "\n\t"
            )
            XCTFail("Expected empty password")
        } catch {
            XCTAssertEqual(error as? CredentialVaultError, .emptyPassword)
        }

        let operations = await passwordStore.operations
        XCTAssertEqual(operations, [])
    }

    func testVaultSerializesTransactionsAcrossPasswordStoreSuspension() async throws {
        let passwordStore = BlockingFirstSavePasswordStore()
        let operationProbe = VaultOperationProbe()
        let vault = CredentialVault(
            passwordStore: passwordStore,
            configurationRepository: RdcConfigurationRepository(store: VaultConfigurationStore()),
            operationObserver: operationProbe.observe
        )

        let first = Task {
            try await vault.saveCredential(
                id: "global-1", username: "first", domain: nil, password: "first-value"
            )
        }
        await passwordStore.waitUntilFirstSaveStarted()

        let second = Task {
            try await vault.saveCredential(
                id: "global-1", username: "second", domain: nil, password: "second-value"
            )
        }
        await operationProbe.waitUntilQueued()

        let saveCallCountWhileFirstIsSuspended = await passwordStore.saveCallCount
        XCTAssertEqual(saveCallCountWhileFirstIsSuspended, 1)

        await passwordStore.releaseFirstSave()
        _ = try await first.value
        _ = try await second.value
    }
}

private enum PasswordStoreOperation: Equatable, Sendable {
    case read(String)
    case save(String)
    case delete(String)
}

private enum VaultTestError: Error {
    case passwordStore
    case configurationStore
}

private actor InMemoryPasswordStore: PasswordStore {
    private var passwords: [String: String]
    private let failSave: Bool
    private let failDelete: Bool
    private(set) var operations: [PasswordStoreOperation] = []

    init(
        passwords: [String: String] = [:],
        failSave: Bool = false,
        failDelete: Bool = false
    ) {
        self.passwords = passwords
        self.failSave = failSave
        self.failDelete = failDelete
    }

    func save(password: String, credentialID: String) async throws {
        operations.append(.save(credentialID))
        guard !failSave else { throw VaultTestError.passwordStore }
        passwords[credentialID] = password
    }

    func password(credentialID: String) async throws -> String? {
        operations.append(.read(credentialID))
        return passwords[credentialID]
    }

    func delete(credentialID: String) async throws {
        operations.append(.delete(credentialID))
        guard !failDelete else { throw VaultTestError.passwordStore }
        passwords.removeValue(forKey: credentialID)
    }

    func passwordValue(for credentialID: String) -> String? {
        passwords[credentialID]
    }
}

private actor VaultConfigurationStore: RdcConfigurationStore {
    private var configuration: RdcAppConfiguration
    private let failSaves: Bool

    init(configuration: RdcAppConfiguration = .default, failSaves: Bool = false) {
        self.configuration = configuration
        self.failSaves = failSaves
    }

    func load() async throws -> RdcAppConfiguration {
        configuration
    }

    func save(_ configuration: RdcAppConfiguration) async throws {
        guard !failSaves else { throw VaultTestError.configurationStore }
        self.configuration = configuration
    }
}

private actor BlockingFirstSavePasswordStore: PasswordStore {
    private var passwords: [String: String] = [:]
    private var firstSaveStarted = false
    private var firstSaveStartWaiter: CheckedContinuation<Void, Never>?
    private var firstSaveRelease: CheckedContinuation<Void, Never>?
    private(set) var saveCallCount = 0

    func save(password: String, credentialID: String) async throws {
        saveCallCount += 1
        if saveCallCount == 1 {
            firstSaveStarted = true
            firstSaveStartWaiter?.resume()
            firstSaveStartWaiter = nil
            await withCheckedContinuation { continuation in
                firstSaveRelease = continuation
            }
        }
        passwords[credentialID] = password
    }

    func password(credentialID: String) async throws -> String? {
        passwords[credentialID]
    }

    func delete(credentialID: String) async throws {
        passwords.removeValue(forKey: credentialID)
    }

    func waitUntilFirstSaveStarted() async {
        guard !firstSaveStarted else { return }
        await withCheckedContinuation { continuation in
            firstSaveStartWaiter = continuation
        }
    }

    func releaseFirstSave() {
        firstSaveRelease?.resume()
        firstSaveRelease = nil
    }
}

private final class VaultOperationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = false
    private var waiter: CheckedContinuation<Void, Never>?

    func observe(_ event: CredentialVaultOperationEvent) {
        guard event == .queued else { return }
        lock.withLock {
            queued = true
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilQueued() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if queued {
                    continuation.resume()
                } else {
                    waiter = continuation
                }
            }
        }
    }
}

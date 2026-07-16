import Foundation

enum CredentialVaultOperationEvent: Equatable, Sendable {
    case queued
}

public struct ResolvedCredential: Equatable, Sendable {
    public let metadata: CredentialMetadata
    public let connectionCredential: RdpConnectionCredential

    public init(
        metadata: CredentialMetadata,
        connectionCredential: RdpConnectionCredential
    ) {
        self.metadata = metadata
        self.connectionCredential = connectionCredential
    }
}

public enum CredentialVaultError: Error, Equatable, Sendable {
    case invalidUsername
    case emptyPassword
    case passwordStoreFailed
    case configurationSaveFailed
    case stillReferenced(Int)
}

public actor CredentialVault {
    private let passwordStore: any PasswordStore
    private let configurationRepository: RdcConfigurationRepository
    private let operationObserver: @Sendable (CredentialVaultOperationEvent) -> Void
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        passwordStore: any PasswordStore,
        configurationRepository: RdcConfigurationRepository
    ) {
        self.passwordStore = passwordStore
        self.configurationRepository = configurationRepository
        operationObserver = { _ in }
    }

    init(
        passwordStore: any PasswordStore,
        configurationRepository: RdcConfigurationRepository,
        operationObserver: @escaping @Sendable (CredentialVaultOperationEvent) -> Void
    ) {
        self.passwordStore = passwordStore
        self.configurationRepository = configurationRepository
        self.operationObserver = operationObserver
    }

    public func saveCredential(
        id: String = UUID().uuidString,
        username: String,
        domain: String?,
        password: String
    ) async throws -> CredentialMetadata {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }

        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty else {
            throw CredentialVaultError.invalidUsername
        }
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CredentialVaultError.emptyPassword
        }

        let normalizedDomain = domain?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let metadata = CredentialMetadata(
            id: id,
            username: normalizedUsername,
            domain: normalizedDomain
        )

        let previousPassword: String?
        do {
            previousPassword = try await passwordStore.password(credentialID: id)
            try await passwordStore.save(password: password, credentialID: id)
        } catch {
            throw CredentialVaultError.passwordStoreFailed
        }

        do {
            try await configurationRepository.update { configuration in
                configuration.credentialMetadata[id] = metadata
            }
        } catch {
            do {
                try await rollBackPassword(
                    credentialID: id,
                    previousPassword: previousPassword
                )
            } catch {
                throw CredentialVaultError.passwordStoreFailed
            }
            throw CredentialVaultError.configurationSaveFailed
        }

        return metadata
    }

    public func loadCredential(id: String) async throws -> ResolvedCredential? {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }

        let configuration: RdcAppConfiguration
        do {
            configuration = try await configurationRepository.snapshot()
        } catch {
            throw CredentialVaultError.configurationSaveFailed
        }

        guard let metadata = configuration.credentialMetadata[id] else {
            return nil
        }

        let password: String?
        do {
            password = try await passwordStore.password(credentialID: id)
        } catch {
            throw CredentialVaultError.passwordStoreFailed
        }
        guard let password else {
            return nil
        }

        return ResolvedCredential(
            metadata: metadata,
            connectionCredential: RdpConnectionCredential(
                username: metadata.username,
                domain: metadata.domain,
                password: password
            )
        )
    }

    public func deleteCredential(id: String, referencedBy count: Int) async throws {
        await acquireOperationPermit()
        defer { releaseOperationPermit() }

        guard count <= 0 else {
            throw CredentialVaultError.stillReferenced(count)
        }

        let previousPassword: String?
        do {
            previousPassword = try await passwordStore.password(credentialID: id)
            try await passwordStore.delete(credentialID: id)
        } catch {
            throw CredentialVaultError.passwordStoreFailed
        }

        do {
            try await configurationRepository.update { configuration in
                configuration.credentialMetadata.removeValue(forKey: id)
            }
        } catch {
            if let previousPassword {
                do {
                    try await passwordStore.save(password: previousPassword, credentialID: id)
                } catch {
                    throw CredentialVaultError.passwordStoreFailed
                }
            }
            throw CredentialVaultError.configurationSaveFailed
        }
    }

    private func rollBackPassword(
        credentialID: String,
        previousPassword: String?
    ) async throws {
        if let previousPassword {
            try await passwordStore.save(
                password: previousPassword,
                credentialID: credentialID
            )
        } else {
            try await passwordStore.delete(credentialID: credentialID)
        }
    }

    private func acquireOperationPermit() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }

        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
            operationObserver(.queued)
        }
    }

    private func releaseOperationPermit() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }

        operationWaiters.removeFirst().resume()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

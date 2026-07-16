public struct ServerCredential: Equatable, Sendable {
    public let username: String?
    public let domain: String?
    public let secret: CredentialSecret

    public init(username: String?, domain: String?, secret: CredentialSecret) {
        self.username = username
        self.domain = domain
        self.secret = secret
    }
}

public enum CredentialSecret: Equatable, Sendable {
    case password(String)
}

public struct CredentialImportDecision: Equatable, Sendable {
    public let status: CredentialImportStatus
    public let reason: CredentialImportBlocker?
    public let attemptedDecryption: Bool

    public init(rdcPassword: RdcPassword) {
        switch rdcPassword {
        case .none:
            self.status = .requiresUserEntry
            self.reason = .missingPassword
            self.attemptedDecryption = false
        case .windowsDPAPIEncrypted:
            self.status = .requiresUserEntry
            self.reason = .windowsDPAPINotMigratableToMacOSKeychain
            self.attemptedDecryption = false
        }
    }
}

public enum CredentialImportStatus: Equatable, Sendable {
    case requiresUserEntry
}

public enum CredentialImportBlocker: Equatable, Sendable {
    case missingPassword
    case windowsDPAPINotMigratableToMacOSKeychain
}

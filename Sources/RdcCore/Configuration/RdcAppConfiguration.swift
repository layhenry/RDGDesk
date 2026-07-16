import Foundation

public struct RdcAppConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let `default` = RdcAppConfiguration()

    public var schemaVersion: Int
    public var globalCredentialID: String?
    public var groupCredentialBindings: [String: String]
    public var serverCredentialBindings: [String: String]
    public var credentialMetadata: [String: CredentialMetadata]
    public var certificatePins: [RdpEndpoint: CertificatePin]
    public var lastLibrary: RdcLibrarySnapshot?
    public var preferences: RdcGeneralPreferences

    public init(
        schemaVersion: Int = currentSchemaVersion,
        globalCredentialID: String? = nil,
        groupCredentialBindings: [String: String] = [:],
        serverCredentialBindings: [String: String] = [:],
        credentialMetadata: [String: CredentialMetadata] = [:],
        certificatePins: [RdpEndpoint: CertificatePin] = [:],
        lastLibrary: RdcLibrarySnapshot? = nil,
        preferences: RdcGeneralPreferences = .default
    ) {
        self.schemaVersion = schemaVersion
        self.globalCredentialID = globalCredentialID
        self.groupCredentialBindings = groupCredentialBindings
        self.serverCredentialBindings = serverCredentialBindings
        self.credentialMetadata = credentialMetadata
        self.certificatePins = certificatePins
        self.lastLibrary = lastLibrary
        self.preferences = preferences
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        globalCredentialID = try container.decodeIfPresent(String.self, forKey: .globalCredentialID)
        groupCredentialBindings = try container.decodeIfPresent(
            [String: String].self, forKey: .groupCredentialBindings
        ) ?? [:]
        serverCredentialBindings = try container.decodeIfPresent(
            [String: String].self, forKey: .serverCredentialBindings
        ) ?? [:]
        credentialMetadata = try container.decodeIfPresent(
            [String: CredentialMetadata].self, forKey: .credentialMetadata
        ) ?? [:]
        certificatePins = try container.decodeIfPresent(
            [RdpEndpoint: CertificatePin].self, forKey: .certificatePins
        ) ?? [:]
        lastLibrary = try container.decodeIfPresent(RdcLibrarySnapshot.self, forKey: .lastLibrary)
        preferences = try container.decodeIfPresent(
            RdcGeneralPreferences.self, forKey: .preferences
        ) ?? .default
    }
}

public struct CredentialMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var username: String
    public var domain: String?

    public init(id: String, username: String, domain: String?) {
        self.id = id
        self.username = username
        self.domain = domain
    }
}

public struct RdpEndpoint: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
    }
}

public struct CertificatePin: Codable, Equatable, Sendable {
    public let endpoint: RdpEndpoint
    public var subject: String
    public var issuer: String
    public var sha256Fingerprint: String
    public var notBefore: Date?
    public var notAfter: Date?
    public var firstTrustedAt: Date
    public var lastConfirmedAt: Date

    public init(
        endpoint: RdpEndpoint,
        subject: String,
        issuer: String,
        sha256Fingerprint: String,
        notBefore: Date?,
        notAfter: Date?,
        firstTrustedAt: Date,
        lastConfirmedAt: Date
    ) {
        self.endpoint = endpoint
        self.subject = subject
        self.issuer = issuer
        self.sha256Fingerprint = sha256Fingerprint
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.firstTrustedAt = firstTrustedAt
        self.lastConfirmedAt = lastConfirmedAt
    }
}

public struct RdcGeneralPreferences: Codable, Equatable, Sendable {
    public static let `default` = RdcGeneralPreferences()

    public var restoresLastLibrary: Bool
    public var doubleClickConnects: Bool
    public var resizesRemoteDesktopWithWindow: Bool

    public init(
        restoresLastLibrary: Bool = true,
        doubleClickConnects: Bool = true,
        resizesRemoteDesktopWithWindow: Bool = true
    ) {
        self.restoresLastLibrary = restoresLastLibrary
        self.doubleClickConnects = doubleClickConnects
        self.resizesRemoteDesktopWithWindow = resizesRemoteDesktopWithWindow
    }
}

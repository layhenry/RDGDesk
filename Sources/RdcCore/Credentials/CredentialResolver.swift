public enum CredentialSource: Equatable, Sendable {
    case server(serverID: String)
    case group(groupID: String)
    case global
}

public struct CredentialResolution: Equatable, Sendable {
    public let credentialID: String
    public let source: CredentialSource

    public init(credentialID: String, source: CredentialSource) {
        self.credentialID = credentialID
        self.source = source
    }
}

public enum CredentialResolver {
    public static func resolve(
        server: RdcImportedServer,
        configuration: RdcAppConfiguration
    ) -> CredentialResolution? {
        if let credentialID = configuration.serverCredentialBindings[server.id] {
            return CredentialResolution(
                credentialID: credentialID,
                source: .server(serverID: server.id)
            )
        }

        for groupID in server.groupPathIDs.reversed() {
            if let credentialID = configuration.groupCredentialBindings[groupID] {
                return CredentialResolution(
                    credentialID: credentialID,
                    source: .group(groupID: groupID)
                )
            }
        }

        return configuration.globalCredentialID.map {
            CredentialResolution(credentialID: $0, source: .global)
        }
    }

    public static func resolve(
        server: RdcImportedServer,
        configuration: RdcAppConfiguration,
        vault: CredentialVault
    ) async throws -> ResolvedCredential? {
        guard let resolution = resolve(server: server, configuration: configuration) else {
            return nil
        }
        return try await vault.loadCredential(id: resolution.credentialID)
    }
}

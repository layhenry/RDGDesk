import Foundation
import XCTest
@testable import RdcCore

final class CredentialResolverTests: XCTestCase {
    func testServerBindingOverridesEveryInheritedScope() {
        var configuration = RdcAppConfiguration(globalCredentialID: "global-id")
        configuration.groupCredentialBindings = [
            "parent": "parent-id",
            "child": "child-id"
        ]
        configuration.serverCredentialBindings = ["server": "server-id"]

        XCTAssertEqual(
            CredentialResolver.resolve(
                server: importedServer(id: "server", groupPathIDs: ["parent", "child"]),
                configuration: configuration
            ),
            CredentialResolution(
                credentialID: "server-id",
                source: .server(serverID: "server")
            )
        )
    }

    func testNearestNestedGroupOverridesParentAndGlobalScopes() {
        var configuration = RdcAppConfiguration(globalCredentialID: "global-id")
        configuration.groupCredentialBindings = [
            "parent": "parent-id",
            "child": "child-id"
        ]

        XCTAssertEqual(
            CredentialResolver.resolve(
                server: importedServer(id: "server", groupPathIDs: ["parent", "child"]),
                configuration: configuration
            ),
            CredentialResolution(
                credentialID: "child-id",
                source: .group(groupID: "child")
            )
        )
    }

    func testParentGroupIsUsedWhenNestedGroupHasNoBinding() {
        var configuration = RdcAppConfiguration(globalCredentialID: "global-id")
        configuration.groupCredentialBindings = ["parent": "parent-id"]

        XCTAssertEqual(
            CredentialResolver.resolve(
                server: importedServer(id: "server", groupPathIDs: ["parent", "child"]),
                configuration: configuration
            ),
            CredentialResolution(
                credentialID: "parent-id",
                source: .group(groupID: "parent")
            )
        )
    }

    func testGlobalBindingIsUsedWhenServerAndGroupsHaveNoBindings() {
        let configuration = RdcAppConfiguration(globalCredentialID: "global-id")

        XCTAssertEqual(
            CredentialResolver.resolve(
                server: importedServer(id: "server", groupPathIDs: ["parent", "child"]),
                configuration: configuration
            ),
            CredentialResolution(credentialID: "global-id", source: .global)
        )
    }

    func testMissingBindingsReturnNilForOneTimePromptFallback() {
        XCTAssertNil(
            CredentialResolver.resolve(
                server: importedServer(id: "server", groupPathIDs: ["parent", "child"]),
                configuration: .default
            )
        )
    }

    func testSanitizedSnapshotReimportPreservesCredentialBindingResolution() throws {
        let document = try fixtureDocument()
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-1",
            sourceName: "temp2.rdg",
            document: document
        )
        let initialLibrary = RdcImportedLibrary(
            document: document,
            sourceID: snapshot.sourceID,
            sourceName: snapshot.sourceName
        )
        let initiallyBoundServer = try XCTUnwrap(initialLibrary.servers.first)
        var configuration = RdcAppConfiguration()
        configuration.serverCredentialBindings[initiallyBoundServer.id] = "credential-id"

        let encoded = try JSONEncoder().encode(snapshot)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains("AQAAANCM"))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("password"))
        let restoredDocument = snapshot.makeDocument()
        assertSensitiveNil(restoredDocument.root.logonCredentials)
        assertSensitiveNil(restoredDocument.root.groups.first?.logonCredentials)
        assertSensitiveNil(restoredDocument.root.groups.first?.groups.first?.servers.first?.logonCredentials)

        let restoredLibrary = RdcImportedLibrary(
            document: restoredDocument,
            sourceID: snapshot.sourceID,
            sourceName: snapshot.sourceName
        )
        let restoredServer = try XCTUnwrap(restoredLibrary.servers.first)
        XCTAssertEqual(restoredServer.id, initiallyBoundServer.id)
        XCTAssertEqual(
            CredentialResolver.resolve(server: restoredServer, configuration: configuration),
            CredentialResolution(
                credentialID: "credential-id",
                source: .server(serverID: restoredServer.id)
            )
        )
    }

    func testMissingClosestMetadataPromptsWithoutFallingBackToValidInheritedScopes() async throws {
        try await assertMissingClosestCredentialReturnsNil(
            serverCredentialID: "missing-server-metadata",
            childCredentialID: nil,
            metadata: [:],
            passwords: [:]
        )
        try await assertMissingClosestCredentialReturnsNil(
            serverCredentialID: nil,
            childCredentialID: "missing-group-metadata",
            metadata: [:],
            passwords: [:]
        )
    }

    func testMissingClosestKeychainPasswordPromptsWithoutFallingBackToInheritedScopes() async throws {
        try await assertMissingClosestCredentialReturnsNil(
            serverCredentialID: "server-id",
            childCredentialID: nil,
            metadata: [
                "server-id": CredentialMetadata(
                    id: "server-id", username: "server-user", domain: nil
                )
            ],
            passwords: [:]
        )
        try await assertMissingClosestCredentialReturnsNil(
            serverCredentialID: nil,
            childCredentialID: "child-id",
            metadata: [
                "child-id": CredentialMetadata(
                    id: "child-id", username: "child-user", domain: nil
                )
            ],
            passwords: [:]
        )
    }

    func testNearestCompleteCredentialLoadsWithoutConsultingFallbackScopes() async throws {
        let server = importedServer(id: "server", groupPathIDs: ["parent", "child"])
        var configuration = fallbackConfiguration()
        configuration.groupCredentialBindings["child"] = "child-id"
        configuration.credentialMetadata["child-id"] = CredentialMetadata(
            id: "child-id", username: "child-user", domain: "CHILD"
        )
        let vault = resolverVault(
            configuration: configuration,
            passwords: [
                "child-id": "child-value",
                "parent-id": "parent-value",
                "global-id": "global-value"
            ]
        )

        let resolved = try await CredentialResolver.resolve(
            server: server,
            configuration: configuration,
            vault: vault
        )

        XCTAssertEqual(resolved?.metadata.id, "child-id")
        assertSensitiveEqual(resolved?.connectionCredential.password, "child-value")
    }

    private func importedServer(id: String, groupPathIDs: [String]) -> RdcImportedServer {
        RdcImportedServer(
            id: id,
            displayName: "Server",
            address: RdcServerAddress("example.invalid"),
            credentials: nil,
            groupPathIDs: groupPathIDs
        )
    }

    private func fixtureDocument() throws -> RdcManDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/minimal-rdcman.rdg")
        return try RdcManParser().parse(fileAt: url)
    }

    private func fallbackConfiguration() -> RdcAppConfiguration {
        RdcAppConfiguration(
            globalCredentialID: "global-id",
            groupCredentialBindings: ["parent": "parent-id"],
            credentialMetadata: [
                "parent-id": CredentialMetadata(
                    id: "parent-id", username: "parent-user", domain: nil
                ),
                "global-id": CredentialMetadata(
                    id: "global-id", username: "global-user", domain: nil
                )
            ]
        )
    }

    private func resolverVault(
        configuration: RdcAppConfiguration,
        passwords: [String: String]
    ) -> CredentialVault {
        CredentialVault(
            passwordStore: ResolverPasswordStore(passwords: passwords),
            configurationRepository: RdcConfigurationRepository(
                store: ResolverConfigurationStore(configuration: configuration)
            )
        )
    }

    private func assertMissingClosestCredentialReturnsNil(
        serverCredentialID: String?,
        childCredentialID: String?,
        metadata: [String: CredentialMetadata],
        passwords: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let server = importedServer(id: "server", groupPathIDs: ["parent", "child"])
        var configuration = fallbackConfiguration()
        if let serverCredentialID {
            configuration.serverCredentialBindings[server.id] = serverCredentialID
        }
        if let childCredentialID {
            configuration.groupCredentialBindings["child"] = childCredentialID
        }
        configuration.credentialMetadata.merge(metadata) { _, closest in closest }
        let vault = resolverVault(
            configuration: configuration,
            passwords: passwords.merging([
                "parent-id": "parent-value",
                "global-id": "global-value"
            ]) { closest, _ in closest }
        )

        let resolved = try await CredentialResolver.resolve(
            server: server,
            configuration: configuration,
            vault: vault
        )

        XCTAssertNil(resolved, file: file, line: line)
    }
}

private actor ResolverPasswordStore: PasswordStore {
    private let passwords: [String: String]

    init(passwords: [String: String]) {
        self.passwords = passwords
    }

    func save(password: String, credentialID: String) async throws {}

    func password(credentialID: String) async throws -> String? {
        passwords[credentialID]
    }

    func delete(credentialID: String) async throws {}
}

private actor ResolverConfigurationStore: RdcConfigurationStore {
    private var configuration: RdcAppConfiguration

    init(configuration: RdcAppConfiguration) {
        self.configuration = configuration
    }

    func load() async throws -> RdcAppConfiguration {
        configuration
    }

    func save(_ configuration: RdcAppConfiguration) async throws {
        self.configuration = configuration
    }
}

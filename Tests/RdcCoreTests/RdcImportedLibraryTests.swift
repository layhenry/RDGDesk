import Foundation
import XCTest
@testable import RdcCore

final class RdcImportedLibraryTests: XCTestCase {
    func testImportedLibraryUsesPersistedIDsInsteadOfRecomputingFromEditedFields() throws {
        var snapshot = RdcLibrarySnapshot(
            sourceID: "source-editable",
            sourceName: "temp2.rdg",
            document: try fixtureDocument()
        ).normalizedStableIdentity()
        let originalID = try XCTUnwrap(snapshot.root.groups.first?.groups.first?.servers.first?.id)
        snapshot.root.groups[0].groups[0].servers[0].displayName = "Renamed"
        snapshot.root.groups[0].groups[0].servers[0].address = "198.51.100.8:3391"

        XCTAssertEqual(snapshot.makeLibrary().servers.first?.id, originalID)
    }

    func testReimportWithSameSourceIDKeepsStableGroupAndServerIDs() throws {
        let document = try fixtureDocument()
        let first = RdcImportedLibrary(
            document: document,
            sourceID: "source-1",
            sourceName: "temp2.rdg"
        )
        let second = RdcImportedLibrary(
            document: document,
            sourceID: "source-1",
            sourceName: "temp2.rdg"
        )

        XCTAssertEqual(first.sourceID, "source-1")
        XCTAssertEqual(first.groups.map(\.id), second.groups.map(\.id))
        XCTAssertEqual(first.servers.map(\.id), second.servers.map(\.id))
    }

    func testStableIDsAreSourceScopedAndChangedEndpointGetsDifferentServerIdentity() {
        XCTAssertNotEqual(
            StableLibraryID.group(sourceID: "source-1", path: ["root"]),
            StableLibraryID.group(sourceID: "source-2", path: ["root"])
        )
        XCTAssertNotEqual(
            StableLibraryID.server(
                sourceID: "source-1", path: ["root", "host"], host: "a", port: 3_389
            ),
            StableLibraryID.server(
                sourceID: "source-1", path: ["root", "host"], host: "b", port: 3_389
            )
        )
        XCTAssertNotEqual(
            StableLibraryID.server(
                sourceID: "source-1", path: ["root", "host"], host: "a", port: 3_389
            ),
            StableLibraryID.server(
                sourceID: "source-1", path: ["root", "host"], host: "a", port: 3_390
            )
        )
    }

    func testLengthPrefixedComponentsPreventPathSeparatorCollisions() {
        XCTAssertNotEqual(
            StableLibraryID.group(sourceID: "source", path: ["a/b", "c"]),
            StableLibraryID.group(sourceID: "source", path: ["a", "b/c"])
        )
    }

    func testFlattenedGroupsAndServersExposeStableAncestry() throws {
        let library = RdcImportedLibrary(
            document: try fixtureDocument(),
            sourceID: "source-1",
            sourceName: "temp2.rdg"
        )

        XCTAssertEqual(library.groups.map(\.path), [
            ["示例资源库"],
            ["示例资源库", "生产环境"],
            ["示例资源库", "生产环境", "业务服务器"]
        ])
        XCTAssertNil(library.groups[0].parentID)
        XCTAssertEqual(library.groups[1].parentID, library.groups[0].id)
        XCTAssertEqual(library.groups[2].parentID, library.groups[1].id)
        XCTAssertEqual(
            library.servers.map(\.groupPathIDs),
            [
                library.groups.map(\.id),
                library.groups.map(\.id)
            ]
        )
    }

    func testServerWithoutPortUsesRDPDefaultForStableIdentity() throws {
        let library = RdcImportedLibrary(
            document: try fixtureDocument(),
            sourceID: "source-1",
            sourceName: "temp2.rdg"
        )
        let server = try XCTUnwrap(library.servers.last)

        XCTAssertEqual(
            server.id,
            StableLibraryID.server(
                sourceID: "source-1",
                path: ["示例资源库", "生产环境", "业务服务器", "Windows Server B"],
                host: "198.51.100.57",
                port: 3_389
            )
        )
    }

    func testCompatibilityInitializerDerivesDeterministicSourceIdentity() throws {
        let document = try fixtureDocument()
        let first = RdcImportedLibrary(document: document, sourceName: "temp2.rdg")
        let second = RdcImportedLibrary(document: document, sourceName: "temp2.rdg")

        XCTAssertEqual(first.sourceID, second.sourceID)
        XCTAssertEqual(first.servers.map(\.id), second.servers.map(\.id))
    }

    func testDuplicateSiblingGroupsAndServersHaveUniqueStableIdentities() {
        let document = duplicateIdentityDocument()
        let first = RdcImportedLibrary(
            document: document,
            sourceID: "duplicate-source",
            sourceName: "duplicates.rdg"
        )
        let second = RdcImportedLibrary(
            document: document,
            sourceID: "duplicate-source",
            sourceName: "duplicates.rdg"
        )

        XCTAssertEqual(Set(first.groups.map(\.id)).count, first.groups.count)
        XCTAssertEqual(Set(first.servers.map(\.id)).count, first.servers.count)
        XCTAssertEqual(first.groups.map(\.id), second.groups.map(\.id))
        XCTAssertEqual(first.servers.map(\.id), second.servers.map(\.id))

        var configuration = RdcAppConfiguration()
        configuration.serverCredentialBindings[first.servers[0].id] = "first-id"
        configuration.serverCredentialBindings[first.servers[1].id] = "second-id"
        XCTAssertEqual(
            CredentialResolver.resolve(server: first.servers[0], configuration: configuration)?
                .credentialID,
            "first-id"
        )
        XCTAssertEqual(
            CredentialResolver.resolve(server: first.servers[1], configuration: configuration)?
                .credentialID,
            "second-id"
        )
        XCTAssertEqual(
            first.selectingServer(id: first.servers[1].id).selectedServer?.id,
            first.servers[1].id
        )
    }

    private func fixtureDocument() throws -> RdcManDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/minimal-rdcman.rdg")
        return try RdcManParser().parse(fileAt: url)
    }

    private func duplicateIdentityDocument() -> RdcManDocument {
        let duplicateServer = RdcServer(
            displayName: "Duplicate",
            address: RdcServerAddress("same.example:3389"),
            logonCredentials: nil
        )
        return RdcManDocument(
            programVersion: "2.92",
            schemaVersion: "3",
            root: RdcGroup(
                name: "Root",
                isExpanded: true,
                logonCredentials: nil,
                groups: [
                    RdcGroup(
                        name: "Same",
                        isExpanded: true,
                        logonCredentials: nil,
                        groups: [],
                        servers: [duplicateServer, duplicateServer]
                    ),
                    RdcGroup(
                        name: "Same",
                        isExpanded: true,
                        logonCredentials: nil,
                        groups: [],
                        servers: [duplicateServer]
                    )
                ],
                servers: []
            )
        )
    }
}

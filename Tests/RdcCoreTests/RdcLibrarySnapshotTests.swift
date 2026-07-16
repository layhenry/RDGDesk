import Foundation
import XCTest
@testable import RdcCore

final class RdcLibrarySnapshotTests: XCTestCase {
    func testLegacySnapshotNormalizesStableIDsAndPreservesThemAfterMutableEdits() throws {
        let legacy = try JSONDecoder().decode(
            RdcLibrarySnapshot.self,
            from: legacySnapshotJSON()
        )
        let preMigrationLibrary = RdcImportedLibrary(
            document: legacy.makeDocument(),
            sourceID: legacy.sourceID,
            sourceName: legacy.sourceName
        )
        let migrated = legacy.normalizedStableIdentity()
        let groupID = try XCTUnwrap(migrated.root.groups.first?.id)
        let serverID = try XCTUnwrap(migrated.root.groups.first?.servers.first?.id)

        XCTAssertEqual(
            migrated.makeLibrary().groups.map(\.id),
            preMigrationLibrary.groups.map(\.id)
        )
        XCTAssertEqual(
            migrated.makeLibrary().servers.map(\.id),
            preMigrationLibrary.servers.map(\.id)
        )

        var edited = migrated
        edited.root.groups[0].name = "新分组名称"
        edited.root.groups[0].servers[0].displayName = "新服务器名称"
        edited.root.groups[0].servers[0].address = "203.0.113.10:3390"

        let renormalized = edited.normalizedStableIdentity()

        XCTAssertEqual(renormalized.root.groups[0].id, groupID)
        XCTAssertEqual(renormalized.root.groups[0].servers[0].id, serverID)
        XCTAssertEqual(
            renormalized.root.groups[0].sourceFingerprint,
            migrated.root.groups[0].sourceFingerprint
        )
        XCTAssertEqual(
            renormalized.root.groups[0].servers[0].sourceFingerprint,
            migrated.root.groups[0].servers[0].sourceFingerprint
        )
        XCTAssertFalse(try XCTUnwrap(renormalized.root.groups[0].sourceFingerprint).isEmpty)
        XCTAssertFalse(
            try XCTUnwrap(renormalized.root.groups[0].servers[0].sourceFingerprint).isEmpty
        )
    }

    func testNormalizationDoesNotTurnLocallyCreatedResourcesIntoImportedResources() throws {
        var snapshot = RdcLibrarySnapshot(
            sourceID: "source-1", sourceName: "temp2.rdg",
            document: try fixtureDocument(named: "minimal-rdcman")
        )
        snapshot.root.groups.append(RdcGroupSnapshot(
            id: UUID().uuidString,
            sourceFingerprint: nil,
            name: "Mac 专用",
            isExpanded: true,
            groups: [],
            servers: []
        ))

        let normalized = snapshot.normalizedStableIdentity()

        XCTAssertNil(normalized.root.groups.last?.sourceFingerprint)
    }

    func testLegacyBracketedIPv6UsesFrozenStableIDAddressSemantics() throws {
        let sourceID = "legacy-ipv6"
        let rawAddress = "[2001:db8::1]:3390"
        let document = RdcManDocument(
            programVersion: "2.7", schemaVersion: "3",
            root: RdcGroup(
                name: "Root", isExpanded: true, logonCredentials: nil,
                groups: [], servers: [RdcServer(
                    displayName: "IPv6", address: RdcServerAddress(rawAddress),
                    logonCredentials: nil
                )]
            )
        )
        var legacy = RdcLibrarySnapshot(
            sourceID: sourceID, sourceName: "legacy.rdg", document: document
        )
        legacy.root.servers[0].id = nil
        legacy.root.servers[0].sourceFingerprint = nil

        let migrated = legacy.normalizedStableIdentity()
        let expectedOldID = StableLibraryID.server(
            sourceID: sourceID,
            path: ["Root", "IPv6"],
            host: rawAddress,
            port: 3_389,
            groupSiblingOccurrences: [],
            siblingOccurrence: 0
        )

        XCTAssertEqual(migrated.root.servers[0].id, expectedOldID)
        XCTAssertEqual(RdcServerAddress(rawAddress).host, "2001:db8::1")
        XCTAssertEqual(RdcServerAddress(rawAddress).port, 3_390)
    }

    func testSnapshotRestoresTreeWithoutDPAPICiphertext() throws {
        let document = try fixtureDocument(named: "minimal-rdcman")
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-1", sourceName: "temp2.rdg", document: document
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let restored = snapshot.makeDocument()
        XCTAssertFalse(text.contains("AQAAANCM"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("password"))
        XCTAssertNil(restored.root.logonCredentials)
        XCTAssertNil(restored.root.groups.first?.logonCredentials)
        XCTAssertNil(restored.root.groups.first?.groups.first?.logonCredentials)
        XCTAssertNil(restored.root.groups.first?.groups.first?.servers.first?.logonCredentials)
        XCTAssertEqual(
            restored.root.groups.first?.groups.first?.servers.first?.address.rawValue,
            "rdp.example.test:6166"
        )
    }

    func testSnapshotRoundTripPreservesOnlyLibraryDisplayFields() throws {
        let snapshot = RdcLibrarySnapshot(
            sourceID: "source-1",
            sourceName: "temp2.rdg",
            document: try fixtureDocument(named: "minimal-rdcman")
        )

        let decoded = try JSONDecoder().decode(
            RdcLibrarySnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.programVersion, "2.92")
        XCTAssertEqual(decoded.schemaVersion, "3")
        XCTAssertEqual(decoded.root.name, "示例资源库")
        XCTAssertEqual(decoded.root.isExpanded, true)
        XCTAssertEqual(decoded.root.groups.first?.name, "生产环境")
        XCTAssertEqual(
            decoded.root.groups.first?.groups.first?.servers.first?.displayName,
            "Windows Server A"
        )
    }

    func testSourceLocatorAliasesDecodeLegacyAndNeverContainRawPath() throws {
        var snapshot = RdcLibrarySnapshot(
            sourceID: "source", sourceName: "a.rdg", document: try fixtureDocument(named: "minimal-rdcman")
        )
        snapshot.sourceLocatorAliases = ["file-id:abc", "path-hash:def"]
        let encoded = try JSONEncoder().encode(snapshot)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("/Users/example"))
        XCTAssertEqual(
            try JSONDecoder().decode(RdcLibrarySnapshot.self, from: encoded).sourceLocatorAliases,
            Set(["file-id:abc", "path-hash:def"])
        )

        let legacy = try JSONDecoder().decode(RdcLibrarySnapshot.self, from: legacySnapshotJSON())
        XCTAssertTrue(legacy.sourceLocatorAliases.isEmpty)
    }

    private func fixtureDocument(named name: String) throws -> RdcManDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).rdg")
        return try RdcManParser().parse(fileAt: url)
    }

    private func legacySnapshotJSON() -> Data {
        Data(
            #"""
            {
              "sourceID": "legacy-source",
              "sourceName": "legacy.rdg",
              "programVersion": "2.92",
              "schemaVersion": "3",
              "root": {
                "name": "Root",
                "isExpanded": true,
                "groups": [{
                  "name": "Production",
                  "isExpanded": true,
                  "groups": [],
                  "servers": [{
                    "displayName": "Gateway",
                    "address": "192.0.2.10:3389"
                  }]
                }],
                "servers": []
              }
            }
            """#.utf8
        )
    }
}

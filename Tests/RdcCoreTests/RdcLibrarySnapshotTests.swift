import Foundation
import XCTest
@testable import RdcCore

final class RdcLibrarySnapshotTests: XCTestCase {
    func testLegacySecurityCompatibilityOptInSurvivesSnapshotRoundTrip() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacySnapshotJSON()) as? [String: Any]
        )
        var root = try XCTUnwrap(object["root"] as? [String: Any])
        var groups = try XCTUnwrap(root["groups"] as? [[String: Any]])
        var servers = try XCTUnwrap(groups[0]["servers"] as? [[String: Any]])
        servers[0]["legacySecurityEnabled"] = true
        groups[0]["servers"] = servers
        root["groups"] = groups
        object["root"] = root

        let decoded = try JSONDecoder().decode(
            RdcLibrarySnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let roundTripped = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
                as? [String: Any]
        )
        let encodedRoot = try XCTUnwrap(roundTripped["root"] as? [String: Any])
        let encodedGroups = try XCTUnwrap(encodedRoot["groups"] as? [[String: Any]])
        let encodedServers = try XCTUnwrap(encodedGroups[0]["servers"] as? [[String: Any]])

        XCTAssertEqual(encodedServers[0]["legacySecurityEnabled"] as? Bool, true)
    }

    func testLegacySecurityCompatibilityOptInReachesConnectionRequest() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacySnapshotJSON()) as? [String: Any]
        )
        var root = try XCTUnwrap(object["root"] as? [String: Any])
        var groups = try XCTUnwrap(root["groups"] as? [[String: Any]])
        var servers = try XCTUnwrap(groups[0]["servers"] as? [[String: Any]])
        servers[0]["legacySecurityEnabled"] = true
        groups[0]["servers"] = servers
        root["groups"] = groups
        object["root"] = root
        let snapshot = try JSONDecoder().decode(
            RdcLibrarySnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        let server = try XCTUnwrap(snapshot.makeLibrary().servers.first)

        XCTAssertEqual(
            Mirror(reflecting: server.connectionRequest)
                .descendant("legacySecurityEnabled") as? Bool,
            true
        )
    }

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
            sourceID: "source-1", sourceName: "example.rdg",
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

    func testSuppressedImportedGroupRoundTripStaysLocalAfterNormalization() throws {
        let original = RdcLibrarySnapshot(
            sourceID: "durable-shell-source",
            sourceName: "durable-shell.rdg",
            document: RdcManDocument(
                programVersion: "2.7",
                schemaVersion: "3",
                root: RdcGroup(
                    name: "Root",
                    isExpanded: true,
                    logonCredentials: nil,
                    groups: [RdcGroup(
                        name: "Imported Parent",
                        isExpanded: true,
                        logonCredentials: nil,
                        groups: [],
                        servers: []
                    )],
                    servers: []
                )
            )
        )
        let parentID = try XCTUnwrap(original.root.groups.first?.id)
        let withManualServer = try ResourceLibraryEditor.createServer(
            in: original,
            parentID: parentID,
            draft: .init(displayName: "Manual", host: "192.0.2.94", port: 3_389)
        ).snapshot
        let absentUpstream = RdcLibrarySnapshot(
            sourceID: original.sourceID,
            sourceName: original.sourceName,
            document: RdcManDocument(
                programVersion: "2.7",
                schemaVersion: "3",
                root: RdcGroup(
                    name: "Root",
                    isExpanded: true,
                    logonCredentials: nil,
                    groups: [],
                    servers: []
                )
            )
        )
        let detached = ResourceLibraryEditor.mergeReimport(
            existing: withManualServer,
            imported: absentUpstream,
            restoreDeletedItems: false
        )

        let encoded = try JSONEncoder().encode(detached)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let decoded = try JSONDecoder().decode(RdcLibrarySnapshot.self, from: encoded)
        let normalized = decoded.normalizedStableIdentity()
        let shell = try XCTUnwrap(normalized.root.groups.first { $0.id == parentID })

        XCTAssertTrue(encodedText.contains(#""sourceFingerprintSuppressed":true"#))
        XCTAssertEqual(shell.id, parentID)
        XCTAssertEqual(shell.name, "Imported Parent")
        XCTAssertNil(shell.sourceFingerprint)
        XCTAssertEqual(shell.servers.compactMap(\.id), withManualServer.allServers.compactMap(\.id))
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
            sourceID: "source-1", sourceName: "example.rdg", document: document
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
            sourceName: "example.rdg",
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
            "Example Server A"
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

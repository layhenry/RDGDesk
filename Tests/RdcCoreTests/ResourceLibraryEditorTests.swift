import XCTest
@testable import RdcCore

final class ResourceLibraryEditorTests: XCTestCase {
    func testUpdateServerValidatesAndPreservesIdentity() throws {
        let snapshot = editableFixture()
        let serverID = try XCTUnwrap(snapshot.root.groups[0].servers[0].id)
        let fingerprint = snapshot.root.groups[0].servers[0].sourceFingerprint

        let updated = try ResourceLibraryEditor.updateServer(
            in: snapshot,
            id: serverID,
            draft: ServerPropertiesDraft(
                displayName: "  生产服务器  ",
                host: "203.0.113.20",
                port: 3_390
            )
        )

        let server = updated.root.groups[0].servers[0]
        XCTAssertEqual(server.id, serverID)
        XCTAssertEqual(server.sourceFingerprint, fingerprint)
        XCTAssertEqual(server.displayName, "生产服务器")
        XCTAssertEqual(server.address, "203.0.113.20:3390")
        XCTAssertEqual(snapshot.root.groups[0].servers[0].displayName, "Server A")
    }

    func testServerDraftRejectsEmptyNameInvalidHostAndInvalidPort() {
        XCTAssertThrowsError(
            try ServerPropertiesDraft(displayName: "   ", host: "host", port: 3_389).validated()
        ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .emptyName) }

        for invalidHost in ["https://host", "host name", "host/path", "\tserver"] {
            XCTAssertThrowsError(
                try ServerPropertiesDraft(
                    displayName: "Server",
                    host: invalidHost,
                    port: 3_389
                ).validated()
            ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .invalidHost) }
        }

        for invalidPort in [0, 65_536] {
            XCTAssertThrowsError(
                try ServerPropertiesDraft(
                    displayName: "Server",
                    host: "server.example",
                    port: invalidPort
                ).validated()
            ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .invalidPort) }
        }
    }

    func testServerDraftAcceptsDNSIPv4AndBareIPv6ButRejectsEmbeddedPortAndDelimiters() throws {
        for host in ["server.example.com", "192.0.2.10", "2001:db8::10"] {
            XCTAssertEqual(
                try ServerPropertiesDraft(displayName: "Server", host: host, port: 3_389)
                    .validated().host,
                host
            )
        }
        for host in ["example.com:3390", "server?query", "user@server", "[2001:db8::1]"] {
            XCTAssertThrowsError(
                try ServerPropertiesDraft(displayName: "Server", host: host, port: 3_389)
                    .validated()
            ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .invalidHost) }
        }
    }

    func testUpdateServerSerializesBareIPv6WithBrackets() throws {
        let snapshot = editableFixture()
        let serverID = try XCTUnwrap(snapshot.root.groups[0].servers[0].id)
        let updated = try ResourceLibraryEditor.updateServer(
            in: snapshot,
            id: serverID,
            draft: .init(displayName: "IPv6", host: "2001:db8::10", port: 3_390)
        )
        XCTAssertEqual(updated.root.groups[0].servers[0].address, "[2001:db8::10]:3390")
        let server = try XCTUnwrap(updated.makeLibrary().servers.first { $0.id == serverID })
        XCTAssertEqual(server.connectionRequest.host, "2001:db8::10")
        XCTAssertEqual(server.connectionRequest.port, 3_390)
    }

    func testUpdateGroupTrimsNamePreservesIdentityAndRejectsDuplicateSibling() throws {
        let snapshot = editableFixture()
        let groupID = try XCTUnwrap(snapshot.root.groups[0].id)
        let fingerprint = snapshot.root.groups[0].sourceFingerprint

        let updated = try ResourceLibraryEditor.updateGroup(
            in: snapshot,
            id: groupID,
            draft: GroupPropertiesDraft(name: "  本地改名  ")
        )
        XCTAssertEqual(updated.root.groups[0].name, "本地改名")
        XCTAssertEqual(updated.root.groups[0].id, groupID)
        XCTAssertEqual(updated.root.groups[0].sourceFingerprint, fingerprint)

        XCTAssertThrowsError(
            try ResourceLibraryEditor.updateGroup(
                in: snapshot,
                id: groupID,
                draft: GroupPropertiesDraft(name: "Group B")
            )
        ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .duplicateSiblingGroupName) }
    }

    func testCreateChildGroupUsesNewIdentityWithoutSourceFingerprint() throws {
        let snapshot = editableFixture()
        let parentID = try XCTUnwrap(snapshot.root.groups[0].id)
        let updated = try ResourceLibraryEditor.createChildGroup(
            in: snapshot,
            parentID: parentID,
            name: "  Mac Only  "
        )
        let created = try XCTUnwrap(updated.root.groups[0].groups.last)
        XCTAssertEqual(created.name, "Mac Only")
        XCTAssertNotNil(created.id)
        XCTAssertNil(created.sourceFingerprint)
        XCTAssertTrue(created.groups.isEmpty)
        XCTAssertTrue(created.servers.isEmpty)

        XCTAssertThrowsError(
            try ResourceLibraryEditor.createChildGroup(
                in: updated,
                parentID: parentID,
                name: "Mac Only"
            )
        ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .duplicateSiblingGroupName) }
    }

    func testMoveServerPreservesIdentityAndMovesNode() throws {
        let snapshot = editableFixture()
        let server = snapshot.root.groups[0].servers[0]
        let destinationID = try XCTUnwrap(snapshot.root.groups[1].id)
        let updated = try ResourceLibraryEditor.moveServer(
            in: snapshot,
            id: try XCTUnwrap(server.id),
            destinationGroupID: destinationID
        )
        XCTAssertTrue(updated.root.groups[0].servers.isEmpty)
        XCTAssertEqual(updated.root.groups[1].servers.last, server)
    }

    func testMoveGroupRejectsRootCycleAndDuplicateDestinationName() throws {
        let fixture = editableNestedFixture()
        XCTAssertThrowsError(
            try ResourceLibraryEditor.moveGroup(
                in: fixture.snapshot,
                id: try XCTUnwrap(fixture.snapshot.root.id),
                destinationGroupID: fixture.parentGroupID
            )
        ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .cannotMoveRoot) }
        XCTAssertThrowsError(
            try ResourceLibraryEditor.moveGroup(
                in: fixture.snapshot,
                id: fixture.parentGroupID,
                destinationGroupID: fixture.childGroupID
            )
        ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .cyclicGroupMove) }

        let duplicate = try XCTUnwrap(fixture.snapshot.root.groups[1].id)
        XCTAssertThrowsError(
            try ResourceLibraryEditor.moveGroup(
                in: fixture.snapshot,
                id: fixture.childGroupID,
                destinationGroupID: duplicate
            )
        ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .duplicateSiblingGroupName) }
    }

    func testDeleteGroupRejectsRootAndRequiresRemoveLibrary() throws {
        let snapshot = editableFixture()
        XCTAssertThrowsError(
            try ResourceLibraryEditor.deleteGroup(
                in: snapshot,
                id: try XCTUnwrap(snapshot.root.id),
                selectedServerID: nil
            )
        ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .cannotDeleteRoot) }
    }

    func testMoveGroupPreservesCompleteSubtreeIdentity() throws {
        let fixture = editableNestedFixture()
        let child = fixture.snapshot.root.groups[0].groups[0]
        let destinationID = try XCTUnwrap(fixture.snapshot.root.groups[2].id)
        let updated = try ResourceLibraryEditor.moveGroup(
            in: fixture.snapshot,
            id: fixture.childGroupID,
            destinationGroupID: destinationID
        )
        XCTAssertTrue(updated.root.groups[0].groups.isEmpty)
        XCTAssertEqual(updated.root.groups[2].groups, [child])
    }

    func testDeleteGroupReportsRecursiveImpactSelectionAndTombstones() throws {
        let fixture = editableNestedFixture()
        XCTAssertEqual(
            try ResourceLibraryEditor.deletionImpact(
                in: fixture.snapshot,
                groupID: fixture.parentGroupID,
                selectedServerID: fixture.selectedServerID
            ),
            ResourceDeletionImpact(groupCount: 2, serverCount: 3, containsSelectedServer: true)
        )

        let result = try ResourceLibraryEditor.deleteGroup(
            in: fixture.snapshot,
            id: fixture.parentGroupID,
            selectedServerID: fixture.selectedServerID
        )
        XCTAssertEqual(result.impact.groupCount, 2)
        XCTAssertEqual(result.impact.serverCount, 3)
        XCTAssertTrue(result.impact.containsSelectedServer)
        XCTAssertEqual(result.selectedServerID, fixture.expectedFallbackServerID)
        XCTAssertEqual(result.removedGroupIDs.count, 2)
        XCTAssertEqual(result.removedServerIDs.count, 3)
        XCTAssertEqual(result.addedTombstones.count, 5)
        XCTAssertEqual(result.snapshot?.deletedSourceItems.count, 5)
    }

    func testDeleteServerSelectsNextThenPreviousAndOnlyTombstonesSourceItems() throws {
        var snapshot = editableFixture()
        var localServer = snapshot.root.groups[1].servers[0]
        localServer.id = UUID().uuidString
        localServer.sourceFingerprint = nil
        localServer.displayName = "Local"
        localServer.address = "local:3389"
        snapshot.root.groups[0].servers.append(localServer)
        let firstID = try XCTUnwrap(snapshot.root.groups[0].servers[0].id)
        let localID = try XCTUnwrap(snapshot.root.groups[0].servers[1].id)
        let first = try ResourceLibraryEditor.deleteServer(
            in: snapshot,
            id: firstID,
            selectedServerID: firstID
        )
        XCTAssertEqual(first.selectedServerID, localID)
        XCTAssertEqual(first.addedTombstones.count, 1)

        let second = try ResourceLibraryEditor.deleteServer(
            in: try XCTUnwrap(first.snapshot),
            id: localID,
            selectedServerID: localID
        )
        XCTAssertEqual(second.selectedServerID, try XCTUnwrap(snapshot.root.groups[1].servers[0].id))
        XCTAssertTrue(second.addedTombstones.isEmpty)
    }

    func testDeleteServerPrefersSameGroupPreviousOverGlobalLaterServer() throws {
        let snapshot = selectionFallbackFixture()
        let previousID = try XCTUnwrap(snapshot.root.groups[0].servers[0].id)
        let selectedID = try XCTUnwrap(snapshot.root.groups[0].servers[1].id)

        let result = try ResourceLibraryEditor.deleteServer(
            in: snapshot,
            id: selectedID,
            selectedServerID: selectedID
        )

        XCTAssertEqual(result.selectedServerID, previousID)
    }

    func testDeleteServerReturnsNilWhenOnlyGlobalPreviousServerSurvives() throws {
        let snapshot = selectionFallbackFixture()
        let selectedID = try XCTUnwrap(snapshot.root.groups[1].servers[0].id)

        let result = try ResourceLibraryEditor.deleteServer(
            in: snapshot,
            id: selectedID,
            selectedServerID: selectedID
        )

        XCTAssertNil(result.selectedServerID)
    }

    func testDeleteMissingResourcesThrowsAndDoesNotMutateInput() throws {
        let snapshot = editableFixture()
        XCTAssertThrowsError(
            try ResourceLibraryEditor.deleteServer(
                in: snapshot,
                id: "missing",
                selectedServerID: nil
            )
        ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .missingResource) }
        XCTAssertThrowsError(
            try ResourceLibraryEditor.deleteGroup(
                in: snapshot,
                id: "missing",
                selectedServerID: nil
            )
        ) { XCTAssertEqual($0 as? ResourceLibraryEditError, .missingResource) }
    }

    func testRemoveLibraryReturnsNilSnapshotAndCompleteImpact() {
        let snapshot = editableFixture()
        let selectedID = snapshot.root.groups[0].servers[0].id
        let result = ResourceLibraryEditor.removeLibrary(snapshot, selectedServerID: selectedID)
        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.impact.groupCount, 3)
        XCTAssertEqual(result.impact.serverCount, 2)
        XCTAssertTrue(result.impact.containsSelectedServer)
        XCTAssertNil(result.selectedServerID)
        XCTAssertEqual(result.addedTombstones.count, 5)
    }

    func testMergeReimportPreservesLocalEditsMovesAndMacOnlyGroupsWithoutRevivingTombstones() throws {
        let original = reimportFixture(includeNewServer: false)
        let groupAID = try XCTUnwrap(original.root.groups[0].id)
        let groupBID = try XCTUnwrap(original.root.groups[1].id)
        let keptServerID = try XCTUnwrap(original.root.groups[0].servers[0].id)
        let deletedServerID = try XCTUnwrap(original.root.groups[0].servers[1].id)
        let deletedFingerprint = try XCTUnwrap(original.root.groups[0].servers[1].sourceFingerprint)

        var existing = try ResourceLibraryEditor.updateGroup(
            in: original,
            id: groupAID,
            draft: GroupPropertiesDraft(name: "本地改名")
        )
        existing = try ResourceLibraryEditor.updateServer(
            in: existing,
            id: keptServerID,
            draft: ServerPropertiesDraft(displayName: "本地服务器", host: "local.example", port: 3_390)
        )
        existing = try ResourceLibraryEditor.moveServer(
            in: existing,
            id: keptServerID,
            destinationGroupID: groupBID
        )
        existing = try ResourceLibraryEditor.createChildGroup(
            in: existing,
            parentID: groupBID,
            name: "Mac Only"
        )
        existing = try XCTUnwrap(
            ResourceLibraryEditor.deleteServer(
                in: existing,
                id: deletedServerID,
                selectedServerID: nil
            ).snapshot
        )

        let imported = reimportFixture(includeNewServer: true)
        let merged = ResourceLibraryEditor.mergeReimport(
            existing: existing,
            imported: imported,
            restoreDeletedItems: false
        )

        XCTAssertEqual(merged.root.groups[0].name, "本地改名")
        XCTAssertEqual(merged.root.groups[0].servers.map(\.displayName), ["New upstream"])
        XCTAssertEqual(merged.root.groups[1].servers[0].displayName, "本地服务器")
        XCTAssertEqual(merged.root.groups[1].servers[0].address, "local.example:3390")
        XCTAssertEqual(merged.root.groups[1].servers[0].id, keptServerID)
        XCTAssertEqual(merged.root.groups[1].groups[0].name, "Mac Only")
        XCTAssertFalse(merged.allServers.contains { $0.sourceFingerprint == deletedFingerprint })
        XCTAssertTrue(merged.allServers.contains { $0.displayName == "New upstream" })
        XCTAssertEqual(merged.deletedSourceItems, existing.deletedSourceItems)
    }

    func testMergeReimportCanExplicitlyRestoreDeletedSourceItems() throws {
        let original = reimportFixture(includeNewServer: false)
        let deleted = try ResourceLibraryEditor.deleteServer(
            in: original,
            id: try XCTUnwrap(original.root.groups[0].servers[1].id),
            selectedServerID: nil
        )
        let merged = ResourceLibraryEditor.mergeReimport(
            existing: try XCTUnwrap(deleted.snapshot),
            imported: original,
            restoreDeletedItems: true
        )
        XCTAssertEqual(merged.allServers.count, original.allServers.count)
        XCTAssertTrue(merged.deletedSourceItems.isEmpty)
    }

    func testMergeRestoredParentStillMergesNewChildrenIntoLocallyMovedDescendant() throws {
        let original = nestedReimportFixture(includeNewServer: false)
        let parentID = try XCTUnwrap(original.root.groups[0].id)
        let childID = try XCTUnwrap(original.root.groups[0].groups[0].id)
        let destinationID = try XCTUnwrap(original.root.groups[1].id)
        var existing = try ResourceLibraryEditor.moveGroup(
            in: original,
            id: childID,
            destinationGroupID: destinationID
        )
        existing = try XCTUnwrap(
            ResourceLibraryEditor.deleteGroup(
                in: existing,
                id: parentID,
                selectedServerID: nil
            ).snapshot
        )

        let merged = ResourceLibraryEditor.mergeReimport(
            existing: existing,
            imported: nestedReimportFixture(includeNewServer: true),
            restoreDeletedItems: true
        )

        XCTAssertEqual(merged.root.groups[0].name, "Destination")
        XCTAssertEqual(merged.root.groups[0].groups[0].name, "Child")
        XCTAssertEqual(
            merged.root.groups[0].groups[0].servers.map(\.displayName),
            ["Existing", "New nested"]
        )
        XCTAssertEqual(merged.root.groups[1].name, "Parent")
        XCTAssertTrue(merged.root.groups[1].groups.isEmpty)
    }

    func testMergeReimportFromDifferentSourceReturnsExistingSnapshotUnchanged() throws {
        let original = editableFixture()
        let deleted = try ResourceLibraryEditor.deleteServer(
            in: original,
            id: try XCTUnwrap(original.root.groups[0].servers[0].id),
            selectedServerID: nil
        )
        let existing = try XCTUnwrap(deleted.snapshot)
        var imported = reimportFixture(includeNewServer: true)
        imported.sourceID = "different-source"
        imported.sourceName = "different.rdg"
        imported.programVersion = "99.0"
        imported.schemaVersion = "99"
        imported.root.name = "Different Root"

        let merged = ResourceLibraryEditor.mergeReimport(
            existing: existing,
            imported: imported,
            restoreDeletedItems: true
        )

        XCTAssertEqual(merged, existing)
    }

    private func editableFixture() -> RdcLibrarySnapshot {
        snapshot(
            root: RdcGroup(
                name: "Root",
                isExpanded: true,
                logonCredentials: nil,
                groups: [
                    group("Group A", servers: [server("Server A", "a.example:3389")]),
                    group("Group B", servers: [server("Server B", "b.example:3389")])
                ],
                servers: []
            )
        )
    }

    private func selectionFallbackFixture() -> RdcLibrarySnapshot {
        snapshot(
            root: RdcGroup(
                name: "Root",
                isExpanded: true,
                logonCredentials: nil,
                groups: [
                    group(
                        "First",
                        servers: [
                            server("Previous", "previous.example:3389"),
                            server("Selected", "selected.example:3389")
                        ]
                    ),
                    group("Second", servers: [server("Later", "later.example:3389")])
                ],
                servers: []
            )
        )
    }

    private func editableNestedFixture() -> (
        snapshot: RdcLibrarySnapshot,
        parentGroupID: String,
        childGroupID: String,
        selectedServerID: String,
        expectedFallbackServerID: String
    ) {
        let snapshot = snapshot(
            root: RdcGroup(
                name: "Root",
                isExpanded: true,
                logonCredentials: nil,
                groups: [
                    group(
                        "Parent",
                        groups: [group("Duplicate", servers: [server("Nested", "nested:3389")])],
                        servers: [server("One", "one:3389"), server("Two", "two:3389")]
                    ),
                    group("Destination", groups: [group("Duplicate")], servers: [server("Next", "next:3389")]),
                    group("Empty")
                ],
                servers: []
            )
        )
        return (
            snapshot,
            snapshot.root.groups[0].id!,
            snapshot.root.groups[0].groups[0].id!,
            snapshot.root.groups[0].groups[0].servers[0].id!,
            snapshot.root.groups[1].servers[0].id!
        )
    }

    private func reimportFixture(includeNewServer: Bool) -> RdcLibrarySnapshot {
        var servers = [server("Kept", "kept.example:3389"), server("Deleted", "deleted.example:3389")]
        if includeNewServer {
            servers.append(server("New upstream", "new.example:3389"))
        }
        return snapshot(
            root: RdcGroup(
                name: "Root",
                isExpanded: true,
                logonCredentials: nil,
                groups: [group("Group A", servers: servers), group("Group B")],
                servers: []
            )
        )
    }

    private func nestedReimportFixture(includeNewServer: Bool) -> RdcLibrarySnapshot {
        var servers = [server("Existing", "existing.example:3389")]
        if includeNewServer {
            servers.append(server("New nested", "nested-new.example:3389"))
        }
        return snapshot(
            root: RdcGroup(
                name: "Root",
                isExpanded: true,
                logonCredentials: nil,
                groups: [
                    group("Parent", groups: [group("Child", servers: servers)]),
                    group("Destination")
                ],
                servers: []
            )
        )
    }

    private func snapshot(root: RdcGroup) -> RdcLibrarySnapshot {
        RdcLibrarySnapshot(
            sourceID: "source-1",
            sourceName: "fixture.rdg",
            document: RdcManDocument(programVersion: "2.92", schemaVersion: "3", root: root)
        )
    }

    private func group(
        _ name: String,
        groups: [RdcGroup] = [],
        servers: [RdcServer] = []
    ) -> RdcGroup {
        RdcGroup(
            name: name,
            isExpanded: true,
            logonCredentials: nil,
            groups: groups,
            servers: servers
        )
    }

    private func server(_ name: String, _ address: String) -> RdcServer {
        RdcServer(
            displayName: name,
            address: RdcServerAddress(address),
            logonCredentials: nil
        )
    }
}

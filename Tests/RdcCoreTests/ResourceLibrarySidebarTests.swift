import XCTest
@testable import RdcCore

final class ResourceLibrarySidebarTests: XCTestCase {
    func testDirection2SidebarChromeOmitsStatsAndFavorites() throws {
        let sidebar = try ResourceLibrarySidebarState(document: parsedFixture())

        XCTAssertTrue(sidebar.chrome.showsSearchField)
        XCTAssertEqual(sidebar.chrome.rowStyle, .macOSSourceList)
        XCTAssertFalse(sidebar.chrome.showsStatisticsCards)
        XCTAssertFalse(sidebar.chrome.showsFavoritesSection)
    }

    func testBuildsIndentedTreeRowsWithIconsDisclosureBadgesAndSelection() throws {
        let document = try parsedFixture()
        let library = RdcImportedLibrary(
            document: document, sourceID: "source-1", sourceName: "temp2.rdg"
        )
        let sidebar = ResourceLibrarySidebarState(
            document: document,
            sourceID: "source-1",
            selectedServerID: library.servers[0].id,
            expandedGroupIDs: Set(library.groups.map(\.id))
        )

        XCTAssertEqual(sidebar.rows.map(\.title), [
            "示例资源库",
            "生产环境",
            "业务服务器",
            "Windows Server A",
            "Windows Server B"
        ])

        XCTAssertEqual(sidebar.rows.map(\.indentationLevel), [0, 1, 2, 3, 3])
        XCTAssertEqual(sidebar.rows[0].symbolName, "folder")
        XCTAssertEqual(sidebar.rows[0].disclosureState, .expanded)
        XCTAssertEqual(sidebar.rows[0].countBadge, 2)
        XCTAssertEqual(sidebar.rows[3].symbolName, "desktopcomputer")
        XCTAssertNil(sidebar.rows[3].disclosureState)
        XCTAssertNil(sidebar.rows[3].countBadge)
        XCTAssertTrue(sidebar.rows[3].isSelected)
        XCTAssertEqual(sidebar.rows[3].subtitle, "rdp.example.test:6166")
        XCTAssertEqual(
            sidebar.rows.filter { $0.kind == .group }.compactMap(\.representedGroupID),
            library.groups.map(\.id)
        )
        XCTAssertEqual(
            sidebar.rows.filter { $0.kind == .server }.compactMap(\.representedServerID),
            library.servers.map(\.id)
        )
    }

    func testSearchFiltersServersWhileKeepingMatchingAncestors() throws {
        let sidebar = try ResourceLibrarySidebarState(
            document: parsedFixture(),
            searchText: "Server B"
        )

        XCTAssertEqual(sidebar.rows.map(\.title), [
            "示例资源库",
            "生产环境",
            "业务服务器",
            "Windows Server B"
        ])
        XCTAssertEqual(sidebar.rows.map(\.indentationLevel), [0, 1, 2, 3])
    }

    func testDuplicateSiblingRowsMatchUniqueImportedLibraryIdentities() {
        let duplicateServer = RdcServer(
            displayName: "Duplicate",
            address: RdcServerAddress("same.example:3389"),
            logonCredentials: nil
        )
        let document = RdcManDocument(
            programVersion: "2.92",
            schemaVersion: "3",
            root: RdcGroup(
                name: "Root",
                isExpanded: true,
                logonCredentials: nil,
                groups: [
                    RdcGroup(
                        name: "Same", isExpanded: true, logonCredentials: nil,
                        groups: [], servers: [duplicateServer, duplicateServer]
                    ),
                    RdcGroup(
                        name: "Same", isExpanded: true, logonCredentials: nil,
                        groups: [], servers: [duplicateServer]
                    )
                ],
                servers: []
            )
        )
        let library = RdcImportedLibrary(
            document: document,
            sourceID: "duplicate-source",
            sourceName: "duplicates.rdg"
        )
        let sidebar = ResourceLibrarySidebarState(
            document: document,
            sourceID: library.sourceID,
            selectedServerID: library.servers[1].id,
            expandedGroupIDs: Set(library.groups.map(\.id))
        )
        let repeatedSidebar = ResourceLibrarySidebarState(
            document: document,
            sourceID: library.sourceID,
            selectedServerID: library.servers[1].id,
            expandedGroupIDs: Set(library.groups.map(\.id))
        )

        XCTAssertEqual(
            sidebar.rows.filter { $0.kind == .group }.compactMap(\.representedGroupID),
            library.groups.map(\.id)
        )
        XCTAssertEqual(
            sidebar.rows.filter { $0.kind == .server }.compactMap(\.representedServerID),
            library.servers.map(\.id)
        )
        XCTAssertEqual(sidebar.rows.filter(\.isSelected).count, 1)
        XCTAssertEqual(Set(sidebar.rows.map(\.id)).count, sidebar.rows.count)
        XCTAssertEqual(sidebar.rows.map(\.id), repeatedSidebar.rows.map(\.id))
    }

    private func parsedFixture() throws -> RdcManDocument {
        try RdcManParser().parse(fileAt: fixtureURL())
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/minimal-rdcman.rdg")
    }
}

import Foundation

public struct ResourceLibrarySidebarState: Equatable, Sendable {
    public let chrome: ResourceLibrarySidebarChrome
    public let rows: [ResourceLibrarySidebarRow]
    public let searchText: String

    public init(
        library: RdcImportedLibrary,
        expandedGroupIDs: Set<String> = [],
        searchText: String = ""
    ) {
        self.chrome = .direction2
        self.searchText = searchText

        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rows = ImportedResourceLibraryTreeBuilder(
            library: library,
            expandedGroupIDs: expandedGroupIDs,
            searchText: normalizedSearch
        ).rows()
    }

    public init(
        document: RdcManDocument,
        sourceID: String,
        selectedServerID: String? = nil,
        expandedGroupIDs: Set<String> = [],
        searchText: String = ""
    ) {
        self.chrome = .direction2
        self.searchText = searchText

        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rows = ResourceLibraryTreeBuilder(
            sourceID: sourceID,
            selectedServerID: selectedServerID,
            expandedGroupIDs: expandedGroupIDs,
            searchText: normalizedSearch
        ).rows(for: document.root)
    }

    public init(
        document: RdcManDocument,
        selectedServerID: String? = nil,
        expandedGroupIDs: Set<String> = [],
        searchText: String = ""
    ) {
        self.init(
            document: document,
            sourceID: StableLibraryID.compatibilitySourceID(for: document),
            selectedServerID: selectedServerID,
            expandedGroupIDs: expandedGroupIDs,
            searchText: searchText
        )
    }
}

private struct ImportedResourceLibraryTreeBuilder {
    let library: RdcImportedLibrary
    let expandedGroupIDs: Set<String>
    let searchText: String

    func rows() -> [ResourceLibrarySidebarRow] {
        library.groups.filter { $0.parentID == nil }.flatMap {
            groupRows(for: $0, indentationLevel: 0)
        }
    }

    private func groupRows(
        for group: RdcImportedGroup,
        indentationLevel: Int
    ) -> [ResourceLibrarySidebarRow] {
        let childRows = visibleChildRows(
            for: group,
            indentationLevel: indentationLevel + 1
        )
        guard searchText.isEmpty || matches(group.name) || !childRows.isEmpty else {
            return []
        }

        let legacyGroupID = group.path.joined(separator: "/")
        let isExpanded = searchText.isEmpty
            ? expandedGroupIDs.contains(group.id) || expandedGroupIDs.contains(legacyGroupID)
            : true
        let row = ResourceLibrarySidebarRow(
            id: "group:\(group.id)",
            title: group.name,
            subtitle: nil,
            representedGroupID: group.id,
            representedServerID: nil,
            kind: .group,
            indentationLevel: indentationLevel,
            symbolName: "folder",
            disclosureState: isExpanded ? .expanded : .collapsed,
            countBadge: totalServerCount(in: group),
            isSelected: false
        )
        return isExpanded || !searchText.isEmpty ? [row] + childRows : [row]
    }

    private func visibleChildRows(
        for group: RdcImportedGroup,
        indentationLevel: Int
    ) -> [ResourceLibrarySidebarRow] {
        let nestedRows = library.groups.filter { $0.parentID == group.id }.flatMap {
            groupRows(for: $0, indentationLevel: indentationLevel)
        }
        let serverRows = library.servers.filter { $0.groupPathIDs.last == group.id }.compactMap {
            serverRow(for: $0, indentationLevel: indentationLevel)
        }
        return nestedRows + serverRows
    }

    private func serverRow(
        for server: RdcImportedServer,
        indentationLevel: Int
    ) -> ResourceLibrarySidebarRow? {
        guard searchText.isEmpty
            || matches(server.displayName)
            || matches(server.address.rawValue) else {
            return nil
        }
        return ResourceLibrarySidebarRow(
            id: "server:\(server.id)",
            title: server.displayName,
            subtitle: server.address.rawValue,
            representedGroupID: nil,
            representedServerID: server.id,
            kind: .server,
            indentationLevel: indentationLevel,
            symbolName: "desktopcomputer",
            disclosureState: nil,
            countBadge: nil,
            isSelected: server.id == library.selectedServerID
        )
    }

    private func totalServerCount(in group: RdcImportedGroup) -> Int {
        library.servers.reduce(into: 0) { count, server in
            if server.groupPathIDs.contains(group.id) {
                count += 1
            }
        }
    }

    private func matches(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains(searchText)
    }
}

public struct ResourceLibrarySidebarChrome: Equatable, Sendable {
    public let showsSearchField: Bool
    public let rowStyle: ResourceLibrarySidebarRowStyle
    public let showsStatisticsCards: Bool
    public let showsFavoritesSection: Bool

    public static let direction2 = ResourceLibrarySidebarChrome(
        showsSearchField: true,
        rowStyle: .macOSSourceList,
        showsStatisticsCards: false,
        showsFavoritesSection: false
    )
}

public enum ResourceLibrarySidebarRowStyle: Equatable, Sendable {
    case macOSSourceList
}

public struct ResourceLibrarySidebarRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let representedGroupID: String?
    public let representedServerID: String?
    public let kind: ResourceLibrarySidebarRowKind
    public let indentationLevel: Int
    public let symbolName: String
    public let disclosureState: ResourceLibraryDisclosureState?
    public let countBadge: Int?
    public let isSelected: Bool
}

public enum ResourceLibrarySidebarRowKind: Equatable, Sendable {
    case group
    case server
}

public enum ResourceLibraryDisclosureState: Equatable, Sendable {
    case expanded
    case collapsed
}

public enum ResourceLibrarySampleData {
    public static var direction2Document: RdcManDocument {
        RdcManDocument(
            programVersion: "2.92",
            schemaVersion: "3",
            root: RdcGroup(
                name: "示例资源库",
                isExpanded: true,
                logonCredentials: nil,
                groups: [
                    RdcGroup(
                        name: "生产环境",
                        isExpanded: true,
                        logonCredentials: nil,
                        groups: [
                            RdcGroup(
                                name: "业务服务器",
                                isExpanded: true,
                                logonCredentials: nil,
                                groups: [],
                                servers: [
                                    RdcServer(
                                        displayName: "Example Server A",
                                        address: RdcServerAddress("rdp.example.test:6166"),
                                        logonCredentials: nil
                                    ),
                                    RdcServer(
                                        displayName: "Example Server B",
                                        address: RdcServerAddress("198.51.100.57"),
                                        logonCredentials: nil
                                    )
                                ]
                            )
                        ],
                        servers: []
                    ),
                    RdcGroup(
                        name: "测试环境",
                        isExpanded: true,
                        logonCredentials: nil,
                        groups: [],
                        servers: [
                            RdcServer(
                                displayName: "Example Server C",
                                address: RdcServerAddress("rdp.example.test:6021"),
                                logonCredentials: nil
                            )
                        ]
                    )
                ],
                servers: []
            )
        )
    }
}

private struct ResourceLibraryTreeBuilder {
    let sourceID: String
    let selectedServerID: String?
    let expandedGroupIDs: Set<String>
    let searchText: String

    func rows(for root: RdcGroup) -> [ResourceLibrarySidebarRow] {
        groupRows(
            for: root,
            path: [root.name],
            groupSiblingOccurrences: [],
            indentationLevel: 0
        )
    }

    private func groupRows(
        for group: RdcGroup,
        path: [String],
        groupSiblingOccurrences: [Int],
        indentationLevel: Int
    ) -> [ResourceLibrarySidebarRow] {
        let groupID = StableLibraryID.group(
            sourceID: sourceID,
            path: path,
            siblingOccurrences: groupSiblingOccurrences
        )
        let childRows = visibleChildRows(
            for: group,
            path: path,
            groupSiblingOccurrences: groupSiblingOccurrences,
            indentationLevel: indentationLevel + 1
        )
        let groupMatches = matches(group.name)

        guard searchText.isEmpty || groupMatches || !childRows.isEmpty else {
            return []
        }

        let legacyGroupID = path.joined(separator: "/")
        let isExpanded = searchText.isEmpty
            ? expandedGroupIDs.contains(groupID) || expandedGroupIDs.contains(legacyGroupID)
            : true
        let disclosureState: ResourceLibraryDisclosureState = isExpanded ? .expanded : .collapsed
        let groupRow = ResourceLibrarySidebarRow(
            id: "group:\(groupID)",
            title: group.name,
            subtitle: nil,
            representedGroupID: groupID,
            representedServerID: nil,
            kind: .group,
            indentationLevel: indentationLevel,
            symbolName: "folder",
            disclosureState: disclosureState,
            countBadge: totalServerCount(in: group),
            isSelected: false
        )

        if isExpanded || !searchText.isEmpty {
            return [groupRow] + childRows
        }
        return [groupRow]
    }

    private func visibleChildRows(
        for group: RdcGroup,
        path: [String],
        groupSiblingOccurrences: [Int],
        indentationLevel: Int
    ) -> [ResourceLibrarySidebarRow] {
        let childOccurrences = StableLibraryIdentityTraversal.groupSiblingOccurrences(
            in: group.groups
        )
        let nestedGroupRows = zip(group.groups, childOccurrences).flatMap {
            groupRows(
                for: $0.0,
                path: path + [$0.0.name],
                groupSiblingOccurrences: groupSiblingOccurrences + [$0.1],
                indentationLevel: indentationLevel
            )
        }
        let serverOccurrences = StableLibraryIdentityTraversal.serverSiblingOccurrences(
            in: group.servers
        )
        let serverRows = zip(group.servers, serverOccurrences).compactMap {
            serverRow(
                for: $0.0,
                path: path,
                groupSiblingOccurrences: groupSiblingOccurrences,
                siblingOccurrence: $0.1,
                indentationLevel: indentationLevel
            )
        }
        return nestedGroupRows + serverRows
    }

    private func serverRow(
        for server: RdcServer,
        path: [String],
        groupSiblingOccurrences: [Int],
        siblingOccurrence: Int,
        indentationLevel: Int
    ) -> ResourceLibrarySidebarRow? {
        guard searchText.isEmpty || matches(server.displayName) || matches(server.address.rawValue) else {
            return nil
        }

        let serverID = StableLibraryID.server(
            sourceID: sourceID,
            path: path + [server.displayName],
            host: server.address.host,
            port: server.address.port ?? 3_389,
            groupSiblingOccurrences: groupSiblingOccurrences,
            siblingOccurrence: siblingOccurrence
        )
        return ResourceLibrarySidebarRow(
            id: "server:\(serverID)",
            title: server.displayName,
            subtitle: server.address.rawValue,
            representedGroupID: nil,
            representedServerID: serverID,
            kind: .server,
            indentationLevel: indentationLevel,
            symbolName: "desktopcomputer",
            disclosureState: nil,
            countBadge: nil,
            isSelected: serverID == selectedServerID || server.address.rawValue == selectedServerID
        )
    }

    private func totalServerCount(in group: RdcGroup) -> Int {
        group.servers.count + group.groups.map(totalServerCount).reduce(0, +)
    }

    private func matches(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains(searchText)
    }
}

public struct RdcDeletedSourceItem: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case group
        case server
    }

    public let kind: Kind
    public let sourceFingerprint: String

    public init(kind: Kind, sourceFingerprint: String) {
        self.kind = kind
        self.sourceFingerprint = sourceFingerprint
    }
}

public struct RdcLibrarySnapshot: Codable, Equatable, Sendable {
    public var sourceID: String
    public var sourceName: String
    public var sourceLocatorFingerprint: String?
    public var sourceLocatorAliases: Set<String>
    public var programVersion: String
    public var schemaVersion: String
    public var root: RdcGroupSnapshot
    public var deletedSourceItems: Set<RdcDeletedSourceItem>

    public init(
        sourceID: String,
        sourceName: String,
        sourceLocatorFingerprint: String? = nil,
        sourceLocatorAliases: Set<String> = [],
        document: RdcManDocument
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.sourceLocatorFingerprint = sourceLocatorFingerprint
        self.sourceLocatorAliases = sourceLocatorAliases
        programVersion = document.programVersion
        schemaVersion = document.schemaVersion
        root = RdcGroupSnapshot(group: document.root)
        deletedSourceItems = []
        self = normalizedStableIdentity()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        sourceName = try container.decode(String.self, forKey: .sourceName)
        sourceLocatorFingerprint = try container.decodeIfPresent(
            String.self, forKey: .sourceLocatorFingerprint
        )
        sourceLocatorAliases = try container.decodeIfPresent(
            Set<String>.self, forKey: .sourceLocatorAliases
        ) ?? []
        programVersion = try container.decode(String.self, forKey: .programVersion)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        root = try container.decode(RdcGroupSnapshot.self, forKey: .root)
        deletedSourceItems = try container.decodeIfPresent(
            Set<RdcDeletedSourceItem>.self,
            forKey: .deletedSourceItems
        ) ?? []
    }

    public func makeDocument() -> RdcManDocument {
        RdcManDocument(
            programVersion: programVersion,
            schemaVersion: schemaVersion,
            root: root.makeGroup()
        )
    }
}

public struct RdcGroupSnapshot: Codable, Equatable, Sendable {
    public var id: String?
    public var sourceFingerprint: String?
    public var name: String
    public var isExpanded: Bool?
    public var groups: [RdcGroupSnapshot]
    public var servers: [RdcServerSnapshot]

    init(
        id: String?,
        sourceFingerprint: String?,
        name: String,
        isExpanded: Bool?,
        groups: [RdcGroupSnapshot],
        servers: [RdcServerSnapshot]
    ) {
        self.id = id
        self.sourceFingerprint = sourceFingerprint
        self.name = name
        self.isExpanded = isExpanded
        self.groups = groups
        self.servers = servers
    }

    init(group: RdcGroup) {
        id = nil
        sourceFingerprint = nil
        name = group.name
        isExpanded = group.isExpanded
        groups = group.groups.map(RdcGroupSnapshot.init(group:))
        servers = group.servers.map(RdcServerSnapshot.init(server:))
    }

    func makeGroup() -> RdcGroup {
        RdcGroup(
            name: name,
            isExpanded: isExpanded,
            logonCredentials: nil,
            groups: groups.map { $0.makeGroup() },
            servers: servers.map { $0.makeServer() }
        )
    }

    func normalized(
        sourceID: String,
        path: [String],
        siblingOccurrences: [Int]
    ) -> RdcGroupSnapshot {
        var copy = self
        let generatedID = StableLibraryID.group(
            sourceID: sourceID,
            path: path,
            siblingOccurrences: siblingOccurrences
        )
        let generatedSourceFingerprint = StableLibraryID.group(
            sourceID: "source-fingerprint",
            path: path,
            siblingOccurrences: siblingOccurrences
        )
        let shouldBackfillSourceFingerprint = copy.id == nil || copy.id == generatedID
        copy.id = copy.id ?? generatedID
        if copy.sourceFingerprint == nil, shouldBackfillSourceFingerprint {
            copy.sourceFingerprint = generatedSourceFingerprint
        }

        let serverOccurrences = SnapshotIdentityTraversal.serverSiblingOccurrences(in: servers)
        copy.servers = zip(servers, serverOccurrences).map { server, occurrence in
            server.normalized(
                sourceID: sourceID,
                path: path + [server.displayName],
                groupSiblingOccurrences: siblingOccurrences,
                siblingOccurrence: occurrence
            )
        }

        let groupOccurrences = SnapshotIdentityTraversal.groupSiblingOccurrences(in: groups)
        copy.groups = zip(groups, groupOccurrences).map { group, occurrence in
            group.normalized(
                sourceID: sourceID,
                path: path + [group.name],
                siblingOccurrences: siblingOccurrences + [occurrence]
            )
        }
        return copy
    }
}

public struct RdcServerSnapshot: Codable, Equatable, Sendable {
    public var id: String?
    public var sourceFingerprint: String?
    public var displayName: String
    public var address: String

    init(server: RdcServer) {
        id = nil
        sourceFingerprint = nil
        displayName = server.displayName
        address = server.address.rawValue
    }

    func makeServer() -> RdcServer {
        RdcServer(
            displayName: displayName,
            address: RdcServerAddress(address),
            logonCredentials: nil
        )
    }

    func normalized(
        sourceID: String,
        path: [String],
        groupSiblingOccurrences: [Int],
        siblingOccurrence: Int
    ) -> RdcServerSnapshot {
        var copy = self
        // Stable IDs shipped before IPv6 endpoint parsing existed. Keep those
        // exact split semantics frozen so a legacy snapshot with missing IDs
        // still resolves existing credential bindings after an upgrade.
        let legacyAddress = LegacyStableAddress(address)
        let generatedID = StableLibraryID.server(
            sourceID: sourceID,
            path: path,
            host: legacyAddress.host,
            port: legacyAddress.port ?? 3_389,
            groupSiblingOccurrences: groupSiblingOccurrences,
            siblingOccurrence: siblingOccurrence
        )
        let generatedSourceFingerprint = StableLibraryID.server(
            sourceID: "source-fingerprint",
            path: path,
            host: legacyAddress.host,
            port: legacyAddress.port ?? 3_389,
            groupSiblingOccurrences: groupSiblingOccurrences,
            siblingOccurrence: siblingOccurrence
        )
        let shouldBackfillSourceFingerprint = copy.id == nil || copy.id == generatedID
        copy.id = copy.id ?? generatedID
        if copy.sourceFingerprint == nil, shouldBackfillSourceFingerprint {
            copy.sourceFingerprint = generatedSourceFingerprint
        }
        return copy
    }
}

private struct LegacyStableAddress {
    let host: String
    let port: Int?

    init(_ rawValue: String) {
        let parts = rawValue.split(
            separator: ":", maxSplits: 1, omittingEmptySubsequences: false
        )
        if parts.count == 2, let parsedPort = Int(parts[1]) {
            host = String(parts[0])
            port = parsedPort
        } else {
            host = rawValue
            port = nil
        }
    }
}

public extension RdcLibrarySnapshot {
    var allServers: [RdcServerSnapshot] {
        root.allServers
    }

    func normalizedStableIdentity() -> RdcLibrarySnapshot {
        var copy = self
        copy.root = copy.root.normalized(
            sourceID: sourceID,
            path: [copy.root.name],
            siblingOccurrences: []
        )
        return copy
    }

    func makeLibrary(selectedServerID: String? = nil) -> RdcImportedLibrary {
        RdcImportedLibrary(
            snapshot: normalizedStableIdentity(),
            selectedServerID: selectedServerID
        )
    }
}

private extension RdcGroupSnapshot {
    var allServers: [RdcServerSnapshot] {
        servers + groups.flatMap(\.allServers)
    }
}

private enum SnapshotIdentityTraversal {
    static func groupSiblingOccurrences(in groups: [RdcGroupSnapshot]) -> [Int] {
        occurrences(for: groups.map(\.name))
    }

    static func serverSiblingOccurrences(in servers: [RdcServerSnapshot]) -> [Int] {
        occurrences(for: servers.map {
            let address = RdcServerAddress($0.address)
            return StableLibraryID.server(
                sourceID: "",
                path: [$0.displayName],
                host: address.host,
                port: address.port ?? 3_389
            )
        })
    }

    private static func occurrences(for keys: [String]) -> [Int] {
        var counts: [String: Int] = [:]
        return keys.map { key in
            let occurrence = counts[key, default: 0]
            counts[key] = occurrence + 1
            return occurrence
        }
    }
}

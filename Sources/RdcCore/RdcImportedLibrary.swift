import CryptoKit
import Foundation

public enum StableLibraryID {
    public static func sourceLocatorFingerprint(for locator: String) -> String {
        "source-locator-" + digest(domain: "source-locator", components: [locator])
    }

    public static func group(sourceID: String, path: [String]) -> String {
        "group-" + digest(domain: "group", components: [sourceID] + path)
    }

    public static func server(
        sourceID: String,
        path: [String],
        host: String,
        port: Int
    ) -> String {
        "server-" + digest(
            domain: "server",
            components: [sourceID] + path + [host, String(port)]
        )
    }

    static func group(
        sourceID: String,
        path: [String],
        siblingOccurrences: [Int]
    ) -> String {
        guard siblingOccurrences.contains(where: { $0 != 0 }) else {
            return group(sourceID: sourceID, path: path)
        }
        return "group-" + digest(
            domain: "group-occurrence",
            components: [sourceID] + path + siblingOccurrences.map(String.init)
        )
    }

    static func server(
        sourceID: String,
        path: [String],
        host: String,
        port: Int,
        groupSiblingOccurrences: [Int],
        siblingOccurrence: Int
    ) -> String {
        guard siblingOccurrence != 0 || groupSiblingOccurrences.contains(where: { $0 != 0 }) else {
            return server(sourceID: sourceID, path: path, host: host, port: port)
        }
        return "server-" + digest(
            domain: "server-occurrence",
            components: [sourceID] + path + [host, String(port)]
                + groupSiblingOccurrences.map(String.init) + [String(siblingOccurrence)]
        )
    }

    static func compatibilitySourceID(for document: RdcManDocument) -> String {
        var components = [document.programVersion, document.schemaVersion]
        appendCompatibilityComponents(for: document.root, to: &components)
        return "source-" + digest(domain: "compatibility-source", components: components)
    }

    private static func appendCompatibilityComponents(
        for group: RdcGroup,
        to components: inout [String]
    ) {
        components.append("group")
        components.append(group.name)
        components.append(group.isExpanded.map(String.init) ?? "nil")
        for server in group.servers {
            components.append("server")
            components.append(server.displayName)
            components.append(server.address.rawValue)
        }
        for child in group.groups {
            appendCompatibilityComponents(for: child, to: &components)
        }
        components.append("end-group")
    }

    private static func digest(domain: String, components: [String]) -> String {
        var input = Data()
        append(domain, to: &input)
        append(String(components.count), to: &input)
        for component in components {
            append(component, to: &input)
        }
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ component: String, to data: inout Data) {
        let bytes = Data(component.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}

enum StableLibraryIdentityTraversal {
    static func groupSiblingOccurrences(in groups: [RdcGroup]) -> [Int] {
        occurrences(for: groups.map(\.name))
    }

    static func serverSiblingOccurrences(in servers: [RdcServer]) -> [Int] {
        occurrences(for: servers.map {
            StableLibraryID.server(
                sourceID: "",
                path: [$0.displayName],
                host: $0.address.host,
                port: $0.address.port ?? 3_389
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

public struct RdcImportedLibrary: Equatable, Sendable {
    public let document: RdcManDocument
    public let sourceID: String
    public let sourceName: String
    public let groups: [RdcImportedGroup]
    public let servers: [RdcImportedServer]
    public let selectedServerID: String?

    public init(
        document: RdcManDocument,
        sourceID: String,
        sourceName: String,
        selectedServerID: String? = nil
    ) {
        let flattened = RdcImportedLibrary.flatten(document.root, sourceID: sourceID)
        self.document = document
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.groups = flattened.groups
        self.servers = flattened.servers
        self.selectedServerID = selectedServerID ?? flattened.servers.first?.id
    }

    public init(snapshot: RdcLibrarySnapshot, selectedServerID: String? = nil) {
        let normalized = snapshot.normalizedStableIdentity()
        let flattened = RdcImportedLibrary.flatten(normalized.root)
        document = normalized.makeDocument()
        sourceID = normalized.sourceID
        sourceName = normalized.sourceName
        groups = flattened.groups
        servers = flattened.servers
        self.selectedServerID = selectedServerID ?? flattened.servers.first?.id
    }

    public init(
        document: RdcManDocument,
        sourceName: String,
        selectedServerID: String? = nil
    ) {
        self.init(
            document: document,
            sourceID: StableLibraryID.compatibilitySourceID(for: document),
            sourceName: sourceName,
            selectedServerID: selectedServerID
        )
    }

    public var selectedServer: RdcImportedServer? {
        guard let selectedServerID else {
            return nil
        }
        return servers.first { $0.id == selectedServerID }
    }

    public func selectingServer(id: String) -> RdcImportedLibrary {
        RdcImportedLibrary(
            document: document,
            sourceID: sourceID,
            sourceName: sourceName,
            groups: groups,
            servers: servers,
            selectedServerID: id
        )
    }

    private init(
        document: RdcManDocument,
        sourceID: String,
        sourceName: String,
        groups: [RdcImportedGroup],
        servers: [RdcImportedServer],
        selectedServerID: String?
    ) {
        self.document = document
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.groups = groups
        self.servers = servers
        self.selectedServerID = selectedServerID
    }

    private static func flatten(
        _ root: RdcGroupSnapshot
    ) -> (groups: [RdcImportedGroup], servers: [RdcImportedServer]) {
        var groups: [RdcImportedGroup] = []
        var servers: [RdcImportedServer] = []
        flatten(
            group: root,
            path: [root.name],
            groupPathIDs: [],
            parentID: nil,
            groups: &groups,
            servers: &servers
        )
        return (groups, servers)
    }

    private static func flatten(
        group: RdcGroupSnapshot,
        path: [String],
        groupPathIDs: [String],
        parentID: String?,
        groups: inout [RdcImportedGroup],
        servers: inout [RdcImportedServer]
    ) {
        guard let groupID = group.id else {
            preconditionFailure("Snapshot identity must be normalized before flattening")
        }
        let currentGroupPathIDs = groupPathIDs + [groupID]
        groups.append(
            RdcImportedGroup(id: groupID, name: group.name, path: path, parentID: parentID)
        )

        for server in group.servers {
            guard let serverID = server.id else {
                preconditionFailure("Snapshot identity must be normalized before flattening")
            }
            servers.append(
                RdcImportedServer(
                    id: serverID,
                    displayName: server.displayName,
                    address: RdcServerAddress(server.address),
                    credentials: nil,
                    groupPathIDs: currentGroupPathIDs
                )
            )
        }

        for child in group.groups {
            flatten(
                group: child,
                path: path + [child.name],
                groupPathIDs: currentGroupPathIDs,
                parentID: groupID,
                groups: &groups,
                servers: &servers
            )
        }
    }

    private static func flatten(
        _ root: RdcGroup,
        sourceID: String
    ) -> (groups: [RdcImportedGroup], servers: [RdcImportedServer]) {
        var groups: [RdcImportedGroup] = []
        var servers: [RdcImportedServer] = []
        flatten(
            group: root,
            sourceID: sourceID,
            inheritedCredentials: root.logonCredentials,
            path: [root.name],
            groupSiblingOccurrences: [],
            groupPathIDs: [],
            parentID: nil,
            groups: &groups,
            servers: &servers
        )
        return (groups, servers)
    }

    private static func flatten(
        group: RdcGroup,
        sourceID: String,
        inheritedCredentials: RdcLogonCredentials?,
        path: [String],
        groupSiblingOccurrences: [Int],
        groupPathIDs: [String],
        parentID: String?,
        groups: inout [RdcImportedGroup],
        servers: inout [RdcImportedServer]
    ) {
        let groupID = StableLibraryID.group(
            sourceID: sourceID,
            path: path,
            siblingOccurrences: groupSiblingOccurrences
        )
        let currentGroupPathIDs = groupPathIDs + [groupID]
        let currentCredentials = group.logonCredentials ?? inheritedCredentials
        groups.append(
            RdcImportedGroup(id: groupID, name: group.name, path: path, parentID: parentID)
        )

        let serverOccurrences = StableLibraryIdentityTraversal.serverSiblingOccurrences(
            in: group.servers
        )
        for (server, siblingOccurrence) in zip(group.servers, serverOccurrences) {
            let serverPath = path + [server.displayName]
            servers.append(
                RdcImportedServer(
                    id: StableLibraryID.server(
                        sourceID: sourceID,
                        path: serverPath,
                        host: server.address.host,
                        port: server.address.port ?? 3_389,
                        groupSiblingOccurrences: groupSiblingOccurrences,
                        siblingOccurrence: siblingOccurrence
                    ),
                    displayName: server.displayName,
                    address: server.address,
                    credentials: server.logonCredentials ?? currentCredentials,
                    groupPathIDs: currentGroupPathIDs
                )
            )
        }

        let childOccurrences = StableLibraryIdentityTraversal.groupSiblingOccurrences(
            in: group.groups
        )
        for (child, siblingOccurrence) in zip(group.groups, childOccurrences) {
            flatten(
                group: child,
                sourceID: sourceID,
                inheritedCredentials: currentCredentials,
                path: path + [child.name],
                groupSiblingOccurrences: groupSiblingOccurrences + [siblingOccurrence],
                groupPathIDs: currentGroupPathIDs,
                parentID: groupID,
                groups: &groups,
                servers: &servers
            )
        }
    }
}

public struct RdcImportedGroup: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let path: [String]
    public let parentID: String?

    public init(id: String, name: String, path: [String], parentID: String?) {
        self.id = id
        self.name = name
        self.path = path
        self.parentID = parentID
    }
}

public struct RdcImportedServer: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let address: RdcServerAddress
    public let credentials: RdcLogonCredentials?
    public let groupPathIDs: [String]

    public init(
        id: String,
        displayName: String,
        address: RdcServerAddress,
        credentials: RdcLogonCredentials?,
        groupPathIDs: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.credentials = credentials
        self.groupPathIDs = groupPathIDs
    }

    public var connectionRequest: RdpConnectionRequest {
        RdpConnectionRequest(
            serverID: id,
            host: address.host,
            port: address.port,
            username: credentials?.userName,
            domain: credentials?.domain
        )
    }
}

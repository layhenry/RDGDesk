import Foundation
import Darwin

public struct ServerPropertiesDraft: Equatable, Sendable {
    public var displayName: String
    public var host: String
    public var port: Int

    public init(displayName: String, host: String, port: Int) {
        self.displayName = displayName
        self.host = host
        self.port = port
    }

    public func validated() throws -> ServerPropertiesDraft {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ResourceLibraryEditError.emptyName
        }
        guard !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }),
              !host.contains("/"),
              !host.contains("://"),
              !host.contains("?"),
              !host.contains("@"),
              !host.contains("["),
              !host.contains("]"),
              isValidHostShape(host) else {
            throw ResourceLibraryEditError.invalidHost
        }
        guard (1...65_535).contains(port) else {
            throw ResourceLibraryEditError.invalidPort
        }
        return ServerPropertiesDraft(displayName: trimmedName, host: host, port: port)
    }

    private func isValidHostShape(_ value: String) -> Bool {
        let colonCount = value.filter { $0 == ":" }.count
        if colonCount == 0 {
            guard value.utf8.count <= 253 else { return false }
            let labels = value.split(separator: ".", omittingEmptySubsequences: false)
            return !labels.isEmpty && labels.allSatisfy { label in
                !label.isEmpty && label.utf8.count <= 63
                    && label.first != "-" && label.last != "-"
                    && label.allSatisfy { character in
                        character.isASCII
                            && (character.isLetter || character.isNumber || character == "-")
                    }
            }
        }
        guard colonCount >= 2 else { return false }
        var address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }
}

public struct GroupPropertiesDraft: Equatable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }

    public func validated() throws -> GroupPropertiesDraft {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ResourceLibraryEditError.emptyName
        }
        return GroupPropertiesDraft(name: trimmedName)
    }
}

public struct ResourceDeletionImpact: Equatable, Sendable {
    public let groupCount: Int
    public let serverCount: Int
    public let containsSelectedServer: Bool

    public init(groupCount: Int, serverCount: Int, containsSelectedServer: Bool) {
        self.groupCount = groupCount
        self.serverCount = serverCount
        self.containsSelectedServer = containsSelectedServer
    }
}

public struct ResourceDeletionResult: Equatable, Sendable {
    public let snapshot: RdcLibrarySnapshot?
    public let impact: ResourceDeletionImpact
    public let selectedServerID: String?
    public let removedGroupIDs: Set<String>
    public let removedServerIDs: Set<String>
    public let addedTombstones: Set<RdcDeletedSourceItem>

    public init(
        snapshot: RdcLibrarySnapshot?,
        impact: ResourceDeletionImpact,
        selectedServerID: String?,
        removedGroupIDs: Set<String>,
        removedServerIDs: Set<String>,
        addedTombstones: Set<RdcDeletedSourceItem>
    ) {
        self.snapshot = snapshot
        self.impact = impact
        self.selectedServerID = selectedServerID
        self.removedGroupIDs = removedGroupIDs
        self.removedServerIDs = removedServerIDs
        self.addedTombstones = addedTombstones
    }
}

public enum ResourceLibraryEditError: Error, Equatable, Sendable {
    case missingResource
    case emptyName
    case duplicateSiblingGroupName
    case invalidHost
    case invalidPort
    case cannotMoveRoot
    case cannotDeleteRoot
    case cyclicGroupMove
}

public enum ResourceLibraryEditor {
    public static func updateServer(
        in snapshot: RdcLibrarySnapshot,
        id: String,
        draft: ServerPropertiesDraft
    ) throws -> RdcLibrarySnapshot {
        let validated = try draft.validated()
        var copy = snapshot
        guard mutateGroup(&copy.root, where: { group in
            guard let index = group.servers.firstIndex(where: { $0.id == id }) else {
                return false
            }
            group.servers[index].displayName = validated.displayName
            let serializedHost = validated.host.contains(":")
                ? "[\(validated.host)]" : validated.host
            group.servers[index].address = "\(serializedHost):\(validated.port)"
            return true
        }) else {
            throw ResourceLibraryEditError.missingResource
        }
        return copy
    }

    public static func updateGroup(
        in snapshot: RdcLibrarySnapshot,
        id: String,
        draft: GroupPropertiesDraft
    ) throws -> RdcLibrarySnapshot {
        let validated = try draft.validated()
        var copy = snapshot
        if copy.root.id == id {
            copy.root.name = validated.name
            return copy
        }
        var duplicate = false
        guard mutateGroup(&copy.root, where: { parent in
            guard let index = parent.groups.firstIndex(where: { $0.id == id }) else {
                return false
            }
            guard !parent.groups.enumerated().contains(where: {
                $0.offset != index && $0.element.name == validated.name
            }) else {
                duplicate = true
                return true
            }
            parent.groups[index].name = validated.name
            return true
        }) else {
            throw ResourceLibraryEditError.missingResource
        }
        if duplicate {
            throw ResourceLibraryEditError.duplicateSiblingGroupName
        }
        return copy
    }

    public static func createChildGroup(
        in snapshot: RdcLibrarySnapshot,
        parentID: String,
        name: String
    ) throws -> RdcLibrarySnapshot {
        let validated = try GroupPropertiesDraft(name: name).validated()
        var copy = snapshot
        var duplicate = false
        guard mutateGroup(&copy.root, where: { parent in
            guard parent.id == parentID else { return false }
            guard !parent.groups.contains(where: { $0.name == validated.name }) else {
                duplicate = true
                return true
            }
            parent.groups.append(
                RdcGroupSnapshot(
                    id: UUID().uuidString,
                    sourceFingerprint: nil,
                    name: validated.name,
                    isExpanded: true,
                    groups: [],
                    servers: []
                )
            )
            return true
        }) else {
            throw ResourceLibraryEditError.missingResource
        }
        if duplicate {
            throw ResourceLibraryEditError.duplicateSiblingGroupName
        }
        return copy
    }

    public static func moveServer(
        in snapshot: RdcLibrarySnapshot,
        id: String,
        destinationGroupID: String
    ) throws -> RdcLibrarySnapshot {
        guard group(snapshot: snapshot.root, id: destinationGroupID) != nil else {
            throw ResourceLibraryEditError.missingResource
        }
        var copy = snapshot
        guard let server = removeServer(from: &copy.root, id: id) else {
            throw ResourceLibraryEditError.missingResource
        }
        _ = mutateGroup(&copy.root, where: { destination in
            guard destination.id == destinationGroupID else { return false }
            destination.servers.append(server)
            return true
        })
        return copy
    }

    public static func moveGroup(
        in snapshot: RdcLibrarySnapshot,
        id: String,
        destinationGroupID: String
    ) throws -> RdcLibrarySnapshot {
        guard snapshot.root.id != id else {
            throw ResourceLibraryEditError.cannotMoveRoot
        }
        guard let moving = group(snapshot: snapshot.root, id: id),
              let destination = group(snapshot: snapshot.root, id: destinationGroupID) else {
            throw ResourceLibraryEditError.missingResource
        }
        guard !containsGroup(moving, id: destinationGroupID) else {
            throw ResourceLibraryEditError.cyclicGroupMove
        }
        guard !destination.groups.contains(where: { $0.id != id && $0.name == moving.name }) else {
            throw ResourceLibraryEditError.duplicateSiblingGroupName
        }
        var copy = snapshot
        guard let removed = removeGroup(from: &copy.root, id: id) else {
            throw ResourceLibraryEditError.missingResource
        }
        _ = mutateGroup(&copy.root, where: { group in
            guard group.id == destinationGroupID else { return false }
            group.groups.append(removed)
            return true
        })
        return copy
    }

    public static func deletionImpact(
        in snapshot: RdcLibrarySnapshot,
        groupID: String,
        selectedServerID: String?
    ) throws -> ResourceDeletionImpact {
        guard let target = group(snapshot: snapshot.root, id: groupID) else {
            throw ResourceLibraryEditError.missingResource
        }
        let resources = resources(in: target)
        return ResourceDeletionImpact(
            groupCount: resources.groupIDs.count,
            serverCount: resources.serverIDs.count,
            containsSelectedServer: selectedServerID.map(resources.serverIDs.contains) ?? false
        )
    }

    public static func deleteServer(
        in snapshot: RdcLibrarySnapshot,
        id: String,
        selectedServerID: String?
    ) throws -> ResourceDeletionResult {
        let selectionContext = selectionContext(
            in: snapshot,
            selectedServerID: selectedServerID
        )
        var copy = snapshot
        guard let removed = removeServer(from: &copy.root, id: id) else {
            throw ResourceLibraryEditError.missingResource
        }
        let tombstones = tombstones(for: [removed])
        let added = tombstones.subtracting(copy.deletedSourceItems)
        copy.deletedSourceItems.formUnion(tombstones)
        let removedIDs = Set([removed.id].compactMap { $0 })
        return ResourceDeletionResult(
            snapshot: copy,
            impact: ResourceDeletionImpact(
                groupCount: 0,
                serverCount: 1,
                containsSelectedServer: selectedServerID == removed.id
            ),
            selectedServerID: fallbackSelection(
                selectedServerID,
                removedIDs: removedIDs,
                context: selectionContext,
                newOrder: copy.allServers.compactMap(\.id)
            ),
            removedGroupIDs: [],
            removedServerIDs: removedIDs,
            addedTombstones: added
        )
    }

    public static func deleteGroup(
        in snapshot: RdcLibrarySnapshot,
        id: String,
        selectedServerID: String?
    ) throws -> ResourceDeletionResult {
        guard let target = group(snapshot: snapshot.root, id: id) else {
            throw ResourceLibraryEditError.missingResource
        }
        if snapshot.root.id == id {
            throw ResourceLibraryEditError.cannotDeleteRoot
        }
        let selectionContext = selectionContext(
            in: snapshot,
            selectedServerID: selectedServerID
        )
        let removed = resources(in: target)
        var copy = snapshot
        guard removeGroup(from: &copy.root, id: id) != nil else {
            throw ResourceLibraryEditError.missingResource
        }
        let allTombstones = tombstones(for: target)
        let added = allTombstones.subtracting(copy.deletedSourceItems)
        copy.deletedSourceItems.formUnion(allTombstones)
        return ResourceDeletionResult(
            snapshot: copy,
            impact: ResourceDeletionImpact(
                groupCount: removed.groupIDs.count,
                serverCount: removed.serverIDs.count,
                containsSelectedServer: selectedServerID.map(removed.serverIDs.contains) ?? false
            ),
            selectedServerID: fallbackSelection(
                selectedServerID,
                removedIDs: removed.serverIDs,
                context: selectionContext,
                newOrder: copy.allServers.compactMap(\.id)
            ),
            removedGroupIDs: removed.groupIDs,
            removedServerIDs: removed.serverIDs,
            addedTombstones: added
        )
    }

    public static func removeLibrary(
        _ snapshot: RdcLibrarySnapshot,
        selectedServerID: String?
    ) -> ResourceDeletionResult {
        let removed = resources(in: snapshot.root)
        let allTombstones = tombstones(for: snapshot.root)
        return ResourceDeletionResult(
            snapshot: nil,
            impact: ResourceDeletionImpact(
                groupCount: removed.groupIDs.count,
                serverCount: removed.serverIDs.count,
                containsSelectedServer: selectedServerID.map(removed.serverIDs.contains) ?? false
            ),
            selectedServerID: nil,
            removedGroupIDs: removed.groupIDs,
            removedServerIDs: removed.serverIDs,
            addedTombstones: allTombstones.subtracting(snapshot.deletedSourceItems)
        )
    }

    public static func mergeReimport(
        existing: RdcLibrarySnapshot,
        imported: RdcLibrarySnapshot,
        restoreDeletedItems: Bool
    ) -> RdcLibrarySnapshot {
        guard existing.sourceID == imported.sourceID else {
            return existing
        }
        let normalizedImport = imported.normalizedStableIdentity()
        let tombstones: Set<RdcDeletedSourceItem> = restoreDeletedItems
            ? []
            : existing.deletedSourceItems
        let importedFingerprints = sourceFingerprints(in: normalizedImport.root)

        var merged = existing
        merged.sourceID = normalizedImport.sourceID
        merged.sourceName = normalizedImport.sourceName
        merged.sourceLocatorFingerprint = normalizedImport.sourceLocatorFingerprint
            ?? existing.sourceLocatorFingerprint
        merged.sourceLocatorAliases.formUnion(existing.sourceLocatorAliases)
        merged.sourceLocatorAliases.formUnion(normalizedImport.sourceLocatorAliases)
        merged.programVersion = normalizedImport.programVersion
        merged.schemaVersion = normalizedImport.schemaVersion
        merged.deletedSourceItems = tombstones
        merged.root = pruneExisting(
            merged.root,
            importedFingerprints: importedFingerprints,
            tombstones: tombstones,
            isRoot: true
        ) ?? merged.root

        mergeImportedGroup(
            normalizedImport.root,
            into: &merged.root,
            tombstones: tombstones
        )
        return merged
    }
}

private extension ResourceLibraryEditor {
    struct SelectionContext {
        let groupServerOrder: [String]
        let libraryOrder: [String]
    }

    struct ResourceSet {
        var groupIDs: Set<String> = []
        var serverIDs: Set<String> = []
    }

    struct SourceFingerprintSet {
        var groups: Set<String> = []
        var servers: Set<String> = []
    }

    @discardableResult
    static func mutateGroup(
        _ group: inout RdcGroupSnapshot,
        where mutation: (inout RdcGroupSnapshot) -> Bool
    ) -> Bool {
        if mutation(&group) {
            return true
        }
        for index in group.groups.indices {
            if mutateGroup(&group.groups[index], where: mutation) {
                return true
            }
        }
        return false
    }

    static func group(snapshot: RdcGroupSnapshot, id: String) -> RdcGroupSnapshot? {
        if snapshot.id == id { return snapshot }
        for child in snapshot.groups {
            if let match = group(snapshot: child, id: id) { return match }
        }
        return nil
    }

    static func containsGroup(_ group: RdcGroupSnapshot, id: String) -> Bool {
        Self.group(snapshot: group, id: id) != nil
    }

    static func removeServer(
        from group: inout RdcGroupSnapshot,
        id: String
    ) -> RdcServerSnapshot? {
        if let index = group.servers.firstIndex(where: { $0.id == id }) {
            return group.servers.remove(at: index)
        }
        for index in group.groups.indices {
            if let server = removeServer(from: &group.groups[index], id: id) {
                return server
            }
        }
        return nil
    }

    static func removeGroup(
        from group: inout RdcGroupSnapshot,
        id: String
    ) -> RdcGroupSnapshot? {
        if let index = group.groups.firstIndex(where: { $0.id == id }) {
            return group.groups.remove(at: index)
        }
        for index in group.groups.indices {
            if let removed = removeGroup(from: &group.groups[index], id: id) {
                return removed
            }
        }
        return nil
    }

    static func resources(in group: RdcGroupSnapshot) -> ResourceSet {
        var result = ResourceSet()
        if let id = group.id { result.groupIDs.insert(id) }
        result.serverIDs.formUnion(group.servers.compactMap(\.id))
        for child in group.groups {
            let childResources = resources(in: child)
            result.groupIDs.formUnion(childResources.groupIDs)
            result.serverIDs.formUnion(childResources.serverIDs)
        }
        return result
    }

    static func tombstones(for servers: [RdcServerSnapshot]) -> Set<RdcDeletedSourceItem> {
        Set(servers.compactMap { server in
            server.sourceFingerprint.map {
                RdcDeletedSourceItem(kind: .server, sourceFingerprint: $0)
            }
        })
    }

    static func tombstones(for group: RdcGroupSnapshot) -> Set<RdcDeletedSourceItem> {
        var result = tombstones(for: group.servers)
        if let fingerprint = group.sourceFingerprint {
            result.insert(RdcDeletedSourceItem(kind: .group, sourceFingerprint: fingerprint))
        }
        for child in group.groups {
            result.formUnion(tombstones(for: child))
        }
        return result
    }

    static func fallbackSelection(
        _ selectedServerID: String?,
        removedIDs: Set<String>,
        context: SelectionContext?,
        newOrder: [String]
    ) -> String? {
        guard let selectedServerID, removedIDs.contains(selectedServerID) else {
            return selectedServerID
        }
        guard let context else {
            return nil
        }
        let surviving = Set(newOrder)

        if let groupIndex = context.groupServerOrder.firstIndex(of: selectedServerID) {
            if groupIndex + 1 < context.groupServerOrder.count,
               let next = context.groupServerOrder[(groupIndex + 1)...].first(
                   where: surviving.contains
               ) {
                return next
            }
            if let previous = context.groupServerOrder[..<groupIndex]
                .reversed()
                .first(where: surviving.contains) {
                return previous
            }
        }

        if let libraryIndex = context.libraryOrder.firstIndex(of: selectedServerID),
           libraryIndex + 1 < context.libraryOrder.count,
           let next = context.libraryOrder[(libraryIndex + 1)...].first(
               where: surviving.contains
           ) {
            return next
        }
        return nil
    }

    static func selectionContext(
        in snapshot: RdcLibrarySnapshot,
        selectedServerID: String?
    ) -> SelectionContext? {
        guard let selectedServerID,
              let groupServerOrder = directServerOrder(
                  containing: selectedServerID,
                  in: snapshot.root
              ) else {
            return nil
        }
        return SelectionContext(
            groupServerOrder: groupServerOrder,
            libraryOrder: snapshot.allServers.compactMap(\.id)
        )
    }

    static func directServerOrder(
        containing serverID: String,
        in group: RdcGroupSnapshot
    ) -> [String]? {
        if group.servers.contains(where: { $0.id == serverID }) {
            return group.servers.compactMap(\.id)
        }
        for child in group.groups {
            if let order = directServerOrder(containing: serverID, in: child) {
                return order
            }
        }
        return nil
    }

    static func sourceFingerprints(in group: RdcGroupSnapshot) -> SourceFingerprintSet {
        var result = SourceFingerprintSet()
        if let fingerprint = group.sourceFingerprint { result.groups.insert(fingerprint) }
        result.servers.formUnion(group.servers.compactMap(\.sourceFingerprint))
        for child in group.groups {
            let childResult = sourceFingerprints(in: child)
            result.groups.formUnion(childResult.groups)
            result.servers.formUnion(childResult.servers)
        }
        return result
    }

    static func pruneExisting(
        _ group: RdcGroupSnapshot,
        importedFingerprints: SourceFingerprintSet,
        tombstones: Set<RdcDeletedSourceItem>,
        isRoot: Bool = false
    ) -> RdcGroupSnapshot? {
        if !isRoot, let fingerprint = group.sourceFingerprint {
            let marker = RdcDeletedSourceItem(kind: .group, sourceFingerprint: fingerprint)
            guard importedFingerprints.groups.contains(fingerprint), !tombstones.contains(marker) else {
                return nil
            }
        }
        var copy = group
        copy.servers = group.servers.filter { server in
            guard let fingerprint = server.sourceFingerprint else { return true }
            return importedFingerprints.servers.contains(fingerprint)
                && !tombstones.contains(
                    RdcDeletedSourceItem(kind: .server, sourceFingerprint: fingerprint)
                )
        }
        copy.groups = group.groups.compactMap {
            pruneExisting(
                $0,
                importedFingerprints: importedFingerprints,
                tombstones: tombstones
            )
        }
        return copy
    }

    static func mergeImportedGroup(
        _ imported: RdcGroupSnapshot,
        into mergedRoot: inout RdcGroupSnapshot,
        tombstones: Set<RdcDeletedSourceItem>
    ) {
        guard let targetID = matchingGroupID(
            fingerprint: imported.sourceFingerprint,
            in: mergedRoot
        ) ?? mergedRoot.id else { return }

        for server in imported.servers where !isTombstoned(server, tombstones: tombstones) {
            if let fingerprint = server.sourceFingerprint,
               containsServer(fingerprint: fingerprint, in: mergedRoot) {
                continue
            }
            _ = mutateGroup(&mergedRoot, where: { target in
                guard target.id == targetID else { return false }
                target.servers.append(server)
                return true
            })
        }

        for child in imported.groups where !isTombstoned(child, tombstones: tombstones) {
            if !containsGroup(fingerprint: child.sourceFingerprint, in: mergedRoot) {
                let filtered = filteredImportedSubtree(
                    child,
                    existingRoot: mergedRoot,
                    tombstones: tombstones
                )
                _ = mutateGroup(&mergedRoot, where: { target in
                    guard target.id == targetID else { return false }
                    target.groups.append(filtered)
                    return true
                })
            }
            mergeImportedGroup(child, into: &mergedRoot, tombstones: tombstones)
        }
    }

    static func filteredImportedSubtree(
        _ group: RdcGroupSnapshot,
        existingRoot: RdcGroupSnapshot,
        tombstones: Set<RdcDeletedSourceItem>
    ) -> RdcGroupSnapshot {
        var copy = group
        copy.servers = group.servers.filter {
            !isTombstoned($0, tombstones: tombstones)
                && !containsServer(fingerprint: $0.sourceFingerprint, in: existingRoot)
        }
        copy.groups = group.groups.compactMap { child in
            guard !isTombstoned(child, tombstones: tombstones),
                  !containsGroup(fingerprint: child.sourceFingerprint, in: existingRoot) else {
                return nil
            }
            return filteredImportedSubtree(
                child,
                existingRoot: existingRoot,
                tombstones: tombstones
            )
        }
        return copy
    }

    static func matchingGroupID(
        fingerprint: String?,
        in group: RdcGroupSnapshot
    ) -> String? {
        if group.sourceFingerprint == fingerprint, fingerprint != nil { return group.id }
        for child in group.groups {
            if let id = matchingGroupID(fingerprint: fingerprint, in: child) { return id }
        }
        return nil
    }

    static func containsGroup(fingerprint: String?, in group: RdcGroupSnapshot) -> Bool {
        guard let fingerprint else { return false }
        return matchingGroupID(fingerprint: fingerprint, in: group) != nil
    }

    static func containsServer(fingerprint: String?, in group: RdcGroupSnapshot) -> Bool {
        guard let fingerprint else { return false }
        if group.servers.contains(where: { $0.sourceFingerprint == fingerprint }) { return true }
        return group.groups.contains { containsServer(fingerprint: fingerprint, in: $0) }
    }

    static func isTombstoned(
        _ group: RdcGroupSnapshot,
        tombstones: Set<RdcDeletedSourceItem>
    ) -> Bool {
        group.sourceFingerprint.map {
            tombstones.contains(RdcDeletedSourceItem(kind: .group, sourceFingerprint: $0))
        } ?? false
    }

    static func isTombstoned(
        _ server: RdcServerSnapshot,
        tombstones: Set<RdcDeletedSourceItem>
    ) -> Bool {
        server.sourceFingerprint.map {
            tombstones.contains(RdcDeletedSourceItem(kind: .server, sourceFingerprint: $0))
        } ?? false
    }
}
